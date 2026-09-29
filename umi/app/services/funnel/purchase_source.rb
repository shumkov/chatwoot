# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
class Umi::Funnel::PurchaseSource
  attr_reader :state, :link, :contact, :command, :evidence, :event

  def self.channels
    values = ENV.fetch('UMI_FUNNEL_META_PURCHASE_CHANNELS', '').split(',').map(&:strip).reject(&:empty?)
    raise ArgumentError, 'Invalid Meta Purchase channels' if (values - %w[messenger instagram]).any?

    values
  end

  def initialize(state)
    @state = state
  end

  def refresh
    Umi::Shopify::OrderFinancialStateService.request(account_id: state.account_id, shop_domain: state.shop_domain, order_id: state.shopify_order_id)
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    true
  rescue StandardError
    false
  end

  # Financial reconciliation and manual linking take the same advisory/contact prefix.
  # Native message deletion is fenced by the message row locks before a delivery claim.
  def with_lock(command: nil)
    state.class.transaction do
      state.class.connection.execute("SELECT pg_advisory_xact_lock(74219, #{state.id.to_i})")
      state.reload
      @link = Umi::ShopifyOrderAttribution.find_by(account_id: state.account_id, shop_domain: state.shop_domain,
                                                   shopify_order_id: state.shopify_order_id)
      @contact = Contact.find_by(id: link&.contact_id || state.paid_event&.contact_id, account_id: state.account_id)
      operation = lambda do
        state.lock!
        @event = state.paid_event&.reload
        link&.lock!
        load_messages(command)
        yield self
      end
      contact ? contact.with_lock(&operation) : operation.call
    end
  end

  def binding
    { 'attribution_id' => link.id, 'account_id' => link.account_id, 'shop_domain' => link.shop_domain,
      'order_id' => link.shopify_order_id, 'contact_id' => link.contact_id, 'conversation_id' => link.conversation_id }
  end

  def binding_valid?(data)
    link && link.redacted_at.nil? && link.attribution_state == 'verified' && contact && !contact.additional_attributes['umi_profile_redacted'] &&
      Conversation.exists?(id: link.conversation_id, account_id: link.account_id, contact_id: contact.id) &&
      binding.all? { |key, value| value.present? && data[key] == value }
  end

  def financial_reason
    return 'redacted' if state.redacted_at || event&.redacted_at
    return 'financial_identity_conflict' unless link && binding_valid?(binding) && state.snapshot['identity_hold'].blank?
    return 'payment_not_verified' unless event && event.event_type == 'order_paid' && event.provenance == 'shopify' &&
                                         event.account_id == link.account_id && event.contact_id == link.contact_id &&
                                         event.conversation_id == link.conversation_id && event.payload['shop_domain'] == link.shop_domain &&
                                         event.payload['order_id'].to_s == link.shopify_order_id
    return 'financial_observation_stale' if state.last_error.present? || !state.reconciled_at ||
                                            state.reconciliation_requested_at > state.reconciled_at || observed_at.nil? || observed_at < 5.minutes.ago
    return 'payment_not_verified' unless %w[paid partially_refunded refunded].include?(state.snapshot['classification'])

    source = state.snapshot['order_source'].to_h
    return 'purchase_source_unknown' unless source.key?('checkout_id') && source.key?('source_name') && source['source_name'].present?
    return 'website_checkout' if !source['checkout_id'].nil? || %w[web checkout online_store].include?(source['source_name'])

    nil
  end

  def active?
    data = command&.content_attributes&.[](Umi::Funnel::SettlementCommand::KEY)
    data.is_a?(Hash) && data['status'] == 'accepted' && data['verb'] == 'confirm' &&
      Umi::Funnel::SettlementCommand.registered?(command, data) && binding_valid?(data)
  end

  def reason
    financial_reason || (!active? && 'chat_settlement_unconfirmed') || (!valid_evidence?(evidence) && 'purchase_evidence_missing') ||
      (self.class.channels.exclude?(evidence.payload['messaging_channel']) && 'purchase_channel_disabled')
  end

  def valid_evidence?(candidate)
    return false unless candidate && event && candidate.account_id == event.account_id && candidate.contact_id == event.contact_id &&
                        candidate.conversation_id == event.conversation_id && candidate.event_type == 'message_received' &&
                        candidate.provenance == 'live' && !candidate.redacted_at && candidate.occurred_at &&
                        candidate.occurred_at >= Umi::Funnel::Configuration.started_at && candidate.occurred_at <= event.occurred_at

    message = Message.find_by(id: candidate.payload['message_id'])
    message && candidate.evidence_message_ids.include?(message.id) && message.account_id == candidate.account_id &&
      message.conversation_id == candidate.conversation_id && message.inbox_id == candidate.payload['inbox_id'] &&
      message.sender_type == 'Contact' && message.sender_id == candidate.contact_id && message.incoming? && !message.private? &&
      !message.content_attributes['deleted'] && !message.content_attributes['umi_recovered'] &&
      message.source_id.present? && message.created_at >= Umi::Funnel::Configuration.started_at && message.created_at <= event.occurred_at &&
      Umi::Funnel::EventRecorder.identity(message).slice('inbox_id', 'channel_type', 'messaging_channel', 'page_id', 'instagram_id',
                                                         'scoped_user_id') ==
        candidate.payload.slice('inbox_id', 'channel_type', 'messaging_channel', 'page_id', 'instagram_id', 'scoped_user_id') &&
      %w[messenger instagram].include?(candidate.payload['messaging_channel'])
  end

  private

  def observed_at
    Time.iso8601(state.snapshot['observed_at'])
  rescue ArgumentError, TypeError
    nil
  end

  def load_messages(request)
    @command = request || Message.find_by(id: link&.settlement_command_message_id)
    data = @command&.content_attributes&.[](Umi::Funnel::SettlementCommand::KEY).to_h
    @evidence = Umi::ConversationEvent.find_by(id: data['evidence_event_id'])
    if request && data['verb'] == 'confirm' && event
      previous = Message.find_by(id: link&.settlement_command_message_id)&.content_attributes&.[](Umi::Funnel::SettlementCommand::KEY).to_h
      if previous['status'] == 'accepted' && previous['verb'] == 'confirm'
        @evidence = Umi::ConversationEvent.find_by(id: previous['evidence_event_id'])
      end
      @evidence ||= Umi::ConversationEvent.where(account_id: event.account_id, contact_id: event.contact_id, conversation_id: event.conversation_id,
                                                 event_type: 'message_received', provenance: 'live', redacted_at: nil)
                                          .where(occurred_at: Umi::Funnel::Configuration.started_at..event.occurred_at)
                                          .order(occurred_at: :desc, id: :desc).detect { |candidate| valid_evidence?(candidate) }
    end
    ids = [@command&.id, @evidence&.payload&.[]('message_id')].compact
    Message.where(id: ids).reorder(:id).lock.to_a
    @command = Message.find_by(id: @command&.id)
    @evidence&.reload
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
