# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Funnel::ConversationClassifier
  POLICY_VERSION = Umi::Funnel::ClassificationClient::VERSION
  InvalidDecision = Umi::Funnel::ClassificationClient::InvalidDecision

  def self.mode
    value = ENV.fetch('UMI_FUNNEL_CLASSIFIER_MODE', 'off')
    raise ArgumentError, 'Invalid classifier mode' unless %w[off shadow auto].include?(value)

    value
  end

  def self.inbox_ids
    ENV.fetch('UMI_FUNNEL_CLASSIFIER_INBOX_IDS').split(',').map do |value|
      raise ArgumentError, 'Invalid classifier inbox ID' unless value.match?(/\A[1-9]\d*\z/)

      value.to_i
    end
  end

  def self.public_messages
    # Message's store coder serializes JSON into a string inside the JSON column.
    attributes = "CASE WHEN json_typeof(content_attributes) = 'string' THEN (content_attributes #>> '{}')::json ELSE content_attributes END"
    Message.where(private: false, created_at: Umi::Funnel::Configuration.started_at..Time.current)
           .where("COALESCE((#{attributes}) ->> 'umi_recovered', 'false') != 'true'")
           .where("COALESCE((#{attributes}) ->> 'deleted', 'false') != 'true'")
  end

  def self.sources
    messages = public_messages.incoming
    Umi::ConversationEvent.where(account_id: Umi::Funnel::Configuration.account_ids, event_type: 'message_received', provenance: 'live',
                                 redacted_at: nil)
                          .where(occurred_at: Umi::Funnel::Configuration.started_at..Time.current)
                          .where(conversation_id: Conversation.where(inbox_id: inbox_ids).select(:id))
                          .where("(payload ->> 'message_id')::bigint IN (?)", messages.select(:id))
  end

  def self.auto_started_at
    value = ENV.fetch('UMI_FUNNEL_CLASSIFIER_AUTO_STARTED_AT')
    raise ArgumentError, 'Classifier activation must use UTC Z' unless value.end_with?('Z')

    Time.iso8601(value)
  end

  def self.enqueue
    return if mode == 'off'

    eligible = mode == 'auto' ? sources.where('occurred_at >= ?', auto_started_at) : sources
    latest = eligible.group(:conversation_id).maximum(Arel.sql("(payload ->> 'message_id')::bigint"))
    processed = Umi::ConversationEvent.where(account_id: Umi::Funnel::Configuration.account_ids, redacted_at: nil,
                                             event_type: %w[classification_evaluated classification_changed])
                                      .group(:conversation_id).maximum(Arel.sql("(payload ->> 'input_message_id')::bigint"))
    candidates = latest.select { |id, watermark| watermark && watermark > processed.fetch(id, nil).to_i }
    candidates.sort_by(&:last).first(100).each { |entry| Umi::Funnel::ClassificationJob.perform_later(entry.first) }
  end

  def initialize(conversation)
    @conversation = conversation
  end

  def perform
    return if self.class.mode == 'off'
    return unless Umi::Funnel::Configuration.enabled?(@conversation.account_id) && self.class.inbox_ids.include?(@conversation.inbox_id)

    @mode = self.class.mode
    @configuration = Umi::Funnel::ClassificationClient.configuration
    @model = @configuration.fetch('model')
    @contact_id = @conversation.contact_id
    return if @conversation.contact.additional_attributes['umi_profile_redacted']

    @watermark = latest_message_id
    return unless @watermark && @watermark > processed_message_id

    message = incoming_messages.find_by(id: @watermark)
    return unless message && message.created_at <= 30.seconds.ago

    @auto_boundary = self.class.auto_started_at if @mode == 'auto'
    return if @auto_boundary && message.created_at < @auto_boundary

    @correction = latest_correction
    @as_of = Time.current
    @cutoff = Umi::Funnel::ClassificationContext.public_messages(@conversation).maximum(:id)
    @context = Umi::Funnel::ClassificationContext.new(@conversation, watermark: @watermark, cutoff: @cutoff,
                                                                     boundary: @auto_boundary || Umi::Funnel::Configuration.started_at, as_of: @as_of)
    @input = @context.build
    @comparison = @context.comparison(@input).deep_dup
    @input_bytes = Umi::Funnel::ClassificationClient.request_bytes(@input)
    @reason_code = Umi::Funnel::ClassificationClient.uncertainty(@input, @configuration)
    decision = if @reason_code
                 { 'status' => 'uncertain', 'topics' => [], 'roles' => [], 'reason' => @reason_code.humanize, 'evidence_message_ids' => [] }
               else
                 Umi::Funnel::ClassificationClient.new.classify(@input)
               end
    Umi::Funnel::ClassificationClient.validate!(decision, @input)
    @reason_code ||= 'model_uncertain' if decision['status'] == 'uncertain'
    finish(decision)
  rescue StandardError => e
    raise unless @input

    finish(nil, error: e.class.name)
  end

  private

  def latest_message_id
    self.class.sources.where(conversation_id: @conversation.id).maximum(Arel.sql("(payload ->> 'message_id')::bigint"))
  end

  def processed_message_id
    Umi::ConversationEvent.where(conversation_id: @conversation.id, redacted_at: nil,
                                 event_type: %w[classification_evaluated classification_changed])
                          .maximum(Arel.sql("(payload ->> 'input_message_id')::bigint")).to_i
  end

  def latest_correction
    Umi::ConversationEvent.where(conversation_id: @conversation.id, event_type: 'classification_changed', provenance: 'operator', redacted_at: nil)
                          .order(id: :desc).first
  end

  def incoming_messages
    self.class.public_messages.where(conversation_id: @conversation.id).incoming
  end

  def finish(decision, error: nil)
    contact = Contact.find_by(id: @contact_id, account_id: @conversation.account_id)
    return unless contact

    contact.with_lock do # rubocop:disable Metrics/BlockLength
      next if contact.additional_attributes['umi_profile_redacted'] || self.class.mode == 'off'

      @conversation.reload.with_lock do
        next if @conversation.contact_id != @contact_id
        next if Umi::ConversationEvent.where(conversation_id: @conversation.id, event_type: 'classification_evaluated', redacted_at: nil)
                                      .exists?(["(payload ->> 'input_message_id')::bigint >= ?", @watermark])
        next unless Umi::Funnel::Configuration.enabled?(@conversation.account_id) && self.class.inbox_ids.include?(@conversation.inbox_id)

        # Native deletion updates the message row independently of the conversation.
        # Keep the captured history stable through the final comparison and application.
        @conversation.messages.where(id: @input.fetch(:messages).pluck(:id)).reorder(:id).lock.load
        current_input = @context.build
        stale = @mode != self.class.mode || incoming_messages.maximum(:id) != @watermark ||
                @configuration != Umi::Funnel::ClassificationClient.configuration || @comparison != @context.comparison(current_input)
        stale ||= @auto_boundary && @auto_boundary != self.class.auto_started_at
        manual = latest_correction&.id != @correction&.id || current_input[:topic_corrections] != @input[:topic_corrections]
        outcome = if manual
                    'manual_override'
                  elsif stale
                    'stale'
                  elsif error
                    'failed'
                  elsif @mode == 'auto' && @conversation.resolved?
                    'resolved'
                  elsif @mode == 'auto' && !accepted_configuration?
                    'configuration_unaccepted'
                  elsif decision['status'] == 'uncertain'
                    'uncertain'
                  else
                    @mode == 'auto' ? 'applied' : 'shadow'
                  end
        apply!(decision, contact) if outcome == 'applied'
        uncertainty_note!(decision, contact) if outcome == 'uncertain' && @mode == 'auto'

        record_evaluation(outcome, error ? nil : decision, error)
      end
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def record_evaluation(outcome, decision, error)
    ids = decision.to_h.fetch('evidence_message_ids', []) & @conversation.messages.pluck(:id)
    Umi::ConversationEvent.record!(account_id: @conversation.account_id, contact_id: @contact_id, conversation_id: @conversation.id,
                                   event_type: 'classification_evaluated', provenance: 'classifier', occurred_at: Time.current,
                                   observed_at: Time.current, occurrence_key: "classifier:#{@conversation.id}:#{@watermark}:#{POLICY_VERSION}",
                                   evidence_message_ids: ids,
                                   payload: { input_message_id: @watermark, public_history_cutoff: @cutoff, policy_version: POLICY_VERSION,
                                              model: @model, mode: @mode,
                                              configuration: @configuration,
                                              configuration_digest: Umi::Funnel::ClassificationClient.configuration_digest(@configuration),
                                              input_bytes: @input_bytes, reason_code: @reason_code,
                                              outcome: outcome, decision: decision || {}, error: error })
  end

  def accepted_configuration?
    ENV['UMI_FUNNEL_CLASSIFIER_ACCEPTED_CONFIGURATION'] == Umi::Funnel::ClassificationClient.configuration_digest(@configuration)
  end

  def uncertainty_note!(decision, contact)
    previous = Umi::ConversationEvent.where(conversation_id: @conversation.id, event_type: 'classification_evaluated', redacted_at: nil)
                                     .where("payload ->> 'mode' = 'auto'").order(id: :desc).first
    return if previous && previous.payload.values_at('outcome', 'reason_code') == ['uncertain', @reason_code]

    Umi::Funnel::CustomerProjection.create_note!(@conversation, contact, "Classification uncertain: #{decision.fetch('reason')}",
                                                 kind: 'classification_uncertain', reason_code: @reason_code,
                                                 input_message_id: @watermark,
                                                 configuration: Umi::Funnel::ClassificationClient.configuration_digest(@configuration))
  end

  def apply!(decision, contact)
    previous_status = @conversation.custom_attributes['umi_sales_status'] || 'unevaluated'
    previous_topics = @conversation.label_list & Umi::Funnel::ClassificationClient::TOPICS
    previous_roles = contact.custom_attributes.slice(*Umi::Funnel::Configuration::ROLES.keys)
    prior_qualification = Umi::ConversationEvent.exists?(conversation_id: @conversation.id, event_type: 'conversation_qualified', redacted_at: nil)
    preserved_qualification = prior_qualification && %w[not_sales unevaluated].exclude?(latest_correction&.payload&.[]('status'))
    unless preserved_qualification || %w[order_placed purchased].include?(@conversation.custom_attributes['umi_sales_status'])
      Umi::Funnel::ConversationTransition.new(conversation: @conversation, status: decision.fetch('status'), actor: nil,
                                              reason: decision.fetch('reason'), evidence_message_ids: decision.fetch('evidence_message_ids'),
                                              classifier: { 'model' => @model, 'policy_version' => POLICY_VERSION,
                                                            'input_message_id' => @watermark }).perform
    end
    topics = decision.fetch('topics').select { |topic| Umi::Funnel::TopicCorrection.permitted?(topic, @input) }.pluck('label')
    topics.each { |title| @conversation.account.labels.find_or_create_by!(title: title) }
    @conversation.update!(label_list: (@conversation.label_list + topics).uniq)
    roles = decision.fetch('roles').to_h { |role| [role.fetch('role'), 'yes'] }
    Umi::Funnel::CustomerMutation.new(contact, source: 'ai', conversation: @conversation).perform(roles: roles, defer_projection: true) if roles.any?
    current_status = @conversation.custom_attributes['umi_sales_status'] || 'unevaluated'
    changes = []
    changes << "Sales status: #{previous_status} → #{current_status}." if previous_status != current_status
    added = topics - previous_topics
    changes << "Topics added: #{added.join(', ')}." if added.any?
    contact.custom_attributes.slice(*Umi::Funnel::Configuration::ROLES.keys).each do |key, value|
      if previous_roles[key] != value
        previous = previous_roles.fetch(key, 'unknown')
        changes << "#{Umi::Funnel::Configuration::ROLES.fetch(key)}: #{previous} → #{value}."
      end
    end
    return if changes.empty?

    changes << "Reason: #{decision.fetch('reason')}"
    Umi::Funnel::CustomerProjection.apply!(@conversation, contact, classification: {
                                             text: changes.join("\n"), kind: 'classification_applied', input_message_id: @watermark,
                                             configuration: Umi::Funnel::ClassificationClient.configuration_digest(@configuration)
                                           })
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
