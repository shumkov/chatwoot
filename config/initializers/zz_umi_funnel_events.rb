# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  Umi::Funnel::Configuration.account_ids
  raise 'UMI funnel: Shopify events action changed' unless Webhooks::ShopifyController.method_defined?(:events)
  raise 'UMI funnel: Conversation validation callbacks changed' unless Conversation.respond_to?(:before_validation)

  controller = Api::V1::Accounts::Conversations::MessagesController
  raise 'UMI settlement: native message creation changed' unless controller.instance_method(:create).arity.zero?

  controller.prepend(Umi::Funnel::SettlementMessages) unless controller.include?(Umi::Funnel::SettlementMessages)
  Message.include(Umi::Funnel::SettlementMessage) unless Message.include?(Umi::Funnel::SettlementMessage)
  Message.include(Umi::Funnel::MessageCapture) unless Message.include?(Umi::Funnel::MessageCapture)
  Conversation.include(Umi::Funnel::ConversationProjection) unless Conversation.include?(Umi::Funnel::ConversationProjection)
  # Shopify's existing prepend must execute inside this wrapper so both financial and attribution work run.
  Webhooks::ShopifyController.prepend(Umi::Webhooks::ShopifyOrderLink) unless Webhooks::ShopifyController.include?(Umi::Webhooks::ShopifyOrderLink)
  Webhooks::ShopifyController.prepend(Umi::Webhooks::ShopifyFunnel) unless Webhooks::ShopifyController.include?(Umi::Webhooks::ShopifyFunnel)
end

Rails.application.config.after_initialize do
  next unless Sidekiq.server?

  if Umi::Funnel::Configuration.account_ids.empty?
    Sidekiq::Cron::Job.destroy('umi_funnel_reconciliation')
  else
    job = Sidekiq::Cron::Job.new(name: 'umi_funnel_reconciliation', cron: '*/5 * * * *', class: 'Umi::Funnel::ReconcileJob', queue: 'low',
                                 source: 'umi')
    raise "UMI funnel cron registration failed: #{job.errors.join('; ')}" unless job.save
  end
end
