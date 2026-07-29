require 'digest'
require 'fileutils'
require 'rails_helper'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe 'UMI FB/IG production-first profile approval generator' do
  let(:repository_root) { File.expand_path('../../..', __dir__) }
  let(:program) do
    File.join(repository_root, 'script/umi_fbig/support/fbig_production_first_profile_approve.rb')
  end

  def seal(directory, basename, bytes)
    path = File.join(directory, basename)
    File.binwrite(path, bytes)
    File.chmod(0o400, path)
    File.binwrite("#{path}.sha256", "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n")
    File.chmod(0o400, "#{path}.sha256")
    path
  end

  def ordered_bytes(klass, values)
    klass::FIELD_NAMES.map { |field| "#{field}\t#{values.fetch(field)}\n" }.join
  end

  it 'accepts a terminal Messenger ancestor and bundles every coordinated backup component' do
    Dir.mktmpdir do |root|
      authorization_directory = File.join(root, 'authorization')
      messenger_directory = File.join(root, 'messenger')
      instagram_directory = File.join(root, 'instagram')
      backup_directory = File.join(root, 'backup')
      source_directory = File.join(root, 'source')
      output_directory = File.join(root, 'output')
      [
        authorization_directory, messenger_directory, instagram_directory,
        backup_directory, source_directory, output_directory
      ].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end

      target_bytes = "1\t1\t123456\n"
      target_path = seal(source_directory, 'fbig-profile-targets-v1.tsv', target_bytes)
      source_state_bytes = "schema_version\t1\naccount_id\t1\ninbox_id\t2\nrow_count\t0\n"
      source_state_path = seal(source_directory, 'fbig-profile-state-v1.tsv', source_state_bytes)

      component_contents = {
        'database.dump' => 'database',
        'database.restore.list' => 'restore-list',
        'storage.tar' => 'storage',
        'storage.manifest' => 'storage-manifest',
        'fbig-history-backup-messenger-state-v1.tsv' =>
          "schema_version\t1\naccount_id\t1\ninbox_id\t2\nplatforms\tmessenger\n" \
          "captured_at\t2026-07-29T01:02:03Z\nrow_count\t0\n",
        'fbig-history-backup-instagram-state-v1.tsv' =>
          "schema_version\t1\naccount_id\t1\ninbox_id\t2\nplatforms\tinstagram\n" \
          "captured_at\t2026-07-29T01:02:03Z\nrow_count\t0\n"
      }
      component_contents.each { |basename, bytes| seal(backup_directory, basename, bytes) }
      backup_values = {
        'schema_version' => '1',
        'backup_id' => '20260729T010203Z-0123456789abcdef',
        'production_database_name' => 'chatwoot_production',
        'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'1' * 64}",
        'account_id' => '1',
        'inbox_id' => '2',
        'facebook_page_id' => '3',
        'instagram_business_id' => '4',
        'database_dump_sha256' => Digest::SHA256.hexdigest(component_contents.fetch('database.dump')),
        'database_restore_list_sha256' =>
          Digest::SHA256.hexdigest(component_contents.fetch('database.restore.list')),
        'storage_archive_sha256' => Digest::SHA256.hexdigest(component_contents.fetch('storage.tar')),
        'storage_manifest_sha256' => Digest::SHA256.hexdigest(component_contents.fetch('storage.manifest')),
        'messenger_history_state_sha256' =>
          Digest::SHA256.hexdigest(component_contents.fetch('fbig-history-backup-messenger-state-v1.tsv')),
        'instagram_history_state_sha256' =>
          Digest::SHA256.hexdigest(component_contents.fetch('fbig-history-backup-instagram-state-v1.tsv')),
        'created_at' => '2026-07-29T01:02:03Z'
      }
      backup_bytes = ordered_bytes(Umi::Fbig::CoordinatedBackupManifest, backup_values)
      backup_path = seal(backup_directory, 'fbig-coordinated-backup-v1.tsv', backup_bytes)

      empty_messenger =
        Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: [])
      empty_instagram =
        Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: [])
      authorization_values = Umi::Fbig::ProductionFirstAuthorization::FIELD_NAMES.index_with do |_field|
        '2' * 64
      end.merge(
        'schema_version' => '1',
        'authorization_mode' => 'production_first',
        'repository_commit' => '3' * 40,
        'image_digest' => backup_values.fetch('image_digest'),
        'production_database' => backup_values.fetch('production_database_name'),
        'account_id' => '1',
        'inbox_id' => '2',
        'facebook_page_id' => '3',
        'instagram_business_id' => '4',
        'since' => 'all',
        'before' => '2026-07-29T00:00:00Z',
        'outbound_policy' => 'pre_presence',
        'profile_mode' => 'defer',
        'messenger_count' => '5',
        'instagram_count' => '7',
        'messenger_unavailable_message_thread_count' => '0',
        'messenger_unavailable_message_thread_fingerprint' => empty_messenger.fingerprint,
        'instagram_unavailable_message_thread_count' => '0',
        'instagram_unavailable_message_thread_fingerprint' => empty_instagram.fingerprint,
        'placeholder_targets_sha256' => Digest::SHA256.hexdigest(target_bytes),
        'coordinated_backup_manifest_sha256' => Digest::SHA256.hexdigest(backup_bytes),
        'history_program_sha256' => '4' * 64,
        'profile_approval_generator_sha256' => Digest::SHA256.file(program).hexdigest,
        'normal_terminal_acceptance_sha256' => 'none',
        'normal_dry_pair_sha256' => 'none',
        'predecessor_authorization_sha256' => 'none',
        'predecessor_history_result_sha256' => 'none',
        'predecessor_terminal_summary_sha256' => 'none',
        'predecessor_delta_sha256' => 'none',
        'predecessor_expanded_baseline_sha256' => 'none',
        'current_state_backup_sha256' => 'none',
        'approved_by' => 'operator@example.com',
        'created_at' => '2026-07-29T02:00:00Z'
      )
      authorization_bytes = ordered_bytes(Umi::Fbig::ProductionFirstAuthorization, authorization_values)
      authorization_path = seal(
        authorization_directory,
        'fbig-production-first-authorization-v1.tsv',
        authorization_bytes
      )
      authorization = Umi::Fbig::ProductionFirstAuthorization.parse(authorization_bytes)
      approval_values = {
        'schema_version' => '1',
        'authorization_mode' => 'production_first',
        'repository_commit' => authorization.repository_commit,
        'image_digest' => authorization.image_digest,
        'production_database' => authorization.production_database,
        'account_id' => authorization.account_id.to_s,
        'inbox_id' => authorization.inbox_id.to_s,
        'facebook_page_id' => authorization.facebook_page_id,
        'instagram_business_id' => authorization.instagram_business_id,
        'since' => authorization.since,
        'before' => authorization.values.fetch('before'),
        'outbound_policy' => authorization.outbound_policy,
        'profile_mode' => authorization.profile_mode,
        'coordinated_backup_manifest_sha256' => authorization.coordinated_backup_manifest_sha256,
        'production_first_authorization_sha256' => authorization.sha256,
        'recovered_thread_targets_sha256' => authorization.recovered_thread_targets_sha256,
        'placeholder_targets_sha256' => authorization.placeholder_targets_sha256,
        'unrecoverable_sidecar_sha256' => authorization.unrecoverable_sidecar_sha256,
        'messenger_count' => authorization.messenger_count,
        'messenger_fingerprint' => authorization.messenger_fingerprint,
        'instagram_count' => authorization.instagram_count,
        'instagram_fingerprint' => authorization.instagram_fingerprint,
        'messenger_unavailable_message_thread_count' => authorization.messenger_unavailable_message_thread_count,
        'messenger_unavailable_message_thread_fingerprint' =>
          authorization.messenger_unavailable_message_thread_fingerprint,
        'instagram_unavailable_message_thread_count' => authorization.instagram_unavailable_message_thread_count,
        'instagram_unavailable_message_thread_fingerprint' =>
          authorization.instagram_unavailable_message_thread_fingerprint,
        'r2_acceptance_binding_sha256' => authorization.r2_acceptance_binding_sha256,
        'r2_launch_manifest_sha256' => authorization.r2_launch_manifest_sha256,
        'r2_probe_log_sha256' => authorization.r2_probe_log_sha256,
        'r2_probe_summary_sha256' => authorization.r2_probe_summary_sha256,
        'revision_platform' => 'none',
        'predecessor_approval_sha256' => 'none',
        'predecessor_attempt_result_sha256' => 'none',
        'predecessor_run_summary_sha256' => 'none',
        'predecessor_delta_sha256' => 'none',
        'approved_by' => 'operator@example.com',
        'approved_at' => '2026-07-29T02:00:00Z'
      }
      approval_bytes = ordered_bytes(Umi::Fbig::ProductionFirstHistoryApproval, approval_values)
      approval_path = seal(
        authorization_directory,
        'fbig-production-first-history-approval-v1.tsv',
        approval_bytes
      )
      approval = Umi::Fbig::ProductionFirstHistoryApproval.parse(approval_bytes)

      result_values = {
        'authorization_mode' => 'production_first',
        'authorization_sha256' => authorization.sha256,
        'program_sha256' => authorization.history_program_sha256,
        'candidate_commit' => authorization.repository_commit,
        'candidate_image' => authorization.image_digest,
        'production_database' => authorization.production_database,
        'inbox_id' => authorization.inbox_id.to_s,
        'history_approval_sha256' => approval.sha256,
        'acceptance_sha256' => 'none',
        'pre_history_backup_sha256' => approval.coordinated_backup_manifest_sha256,
        'dry_pair_sha256' => 'none',
        'operation' => 'apply',
        'require_zero_writes' => 'true',
        'zero_write_observed' => 'true',
        'exit_status' => '0',
        'termination' => 'normal',
        'protected_changes' => '0',
        'deleted_rows' => '0',
        'unattributed_changes' => '0',
        'counter_mismatches' => 'none'
      }
      messenger_bytes = result_values.merge(
        'platforms' => 'messenger',
        'predecessor_result_sha256' => 'none'
      ).map { |field, value| "#{field}\t#{value}\n" }.join
      messenger_path = seal(
        messenger_directory,
        'fbig-history-attempt-result-v1.tsv',
        messenger_bytes
      )
      messenger_sha = Digest::SHA256.hexdigest(messenger_bytes)
      messenger_summary = <<~LOG
        [UMI-FBIG] stage=history_import_summary platforms=messenger dry_run=false scan_complete=true write_complete=true failed_threads=0 partially_paginated_threads=0
      LOG
      seal(messenger_directory, 'history-summary.tsv', messenger_summary)
      instagram_bytes = result_values.merge(
        'platforms' => 'instagram',
        'predecessor_result_sha256' => messenger_sha
      ).map { |field, value| "#{field}\t#{value}\n" }.join
      instagram_path = seal(
        instagram_directory,
        'fbig-history-attempt-result-v1.tsv',
        instagram_bytes
      )
      instagram_sha = Digest::SHA256.hexdigest(instagram_bytes)
      index_bytes = [
        ['1', messenger_path, messenger_sha, authorization_path, authorization.sha256, approval_path, approval.sha256],
        ['2', instagram_path, instagram_sha, authorization_path, authorization.sha256, approval_path, approval.sha256]
      ].map { |row| "#{row.join("\t")}\n" }.join
      index_path = seal(
        source_directory,
        'fbig-production-first-history-result-index-v1.tsv',
        index_bytes
      )

      channel = instance_double(Channel::FacebookPage, page_id: '3', instagram_id: '4')
      inbox = instance_double(Inbox, account_id: 1, id: 2, channel: channel)
      allow(Inbox).to receive(:find).with(2).and_return(inbox)
      stable = {
        'messenger' => { count: 11, fingerprint: '5' * 64 },
        'instagram' => { count: 12, fingerprint: '6' * 64 }
      }
      allow(Umi::Fbig::HistoryProfileBackfillService).to receive(:stable_target_summary).and_return(stable)
      env = {
        'UMI_FBIG_EXPECTED_UID' => Process.uid.to_s,
        'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH' => authorization_path,
        'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_CHECKSUM_PATH' => "#{authorization_path}.sha256",
        'UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_PATH' => approval_path,
        'UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{approval_path}.sha256",
        'UMI_FBIG_HISTORY_RESULT_INDEX_PATH' => index_path,
        'UMI_FBIG_HISTORY_RESULT_INDEX_CHECKSUM_PATH' => "#{index_path}.sha256",
        'UMI_FBIG_MESSENGER_TERMINAL_HISTORY_RESULT_PATH' => messenger_path,
        'UMI_FBIG_INSTAGRAM_TERMINAL_HISTORY_RESULT_PATH' => instagram_path,
        'UMI_FBIG_PROFILE_STATE_PATH' => source_state_path,
        'UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH' => "#{source_state_path}.sha256",
        'UMI_FBIG_PROFILE_TARGETS_PATH' => target_path,
        'UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_PATH' => backup_path,
        'UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_CHECKSUM_PATH' => "#{backup_path}.sha256",
        'UMI_FBIG_APPROVED_BY' => 'operator@example.com',
        'UMI_FBIG_APPROVED_AT' => '2026-07-29T03:00:00Z',
        'UMI_FBIG_PROFILE_GRAPH_DELAY_MS' => '250',
        'UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES' => '10000',
        'UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS' => '300',
        'UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES' => '1000000',
        'UMI_FBIG_PRODUCTION_FIRST_PROFILE_OUTPUT_DIR' => output_directory
      }

      database_dump = File.join(backup_directory, 'database.dump')
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
      with_modified_env(env) { load program }

      profile = Umi::Fbig::ProductionFirstProfileApproval.load(
        manifest_path: File.join(output_directory, 'fbig-production-first-profile-approval-v1.tsv'),
        checksum_path: File.join(output_directory, 'fbig-production-first-profile-approval-v1.tsv.sha256'),
        expected_uid: Process.uid
      )
      expect(profile.messenger_terminal_history_result_sha256).to eq(messenger_sha)
      expect(profile.instagram_terminal_history_result_sha256).to eq(instagram_sha)
      component_contents.each do |basename, bytes|
        expect(File.binread(File.join(output_directory, basename))).to eq(bytes)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
