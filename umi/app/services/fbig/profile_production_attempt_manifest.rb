# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProfileProductionAttemptManifest
  class InvalidManifest < StandardError; end

  FIELD_NAMES = %w[
    schema_version profile_approval_sha256 image_digest production_database_name platforms dry_run
    pre_attempt_backup_sha256 prestate_sha256 poststate_sha256 avatar_staging_sha256 run_log_sha256
    run_summary_sha256 exit_status started_at finished_at
  ].freeze
  SHA_OR_NONE_FIELDS = %w[
    pre_attempt_backup_sha256 prestate_sha256 poststate_sha256 avatar_staging_sha256 run_summary_sha256
  ].freeze
  SHA_FIELDS = %w[profile_approval_sha256 run_log_sha256].freeze
  SHA_PATTERN = /\A[0-9a-f]{64}\z/

  attr_reader :values, :sha256

  FIELD_NAMES.each { |name| define_method(name) { values.fetch(name) } }

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
  end

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    manifest = canonical_path!(manifest_path, 'fbig-profile-production-attempt-v1.tsv')
    checksum = canonical_path!(checksum_path, 'fbig-profile-production-attempt-v1.tsv.sha256')
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

  class << self
    private

    def validate!(values)
      raise InvalidManifest unless values.fetch('schema_version') == '1'

      SHA_FIELDS.each { |name| raise InvalidManifest unless values.fetch(name).match?(SHA_PATTERN) }
      SHA_OR_NONE_FIELDS.each do |name|
        value = values.fetch(name)
        raise InvalidManifest unless value == 'none' || value.match?(SHA_PATTERN)
      end
      prestate_group = %w[prestate_sha256 poststate_sha256 avatar_staging_sha256].map { |name| values.fetch(name) }
      raise InvalidManifest if values.fetch('pre_attempt_backup_sha256') == 'none' && prestate_group.any? { |value| value != 'none' }

      if values.fetch('exit_status') == '0'
        required = [
          values.fetch('pre_attempt_backup_sha256'),
          *prestate_group,
          values.fetch('run_summary_sha256')
        ]
        raise InvalidManifest unless required.all? { |value| value.match?(SHA_PATTERN) }
      end
      raise InvalidManifest unless values.fetch('image_digest').match?(
        %r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z}
      )
      raise InvalidManifest unless values.fetch('production_database_name').match?(/\A[a-z_][a-z0-9_]*\z/)
      raise InvalidManifest unless values.fetch('platforms').in?(%w[messenger instagram messenger,instagram])
      raise InvalidManifest unless values.fetch('dry_run').in?(%w[true false])

      status = values.fetch('exit_status')
      raise InvalidManifest unless status.match?(/\A(?:0|[1-9][0-9]{0,2})\z/) && status.to_i <= 255

      started_at = canonical_time!(values.fetch('started_at'))
      finished_at = canonical_time!(values.fetch('finished_at'))
      raise InvalidManifest if finished_at < started_at
    end

    def canonical_time!(value)
      parsed = Time.iso8601(value)
      raise InvalidManifest unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value

      parsed.utc
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
