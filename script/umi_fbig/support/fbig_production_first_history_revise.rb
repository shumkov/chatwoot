# frozen_string_literal: true

require 'digest'
require 'pathname'

# The revision gate deliberately validates every accepted failure invariant in one place.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
REVISION_OUTPUTS = {
  history_approval: 'fbig-production-first-history-approval-v1.tsv',
  authorization: 'fbig-production-first-authorization-v1.tsv',
  recovered_targets: 'fbig-recovered-thread-targets-v1.tsv',
  unrecoverable_sidecar: 'fbig-unrecoverable-envelope-v1.tsv',
  unrecoverable_inspector: 'fbig-unrecoverable-envelope-inspector.rb'
}.freeze
SHA256_PATTERN = /\A[0-9a-f]{64}\z/
REVISION_ZERO_FIELDS = %w[
  failed_threads partially_paginated_threads uncategorized_threads unavailable_message_threads
  unavailable_message_thread_acceptance_mismatches platform_failures retry_exhaustion rate_limits
  authentication_failures lock_loss foreign_source_id_anomalies reindex_failures
  download_budget_exhaustions recovered_target_mismatches recovered_target_duplicate_listings
  ambiguous_senders predecessor_archive_not_returned
].freeze
REVISION_DELTA_FIELDS = %w[
  active_storage_attachments_created active_storage_blobs_created archive_activity_changed
  archive_configuration_changed archives_created attachments_created contact_activity_changed
  contact_inboxes_created contact_inboxes_reused contact_profile_changed contacts_created
  contacts_reused incoming_created messages_created outgoing_created
].freeze
REVISION_SUMMARY_DELTA_FIELDS = {
  'imported_contacts' => 'contacts_created',
  'imported_archives' => 'archives_created',
  'imported_incoming' => 'incoming_created',
  'imported_outgoing' => 'outgoing_created',
  'imported_messages' => 'messages_created',
  'imported_attachments' => 'attachments_created',
  'marker_normalizations' => 'archive_configuration_changed'
}.freeze

def invalid!
  raise 'production-first history revision inputs are invalid'
end

def protected_bytes(path, expected_uid, checksum: true)
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
    checksum_bytes = protected_bytes("#{path}.sha256", expected_uid, checksum: false)
    invalid! unless checksum_bytes == "#{Digest::SHA256.hexdigest(bytes)}  #{candidate.basename}\n"
  end
  bytes
rescue SystemCallError
  invalid!
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

