# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'UMI LINE identity binding', type: :request do
  let(:origin) { 'https://store.example' }

  it 'mints a personalised bind URL for a submitted email' do
    klaviyo = instance_double(Umi::Line::KlaviyoClient, profile_import: true)
    allow(Umi::Line::KlaviyoClient).to receive(:new).and_return(klaviyo)

    with_modified_env UMI_LINE_BINDING_ENABLED: 'true',
                      UMI_LINE_ALLOWED_ORIGINS: origin,
                      UMI_LINE_PUBLIC_BASE_URL: 'https://chatwoot.example',
                      UMI_LINE_LIFF_URL: 'https://chatwoot.example/line-connect' do
      post '/line-connect/token',
           params: { email: ' Person@Example.com ' }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json', 'Origin' => origin }
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('url')).to match(%r{\Ahttps://chatwoot\.example/line-connect\?token=})
    expect(response.parsed_body.fetch('url')).not_to include('Person@Example.com')
  end

  it 'serves a non-cacheable LIFF page without consuming the URL claim' do
    with_modified_env UMI_LINE_BINDING_ENABLED: 'true',
                      UMI_LINE_PUBLIC_BASE_URL: 'https://chatwoot.example',
                      UMI_LINE_LIFF_ID: 'liff-id',
                      UMI_LINE_OA_ADD_FRIEND_URL: 'https://lin.ee/example',
                      UMI_LINE_CONSENT_TEXT: 'Approved consent text',
                      UMI_LINE_LIFF_SDK_SRI: 'sha384-test' do
      get '/line-connect?token=opaque-token'
    end

    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq('no-store')
    expect(response.headers['Referrer-Policy']).to eq('no-referrer')
    expect(response.headers['Content-Security-Policy']).to include("script-src 'self'")
    header_nonce = response.headers['Content-Security-Policy'][/nonce-([^']+)/, 1]
    script_nonce = response.body[/<script nonce="([^"]+)"/, 1]
    expect(header_nonce).to eq(script_nonce)
    expect(response.body).not_to include('opaque-token')
  end

  it 'rejects a storefront mint from an unconfigured origin without writing a claim' do
    klaviyo = instance_double(Umi::Line::KlaviyoClient, profile_import: true)
    allow(Umi::Line::KlaviyoClient).to receive(:new).and_return(klaviyo)

    with_modified_env UMI_LINE_BINDING_ENABLED: 'true',
                      UMI_LINE_ALLOWED_ORIGINS: origin,
                      UMI_LINE_PUBLIC_BASE_URL: 'https://chatwoot.example' do
      post '/line-connect/token',
           params: { email: 'person@example.com' }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json', 'Origin' => 'https://evil.example' }
    end

    expect(response).to have_http_status(:forbidden)
    expect(klaviyo).not_to have_received(:profile_import)
  end

  it 'rejects a mint request without an Origin header' do
    with_modified_env UMI_LINE_BINDING_ENABLED: 'true',
                      UMI_LINE_ALLOWED_ORIGINS: origin,
                      UMI_LINE_PUBLIC_BASE_URL: 'https://chatwoot.example' do
      expect do
        post '/line-connect/token',
             params: { email: 'person@example.com' }.to_json,
             headers: { 'CONTENT_TYPE' => 'application/json' }
      end.not_to have_enqueued_job(Umi::Line::KlaviyoProvisionEmailEntryJob)
    end

    expect(response).to have_http_status(:forbidden)
  end
end
