# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
OUTPUT_BASENAME = 'fbig-production-first-request-v1.tsv'
PROGRAM_FIELDS = {
  'history_program_sha256' => 'UMI_FBIG_HISTORY_PROGRAM_PATH',
  'profile_program_sha256' => 'UMI_FBIG_PROFILE_PROGRAM_PATH',
  'final_audit_program_sha256' => 'UMI_FBIG_FINAL_AUDIT_PROGRAM_PATH',
  'delivery_audit_program_sha256' => 'UMI_FBIG_DELIVERY_AUDIT_PROGRAM_PATH',
  'delivery_checkpoint_program_sha256' => 'UMI_FBIG_DELIVERY_CHECKPOINT_PROGRAM_PATH',
  'profile_wrapper_sha256' => 'UMI_FBIG_PROFILE_WRAPPER_PATH',
  'storage_helper_sha256' => 'UMI_FBIG_STORAGE_HELPER_PATH',
  'recovered_target_generator_sha256' => 'UMI_FBIG_RECOVERED_TARGET_GENERATOR_PATH',
  'authorization_generator_sha256' => 'UMI_FBIG_AUTHORIZATION_GENERATOR_PATH',
  'history_revision_generator_sha256' => 'UMI_FBIG_HISTORY_REVISION_GENERATOR_PATH',
  'profile_approval_generator_sha256' => 'UMI_FBIG_PROFILE_APPROVAL_GENERATOR_PATH'
}.freeze
SIDECAR_FIELDS = %w[
  schema_version repository_commit image_digest account_id inbox_id
  instagram_business_id before platform count fingerprint
  inspector_script_sha256 approved_by approved_at
].freeze
STABLE_SIDECAR_FIELDS = %w[
  schema_version account_id inbox_id instagram_business_id before platform count fingerprint
].freeze
SUCCESSOR_INVARIANT_FIELDS = %w[
  production_database account_id inbox_id facebook_page_id instagram_business_id since before
  outbound_policy profile_mode recovered_thread_targets_sha256 placeholder_targets_sha256
  messenger_unavailable_message_thread_count messenger_unavailable_message_thread_fingerprint
  instagram_unavailable_message_thread_count instagram_unavailable_message_thread_fingerprint
  r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
].freeze
SUCCESSOR_REVISION_ZERO_FIELDS = %w[
  failed_threads partially_paginated_threads uncategorized_threads unavailable_message_threads
  unavailable_message_thread_acceptance_mismatches platform_failures retry_exhaustion rate_limits
  authentication_failures lock_loss foreign_source_id_anomalies reindex_failures
  download_budget_exhaustions recovered_target_mismatches recovered_target_duplicate_listings
  ambiguous_senders predecessor_archive_not_returned
].freeze

def invalid!
  raise 'production-first request inputs are invalid'
end

def locked_bytes(path, expected_uid)
  candidate = Pathname.new(path.to_s)
  invalid! unless candidate.absolute? && candidate.cleanpath.to_s == path.to_s
  directory = File.lstat(candidate.dirname)
  invalid! unless
    directory.directory? && !directory.symlink? && directory.uid == expected_uid &&
    (directory.mode & 0o777) == 0o700
  bytes = nil
  opened = nil
  File.open(candidate, 'rb') do |file|
    opened = file.stat
    invalid! unless
      opened.file? && opened.uid == expected_uid && opened.nlink == 1 &&
      (opened.mode & 0o777) == 0o400
    bytes = file.read
  end
  current = File.lstat(candidate)
  invalid! if current.symlink? || current.dev != opened.dev || current.ino != opened.ino
  bytes
rescue SystemCallError
  invalid!
end

def manifest_values(bytes)
  pairs = bytes.to_s.lines(chomp: true).map { |line| line.split("\t", -1) }
  invalid! unless pairs.all? { |pair| pair.size == 2 } && pairs.map(&:first).uniq.size == pairs.size
  pairs.to_h
end

def verified_bytes(path, expected_uid)
  bytes = locked_bytes(path, expected_uid)
  checksum = locked_bytes("#{path}.sha256", expected_uid)
  invalid! unless checksum == "#{Digest::SHA256.hexdigest(bytes)}  #{Pathname.new(path).basename}\n"

  bytes
end