def stage_values(bytes, stage)
  text = bytes.dup.force_encoding(Encoding::UTF_8)
  invalid! unless
    text.valid_encoding? && text.end_with?("\n") && text.lines.size == 1 &&
    text.exclude?("\r") && text.exclude?("\0")
  marker = "[UMI-FBIG] stage=#{stage} "
  line = text.chomp
  invalid! unless line.start_with?(marker)
  payload = line.delete_prefix(marker)
  fields = payload.split
  invalid! unless fields.join(' ') == payload
  pairs = fields.map do |field|
    pair = field.split('=', 2)
    invalid! unless
      pair.size == 2 && pair.first.match?(/\A[a-z0-9_]+\z/) &&
      !pair.last.empty?
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
  authorization = Umi::Fbig::ProductionFirstAuthorization.load(
    manifest_path: ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  authorization_bytes = protected_bytes(
    ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH'),
    expected_uid
  )
  package_directory = Pathname.new(ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH')).dirname
  package_bytes = {
    REVISION_OUTPUTS.fetch(:authorization) => authorization_bytes,
    REVISION_OUTPUTS.fetch(:recovered_targets) => protected_bytes(
      package_directory.join(REVISION_OUTPUTS.fetch(:recovered_targets)).to_s,
      expected_uid
    ),
    REVISION_OUTPUTS.fetch(:unrecoverable_sidecar) => protected_bytes(
      package_directory.join(REVISION_OUTPUTS.fetch(:unrecoverable_sidecar)).to_s,
      expected_uid
    ),
    REVISION_OUTPUTS.fetch(:unrecoverable_inspector) => protected_bytes(
      package_directory.join(REVISION_OUTPUTS.fetch(:unrecoverable_inspector)).to_s,
      expected_uid
    )
  }
  invalid! unless
    Digest::SHA256.hexdigest(package_bytes.fetch(REVISION_OUTPUTS.fetch(:recovered_targets))) ==
    authorization.recovered_thread_targets_sha256 &&
    Digest::SHA256.hexdigest(package_bytes.fetch(REVISION_OUTPUTS.fetch(:unrecoverable_sidecar))) ==
    authorization.unrecoverable_sidecar_sha256 &&
    Digest::SHA256.hexdigest(package_bytes.fetch(REVISION_OUTPUTS.fetch(:unrecoverable_inspector))) ==
    authorization.unrecoverable_inspector_sha256
  invalid! unless authorization.history_revision_generator_sha256 == Digest::SHA256.file(__FILE__).hexdigest
  predecessor = Umi::Fbig::ProductionFirstHistoryApproval.load(
    manifest_path: ENV.fetch('UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_PREDECESSOR_HISTORY_APPROVAL_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  invalid! unless predecessor.production_first_authorization_sha256 == authorization.sha256

  result_bytes = protected_bytes(ENV.fetch('UMI_FBIG_FAILED_HISTORY_RESULT_PATH'), expected_uid)
  summary_bytes = protected_bytes(ENV.fetch('UMI_FBIG_FAILED_HISTORY_SUMMARY_PATH'), expected_uid)
  delta_bytes = protected_bytes(ENV.fetch('UMI_FBIG_FAILED_HISTORY_DELTA_PATH'), expected_uid)
  result = manifest_values(result_bytes)
  summary = stage_values(summary_bytes, 'history_import_summary')
  delta = stage_values(delta_bytes, 'history_state_delta')
  platform = result.fetch('platforms')
  invalid! unless %w[messenger instagram].include?(platform)
  invalid! unless
    result['authorization_mode'] == 'production_first' &&
    result['authorization_sha256'] == authorization.sha256 &&
    result['history_approval_sha256'] == predecessor.sha256 &&
    result['operation'] == 'apply' &&
    result['run_summary_sha256'] == Digest::SHA256.hexdigest(summary_bytes) &&
    result['delta_sha256'] == Digest::SHA256.hexdigest(delta_bytes) &&
    result['exit_status'] == '1' &&
    result['termination'] == 'normal' &&
    result['protected_changes'] == '0' &&
    result['deleted_rows'] == '0' &&
    result['unattributed_changes'] == '0' &&
    result['counter_mismatches'] == 'none'
  invalid! unless
    summary['dry_run'] == 'false' &&
    summary['scan_complete'] == 'true' &&
    summary['write_complete'] == 'false' &&
    summary['contentless_acceptance_mismatches'] == '1' &&
    summary['exit_failures'] == '1' &&
    REVISION_ZERO_FIELDS.all? { |field| summary.fetch(field) == '0' }
  delta_matches = REVISION_DELTA_FIELDS.all? do |field|
    delta.fetch(field).match?(/\A(?:0|[1-9][0-9]*)\z/) &&
      delta.fetch(field) == result.fetch("#{platform}_#{field}")
  end
  summary_delta_matches = REVISION_SUMMARY_DELTA_FIELDS.all? do |summary_field, delta_field|
    summary.fetch(summary_field) == delta.fetch(delta_field)
  end
  invalid! unless
    delta.keys.sort == (REVISION_DELTA_FIELDS + ['platform']).sort &&
    delta['platform'] == platform &&
    delta_matches &&
    summary_delta_matches

  expected_target_sha = platform == 'instagram' ? predecessor.recovered_thread_targets_sha256 : 'none'
  expected_target_count = platform == 'instagram' ? '2' : '0'
  invalid! unless
    summary['recovered_thread_targets_sha256'] == expected_target_sha &&
    summary['recovered_targets_expected'] == expected_target_count &&
    summary['recovered_targets_listed'] == expected_target_count &&
    summary['recovered_targets_message_cursor_exhausted'] == expected_target_count

  structural_count = platform == 'instagram' ? '1' : '0'
  listed = Integer(summary.fetch('listed_threads'), 10)
  exhausted = Integer(summary.fetch('message_cursor_exhausted_threads'), 10)
  invalid! unless
    summary['structural_unrecoverable_threads'] == structural_count &&
    summary['ambiguous_participants'] == structural_count &&
    summary['classified_omitted_threads'] == structural_count &&
    summary.fetch("#{platform}_listed_threads") == summary.fetch('listed_threads') &&
    summary.fetch("#{platform}_message_cursor_exhausted_threads") ==
    summary.fetch('message_cursor_exhausted_threads') &&
    summary.fetch("#{platform}_structural_unrecoverable_threads") == structural_count &&
    summary.fetch("#{platform}_unavailable_message_threads") == '0' &&
    summary.fetch("#{platform}_classified_omitted_threads") == structural_count &&
    summary.fetch("#{platform}_failed_threads") == '0' &&
    summary.fetch("#{platform}_partially_paginated_threads") == '0' &&
    summary.fetch("#{platform}_uncategorized_threads") == '0' &&
    listed == exhausted + Integer(structural_count, 10)

  in_scope = Integer(summary.fetch('in_scope_mids_scanned'), 10)
  already_present = Integer(summary.fetch('already_present'), 10)
  candidate_incoming = Integer(summary.fetch('candidate_incoming'), 10)
  candidate_outbound = Integer(summary.fetch('candidate_outbound'), 10)
  outbound_import = Integer(summary.fetch('outbound_pre_presence_import'), 10)
  outbound_skip = Integer(summary.fetch('outbound_pre_presence_skip'), 10)
  imported_messages = Integer(summary.fetch('imported_messages'), 10)
  imported_incoming = Integer(summary.fetch('imported_incoming'), 10)
  imported_outgoing = Integer(summary.fetch('imported_outgoing'), 10)
  late_already_present = Integer(summary.fetch('late_already_present'), 10)
  contentless = Integer(summary.fetch("#{platform}_contentless_details"), 10)
  invalid! unless
    in_scope == already_present + candidate_incoming + candidate_outbound &&
    candidate_outbound == outbound_import + outbound_skip &&
    candidate_incoming + outbound_import == imported_messages + late_already_present + contentless &&
    imported_messages == imported_incoming + imported_outgoing &&
    Integer(summary.fetch('content_unavailable'), 10) == contentless

  observed_count = summary.fetch("#{platform}_contentless_details")
  observed_fingerprint = summary.fetch("#{platform}_contentless_fingerprint")
  invalid! unless observed_count.match?(/\A(?:0|[1-9][0-9]*)\z/) && observed_fingerprint.match?(SHA256_PATTERN)
  invalid! if
    observed_count == predecessor.values.fetch("#{platform}_count") &&
    observed_fingerprint == predecessor.values.fetch("#{platform}_fingerprint")

  values = predecessor.values.dup
  values["#{platform}_count"] = observed_count
  values["#{platform}_fingerprint"] = observed_fingerprint
  values['revision_platform'] = platform
  values['predecessor_approval_sha256'] = predecessor.sha256
  values['predecessor_attempt_result_sha256'] = Digest::SHA256.hexdigest(result_bytes)
  values['predecessor_run_summary_sha256'] = Digest::SHA256.hexdigest(summary_bytes)
  values['predecessor_delta_sha256'] = Digest::SHA256.hexdigest(delta_bytes)
  values['approved_by'] = ENV.fetch('UMI_FBIG_APPROVED_BY')
  values['approved_at'] = ENV.fetch('UMI_FBIG_APPROVED_AT')
  bytes = Umi::Fbig::ProductionFirstHistoryApproval::FIELD_NAMES.map do |field|
    "#{field}\t#{values.fetch(field)}\n"
  end.join
  Umi::Fbig::ProductionFirstHistoryApproval.parse(bytes)

  output = Pathname.new(ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_REVISION_OUTPUT_DIR'))
  stat = File.lstat(output)
  invalid! unless
    output.absolute? && output.cleanpath.to_s == output.to_s &&
    stat.directory? && !stat.symlink? && stat.uid == expected_uid &&
    (stat.mode & 0o777) == 0o700
  REVISION_OUTPUTS.each_value do |basename|
    invalid! if output.join(basename).exist? || output.join("#{basename}.sha256").exist?
  end
  publish!(output, REVISION_OUTPUTS.fetch(:history_approval), bytes)
  package_bytes.each { |basename, content| publish!(output, basename, content) }
rescue StandardError
  warn 'production-first history revision generation failed'
  exit 1
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
