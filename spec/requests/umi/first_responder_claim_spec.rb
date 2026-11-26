# frozen_string_literal: true

require 'rails_helper'

# While the team shares one unassigned queue, the first person who answers a
# conversation from a signed-in dashboard or mobile session becomes its owner.
# An agent account can also own the automation's access tokens, so only a
# request from an interactive sign-in session may claim; sender identity alone
# is not enough.
RSpec.describe 'First authenticated human reply claims an unassigned conversation', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:ivan) { create(:user, account: account, role: :administrator, name: 'Ivan') }
  let(:dina) { create(:user, account: account, role: :agent, name: 'Dina') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:messages_path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages" }
  let!(:settings) { InstallationConfig.create!(name: 'UMI_FIRST_RESPONDER_CLAIM', value: { 'inbox_ids' => [inbox.id] }) }

  before do
    [ivan, dina].each { |user| create(:inbox_member, inbox: inbox, user: user) }
  end

  # A real interactive sign-in, as the dashboard and the mobile app perform it.
  def interactive_sign_in(params, headers: {})
    post new_user_session_url, params: params, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    response.headers.slice('access-token', 'client', 'uid')
  end

  def password_session(user, headers: {})
    interactive_sign_in({ email: user.email, password: 'Password1!' }, headers: headers)
  end

  def reply(headers, **params)
    post messages_path, params: { content: 'Size M is in stock.' }.merge(params), headers: headers, as: :json
  end

  describe 'claims' do
    it 'assigns the conversation to the first signed-in human who answers it' do
      headers = password_session(ivan)
      expect { reply(headers) }.to have_enqueued_job(SendReplyJob).exactly(:once)

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to eq(ivan)
      activities = enqueued_jobs.select { |job| job[:job] == Conversations::ActivityMessageJob }
      expect(activities.map { |job| job[:args].last['content'] }).to eq(['Ivan self-assigned this conversation'])
    end

    it 'does not move the owner when the other agent answers later' do
      reply(password_session(ivan))
      reply(password_session(dina))

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to eq(ivan)
    end

    it 'keeps the claim when the reply later fails to send' do
      reply(password_session(ivan))
      Message.find(response.parsed_body['id']).update!(status: :failed)

      expect(conversation.reload.assignee).to eq(ivan)
    end

    it 'claims a resolved conversation that the customer reopened' do
      conversation.update!(status: :resolved)
      create(:message, conversation: conversation, message_type: :incoming, content: 'Back again')
      expect(conversation.reload).to be_open

      reply(password_session(dina))

      expect(conversation.reload.assignee).to eq(dina)
    end

    it 'claims through the production funnel settlement path' do
      with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z',
                        UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
        reply(password_session(ivan))
      end

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to eq(ivan)
    end

    it 'claims for the mobile app sign-in and for a regular SSO sign-in' do
      mobile = password_session(dina, headers: { 'X-Chatwoot-Client-Name' => 'Chatwoot Mobile', 'X-Chatwoot-Client-Version' => '4.0.0' })
      reply(mobile)
      expect(conversation.reload.assignee).to eq(dina)

      other = create(:conversation, account: account, inbox: inbox)
      sso = interactive_sign_in({ email: ivan.email, sso_auth_token: ivan.generate_sso_auth_token })
      post "/api/v1/accounts/#{account.id}/conversations/#{other.display_id}/messages",
           params: { content: 'Hello' }, headers: sso, as: :json
      expect(other.reload.assignee).to eq(ivan)
    end
  end

  describe 'never claims' do
    it 'for any access-token request, even from a user with an interactive session' do
      session = password_session(ivan)
      expect(ivan.user_sessions.exists?(client_id: session['client'])).to be(true)
      token = { 'api_access_token' => ivan.access_token.token }

      [token, token.merge(session), token.merge('client' => session['client'])].each do |headers|
        reply(headers)
        expect(response).to have_http_status(:success)
        expect(Message.find(response.parsed_body['id'])).to be_persisted
      end

      expect(conversation.reload.assignee).to be_nil
    end

    it 'for a token minted outside an interactive sign-in, even when another session of that user exists' do
      session = password_session(ivan)
      expect(ivan.user_sessions.exists?(client_id: session['client'])).to be(true)

      reply(ivan.reload.create_new_auth_token)

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to be_nil
      expect(ivan.user_sessions.exists?(client_id: session['client'])).to be(true)
    end

    it 'for an impersonation sign-in' do
      reply(interactive_sign_in({ email: ivan.email, sso_auth_token: ivan.generate_sso_auth_token(impersonation: true) }))

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to be_nil
    end

    it 'for a private note, a reply sent as a bot, or an automation or campaign message' do
      headers = password_session(ivan)
      bot = create(:agent_bot, account: account)
      reply(headers, private: true)
      reply(headers, sender_type: 'AgentBot', sender_id: bot.id)
      # Counts as a human response natively, but the sender is not the person signed in.
      reply(headers, sender_type: 'AgentBot', sender_id: bot.id, content_attributes: { external_echo: true })
      reply(headers, content_attributes: { automation_rule_id: 1 })
      reply(headers, campaign_id: 1)

      expect(conversation.reload.assignee).to be_nil
      expect(conversation.messages.outgoing.count).to eq(5)
    end

    it 'when the reply cannot be created' do
      reply(password_session(ivan), content: "#{'h' * 150 * 1000}a")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.reload.assignee).to be_nil
    end

    it 'when the reply is rolled back after it was created' do
      headers = password_session(ivan)
      allow(Umi::Funnel::SettlementCommand).to receive(:register).and_raise(ActiveRecord::RecordInvalid)

      reply(headers)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.messages.outgoing).to be_empty
      expect(conversation.reload.assignee).to be_nil
    end

    it 'when the reply is committed but its request still answers with an error' do
      headers = password_session(ivan)
      allow_any_instance_of(Message).to receive(:send_reply).and_raise(StandardError) # rubocop:disable RSpec/AnyInstance

      reply(headers)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.messages.outgoing.count).to eq(1)
      expect(conversation.reload.assignee).to be_nil
    end

    it 'in an inbox that is not configured, or when the feature is off' do
      headers = password_session(ivan)
      settings.update!(value: { 'inbox_ids' => [] })
      reply(headers)
      settings.destroy!
      reply(headers)

      expect(conversation.reload.assignee).to be_nil
    end

    it 'for an administrator who is not a member of the inbox' do
      outsider = create(:user, account: account, role: :administrator)
      reply(password_session(outsider))

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to be_nil
    end

    it 'for a resolved, snoozed or bot-pending conversation' do
      headers = password_session(ivan)
      create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot, account: account))
      %i[resolved snoozed pending].each do |status|
        conversation.update!(status: status)
        reply(headers)
        expect(conversation.reload).to have_attributes(status: status.to_s, assignee_id: nil)
      end
    end

    it 'away from an existing human or bot owner' do
      headers = password_session(dina)
      mai = create(:user, account: account, role: :agent)
      conversation.update!(assignee: mai)
      reply(headers)
      expect(conversation.reload.assignee).to eq(mai)

      bot = create(:agent_bot, account: account)
      conversation.update!(assignee: nil, assignee_agent_bot: bot)
      reply(headers)
      expect(conversation.reload).to have_attributes(assignee_id: nil, assignee_agent_bot_id: bot.id)
    end

    it 'when an agent retries their own earlier failed message' do
      failed = create(:message, conversation: conversation, message_type: :outgoing, sender: ivan, status: :failed, content: 'Hi')
      post "#{messages_path}/#{failed.id}/retry", headers: password_session(ivan), as: :json

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to be_nil
    end

    it 'and still answers the reply normally when the claim itself fails' do
      headers = password_session(ivan)
      allow_any_instance_of(Conversation).to receive(:update!).and_raise(ActiveRecord::RecordInvalid) # rubocop:disable RSpec/AnyInstance
      allow(Rails.logger).to receive(:error).and_call_original

      reply(headers)

      expect(response).to have_http_status(:success)
      expect(conversation.reload.assignee).to be_nil
      expect(Rails.logger).to have_received(:error).with(/\A\[umi-first-responder-claim\] claim failed conversation=#{conversation.id} /)
    end
  end

  # Devise rejects these requests before the reply is created, so they stay
  # unassigned whatever the claim does.
  describe 'session lifecycle' do
    it 'ignores headers from a session that was signed out, revoked or has expired' do
      signed_out = password_session(ivan)
      delete destroy_user_session_url, headers: signed_out, as: :json
      revoked = password_session(dina)
      current = password_session(dina)
      delete "/api/v1/profile/sessions/#{dina.user_sessions.find_by!(client_id: revoked['client']).id}", headers: current, as: :json
      expect(response).to have_http_status(:success)
      expiring = password_session(ivan)

      [signed_out, revoked].each do |headers|
        reply(headers)
        expect(response).to have_http_status(:unauthorized)
      end
      travel 2.months + 1.day
      reply(expiring)
      expect(response).to have_http_status(:unauthorized)
      expect(conversation.reload.assignee).to be_nil
    end
  end
end
