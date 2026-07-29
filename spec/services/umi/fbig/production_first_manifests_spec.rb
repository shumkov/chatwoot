require 'rails_helper'
require 'fileutils'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe 'UMI FB/IG production-first manifests' do
  let(:empty_messenger) do
    Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: [])
  end
  let(:empty_instagram) do
    Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: [])
  end
  let(:common) do
    {
      'repository_commit' => 'a' * 40,
      'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
      'production_database' => 'chatwoot_production',
      'account_id' => '1',
      'inbox_id' => '2',
      'facebook_page_id' => '3',
      'instagram_business_id' => '4',
      'since' => 'all',
      'before' => '2026-07-28T15:39:00Z',
      'outbound_policy' => 'pre_presence',
      'profile_mode' => 'defer',
      'r2_acceptance_binding_sha256' => '1' * 64,
      'r2_launch_manifest_sha256' => '2' * 64,
      'r2_probe_log_sha256' => '3' * 64,
      'r2_probe_summary_sha256' => '4' * 64,
      'messenger_count' => '10',
      'messenger_fingerprint' => '5' * 64,
      'instagram_count' => '20',
      'instagram_fingerprint' => '6' * 64,
      'messenger_unavailable_message_thread_count' => '0',
      'messenger_unavailable_message_thread_fingerprint' => empty_messenger.fingerprint,
      'instagram_unavailable_message_thread_count' => '0',
      'instagram_unavailable_message_thread_fingerprint' => empty_instagram.fingerprint,
      'recovered_thread_targets_sha256' => '7' * 64,
      'placeholder_targets_sha256' => '8' * 64,
      'unrecoverable_sidecar_sha256' => '9' * 64,
      'unrecoverable_inspector_sha256' => '9' * 64,
      'coordinated_backup_manifest_sha256' => 'a' * 64
    }
  end

  def bytes_for(klass, values)
    klass::FIELD_NAMES.map { |field| "#{field}\t#{values.fetch(field)}\n" }.join
  end

  it 'keeps the operator authorization distinct from clone evidence' do
    values = common.merge(
      'schema_version' => '1',
      'authorization_mode' => 'production_first',
      'history_program_sha256' => 'b' * 64,
      'profile_program_sha256' => 'c' * 64,
      'final_audit_program_sha256' => 'd' * 64,
      'delivery_audit_program_sha256' => 'd' * 64,
      'delivery_checkpoint_program_sha256' => 'd' * 64,
      'profile_wrapper_sha256' => 'd' * 64,
      'storage_helper_sha256' => 'd' * 64,
      'recovered_target_generator_sha256' => 'e' * 64,
      'authorization_generator_sha256' => 'e' * 64,
      'history_revision_generator_sha256' => 'e' * 64,
      'profile_approval_generator_sha256' => 'e' * 64,
      'normal_terminal_acceptance_sha256' => 'none',
      'normal_dry_pair_sha256' => 'none',
      'predecessor_authorization_sha256' => 'none',
      'predecessor_history_result_sha256' => 'none',
      'predecessor_terminal_summary_sha256' => 'none',
      'predecessor_delta_sha256' => 'none',
      'predecessor_expanded_baseline_sha256' => 'none',
      'current_state_backup_sha256' => 'none',
      'approved_by' => 'operator@example.com',
      'created_at' => '2026-07-29T00:00:00Z'
    )

    authorization = Umi::Fbig::ProductionFirstAuthorization.parse(
      bytes_for(Umi::Fbig::ProductionFirstAuthorization, values)
    )
    expect(authorization.inbox_id).to eq(2)

    invalid = values.merge('normal_terminal_acceptance_sha256' => 'f' * 64)
    expect do
      Umi::Fbig::ProductionFirstAuthorization.parse(
        bytes_for(Umi::Fbig::ProductionFirstAuthorization, invalid)
      )
    end.to raise_error(Umi::Fbig::ProductionFirstAuthorization::InvalidAuthorization)
  end

  it 'requires literal-zero unavailable acceptance and an all-or-none revision lineage' do
    values = common.merge(
      'schema_version' => '1',
      'authorization_mode' => 'production_first',
      'production_first_authorization_sha256' => 'b' * 64,
      'revision_platform' => 'none',
      'predecessor_approval_sha256' => 'none',
      'predecessor_attempt_result_sha256' => 'none',
      'predecessor_run_summary_sha256' => 'none',
      'predecessor_delta_sha256' => 'none',
      'approved_by' => 'operator@example.com',
      'approved_at' => '2026-07-29T00:00:00Z'
    )

    approval = Umi::Fbig::ProductionFirstHistoryApproval.parse(
      bytes_for(Umi::Fbig::ProductionFirstHistoryApproval, values)
    )
    expect(approval.accepted_unavailable_message_threads(%w[messenger instagram]).values)
      .to all(have_attributes(count: 0))

    invalid = values.merge('instagram_unavailable_message_thread_count' => '1')
    expect do
      Umi::Fbig::ProductionFirstHistoryApproval.parse(
        bytes_for(Umi::Fbig::ProductionFirstHistoryApproval, invalid)
      )
    end.to raise_error(Umi::Fbig::ProductionFirstHistoryApproval::InvalidApproval)
  end

  it 'admits a matching chain parsed through the real authorization and approval classes' do
    authorization_values = common.merge(
      'schema_version' => '1',
      'authorization_mode' => 'production_first',
      'history_program_sha256' => 'b' * 64,
      'profile_program_sha256' => 'c' * 64,
      'final_audit_program_sha256' => 'd' * 64,
      'delivery_audit_program_sha256' => 'd' * 64,
      'delivery_checkpoint_program_sha256' => 'd' * 64,
      'profile_wrapper_sha256' => 'd' * 64,
      'storage_helper_sha256' => 'd' * 64,
      'recovered_target_generator_sha256' => 'e' * 64,
      'authorization_generator_sha256' => 'e' * 64,
      'history_revision_generator_sha256' => 'e' * 64,
      'profile_approval_generator_sha256' => 'e' * 64,
      'normal_terminal_acceptance_sha256' => 'none',
      'normal_dry_pair_sha256' => 'none',
      'predecessor_authorization_sha256' => 'none',
      'predecessor_history_result_sha256' => 'none',
      'predecessor_terminal_summary_sha256' => 'none',
      'predecessor_delta_sha256' => 'none',
      'predecessor_expanded_baseline_sha256' => 'none',
      'current_state_backup_sha256' => 'none',
      'approved_by' => 'operator@example.com',
      'created_at' => '2026-07-29T00:00:00Z'
    )
    authorization = Umi::Fbig::ProductionFirstAuthorization.parse(
      bytes_for(Umi::Fbig::ProductionFirstAuthorization, authorization_values)
    )
    approval_values = common.merge(
      'schema_version' => '1',
      'authorization_mode' => 'production_first',
      'production_first_authorization_sha256' => authorization.sha256,
      'revision_platform' => 'none',
      'predecessor_approval_sha256' => 'none',
      'predecessor_attempt_result_sha256' => 'none',
      'predecessor_run_summary_sha256' => 'none',
      'predecessor_delta_sha256' => 'none',
      'approved_by' => 'operator@example.com',
      'approved_at' => '2026-07-29T00:00:00Z'
    )
    approval = Umi::Fbig::ProductionFirstHistoryApproval.parse(
      bytes_for(Umi::Fbig::ProductionFirstHistoryApproval, approval_values)
    )

    expect do
      Umi::Fbig::HistoryImportService.send(:validate_production_first_chain!, authorization, approval)
    end.not_to raise_error
  end

  it 'binds profile work to both terminal history results and forbids clone evidence' do
    values = {
      'schema_version' => '1',
      'authorization_mode' => 'production_first',
      'repository_commit' => common.fetch('repository_commit'),
      'image_digest' => common.fetch('image_digest'),
      'production_database_name' => common.fetch('production_database'),
      'account_id' => '1',
      'inbox_id' => '2',
      'facebook_page_id' => '3',
      'instagram_business_id' => '4',
      'production_first_authorization_sha256' => '1' * 64,
      'coordinated_pre_profile_backup_sha256' => '2' * 64,
      'history_manifest_sha256' => '3' * 64,
      'messenger_terminal_history_result_sha256' => '4' * 64,
      'instagram_terminal_history_result_sha256' => '5' * 64,
      'source_profile_state_sha256' => '6' * 64,
      'messenger_stable_target_count' => '10',
      'messenger_stable_target_fingerprint' => '7' * 64,
      'instagram_stable_target_count' => '20',
      'instagram_stable_target_fingerprint' => '8' * 64,
      'placeholder_targets_sha256' => '9' * 64,
      'placeholder_target_count' => '2',
      'recovered_thread_targets_sha256' => 'a' * 64,
      'platforms' => 'messenger,instagram',
      'graph_delay_ms' => '250',
      'max_conversation_pages' => '10000',
      'max_rate_limit_wait_seconds' => '600',
      'max_avatar_download_bytes' => '104857600',
      'clone_terminal_acceptance_sha256' => 'none',
      'clone_profile_evidence_sha256' => 'none',
      'approved_by' => 'operator@example.com',
      'approved_at' => '2026-07-29T00:00:00Z'
    }

    approval = Umi::Fbig::ProductionFirstProfileApproval.parse(
      bytes_for(Umi::Fbig::ProductionFirstProfileApproval, values)
    )
    expect(approval.placeholder_target_count).to eq(2)

    invalid = values.merge('clone_profile_evidence_sha256' => 'b' * 64)
    expect do
      Umi::Fbig::ProductionFirstProfileApproval.parse(
        bytes_for(Umi::Fbig::ProductionFirstProfileApproval, invalid)
      )
    end.to raise_error(Umi::Fbig::ProductionFirstProfileApproval::InvalidApproval)
  end

  it 'rejects changed backup components and history snapshots outside their exact scope' do
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      components = {
        'database_dump_sha256' => ['database.dump', 'database'],
        'database_restore_list_sha256' => ['database.restore.list', 'restore-list'],
        'storage_archive_sha256' => ['storage.tar', 'storage'],
        'storage_manifest_sha256' => ['storage.manifest', 'storage-manifest'],
        'messenger_history_state_sha256' => [
          'fbig-history-backup-messenger-state-v1.tsv',
          "schema_version\t1\naccount_id\t1\ninbox_id\t2\nplatforms\tmessenger\n" \
          "captured_at\t2026-07-29T01:02:03Z\nrow_count\t0\n"
        ],
        'instagram_history_state_sha256' => [
          'fbig-history-backup-instagram-state-v1.tsv',
          "schema_version\t1\naccount_id\t1\ninbox_id\t2\nplatforms\tinstagram\n" \
          "captured_at\t2026-07-29T01:02:03Z\nrow_count\t0\n"
        ]
      }
      components.each_value do |basename, content|
        File.binwrite(File.join(directory, basename), content)
        File.chmod(0o400, File.join(directory, basename))
        next unless basename.start_with?('fbig-history-backup-')

        File.binwrite(
          File.join(directory, "#{basename}.sha256"),
          "#{Digest::SHA256.hexdigest(content)}  #{basename}\n"
        )
        File.chmod(0o400, File.join(directory, "#{basename}.sha256"))
      end
      values = {
        'schema_version' => '1',
        'backup_id' => '20260729T010203Z-0123456789abcdef',
        'production_database_name' => 'chatwoot_production',
        'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'a' * 64}",
        'account_id' => '1',
        'inbox_id' => '2',
        'facebook_page_id' => '3',
        'instagram_business_id' => '4',
        'created_at' => '2026-07-29T01:02:03Z'
      }
      components.each do |field, (basename, _)|
        values[field] = Digest::SHA256.file(File.join(directory, basename)).hexdigest
      end
      bytes = Umi::Fbig::CoordinatedBackupManifest::FIELD_NAMES.map do |field|
        "#{field}\t#{values.fetch(field)}\n"
      end.join
      manifest = File.join(directory, 'fbig-coordinated-backup-v1.tsv')
      File.binwrite(manifest, bytes)
      File.chmod(0o400, manifest)
      File.binwrite("#{manifest}.sha256", "#{Digest::SHA256.hexdigest(bytes)}  #{File.basename(manifest)}\n")
      File.chmod(0o400, "#{manifest}.sha256")

      database_dump = File.join(directory, 'database.dump')
      allow(File).to receive(:open).and_wrap_original do |method, path, *arguments, &block|
        next method.call(path, *arguments, &block) unless path.to_s == database_dump && block

        method.call(path, *arguments) do |file|
          reader = Object.new
          reader.define_singleton_method(:stat) { file.stat }
          reader.define_singleton_method(:read) do |*read_arguments|
            raise 'database dump was read without a bounded chunk size' if read_arguments.empty?

            file.read(*read_arguments)
          end
          block.call(reader)
        end
      end
      expect(
        Umi::Fbig::CoordinatedBackupManifest.load(
          manifest_path: manifest,
          checksum_path: "#{manifest}.sha256",
          expected_uid: Process.uid
        ).backup_id
      ).to eq('20260729T010203Z-0123456789abcdef')

      bundled_manifest = File.join(directory, 'fbig-coordinated-pre-profile-backup-v1.tsv')
      File.binwrite(bundled_manifest, bytes)
      File.chmod(0o400, bundled_manifest)
      File.binwrite(
        "#{bundled_manifest}.sha256",
        "#{Digest::SHA256.hexdigest(bytes)}  #{File.basename(bundled_manifest)}\n"
      )
      File.chmod(0o400, "#{bundled_manifest}.sha256")
      expect(
        Umi::Fbig::CoordinatedBackupManifest.load(
          manifest_path: bundled_manifest,
          checksum_path: "#{bundled_manifest}.sha256",
          expected_uid: Process.uid
        ).backup_id
      ).to eq('20260729T010203Z-0123456789abcdef')

      messenger_state = File.join(directory, 'fbig-history-backup-messenger-state-v1.tsv')
      original_state = File.binread(messenger_state)
      [
        original_state.sub("account_id\t1\n", "account_id\t9\n"),
        original_state.sub("inbox_id\t2\n", "inbox_id\t9\n"),
        original_state.sub("platforms\tmessenger\n", "platforms\tinstagram\n")
      ].each do |wrong_state|
        File.chmod(0o600, messenger_state)
        File.binwrite(messenger_state, wrong_state)
        File.chmod(0o400, messenger_state)
        File.chmod(0o600, "#{messenger_state}.sha256")
        File.binwrite(
          "#{messenger_state}.sha256",
          "#{Digest::SHA256.hexdigest(wrong_state)}  #{File.basename(messenger_state)}\n"
        )
        File.chmod(0o400, "#{messenger_state}.sha256")
        wrong_values = values.merge(
          'messenger_history_state_sha256' => Digest::SHA256.hexdigest(wrong_state)
        )
        wrong_bytes = Umi::Fbig::CoordinatedBackupManifest::FIELD_NAMES.map do |field|
          "#{field}\t#{wrong_values.fetch(field)}\n"
        end.join
        File.chmod(0o600, manifest)
        File.binwrite(manifest, wrong_bytes)
        File.chmod(0o400, manifest)
        File.chmod(0o600, "#{manifest}.sha256")
        File.binwrite(
          "#{manifest}.sha256",
          "#{Digest::SHA256.hexdigest(wrong_bytes)}  #{File.basename(manifest)}\n"
        )
        File.chmod(0o400, "#{manifest}.sha256")
        expect do
          Umi::Fbig::CoordinatedBackupManifest.load(
            manifest_path: manifest,
            checksum_path: "#{manifest}.sha256",
            expected_uid: Process.uid
          )
        end.to raise_error(Umi::Fbig::CoordinatedBackupManifest::InvalidManifest)
      end
      File.chmod(0o600, messenger_state)
      File.binwrite(messenger_state, original_state)
      File.chmod(0o400, messenger_state)
      File.chmod(0o600, "#{messenger_state}.sha256")
      File.binwrite(
        "#{messenger_state}.sha256",
        "#{Digest::SHA256.hexdigest(original_state)}  #{File.basename(messenger_state)}\n"
      )
      File.chmod(0o400, "#{messenger_state}.sha256")
      File.chmod(0o600, manifest)
      File.binwrite(manifest, bytes)
      File.chmod(0o400, manifest)
      File.chmod(0o600, "#{manifest}.sha256")
      File.binwrite("#{manifest}.sha256", "#{Digest::SHA256.hexdigest(bytes)}  #{File.basename(manifest)}\n")
      File.chmod(0o400, "#{manifest}.sha256")

      File.chmod(0o600, File.join(directory, 'storage.tar'))
      File.binwrite(File.join(directory, 'storage.tar'), 'substituted')
      File.chmod(0o400, File.join(directory, 'storage.tar'))
      expect do
        Umi::Fbig::CoordinatedBackupManifest.load(
          manifest_path: manifest,
          checksum_path: "#{manifest}.sha256",
          expected_uid: Process.uid
        )
      end.to raise_error(Umi::Fbig::CoordinatedBackupManifest::InvalidManifest)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
