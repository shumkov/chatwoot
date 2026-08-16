# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Line::TokenService do
  around do |example|
    with_modified_env UMI_LINE_PUBLIC_BASE_URL: 'https://chatwoot.example',
                      UMI_LINE_LIFF_URL: 'https://chatwoot.example/line-connect' do
      example.run
    end
  end

  describe '.mint' do
    it 'normalises the email without putting it in the signed URL' do
      result = described_class.mint(' Person@Example.com ', provision_email: false)

      expect(result[:url]).to match(%r{\Ahttps://chatwoot\.example/line-connect\?token=})
      expect(result[:url]).not_to include('Person@Example.com')
      claim = described_class.peek(result[:url].split('token=', 2).last)
      expect(claim['email']).to eq('person@example.com')
    end
  end

  describe '.consume' do
    it 'consumes the namespaced Redis claim exactly once' do
      result = described_class.mint('person@example.com', provision_email: false)
      claim = described_class.peek(result[:url].split('token=', 2).last)

      expect(described_class.consume(claim)).to be(true)
      expect { described_class.consume(claim) }.to raise_error(described_class::Replay)
      expect(Redis::Alfred.get("#{described_class::CLAIM_PREFIX}#{claim.fetch('nonce')}"))
        .to be_nil
    end
  end

  it 'marks a welcome-email exchange as mailbox-confirmed and consumes its entry token' do
    result = described_class.mint('person@example.com')
    email_token = result.fetch(:email_entry_url).split('email_token=', 2).last

    exchanged = described_class.exchange_email_entry(email_token)
    claim = described_class.peek(exchanged.fetch(:url).split('token=', 2).last)

    expect(claim['verified_email']).to be(true)
    expect { described_class.exchange_email_entry(email_token) }
      .to raise_error(described_class::Error)
  end

  it 'rejects a tampered token' do
    result = described_class.mint('person@example.com', provision_email: false)

    expect { described_class.peek("#{result[:url].split('token=', 2).last}x") }
      .to raise_error(described_class::InvalidToken)
  end
end
