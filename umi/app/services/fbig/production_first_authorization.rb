# frozen_string_literal: true

require 'digest'
require 'pathname'

# Strict artifact parsing is intentionally explicit at every trust boundary.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProductionFirstAuthorization
  class InvalidAuthorization < StandardError; end

  FIELD_NAMES = %w[
    schema_version authorization_mode repository_commit image_digest production_database
    account_id inbox_id facebook_page_id instagram_business_id since before outbound_policy profile_mode
    r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
    messenger_count messenger_fingerprint instagram_count instagram_fingerprint
    messenger_unavailable_message_thread_count messenger_unavailable_message_thread_fingerprint
    instagram_unavailable_message_thread_count instagram_unavailable_message_thread_fingerprint
    recovered_thread_targets_sha256 placeholder_targets_sha256 unrecoverable_sidecar_sha256
    unrecoverable_inspector_sha256
    coordinated_backup_manifest_sha256
    history_program_sha256 profile_program_sha256 final_audit_program_sha256
    delivery_audit_program_sha256 delivery_checkpoint_program_sha256 profile_wrapper_sha256
    storage_helper_sha256 recovered_target_generator_sha256 authorization_generator_sha256
    history_revision_generator_sha256 profile_approval_generator_sha256
    normal_terminal_acceptance_sha256 normal_dry_pair_sha256 predecessor_authorization_sha256
    predecessor_history_result_sha256 predecessor_terminal_summary_sha256 predecessor_delta_sha256
    predecessor_expanded_baseline_sha256 current_state_backup_sha256 approved_by created_at
  ].freeze
  SHA256_FIELDS = %w[
    r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
    messenger_fingerprint instagram_fingerprint messenger_unavailable_message_thread_fingerprint
    instagram_unavailable_message_thread_fingerprint recovered_thread_targets_sha256 placeholder_targets_sha256
    unrecoverable_inspector_sha256 coordinated_backup_manifest_sha256
    history_program_sha256 profile_program_sha256 final_audit_program_sha256
    delivery_audit_program_sha256 delivery_checkpoint_program_sha256 profile_wrapper_sha256
    storage_helper_sha256 recovered_target_generator_sha256 authorization_generator_sha256
    history_revision_generator_sha256 profile_approval_generator_sha256
    unrecoverable_sidecar_sha256
  ].freeze
  OPTIONAL_SHA256_FIELDS = %w[
    normal_terminal_acceptance_sha256 normal_dry_pair_sha256 predecessor_authorization_sha256
    predecessor_history_result_sha256 predecessor_terminal_summary_sha256 predecessor_delta_sha256
    predecessor_expanded_baseline_sha256 current_state_backup_sha256
  ].freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/

  attr_reader :values, :sha256

  FIELD_NAMES.each { |name| define_method(name) { values.fetch(name) } }

  def initialize(values, sha256)
    @values = values
    @sha256 = sha256
  end

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidAuthorization unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidAuthorization if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidAuthorization unless lines.size == FIELD_NAMES.size

    values = {}
    lines.each_with_index do |line, index|
      name, value, extra = line.split("\t", -1)
      raise InvalidAuthorization if extra || name != FIELD_NAMES.fetch(index)

      values[name] = value
    end
    validate!(values)
    new(values.freeze, Digest::SHA256.hexdigest(text))
  rescue ArgumentError, KeyError
    raise InvalidAuthorization
  end

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    manifest = canonical_path!(manifest_path, 'fbig-production-first-authorization-v1.tsv')
    checksum = canonical_path!(checksum_path, 'fbig-production-first-authorization-v1.tsv.sha256')
    raise InvalidAuthorization unless manifest.dirname == checksum.dirname

    verify_directory!(manifest.dirname, expected_uid)
    bytes = read_artifact!(manifest, expected_uid)
    checksum_bytes = read_artifact!(checksum, expected_uid)
    sha256 = Digest::SHA256.hexdigest(bytes)
    raise InvalidAuthorization unless checksum_bytes == "#{sha256}  #{manifest.basename}\n"

    parse(bytes)
  rescue SystemCallError
    raise InvalidAuthorization
  end

  %w[account_id inbox_id facebook_page_id instagram_business_id].each do |field|
    define_method(field) { Integer(values.fetch(field), 10) }
  end

  def before
    self.class.send(:canonical_time!, values.fetch('before'))
  end

  class << self
    private

    def validate!(values)
      exact!(values, 'schema_version', '1')
      exact!(values, 'authorization_mode', 'production_first')
      pattern!(values, 'repository_commit', /\A[0-9a-f]{40}\z/)
      pattern!(values, 'image_digest', %r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z})
      pattern!(values, 'production_database', /\A[a-z_][a-z0-9_]*\z/)
      %w[account_id inbox_id facebook_page_id instagram_business_id].each do |field|
        pattern!(values, field, /\A[1-9][0-9]*\z/)
      end
      exact!(values, 'inbox_id', '2')
      exact!(values, 'since', 'all')
      canonical_time!(values.fetch('before'))
      exact!(values, 'outbound_policy', 'pre_presence')
      exact!(values, 'profile_mode', 'defer')
      %w[messenger_count instagram_count].each { |field| pattern!(values, field, /\A(?:0|[1-9][0-9]*)\z/) }
      SHA256_FIELDS.each { |field| pattern!(values, field, SHA256_PATTERN) }
      OPTIONAL_SHA256_FIELDS.each { |field| optional_sha!(values, field) }
      %w[messenger instagram].each do |platform|
        empty = Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: platform, records: [])
        exact!(values, "#{platform}_unavailable_message_thread_count", '0')
        exact!(values, "#{platform}_unavailable_message_thread_fingerprint", empty.fingerprint)
      end
      %w[normal_terminal_acceptance_sha256 normal_dry_pair_sha256].each { |field| exact!(values, field, 'none') }
      predecessor_values = OPTIONAL_SHA256_FIELDS.drop(2).map { |field| values.fetch(field) }
      valid_predecessors = predecessor_values.all?('none') ||
                           predecessor_values.all? { |value| value.match?(SHA256_PATTERN) }
      raise InvalidAuthorization unless valid_predecessors
      raise InvalidAuthorization if values.fetch('approved_by').blank? || values.fetch('approved_by').bytesize > 255

      canonical_time!(values.fetch('created_at'))
    end

    def exact!(values, field, expected)
      raise InvalidAuthorization unless values.fetch(field) == expected
    end

    def pattern!(values, field, pattern)
      raise InvalidAuthorization unless values.fetch(field).match?(pattern)
    end

    def optional_sha!(values, field)
      value = values.fetch(field)
      raise InvalidAuthorization unless value == 'none' || value.match?(SHA256_PATTERN)
    end

    def canonical_time!(value)
      parsed = Time.iso8601(value)
      raise InvalidAuthorization unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value

      parsed.utc
    rescue ArgumentError
      raise InvalidAuthorization
    end

    def canonical_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidAuthorization unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      stat = File.lstat(path)
      raise InvalidAuthorization unless
        stat.directory? && !stat.symlink? && stat.uid == expected_uid && (stat.mode & 0o777) == 0o700
    end

    def read_artifact!(path, expected_uid)
      bytes = nil
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        raise InvalidAuthorization unless
          opened_stat.file? && opened_stat.uid == expected_uid && opened_stat.nlink == 1 &&
          (opened_stat.mode & 0o777) == 0o400

        bytes = file.read
      end
      path_stat = File.lstat(path)
      raise InvalidAuthorization if path_stat.symlink?
      raise InvalidAuthorization unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino

      bytes
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
