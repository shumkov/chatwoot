# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Funnel::HistoricalClassification
  def self.applied_event(conversation)
    Umi::ConversationEvent.where(account_id: conversation.account_id, conversation_id: conversation.id,
                                 contact_id: conversation.contact_id, event_type: 'classification_evaluated',
                                 provenance: 'historical', redacted_at: nil)
                          .where("payload ->> 'mode' = 'historical' AND payload ->> 'outcome' = 'applied'").order(id: :desc).first
  end

  def self.reviewed_event(conversation)
    Umi::ConversationEvent.where(account_id: conversation.account_id, conversation_id: conversation.id,
                                 contact_id: conversation.contact_id, event_type: 'classification_evaluated',
                                 provenance: 'historical', redacted_at: nil)
                          .where("payload ->> 'mode' = 'historical' AND payload ->> 'outcome' IN ('applied', 'uncertain')").order(id: :desc).first
  end

  def self.fresh_evidence?(message, event)
    return true unless event

    message.id > event.payload.fetch('public_history_cutoff') && message.created_at > Time.iso8601(event.payload.fetch('snapshot_at'))
  end

  def self.snapshot(conversation)
    contact = conversation.contact.reload
    messages = conversation.messages.where(message_type: %i[incoming outgoing]).reorder(:id).includes(:attachments).reject do |message|
      message.content_attributes['deleted'] || (message.private? && message.content_attributes[Umi::Funnel::CustomerProjection::NOTE_MARKER])
    end
    { 'account_id' => conversation.account_id, 'conversation_id' => conversation.id, 'contact_id' => contact.id,
      'inbox_id' => conversation.inbox_id, 'sales_status' => conversation.custom_attributes['umi_sales_status'],
      'topics' => (conversation.label_list & Umi::Funnel::ClassificationClient::TOPICS).sort,
      'identity' => contact.additional_attributes.slice('shopify_customer_id', 'umi_klaviyo_profile_id', 'umi_klaviyo_binding')
                           .merge(contact.attributes.slice('email', 'phone_number', 'identifier')),
      'customer' => contact.custom_attributes.slice(*(Umi::Funnel::Configuration::CONTACT_FIELDS - ['umi_payment_snapshot_at'])),
      'commerce' => commerce_snapshot(conversation),
      'messages' => messages.map do |message|
        { 'id' => message.id, 'created_at' => message.created_at.utc.iso8601(6), 'content' => message.content,
          'message_type' => message.message_type, 'private' => message.private?, 'sender_type' => message.sender_type,
          'sender_id' => message.sender_id, 'status' => message.status, 'campaign_id' => message.additional_attributes['campaign_id'],
          'content_attributes' => message.content_attributes,
          'attachments' => message.attachments.sort_by(&:id).map do |attachment|
            { 'id' => attachment.id, 'file_type' => attachment.file_type, 'updated_at' => attachment.updated_at.utc.iso8601(6) }
          end }
      end }
  end

  def self.commerce_snapshot(conversation)
    scope = { account_id: conversation.account_id, conversation_id: conversation.id, redacted_at: nil }
    links = Umi::ShopifyOrderAttribution.where(scope).order(:id).to_a
    states = Umi::ShopifyOrderFinancialState.where(account_id: conversation.account_id, shopify_order_id: links.map(&:shopify_order_id))
                                            .includes(:paid_event).index_by { |state| [state.shop_domain, state.shopify_order_id] }
    orders = links.map do |link|
      state = states[[link.shop_domain, link.shopify_order_id]]
      link.attributes.slice('id', 'shop_domain', 'shopify_order_id', 'shopify_order_name', 'contact_id', 'shopify_customer_id',
                            'attribution_state', 'source', 'match_method', 'order_total', 'currency').merge(
                              'payment' => state && { 'facts' => state.snapshot.slice(*Umi::Funnel::OperatorQueue::PAYMENT_FIELDS),
                                                      'error' => state.last_error, 'redacted_at' => state.redacted_at,
                                                      'paid_event' => state.paid_event&.attributes&.slice('id', 'account_id', 'contact_id',
                                                                                                          'conversation_id', 'redacted_at') }
                            )
    end
    drafts = Umi::ShopifyDraftLink.where(scope).order(:id).map do |draft|
      draft.attributes.slice('id', 'shop_domain', 'shopify_draft_id', 'shopify_order_id', 'name', 'status', 'contact_id',
                             'shopify_customer_id', 'last_error')
    end
    { 'orders' => orders, 'drafts' => drafts }.as_json
  end

  def initialize(conversation:, actor:, run_id:, as_of:, expected:, decision:) # rubocop:disable Metrics/ParameterLists
    @conversation = conversation
    @actor = actor
    @run_id = run_id
    @as_of = as_of.is_a?(String) ? Time.iso8601(as_of) : as_of
    @expected = expected.deep_stringify_keys
    @decision_input = decision
  end

  def preview
    validate!
    reason = hold_reason
    return { status: 'held', reason: reason } if reason

    uncertain = @decision['status'] == 'uncertain'
    { status: 'eligible', sales_status: uncertain ? @expected['sales_status'] : @decision['status'],
      topics_added: uncertain ? [] : @decision.fetch('topics').pluck('label') - @expected.fetch('topics') }
  end

  def perform
    validate!
    contact = Contact.find_by!(id: @expected.fetch('contact_id'), account_id: @expected.fetch('account_id'))
    contact.with_lock do
      @conversation.reload.with_lock do
        previous = Umi::ConversationEvent.find_by(account_id: @conversation.account_id, occurrence_key: occurrence_key)
        if previous
          raise ArgumentError, 'Run already contains a different decision or review' unless previous.payload['review'] == review_receipt
          raise ArgumentError, 'Historical receipt is redacted' if previous.redacted_at

          next previous
        end
        ids = @expected.fetch('messages').pluck('id')
        @conversation.messages.where(id: ids).reorder(:id).lock.load
        Attachment.where(message_id: ids).order(:id).lock.load
        reason = hold_reason
        raise ArgumentError, reason if reason

        apply!(contact)
      end
    end
  end

  private

  def validate!
    raise ArgumentError, 'Invalid historical run ID' unless @run_id.is_a?(String) && @run_id.match?(/\A[a-zA-Z0-9_-]{1,100}\z/)
    raise ArgumentError, 'Invalid historical snapshot time' unless @as_of.is_a?(Time) && @as_of <= Time.current
    raise ArgumentError, 'Actor must belong to account' unless @actor && @conversation.account.users.exists?(id: @actor.id)

    @decision = @decision_input.deep_stringify_keys
    unless @decision.keys.sort == %w[evidence_message_ids reason status topics] &&
           Umi::Funnel::ClassificationClient::STATUSES.include?(@decision['status']) &&
           @decision['reason'].is_a?(String) && @decision['reason'].strip.length.between?(1, 1000)
      raise ArgumentError, 'Invalid historical decision'
    end

    incoming = @expected.fetch('messages').select { |row| !row.fetch('private') && row.fetch('message_type') == 'incoming' }.pluck('id')
    validate_evidence!(@decision['evidence_message_ids'], incoming, allow_empty: @decision['status'] == 'uncertain')
    topics = @decision['topics']
    unless topics.is_a?(Array) && topics.all? do |topic|
      topic.is_a?(Hash) && topic.keys.sort == %w[evidence_message_ids label] && Umi::Funnel::ClassificationClient::TOPICS.include?(topic['label'])
    end && topics.pluck('label').uniq.size == topics.size
      raise ArgumentError, 'Invalid historical topic'
    end

    topics.each { |topic| validate_evidence!(topic['evidence_message_ids'], incoming) }
  end

  def validate_evidence!(ids, allowed, allow_empty: false)
    return if ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq == ids &&
              (ids - allowed).empty? && (allow_empty || ids.any?)

    raise ArgumentError, 'Invalid historical evidence'
  end

  def hold_reason
    @conversation.reload
    return 'account_or_inbox_disabled' unless Umi::Funnel::Configuration.enabled?(@conversation.account_id) &&
                                              Umi::Funnel::Configuration.customer_context_enabled?(@conversation.account_id) &&
                                              Umi::Funnel::ConversationClassifier.inbox_ids.include?(@conversation.inbox_id)
    return 'contact_redacted' if @conversation.contact.reload.additional_attributes['umi_profile_redacted']
    return 'review_inputs_changed' unless self.class.snapshot(@conversation) == @expected
    return 'review_inputs_changed' if @expected.fetch('messages').any? { |row| Time.iso8601(row.fetch('created_at')) > @as_of }
    return 'already_classified' unless [nil, 'unevaluated'].include?(@conversation.custom_attributes['umi_sales_status'])
    return 'manual_correction' if Umi::ConversationEvent.exists?(conversation_id: @conversation.id, provenance: 'operator', redacted_at: nil,
                                                                 event_type: %w[classification_changed classification_topics_corrected])

    nil
  end

  def occurrence_key
    "historical-classification:#{@conversation.id}:#{@run_id}"
  end

  def review_receipt
    { 'decision' => @decision, 'snapshot_at' => @as_of.utc.iso8601(6),
      'input_digest' => Digest::SHA256.hexdigest(JSON.generate(@expected)), 'actor_id' => @actor.id }
  end

  def apply!(contact)
    public_rows = @expected.fetch('messages').reject { |row| row.fetch('private') }
    evidence_rows = public_rows.select { |row| @decision.fetch('evidence_message_ids').include?(row.fetch('id')) }
    evidence_times = evidence_rows.map do |row|
      attributes = row.fetch('content_attributes')
      next Umi::Funnel::EventRecorder.source_time(attributes['external_created_at']) if attributes['umi_recovered'] == true

      Time.iso8601(row.fetch('created_at'))
    end
    outcome = @decision['status'] == 'uncertain' ? 'uncertain' : 'applied'
    event = Umi::ConversationEvent.record!(account_id: @conversation.account_id, contact_id: contact.id, conversation_id: @conversation.id,
                                           event_type: 'classification_evaluated', provenance: 'historical', occurrence_key: occurrence_key,
                                           occurred_at: evidence_times.all? ? evidence_times.max : nil,
                                           observed_at: Time.current, evidence_message_ids: @decision.fetch('evidence_message_ids'),
                                           payload: { mode: 'historical', outcome: outcome, decision: @decision, review: review_receipt,
                                                      public_history_cutoff: public_rows.pluck('id').max || 0, snapshot_at: @as_of.utc.iso8601(6) })
    changes = ["Historical classification (reviewed #{@as_of.utc.iso8601}):"]
    if outcome == 'applied'
      status = @decision.fetch('status')
      @conversation.project_umi_sales_status!(status)
      changes << "Sales status: #{@expected['sales_status'] || 'unevaluated'} → #{status}."
      topics = @decision.fetch('topics').pluck('label')
      topics.each { |title| @conversation.account.labels.find_or_create_by!(title: title) }
      @conversation.update!(label_list: (@conversation.label_list + topics).uniq)
      added = topics - @expected.fetch('topics')
      changes << "Topics added: #{added.join(', ')}." if added.any?
    else
      changes << 'Classification uncertain; sales status unchanged.'
    end
    changes << "Reason: #{@decision.fetch('reason')}"
    classification = { text: changes.join("\n"), kind: 'historical_classification', run_id: @run_id }
    Umi::Funnel::CustomerProjection.apply!(@conversation, contact, historical: true, classification: classification)
    event
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
