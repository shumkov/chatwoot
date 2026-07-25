require 'rails_helper'

RSpec.describe Umi::Fbig::ContentlessFingerprint do
  describe '.build' do
    it 'pins the empty-set digest to the selected platform' do
      messenger = described_class.build(platform: 'messenger', mids: [])
      instagram = described_class.build(platform: 'instagram', mids: [])

      expect(messenger.to_h).to eq(
        count: 0,
        fingerprint: '04e72bcc7be4b4d95f4b952c2b73454ed844719d61466b4ad5e511c54292ca82'
      )
      expect(instagram.to_h).to eq(
        count: 0,
        fingerprint: 'b54eb945edc7e917d0f1d53aea4a631b97f98ad5238ce33ecde381a85c194da7'
      )
    end

    it 'sorts mids by UTF-8 bytes before hashing' do
      forward = described_class.build(platform: 'messenger', mids: %w[mid-2 mid-1])
      reverse = described_class.build(platform: 'messenger', mids: %w[mid-1 mid-2])

      expect(forward).to eq(reverse)
      expect(forward.to_h).to eq(
        count: 2,
        fingerprint: 'd61e4cc0fac3272aeb403a5a46cec8c8cd5d7945a450c4f92384f6c2cde5b362'
      )
    end

    it 'uses length framing rather than ambiguous concatenation' do
      left = described_class.build(platform: 'messenger', mids: %w[a bc])
      right = described_class.build(platform: 'messenger', mids: %w[ab c])

      expect(left.fingerprint).to eq('7164d2f12ad685667495abf3e887fea49d1326ef14399ecefd77b690beda4a95')
      expect(right.fingerprint).to eq('161fbb7c90453e6399582170ec1cc9cfbf1e9dfcef68d1b28e055171a0d9ebc6')
    end

    it 'rejects duplicate mids instead of silently deduplicating them' do
      expect do
        described_class.build(platform: 'messenger', mids: %w[mid-1 mid-1])
      end.to raise_error(described_class::DuplicateMidError)
    end

    it 'rejects invalid UTF-8 mids and unsupported platforms' do
      invalid_mid = "\xFF".dup.force_encoding(Encoding::UTF_8)

      expect do
        described_class.build(platform: 'messenger', mids: [invalid_mid])
      end.to raise_error(described_class::InvalidEncodingError)
      expect do
        described_class.build(platform: 'threads', mids: [])
      end.to raise_error(ArgumentError, 'unsupported platform')
    end
  end
end
