require 'rails_helper'

RSpec.describe Umi::Fbig::RecoveredThreadTargets do
  describe '.digest' do
    it 'pins the privacy-safe typed digest protocol' do
      expect(described_class.digest(platform: 'instagram', thread_id: 'thread-1'))
        .to eq('b42b5a77f911bd4f4a66a389923f567ae65c819bc44d196af12b8a2eb5f61c59')
    end

    it 'separates platforms and rejects invalid identifiers' do
      expect(described_class.digest(platform: 'messenger', thread_id: 'thread-1'))
        .not_to eq(described_class.digest(platform: 'instagram', thread_id: 'thread-1'))
      expect { described_class.digest(platform: 'instagram', thread_id: '') }.to raise_error(ArgumentError)
      expect do
        described_class.digest(platform: 'instagram', thread_id: "\xFF".b)
      end.to raise_error(ArgumentError)
      expect do
        described_class.digest(platform: 'instagram', thread_id: 'x' * (ApplicationRecord::MAX_TEXT_COLUMN_LENGTH + 1))
      end.to raise_error(ArgumentError)
    end
  end

  describe '.parse' do
    let(:first_digest) { described_class.digest(platform: 'instagram', thread_id: 'thread-1') }
    let(:second_digest) { described_class.digest(platform: 'instagram', thread_id: 'thread-2') }
    let(:values) do
      {
        'schema_version' => '1',
        'platform' => 'instagram',
        'target_count' => '2',
        'target_digest_1' => [first_digest, second_digest].min,
        'target_digest_2' => [first_digest, second_digest].max,
        'source_acceptance_id' => 'candidate-7a6929e3-c6348a23060d-r2',
        'source_repository_commit' => '7a6929e331d62c8b33801119c3fff13e74acfb51',
        'source_image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'c' * 64}",
        'source_invocation_id' => 'a65dcb24ec6a46e9b989357ebdd448e5',
        'source_acceptance_binding_sha256' => '1' * 64,
        'source_launch_manifest_sha256' => '2' * 64,
        'source_probe_log_sha256' => '3' * 64,
        'source_probe_summary_sha256' => '4' * 64,
        'generator_sha256' => '5' * 64
      }
    end
    let(:bytes) do
      described_class::FIELD_NAMES.map { |name| "#{name}\t#{values.fetch(name)}\n" }.join
    end

    it 'accepts exactly two sorted unique Instagram target digests' do
      result = described_class.parse(bytes)

      expect(result.platform).to eq('instagram')
      expect(result.digests).to eq([first_digest, second_digest].sort)
      expect(result.sha256).to eq(Digest::SHA256.hexdigest(bytes))
    end

    it 'rejects duplicates, ordering drift, and non-Instagram artifacts' do
      duplicate = values.merge('target_digest_2' => values.fetch('target_digest_1'))
      reversed = values.merge(
        'target_digest_1' => values.fetch('target_digest_2'),
        'target_digest_2' => values.fetch('target_digest_1')
      )

      [duplicate, reversed, values.merge('platform' => 'messenger')].each do |invalid|
        invalid_bytes = described_class::FIELD_NAMES.map { |name| "#{name}\t#{invalid.fetch(name)}\n" }.join
        expect { described_class.parse(invalid_bytes) }.to raise_error(described_class::InvalidTargets)
      end
    end
  end
end
