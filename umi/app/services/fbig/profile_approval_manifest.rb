# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProfileApprovalManifest
  class InvalidManifest < StandardError; end

  FIELD_NAMES = %w[
    schema_version history_manifest_sha256 repository_commit image_digest clone_database_name
    production_database_name account_id inbox_id facebook_page_id instagram_business_id platforms
    graph_delay_ms max_conversation_pages max_rate_limit_wait_seconds max_avatar_download_bytes
    placeholder_targets_sha256 predecessor_profile_approval_sha256 predecessor_production_attempt_sha256
    source_profile_state_sha256 messenger_stable_target_count messenger_stable_target_fingerprint
    instagram_stable_target_count instagram_stable_target_fingerprint clone_profile_dry_log_sha256
    clone_profile_dry_summary_sha256 clone_profile_apply_log_sha256 clone_profile_apply_summary_sha256
    clone_profile_idempotency_log_sha256 clone_profile_idempotency_summary_sha256 approved_by approved_at
  ].freeze
  SHA_FIELDS = %w[
    history_manifest_sha256 placeholder_targets_sha256 source_profile_state_sha256
    messenger_stable_target_fingerprint instagram_stable_target_fingerprint
    clone_profile_dry_log_sha256 clone_profile_dry_summary_sha256 clone_profile_apply_log_sha256
    clone_profile_apply_summary_sha256 clone_profile_idempotency_log_sha256 clone_profile_idempotency_summary_sha256
  ].freeze
  ID_FIELDS = %w[account_id inbox_id facebook_page_id instagram_business_id].freeze
  POSITIVE_FIELDS = %w[
    graph_delay_ms max_conversation_pages max_rate_limit_wait_seconds max_avatar_download_bytes
    messenger_stable_target_count instagram_stable_target_count
  ].freeze
  SHA_PATTERN = /\A[0-9a-f]{64}\z/

  attr_reader :values, :sha256

  FIELD_NAMES.each do |name|
    define_method(name) { values.fetch(name) }
  end

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidManifest unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidManifest if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidManifest unless lines.size == FIELD_NAMES.size

    values = {}
    lines.each_with_index do |line, index|
      parts = line.split("\t", -1)
      raise InvalidManifest unless parts.size == 2 && parts.first == FIELD_NAMES.fetch(index)

      values[parts.first] = parts.last
    end
    validate!(values)
    new(values.freeze, Digest::SHA256.hexdigest(text))
  rescue ArgumentError
    raise InvalidManifest
  end

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    manifest = canonical_path!(manifest_path, 'fbig-profile-approval-v1.tsv')
    checksum = canonical_path!(checksum_path, 'fbig-profile-approval-v1.tsv.sha256')
    raise InvalidManifest unless manifest.dirname == checksum.dirname

    verify_directory!(manifest.dirname, expected_uid)
    bytes = read_artifact!(manifest, expected_uid)
    checksum_bytes = read_artifact!(checksum, expected_uid)
    raise InvalidManifest unless checksum_bytes == "#{Digest::SHA256.hexdigest(bytes)}  #{manifest.basename}\n"

    parse(bytes)
  rescue SystemCallError
    raise InvalidManifest
  end

  def initialize(values, sha256)
    @values = values
    @sha256 = sha256
  end

  ID_FIELDS.each do |name|
    define_method(name) { Integer(values.fetch(name), 10) }
  end

  POSITIVE_FIELDS.each do |name|
    define_method(name) { Integer(values.fetch(name), 10) }
  end

  def platforms
    values.fetch('platforms').split(',')
  end

  class << self
    private

    def validate!(values)
      raise InvalidManifest unless values.fetch('schema_version') == '1'
      raise InvalidManifest unless values.fetch('repository_commit').match?(/\A[0-9a-f]{40}\z/)
      raise InvalidManifest unless values.fetch('image_digest').match?(
        %r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z}
      )

      %w[clone_database_name production_database_name].each do |name|
        raise InvalidManifest unless values.fetch(name).match?(/\A[a-z_][a-z0-9_]*\z/)
      end
      raise InvalidManifest if values.fetch('clone_database_name') == values.fetch('production_database_name')

      ID_FIELDS.each { |name| positive_decimal!(values.fetch(name)) }
      raise InvalidManifest unless values.fetch('platforms') == 'messenger,instagram'

      POSITIVE_FIELDS.each { |name| positive_decimal!(values.fetch(name)) }
      SHA_FIELDS.each { |name| raise InvalidManifest unless values.fetch(name).match?(SHA_PATTERN) }
      predecessors = %w[predecessor_profile_approval_sha256 predecessor_production_attempt_sha256].map do |name|
        values.fetch(name)
      end
      raise InvalidManifest unless predecessors == %w[none none]

      approved_by = values.fetch('approved_by')
      raise InvalidManifest if approved_by.strip.empty? || approved_by.bytesize > 255

      canonical_utc_time!(values.fetch('approved_at'))
    end

    def positive_decimal!(value)
      raise InvalidManifest unless value.match?(/\A[1-9][0-9]*\z/)
    end

    def canonical_utc_time!(value)
      parsed = Time.iso8601(value)
      raise InvalidManifest unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value
    rescue ArgumentError
      raise InvalidManifest
    end

    def canonical_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidManifest unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      stat = File.lstat(path)
      raise InvalidManifest unless stat.directory? &&
                                   !stat.symlink? &&
                                   stat.uid == expected_uid &&
                                   (stat.mode & 0o777) == 0o700
    end

    def read_artifact!(path, expected_uid)
      bytes = nil
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        raise InvalidManifest unless opened_stat.file? &&
                                     opened_stat.uid == expected_uid &&
                                     opened_stat.nlink == 1 &&
                                     (opened_stat.mode & 0o777) == 0o400

        bytes = file.read
      end
      stat = File.lstat(path)
      raise InvalidManifest if stat.symlink?
      raise InvalidManifest unless stat.dev == opened_stat.dev && stat.ino == opened_stat.ino

      bytes
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
