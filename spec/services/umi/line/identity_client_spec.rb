# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Line::IdentityClient do
  let(:channel_id) { '1234567890' }
  let(:user_id) { "U#{'a' * 32}" }

  around do |example|
    with_modified_env UMI_LINE_LOGIN_CHANNEL_ID: channel_id,
                      UMI_LINE_MESSAGING_CHANNEL_ACCESS_TOKEN: 'channel-token' do
      example.run
    end
  end

  it 'verifies the raw ID token and then verifies the followed user through the bot channel' do
    now = Time.current.to_i
    stub_request(:post, described_class::VERIFY_URI)
      .with(body: hash_including('id_token' => 'raw-id-token', 'client_id' => channel_id))
      .to_return(status: 200, body: {
        iss: 'https://access.line.me', aud: channel_id, exp: now + 300, iat: now,
        sub: user_id, name: 'Test User', email: 'private@example.com', picture: 'https://example.com/picture'
      }.to_json)
    stub_request(:get, "#{described_class::PROFILE_URI}/#{user_id}")
      .with(headers: { 'Authorization' => 'Bearer channel-token' })
      .to_return(status: 200, body: { userId: user_id, displayName: 'Test User' }.to_json)

    identity = described_class.new.verify_id_token('raw-id-token')

    expect(identity).to eq(user_id: user_id, display_name: 'Test User')
    expect(described_class.new.verify_friendship!(user_id)).to be(true)
  end

  it 'rejects an old ID token before any binding write' do
    now = Time.current.to_i
    stub_request(:post, described_class::VERIFY_URI)
      .to_return(status: 200, body: {
        iss: 'https://access.line.me', aud: channel_id, exp: now + 300,
        iat: now - Umi::Line::Config::ID_TOKEN_FRESHNESS.to_i - 1, sub: user_id
      }.to_json)

    expect { described_class.new.verify_id_token('old-id-token') }
      .to raise_error(described_class::Error, /invalid identity claims/)
  end
end
