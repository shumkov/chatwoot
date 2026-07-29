require 'rails_helper'
require 'tmpdir'

RSpec.describe Umi::Fbig::HistoryApprovalManifest do
  subject(:parse) { described_class.parse(manifest) }

  let(:fields) do
    {
      'schema_version' => '2',
      'repository_commit' => 'a' * 40,
      'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
      'clone_backup_id' => '20260724T190000Z-0123456789abcdef',
      'clone_database_name' => 'chatwoot_fbig_clone',
      'database_dump_sha256' => 'c' * 64,
      'source_storage_manifest_sha256' => 'd' * 64,
      'restored_storage_manifest_sha256' => 'e' * 64,
      'account_id' => '1',
      'inbox_id' => '2',
      'facebook_page_id' => '123456789',
      'instagram_business_id' => '987654321',
      'since' => 'all',
      'before' => '2026-07-24T19:00:00Z',
      'outbound_policy' => 'pre_presence',
      'profile_mode' => 'defer',
      'messenger_count' => '2',
      'messenger_fingerprint' => 'f' * 64,
      'instagram_count' => '0',
      'instagram_fingerprint' => '1' * 64,
      'messenger_unavailable_message_thread_count' => '0',
      'messenger_unavailable_message_thread_fingerprint' => '901290cdf01a1cd38b6c8ac38c1a36fb1b02376245c8237a44fc6252971bf1fa',
      'instagram_unavailable_message_thread_count' => '0',
      'instagram_unavailable_message_thread_fingerprint' => 'bd73d5c7d96c25c097496395aec4bdd8ce66b3bd8ef474bf4a4f5cb2d317ca17',
      'placeholder_targets_sha256' => '2' * 64,
      'source_dry_log_sha256' => '3' * 64,
      'source_dry_summary_sha256' => '4' * 64,
      'approved_by' => 'operator@example.com',
      'approved_at' => '2026-07-24T20:00:00Z'
    }
  end
  let(:manifest) do
    described_class::FIELD_NAMES.map { |name| "#{name}\t#{fields.fetch(name)}\n" }.join
  end

  it 'parses the exact fixed-order v2 record and projects both accepted omission sets' do
    result = parse

    expect(result.account_id).to eq(1)
    expect(result.before).to eq(Time.zone.parse('2026-07-24 19:00:00 UTC'))
    expect(result.accepted_contentless(%w[instagram messenger])).to eq(
      'instagram' => Umi::Fbig::ContentlessFingerprint::Result.new(count: 0, fingerprint: '1' * 64),
      'messenger' => Umi::Fbig::ContentlessFingerprint::Result.new(count: 2, fingerprint: 'f' * 64)
    )
    expect(result.accepted_unavailable_message_threads(%w[instagram messenger])).to eq(
      'instagram' => Umi::Fbig::UnavailableMessageThreadFingerprint::Result.new(
        count: 0,
        fingerprint: 'bd73d5c7d96c25c097496395aec4bdd8ce66b3bd8ef474bf4a4f5cb2d317ca17'
      ),
      'messenger' => Umi::Fbig::UnavailableMessageThreadFingerprint::Result.new(
        count: 0,
        fingerprint: '901290cdf01a1cd38b6c8ac38c1a36fb1b02376245c8237a44fc6252971bf1fa'
      )
    )
  end

  it 'rejects reordered, malformed, or non-canonical records' do
    reordered = manifest.lines.values_at(1, 0, *(2...29)).join
    crlf = manifest.gsub("\n", "\r\n")
    extra_tab = manifest.sub("approved_by\toperator@example.com", "approved_by\toperator\textra")
    noncanonical_count = manifest.sub("messenger_count\t2", "messenger_count\t02")

    [reordered, crlf, extra_tab, noncanonical_count, manifest.delete_suffix("\n")].each do |invalid|
      expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'rejects values outside the manifest contract' do
    invalid_fields = {
      'schema_version' => '1',
      'repository_commit' => 'A' * 40,
      'image_digest' => "ghcr.io/shumkov/chatwoot:umi-latest@sha256:#{'b' * 64}",
      'clone_backup_id' => '20260724T190000+0000',
      'clone_database_name' => 'chatwoot-fbig-clone',
      'account_id' => '0',
      'since' => '2026-01-01T00:00:00Z',
      'before' => '2026-07-24T19:00:00+00:00',
      'outbound_policy' => 'all',
      'profile_mode' => 'inline',
      'messenger_count' => '2147483648',
      'messenger_fingerprint' => 'F' * 64,
      'messenger_unavailable_message_thread_count' => '1',
      'approved_by' => '',
      'approved_at' => '2026-07-24T20:00:00+00:00'
    }

    invalid_fields.each do |name, value|
      invalid = manifest.sub("#{name}\t#{fields.fetch(name)}", "#{name}\t#{value}")
      expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidManifest), name
    end
  end

  it 'rejects nonzero or noncanonical empty unavailable-thread acceptance for either platform' do
    nonzero = manifest.sub("instagram_unavailable_message_thread_count\t0",
                           "instagram_unavailable_message_thread_count\t2")
    arbitrary_empty = manifest.sub(
      "instagram_unavailable_message_thread_fingerprint\t#{fields.fetch('instagram_unavailable_message_thread_fingerprint')}",
      "instagram_unavailable_message_thread_fingerprint\t#{'9' * 64}"
    )

    [nonzero, arbitrary_empty].each do |invalid|
      expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'loads only a checksummed fixed-basename artifact from a locked directory' do
    Dir.mktmpdir do |directory|
      manifest_path = File.join(directory, 'fbig-approval-v2.tsv')
      checksum_path = "#{manifest_path}.sha256"
      File.binwrite(manifest_path, manifest)
      File.binwrite(
        checksum_path,
        "#{Digest::SHA256.hexdigest(manifest)}  fbig-approval-v2.tsv\n"
      )
      File.chmod(0o700, directory)
      File.chmod(0o400, manifest_path)
      File.chmod(0o400, checksum_path)

      loaded = described_class.load(
        manifest_path: manifest_path,
        checksum_path: checksum_path,
        expected_uid: Process.uid
      )

      expect(loaded.repository_commit).to eq('a' * 40)

      File.chmod(0o600, manifest_path)
      expect do
        described_class.load(
          manifest_path: manifest_path,
          checksum_path: checksum_path,
          expected_uid: Process.uid
        )
      end.to raise_error(described_class::InvalidManifest)
    end
  end
end
