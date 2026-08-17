# frozen_string_literal: true

class Umi::Shopify::OrderAttributionService
  class Permanent < StandardError; end
  class InProgress < StandardError; end

  DELIVERY_KEY_PREFIX = 'UMI_SHOPIFY_ORDER_LINK_DELIVERY::'
  DELIVERY_TTL = 10.minutes
  COMPLETED_DELIVERY_TTL = 7.days

  def initialize(payload:, shop_domain:, webhook_id:)
    @payload = payload.deep_stringify_keys
    @shop_domain = shop_domain.to_s.downcase
    @webhook_id = webhook_id.to_s.presence
  end

  def perform
    return with_delivery_guard { process } if @webhook_id.present?

    process
  rescue Umi::Shopify::OrderLinkTokenService::InvalidToken,
         Umi::Shopify::OrderLinkTokenService::Replay => e
    Redis::Alfred.set("#{DELIVERY_KEY_PREFIX}#{@webhook_id}", 'done', ex: COMPLETED_DELIVERY_TTL.to_i) if @webhook_id.present?
    permanent('token_invalid', e)
  end

  private

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def process
    consumed = false
    hook = Integrations::Hook.find_by(app_id: 'shopify', reference_id: @shop_domain, status: :enabled)
    return :unconfigured unless hook

    order_id = @payload['id'].to_s.presence
    permanent('order_id_missing') unless order_id
    return :duplicate if Umi::ShopifyOrderAttribution.exists?(account_id: hook.account_id, shopify_order_id: order_id)

    token = note_attribute('_cw')
    return :unlinked if token.blank?

    claim = Umi::Shopify::OrderLinkTokenService.peek(token)
    Umi::Shopify::OrderLinkTokenService.consume(claim)
    consumed = true
    permanent('token_account_mismatch') unless claim['account_id'].to_i == hook.account_id

    conversation = Conversation.find_by(id: claim['conversation_id'], account_id: hook.account_id)
    contact = Contact.find_by(id: claim['contact_id'], account_id: hook.account_id)
    permanent('token_target_missing') unless conversation && contact && conversation.contact_id == contact.id

    state, match_method = identity_match(contact)
    create_attribution!(hook, order_id, claim, conversation, contact, state, match_method)
  rescue ActiveRecord::RecordNotUnique
    :duplicate
  rescue Permanent
    raise
  rescue StandardError
    Umi::Shopify::OrderLinkTokenService.restore(claim) if claim && consumed
    raise
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
  def create_attribution!(hook, order_id, claim, conversation, contact, state, match_method)
    verified = state == 'verified'
    Umi::ShopifyOrderAttribution.create!(
      account_id: hook.account_id,
      shop_domain: @shop_domain,
      candidate_conversation_id: conversation.id,
      candidate_contact_id: contact.id,
      conversation_id: verified ? conversation.id : nil,
      contact_id: verified ? contact.id : nil,
      shopify_order_id: order_id,
      shopify_order_name: @payload['name'].presence,
      order_total: @payload['current_total_price'].presence || @payload['total_price'].presence,
      currency: (@payload['currency'] || @payload['presentment_currency']).to_s.presence,
      attribution_state: state,
      match_method: match_method,
      token_nonce: claim['nonce'],
      webhook_id: @webhook_id
    ).tap do |attribution|
      Rails.logger.info("[umi-shopify-order-link] #{state} order=#{attribution.shopify_order_id} account=#{hook.account_id}")
    end
    state.to_sym
  end
  # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def identity_match(contact)
    email = @payload['email'].presence || @payload.dig('customer', 'email').presence
    return %w[verified email] if email && normalize_email(email) == normalize_email(contact.email)
    return %w[unverified email_mismatch] if email

    phones = [
      @payload['phone'],
      @payload.dig('customer', 'phone'),
      @payload.dig('billing_address', 'phone'),
      @payload.dig('shipping_address', 'phone')
    ].filter_map { |phone| normalize_phone(phone) }.uniq
    return %w[unavailable phone_missing] if phones.empty?
    return %w[unavailable phone_ambiguous] if phones.length > 1
    return %w[verified phone] if phones.first == normalize_phone(contact.phone_number)

    %w[unverified phone_mismatch]
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def normalize_email(value)
    value.to_s.strip.downcase
  end

  def normalize_phone(value)
    phone = value.to_s.gsub(/[\s().-]/, '')
    phone if phone.match?(/\A\+\d{8,15}\z/)
  end

  def note_attribute(name)
    attributes = @payload['note_attributes']
    return nil unless attributes.is_a?(Array)

    values = attributes.filter_map do |attribute|
      next unless attribute.is_a?(Hash) && attribute['name'].to_s == name

      attribute['value'].to_s
    end
    return nil if values.empty?

    permanent('carrier_ambiguous') if values.length > 1

    values.first
  end

  def with_delivery_guard
    key = "#{DELIVERY_KEY_PREFIX}#{@webhook_id}"
    prior = Redis::Alfred.get(key)
    return :duplicate if prior == 'done'
    raise InProgress if prior == 'processing'

    claimed = Redis::Alfred.set(key, 'processing', nx: true, ex: DELIVERY_TTL.to_i)
    raise InProgress unless claimed

    result = yield
    Redis::Alfred.set(key, 'done', ex: COMPLETED_DELIVERY_TTL.to_i)
    result
  rescue Permanent
    Redis::Alfred.set(key, 'done', ex: COMPLETED_DELIVERY_TTL.to_i) if claimed
    raise
  rescue StandardError
    Redis::Alfred.delete(key) if claimed
    raise
  end

  def permanent(reason, error = nil)
    Rails.logger.warn("[umi-shopify-order-link] terminal=#{reason} shop=#{@shop_domain} webhook=#{@webhook_id}")
    raise Permanent, reason unless error

    raise Permanent, "#{reason}: #{error.class}"
  end
end
