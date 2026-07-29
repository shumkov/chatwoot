require 'digest'
require 'fileutils'
require 'open3'
require 'rails_helper'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe 'UMI FB/IG production-first authorization generator' do
  let(:repository_root) { File.expand_path('../../..', __dir__) }
  let(:program) do
    File.join(repository_root, 'script/umi_fbig/support/fbig_production_first_authorize.rb')
  end
  let(:request_program) do
    File.join(repository_root, 'script/umi_fbig/support/fbig_production_first_request.rb')
  end

  def seal(directory, basename, bytes, checksum: true)
    path = File.join(directory, basename)
    File.binwrite(path, bytes)
    File.chmod(0o400, path)
    if checksum
      File.binwrite("#{path}.sha256", "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n")
      File.chmod(0o400, "#{path}.sha256")
    end
    path
  end

  def ordered_bytes(klass, values)
    klass::FIELD_NAMES.map { |field| "#{field}\t#{values.fetch(field)}\n" }.join
  end

  it 'publishes a self-contained release package from exact R2 and coordinated-backup evidence' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source')
      request_output = File.join(root, 'request')
      output = File.join(root, 'output')
      [source, request_output, output].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end

      artifacts = {}
      add = lambda do |basename, bytes, checksum: true|
        artifacts[basename] = [
          seal(source, basename, bytes, checksum: checksum),
          Digest::SHA256.hexdigest(bytes)
        ]
      end
      add.call('r2-acceptance.tsv', "r2\tacceptance\n")
      add.call('r2-launch.tsv', "r2\tlaunch\n")
      add.call('r2-probe.log', "probe\n", checksum: false)
      summary_bytes = <<~LOG
        [UMI-FBIG] stage=history_import_summary messenger_contentless_details=5 messenger_contentless_fingerprint=#{
          '1' * 64
        } instagram_contentless_details=7 instagram_contentless_fingerprint=#{'2' * 64}
      LOG
      add.call('r2-probe-summary.log', summary_bytes, checksum: false)
      add.call('fbig-profile-targets-v1.tsv', "10\t20\t30\n", checksum: false)
      add.call('fbig-unrecoverable-envelope-inspector.rb', "puts 'inspect'\n", checksum: false)
      %w[
        history.sh profile.sh final-audit.sh delivery-audit.sh delivery-checkpoint.sh
        profile-wrapper.sh storage.py recovered-generator.rb revision-generator.rb
        profile-approval-generator.rb
      ].each { |basename| add.call(basename, "#{basename}\n") }
      add.call('authorization-generator.rb', File.binread(program))

      recovered_values = {
        'schema_version' => '1',
        'platform' => 'instagram',
        'target_count' => '2',
        'target_digest_1' => '3' * 64,
        'target_digest_2' => '4' * 64,
        'source_acceptance_id' => 'candidate-r2',
        'source_repository_commit' => '5' * 40,
        'source_image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'6' * 64}",
        'source_invocation_id' => '7' * 32,
        'source_acceptance_binding_sha256' => artifacts.fetch('r2-acceptance.tsv').last,
        'source_launch_manifest_sha256' => artifacts.fetch('r2-launch.tsv').last,
        'source_probe_log_sha256' => artifacts.fetch('r2-probe.log').last,
        'source_probe_summary_sha256' => artifacts.fetch('r2-probe-summary.log').last,
        'generator_sha256' => artifacts.fetch('recovered-generator.rb').last
      }
      recovered_bytes = ordered_bytes(Umi::Fbig::RecoveredThreadTargets, recovered_values)
      add.call('fbig-recovered-thread-targets-v1.tsv', recovered_bytes)

      backup_components = {
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
      backup_values = {
        'schema_version' => '1',
        'backup_id' => '20260729T010203Z-0123456789abcdef',
        'production_database_name' => 'chatwoot_production',
        'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'8' * 64}",
        'account_id' => '1',
        'inbox_id' => '2',
        'facebook_page_id' => '3',
        'instagram_business_id' => '4',
        'created_at' => '2026-07-29T01:02:03Z'
      }
      backup_components.each do |field, (basename, content)|
        seal(source, basename, content, checksum: basename.start_with?('fbig-history-backup-'))
        backup_values[field] = Digest::SHA256.hexdigest(content)
      end
      backup_bytes = ordered_bytes(Umi::Fbig::CoordinatedBackupManifest, backup_values)
      add.call('fbig-coordinated-backup-v1.tsv', backup_bytes)

      sidecar_values = {
        'schema_version' => '1',
        'repository_commit' => recovered_values.fetch('source_repository_commit'),
        'image_digest' => recovered_values.fetch('source_image_digest'),
        'account_id' => '1',
        'inbox_id' => '2',
        'instagram_business_id' => '4',
        'before' => '2026-07-28T15:39:00Z',
        'platform' => 'instagram',
        'count' => '1',
        'fingerprint' => '9' * 64,
        'inspector_script_sha256' => artifacts.fetch('fbig-unrecoverable-envelope-inspector.rb').last,
        'approved_by' => 'r2@example.com',
        'approved_at' => '2026-07-28T16:00:00Z'
      }
      sidecar_fields = %w[
        schema_version repository_commit image_digest account_id inbox_id
        instagram_business_id before platform count fingerprint
        inspector_script_sha256 approved_by approved_at
      ]
      source_sidecar = sidecar_fields.map do |field|
        "#{field}\t#{sidecar_values.fetch(field)}\n"
      end.join
      add.call('r2-sidecar.tsv', source_sidecar, checksum: false)
      corrected_sidecar = sidecar_values.merge(
        'repository_commit' => 'a' * 40,
        'image_digest' => backup_values.fetch('image_digest'),
        'approved_by' => 'operator@example.com',
        'approved_at' => '2026-07-29T02:00:00Z'
      )
      corrected_sidecar_bytes = sidecar_fields.map do |field|
        "#{field}\t#{corrected_sidecar.fetch(field)}\n"
      end.join

      empty_messenger =
        Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: [])
      empty_instagram =
        Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: [])
      values = Umi::Fbig::ProductionFirstAuthorization::FIELD_NAMES.index_with { 'a' * 64 }.merge(
        'schema_version' => '1',
        'authorization_mode' => 'production_first',
        'repository_commit' => corrected_sidecar.fetch('repository_commit'),
        'image_digest' => corrected_sidecar.fetch('image_digest'),
        'production_database' => 'chatwoot_production',
        'account_id' => '1',
        'inbox_id' => '2',
        'facebook_page_id' => '3',
        'instagram_business_id' => '4',
        'since' => 'all',
        'before' => corrected_sidecar.fetch('before'),
        'outbound_policy' => 'pre_presence',
        'profile_mode' => 'defer',
        'r2_acceptance_binding_sha256' => artifacts.fetch('r2-acceptance.tsv').last,
        'r2_launch_manifest_sha256' => artifacts.fetch('r2-launch.tsv').last,
        'r2_probe_log_sha256' => artifacts.fetch('r2-probe.log').last,
        'r2_probe_summary_sha256' => artifacts.fetch('r2-probe-summary.log').last,
        'messenger_count' => '5',
        'messenger_fingerprint' => '1' * 64,
        'instagram_count' => '7',
        'instagram_fingerprint' => '2' * 64,
        'messenger_unavailable_message_thread_count' => '0',
        'messenger_unavailable_message_thread_fingerprint' => empty_messenger.fingerprint,
        'instagram_unavailable_message_thread_count' => '0',
        'instagram_unavailable_message_thread_fingerprint' => empty_instagram.fingerprint,
        'recovered_thread_targets_sha256' => Digest::SHA256.hexdigest(recovered_bytes),
        'placeholder_targets_sha256' => artifacts.fetch('fbig-profile-targets-v1.tsv').last,
        'unrecoverable_sidecar_sha256' => Digest::SHA256.hexdigest(corrected_sidecar_bytes),
        'unrecoverable_inspector_sha256' => artifacts.fetch('fbig-unrecoverable-envelope-inspector.rb').last,
        'coordinated_backup_manifest_sha256' => Digest::SHA256.hexdigest(backup_bytes),
        'history_program_sha256' => artifacts.fetch('history.sh').last,
        'profile_program_sha256' => artifacts.fetch('profile.sh').last,
        'final_audit_program_sha256' => artifacts.fetch('final-audit.sh').last,
        'delivery_audit_program_sha256' => artifacts.fetch('delivery-audit.sh').last,
        'delivery_checkpoint_program_sha256' => artifacts.fetch('delivery-checkpoint.sh').last,
        'profile_wrapper_sha256' => artifacts.fetch('profile-wrapper.sh').last,
        'storage_helper_sha256' => artifacts.fetch('storage.py').last,
        'recovered_target_generator_sha256' => artifacts.fetch('recovered-generator.rb').last,
        'authorization_generator_sha256' => artifacts.fetch('authorization-generator.rb').last,
        'history_revision_generator_sha256' => artifacts.fetch('revision-generator.rb').last,
        'profile_approval_generator_sha256' => artifacts.fetch('profile-approval-generator.rb').last,
        'normal_terminal_acceptance_sha256' => 'none',
        'normal_dry_pair_sha256' => 'none',
        'predecessor_authorization_sha256' => 'none',
        'predecessor_history_result_sha256' => 'none',
        'predecessor_terminal_summary_sha256' => 'none',
        'predecessor_delta_sha256' => 'none',
        'predecessor_expanded_baseline_sha256' => 'none',
        'current_state_backup_sha256' => 'none',
        'approved_by' => corrected_sidecar.fetch('approved_by'),
        'created_at' => corrected_sidecar.fetch('approved_at')
      )
      request_bytes = ordered_bytes(Umi::Fbig::ProductionFirstAuthorization, values)
      request_env = {
        'UMI_FBIG_EXPECTED_UID' => Process.uid.to_s,
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_MODE' => 'initial',
        'UMI_FBIG_REPOSITORY_COMMIT' => values.fetch('repository_commit'),
        'UMI_FBIG_IMAGE_DIGEST' => values.fetch('image_digest'),
        'UMI_FBIG_PRODUCTION_DATABASE' => values.fetch('production_database'),
        'UMI_FBIG_ACCOUNT_ID' => values.fetch('account_id'),
        'UMI_FBIG_INBOX_ID' => values.fetch('inbox_id'),
        'UMI_FBIG_FACEBOOK_PAGE_ID' => values.fetch('facebook_page_id'),
        'UMI_FBIG_INSTAGRAM_BUSINESS_ID' => values.fetch('instagram_business_id'),
        'UMI_FBIG_BEFORE' => values.fetch('before'),
        'UMI_FBIG_APPROVED_BY' => values.fetch('approved_by'),
        'UMI_FBIG_APPROVED_AT' => values.fetch('created_at'),
        'UMI_FBIG_R2_ACCEPTANCE_BINDING_PATH' => artifacts.fetch('r2-acceptance.tsv').first,
        'UMI_FBIG_R2_LAUNCH_MANIFEST_PATH' => artifacts.fetch('r2-launch.tsv').first,
        'UMI_FBIG_R2_PROBE_LOG_PATH' => artifacts.fetch('r2-probe.log').first,
        'UMI_FBIG_R2_PROBE_SUMMARY_PATH' => artifacts.fetch('r2-probe-summary.log').first,
        'UMI_FBIG_RECOVERED_THREAD_TARGETS_PATH' =>
          artifacts.fetch('fbig-recovered-thread-targets-v1.tsv').first,
        'UMI_FBIG_PLACEHOLDER_TARGETS_PATH' => artifacts.fetch('fbig-profile-targets-v1.tsv').first,
        'UMI_FBIG_UNRECOVERABLE_SIDECAR_PATH' => artifacts.fetch('r2-sidecar.tsv').first,
        'UMI_FBIG_UNRECOVERABLE_INSPECTOR_PATH' =>
          artifacts.fetch('fbig-unrecoverable-envelope-inspector.rb').first,
        'UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH' =>
          artifacts.fetch('fbig-coordinated-backup-v1.tsv').first,
        'UMI_FBIG_COORDINATED_BACKUP_MANIFEST_CHECKSUM_PATH' =>
          "#{artifacts.fetch('fbig-coordinated-backup-v1.tsv').first}.sha256",
        'UMI_FBIG_HISTORY_PROGRAM_PATH' => artifacts.fetch('history.sh').first,
        'UMI_FBIG_PROFILE_PROGRAM_PATH' => artifacts.fetch('profile.sh').first,
        'UMI_FBIG_FINAL_AUDIT_PROGRAM_PATH' => artifacts.fetch('final-audit.sh').first,
        'UMI_FBIG_DELIVERY_AUDIT_PROGRAM_PATH' => artifacts.fetch('delivery-audit.sh').first,
        'UMI_FBIG_DELIVERY_CHECKPOINT_PROGRAM_PATH' => artifacts.fetch('delivery-checkpoint.sh').first,
        'UMI_FBIG_PROFILE_WRAPPER_PATH' => artifacts.fetch('profile-wrapper.sh').first,
        'UMI_FBIG_STORAGE_HELPER_PATH' => artifacts.fetch('storage.py').first,
        'UMI_FBIG_RECOVERED_TARGET_GENERATOR_PATH' => artifacts.fetch('recovered-generator.rb').first,
        'UMI_FBIG_AUTHORIZATION_GENERATOR_PATH' => artifacts.fetch('authorization-generator.rb').first,
        'UMI_FBIG_HISTORY_REVISION_GENERATOR_PATH' => artifacts.fetch('revision-generator.rb').first,
        'UMI_FBIG_PROFILE_APPROVAL_GENERATOR_PATH' =>
          artifacts.fetch('profile-approval-generator.rb').first,
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_OUTPUT_DIR' => request_output
      }
      _request_stdout, request_stderr, request_status = Open3.capture3(
        request_env, Gem.ruby, 'bin/rails', 'runner', request_program, chdir: repository_root
      )
      expect(request_status).to be_success, request_stderr
      request = File.join(request_output, 'fbig-production-first-request-v1.tsv')
      expect(File.binread(request)).to eq(request_bytes)
      env = {
        'UMI_FBIG_EXPECTED_UID' => Process.uid.to_s,
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_PATH' => request,
        'UMI_FBIG_R2_ACCEPTANCE_BINDING_PATH' => artifacts.fetch('r2-acceptance.tsv').first,
        'UMI_FBIG_R2_LAUNCH_MANIFEST_PATH' => artifacts.fetch('r2-launch.tsv').first,
        'UMI_FBIG_R2_PROBE_LOG_PATH' => artifacts.fetch('r2-probe.log').first,
        'UMI_FBIG_R2_PROBE_SUMMARY_PATH' => artifacts.fetch('r2-probe-summary.log').first,
        'UMI_FBIG_RECOVERED_THREAD_TARGETS_PATH' =>
          artifacts.fetch('fbig-recovered-thread-targets-v1.tsv').first,
        'UMI_FBIG_PLACEHOLDER_TARGETS_PATH' => artifacts.fetch('fbig-profile-targets-v1.tsv').first,
        'UMI_FBIG_UNRECOVERABLE_SIDECAR_PATH' => artifacts.fetch('r2-sidecar.tsv').first,
        'UMI_FBIG_UNRECOVERABLE_INSPECTOR_PATH' =>
          artifacts.fetch('fbig-unrecoverable-envelope-inspector.rb').first,
        'UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH' =>
          artifacts.fetch('fbig-coordinated-backup-v1.tsv').first,
        'UMI_FBIG_HISTORY_PROGRAM_PATH' => artifacts.fetch('history.sh').first,
        'UMI_FBIG_PROFILE_PROGRAM_PATH' => artifacts.fetch('profile.sh').first,
        'UMI_FBIG_FINAL_AUDIT_PROGRAM_PATH' => artifacts.fetch('final-audit.sh').first,
        'UMI_FBIG_DELIVERY_AUDIT_PROGRAM_PATH' => artifacts.fetch('delivery-audit.sh').first,
        'UMI_FBIG_DELIVERY_CHECKPOINT_PROGRAM_PATH' => artifacts.fetch('delivery-checkpoint.sh').first,
        'UMI_FBIG_PROFILE_WRAPPER_PATH' => artifacts.fetch('profile-wrapper.sh').first,
        'UMI_FBIG_STORAGE_HELPER_PATH' => artifacts.fetch('storage.py').first,
        'UMI_FBIG_RECOVERED_TARGET_GENERATOR_PATH' => artifacts.fetch('recovered-generator.rb').first,
        'UMI_FBIG_HISTORY_REVISION_GENERATOR_PATH' => artifacts.fetch('revision-generator.rb').first,
        'UMI_FBIG_PROFILE_APPROVAL_GENERATOR_PATH' =>
          artifacts.fetch('profile-approval-generator.rb').first,
        'UMI_FBIG_PRODUCTION_FIRST_OUTPUT_DIR' => output
      }

      _stdout, stderr, status = Open3.capture3(env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root)

      expect(status).to be_success, stderr
      expect(
        Umi::Fbig::ProductionFirstAuthorization.load(
          manifest_path: File.join(output, 'fbig-production-first-authorization-v1.tsv'),
          checksum_path: File.join(output, 'fbig-production-first-authorization-v1.tsv.sha256'),
          expected_uid: Process.uid
        ).sha256
      ).to eq(Digest::SHA256.hexdigest(request_bytes))
      expect(File.binread(File.join(output, 'fbig-unrecoverable-envelope-v1.tsv')))
        .to eq(corrected_sidecar_bytes)

      predecessor_authorization_path = File.join(output, 'fbig-production-first-authorization-v1.tsv')
      predecessor_approval_path = File.join(output, 'fbig-production-first-history-approval-v1.tsv')
      predecessor_sidecar_path = File.join(output, 'fbig-unrecoverable-envelope-v1.tsv')
      predecessor_authorization = Umi::Fbig::ProductionFirstAuthorization.load(
        manifest_path: predecessor_authorization_path,
        checksum_path: "#{predecessor_authorization_path}.sha256",
        expected_uid: Process.uid
      )
      predecessor_approval = Umi::Fbig::ProductionFirstHistoryApproval.load(
        manifest_path: predecessor_approval_path,
        checksum_path: "#{predecessor_approval_path}.sha256",
        expected_uid: Process.uid
      )
      original_approval_path = predecessor_approval_path
      original_approval = predecessor_approval
      successor_source = File.join(root, 'successor-source')
      successor_attempt = File.join(root, 'successor-attempt')
      successor_request_output = File.join(root, 'successor-request')
      successor_output = File.join(root, 'successor-output')
      [successor_source, successor_attempt, successor_request_output, successor_output].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end
      successor_image = "ghcr.io/shumkov/chatwoot@sha256:#{'c' * 64}"
      successor_commit = 'd' * 40
      backup_components.each_value do |basename, content|
        seal(
          successor_source,
          basename,
          content,
          checksum: basename.start_with?('fbig-history-backup-')
        )
      end
      successor_backup_values = backup_values.merge(
        'backup_id' => '20260729T030000Z-fedcba9876543210',
        'image_digest' => successor_image,
        'created_at' => '2026-07-29T03:00:00Z'
      )
      successor_backup_bytes = ordered_bytes(Umi::Fbig::CoordinatedBackupManifest, successor_backup_values)
      successor_backup_path = seal(
        successor_source,
        'fbig-coordinated-backup-v1.tsv',
        successor_backup_bytes
      )
      revision_zero_fields = %w[
        failed_threads partially_paginated_threads uncategorized_threads unavailable_message_threads
        unavailable_message_thread_acceptance_mismatches platform_failures retry_exhaustion rate_limits
        authentication_failures lock_loss foreign_source_id_anomalies reindex_failures
        download_budget_exhaustions recovered_target_mismatches recovered_target_duplicate_listings
        ambiguous_senders predecessor_archive_not_returned
      ]
      predecessor_summary_fields = {
        'platforms' => 'messenger',
        'dry_run' => 'false',
        'scan_complete' => 'true',
        'write_complete' => 'false',
        'contentless_acceptance_mismatches' => '1',
        'exit_failures' => '1',
        'messenger_contentless_details' => '9',
        'messenger_contentless_fingerprint' => 'e' * 64
      }.merge(revision_zero_fields.index_with('0'))
      predecessor_summary_bytes =
        "[UMI-FBIG] stage=history_import_summary #{predecessor_summary_fields.map { |field, value| "#{field}=#{value}" }.join(' ')}\n"
      predecessor_delta_bytes =
        '[UMI-FBIG] stage=history_state_comparison protected_changes=0 deleted_rows=0 ' \
        "unattributed_changes=0 counter_mismatches=none\n"
      predecessor_poststate_bytes = "schema_version\t1\nrow_count\t0\n"
      predecessor_summary_path = seal(successor_attempt, 'history-summary.tsv', predecessor_summary_bytes)
      predecessor_delta_path = seal(successor_attempt, 'history-delta.tsv', predecessor_delta_bytes)
      predecessor_poststate_path = seal(
        successor_attempt,
        'fbig-history-production-poststate-v1.tsv',
        predecessor_poststate_bytes
      )
      predecessor_result_bytes = {
        'authorization_mode' => 'production_first',
        'authorization_sha256' => predecessor_authorization.sha256,
        'history_approval_sha256' => original_approval.sha256,
        'candidate_commit' => predecessor_authorization.repository_commit,
        'candidate_image' => predecessor_authorization.image_digest,
        'platforms' => 'messenger',
        'operation' => 'apply',
        'run_summary_sha256' => Digest::SHA256.hexdigest(predecessor_summary_bytes),
        'delta_sha256' => Digest::SHA256.hexdigest(predecessor_delta_bytes),
        'poststate_sha256' => Digest::SHA256.hexdigest(predecessor_poststate_bytes),
        'exit_status' => '1',
        'termination' => 'normal',
        'protected_changes' => '0',
        'deleted_rows' => '0',
        'unattributed_changes' => '0',
        'counter_mismatches' => 'none'
      }.map { |field, value| "#{field}\t#{value}\n" }.join
      predecessor_result_path = seal(
        successor_attempt,
        'fbig-history-attempt-result-v1.tsv',
        predecessor_result_bytes
      )
      revision_directory = File.join(root, 'revision')
      FileUtils.mkdir_p(revision_directory, mode: 0o700)
      File.chmod(0o700, revision_directory)
      revised_approval_values = original_approval.values.merge(
        'messenger_count' => '9',
        'messenger_fingerprint' => 'e' * 64,
        'revision_platform' => 'messenger',
        'predecessor_approval_sha256' => original_approval.sha256,
        'predecessor_attempt_result_sha256' => Digest::SHA256.hexdigest(predecessor_result_bytes),
        'predecessor_run_summary_sha256' => Digest::SHA256.hexdigest(predecessor_summary_bytes),
        'predecessor_delta_sha256' => Digest::SHA256.hexdigest(predecessor_delta_bytes),
        'approved_at' => '2026-07-29T02:30:00Z'
      )
      predecessor_approval_path = seal(
        revision_directory,
        'fbig-production-first-history-approval-v1.tsv',
        ordered_bytes(Umi::Fbig::ProductionFirstHistoryApproval, revised_approval_values)
      )
      predecessor_approval = Umi::Fbig::ProductionFirstHistoryApproval.load(
        manifest_path: predecessor_approval_path,
        checksum_path: "#{predecessor_approval_path}.sha256",
        expected_uid: Process.uid
      )
      successor_sidecar = corrected_sidecar.merge(
        'repository_commit' => successor_commit,
        'image_digest' => successor_image,
        'approved_at' => '2026-07-29T03:10:00Z'
      )
      successor_sidecar_bytes = sidecar_fields.map do |field|
        "#{field}\t#{successor_sidecar.fetch(field)}\n"
      end.join
      successor_values = values.merge(
        'repository_commit' => successor_commit,
        'image_digest' => successor_image,
        'unrecoverable_sidecar_sha256' => Digest::SHA256.hexdigest(successor_sidecar_bytes),
        'coordinated_backup_manifest_sha256' => Digest::SHA256.hexdigest(successor_backup_bytes),
        'messenger_count' => predecessor_approval.messenger_count,
        'messenger_fingerprint' => predecessor_approval.messenger_fingerprint,
        'predecessor_authorization_sha256' => predecessor_authorization.sha256,
        'predecessor_history_result_sha256' => Digest::SHA256.hexdigest(predecessor_result_bytes),
        'predecessor_terminal_summary_sha256' => Digest::SHA256.hexdigest(predecessor_summary_bytes),
        'predecessor_delta_sha256' => Digest::SHA256.hexdigest(predecessor_delta_bytes),
        'predecessor_expanded_baseline_sha256' => Digest::SHA256.hexdigest(predecessor_poststate_bytes),
        'current_state_backup_sha256' => Digest::SHA256.hexdigest(successor_backup_bytes),
        'created_at' => successor_sidecar.fetch('approved_at')
      )
      successor_request_env = request_env.merge(
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_MODE' => 'successor',
        'UMI_FBIG_REPOSITORY_COMMIT' => successor_commit,
        'UMI_FBIG_IMAGE_DIGEST' => successor_image,
        'UMI_FBIG_APPROVED_AT' => successor_sidecar.fetch('approved_at'),
        'UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH' => successor_backup_path,
        'UMI_FBIG_COORDINATED_BACKUP_MANIFEST_CHECKSUM_PATH' => "#{successor_backup_path}.sha256",
        'UMI_FBIG_PREDECESSOR_AUTHORIZATION_PATH' => predecessor_authorization_path,
        'UMI_FBIG_PREDECESSOR_AUTHORIZATION_CHECKSUM_PATH' => "#{predecessor_authorization_path}.sha256",
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH' => predecessor_approval_path,
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{predecessor_approval_path}.sha256",
        'UMI_FBIG_PREDECESSOR_RESULT_APPROVAL_PATH' => original_approval_path,
        'UMI_FBIG_PREDECESSOR_RESULT_APPROVAL_CHECKSUM_PATH' => "#{original_approval_path}.sha256",
        'UMI_FBIG_PREDECESSOR_HISTORY_RESULT_PATH' => predecessor_result_path,
        'UMI_FBIG_PREDECESSOR_TERMINAL_SUMMARY_PATH' => predecessor_summary_path,
        'UMI_FBIG_PREDECESSOR_DELTA_PATH' => predecessor_delta_path,
        'UMI_FBIG_PREDECESSOR_EXPANDED_BASELINE_PATH' => predecessor_poststate_path,
        'UMI_FBIG_PREDECESSOR_UNRECOVERABLE_SIDECAR_PATH' => predecessor_sidecar_path,
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_OUTPUT_DIR' => successor_request_output
      )
      invalid_revision_directory = File.join(root, 'invalid-revision')
      invalid_request_output = File.join(root, 'invalid-successor-request')
      [invalid_revision_directory, invalid_request_output].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end
      invalid_approval_path = seal(
        invalid_revision_directory,
        'fbig-production-first-history-approval-v1.tsv',
        ordered_bytes(
          Umi::Fbig::ProductionFirstHistoryApproval,
          revised_approval_values.merge('messenger_count' => '8')
        )
      )
      invalid_request_env = successor_request_env.merge(
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH' => invalid_approval_path,
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{invalid_approval_path}.sha256",
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_OUTPUT_DIR' => invalid_request_output
      )
      _invalid_stdout, _invalid_stderr, invalid_status = Open3.capture3(
        invalid_request_env, Gem.ruby, 'bin/rails', 'runner', request_program, chdir: repository_root
      )
      expect(invalid_status).not_to be_success
      invalid_other_revision_directory = File.join(root, 'invalid-other-revision')
      invalid_other_request_output = File.join(root, 'invalid-other-successor-request')
      [invalid_other_revision_directory, invalid_other_request_output].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end
      invalid_other_approval_path = seal(
        invalid_other_revision_directory,
        'fbig-production-first-history-approval-v1.tsv',
        ordered_bytes(
          Umi::Fbig::ProductionFirstHistoryApproval,
          revised_approval_values.merge('instagram_count' => '8')
        )
      )
      invalid_other_request_env = successor_request_env.merge(
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH' => invalid_other_approval_path,
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{invalid_other_approval_path}.sha256",
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_OUTPUT_DIR' => invalid_other_request_output
      )
      _invalid_stdout, _invalid_stderr, invalid_status = Open3.capture3(
        invalid_other_request_env, Gem.ruby, 'bin/rails', 'runner', request_program, chdir: repository_root
      )
      expect(invalid_status).not_to be_success
      _successor_request_stdout, successor_request_stderr, successor_request_status = Open3.capture3(
        successor_request_env, Gem.ruby, 'bin/rails', 'runner', request_program, chdir: repository_root
      )
      expect(successor_request_status).to be_success, successor_request_stderr
      successor_request_path = File.join(
        successor_request_output,
        'fbig-production-first-request-v1.tsv'
      )
      expect(File.binread(successor_request_path)).to eq(
        ordered_bytes(Umi::Fbig::ProductionFirstAuthorization, successor_values)
      )
      successor_authorizer_env = env.merge(
        'UMI_FBIG_PRODUCTION_FIRST_REQUEST_PATH' => successor_request_path,
        'UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH' => successor_backup_path,
        'UMI_FBIG_PREDECESSOR_AUTHORIZATION_PATH' => predecessor_authorization_path,
        'UMI_FBIG_PREDECESSOR_AUTHORIZATION_CHECKSUM_PATH' => "#{predecessor_authorization_path}.sha256",
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH' => predecessor_approval_path,
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{predecessor_approval_path}.sha256",
        'UMI_FBIG_PREDECESSOR_RESULT_APPROVAL_PATH' => original_approval_path,
        'UMI_FBIG_PREDECESSOR_RESULT_APPROVAL_CHECKSUM_PATH' => "#{original_approval_path}.sha256",
        'UMI_FBIG_PREDECESSOR_HISTORY_RESULT_PATH' => predecessor_result_path,
        'UMI_FBIG_PREDECESSOR_TERMINAL_SUMMARY_PATH' => predecessor_summary_path,
        'UMI_FBIG_PREDECESSOR_DELTA_PATH' => predecessor_delta_path,
        'UMI_FBIG_PREDECESSOR_EXPANDED_BASELINE_PATH' => predecessor_poststate_path,
        'UMI_FBIG_CURRENT_STATE_BACKUP_PATH' => successor_backup_path,
        'UMI_FBIG_PREDECESSOR_UNRECOVERABLE_SIDECAR_PATH' => predecessor_sidecar_path,
        'UMI_FBIG_PRODUCTION_FIRST_OUTPUT_DIR' => successor_output
      )
      invalid_successor_output = File.join(root, 'invalid-successor-output')
      FileUtils.mkdir_p(invalid_successor_output, mode: 0o700)
      File.chmod(0o700, invalid_successor_output)
      invalid_authorizer_env = successor_authorizer_env.merge(
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH' => invalid_approval_path,
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{invalid_approval_path}.sha256",
        'UMI_FBIG_PRODUCTION_FIRST_OUTPUT_DIR' => invalid_successor_output
      )
      _invalid_stdout, _invalid_stderr, invalid_status = Open3.capture3(
        invalid_authorizer_env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(invalid_status).not_to be_success
      _successor_stdout, successor_stderr, successor_status = Open3.capture3(
        successor_authorizer_env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(successor_status).to be_success, successor_stderr
      successor_authorization = Umi::Fbig::ProductionFirstAuthorization.load(
        manifest_path: File.join(successor_output, 'fbig-production-first-authorization-v1.tsv'),
        checksum_path: File.join(successor_output, 'fbig-production-first-authorization-v1.tsv.sha256'),
        expected_uid: Process.uid
      )
      expect(successor_authorization.predecessor_authorization_sha256).to eq(
        predecessor_authorization.sha256
      )
      expect(successor_authorization.unrecoverable_sidecar_sha256).not_to eq(
        predecessor_authorization.unrecoverable_sidecar_sha256
      )
      successor_approval = Umi::Fbig::ProductionFirstHistoryApproval.load(
        manifest_path: File.join(successor_output, 'fbig-production-first-history-approval-v1.tsv'),
        checksum_path: File.join(successor_output, 'fbig-production-first-history-approval-v1.tsv.sha256'),
        expected_uid: Process.uid
      )
      expect(successor_approval.revision_platform).to eq('messenger')
      expect(successor_approval.predecessor_approval_sha256).to eq(original_approval.sha256)
      expect(successor_approval.predecessor_attempt_result_sha256).to eq(
        Digest::SHA256.hexdigest(predecessor_result_bytes)
      )
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
