require 'rails_helper'

RSpec.describe Umi::Fbig::ProfileApprovalManifest do
  let(:values) do
    described_class::FIELD_NAMES.index_with { 'a' * 64 }.merge(
      'schema_version' => '1',
      'repository_commit' => 'b' * 40,
      'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'c' * 64}",
      'clone_database_name' => 'chatwoot_fbig_clone',
      'production_database_name' => 'chatwoot_production',
      'account_id' => '1',
      'inbox_id' => '2',
      'facebook_page_id' => '1000',
      'instagram_business_id' => '2000',
      'platforms' => 'messenger,instagram',
      'graph_delay_ms' => '250',
      'max_conversation_pages' => '10000',
      'max_rate_limit_wait_seconds' => '3600',
      'max_avatar_download_bytes' => '104857600',
      'predecessor_profile_approval_sha256' => 'none',
      'predecessor_production_attempt_sha256' => 'none',
      'messenger_stable_target_count' => '73',
      'instagram_stable_target_count' => '590',
      'approved_by' => 'operator@example.com',
      'approved_at' => '2026-07-24T20:00:00Z'
    )
  end
  let(:bytes) do
    described_class::FIELD_NAMES.map { |name| "#{name}\t#{values.fetch(name)}\n" }.join
  end

  it 'parses the exact fixed-order production profile approval' do
    manifest = described_class.parse(bytes)

    expect(manifest).to have_attributes(
      account_id: 1,
      inbox_id: 2,
      clone_database_name: 'chatwoot_fbig_clone',
      production_database_name: 'chatwoot_production'
    )
    expect(manifest.platforms).to eq(%w[messenger instagram])
  end

  it 'rejects broken predecessor pairs, database aliasing, and reordered fields' do
    invalid_predecessor = bytes.sub(
      "predecessor_profile_approval_sha256\tnone",
      "predecessor_profile_approval_sha256\t#{'d' * 64}"
    )
    unsupported_predecessor = bytes
                              .sub(
                                "predecessor_profile_approval_sha256\tnone",
                                "predecessor_profile_approval_sha256\t#{'d' * 64}"
                              )
                              .sub(
                                "predecessor_production_attempt_sha256\tnone",
                                "predecessor_production_attempt_sha256\t#{'e' * 64}"
                              )
    same_database = bytes.sub(
      "production_database_name\tchatwoot_production",
      "production_database_name\tchatwoot_fbig_clone"
    )
    reordered = bytes.lines.values_at(1, 0, *(2...31)).join

    {
      predecessor: invalid_predecessor,
      unsupported_predecessor: unsupported_predecessor,
      database: same_database,
      order: reordered
    }.each do |reason, invalid|
      expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidManifest), reason.to_s
    end
  end
end
