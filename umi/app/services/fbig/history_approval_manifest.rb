# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
class Umi::Fbig::HistoryApprovalManifest
  class InvalidManifest < StandardError; end

  FIELD_NAMES = %w[
    schema_version repository_commit image_digest clone_backup_id clone_database_name
    database_dump_sha256 source_storage_manifest_sha256 restored_storage_manifest_sha256
    account_id inbox_id facebook_page_id instagram_business_id since before outbound_policy
    profile_mode messenger_count messenger_fingerprint instagram_count instagram_fingerprint
    messenger_unavailable_message_thread_count messenger_unavailable_message_thread_fingerprint
    instagram_unavailable_message_thread_count instagram_unavailable_message_thread_fingerprint
    placeholder_targets_sha256 source_dry_log_sha256 source_dry_summary_sha256 approved_by approved_at
  ].freeze
  SHA256_FIELDS = %w[
    database_dump_sha256 source_storage_manifest_sha256 restored_storage_manifest_sha256
    placeholder_targets_sha256 source_dry_log_sha256 source_dry_summary_sha256
  ].freeze
  ID_FIELDS = %w[account_id inbox_id facebook_page_id instagram_business_id].freeze
  COUNT_FIELDS = %w[
    messenger_count instagram_count
    messenger_unavailable_message_thread_count instagram_unavailable_message_thread_count
  ].freeze
  FINGERPRINT_FIELDS = %w[
    messenger_fingerprint instagram_fingerprint
    messenger_unavailable_message_thread_fingerprint instagram_unavailable_message_thread_fingerprint
  ].freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/
  COUNT_PATTERN = /\A(?:0|[1-9][0-9]*)\z/
  MAX_COUNT = 2_147_483_647

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
      raise InvalidManifest unless parts.size == 2

      name, value = parts
      raise InvalidManifest unless name == FIELD_NAMES.fetch(index)

      values[name] = value
    end
    validate!(values)
    new(values.freeze, Digest::SHA256.hexdigest(text))
  rescue ArgumentError
    raise InvalidManifest
  end

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    manifest = canonical_artifact_path!(manifest_path, 'fbig-approval-v2.tsv')
    checksum = canonical_artifact_path!(checksum_path, 'fbig-approval-v2.tsv.sha256')
    raise InvalidManifest unless manifest.dirname == checksum.dirname

    verify_directory!(manifest.dirname, expected_uid)
    manifest_bytes = read_locked_artifact!(manifest, expected_uid)
    checksum_bytes = read_locked_artifact!(checksum, expected_uid)
    expected_line = "#{Digest::SHA256.hexdigest(manifest_bytes)}  #{manifest.basename}\n"
    raise InvalidManifest unless checksum_bytes == expected_line

    parse(manifest_bytes)
  rescue SystemCallError
    raise InvalidManifest
  end

  def initialize(values, sha256)
    @values = values
    @sha256 = sha256
  end

  def account_id
    Integer(values.fetch('account_id'), 10)
  end

  def inbox_id
    Integer(values.fetch('inbox_id'), 10)
  end

  def facebook_page_id
    Integer(values.fetch('facebook_page_id'), 10)
  end

  def instagram_business_id
    Integer(values.fetch('instagram_business_id'), 10)
  end

  def before
    self.class.send(:canonical_utc_time!, values.fetch('before'))
  end

  def approved_at
    self.class.send(:canonical_utc_time!, values.fetch('approved_at'))
  end

  def accepted_contentless(platforms)
    platforms.index_with do |platform|
      Umi::Fbig::ContentlessFingerprint::Result.new(
        count: Integer(values.fetch("#{platform}_count"), 10),
        fingerprint: values.fetch("#{platform}_fingerprint")
      )
    end
  rescue KeyError
    raise InvalidManifest
  end

  def accepted_unavailable_message_threads(platforms)
    platforms.index_with do |platform|
      Umi::Fbig::UnavailableMessageThreadFingerprint::Result.new(
        count: Integer(values.fetch("#{platform}_unavailable_message_thread_count"), 10),
        fingerprint: values.fetch("#{platform}_unavailable_message_thread_fingerprint")
      )
    end
  rescue KeyError
    raise InvalidManifest
  end

  class << self
    private

    def canonical_artifact_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidManifest unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      stat = File.lstat(path)
      valid = stat.directory? &&
              !stat.symlink? &&
              stat.uid == expected_uid &&
              (stat.mode & 0o777) == 0o700
      raise InvalidManifest unless valid
    end

    def read_locked_artifact!(path, expected_uid)
      bytes = nil
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        valid = opened_stat.file? &&
                opened_stat.uid == expected_uid &&
                opened_stat.nlink == 1 &&
                (opened_stat.mode & 0o777) == 0o400
        raise InvalidManifest unless valid

        bytes = file.read
      end
      path_stat = File.lstat(path)
      raise InvalidManifest if path_stat.symlink?
      raise InvalidManifest unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino

      bytes
    end

    def validate!(values)
      exact!(values, 'schema_version', '2')
      pattern!(values, 'repository_commit', /\A[0-9a-f]{40}\z/)
      pattern!(values, 'image_digest', %r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z})
      pattern!(values, 'clone_backup_id', /\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z/)
      pattern!(values, 'clone_database_name', /\A[a-z_][a-z0-9_]*\z/)
      SHA256_FIELDS.each { |name| pattern!(values, name, SHA256_PATTERN) }
      ID_FIELDS.each { |name| positive_decimal!(values, name) }
      exact!(values, 'since', 'all')
      canonical_utc_time!(values.fetch('before'))
      exact!(values, 'outbound_policy', 'pre_presence')
      exact!(values, 'profile_mode', 'defer')
      COUNT_FIELDS.each { |name| count!(values, name) }
      FINGERPRINT_FIELDS.each { |name| pattern!(values, name, SHA256_PATTERN) }
      empty_messenger = Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: [])
      exact!(values, 'messenger_unavailable_message_thread_count', empty_messenger.count.to_s)
      exact!(values, 'messenger_unavailable_message_thread_fingerprint', empty_messenger.fingerprint)
      approved_by = values.fetch('approved_by')
      raise InvalidManifest if approved_by.strip.empty? || approved_by.bytesize > 255

      canonical_utc_time!(values.fetch('approved_at'))
    end

    def exact!(values, name, expected)
      raise InvalidManifest unless values.fetch(name) == expected
    end

    def pattern!(values, name, pattern)
      raise InvalidManifest unless values.fetch(name).match?(pattern)
    end

    def positive_decimal!(values, name)
      value = values.fetch(name)
      raise InvalidManifest unless value.match?(/\A[1-9][0-9]*\z/)
    end

    def count!(values, name)
      value = values.fetch(name)
      raise InvalidManifest unless value.match?(COUNT_PATTERN) && Integer(value, 10) <= MAX_COUNT
    end

    def canonical_utc_time!(value)
      parsed = Time.iso8601(value)
      raise InvalidManifest unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value

      parsed.utc
    rescue ArgumentError
      raise InvalidManifest
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
