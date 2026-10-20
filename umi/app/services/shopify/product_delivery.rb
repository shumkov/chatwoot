# frozen_string_literal: true

module Umi::Shopify::ProductDelivery
  private

  def perform_reply
    return super unless message.content_attributes.key?('umi_product_card')

    deliver_product_card
  end

  def deliver_product_card
    deliver = false
    message.with_lock do
      state = message.content_attributes.dig('umi_product_delivery', 'state')
      next if state.present?

      reason = product_hold_reason
      if reason
        product_state('held', reason)
      else
        product_state('dispatching')
        deliver = true
      end
    end
    return unless deliver

    record_product_response(product_provider_call)
  rescue Facebook::Messenger::FacebookError => e
    product_state('rejected', e.message)
  rescue StandardError => e
    product_state('ambiguous', "#{e.class}: provider outcome unknown; reconcile before retry.")
  end

  def record_product_response(response)
    if response['message_id'].present? && response['error'].blank?
      message.update!(source_id: response['message_id'])
      product_state('accepted')
    elsif response['error'].present?
      product_state('rejected', response['error']['message'].to_s)
    else
      product_state('ambiguous', 'Provider returned no message ID; reconcile before retry.')
    end
  end

  def product_hold_reason
    return 'Product share service principal mismatch.' unless product_service_principal?

    policy_hold = product_policy_hold
    return policy_hold if policy_hold

    card = message.content_attributes.fetch('umi_product_card')
    return 'Product attribution is unavailable.' unless product_attribution_valid?(card)

    source = conversation.messages.find(card.fetch('source_id'))
    requester = Umi::Shopify::ProductSource.verify!(source, card)
    return 'Staff requester changed.' unless requester == card['requested_by']

    nil
  rescue ActiveRecord::RecordNotFound, ArgumentError => e
    e.message
  end

  def product_policy_hold
    flag = conversation.additional_attributes['type'] == 'instagram_direct_message' ? 'INSTAGRAM' : 'FACEBOOK'
    return 'Product cards are not activated for this channel.' unless ENV["UMI_PRODUCT_CARDS_#{flag}_ENABLED"] == 'true'

    last_incoming = conversation.messages.incoming.order(:created_at).last
    return 'The standard 24-hour messaging window is closed.' unless last_incoming && last_incoming.created_at > 24.hours.ago

    nil
  end

  def product_service_principal?
    message.sender.is_a?(User) && message.sender_id.to_s == ENV['UMI_COMMERCE_BRIDGE_USER_ID'] &&
      conversation.account_id == ENV.fetch('UMI_COMMERCE_ACCOUNT_ID', '1').to_i &&
      conversation.inbox_id == ENV.fetch('UMI_COMMERCE_META_INBOX_ID', '2').to_i
  end

  def product_attribution_valid?(card)
    query = URI.decode_www_form(URI.parse(card.fetch('url')).query.to_s)
    tokens = query.find_all { |pair| pair.first == 'umi_cw' }
    return false unless tokens.one?

    claim = Umi::Shopify::OrderLinkTokenService.peek(tokens.sole.last)
    claim && claim.values_at('account_id', 'conversation_id', 'contact_id') ==
      [conversation.account_id, conversation.id, conversation.contact_id]
  rescue Umi::Shopify::OrderLinkTokenService::Error
    false
  end

  def product_payload
    card = message.content_attributes.fetch('umi_product_card')
    element = { title: card.fetch('title'), buttons: [{ type: 'web_url', url: card.fetch('url'), title: 'View product' }] }
    element[:image_url] = card['image_url'] if card['image_url'].present?
    subtitle = [card['variant_title']]
    price = card['price']
    subtitle << "#{price.fetch('amount')} #{price.fetch('currency')} (#{price.fetch('market')})" if price
    element[:subtitle] = subtitle.compact.join(' · ') if subtitle.compact.any?
    { recipient: { id: contact.get_source_id(inbox.id) }, messaging_type: 'RESPONSE',
      message: { attachment: { type: 'template', payload: { template_type: 'generic', elements: [element] } } } }
  end

  def product_provider_call
    payload = product_payload
    return JSON.parse(Facebook::Messenger::Bot.deliver(payload, page_id: channel.page_id)) unless
      conversation.additional_attributes['type'] == 'instagram_direct_message'

    access_token = channel.page_access_token
    query = { access_token: access_token }
    proof = calculate_app_secret_proof(GlobalConfigService.load('FB_APP_SECRET', ''), access_token)
    query[:appsecret_proof] = proof if proof
    HTTParty.post(
      'https://graph.facebook.com/v21.0/me/messages',
      body: payload.to_json,
      headers: { 'Content-Type' => 'application/json' }, query: query, timeout: 30
    ).parsed_response
  end

  def product_state(state, error = nil)
    message.update!(content_attributes: message.content_attributes.merge('umi_product_delivery' => { 'state' => state }))
    Messages::StatusUpdateService.new(message, 'failed', error).perform if error
  end
end
