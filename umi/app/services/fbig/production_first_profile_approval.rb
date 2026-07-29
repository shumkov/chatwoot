# frozen_string_literal: true

require 'digest'
require 'pathname'

# Strict artifact parsing is intentionally explicit at every trust boundary.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
class Umi::Fbig::ProductionFirstProfileApproval
  class InvalidApproval < StandardError; end

  FIELD_NAMES = %w[
    schema_version authorization_mode repository_commit image_digest production_database_name
    account_id inbox_id facebook_page_id instagram_business_id production_first_authorization_sha256
    coordinated_pre_profile_backup_sha256 history_manifest_sha256
    messenger_terminal_history_result_sha256 instagram_terminal_history_result_sha256
    source_profile_state_sha256 messenger_stable_target_count messenger_stable_target_fingerprint
    instagram_stable_target_count instagram_stable_target_fingerprint placeholder_targets_sha256
    placeholder_target_count recovered_thread_targets_sha256 platforms graph_delay_ms
    max_conversation_pages max_rate_limit_wait_seconds max_avatar_download_bytes
    clone_terminal_acceptance_sha256 clone_profile_evidence_sha256 approved_by approved_at
  ].freeze
  SHA256_FIELDS = %w[
    production_first_authorization_sha256 coordinated_pre_profile_backup_sha256 history_manifest_sha256
    messenger_terminal_history_result_sha256 instagram_terminal_history_result_sha256
    source_profile_state_sha256 messenger_stable_target_fingerprint instagram_stable_target_fingerprint
    placeholder_targets_sha256 recovered_thread_targets_sha256
  ].freeze
  COUNT_FIELDS = %w[
    messenger_stable_target_count instagram_stable_target_count placeholder_target_count
  ].freeze
  SETTING_FIELDS = %w[
    graph_delay_ms max_conversation_pages max_rate_limit_wait_seconds max_avatar_download_bytes
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
    raise InvalidApproval unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidApproval if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidApproval unless lines.size == FIELD_NAMES.size

    values = {}
    lines.each_with_index do |line, index|
      name, value, extra = line.split("\t", -1)
      raise InvalidApproval if extra || name != FIELD_NAMES.fetch(index)

      values[name] = value
    end
    validate!(values)
    new(values.freeze, Digest::SHA256.hexdigest(text))
  rescue ArgumentError, KeyError
    raise InvalidApproval
  end

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    manifest = canonical_path!(manifest_path, 'fbig-production-first-profile-approval-v1.tsv')
    checksum = canonical_path!(checksum_path, 'fbig-production-first-profile-approval-v1.tsv.sha256')
    raise InvalidApproval unless manifest.dirname == checksum.dirname

    verify_directory!(manifest.dirname, expected_uid)
    bytes = read_artifact!(manifest, expected_uid)
    checksum_bytes = read_artifact!(checksum, expected_uid)
    sha256 = Digest::SHA256.hexdigest(bytes)
    raise InvalidApproval unless checksum_bytes == "#{sha256}  #{manifest.basename}\n"

    parse(bytes)
  rescue SystemCallError
    raise InvalidApproval
  end

  %w[account_id inbox_id facebook_page_id instagram_business_id].each do |field|
    define_method(field) { Integer(values.fetch(field), 10) }
  end
  (COUNT_FIELDS + SETTING_FIELDS).each do |field|
    define_method(field) { Integer(values.fetch(field), 10) }
  end

  def platforms
    values.fetch('platforms').split(',')
  end

  class << self
    private

    def validate!(values)
      raise InvalidApproval unless values.fetch('schema_version') == '1'
      raise InvalidApproval unless values.fetch('authorization_mode') == 'production_first'
      raise InvalidApproval unless values.fetch('repository_commit').match?(/\A[0-9a-f]{40}\z/)
      raise InvalidApproval unless
        values.fetch('image_digest').match?(%r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z})
      raise InvalidApproval unless values.fetch('production_database_name').match?(/\A[a-z_][a-z0-9_]*\z/)

      %w[account_id inbox_id facebook_page_id instagram_business_id].each do |field|
        raise InvalidApproval unless values.fetch(field).match?(/\A[1-9][0-9]*\z/)
      end
      raise InvalidApproval unless values.fetch('inbox_id') == '2'

      SHA256_FIELDS.each { |field| raise InvalidApproval unless values.fetch(field).match?(SHA256_PATTERN) }
      COUNT_FIELDS.each { |field| raise InvalidApproval unless values.fetch(field).match?(/\A(?:0|[1-9][0-9]*)\z/) }
      SETTING_FIELDS.each { |field| raise InvalidApproval unless values.fetch(field).match?(/\A[1-9][0-9]*\z/) }
      raise InvalidApproval unless values.fetch('placeholder_target_count').to_i.positive?
      raise InvalidApproval unless values.fetch('platforms') == 'messenger,instagram'
      raise InvalidApproval unless values.fetch('clone_terminal_acceptance_sha256') == 'none'
      raise InvalidApproval unless values.fetch('clone_profile_evidence_sha256') == 'none'
      raise InvalidApproval if values.fetch('approved_by').blank? || values.fetch('approved_by').bytesize > 255

      canonical_time!(values.fetch('approved_at'))
    end

    def canonical_time!(value)
      parsed = Time.iso8601(value)
      raise InvalidApproval unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value
    rescue ArgumentError
      raise InvalidApproval
    end

    def canonical_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidApproval unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      stat = File.lstat(path)
      raise InvalidApproval unless
        stat.directory? && !stat.symlink? && stat.uid == expected_uid && (stat.mode & 0o777) == 0o700
    end

    def read_artifact!(path, expected_uid)
      bytes = nil
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        raise InvalidApproval unless
          opened_stat.file? && opened_stat.uid == expected_uid && opened_stat.nlink == 1 &&
          (opened_stat.mode & 0o777) == 0o400

        bytes = file.read
      end
      path_stat = File.lstat(path)
      raise InvalidApproval if path_stat.symlink?
      raise InvalidApproval unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino

      bytes
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
