# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity

module Umi::Webhooks::ShopifyFunnel
  FINANCIAL_TOPICS = %w[orders/create orders/paid orders/updated orders/cancelled refunds/create].freeze

  def events
    topic = request.headers['X-Shopify-Topic']
    shop = request.headers['X-Shopify-Shop-Domain'].to_s.downcase
    result = super if topic == 'orders/create'
    if FINANCIAL_TOPICS.include?(topic)
      hook = Integrations::Hook.find_by(app_id: 'shopify', reference_id: shop, status: :enabled)
      order_id = topic == 'refunds/create' ? params[:order_id] : params[:id]
      Umi::Shopify::OrderFinancialStateService.request(account_id: hook.account_id, shop_domain: shop, order_id: order_id) if hook
    end
    result = super unless topic == 'orders/create'
    Umi::Funnel::Privacy.redact_shop!(shop.presence || params[:shop_domain].to_s.downcase) if topic == 'shop/redact'
    result
  end
end

# rubocop:enable Metrics/CyclomaticComplexity
