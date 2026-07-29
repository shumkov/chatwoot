# frozen_string_literal: true

require 'digest'
require 'pathname'

# These checks are deliberately linear and fail closed at each filesystem boundary.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
AUTHORIZATION_OUTPUTS = {
  request: 'fbig-production-first-authorization-v1.tsv',
  history_approval: 'fbig-production-first-history-approval-v1.tsv',
  recovered_targets: 'fbig-recovered-thread-targets-v1.tsv',
  unrecoverable_sidecar: 'fbig-unrecoverable-envelope-v1.tsv',
  unrecoverable_inspector: 'fbig-unrecoverable-envelope-inspector.rb'
}.freeze
UNRECOVERABLE_SIDECAR_FIELDS = %w[
  schema_version repository_commit image_digest account_id inbox_id
  instagram_business_id before platform count fingerprint
  inspector_script_sha256 approved_by approved_at
].freeze
STABLE_UNRECOVERABLE_SIDECAR_FIELDS = %w[
  schema_version account_id inbox_id instagram_business_id before platform count fingerprint
].freeze

def invalid!
  raise 'production-first authorization inputs are invalid'
end

def protected_bytes(path, expected_uid, checksum: false)
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
  if checksum
    checksum_bytes = protected_bytes("#{path}.sha256", expected_uid)
    expected = "#{Digest::SHA256.hexdigest(bytes)}  #{candidate.basename}\n"
    invalid! unless checksum_bytes == expected
  end
  bytes
rescue SystemCallError
  invalid!
end

def stage_values(bytes, stage)
  text = bytes.dup.force_encoding(Encoding::UTF_8)
  invalid! unless text.valid_encoding?
  marker = "[UMI-FBIG] stage=#{stage} "
  rows = text.lines.filter_map do |line|
    offset = line.index(marker)
    next unless offset

    pairs = line.byteslice(offset + marker.bytesize..).to_s.strip.split.map { |field| field.split('=', 2) }
    invalid! unless pairs.all? { |pair| pair.size == 2 } && pairs.map(&:first).uniq.size == pairs.size
    pairs.to_h
  end
  invalid! unless rows.one?
  rows.first
end

def manifest_values(bytes)
  text = bytes.dup.force_encoding(Encoding::UTF_8)
  invalid! unless text.valid_encoding? && text.end_with?("\n") && text.exclude?("\r") && text.exclude?("\0")
  pairs = text.lines(chomp: true).map do |line|
    pair = line.split("\t", -1)
    invalid! unless pair.size == 2
    pair
  end
  invalid! unless pairs.map(&:first).uniq.size == pairs.size
  pairs.to_h
end

