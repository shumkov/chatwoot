# frozen_string_literal: true

require 'rails_helper'

# Shumabit follows private @shumabit notes as staff direction only when the note was written from a signed-in session.
# The automation can share a staff member's own account and write with that account's access token, so the sender
# alone proves nothing. The server records the signed-in sender on the note; nothing a client sends can set it.
RSpec.describe 'Signed-in private note provenance', type: :request do
  let(:key) { 'umi_signed_in_sender_id' }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  # The owner's own account is also the automation's identity: the automation holds its access token.
  let(:owner) { create(:user, account: account, role: :administrator, name: 'Owner') }
  let(:agent) { create(:user, account: account, role: :agent, name: 'Agent') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:messages_path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages" }

  before do
    [owner, agent].each { |user| create(:inbox_member, inbox: inbox, user: user) }
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

  def note(headers, **params)
    post messages_path, params: { content: '@shumabit shorter please', private: true }.merge(params), headers: headers, as: :json
    Message.find_by(id: response.parsed_body['id'])
  end

  describe 'marks the note' do
    it "with the owner's id when the owner writes it signed in to the account the automation also uses" do
      session = password_session(owner)
      expect(owner.access_token.token).to be_present

      message = note(session)

      expect(response).to have_http_status(:success)
      expect(message.content_attributes[key]).to eq(owner.id)
      expect(message.webhook_data[:content_attributes][key]).to eq(owner.id)
      get messages_path, headers: session, as: :json
      listed = response.parsed_body['payload'].find { |item| item['id'] == message.id }
      expect(listed['content_attributes'][key]).to eq(owner.id)
    end

    it 'with the id of any other signed-in staff member, on the mobile app or through SSO' do
      mobile = password_session(agent, headers: { 'X-Chatwoot-Client-Name' => 'Chatwoot Mobile', 'X-Chatwoot-Client-Version' => '4.0.0' })
      expect(note(mobile).content_attributes[key]).to eq(agent.id)

      sso = interactive_sign_in({ email: owner.email, sso_auth_token: owner.generate_sso_auth_token })
      expect(note(sso).content_attributes[key]).to eq(owner.id)
    end

    it 'with the signed-in sender, replacing any value the client sent' do
      forged = note(password_session(owner), content_attributes: { key => agent.id, 'in_reply_to' => nil })

      expect(forged.content_attributes[key]).to eq(owner.id)
    end

    it 'when the private flag arrives as a string' do
      expect(note(password_session(agent), private: 'true').content_attributes[key]).to eq(agent.id)
    end

    # Chatwoot does not rotate tokens per request, so a session keeps its client, and that client keeps its session row.
    it 'on every later note of the same session, and again after the token is validated' do
      expect(DeviseTokenAuth.change_headers_on_each_request).to be(false)
      session = password_session(owner)
      expect(note(session).content_attributes[key]).to eq(owner.id)

      get '/auth/validate_token', headers: session, as: :json
      expect(response).to have_http_status(:success)

      expect(note(session).content_attributes[key]).to eq(owner.id)
    end
  end

  describe 'never marks' do
    it 'a note written with an access token, even one that carries a forged value or signed-in headers' do
      session = password_session(owner)
      token = { 'api_access_token' => owner.access_token.token }

      [token, token.merge(session), token.merge('client' => session['client'])].each do |headers|
        message = note(headers, content_attributes: { key => owner.id })
        expect(response).to have_http_status(:success)
        expect(message.content_attributes).not_to have_key(key)
      end
    end

    it 'a note written with a token minted outside an interactive sign-in, or from an impersonation sign-in' do
      password_session(owner)
      expect(note(owner.reload.create_new_auth_token).content_attributes).not_to have_key(key)

      impersonation = interactive_sign_in({ email: owner.email, sso_auth_token: owner.generate_sso_auth_token(impersonation: true) })
      expect(note(impersonation).content_attributes).not_to have_key(key)
    end

    it 'a public reply, a note sent as a bot, or a note whose private flag is false' do
      session = password_session(owner)
      # A bot whose id equals the signed-in user's id, so only the sender type tells them apart.
      bot = create(:agent_bot, account: account, id: owner.id)

      [note(session, private: false, content_attributes: { key => owner.id }),
       note(session, private: 'false'),
       note(session, sender_type: 'AgentBot', sender_id: bot.id, content_attributes: { key => owner.id })].each do |message|
        expect(response).to have_http_status(:success)
        expect(message.content_attributes).not_to have_key(key)
      end
    end

    it 'a private note created through another action of a signed-in session' do
      contact_inbox = create(:contact_inbox, inbox: inbox)
      post "/api/v1/accounts/#{account.id}/conversations", headers: password_session(owner), as: :json,
                                                           params: { source_id: contact_inbox.source_id,
                                                                     message: { content: '@shumabit hi', private: true,
                                                                                content_attributes: { key => owner.id } } }

      expect(response).to have_http_status(:success)
      created = Conversation.find_by!(display_id: response.parsed_body['id'], account: account).messages.where(private: true).sole
      expect(created.content_attributes).not_to have_key(key)
    end

    it 'once the session row is gone, even while devise still accepts the token' do
      session = password_session(owner)
      owner.user_sessions.delete_all

      message = note(session)

      expect(response).to have_http_status(:success)
      expect(message.content_attributes).not_to have_key(key)
    end

    it 'with headers from a session that was signed out, revoked or has expired: devise refuses the request' do
      signed_out = password_session(owner)
      delete destroy_user_session_url, headers: signed_out, as: :json
      revoked = password_session(agent)
      current = password_session(agent)
      delete "/api/v1/profile/sessions/#{agent.user_sessions.find_by!(client_id: revoked['client']).id}", headers: current, as: :json
      expect(response).to have_http_status(:success)
      expiring = password_session(owner)

      [signed_out, revoked].each do |headers|
        note(headers)
        expect(response).to have_http_status(:unauthorized)
      end
      travel 2.months + 1.day
      note(expiring)
      expect(response).to have_http_status(:unauthorized)
      expect(conversation.messages).to be_empty
    end

    it 'a later message on the same thread after the request failed' do
      session = password_session(owner)
      note(session, content: "#{'h' * 150 * 1000}a")
      expect(response).to have_http_status(:unprocessable_entity)

      later = create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: owner,
                               content_attributes: { key => owner.id })

      expect(later.content_attributes).not_to have_key(key)
    end
  end

  describe 'after creation' do
    let(:session) { password_session(owner) }

    it 'keeps the mark through a native translation and drops it when the note is deleted' do
      marked = note(session)
      marked.update!(translations: { 'th' => 'สั้นลงหน่อย' })
      expect(marked.reload.content_attributes[key]).to eq(owner.id)

      delete "#{messages_path}/#{marked.id}", headers: session, as: :json

      expect(response).to have_http_status(:success)
      expect(marked.reload.content_attributes).not_to have_key(key)
    end

    it 'can never gain or change the mark through an update' do
      unmarked = note({ 'api_access_token' => owner.access_token.token })
      unmarked.update!(content_attributes: unmarked.content_attributes.merge(key => owner.id))
      expect(unmarked.reload.content_attributes).not_to have_key(key)

      marked = note(session)
      marked.update!(content_attributes: marked.content_attributes.merge(key => agent.id))
      expect(marked.reload.content_attributes[key]).to eq(owner.id)
    end
  end
end
