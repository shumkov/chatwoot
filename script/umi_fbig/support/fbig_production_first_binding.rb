# frozen_string_literal: true

require 'digest'
require 'pathname'

FIELDS = {
  'history' => %w[
    schema_version label operation platforms require_zero_writes candidate_commit
    candidate_image stack_dir compose_file compose_file_sha256 compose_project
    rails_service sidekiq_service production_database audit_root inbox_id
    history_approval history_approval_checksum history_approval_sha256
    acceptance_manifest acceptance_checksum acceptance_sha256
    pre_history_backup_manifest pre_history_backup_checksum
    pre_history_backup_sha256 max_download_bytes ack_single_conversation_reopen
    graph_delay_ms max_conversation_pages max_message_pages dry_result_1
    dry_result_1_checksum dry_result_2 dry_result_2_checksum
    predecessor_result predecessor_checksum production_lock
  ],
  'profile' => %w[
    schema_version label profile_phase platforms dry_run require_zero_writes
    candidate_commit candidate_image stack_dir production_database audit_root
    inbox_id history_approval history_approval_checksum history_approval_sha256
    profile_approval profile_approval_checksum profile_approval_sha256
    profile_targets profile_targets_sha256 acceptance_manifest
    acceptance_checksum acceptance_sha256 profile_wrapper
    profile_wrapper_sha256 storage_helper storage_helper_sha256
    profile_attempt_root profile_backup_root
    predecessor_result predecessor_checksum predecessor_audit
    predecessor_audit_checksum before_checkpoint before_checkpoint_checksum
    production_lock
  ],
  'delivery_audit' => %w[
    schema_version authorization_mode authorization_manifest
    authorization_checksum authorization_sha256 label candidate_commit
    candidate_image acceptance_sha256 audit_root attempt_result
    attempt_result_checksum before_checkpoint before_checkpoint_checksum
    after_checkpoint after_checkpoint_checksum predecessor_audit
    predecessor_audit_checksum production_lock
  ],
  'delivery_checkpoint' => %w[
    schema_version authorization_mode authorization_manifest
    authorization_checksum authorization_sha256
    candidate_commit candidate_image service_source_sha256
    stack_dir compose_file compose_file_sha256 compose_project rails_service
    sidekiq_service production_database audit_root inbox_id page_id
    instagram_business_id history_cutoff predecessor_manifest
    predecessor_checksum production_lock
  ],
  'final_audit' => %w[
    schema_version authorization_mode authorization_manifest
    authorization_checksum authorization_sha256 candidate_commit candidate_image
    stack_dir compose_file compose_file_sha256 compose_project rails_service
    sidekiq_service production_database audit_root inbox_id acceptance_manifest
    acceptance_checksum acceptance_sha256 history_approval
    history_approval_checksum history_approval_sha256 profile_approval
    profile_approval_checksum profile_approval_sha256 profile_targets
    profile_targets_sha256 profile_wrapper_sha256 storage_helper_sha256
    unrecoverable_sidecar unrecoverable_sidecar_checksum
    unrecoverable_sidecar_sha256 pre_history_backup
    pre_history_backup_checksum pre_history_backup_sha256 history_result_index
    history_result_index_checksum history_result_index_sha256
    profile_result_index profile_result_index_checksum profile_result_index_sha256
    checkpoint_index checkpoint_index_checksum checkpoint_index_sha256
    messenger_dry_1 messenger_dry_1_checksum messenger_dry_2
    messenger_dry_2_checksum instagram_dry_1 instagram_dry_1_checksum
    instagram_dry_2 instagram_dry_2_checksum messenger_terminal_result
    messenger_terminal_checksum instagram_terminal_result
    instagram_terminal_checksum final_profile_result
    final_profile_result_checksum final_profile_audit
    final_profile_audit_checksum first_checkpoint first_checkpoint_checksum
    final_checkpoint final_checkpoint_checksum production_lock
  ]
}.freeze

def invalid!
  raise 'production-first binding inputs are invalid'
end

def publish!(directory, basename, bytes)
  artifact = directory.join(basename)
  checksum = directory.join("#{basename}.sha256")
  invalid! if artifact.exist? || artifact.symlink? || checksum.exist? || checksum.symlink?
  [[artifact, bytes], [checksum, "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n"]].each do |destination, content|
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
  kind = ENV.fetch('UMI_FBIG_BINDING_KIND')
  fields = FIELDS.fetch(kind)
  basename = ENV.fetch('UMI_FBIG_BINDING_BASENAME')
  invalid! unless basename.match?(/\Afbig-[a-z0-9][a-z0-9-]{1,96}-binding-v1\.tsv\z/)
  values = fields.to_h do |field|
    value = if field == 'schema_version'
              '1'
            else
              ENV.fetch("UMI_FBIG_BIND_#{field.upcase}")
            end
    invalid! if value.empty? || value.include?("\t") || value.include?("\r") || value.include?("\n")
    [field, value]
  end
  invalid! if kind != 'history' && kind != 'profile' && values.fetch('authorization_mode') != 'production_first'
  bytes = fields.map { |field| "#{field}\t#{values.fetch(field)}\n" }.join
  output = Pathname.new(ENV.fetch('UMI_FBIG_BINDING_OUTPUT_DIR'))
  stat = File.lstat(output)
  invalid! unless
    output.absolute? && output.cleanpath.to_s == output.to_s &&
    stat.directory? && !stat.symlink? && stat.uid == expected_uid &&
    (stat.mode & 0o777) == 0o700
  publish!(output, basename, bytes)
rescue StandardError
  warn 'production-first binding generation failed'
  exit 1
end
