# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'UMI LINE identity binding bind endpoint', type: :request do
  let(:origin) { 'https://store.example' }
  let(:public_origin) { 'https://chatwoot.example' }
  let(:channel_id) { '1234567890' }
  let(:user_id) { "U#{'b' * 32}" }

  around do |example|
    with_modified_env UMI_LINE_BINDING_ENABLED: 'true',
                      UMI_LINE_ALLOWED_ORIGINS: origin,
                      UMI_LINE_PUBLIC_BASE_URL: 'https://chatwoot.example',
                      UMI_LINE_LIFF_URL: 'https://chatwoot.example/line-connect',
                      UMI_LINE_LOGIN_CHANNEL_ID: channel_id,
                      UMI_LINE_MESSAGING_CHANNEL_ACCESS_TOKEN: 'channel-token',
                      UMI_LINE_CONSENT_TEXT: 'Approved consent text' do
      example.run
    end
  end

  def bind_request(token, consent: true, line_status: 200)
    now = Time.current.to_i
    stub_request(:post, Umi::Line::IdentityClient::VERIFY_URI)
      .to_return(status: line_status, body: {
        iss: 'https://access.line.me', aud: channel_id, exp: now + 300, iat: now,
        sub: user_id, name: 'LINE User'
      }.to_json)
    stub_request(:get, "#{Umi::Line::IdentityClient::PROFILE_URI}/#{user_id}")
      .to_return(status: 200, body: { userId: user_id }.to_json)

    post '/line-connect/bind',
         params: {
           token: token,
           id_token: 'raw-id-token',
           consent: consent,
           line_user_id: 'Uattacker',
           display_name: 'Attacker'
         }.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json', 'Origin' => public_origin }
  end

  it 'queues a verified binding and ignores browser-supplied identity fields' do
    result = Umi::Line::TokenService.mint('person@example.com', provision_email: false)
    token = result[:url].split('token=', 2).last

    expect do
      bind_request(token)
    end.to have_enqueued_job(Umi::Line::KlaviyoBindJob).with(
      email: 'person@example.com',
      line_user_id: user_id,
      line_display_name: 'LINE User',
      consent_at: kind_of(String),
      fingerprint: Umi::Line::TokenService.fingerprint('person@example.com'),
      verified_email: false
    )
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq('status' => 'queued')
  end

  it 'rejects missing consent without consuming the claim' do
    result = Umi::Line::TokenService.mint('person@example.com', provision_email: false)
    token = result[:url].split('token=', 2).last

    bind_request(token, consent: false)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Umi::Line::TokenService.peek(token)['email']).to eq('person@example.com')
  end

  it 'does not call Klaviyo or consume the claim when LINE verification fails' do
    result = Umi::Line::TokenService.mint('person@example.com', provision_email: false)
    token = result[:url].split('token=', 2).last
    bind_request(token, line_status: 400)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Umi::Line::TokenService.peek(token)['email']).to eq('person@example.com')
    expect(a_request(:post, Umi::Line::KlaviyoClient::BASE_URI)).not_to have_been_made
  end
end
