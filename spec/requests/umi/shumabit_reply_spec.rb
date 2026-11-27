# frozen_string_literal: true

require 'rails_helper'

# In a configured inbox the native "Suggest reply" button only loads a draft Shumabit already wrote as a private
# note. A tap must never start generation (Captain or a bridge turn), must answer the web and the unmodified mobile app
# with shapes they handle, and must repeat every check when a held wait completes.
RSpec.describe 'Shumabit reply loader behind the native Suggest reply button', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:bridge) { create(:user, account: account) }
  let(:cutoff) { 1_700_000_000 }
  let(:status_url) { 'http://bridge.test/webhook' }
  let(:tap_path) { "/api/v1/accounts/#{account.id}/captain/tasks/reply_suggestion" }
  let(:completion_path) { "/api/v1/accounts/#{account.id}/umi/shumabit_reply/#{conversation.display_id}/completion" }
  let(:question) do
    create(:message, conversation: conversation, message_type: :incoming, sender: contact, content: 'Is size M in stock?',
                     created_at: Time.zone.at(cutoff + 10))
  end
  let!(:settings) do
    InstallationConfig.create!(name: 'UMI_SHUMABIT_REPLY',
                               value: { 'inbox_ids' => [inbox.id], 'eligible_after_ms' => cutoff * 1000, 'wait_seconds' => 40 })
  end

  around do |example|
    with_modified_env(UMI_SHUMABIT_BRIDGE_URL: 'http://bridge.test', UMI_COMMERCE_BRIDGE_USER_ID: bridge.id.to_s) { example.run }
  end

  before do
    # Another account's conversation first, so this conversation's id and display id differ.
    create(:conversation)
    create(:inbox_member, inbox: inbox, user: admin)
  end

  # A real interactive sign-in, as the dashboard and the mobile app perform it.
  def signed_in(user)
    post new_user_session_url, params: { email: user.email, password: 'Password1!' }, as: :json
    expect(response).to have_http_status(:success)
    response.headers.slice('access-token', 'client', 'uid')
  end

  def tap(headers)
    post tap_path, params: { conversation_display_id: conversation.display_id }, headers: headers, as: :json
  end

  def draft_note(staff: 'Check the shelf first.')
    marker = { 'source_message_id' => question.id, 'policy_version' => 'draft-v1', 'contract' => 'assist-v1', 'outcome' => 'reply',
               'row_key' => "#{account.id}:#{question.id}", 'covered_message_ids' => [question.id], 'eligible_after' => cutoff,
               'seen_digest' => Digest::SHA256.hexdigest("assist-seen-v1:#{question.id}"), 'reply' => 'Yes, size M is in stock.',
               'staff' => staff }
    create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: bridge,
                     content: "Shumabit draft — review before sending:\nYes, size M is in stock.\n\nStaff only — not for the customer: #{staff}",
                     created_at: Time.zone.at(cutoff + 100), content_attributes: { 'shumabit_bridge' => true, 'shumabit_draft' => marker })
  end

  def active_status
    { status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { draft_status: 'running', terminal_reason: nil, note_id: nil, disposition: nil, validation_code: nil, output_bytes: nil,
              note_status: nil, conversation_busy: true, conversation_ambiguous: false,
              message_classes: { question.id.to_s => 'active' } }.to_json }
  end

  it 'loads the stored draft text only, without Captain, a bridge turn or any write, on every tap' do
    draft_note
    headers = signed_in(admin)
    expect(Captain::ReplySuggestionService).not_to receive(:new)
    expect do
      2.times do
        tap(headers)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq('message' => 'Yes, size M is in stock.')
      end
    end.not_to change(Message, :count)
    expect(response.body).not_to include('Check the shelf')
    expect(a_request(:any, /bridge\.test/)).not_to have_been_made
  end

  it 'keeps the native endpoint for an inbox that is not listed and when the configuration is absent' do
    other = create(:conversation, account: account, inbox: create(:inbox, account: account), contact: contact)
    service = instance_double(Captain::ReplySuggestionService, perform: { message: 'Native suggestion' })
    allow(Captain::ReplySuggestionService).to receive(:new).and_return(service)
    headers = signed_in(admin)
    post tap_path, params: { conversation_display_id: other.display_id }, headers: headers, as: :json
    expect(response.parsed_body).to eq('message' => 'Native suggestion')
    settings.destroy!
    tap(headers)
    expect(response.parsed_body).to eq('message' => 'Native suggestion')
  end

  it 'answers unavailable everywhere for a present but invalid configuration, never falling back to Captain' do
    settings.update!(value: { 'inbox_ids' => [inbox.id.to_s], 'eligible_after_ms' => cutoff * 1000 })
    expect(Captain::ReplySuggestionService).not_to receive(:new)
    headers = signed_in(admin)
    allow(Rails.logger).to receive(:error).and_call_original
    tap(headers)
    expect(Rails.logger).to have_received(:error).with('[umi-shumabit-reply] invalid UMI_SHUMABIT_REPLY configuration')
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq('error' => 'Shumabit is unavailable right now; read the latest Shumabit note or tap again later.')
    get completion_path, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(Rails.logger).to have_received(:error).with('[umi-shumabit-reply] invalid UMI_SHUMABIT_REPLY configuration').twice
  end

  it 'treats a stored configuration row with no value as invalid, not off' do
    settings.update!(value: nil)
    expect(Captain::ReplySuggestionService).not_to receive(:new)
    tap(signed_in(admin))
    expect(response).to have_http_status(:unprocessable_content)
  end

  describe 'caller' do
    before { draft_note }

    it 'refuses a token without an interactive session and an agent who cannot open the conversation, with 403 not 401' do
      expect(Captain::ReplySuggestionService).not_to receive(:new)
      tap(admin.create_new_auth_token)
      expect(response).to have_http_status(:forbidden)
      outsider = create(:user, account: account, role: :agent)
      tap(signed_in(outsider))
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq('error' => 'Shumabit suggestions need a signed-in staff session with access to this conversation.')
      get completion_path, headers: outsider.create_new_auth_token
      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses an access-token caller, which native API access lets through' do
      expect(Captain::ReplySuggestionService).not_to receive(:new)
      tap({ 'api_access_token' => admin.access_token.token })
      expect(response).to have_http_status(:forbidden)
    end
  end

  it 'denies a redacted contact with no draft yet before any status call' do
    question
    stub_request(:post, status_url).to_return(active_status)
    contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
    tap(signed_in(admin))
    expect(response.parsed_body).to eq('error' => 'Shumabit suggestions are not available for this conversation.')
    expect(response.headers.keys.grep(/umi-shumabit/i)).to be_empty
    expect(a_request(:any, /bridge\.test/)).not_to have_been_made
  end

  it 'denies a retained pre-redaction draft with a fixed answer and no status call or wait header' do
    draft_note
    contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
    headers = signed_in(admin)
    tap(headers)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq('error' => 'Shumabit suggestions are not available for this conversation.')
    expect(response.headers.keys.grep(/umi-shumabit/i)).to be_empty
    expect(a_request(:any, /bridge\.test/)).not_to have_been_made
  end

  describe 'a held tap and its completion' do
    let(:headers) { signed_in(admin) }

    before do
      question
      stub_request(:post, status_url).to_return(active_status)
    end

    it 'offers a wait while the bridge works, with Rails-built wait headers' do
      tap(headers)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'Shumabit is still working on this; tap again in a moment.')
      expect(response.headers['X-Umi-Shumabit-Recheck']).to eq(completion_path)
      expect(response.headers['X-Umi-Shumabit-Wait']).to start_with("a=#{account.id};c=#{conversation.display_id};m=#{question.id};d=")
    end

    it 'completes without another wait, and serves the draft once it lands' do
      tap(headers)
      get completion_path, headers: headers
      expect(response.parsed_body).to eq('error' => 'Shumabit has not finished; check the thread or tap again later.')
      expect(response.headers.keys.grep(/umi-shumabit/i)).to be_empty
      draft_note
      get completion_path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('message' => 'Yes, size M is in stock.')
    end

    it 'denies at completion when the contact was redacted during the wait' do
      tap(headers)
      contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
      draft_note
      get completion_path, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'Shumabit suggestions are not available for this conversation.')
    end

    it 'denies at completion when inbox access was removed during the wait' do
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent)
      agent_headers = signed_in(agent)
      tap(agent_headers)
      expect(response.headers['X-Umi-Shumabit-Wait']).to be_present
      InboxMember.where(inbox: inbox, user: agent).destroy_all
      draft_note
      get completion_path, headers: agent_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'answers unavailable for a completion of a missing conversation or an unlisted inbox' do
      unavailable = { 'error' => 'Shumabit is unavailable right now; read the latest Shumabit note or tap again later.' }
      get "/api/v1/accounts/#{account.id}/umi/shumabit_reply/999999/completion", headers: headers
      expect([response.status, response.parsed_body]).to eq([422, unavailable])
      other = create(:conversation, account: account, inbox: create(:inbox, account: account), contact: contact)
      get "/api/v1/accounts/#{account.id}/umi/shumabit_reply/#{other.display_id}/completion", headers: headers
      expect([response.status, response.parsed_body]).to eq([422, unavailable])
    end

    it 'denies at completion when the sign-in session ended during the wait' do
      tap(headers)
      expect(response.headers['X-Umi-Shumabit-Wait']).to be_present
      admin.user_sessions.destroy_all
      draft_note
      get completion_path, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq('error' => 'Shumabit suggestions need a signed-in staff session with access to this conversation.')
    end
  end

  it 'logs one fixed metadata line per request, without message, note or credential content' do
    draft_note
    headers = signed_in(admin)
    lines = []
    allow(Rails.logger).to(receive(:info).and_wrap_original do |original, *args, &block|
      lines << args.first.to_s
      original.call(*args, &block)
    end)
    tap(headers)
    line = lines.grep(/\[umi-shumabit-reply\]/).sole
    expected = "[umi-shumabit-reply] account=#{account.id} conversation=#{conversation.display_id} mode=tap answer=loaded http=200 ms="
    expect(line).to start_with(expected)
    expect(line.delete_prefix(expected)).to match(/\A\d+\z/)
    expect(lines.join).not_to include('size M')
    expect(lines.join).not_to include('Check the shelf')
  end
end
