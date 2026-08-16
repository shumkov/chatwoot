# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Line::KlaviyoClient do
  around do |example|
    with_modified_env UMI_KLAVIYO_PRIVATE_API_KEY: 'private-key' do
      example.run
    end
  end

  it 'writes the complete LINE property set with the pinned API revision' do
    stub_request(:post, described_class::BASE_URI)
      .with(
        headers: {
          'Authorization' => 'Klaviyo-API-Key private-key',
          'Content-Type' => 'application/vnd.api+json',
          'revision' => Umi::Line::Config::API_REVISION
        },
        body: hash_including(
          'data' => hash_including(
            'type' => 'profile',
            'attributes' => hash_including(
              'email' => 'person@example.com',
              'properties' => hash_including('line_user_id' => 'Uabc')
            )
          )
        )
      ).to_return(status: 200, body: '{}')

    expect(described_class.new.profile_import(email: 'person@example.com', properties: { 'line_user_id' => 'Uabc' }))
      .to be_present
  end

  it 'classifies rate limits as retryable job failures' do
    stub_request(:post, described_class::BASE_URI).to_return(status: 429, body: '{}')

    expect { described_class.new.profile_import(email: 'person@example.com', properties: {}) }
      .to raise_error(described_class::TransientError)
  end
end
