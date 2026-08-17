# frozen_string_literal: true

module Umi::Shopify::MessageOrderLinkable
  extend ActiveSupport::Concern

  STORE_URL = %r{https?://umi\.store[^\s<>()"]+}
  TRAILING_URL_PUNCTUATION = /[.,!?;:]+\z/

  included do
    after_validation :rewrite_shopify_order_links, on: :create, if: -> { errors.empty? }
  end

  private

  def rewrite_shopify_order_links
    return unless rewrite_eligible? && shopify_order_link_present?

    token = Umi::Shopify::OrderLinkTokenService.mint(
      account_id: account_id,
      conversation_id: conversation_id,
      contact_id: conversation.contact_id
    )

    applied = apply_shopify_order_link_rewrite(token)
    discard_shopify_order_link_claim(token) unless applied
  rescue StandardError => e
    discard_shopify_order_link_claim(token) if token
    Rails.logger.error("[umi-shopify-order-link] rewrite skipped: #{e.class}: #{e.message}")
  end

  def rewrite_eligible?
    return false if @umi_shopify_order_links_rewritten
    return false if ActiveModel::Type::Boolean.new.cast(ENV.fetch('UMI_SHOPIFY_ORDER_LINK_REWRITE_DISABLED', false))

    (outgoing? || template?) && !private? && conversation.contact_id.present?
  end

  def shopify_order_link_present?
    ([content].compact + email_content_values).any? { |value| value.match?(STORE_URL) }
  end

  def apply_shopify_order_link_rewrite(token)
    rewritten_content = content && rewrite_text(content, token)
    return if rewritten_content && rewritten_content.length > 150_000

    rewritten_attributes = rewrite_email_content(token)
    self.content = rewritten_content if content
    self.content_attributes = rewritten_attributes if rewritten_attributes
    @umi_shopify_order_links_rewritten = true
  end

  def discard_shopify_order_link_claim(token)
    Umi::Shopify::OrderLinkTokenService.discard(token)
  rescue StandardError => e
    Rails.logger.warn("[umi-shopify-order-link] claim cleanup skipped: #{e.class}: #{e.message}")
  end

  def email_content_values
    html_content = email_html_content
    return [] unless html_content

    %w[full reply].filter_map { |key| fetch_hash_value(html_content, key) }
  end

  def rewrite_email_content(token)
    attributes = content_attributes.deep_dup
    html_content = email_html_content(attributes)
    return unless html_content

    %w[full reply].each do |key|
      value = fetch_hash_value(html_content, key)
      next unless value

      html_content[html_content.key?(key) ? key : key.to_sym] = rewrite_text(value, token)
    end
    attributes
  end

  def email_html_content(attributes = content_attributes)
    email = fetch_hash_value(attributes || {}, 'email')
    fetch_hash_value(email || {}, 'html_content')
  end

  def fetch_hash_value(hash, key)
    hash[key] || hash[key.to_sym]
  end

  def rewrite_text(value, token)
    value.to_s.gsub(STORE_URL) { |matched_url| rewrite_shopify_url(matched_url, token) }
  end

  def rewrite_shopify_url(matched_url, token)
    trailing = matched_url[TRAILING_URL_PUNCTUATION]
    url = trailing ? matched_url.delete_suffix(trailing) : matched_url
    uri = URI.parse(url)
    return matched_url unless uri.host&.downcase == 'umi.store'

    query = URI.decode_www_form(uri.query.to_s).to_h.except('umi_cw').to_a
    uri.query = URI.encode_www_form(query + [['umi_cw', token]])
    "#{uri}#{trailing}"
  rescue URI::InvalidURIError, ArgumentError
    matched_url
  end
end
