# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'UMI operator queue', type: :request do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:url) { "/api/v1/accounts/#{account.id}/umi/operator_queue" }
  let(:since) { '2026-09-01T00:00:00Z' }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: since,
                      UMI_FUNNEL_CLASSIFIER_INBOX_IDS: inbox.id.to_s do
      ApplicationRecord.transaction(isolation: :repeatable_read) do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end

  it 'requires authentication' do
    get url, params: { since: since }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'allows the account admin to read by display ID without mutating the conversation' do
    conversation.update!(display_id: 123_456)
    before_attributes = conversation.reload.attributes
    get "#{url}/#{conversation.reload.display_id}", params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('schema_version' => 1, 'account_id' => account.id)
    expect(response.parsed_body['conversation']).to include('id' => conversation.id, 'display_id' => 123_456,
                                                            'resolved_at' => nil, 'resolved_message_id' => nil)
    expect(conversation.reload.attributes).to eq(before_attributes)
  end

  it 'exposes the committed resolution boundary without reviving an old reply reminder' do
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    conversation.update!(status: :resolved)
    boundary = conversation.reload.additional_attributes.slice('umi_operator_resolved_at', 'umi_operator_resolved_message_id')
    conversation.update!(status: :open)

    get "#{url}/#{conversation.display_id}", params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['conversation']).to include(
      'waiting' => nil, 'resolved_at' => boundary['umi_operator_resolved_at'], 'resolved_message_id' => incoming.id
    )
    expect(conversation.reload.additional_attributes).to include(boundary)
  end

  it 'forbids agents even when they belong to the account' do
    agent = create(:user, account: account, role: :agent)
    get url, params: { since: since }, headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not disclose a different account through the list or detail' do
    other = create(:account)
    other_conversation = create(:conversation, account: other)
    get "#{url}/#{other_conversation.reload.display_id}", params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:not_found)
    get "/api/v1/accounts/#{other.id}/umi/operator_queue", params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
  end

  it 'excludes a conversation in an unconfigured inbox from detail' do
    excluded = create(:conversation, account: account)
    get "#{url}/#{excluded.reload.display_id}", params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:not_found)
  end

  it 'authenticates and authorizes both collaboration projection endpoints' do
    endpoint = "#{url}/#{conversation.reload.display_id}/collaboration_projection"
    get endpoint, params: { since: since }
    expect(response).to have_http_status(:unauthorized)
    agent = create(:user, account: account, role: :agent)
    post endpoint, params: { since: since, expected_revision: 'unknown', member: false }, as: :json, headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    get endpoint, params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['projection']).to include('id' => conversation.id, 'member' => false, 'excluded' => false)
  end

  it 'returns persisted membership and rejects stale or malformed membership writes' do
    endpoint = "#{url}/#{conversation.reload.display_id}/collaboration_projection"
    get "#{url}/#{conversation.display_id}", params: { since: since }, headers: user.create_new_auth_token
    revision = response.parsed_body['conversation']['revision']
    post endpoint, params: { since: since, expected_revision: revision, member: true }, as: :json, headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['projection']).to include('member' => true, 'status' => 'open')
    expect(response.parsed_body['revision']).to eq(revision)
    post endpoint, params: { since: since, expected_revision: 'stale', member: false }, as: :json, headers: user.create_new_auth_token
    expect(response).to have_http_status(:conflict)
    post endpoint, params: { since: since, expected_revision: revision, member: 'false' }, as: :json, headers: user.create_new_auth_token
    expect(response).to have_http_status(:bad_request)
    expect(conversation.reload.label_list).to eq(['collaboration-pending'])
  end

  it 'never reads or writes projection state through another account' do
    other = create(:account)
    foreign = create(:conversation, account: other)
    endpoint = "/api/v1/accounts/#{other.id}/umi/operator_queue/#{foreign.reload.display_id}/collaboration_projection"
    get endpoint, params: { since: since }, headers: user.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    post endpoint, params: { since: since, expected_revision: 'unknown', member: false }, as: :json, headers: user.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires a valid activation boundary and valid cursors' do
    [{}, { since: 'invalid' }, { since: since, after_id: '-1' }, { since: since, through_id: '1x' }].each do |parameters|
      get url, params: parameters, headers: user.create_new_auth_token
      expect(response).to have_http_status(:bad_request)
    end
  end
end
