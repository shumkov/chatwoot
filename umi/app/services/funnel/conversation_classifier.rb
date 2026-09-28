# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Funnel::ConversationClassifier
  POLICY_VERSION = '1'
  class InvalidDecision < StandardError; end

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
    @model = ENV.fetch('UMI_FUNNEL_CLASSIFIER_MODEL')
    @contact_id = @conversation.contact_id
    return if @conversation.contact.additional_attributes['umi_profile_redacted']

    @watermark = latest_message_id
    return unless @watermark && @watermark > processed_message_id

    message = incoming_messages.find_by(id: @watermark)
    return unless message && message.created_at <= 30.seconds.ago

    @auto_boundary = self.class.auto_started_at if @mode == 'auto'
    return if @auto_boundary && message.created_at < @auto_boundary

    @correction = latest_correction
    @input = build_input
    decision = Umi::Funnel::ClassificationClient.new.classify(@input)
    validate_decision!(decision)
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

  def build_input
    messages = self.class.public_messages.where(conversation_id: @conversation.id, message_type: %i[incoming outgoing], id: ..@watermark)
                   .reorder(created_at: :desc, id: :desc).limit(101).to_a
    truncated = messages.size > 100
    messages = messages.first(100).reverse
    live_ids = self.class.sources.where(conversation_id: @conversation.id).pluck(Arel.sql("(payload ->> 'message_id')::bigint"))
    fresh = messages.select do |message|
      watermark = @correction&.payload&.[]('input_message_id')
      after_correction = !@correction || (watermark ? message.id > watermark : message.created_at > @correction.observed_at)
      live_ids.include?(message.id) && after_correction && message.created_at >= (@auto_boundary || Umi::Funnel::Configuration.started_at)
    end.map(&:id)
    attached_ids = Attachment.where(message_id: messages.map(&:id)).distinct.pluck(:message_id).to_set
    remaining = 30_000
    rows = messages.reverse.map do |message|
      content = message.content.to_s
      truncated ||= content.length > remaining
      text = content.first(remaining)
      remaining -= text.length
      { id: message.id, role: message.incoming? ? 'customer' : 'staff', text: text, attachments: attached_ids.include?(message.id) }
    end.reverse
    { messages: rows, incoming_ids: messages.select { |message| live_ids.include?(message.id) }.map(&:id), fresh_evidence_ids: fresh,
      truncated: truncated, current_status: @conversation.custom_attributes['umi_sales_status'],
      human_correction: @correction&.payload&.slice('status', 'reason') }
  end

  def validate_decision!(decision)
    raise InvalidDecision unless decision.is_a?(Hash) && decision.keys.sort == %w[evidence_message_ids reason status topics]
    raise InvalidDecision unless Umi::Funnel::ClassificationClient::STATUSES.include?(decision['status'])
    raise InvalidDecision unless decision['reason'].is_a?(String) && decision['reason'].strip.length.between?(1, 1000)

    topics = decision['topics']
    raise InvalidDecision unless topics.is_a?(Array) && topics.uniq == topics && (topics - Umi::Funnel::ClassificationClient::TOPICS).empty?

    ids = decision['evidence_message_ids']
    raise InvalidDecision unless ids.is_a?(Array) && ids.all?(Integer) && ids.uniq == ids && (ids - @input[:incoming_ids]).empty?
    raise InvalidDecision if decision['status'] != 'uncertain' && ids.empty?
    raise InvalidDecision if decision['status'] == 'qualified' && (ids - @input[:fresh_evidence_ids]).any?
  end

  def finish(decision, error: nil)
    contact = Contact.find_by(id: @contact_id, account_id: @conversation.account_id)
    return unless contact

    contact.with_lock do
      next if contact.additional_attributes['umi_profile_redacted'] || self.class.mode == 'off'

      @conversation.reload.with_lock do
        next if @conversation.contact_id != @contact_id
        next if Umi::ConversationEvent.where(conversation_id: @conversation.id, event_type: 'classification_evaluated', redacted_at: nil)
                                      .exists?(["(payload ->> 'input_message_id')::bigint >= ?", @watermark])
        next unless Umi::Funnel::Configuration.enabled?(@conversation.account_id) && self.class.inbox_ids.include?(@conversation.inbox_id)

        stale = @mode != self.class.mode || incoming_messages.maximum(:id) != @watermark || @model != ENV.fetch('UMI_FUNNEL_CLASSIFIER_MODEL')
        stale ||= @auto_boundary && @auto_boundary != self.class.auto_started_at
        if decision && incoming_messages.where(id: decision.fetch('evidence_message_ids')).count != decision.fetch('evidence_message_ids').size
          error = InvalidDecision.name
        end
        outcome = if stale
                    'stale'
                  elsif latest_correction&.id != @correction&.id
                    'manual_override'
                  elsif error
                    'failed'
                  elsif decision['status'] == 'uncertain'
                    'uncertain'
                  else
                    @mode == 'auto' ? 'applied' : 'shadow'
                  end
        apply!(decision) if outcome == 'applied'
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
                                   payload: { input_message_id: @watermark, policy_version: POLICY_VERSION, model: @model, mode: @mode,
                                              outcome: outcome, decision: decision || {}, error: error })
  end

  def apply!(decision)
    prior_qualification = Umi::ConversationEvent.exists?(conversation_id: @conversation.id, event_type: 'conversation_qualified', redacted_at: nil)
    preserved_qualification = prior_qualification && %w[not_sales unevaluated].exclude?(latest_correction&.payload&.[]('status'))
    unless preserved_qualification || %w[qualified order_placed purchased].include?(@conversation.custom_attributes['umi_sales_status'])
      Umi::Funnel::ConversationTransition.new(conversation: @conversation, status: decision.fetch('status'), actor: nil,
                                              reason: decision.fetch('reason'), evidence_message_ids: decision.fetch('evidence_message_ids'),
                                              classifier: { 'model' => @model, 'policy_version' => POLICY_VERSION,
                                                            'input_message_id' => @watermark }).perform
    end
    decision.fetch('topics').each { |title| @conversation.account.labels.find_or_create_by!(title: title) }
    @conversation.update!(label_list: (@conversation.label_list + decision.fetch('topics')).uniq)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