def publish!(directory, basename, bytes)
  path = directory.join(basename)
  checksum = directory.join("#{basename}.sha256")
  invalid! if path.exist? || path.symlink? || checksum.exist? || checksum.symlink?
  [[path, bytes], [checksum, "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n"]].each do |destination, content|
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
  request_path = ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_REQUEST_PATH')
  request_bytes = protected_bytes(request_path, expected_uid, checksum: true)
  authorization = Umi::Fbig::ProductionFirstAuthorization.parse(request_bytes)
  invalid! unless authorization.authorization_generator_sha256 == Digest::SHA256.file(__FILE__).hexdigest

  sources = {
    'r2_acceptance_binding_sha256' => ['UMI_FBIG_R2_ACCEPTANCE_BINDING_PATH', true],
    'r2_launch_manifest_sha256' => ['UMI_FBIG_R2_LAUNCH_MANIFEST_PATH', true],
    'r2_probe_log_sha256' => ['UMI_FBIG_R2_PROBE_LOG_PATH', false],
    'r2_probe_summary_sha256' => ['UMI_FBIG_R2_PROBE_SUMMARY_PATH', false],
    'recovered_thread_targets_sha256' => ['UMI_FBIG_RECOVERED_THREAD_TARGETS_PATH', true],
    'placeholder_targets_sha256' => ['UMI_FBIG_PLACEHOLDER_TARGETS_PATH', false],
    'unrecoverable_inspector_sha256' => ['UMI_FBIG_UNRECOVERABLE_INSPECTOR_PATH', false],
    'coordinated_backup_manifest_sha256' => ['UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH', true],
    'history_program_sha256' => ['UMI_FBIG_HISTORY_PROGRAM_PATH', true],
    'profile_program_sha256' => ['UMI_FBIG_PROFILE_PROGRAM_PATH', true],
    'final_audit_program_sha256' => ['UMI_FBIG_FINAL_AUDIT_PROGRAM_PATH', true],
    'delivery_audit_program_sha256' => ['UMI_FBIG_DELIVERY_AUDIT_PROGRAM_PATH', true],
    'delivery_checkpoint_program_sha256' => ['UMI_FBIG_DELIVERY_CHECKPOINT_PROGRAM_PATH', true],
    'profile_wrapper_sha256' => ['UMI_FBIG_PROFILE_WRAPPER_PATH', true],
    'storage_helper_sha256' => ['UMI_FBIG_STORAGE_HELPER_PATH', true],
    'recovered_target_generator_sha256' => ['UMI_FBIG_RECOVERED_TARGET_GENERATOR_PATH', true],
    'history_revision_generator_sha256' => ['UMI_FBIG_HISTORY_REVISION_GENERATOR_PATH', true],
    'profile_approval_generator_sha256' => ['UMI_FBIG_PROFILE_APPROVAL_GENERATOR_PATH', true]
  }
  source_bytes = {}
  sources.each do |field, (environment_name, checksum)|
    bytes = protected_bytes(ENV.fetch(environment_name), expected_uid, checksum: checksum)
    invalid! unless Digest::SHA256.hexdigest(bytes) == authorization.public_send(field)
    source_bytes[field] = bytes
  end
  source_bytes['r2_unrecoverable_sidecar'] = protected_bytes(
    ENV.fetch('UMI_FBIG_UNRECOVERABLE_SIDECAR_PATH'),
    expected_uid
  )
  coordinated_backup = Umi::Fbig::CoordinatedBackupManifest.load(
    manifest_path: ENV.fetch('UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH'),
    checksum_path: "#{ENV.fetch('UMI_FBIG_COORDINATED_BACKUP_MANIFEST_PATH')}.sha256",
    expected_uid: expected_uid
  )
  invalid! unless
    coordinated_backup.sha256 == authorization.coordinated_backup_manifest_sha256 &&
    coordinated_backup.production_database_name == authorization.production_database &&
    coordinated_backup.image_digest == authorization.image_digest &&
    coordinated_backup.account_id == authorization.account_id &&
    coordinated_backup.inbox_id == authorization.inbox_id &&
    coordinated_backup.facebook_page_id == authorization.facebook_page_id &&
    coordinated_backup.instagram_business_id == authorization.instagram_business_id
  predecessor_sidecar = nil
  if authorization.predecessor_authorization_sha256 != 'none'
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
    predecessor_result_bytes = protected_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_HISTORY_RESULT_PATH'),
      expected_uid
    )
    predecessor_summary_bytes = protected_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_TERMINAL_SUMMARY_PATH'),
      expected_uid
    )
    predecessor_delta_bytes = protected_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_DELTA_PATH'),
      expected_uid
    )
    predecessor_baseline_bytes = protected_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_EXPANDED_BASELINE_PATH'),
      expected_uid
    )
    current_backup_bytes = protected_bytes(
      ENV.fetch('UMI_FBIG_CURRENT_STATE_BACKUP_PATH'),
      expected_uid
    )
    predecessor_sidecar_bytes = protected_bytes(
      ENV.fetch('UMI_FBIG_PREDECESSOR_UNRECOVERABLE_SIDECAR_PATH'),
      expected_uid,
      checksum: true
    )
    predecessor_result = manifest_values(predecessor_result_bytes)
    predecessor_sidecar = manifest_values(predecessor_sidecar_bytes)
    invalid! unless
      predecessor_authorization.sha256 == authorization.predecessor_authorization_sha256 &&
      predecessor_approval.production_first_authorization_sha256 == predecessor_authorization.sha256 &&
      predecessor_result.fetch('authorization_sha256') == predecessor_authorization.sha256 &&
      predecessor_result.fetch('history_approval_sha256') == predecessor_approval.sha256 &&
      predecessor_result.fetch('run_summary_sha256') == authorization.predecessor_terminal_summary_sha256 &&
      predecessor_result.fetch('delta_sha256') == authorization.predecessor_delta_sha256 &&
      predecessor_result.fetch('poststate_sha256') == authorization.predecessor_expanded_baseline_sha256 &&
      Digest::SHA256.hexdigest(predecessor_result_bytes) == authorization.predecessor_history_result_sha256 &&
      Digest::SHA256.hexdigest(predecessor_summary_bytes) == authorization.predecessor_terminal_summary_sha256 &&
      Digest::SHA256.hexdigest(predecessor_delta_bytes) == authorization.predecessor_delta_sha256 &&
      Digest::SHA256.hexdigest(predecessor_baseline_bytes) == authorization.predecessor_expanded_baseline_sha256 &&
      Digest::SHA256.hexdigest(current_backup_bytes) == authorization.current_state_backup_sha256 &&
      authorization.current_state_backup_sha256 == authorization.coordinated_backup_manifest_sha256 &&
      Digest::SHA256.hexdigest(predecessor_sidecar_bytes) == predecessor_approval.unrecoverable_sidecar_sha256 &&
      predecessor_sidecar.fetch('repository_commit') == predecessor_authorization.repository_commit &&
      predecessor_sidecar.fetch('image_digest') == predecessor_authorization.image_digest &&
      predecessor_sidecar.fetch('inspector_script_sha256') ==
      predecessor_authorization.unrecoverable_inspector_sha256 &&
      (authorization.repository_commit != predecessor_authorization.repository_commit ||
       authorization.image_digest != predecessor_authorization.image_digest) &&
      predecessor_result.fetch('protected_changes') == '0' &&
      predecessor_result.fetch('deleted_rows') == '0' &&
      predecessor_result.fetch('unattributed_changes') == '0' &&
      predecessor_result.fetch('counter_mismatches') == 'none'
    invariant_fields = %w[
      production_database account_id inbox_id facebook_page_id instagram_business_id since before
      outbound_policy profile_mode recovered_thread_targets_sha256 placeholder_targets_sha256
      messenger_unavailable_message_thread_count
      messenger_unavailable_message_thread_fingerprint instagram_unavailable_message_thread_count
      instagram_unavailable_message_thread_fingerprint r2_acceptance_binding_sha256 r2_launch_manifest_sha256
      r2_probe_log_sha256 r2_probe_summary_sha256
    ]
    invalid! unless invariant_fields.all? do |field|
      authorization.public_send(field) == predecessor_approval.public_send(field)
    end
    %w[messenger instagram].each do |platform|
      invalid! unless
        authorization.public_send("#{platform}_count") == predecessor_approval.public_send("#{platform}_count") &&
        authorization.public_send("#{platform}_fingerprint") ==
        predecessor_approval.public_send("#{platform}_fingerprint")
    end
  end

  targets = Umi::Fbig::RecoveredThreadTargets.parse(source_bytes.fetch('recovered_thread_targets_sha256'))
  invalid! unless
    targets.values.fetch('source_acceptance_binding_sha256') == authorization.r2_acceptance_binding_sha256 &&
    targets.values.fetch('source_launch_manifest_sha256') == authorization.r2_launch_manifest_sha256 &&
    targets.values.fetch('source_probe_log_sha256') == authorization.r2_probe_log_sha256 &&
    targets.values.fetch('source_probe_summary_sha256') == authorization.r2_probe_summary_sha256 &&
    targets.values.fetch('generator_sha256') == authorization.recovered_target_generator_sha256
  Umi::Fbig::ProfileTargetManifest.load(
    path: ENV.fetch('UMI_FBIG_PLACEHOLDER_TARGETS_PATH'),
    expected_sha256: authorization.placeholder_targets_sha256,
    expected_uid: expected_uid
  )
  source_sidecar = manifest_values(source_bytes.fetch('r2_unrecoverable_sidecar'))
  invalid! unless
    source_sidecar.keys == UNRECOVERABLE_SIDECAR_FIELDS &&
    source_sidecar.fetch('repository_commit') == targets.values.fetch('source_repository_commit') &&
    source_sidecar.fetch('image_digest') == targets.values.fetch('source_image_digest') &&
    source_sidecar.fetch('account_id') == authorization.account_id.to_s &&
    source_sidecar.fetch('inbox_id') == authorization.inbox_id.to_s &&
    source_sidecar.fetch('instagram_business_id') == authorization.instagram_business_id.to_s &&
    source_sidecar.fetch('before') == authorization.values.fetch('before') &&
    source_sidecar.fetch('platform') == 'instagram' &&
    source_sidecar.fetch('count') == '1' &&
    source_sidecar.fetch('inspector_script_sha256') == authorization.unrecoverable_inspector_sha256
  if predecessor_sidecar
    stable_sidecar = STABLE_UNRECOVERABLE_SIDECAR_FIELDS.all? do |field|
      predecessor_sidecar.fetch(field) == source_sidecar.fetch(field)
    end
    invalid! unless stable_sidecar
  end
  sidecar_values = source_sidecar.merge(
    'repository_commit' => authorization.repository_commit,
    'image_digest' => authorization.image_digest,
    'approved_by' => authorization.approved_by,
    'approved_at' => authorization.created_at
  )
  sidecar_bytes = UNRECOVERABLE_SIDECAR_FIELDS.map do |field|
    "#{field}\t#{sidecar_values.fetch(field)}\n"
  end.join
  invalid! unless Digest::SHA256.hexdigest(sidecar_bytes) == authorization.unrecoverable_sidecar_sha256
  unless predecessor_sidecar
    summary = stage_values(source_bytes.fetch('r2_probe_summary_sha256'), 'history_import_summary')
    %w[messenger instagram].each do |platform|
      invalid! unless
        authorization.public_send("#{platform}_count") == summary.fetch("#{platform}_contentless_details") &&
        authorization.public_send("#{platform}_fingerprint") == summary.fetch("#{platform}_contentless_fingerprint")
    end
  end

  output_directory = Pathname.new(ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_OUTPUT_DIR'))
  output_stat = File.lstat(output_directory)
  invalid! unless
    output_directory.absolute? && output_directory.cleanpath.to_s == output_directory.to_s &&
    output_stat.directory? && !output_stat.symlink? && output_stat.uid == expected_uid &&
    (output_stat.mode & 0o777) == 0o700
  AUTHORIZATION_OUTPUTS.each_value do |basename|
    path = output_directory.join(basename)
    checksum = output_directory.join("#{basename}.sha256")
    invalid! if path.exist? || path.symlink? || checksum.exist? || checksum.symlink?
  end

  history_values = {
    'schema_version' => '1',
    'authorization_mode' => 'production_first',
    'repository_commit' => authorization.repository_commit,
    'image_digest' => authorization.image_digest,
    'production_database' => authorization.production_database,
    'account_id' => authorization.account_id.to_s,
    'inbox_id' => authorization.inbox_id.to_s,
    'facebook_page_id' => authorization.facebook_page_id.to_s,
    'instagram_business_id' => authorization.instagram_business_id.to_s,
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
    'messenger_unavailable_message_thread_fingerprint' => authorization.messenger_unavailable_message_thread_fingerprint,
    'instagram_unavailable_message_thread_count' => authorization.instagram_unavailable_message_thread_count,
    'instagram_unavailable_message_thread_fingerprint' => authorization.instagram_unavailable_message_thread_fingerprint,
    'r2_acceptance_binding_sha256' => authorization.r2_acceptance_binding_sha256,
    'r2_launch_manifest_sha256' => authorization.r2_launch_manifest_sha256,
    'r2_probe_log_sha256' => authorization.r2_probe_log_sha256,
    'r2_probe_summary_sha256' => authorization.r2_probe_summary_sha256,
    'revision_platform' => 'none',
    'predecessor_approval_sha256' => 'none',
    'predecessor_attempt_result_sha256' => 'none',
    'predecessor_run_summary_sha256' => 'none',
    'predecessor_delta_sha256' => 'none',
    'approved_by' => authorization.approved_by,
    'approved_at' => authorization.created_at
  }
  history_bytes = Umi::Fbig::ProductionFirstHistoryApproval::FIELD_NAMES.map do |field|
    "#{field}\t#{history_values.fetch(field)}\n"
  end.join
  Umi::Fbig::ProductionFirstHistoryApproval.parse(history_bytes)
  publish!(output_directory, AUTHORIZATION_OUTPUTS.fetch(:request), request_bytes)
  publish!(output_directory, AUTHORIZATION_OUTPUTS.fetch(:history_approval), history_bytes)
  publish!(
    output_directory,
    AUTHORIZATION_OUTPUTS.fetch(:recovered_targets),
    source_bytes.fetch('recovered_thread_targets_sha256')
  )
  publish!(
    output_directory,
    AUTHORIZATION_OUTPUTS.fetch(:unrecoverable_sidecar),
    sidecar_bytes
  )
  publish!(
    output_directory,
    AUTHORIZATION_OUTPUTS.fetch(:unrecoverable_inspector),
    source_bytes.fetch('unrecoverable_inspector_sha256')
  )
rescue StandardError
  warn 'production-first authorization generation failed'
  exit 1
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
