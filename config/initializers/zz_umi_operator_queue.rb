# frozen_string_literal: true

Rails.application.routes.append do
  scope '/api/v1/accounts/:account_id/umi/operator_queue', controller: 'umi/funnel/operator_queue' do
    get '/', action: :index
    get '/:conversation_id', action: :show
  end
end
