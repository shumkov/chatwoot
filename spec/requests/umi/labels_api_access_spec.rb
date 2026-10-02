require 'rails_helper'

RSpec.describe 'Labels API access tokens', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, :administrator, account: account) }
  let!(:label) { create(:label, account: account) }

  it 'returns account labels instead of a server error for an administrator API token' do
    other_label = create(:label)

    get "/api/v1/accounts/#{account.id}/labels", headers: { api_access_token: admin.access_token.token }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].pluck('id')).to eq([label.id])
    expect(response.body).not_to include(other_label.title)
  end

  it 'still rejects API tokens when account API access is disabled' do
    allow(Account).to receive(:find).and_call_original
    allow(Account).to receive(:find).with(account.id.to_s).and_return(account)
    allow(account).to receive(:api_and_webhooks_enabled?).and_return(false)

    get "/api/v1/accounts/#{account.id}/labels", headers: { api_access_token: admin.access_token.token }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to eq('API access is not enabled for this account')
  end

  it 'still rejects a token whose user does not belong to the requested account' do
    other_account = create(:account)

    get "/api/v1/accounts/#{other_account.id}/labels", headers: { api_access_token: admin.access_token.token }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'still rejects invalid API tokens before loading the requested account' do
    expect(Account).not_to receive(:find)

    get "/api/v1/accounts/#{account.id}/labels", headers: { api_access_token: 'invalid' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
