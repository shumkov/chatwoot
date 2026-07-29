require 'rails_helper'

# rubocop:disable Lint/StructNewOverride, RSpec/ExampleLength, RSpec/SpecFilePathFormat
RSpec.describe Umi::Fbig::HistoryImportService, '.preflight_task_environment!' do
  describe '.validate_production_first_chain!' do
    let(:common) do
      %w[
        repository_commit image_digest production_database account_id inbox_id facebook_page_id
        instagram_business_id since before outbound_policy profile_mode coordinated_backup_manifest_sha256
        recovered_thread_targets_sha256 placeholder_targets_sha256 unrecoverable_sidecar_sha256
        messenger_unavailable_message_thread_count messenger_unavailable_message_thread_fingerprint
        instagram_unavailable_message_thread_count instagram_unavailable_message_thread_fingerprint
        r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
      ].index_with { |field| field }
    end
    let(:authorization) do
      values = common.merge(
        'messenger_count' => '5',
        'messenger_fingerprint' => 'a' * 64,
        'instagram_count' => '7',
        'instagram_fingerprint' => 'b' * 64
      )
      Struct.new(:values, :sha256) do
        def method_missing(name, *, &)
          return values.fetch(name.to_s) if values.key?(name.to_s)

          super
        end

        def respond_to_missing?(name, *)
          values.key?(name.to_s) || super
        end
      end.new(values, 'c' * 64)
    end

    def approval_for(authorization, revision_platform:, overrides: {})
      values = authorization.values.merge(overrides).merge(
        'revision_platform' => revision_platform,
        'production_first_authorization_sha256' => authorization.sha256
      )
      Struct.new(:values) do
        def method_missing(name, *, &)
          return values.fetch(name.to_s) if values.key?(name.to_s)

          super
        end

        def respond_to_missing?(name, *)
          values.key?(name.to_s) || super
        end
      end.new(values)
    end

    it 'allows only the selected contentless projection to change in a revision' do
      revised = approval_for(
        authorization,
        revision_platform: 'instagram',
        overrides: { 'instagram_count' => '8', 'instagram_fingerprint' => 'd' * 64 }
      )

      expect do
        described_class.send(:validate_production_first_chain!, authorization, revised)
      end.not_to raise_error
    end

    it 'allows a carried revision whose accepted projections are bound into a successor authorization' do
      carried = approval_for(authorization, revision_platform: 'messenger')

      expect do
        described_class.send(:validate_production_first_chain!, authorization, carried)
      end.not_to raise_error
    end

    it 'rejects a revision that also changes the unselected platform projection' do
      revised = approval_for(
        authorization,
        revision_platform: 'instagram',
        overrides: {
          'instagram_count' => '8',
          'instagram_fingerprint' => 'd' * 64,
          'messenger_count' => '6'
        }
      )

      expect { described_class.send(:validate_production_first_chain!, authorization, revised) }
        .to raise_error(StandardError) { |error| expect(error.class.name).to eq('Umi::Fbig::HistoryImportService::ConfigurationError') }
    end
  end

  it 'admits one live platform only through the separate production-first chain' do
    authorization = instance_double(Umi::Fbig::ProductionFirstAuthorization, sha256: 'a' * 64)
    empty = Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: [])
    approval = instance_double(
      Umi::Fbig::ProductionFirstHistoryApproval,
      repository_commit: 'b' * 40,
      image_digest: "ghcr.io/shumkov/chatwoot@sha256:#{'c' * 64}",
      production_database: 'chatwoot_production',
      before: Time.zone.parse('2026-07-28 15:39:00 UTC'),
      outbound_policy: 'pre_presence',
      profile_mode: 'defer',
      coordinated_backup_manifest_sha256: 'd' * 64,
      account_id: 1,
      inbox_id: 2,
      facebook_page_id: 3,
      instagram_business_id: 4,
      recovered_thread_targets_sha256: 'e' * 64,
      accepted_contentless: {
        'instagram' => Umi::Fbig::ContentlessFingerprint::Result.new(count: 2, fingerprint: 'f' * 64)
      },
      accepted_unavailable_message_threads: { 'instagram' => empty }
    )
    targets = Umi::Fbig::RecoveredThreadTargets::Result.new(
      platform: 'instagram',
      digests: %w[1 2].map { |value| value * 64 },
      sha256: approval.recovered_thread_targets_sha256,
      values: {}
    )
    allow(Umi::Fbig::ProductionFirstAuthorization).to receive(:load).and_return(authorization)
    allow(Umi::Fbig::ProductionFirstHistoryApproval).to receive(:load).and_return(approval)
    allow(Umi::Fbig::RecoveredThreadTargets).to receive(:load).and_return(targets)
    backup = instance_double(
      Umi::Fbig::CoordinatedBackupManifest,
      sha256: approval.coordinated_backup_manifest_sha256,
      production_database_name: approval.production_database,
      image_digest: approval.image_digest,
      account_id: approval.account_id,
      inbox_id: approval.inbox_id,
      facebook_page_id: approval.facebook_page_id,
      instagram_business_id: approval.instagram_business_id
    )
    allow(Umi::Fbig::CoordinatedBackupManifest).to receive(:load).and_return(backup)
    allow(described_class).to receive(:validate_production_first_chain!)
    env = {
      'UMI_FBIG_HISTORY_APPROVAL_MODE' => 'production_first',
      'DRY_RUN' => 'false',
      'PLATFORMS' => 'instagram',
      'ACK_EXPAND_EXISTING' => 'true',
      'ACK_PRODUCTION_FIRST_LIVE_IMPORT' => 'true',
      'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH' => '/audit/authorization.tsv',
      'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_CHECKSUM_PATH' => '/audit/authorization.tsv.sha256',
      'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_SHA256' => authorization.sha256,
      'UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_PATH' => '/audit/history.tsv',
      'UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_CHECKSUM_PATH' => '/audit/history.tsv.sha256',
      'UMI_FBIG_RUNTIME_REPOSITORY_COMMIT' => approval.repository_commit,
      'UMI_FBIG_RUNTIME_IMAGE_DIGEST' => approval.image_digest,
      'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => approval.production_database,
      'UMI_FBIG_PRE_HISTORY_BACKUP_MANIFEST_PATH' => '/backup/manifest.tsv',
      'UMI_FBIG_PRE_HISTORY_BACKUP_MANIFEST_CHECKSUM_PATH' => '/backup/manifest.tsv.sha256',
      'UMI_FBIG_RECOVERED_THREAD_TARGETS_PATH' => '/audit/targets.tsv',
      'UMI_FBIG_RECOVERED_THREAD_TARGETS_CHECKSUM_PATH' => '/audit/targets.tsv.sha256',
      'UMI_FBIG_RECOVERED_THREAD_TARGETS_SHA256' => targets.sha256,
      'UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES' => '104857600'
    }

    envelope = described_class.preflight_task_environment!(
      env: env,
      now: Time.zone.parse('2026-07-29 00:00:00 UTC'),
      expected_uid: Process.uid
    )

    expect(envelope).to have_attributes(
      approval_mode: 'production_first',
      authorization_sha256: authorization.sha256,
      dry_run: false,
      platforms: ['instagram'],
      recovered_thread_targets: targets
    )
    expect(described_class).to have_received(:validate_production_first_chain!).with(authorization, approval)
    expect(Umi::Fbig::CoordinatedBackupManifest).to have_received(:load)
  end
end
# rubocop:enable Lint/StructNewOverride, RSpec/ExampleLength, RSpec/SpecFilePathFormat
