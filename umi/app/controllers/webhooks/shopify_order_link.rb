# frozen_string_literal: true

module Umi::Webhooks::ShopifyOrderLink
  def events
    topic = request.headers['X-Shopify-Topic']
    return handle_order_created if topic == 'orders/create'
    return purge_shop_attributions_after(super) if topic == 'shop/redact'

    super
  end

  private

  # rubocop:disable Metrics/AbcSize
  def handle_order_created
    outcome = Umi::Shopify::OrderAttributionService.new(
      payload: params.to_unsafe_h,
      shop_domain: request.headers['X-Shopify-Shop-Domain'],
      webhook_id: request.headers['X-Shopify-Webhook-Id']
    ).perform
    Rails.logger.info("[umi-shopify-order-link] outcome=#{outcome} shop=#{request.headers['X-Shopify-Shop-Domain']} " \
                      "order=#{params[:id]} webhook=#{request.headers['X-Shopify-Webhook-Id']}")
    head :ok
  rescue Umi::Shopify::OrderAttributionService::Permanent => e
    Rails.logger.warn("[umi-shopify-order-link] acknowledged terminal delivery: #{e.message}")
    head :ok
  rescue Umi::Shopify::OrderAttributionService::InProgress
    head :conflict
  end
  # rubocop:enable Metrics/AbcSize

  def purge_shop_attributions_after(response)
    shop_domain = (request.headers['X-Shopify-Shop-Domain'].presence || params[:shop_domain]).to_s.downcase
    Umi::ShopifyOrderAttribution.where(shop_domain: shop_domain).delete_all if shop_domain.present?
    response
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    Rails.logger.error("[umi-shopify-order-link] shop redaction cleanup failed shop=#{shop_domain}: #{e.message}")
    response
  end
end