def stage_values(bytes, stage)
  marker = "[UMI-FBIG] stage=#{stage} "
  rows = bytes.to_s.lines.filter_map do |line|
    offset = line.index(marker)
    next unless offset

    pairs = line.byteslice(offset + marker.bytesize..).to_s.strip.split.map { |field| field.split('=', 2) }
    invalid! unless pairs.all? { |pair| pair.size == 2 } && pairs.map(&:first).uniq.size == pairs.size
    pairs.to_h
  end
  invalid! unless rows.one?
  rows.first
end

def revision_approval_matches_result?(approval, result_approval, evidence)
  result = evidence.fetch(:result)
  result_bytes = evidence.fetch(:result_bytes)
  summary_bytes = evidence.fetch(:summary_bytes)
  delta_bytes = evidence.fetch(:delta_bytes)
  platform = result.fetch('platforms')
  summary = stage_values(summary_bytes, 'history_import_summary')
  mutable_fields = %W[
    #{platform}_count #{platform}_fingerprint revision_platform predecessor_approval_sha256
    predecessor_attempt_result_sha256 predecessor_run_summary_sha256 predecessor_delta_sha256
    approved_by approved_at
  ]
  invariants_match = Umi::Fbig::ProductionFirstHistoryApproval::FIELD_NAMES.all? do |field|
    mutable_fields.include?(field) || approval.values.fetch(field) == result_approval.values.fetch(field)
  end
  approval.revision_platform == platform &&
    result.fetch('exit_status') == '1' &&
    result_approval.sha256 == result.fetch('history_approval_sha256') &&
    approval.predecessor_approval_sha256 == result_approval.sha256 &&
    approval.predecessor_attempt_result_sha256 == Digest::SHA256.hexdigest(result_bytes) &&
    approval.predecessor_run_summary_sha256 == Digest::SHA256.hexdigest(summary_bytes) &&
    approval.predecessor_delta_sha256 == Digest::SHA256.hexdigest(delta_bytes) &&
    approval.values.fetch("#{platform}_count") == summary.fetch("#{platform}_contentless_details") &&
    approval.values.fetch("#{platform}_fingerprint") == summary.fetch("#{platform}_contentless_fingerprint") &&
    summary.fetch('dry_run') == 'false' &&
    summary.fetch('scan_complete') == 'true' &&
    summary.fetch('write_complete') == 'false' &&
    summary.fetch('contentless_acceptance_mismatches') == '1' &&
    summary.fetch('exit_failures') == '1' &&
    SUCCESSOR_REVISION_ZERO_FIELDS.all? { |field| summary.fetch(field) == '0' } &&
    invariants_match
rescue KeyError
  false
end

def approval_matches_result?(approval, result_approval, evidence)
  result = evidence.fetch(:result)
  result_approval.sha256 == result.fetch('history_approval_sha256') &&
    (
      approval.sha256 == result_approval.sha256 ||
      revision_approval_matches_result?(approval, result_approval, evidence)
    )
end

def publish!(directory, bytes)
  path = directory.join(OUTPUT_BASENAME)
  checksum = directory.join("#{OUTPUT_BASENAME}.sha256")
  invalid! if path.exist? || path.symlink? || checksum.exist? || checksum.symlink?
  [[path, bytes], [checksum, "#{Digest::SHA256.hexdigest(bytes)}  #{OUTPUT_BASENAME}\n"]].each do |destination, content|
    temporary = directory.join(".#{destination.basename}.#{Process.pid}.tmp")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.binmode
      file.write(content)
      file.flush
      file.fsync
    end
    File.chmod(0o400, temporary)
    File.link(temporary, destination)
    File.unlink(temporary)
  end
  File.open(directory, File::RDONLY, &:fsync)
end

