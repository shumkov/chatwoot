require 'rails_helper'

RSpec.describe Umi::Fbig::ProfileProductionAttemptManifest do
  let(:values) do
    described_class::FIELD_NAMES.index_with { 'a' * 64 }.merge(
      'schema_version' => '1',
      'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
      'production_database_name' => 'chatwoot_production',
      'platforms' => 'messenger,instagram',
      'dry_run' => 'false',
      'exit_status' => '0',
      'started_at' => '2026-07-25T01:02:03Z',
      'finished_at' => '2026-07-25T01:03:04Z'
    )
  end
  let(:bytes) do
    described_class::FIELD_NAMES.map { |name| "#{name}\t#{values.fetch(name)}\n" }.join
  end

  it 'parses a complete post-prestate production attempt' do
    attempt = described_class.parse(bytes)

    expect(attempt).to have_attributes(
      production_database_name: 'chatwoot_production',
      platforms: 'messenger,instagram',
      exit_status: '0'
    )
  end

  it 'rejects prestate evidence without a sealed pre-attempt backup' do
    invalid = bytes.sub("pre_attempt_backup_sha256\t#{'a' * 64}", "pre_attempt_backup_sha256\tnone")

    expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidManifest)
  end

  it 'rejects reversed timestamps' do
    reversed = bytes.sub('finished_at	2026-07-25T01:03:04Z', 'finished_at	2026-07-25T01:01:04Z')

    expect { described_class.parse(reversed) }.to raise_error(described_class::InvalidManifest)
  end

  it 'retains honest partial evidence for a nonzero failed attempt' do
    partial = values.merge(
      'poststate_sha256' => 'none',
      'avatar_staging_sha256' => 'none',
      'run_summary_sha256' => 'none',
      'exit_status' => '70'
    )
    partial_bytes = described_class::FIELD_NAMES.map { |name| "#{name}\t#{partial.fetch(name)}\n" }.join

    expect(described_class.parse(partial_bytes)).to have_attributes(
      exit_status: '70',
      prestate_sha256: 'a' * 64,
      poststate_sha256: 'none'
    )
  end

  it 'rejects a successful attempt without backup, state, staging, or terminal summary evidence' do
    invalid = values.merge(
      'pre_attempt_backup_sha256' => 'none',
      'prestate_sha256' => 'none',
      'poststate_sha256' => 'none',
      'avatar_staging_sha256' => 'none',
      'run_summary_sha256' => 'none'
    )
    invalid_bytes = described_class::FIELD_NAMES.map { |name| "#{name}\t#{invalid.fetch(name)}\n" }.join

    expect { described_class.parse(invalid_bytes) }.to raise_error(described_class::InvalidManifest)
  end

  it 'loads only an immutable fixed-basename manifest and exact checksum' do
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      manifest_path = Pathname.new(directory).join('fbig-profile-production-attempt-v1.tsv')
      checksum_path = Pathname.new(directory).join('fbig-profile-production-attempt-v1.tsv.sha256')
      File.binwrite(manifest_path, bytes)
      File.binwrite(checksum_path, "#{Digest::SHA256.hexdigest(bytes)}  #{manifest_path.basename}\n")
      File.chmod(0o400, manifest_path)
      File.chmod(0o400, checksum_path)

      loaded = described_class.load(
        manifest_path: manifest_path.to_s,
        checksum_path: checksum_path.to_s,
        expected_uid: Process.uid
      )

      expect(loaded.sha256).to eq(Digest::SHA256.hexdigest(bytes))
    end
  end
end
