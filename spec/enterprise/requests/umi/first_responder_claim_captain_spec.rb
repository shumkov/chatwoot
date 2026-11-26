# frozen_string_literal: true

require 'rails_helper'

# A human who takes over a conversation Captain was handling reopens it with
# that reply, so the reply claims it like any open unassigned conversation.
RSpec.describe 'First responder claim on a Captain conversation', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:ivan) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }

  before do
    create(:inbox_member, inbox: inbox, user: ivan)
    create(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant, account: account))
    InstallationConfig.create!(name: 'UMI_FIRST_RESPONDER_CLAIM', value: { 'inbox_ids' => [inbox.id] })
  end

  it 'claims the conversation the human reply opened' do
    post new_user_session_url, params: { email: ivan.email, password: 'Password1!' }, as: :json
    headers = response.headers.slice('access-token', 'client', 'uid')

    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
         params: { content: 'I will take it from here.' }, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(conversation.reload).to have_attributes(status: 'open', assignee_id: ivan.id)
  end
end
