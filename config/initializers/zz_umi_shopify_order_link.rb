# frozen_string_literal: true

# UMI patch: carries a signed, single-use conversation claim from an outbound
# Shopify URL through the storefront cart and into Shopify order webhooks.

Rails.application.reloader.to_prepare do
  Message.include(Umi::Shopify::MessageOrderLinkable) if defined?(Message) && !(Message < Umi::Shopify::MessageOrderLinkable)

  if defined?(Webhooks::ShopifyController) && Webhooks::ShopifyController.ancestors.exclude?(Umi::Webhooks::ShopifyOrderLink)
    Webhooks::ShopifyController.prepend(Umi::Webhooks::ShopifyOrderLink)
  end
end

Rails.application.config.filter_parameters += [/(?:\A|_)cw\z/i, 'note_attributes.value']

Rails.application.config.after_initialize do
  next unless Sidekiq.server?

  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('UMI_SHOPIFY_ORDER_LINK_CANARY_DISABLED', false))
    Sidekiq::Cron::Job.destroy('umi_shopify_order_link_canary')
  else
    job = Sidekiq::Cron::Job.new(
      name: 'umi_shopify_order_link_canary',
      cron: ENV.fetch('UMI_SHOPIFY_ORDER_LINK_CANARY_CRON', '30 2 * * *'),
      class: 'Umi::Shopify::OrderAttributionCanaryJob',
      queue: 'low',
      source: 'umi'
    )
    unless job.save
      message = "[umi-shopify-order-link] canary cron registration FAILED: #{job.errors.join('; ')}"
      ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
      Rails.logger.error(message)
    end
  end
end
