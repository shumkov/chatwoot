require 'digest'
require 'fileutils'
require 'open3'
require 'rails_helper'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe 'UMI FB/IG production-first history revision generator' do
  let(:repository_root) { File.expand_path('../../..', __dir__) }
  let(:program) do
    File.join(repository_root, 'script/umi_fbig/support/fbig_production_first_history_revise.rb')
  end

  def seal(directory, basename, bytes)
    path = File.join(directory, basename)
    File.binwrite(path, bytes)
    File.chmod(0o400, path)
    checksum = "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n"
    File.binwrite("#{path}.sha256", checksum)
    File.chmod(0o400, "#{path}.sha256")
    path
  end

  def ordered_bytes(klass, values)
    klass::FIELD_NAMES.map { |field| "#{field}\t#{values.fetch(field)}\n" }.join
  end

  def reseal(path, bytes)
    [path, "#{path}.sha256"].each { |artifact| File.chmod(0o600, artifact) }
    File.binwrite(path, bytes)
    File.binwrite("#{path}.sha256", "#{Digest::SHA256.hexdigest(bytes)}  #{File.basename(path)}\n")
    [path, "#{path}.sha256"].each { |artifact| File.chmod(0o400, artifact) }
  end

  it 'revises from a production-shaped summary without a synthetic platforms field' do
    Dir.mktmpdir do |root|
      authorization_directory = File.join(root, 'authorization')
      approval_directory = File.join(root, 'approval')
      attempt_directory = File.join(root, 'attempt')
      output_directory = File.join(root, 'output')
      [authorization_directory, approval_directory, attempt_directory, output_directory].each do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end

      authorization_values = Umi::Fbig::ProductionFirstAuthorization::FIELD_NAMES.index_with { 'a' * 64 }.merge(
        'schema_version' => '1',
        'authorization_mode' => 'production_first',
        'repository_commit' => 'b' * 40,
        'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'c' * 64}",
        'production_database' => 'chatwoot_production',
        'account_id' => '1',
        'inbox_id' => '2',
        'facebook_page_id' => '3',
        'instagram_business_id' => '4',
        'since' => 'all',
        'before' => '2026-07-28T15:39:00Z',
        'outbound_policy' => 'pre_presence',
        'profile_mode' => 'defer',
        'messenger_count' => '5',
        'instagram_count' => '7',
        'messenger_unavailable_message_thread_count' => '0',
        'messenger_unavailable_message_thread_fingerprint' =>
          Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: []).fingerprint,
        'instagram_unavailable_message_thread_count' => '0',
        'instagram_unavailable_message_thread_fingerprint' =>
          Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: []).fingerprint,
        'history_revision_generator_sha256' => Digest::SHA256.file(program).hexdigest,
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
      package_sources = {
        'fbig-recovered-thread-targets-v1.tsv' => "targets\n",
        'fbig-unrecoverable-envelope-v1.tsv' => "sidecar\n",
        'fbig-unrecoverable-envelope-inspector.rb' => "puts 'inspect'\n"
      }
      package_sources.each { |basename, bytes| seal(authorization_directory, basename, bytes) }
      authorization_values['recovered_thread_targets_sha256'] =
        Digest::SHA256.hexdigest(package_sources.fetch('fbig-recovered-thread-targets-v1.tsv'))
      authorization_values['unrecoverable_sidecar_sha256'] =
        Digest::SHA256.hexdigest(package_sources.fetch('fbig-unrecoverable-envelope-v1.tsv'))
      authorization_values['unrecoverable_inspector_sha256'] =
        Digest::SHA256.hexdigest(package_sources.fetch('fbig-unrecoverable-envelope-inspector.rb'))
      authorization_path = seal(
        authorization_directory,
        'fbig-production-first-authorization-v1.tsv',
        ordered_bytes(Umi::Fbig::ProductionFirstAuthorization, authorization_values)
      )
      authorization = Umi::Fbig::ProductionFirstAuthorization.parse(File.binread(authorization_path))

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
        'approved_at' => '2026-07-29T00:00:00Z'
      }
      approval_path = seal(
        approval_directory,
        'fbig-production-first-history-approval-v1.tsv',
        ordered_bytes(Umi::Fbig::ProductionFirstHistoryApproval, approval_values)
      )
      approval = Umi::Fbig::ProductionFirstHistoryApproval.parse(File.binread(approval_path))

      summary_fields = {
        'dry_run' => 'false',
        'scan_complete' => 'true',
        'write_complete' => 'false',
        'contentless_acceptance_mismatches' => '1',
        'exit_failures' => '1',
        'failed_threads' => '0',
        'partially_paginated_threads' => '0',
        'uncategorized_threads' => '0',
        'unavailable_message_threads' => '0',
        'unavailable_message_thread_acceptance_mismatches' => '0',
        'platform_failures' => '0',
        'retry_exhaustion' => '0',
        'rate_limits' => '0',
        'authentication_failures' => '0',
        'lock_loss' => '0',
        'foreign_source_id_anomalies' => '0',
        'reindex_failures' => '0',
        'download_budget_exhaustions' => '0',
        'recovered_target_mismatches' => '0',
        'recovered_target_duplicate_listings' => '0',
        'in_scope_mids_scanned' => '30',
        'already_present' => '5',
        'candidate_incoming' => '15',
        'candidate_outbound' => '10',
        'outbound_pre_presence_import' => '8',
        'outbound_pre_presence_skip' => '2',
        'imported_contacts' => '2',
        'imported_archives' => '3',
        'imported_messages' => '14',
        'imported_incoming' => '10',
        'imported_outgoing' => '4',
        'imported_attachments' => '0',
        'marker_normalizations' => '0',
        'history_evidence_changes_applied' => '0',
        'late_already_present' => '1',
        'content_unavailable' => '8',
        'ambiguous_senders' => '0',
        'ambiguous_participants' => '1',
        'predecessor_archive_not_returned' => '0',
        'recovered_thread_targets_sha256' => approval.recovered_thread_targets_sha256,
        'recovered_targets_expected' => '2',
        'recovered_targets_listed' => '2',
        'recovered_targets_message_cursor_exhausted' => '2',
        'structural_unrecoverable_threads' => '1',
        'classified_omitted_threads' => '1',
        'listed_threads' => '3',
        'message_cursor_exhausted_threads' => '2',
        'instagram_listed_threads' => '3',
        'instagram_message_cursor_exhausted_threads' => '2',
        'instagram_structural_unrecoverable_threads' => '1',
        'instagram_unavailable_message_threads' => '0',
        'instagram_classified_omitted_threads' => '1',
        'instagram_failed_threads' => '0',
        'instagram_partially_paginated_threads' => '0',
        'instagram_uncategorized_threads' => '0',
        'instagram_contentless_details' => '8',
        'instagram_contentless_fingerprint' => 'd' * 64
      }
      invalid_summary_fields = summary_fields.merge('in_scope_mids_scanned' => '31')
      summary_bytes = "[UMI-FBIG] stage=history_import_summary #{
        invalid_summary_fields.map { |key, value| "#{key}=#{value}" }.join(' ')
      }\n"
      summary_path = seal(attempt_directory, 'history-summary.tsv', summary_bytes)
      delta_fields = {
        'active_storage_attachments_created' => '0',
        'active_storage_blobs_created' => '0',
        'archive_activity_changed' => '0',
        'archive_configuration_changed' => '0',
        'archives_created' => '3',
        'attachments_created' => '0',
        'contact_activity_changed' => '0',
        'contact_inboxes_created' => '2',
        'contact_inboxes_reused' => '1',
        'contact_profile_changed' => '0',
        'contacts_created' => '2',
        'contacts_reused' => '1',
        'incoming_created' => '10',
        'messages_created' => '14',
        'outgoing_created' => '4'
      }
      delta_bytes = "[UMI-FBIG] stage=history_state_delta platform=instagram #{
        delta_fields.map { |key, value| "#{key}=#{value}" }.join(' ')
      }\n"
      delta_path = seal(attempt_directory, 'history-delta.tsv', delta_bytes)
      result_values = {
        'authorization_mode' => 'production_first',
        'authorization_sha256' => authorization.sha256,
        'history_approval_sha256' => approval.sha256,
        'platforms' => 'instagram',
        'operation' => 'apply',
        'run_summary_sha256' => Digest::SHA256.hexdigest(summary_bytes),
        'delta_sha256' => Digest::SHA256.hexdigest(delta_bytes),
        'exit_status' => '1',
        'termination' => 'normal',
        'protected_changes' => '0',
        'deleted_rows' => '0',
        'unattributed_changes' => '0',
        'counter_mismatches' => 'none'
      }.merge(delta_fields.transform_keys { |key| "instagram_#{key}" })
      result_bytes = result_values.map { |key, value| "#{key}\t#{value}\n" }.join
      result_path = seal(attempt_directory, 'fbig-history-attempt-result-v1.tsv', result_bytes)
      env = {
        'UMI_FBIG_EXPECTED_UID' => Process.uid.to_s,
        'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH' => authorization_path,
        'UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_CHECKSUM_PATH' => "#{authorization_path}.sha256",
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH' => approval_path,
        'UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH' => "#{approval_path}.sha256",
        'UMI_FBIG_FAILED_HISTORY_RESULT_PATH' => result_path,
        'UMI_FBIG_FAILED_HISTORY_SUMMARY_PATH' => summary_path,
        'UMI_FBIG_FAILED_HISTORY_DELTA_PATH' => delta_path,
        'UMI_FBIG_APPROVED_BY' => 'operator@example.com',
        'UMI_FBIG_APPROVED_AT' => '2026-07-29T01:00:00Z',
        'UMI_FBIG_PRODUCTION_FIRST_REVISION_OUTPUT_DIR' => output_directory
      }

      _invalid_stdout, _invalid_stderr, invalid_status = Open3.capture3(
        env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(invalid_status).not_to be_success

      summary_bytes = "[UMI-FBIG] stage=history_import_summary #{
        summary_fields.map { |key, value| "#{key}=#{value}" }.join(' ')
      }\n"
      reseal(summary_path, summary_bytes)
      result_values = {
        'authorization_mode' => 'production_first',
        'authorization_sha256' => authorization.sha256,
        'history_approval_sha256' => approval.sha256,
        'platforms' => 'instagram',
        'operation' => 'apply',
        'run_summary_sha256' => Digest::SHA256.hexdigest(summary_bytes),
        'delta_sha256' => Digest::SHA256.hexdigest(delta_bytes),
        'exit_status' => '1',
        'termination' => 'normal',
        'protected_changes' => '0',
        'deleted_rows' => '0',
        'unattributed_changes' => '0',
        'counter_mismatches' => 'none'
      }.merge(delta_fields.transform_keys { |key| "instagram_#{key}" })
      result_bytes = result_values.map { |key, value| "#{key}\t#{value}\n" }.join
      reseal(result_path, result_bytes)

      prefixed_delta_bytes = delta_bytes.sub('[UMI-FBIG]', 'prefix [UMI-FBIG]')
      reseal(delta_path, prefixed_delta_bytes)
      prefixed_result_values = result_values.merge('delta_sha256' => Digest::SHA256.hexdigest(prefixed_delta_bytes))
      reseal(result_path, prefixed_result_values.map { |key, value| "#{key}\t#{value}\n" }.join)
      _stdout, _stderr, prefixed_status = Open3.capture3(
        env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(prefixed_status).not_to be_success

      crlf_delta_bytes = delta_bytes.sub("\n", "\r\n")
      reseal(delta_path, crlf_delta_bytes)
      crlf_result_values = result_values.merge('delta_sha256' => Digest::SHA256.hexdigest(crlf_delta_bytes))
      reseal(result_path, crlf_result_values.map { |key, value| "#{key}\t#{value}\n" }.join)
      _stdout, _stderr, crlf_status = Open3.capture3(
        env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(crlf_status).not_to be_success

      mismatched_delta_fields = delta_fields.merge('messages_created' => '15')
      mismatched_delta_bytes = "[UMI-FBIG] stage=history_state_delta platform=instagram #{
        mismatched_delta_fields.map { |key, value| "#{key}=#{value}" }.join(' ')
      }\n"
      reseal(delta_path, mismatched_delta_bytes)
      counter_unbound_result_values = result_values.merge(
        'delta_sha256' => Digest::SHA256.hexdigest(mismatched_delta_bytes)
      )
      reseal(result_path, counter_unbound_result_values.map { |key, value| "#{key}\t#{value}\n" }.join)
      _stdout, _stderr, counter_binding_status = Open3.capture3(
        env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(counter_binding_status).not_to be_success

      mismatched_result_values = result_values
                                 .merge('delta_sha256' => Digest::SHA256.hexdigest(mismatched_delta_bytes))
                                 .merge('instagram_messages_created' => '15')
      reseal(result_path, mismatched_result_values.map { |key, value| "#{key}\t#{value}\n" }.join)
      _stdout, _stderr, mismatched_status = Open3.capture3(
        env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root
      )
      expect(mismatched_status).not_to be_success

      reseal(delta_path, delta_bytes)
      reseal(result_path, result_bytes)
      _stdout, stderr, status = Open3.capture3(env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root)

      expect(status).to be_success, stderr
      revised = Umi::Fbig::ProductionFirstHistoryApproval.parse(
        File.binread(File.join(output_directory, 'fbig-production-first-history-approval-v1.tsv'))
      )
      expect(revised.revision_platform).to eq('instagram')
      expect(revised.instagram_count).to eq('8')
      expect(revised.instagram_fingerprint).to eq('d' * 64)
      expect(revised.messenger_count).to eq(approval.messenger_count)
      expect(revised.predecessor_attempt_result_sha256).to eq(Digest::SHA256.hexdigest(result_bytes))
      expect(File.binread(File.join(output_directory, 'fbig-production-first-authorization-v1.tsv')))
        .to eq(File.binread(authorization_path))
      package_sources.each do |basename, source_bytes|
        expect(File.binread(File.join(output_directory, basename))).to eq(source_bytes)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
