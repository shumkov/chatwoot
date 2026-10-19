# frozen_string_literal: true

Rails.application.routes.append do
  scope '/api/v1/accounts/:account_id/umi/shopify/conversations/:conversation_id', controller: 'umi/shopify/draft_commands' do
    get '/draft_commands', action: :show
    post '/draft_commands', action: :create
  end
end
