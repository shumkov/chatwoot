# frozen_string_literal: true

Rails.application.config.to_prepare do
  [Facebook::SendOnFacebookService, Instagram::Messenger::SendOnInstagramService, Whatsapp::SendOnWhatsappService].each do |klass|
    raise 'Product card sender hook changed' unless klass.private_method_defined?(:perform_reply)

    klass.prepend(Umi::Shopify::ProductDelivery) unless klass < Umi::Shopify::ProductDelivery
  end
  cloud_sender = Whatsapp::SendOnWhatsappService
  cloud_sender.prepend(Umi::Shopify::CloudProductDelivery) unless cloud_sender < Umi::Shopify::CloudProductDelivery
  cloud_provider = Whatsapp::Providers::WhatsappCloudService
  cloud_provider.prepend(Umi::Shopify::CloudProductProvider) unless cloud_provider < Umi::Shopify::CloudProductProvider
  cloud_incoming = Whatsapp::IncomingMessageWhatsappCloudService
  cloud_incoming.prepend(Umi::Shopify::CloudProductIncoming) unless cloud_incoming < Umi::Shopify::CloudProductIncoming
  controller = Api::V1::Accounts::Conversations::MessagesController
  raise 'Product card retry hook changed' unless controller.method_defined?(:retry)

  controller.prepend(Umi::Shopify::ProductRetry) unless controller < Umi::Shopify::ProductRetry
end

Rails.application.routes.append do
  scope '/api/v1/accounts/:account_id/umi/shopify/conversations/:conversation_id', controller: 'umi/shopify/product_shares' do
    post '/product_shares', action: :create
    get '/product_shares', action: :show
  end
end
