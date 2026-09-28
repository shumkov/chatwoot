# frozen_string_literal: true

Rails.application.config.to_prepare do
  scopes = Shopify::IntegrationHelper::REQUIRED_SCOPES
  Shopify::IntegrationHelper.send(:remove_const, :REQUIRED_SCOPES)
  Shopify::IntegrationHelper.const_set(:REQUIRED_SCOPES, (scopes + ['read_draft_orders']).uniq.freeze)
end

Rails.application.routes.append do
  scope '/api/v1/accounts/:account_id/umi/shopify/conversations/:conversation_id', controller: 'umi/shopify/commerce' do
    get '/', action: :show
    get '/customers', action: :customers
    put '/customer', action: :customer
    post '/preview', action: :preview
    post '/links', action: :create
    delete '/links/:kind/:id', action: :destroy
    post '/refresh', action: :refresh
  end
end
