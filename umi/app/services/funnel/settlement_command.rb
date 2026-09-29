# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Funnel::SettlementCommand
  KEY = 'umi_paid_in_chat'
  RESPONSE_KEY = 'umi_paid_in_chat_response'
  SYNTAX = %r{\A/paid-in-chat (cancel )?#([1-9]\d*)\z}
  USAGE = 'Use /paid-in-chat #1234 or /paid-in-chat cancel #1234 in a private note for an already-linked order. ' \
          'The command takes effect only after its private result appears; a pending cancellation has not stopped submission.'

  def self.register(message, actor)
    return unless Umi::Funnel::Configuration.enabled?(message.account_id) && actor.is_a?(User) && message.sender == actor &&
                  actor.account_users.exists?(account_id: message.account_id) && message.private? && message.outgoing? && message.text? &&
                  !message.content_attributes['shumabit_bridge'] && !message.content_attributes['automation_rule_id'] &&
                  !message.additional_attributes['campaign_id'] && message.content.to_s.strip.start_with?('/paid-in-chat')

    return if message.conversation.contact.reload.additional_attributes['umi_profile_redacted']

    text = message.content.strip
    match = SYNTAX.match(text)
    data = { 'command' => text, 'status' => 'pending', 'actor_id' => actor.id }
    if match
      data['verb'] = match[1] ? 'cancel' : 'confirm'
      hook = Integrations::Hook.where(account_id: message.account_id, app_id: 'shopify', status: :enabled).sole
      links = Umi::ShopifyOrderAttribution.verified.where(account_id: message.account_id, shop_domain: hook.reference_id.downcase,
                                                          conversation_id: message.conversation_id, contact_id: message.conversation.contact_id,
                                                          shopify_order_name: "##{match[2]}").limit(2).to_a
      if links.one?
        link = links.first
        data.merge!('attribution_id' => link.id, 'account_id' => link.account_id, 'shop_domain' => link.shop_domain,
                    'order_id' => link.shopify_order_id, 'contact_id' => link.contact_id, 'conversation_id' => link.conversation_id)
      else
        data['error'] = links.empty? ? 'order_not_linked' : 'order_name_ambiguous'
      end
    else
      data['error'] = 'invalid_command'
    end
    message.update!(content_attributes: message.content_attributes.merge(KEY => data))
  end

  def self.registered?(message, data)
    message&.private? && message.outgoing? && message.text? && message.sender_type == 'User' &&
      message.sender_id == data['actor_id'] && message.content.to_s.strip == data['command'] &&
      !message.content_attributes['deleted'] && !message.content_attributes['shumabit_bridge'] &&
      message.account_id == data.fetch('account_id', message.account_id) &&
      message.conversation_id == data.fetch('conversation_id', message.conversation_id)
  end

  def self.enqueue_unfinished
    Message.where(account_id: Umi::Funnel::Configuration.account_ids).where("(content_attributes #>> '{}')::jsonb -> ? ->> 'status' = 'pending'", KEY)
           .reorder(:id).limit(50).each { |message| Umi::Funnel::SettlementCommandJob.perform_later(message.id) }
  end

  def initialize(message)
    @message = message
  end

  def perform
    data = @message.reload.content_attributes[KEY]
    return unless data.is_a?(Hash) && data['status'] == 'pending' && self.class.registered?(@message, data)
    return unless Umi::Funnel::Configuration.enabled?(@message.account_id)

    if data['error']
      @message.conversation.contact.with_lock do
        @message.with_lock { finish!('rejected', data['error']) if pending? }
      end
      return
    end
    state = Umi::ShopifyOrderFinancialState.create_or_find_by!(account_id: data.fetch('account_id'), shop_domain: data.fetch('shop_domain'),
                                                               shopify_order_id: data.fetch('order_id')) do |row|
      row.reconciliation_requested_at = Time.current
    end
    source = Umi::Funnel::PurchaseSource.new(state)
    refreshed = data['verb'] == 'cancel' || source.refresh
    source.with_lock(command: @message) do
      @message = source.command
      next unless pending?

      current = @message.content_attributes.fetch(KEY)
      next finish!('rejected', 'binding_changed') unless source.binding_valid?(current)
      next finish!('superseded', 'newer_command_applied') if source.link.settlement_command_message_id.to_i > @message.id
      next finish!('rejected', 'shopify_read_failed') unless refreshed
      next finish!('rejected', source.financial_reason) if current['verb'] == 'confirm' && source.financial_reason

      source.link.update!(settlement_command_message_id: @message.id)
      cancel = current['verb'] == 'cancel'
      delivery = source.event&.conversion_deliveries&.find_by(destination: 'meta')
      attempted = false
      delivery&.with_lock do
        attempted = delivery.attempt_count.positive? || delivery.attempted_at.present? || %w[sending accepted confirmed rejected
                                                                                             unknown].include?(delivery.state)
        delivery.update!(reason: 'chat_settlement_canceled') if cancel && !attempted && delivery.state == 'pending'
      end
      reason = if cancel
                 attempted ? 'already_attempted_cannot_recall' : 'chat_settlement_canceled'
               elsif !Umi::Funnel::DeliveryAutomation.enabled?('meta') || Umi::Funnel::PurchaseSource.channels.empty? ||
                     (source.evidence && Umi::Funnel::PurchaseSource.channels.exclude?(source.evidence.payload['messaging_channel']))
                 'purchase_channel_disabled'
               elsif !source.valid_evidence?(source.evidence)
                 'purchase_evidence_missing'
               else
                 'chat_settlement_recorded'
               end
      finish!('accepted', reason, evidence_event_id: cancel ? nil : source.evidence&.id)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def pending?
    data = @message&.reload&.content_attributes&.[](KEY)
    data.is_a?(Hash) && data['status'] == 'pending' && self.class.registered?(@message, data)
  end

  def finish!(status, reason, evidence_event_id: nil)
    data = @message.content_attributes.fetch(KEY)
    response = @message.conversation.messages.create!(account_id: @message.account_id, inbox_id: @message.inbox_id,
                                                      message_type: :outgoing, private: true, content_type: :text,
                                                      content: response_text(reason), content_attributes: { RESPONSE_KEY => true })
    @message.update!(content_attributes: @message.content_attributes.merge(KEY => data.merge('status' => status, 'reason' => reason,
                                                                                             'evidence_event_id' => evidence_event_id,
                                                                                             'response_message_id' => response.id)))
  end

  def response_text(reason)
    {
      'purchase_channel_disabled' => 'Chat settlement recorded. Meta Purchase is disabled; no event was sent by this command.',
      'purchase_evidence_missing' => 'Chat settlement recorded. Awaiting eligible pre-payment channel evidence; no event was sent by this command.',
      'chat_settlement_recorded' => 'Chat settlement recorded. Delivery eligibility will be checked separately; this is not a Meta send receipt.',
      'chat_settlement_canceled' => 'Chat settlement canceled before submission. Payment history is unchanged.',
      'already_attempted_cannot_recall' => 'Chat settlement canceled for future eligibility. ' \
                                           'A Meta attempt may already have been sent and cannot be recalled.',
      'newer_command_applied' => 'This command was superseded by a newer applied command.'
    }.fetch(reason) { "Chat settlement rejected: #{reason.tr('_', ' ')}. #{USAGE}" }
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
