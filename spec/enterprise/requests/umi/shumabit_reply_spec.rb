# frozen_string_literal: true

require 'rails_helper'

# The loader follows the native conversation access rule, including Enterprise custom roles: an inbox member whose
# role only covers conversations they take part in cannot read a draft for one they cannot open.
RSpec.describe 'Shumabit reply loader with Enterprise custom roles', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:bridge) { create(:user, account: account) }
  let(:cutoff) { 1_700_000_000 }

  around do |example|
    with_modified_env(UMI_SHUMABIT_BRIDGE_URL: 'http://bridge.test', UMI_COMMERCE_BRIDGE_USER_ID: bridge.id.to_s) { example.run }
  end

  before do
    InstallationConfig.create!(name: 'UMI_SHUMABIT_REPLY', value: { 'inbox_ids' => [inbox.id], 'eligible_after_ms' => cutoff * 1000 })
    create(:inbox_member, inbox: inbox, user: agent)
    role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    agent.account_users.find_by(account: account).update!(role: :agent, custom_role: role)
    question = create(:message, conversation: conversation, message_type: :incoming, sender: contact, created_at: Time.zone.at(cutoff + 10))
    marker = { 'source_message_id' => question.id, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => 'reply',
               'row_key' => "#{account.id}:#{question.id}", 'covered_message_ids' => [question.id], 'eligible_after' => cutoff,
               'seen_digest' => Digest::SHA256.hexdigest("assist-seen-v1:#{question.id}"), 'reply' => 'Yes, size M is in stock.',
               'staff' => nil }
    create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge, content: 'Shumabit draft',
                     created_at: Time.zone.at(cutoff + 100), content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker })
  end

  it 'refuses an inbox member whose custom role does not cover the conversation, and serves them once assigned' do
    post new_user_session_url, params: { email: agent.email, password: 'Password1!' }, as: :json
    headers = response.headers.slice('access-token', 'client', 'uid')
    path = "/api/v1/accounts/#{account.id}/captain/tasks/reply_suggestion"

    post path, params: { conversation_display_id: conversation.display_id }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)

    conversation.update!(assignee: agent)
    post path, params: { conversation_display_id: conversation.display_id }, headers: headers, as: :json
    expect(response.parsed_body).to eq('message' => 'Yes, size M is in stock.')
  end
end
