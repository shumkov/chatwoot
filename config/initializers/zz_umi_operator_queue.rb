# frozen_string_literal: true

Rails.application.routes.append do
  scope '/api/v1/accounts/:account_id/umi/operator_queue', controller: 'umi/funnel/operator_queue' do
    get '/', action: :index
    get '/:conversation_id', action: :show
  end
end

Rails.application.reloader.to_prepare do
  Conversation.include(Umi::Funnel::OperatorResolution) unless Conversation.include?(Umi::Funnel::OperatorResolution)
end