begin
  expected_uid = Integer(ENV.fetch('UMI_FBIG_EXPECTED_UID', '0'), 10)
  request_mode = ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_REQUEST_MODE')
  invalid! unless request_mode.in?(%w[initial successor])
  backup = Umi::Fbig::CoordinatedBackupManifest.load(
    manifest_path: ENV.fetch('UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_COORDINATED_BACKUP_MANIFEST_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  targets_bytes = locked_bytes(ENV.fetch('UMI_FBIG_RECOVERED_THREAD_TARGETS_PATH'), expected_uid)
  targets = Umi::Fbig::RecoveredThreadTargets.parse(targets_bytes)
  placeholder_bytes = locked_bytes(ENV.fetch('UMI_FBIG_PLACEHOLDER_TARGETS_PATH'), expected_uid)
  Umi::Fbig::ProfileTargetManifest.parse(placeholder_bytes)
  inspector_bytes = locked_bytes(ENV.fetch('UMI_FBIG_UNRECOVERABLE_INSPECTOR_PATH'), expected_uid)
  source_sidecar = manifest_values(
    locked_bytes(ENV.fetch('UMI_FBIG_UNRECOVERABLE_SIDECAR_PATH'), expected_uid)
  )
  probe_summary_bytes = locked_bytes(ENV.fetch('UMI_FBIG_R2_PROBE_SUMMARY_PATH'), expected_uid)
  probe_summary = stage_values(probe_summary_bytes, 'history_import_summary')
  approved_by = ENV.fetch('UMI_FBIG_APPROVED_BY')
  approved_at = ENV.fetch('UMI_FBIG_APPROVED_AT')
  repository_commit = ENV.fetch('UMI_FBIG_REPOSITORY_COMMIT')
  image_digest = ENV.fetch('UMI_FBIG_IMAGE_DIGEST')
  before = ENV.fetch('UMI_FBIG_BEFORE')
  corrected_sidecar = source_sidecar.merge(
    'repository_commit' => repository_commit,
    'image_digest' => image_digest,
    'inspector_script_sha256' => Digest::SHA256.hexdigest(inspector_bytes),
    'approved_by' => approved_by,
    'approved_at' => approved_at
  )
  sidecar_bytes = SIDECAR_FIELDS.map { |field| "#{field}\t#{corrected_sidecar.fetch(field)}\n" }.join
  values = {
    'schema_version' => '1',
    'authorization_mode' => 'production_first',
    'repository_commit' => repository_commit,
    'image_digest' => image_digest,
    'production_database' => ENV.fetch('UMI_FBIG_PRODUCTION_DATABASE'),
    'account_id' => ENV.fetch('UMI_FBIG_ACCOUNT_ID'),
    'inbox_id' => ENV.fetch('UMI_FBIG_INBOX_ID'),
    'facebook_page_id' => ENV.fetch('UMI_FBIG_FACEBOOK_PAGE_ID'),
    'instagram_business_id' => ENV.fetch('UMI_FBIG_INSTAGRAM_BUSINESS_ID'),
    'since' => 'all',
    'before' => before,
    'outbound_policy' => 'pre_presence',
    'profile_mode' => 'defer',
    'r2_acceptance_binding_sha256' =>
      Digest::SHA256.hexdigest(locked_bytes(ENV.fetch('UMI_FBIG_R2_ACCEPTANCE_BINDING_PATH'), expected_uid)),
    'r2_launch_manifest_sha256' =>
      Digest::SHA256.hexdigest(locked_bytes(ENV.fetch('UMI_FBIG_R2_LAUNCH_MANIFEST_PATH'), expected_uid)),
    'r2_probe_log_sha256' =>
      Digest::SHA256.hexdigest(locked_bytes(ENV.fetch('UMI_FBIG_R2_PROBE_LOG_PATH'), expected_uid)),
    'r2_probe_summary_sha256' => Digest::SHA256.hexdigest(probe_summary_bytes),
    'messenger_count' => probe_summary.fetch('messenger_contentless_details'),
    'messenger_fingerprint' => probe_summary.fetch('messenger_contentless_fingerprint'),
    'instagram_count' => probe_summary.fetch('instagram_contentless_details'),
    'instagram_fingerprint' => probe_summary.fetch('instagram_contentless_fingerprint'),
    'messenger_unavailable_message_thread_count' => '0',
    'messenger_unavailable_message_thread_fingerprint' =>
      Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: []).fingerprint,
    'instagram_unavailable_message_thread_count' => '0',
    'instagram_unavailable_message_thread_fingerprint' =>
      Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: []).fingerprint,
    'recovered_thread_targets_sha256' => Digest::SHA256.hexdigest(targets_bytes),
    'placeholder_targets_sha256' => Digest::SHA256.hexdigest(placeholder_bytes),
    'unrecoverable_sidecar_sha256' => Digest::SHA256.hexdigest(sidecar_bytes),
    'unrecoverable_inspector_sha256' => Digest::SHA256.hexdigest(inspector_bytes),
    'coordinated_backup_manifest_sha256' => backup.sha256,
    'normal_terminal_acceptance_sha256' => 'none',
    'normal_dry_pair_sha256' => 'none',
    'predecessor_authorization_sha256' => 'none',
    'predecessor_history_result_sha256' => 'none',
    'predecessor_terminal_summary_sha256' => 'none',
    'predecessor_delta_sha256' => 'none',
    'predecessor_expanded_baseline_sha256' => 'none',
    'current_state_backup_sha256' => 'none',
    'approved_by' => approved_by,
    'created_at' => approved_at
  }
  invalid! unless
    source_sidecar.keys == SIDECAR_FIELDS &&
    targets.values.fetch('source_acceptance_binding_sha256') == values.fetch('r2_acceptance_binding_sha256') &&
    targets.values.fetch('source_launch_manifest_sha256') == values.fetch('r2_launch_manifest_sha256') &&
    targets.values.fetch('source_probe_log_sha256') == values.fetch('r2_probe_log_sha256') &&
    targets.values.fetch('source_probe_summary_sha256') == values.fetch('r2_probe_summary_sha256') &&
    source_sidecar.fetch('repository_commit') == targets.values.fetch('source_repository_commit') &&
    source_sidecar.fetch('image_digest') == targets.values.fetch('source_image_digest') &&
    source_sidecar.fetch('schema_version') == '1' &&
    source_sidecar.fetch('account_id') == values.fetch('account_id') &&
    source_sidecar.fetch('inbox_id') == values.fetch('inbox_id') &&
    source_sidecar.fetch('instagram_business_id') == values.fetch('instagram_business_id') &&
    source_sidecar.fetch('before') == before &&
    source_sidecar.fetch('platform') == 'instagram' &&
    source_sidecar.fetch('count') == '1' &&
    source_sidecar.fetch('fingerprint').match?(/\A[0-9a-f]{64}\z/) &&
    source_sidecar.fetch('inspector_script_sha256') == Digest::SHA256.hexdigest(inspector_bytes) &&
    backup.production_database_name == values.fetch('production_database') &&
    backup.image_digest == image_digest &&
    backup.account_id.to_s == values.fetch('account_id') &&
    backup.inbox_id.to_s == values.fetch('inbox_id') &&
    backup.facebook_page_id.to_s == values.fetch('facebook_page_id') &&
    backup.instagram_business_id.to_s == values.fetch('instagram_business_id')
  if request_mode == 'successor'
    predecessor_authorization = Umi::Fbig::ProductionFirstAuthorization.load(
      manifest_path: ENV.fetch('UMI_FBIG_PREDECESSOR_AUTHORIZATION_PATH'),
      checksum_path: ENV.fetch('UMI_FBIG_PREDECESSOR_AUTHORIZATION_CHECKSUM_PATH'),
      expected_uid: expected_uid
    )
    predecessor_approval = Umi::Fbig::ProductionFirstHistoryApproval.load(
      manifest_path: ENV.fetch('UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH'),
      checksum_path: ENV.fetch('UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH'),
      expected_uid: expected_uid
    )
    predecessor_result_approval = Umi::Fbig::ProductionFirstHistoryApproval.load(
      manifest_path: ENV.fetch('UMI_FBIG_PREDECESSOR_RESULT_APPROVAL_PATH'),
      checksum_path: ENV.fetch('UMI_FBIG_PREDECESSOR_RESULT_APPROVAL_CHECKSUM_PATH'),
      expected_uid: expected_uid
    )
    predecessor_result_bytes = verified_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_HISTORY_RESULT_PATH'),
      expected_uid
    )
    predecessor_summary_bytes = verified_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_TERMINAL_SUMMARY_PATH'),
      expected_uid
    )
    predecessor_delta_bytes = verified_bytes(ENV.fetch('UMI_FBIG_PREDECESSOR_DELTA_PATH'), expected_uid)
    predecessor_baseline_bytes = verified_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_EXPANDED_BASELINE_PATH'),
      expected_uid
    )
    predecessor_sidecar_bytes = verified_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_UNRECOVERABLE_SIDECAR_PATH'),
      expected_uid
    )
    predecessor_result = manifest_values(predecessor_result_bytes)
    predecessor_evidence = {
      result: predecessor_result,
      result_bytes: predecessor_result_bytes,
      summary_bytes: predecessor_summary_bytes,
      delta_bytes: predecessor_delta_bytes
    }
    predecessor_sidecar = manifest_values(predecessor_sidecar_bytes)
    stable_sidecar = STABLE_SIDECAR_FIELDS.all? do |field|
      predecessor_sidecar.fetch(field) == source_sidecar.fetch(field)
    end
    invalid! unless
      predecessor_approval.production_first_authorization_sha256 == predecessor_authorization.sha256 &&
      predecessor_result.fetch('authorization_mode') == 'production_first' &&
      predecessor_result.fetch('authorization_sha256') == predecessor_authorization.sha256 &&
      approval_matches_result?(
        predecessor_approval,
        predecessor_result_approval,
        predecessor_evidence
      ) &&
      predecessor_result.fetch('candidate_commit') == predecessor_authorization.repository_commit &&
      predecessor_result.fetch('candidate_image') == predecessor_authorization.image_digest &&
      predecessor_result.fetch('operation') == 'apply' &&
      predecessor_result.fetch('run_summary_sha256') == Digest::SHA256.hexdigest(predecessor_summary_bytes) &&
      predecessor_result.fetch('delta_sha256') == Digest::SHA256.hexdigest(predecessor_delta_bytes) &&
      predecessor_result.fetch('poststate_sha256') == Digest::SHA256.hexdigest(predecessor_baseline_bytes) &&
      predecessor_result.fetch('termination') == 'normal' &&
      predecessor_result.fetch('exit_status').in?(%w[0 1]) &&
      predecessor_result.fetch('protected_changes') == '0' &&
      predecessor_result.fetch('deleted_rows') == '0' &&
      predecessor_result.fetch('unattributed_changes') == '0' &&
      predecessor_result.fetch('counter_mismatches') == 'none' &&
      predecessor_result_approval.production_first_authorization_sha256 == predecessor_authorization.sha256 &&
      Digest::SHA256.hexdigest(predecessor_sidecar_bytes) == predecessor_approval.unrecoverable_sidecar_sha256 &&
      predecessor_sidecar.fetch('repository_commit') == predecessor_authorization.repository_commit &&
      predecessor_sidecar.fetch('image_digest') == predecessor_authorization.image_digest &&
      predecessor_sidecar.fetch('inspector_script_sha256') ==
      predecessor_authorization.unrecoverable_inspector_sha256 &&
      stable_sidecar
    invariant_fields_match = SUCCESSOR_INVARIANT_FIELDS.all? do |field|
      predecessor_approval.values.fetch(field) == values.fetch(field)
    end
    invalid! unless invariant_fields_match
    invalid! if
      predecessor_authorization.repository_commit == repository_commit &&
      predecessor_authorization.image_digest == image_digest
    %w[messenger instagram].each do |platform|
      values["#{platform}_count"] = predecessor_approval.values.fetch("#{platform}_count")
      values["#{platform}_fingerprint"] = predecessor_approval.values.fetch("#{platform}_fingerprint")
    end
    values['predecessor_authorization_sha256'] = predecessor_authorization.sha256
    values['predecessor_history_result_sha256'] = Digest::SHA256.hexdigest(predecessor_result_bytes)
    values['predecessor_terminal_summary_sha256'] = Digest::SHA256.hexdigest(predecessor_summary_bytes)
    values['predecessor_delta_sha256'] = Digest::SHA256.hexdigest(predecessor_delta_bytes)
    values['predecessor_expanded_baseline_sha256'] = Digest::SHA256.hexdigest(predecessor_baseline_bytes)
    values['current_state_backup_sha256'] = backup.sha256
  end
  PROGRAM_FIELDS.each do |field, environment_name|
    values[field] = Digest::SHA256.hexdigest(locked_bytes(ENV.fetch(environment_name), expected_uid))
  end
  bytes = Umi::Fbig::ProductionFirstAuthorization::FIELD_NAMES.map do |field|
    "#{field}\t#{values.fetch(field)}\n"
  end.join
  Umi::Fbig::ProductionFirstAuthorization.parse(bytes)
  output = Pathname.new(ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_REQUEST_OUTPUT_DIR'))
  stat = File.lstat(output)
  invalid! unless
    output.absolute? && output.cleanpath.to_s == output.to_s &&
    stat.directory? && !stat.symlink? && stat.uid == expected_uid &&
    (stat.mode & 0o777) == 0o700
  publish!(output, bytes)
rescue StandardError
  warn 'production-first request generation failed'
  exit 1
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
