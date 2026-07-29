# frozen_string_literal: true

require 'digest'
require 'pathname'

# These checks are deliberately linear and fail closed at each filesystem boundary.
# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
PROFILE_OUTPUTS = {
  profile_approval: 'fbig-production-first-profile-approval-v1.tsv',
  authorization: 'fbig-production-first-authorization-v1.tsv',
  history_index: 'fbig-production-first-history-result-index-v1.tsv',
  messenger_terminal: 'fbig-messenger-terminal-history-result-v1.tsv',
  instagram_terminal: 'fbig-instagram-terminal-history-result-v1.tsv',
  coordinated_backup: 'fbig-coordinated-pre-profile-backup-v1.tsv',
  database_dump: 'database.dump',
  database_restore_list: 'database.restore.list',
  storage_archive: 'storage.tar',
  storage_manifest: 'storage.manifest',
  profile_state: 'fbig-profile-state-v1.tsv',
  profile_targets: 'fbig-profile-targets-v1.tsv'
}.freeze
PLATFORMS = %w[messenger instagram].freeze
CONTENTLESS_SUFFIXES = %w[count fingerprint].freeze

def invalid!
  raise 'production-first profile approval inputs are invalid'
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
    invalid! unless
      checksum_bytes == "#{Digest::SHA256.hexdigest(bytes)}  #{candidate.basename}\n"
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

def positive_env(name)
  value = ENV.fetch(name)
  parsed = Integer(value, 10)
  invalid! unless parsed.positive? && parsed.to_s == value
  value
rescue ArgumentError
  invalid!
end

def publish!(directory, basename, bytes)
  path = directory.join(basename)
  checksum = directory.join("#{basename}.sha256")
  invalid! if path.exist? || path.symlink? || checksum.exist? || checksum.symlink?
  seal!(directory, path, bytes)
  seal!(directory, checksum, "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n")
  File.open(directory, File::RDONLY, &:fsync)
end

def publish_file!(directory, basename, source, expected_sha256, expected_uid)
  path = directory.join(basename)
  checksum = directory.join("#{basename}.sha256")
  invalid! if path.exist? || path.symlink? || checksum.exist? || checksum.symlink?
  temporary = directory.join(".#{basename}.#{Process.pid}.tmp")
  digest = Digest::SHA256.new
  opened = nil
  File.open(source, 'rb') do |input|
    opened = input.stat
    invalid! unless
      opened.file? && opened.uid == expected_uid && opened.nlink == 1 &&
      (opened.mode & 0o777) == 0o400
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
      output.binmode
      while (chunk = input.read(1024 * 1024))
        output.write(chunk)
        digest << chunk
      end
      output.flush
      output.fsync
    end
  end
  current = File.lstat(source)
  invalid! if current.symlink? || current.dev != opened.dev || current.ino != opened.ino
  invalid! unless digest.hexdigest == expected_sha256
  File.chmod(0o400, temporary)
  File.link(temporary, path)
  File.unlink(temporary)
  seal!(directory, checksum, "#{expected_sha256}  #{basename}\n")
  File.open(directory, File::RDONLY, &:fsync)
ensure
  File.unlink(temporary) if defined?(temporary) && temporary&.exist?
end

def seal!(directory, destination, content)
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
ensure
  File.unlink(temporary) if defined?(temporary) && temporary&.exist?
end

begin
  expected_uid = Integer(ENV.fetch('UMI_FBIG_EXPECTED_UID', '0'), 10)
  authorization_bytes = protected_bytes(
    ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH'),
    expected_uid
  )
  authorization = Umi::Fbig::ProductionFirstAuthorization.load(
    manifest_path: ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  invalid! unless authorization.profile_approval_generator_sha256 == Digest::SHA256.file(__FILE__).hexdigest
  history = Umi::Fbig::ProductionFirstHistoryApproval.load(
    manifest_path: ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  invalid! unless Digest::SHA256.hexdigest(authorization_bytes) == authorization.sha256
  invalid! unless history.production_first_authorization_sha256 == authorization.sha256
  history_index_path = ENV.fetch('UMI_FBIG_HISTORY_RESULT_INDEX_PATH')
  history_index_bytes = protected_bytes(history_index_path, expected_uid)
  history_index_checksum = ENV.fetch('UMI_FBIG_HISTORY_RESULT_INDEX_CHECKSUM_PATH')
  invalid! unless history_index_checksum == "#{history_index_path}.sha256"
  protected_bytes(history_index_checksum, expected_uid, checksum: false)
  entries = {}
  last_by_platform = {}
  previous_result_sha = 'none'
  previous_authorization_sha = 'none'
  previous_approval_sha = 'none'
  previous_result_path = nil
  previous_result = nil
  history_index_bytes.lines(chomp: true).each_with_index do |line, index|
    sequence, result_path, result_sha, authorization_path, authorization_sha, approval_path, approval_sha, extra =
      line.split("\t", -1)
    invalid! if extra || sequence != (index + 1).to_s
    invalid! unless Pathname.new(result_path).basename.to_s == 'fbig-history-attempt-result-v1.tsv'
    result_bytes = protected_bytes(result_path, expected_uid)
    result = manifest_values(result_bytes)
    node_authorization = Umi::Fbig::ProductionFirstAuthorization.load(
      manifest_path: authorization_path,
      checksum_path: "#{authorization_path}.sha256",
      expected_uid: expected_uid
    )
    node_approval = Umi::Fbig::ProductionFirstHistoryApproval.load(
      manifest_path: approval_path,
      checksum_path: "#{approval_path}.sha256",
      expected_uid: expected_uid
    )
    invalid! unless
      Digest::SHA256.hexdigest(result_bytes) == result_sha &&
      node_authorization.sha256 == authorization_sha &&
      node_approval.sha256 == approval_sha &&
      node_approval.production_first_authorization_sha256 == authorization_sha &&
      result.fetch('authorization_mode') == 'production_first' &&
      result.fetch('authorization_sha256') == authorization_sha &&
      result.fetch('history_approval_sha256') == approval_sha &&
      result.fetch('predecessor_result_sha256') == previous_result_sha &&
      result.fetch('program_sha256') == node_authorization.history_program_sha256 &&
      result.fetch('candidate_commit') == node_authorization.repository_commit &&
      result.fetch('candidate_image') == node_authorization.image_digest &&
      result.fetch('production_database') == node_authorization.production_database &&
      result.fetch('inbox_id') == node_authorization.inbox_id.to_s &&
      result.fetch('operation') == 'apply' &&
      result.fetch('acceptance_sha256') == 'none' &&
      result.fetch('pre_history_backup_sha256') == node_approval.coordinated_backup_manifest_sha256 &&
      result.fetch('dry_pair_sha256') == 'none'
    invariant_fields = %w[
      repository_commit image_digest production_database account_id inbox_id
      facebook_page_id instagram_business_id since before outbound_policy profile_mode
      coordinated_backup_manifest_sha256 recovered_thread_targets_sha256
      placeholder_targets_sha256 unrecoverable_sidecar_sha256
      messenger_unavailable_message_thread_count messenger_unavailable_message_thread_fingerprint
      instagram_unavailable_message_thread_count instagram_unavailable_message_thread_fingerprint
      r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
    ]
    invalid! unless invariant_fields.all? do |field|
      node_approval.values.fetch(field) == node_authorization.values.fetch(field)
    end
    contentless_matches = PLATFORMS.to_h do |platform|
      matches = CONTENTLESS_SUFFIXES.all? do |suffix|
        node_approval.values.fetch("#{platform}_#{suffix}") ==
          node_authorization.values.fetch("#{platform}_#{suffix}")
      end
      [platform, matches]
    end
    if node_approval.revision_platform == 'none'
      invalid! unless contentless_matches.values.all?
    else
      invalid! unless
        contentless_matches.fetch(node_approval.revision_platform) == false &&
        contentless_matches.except(node_approval.revision_platform).values.all?
    end
    invalid! if entries.key?(result_sha)
    if previous_authorization_sha == 'none'
      initial_approval = Umi::Fbig::ProductionFirstHistoryApproval::PREDECESSOR_FIELDS.all? do |field|
        node_approval.values.fetch(field) == 'none'
      end
      invalid! unless
        node_authorization.predecessor_authorization_sha256 == 'none' &&
        node_approval.revision_platform == 'none' &&
        initial_approval &&
        result.fetch('platforms') == 'messenger'
    elsif authorization_sha != previous_authorization_sha
      predecessor_summary_bytes = protected_bytes(
        File.join(File.dirname(previous_result_path), 'history-summary.tsv'),
        expected_uid
      )
      predecessor_delta_bytes = protected_bytes(
        File.join(File.dirname(previous_result_path), 'history-delta.tsv'),
        expected_uid
      )
      predecessor_poststate_bytes = protected_bytes(
        File.join(File.dirname(previous_result_path), 'fbig-history-production-poststate-v1.tsv'),
        expected_uid
      )
      initial_approval = Umi::Fbig::ProductionFirstHistoryApproval::PREDECESSOR_FIELDS.all? do |field|
        node_approval.values.fetch(field) == 'none'
      end
      invalid! unless
        node_authorization.predecessor_authorization_sha256 == previous_authorization_sha &&
        node_authorization.predecessor_history_result_sha256 == previous_result_sha &&
        node_authorization.predecessor_terminal_summary_sha256 ==
        Digest::SHA256.hexdigest(predecessor_summary_bytes) &&
        node_authorization.predecessor_delta_sha256 == Digest::SHA256.hexdigest(predecessor_delta_bytes) &&
        node_authorization.predecessor_expanded_baseline_sha256 ==
        Digest::SHA256.hexdigest(predecessor_poststate_bytes) &&
        node_authorization.current_state_backup_sha256 == node_approval.coordinated_backup_manifest_sha256 &&
        node_authorization.current_state_backup_sha256 != 'none' &&
        previous_result.fetch('platforms') == result.fetch('platforms') &&
        previous_result.fetch('protected_changes') == '0' &&
        previous_result.fetch('deleted_rows') == '0' &&
        previous_result.fetch('unattributed_changes') == '0' &&
        previous_result.fetch('counter_mismatches') == 'none' &&
        node_approval.revision_platform == 'none' &&
        initial_approval
    elsif approval_sha != previous_approval_sha
      predecessor_summary_bytes = protected_bytes(
        File.join(File.dirname(previous_result_path), 'history-summary.tsv'),
        expected_uid
      )
      predecessor_delta_bytes = protected_bytes(
        File.join(File.dirname(previous_result_path), 'history-delta.tsv'),
        expected_uid
      )
      predecessor_summary = stage_values(predecessor_summary_bytes, 'history_import_summary')
      invalid! unless
        node_approval.revision_platform != 'none' &&
        result.fetch('platforms') == node_approval.revision_platform &&
        previous_result.fetch('platforms') == node_approval.revision_platform &&
        node_approval.predecessor_approval_sha256 == previous_approval_sha &&
        node_approval.predecessor_attempt_result_sha256 == previous_result_sha &&
        node_approval.predecessor_run_summary_sha256 == Digest::SHA256.hexdigest(predecessor_summary_bytes) &&
        node_approval.predecessor_delta_sha256 == Digest::SHA256.hexdigest(predecessor_delta_bytes) &&
        node_approval.values.fetch("#{node_approval.revision_platform}_count") ==
        predecessor_summary.fetch("#{node_approval.revision_platform}_contentless_details") &&
        node_approval.values.fetch("#{node_approval.revision_platform}_fingerprint") ==
        predecessor_summary.fetch("#{node_approval.revision_platform}_contentless_fingerprint") &&
        predecessor_summary.fetch('contentless_acceptance_mismatches') == '1' &&
        previous_result.fetch('exit_status') == '1' &&
        previous_result.fetch('termination') == 'normal'
    elsif result.fetch('platforms') != previous_result.fetch('platforms')
      summary = stage_values(
        protected_bytes(File.join(File.dirname(previous_result_path), 'history-summary.tsv'), expected_uid),
        'history_import_summary'
      )
      invalid! unless
        previous_result.fetch('platforms') == 'messenger' &&
        result.fetch('platforms') == 'instagram' &&
        previous_result.fetch('require_zero_writes') == 'true' &&
        previous_result.fetch('zero_write_observed') == 'true' &&
        previous_result.fetch('exit_status') == '0' &&
        previous_result.fetch('termination') == 'normal' &&
        previous_result.fetch('protected_changes') == '0' &&
        previous_result.fetch('deleted_rows') == '0' &&
        previous_result.fetch('unattributed_changes') == '0' &&
        previous_result.fetch('counter_mismatches') == 'none' &&
        summary.fetch('platforms') == 'messenger' &&
        summary.fetch('dry_run') == 'false' &&
        summary.fetch('scan_complete') == 'true' &&
        summary.fetch('write_complete') == 'true' &&
        summary.fetch('failed_threads') == '0' &&
        summary.fetch('partially_paginated_threads') == '0'
    end
    entries[result_sha] = {
      authorization: node_authorization,
      approval: node_approval
    }
    last_by_platform[result.fetch('platforms')] = result_sha
    previous_result_sha = result_sha
    previous_authorization_sha = authorization_sha
    previous_approval_sha = approval_sha
    previous_result_path = result_path
    previous_result = result
  end
  invalid! unless
    entries.any? &&
    previous_authorization_sha == authorization.sha256 &&
    previous_approval_sha == history.sha256

  terminal = {}
  terminal_bytes = {}
  PLATFORMS.each do |platform|
    path = ENV.fetch("UMI_FBIG_#{platform.upcase}_TERMINAL_HISTORY_RESULT_PATH")
    bytes = protected_bytes(path, expected_uid)
    values = manifest_values(bytes)
    terminal_sha = Digest::SHA256.hexdigest(bytes)
    node = entries.fetch(terminal_sha)
    node_authorization = node.fetch(:authorization)
    node_approval = node.fetch(:approval)
    valid = values['authorization_mode'] == 'production_first' &&
            values['authorization_sha256'] == node_authorization.sha256 &&
            values['history_approval_sha256'] == node_approval.sha256 &&
            values['platforms'] == platform &&
            values['require_zero_writes'] == 'true' &&
            values['zero_write_observed'] == 'true' &&
            values['exit_status'] == '0' &&
            values['termination'] == 'normal' &&
            values['protected_changes'] == '0' &&
            values['deleted_rows'] == '0' &&
            values['unattributed_changes'] == '0' &&
            values['counter_mismatches'] == 'none' &&
            terminal_sha == last_by_platform.fetch(platform) &&
            node_approval.public_send("#{platform}_count") == history.public_send("#{platform}_count") &&
            node_approval.public_send("#{platform}_fingerprint") == history.public_send("#{platform}_fingerprint") &&
            node_approval.public_send("#{platform}_unavailable_message_thread_count") ==
            history.public_send("#{platform}_unavailable_message_thread_count") &&
            node_approval.public_send("#{platform}_unavailable_message_thread_fingerprint") ==
            history.public_send("#{platform}_unavailable_message_thread_fingerprint")
    invalid! unless valid
    terminal[platform] = terminal_sha
    terminal_bytes[platform] = bytes
  end

  source_state_bytes = protected_bytes(ENV.fetch('UMI_FBIG_PROFILE_STATE_PATH'), expected_uid)
  source_state = Umi::Fbig::ProfileStateSnapshot.load(
    path: ENV.fetch('UMI_FBIG_PROFILE_STATE_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  targets = Umi::Fbig::ProfileTargetManifest.load(
    path: ENV.fetch('UMI_FBIG_PROFILE_TARGETS_PATH'),
    expected_sha256: history.placeholder_targets_sha256,
    expected_uid: expected_uid
  )
  target_bytes = protected_bytes(ENV.fetch('UMI_FBIG_PROFILE_TARGETS_PATH'), expected_uid, checksum: false)
  invalid! unless Digest::SHA256.hexdigest(target_bytes) == history.placeholder_targets_sha256
  backup_bytes = protected_bytes(ENV.fetch('UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_PATH'), expected_uid)
  backup_directory = Pathname.new(ENV.fetch('UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_PATH')).dirname
  coordinated_backup = Umi::Fbig::CoordinatedBackupManifest.load(
    manifest_path: ENV.fetch('UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_PATH'),
    checksum_path: ENV.fetch('UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_CHECKSUM_PATH'),
    expected_uid: expected_uid
  )
  invalid! unless
    coordinated_backup.sha256 == Digest::SHA256.hexdigest(backup_bytes) &&
    coordinated_backup.production_database_name == history.production_database &&
    coordinated_backup.image_digest == history.image_digest &&
    coordinated_backup.account_id == history.account_id &&
    coordinated_backup.inbox_id == history.inbox_id &&
    coordinated_backup.facebook_page_id == history.facebook_page_id &&
    coordinated_backup.instagram_business_id == history.instagram_business_id
  inbox = Inbox.find(history.inbox_id)
  invalid! unless
    source_state.account_id == inbox.account_id &&
    source_state.inbox_id == inbox.id &&
    inbox.account_id == history.account_id &&
    inbox.channel.page_id.to_s == history.facebook_page_id.to_s &&
    inbox.channel.instagram_id.to_s == history.instagram_business_id.to_s
  summary = Umi::Fbig::HistoryProfileBackfillService.stable_target_summary(
    inbox,
    platforms: %w[messenger instagram],
    history_configuration: {
      'since' => history.since,
      'before' => history.values.fetch('before'),
      'outbound_policy' => history.outbound_policy
    },
    seed_targets: targets
  )
  approved_by = ENV.fetch('UMI_FBIG_APPROVED_BY')
  approved_at = ENV.fetch('UMI_FBIG_APPROVED_AT')
  values = {
    'schema_version' => '1',
    'authorization_mode' => 'production_first',
    'repository_commit' => history.repository_commit,
    'image_digest' => history.image_digest,
    'production_database_name' => history.production_database,
    'account_id' => history.account_id.to_s,
    'inbox_id' => history.inbox_id.to_s,
    'facebook_page_id' => history.facebook_page_id.to_s,
    'instagram_business_id' => history.instagram_business_id.to_s,
    'production_first_authorization_sha256' => authorization.sha256,
    'coordinated_pre_profile_backup_sha256' => Digest::SHA256.hexdigest(backup_bytes),
    'history_manifest_sha256' => history.sha256,
    'messenger_terminal_history_result_sha256' => terminal.fetch('messenger'),
    'instagram_terminal_history_result_sha256' => terminal.fetch('instagram'),
    'source_profile_state_sha256' => source_state.sha256,
    'messenger_stable_target_count' => summary.dig('messenger', :count).to_s,
    'messenger_stable_target_fingerprint' => summary.dig('messenger', :fingerprint),
    'instagram_stable_target_count' => summary.dig('instagram', :count).to_s,
    'instagram_stable_target_fingerprint' => summary.dig('instagram', :fingerprint),
    'placeholder_targets_sha256' => history.placeholder_targets_sha256,
    'placeholder_target_count' => targets.size.to_s,
    'recovered_thread_targets_sha256' => history.recovered_thread_targets_sha256,
    'platforms' => 'messenger,instagram',
    'graph_delay_ms' => positive_env('UMI_FBIG_PROFILE_GRAPH_DELAY_MS'),
    'max_conversation_pages' => positive_env('UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES'),
    'max_rate_limit_wait_seconds' => positive_env('UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS'),
    'max_avatar_download_bytes' => positive_env('UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES'),
    'clone_terminal_acceptance_sha256' => 'none',
    'clone_profile_evidence_sha256' => 'none',
    'approved_by' => approved_by,
    'approved_at' => approved_at
  }
  bytes = Umi::Fbig::ProductionFirstProfileApproval::FIELD_NAMES.map do |field|
    "#{field}\t#{values.fetch(field)}\n"
  end.join
  Umi::Fbig::ProductionFirstProfileApproval.parse(bytes)
  output = Pathname.new(ENV.fetch('UMI_FBIG_PRODUCTION_FIRST_PROFILE_OUTPUT_DIR'))
  stat = File.lstat(output)
  invalid! unless
    output.absolute? && output.cleanpath.to_s == output.to_s &&
    stat.directory? && !stat.symlink? && stat.uid == expected_uid &&
    (stat.mode & 0o777) == 0o700
  PROFILE_OUTPUTS.each_value do |basename|
    path = output.join(basename)
    checksum = output.join("#{basename}.sha256")
    invalid! if path.exist? || path.symlink? || checksum.exist? || checksum.symlink?
  end
  bundled = {
    PROFILE_OUTPUTS.fetch(:profile_approval) => bytes,
    PROFILE_OUTPUTS.fetch(:authorization) => authorization_bytes,
    PROFILE_OUTPUTS.fetch(:history_index) => history_index_bytes,
    PROFILE_OUTPUTS.fetch(:messenger_terminal) => terminal_bytes.fetch('messenger'),
    PROFILE_OUTPUTS.fetch(:instagram_terminal) => terminal_bytes.fetch('instagram'),
    PROFILE_OUTPUTS.fetch(:coordinated_backup) => backup_bytes,
    PROFILE_OUTPUTS.fetch(:profile_state) => source_state_bytes,
    PROFILE_OUTPUTS.fetch(:profile_targets) => target_bytes
  }
  bundled.each { |basename, content| publish!(output, basename, content) }
  Umi::Fbig::CoordinatedBackupManifest::COMPONENTS.each do |field, basename|
    publish_file!(
      output,
      basename,
      backup_directory.join(basename),
      coordinated_backup.public_send(field),
      expected_uid
    )
  end
rescue StandardError
  warn 'production-first profile approval generation failed'
  exit 1
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity
