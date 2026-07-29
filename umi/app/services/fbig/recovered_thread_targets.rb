# frozen_string_literal: true

require 'digest'
require 'pathname'

# Strict artifact parsing is intentionally explicit at every trust boundary.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::RecoveredThreadTargets
  Result = Data.define(:platform, :digests, :sha256, :values)

  class InvalidTargets < StandardError; end

  FIELD_NAMES = %w[
    schema_version platform target_count target_digest_1 target_digest_2
    source_acceptance_id source_repository_commit source_image_digest source_invocation_id
    source_acceptance_binding_sha256 source_launch_manifest_sha256 source_probe_log_sha256
    source_probe_summary_sha256 generator_sha256
  ].freeze
  SHA256_FIELDS = %w[
    target_digest_1 target_digest_2 source_acceptance_binding_sha256 source_launch_manifest_sha256
    source_probe_log_sha256 source_probe_summary_sha256 generator_sha256
  ].freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/

  def self.digest(platform:, thread_id:)
    raise ArgumentError, 'unsupported platform' unless platform.in?(%w[messenger instagram])

    valid_id = thread_id.is_a?(String) &&
               thread_id.valid_encoding? &&
               thread_id.encoding.in?([Encoding::UTF_8, Encoding::US_ASCII]) &&
               thread_id.present? &&
               thread_id.bytesize <= ApplicationRecord::MAX_TEXT_COLUMN_LENGTH
    raise ArgumentError, 'invalid thread id' unless valid_id

    Umi::Fbig::TypedValueDigest.hexdigest(
      {
        'domain' => 'umi-fbig-recovered-thread-target-v1',
        'platform' => platform,
        'thread_id' => thread_id
      }
    )
  end

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidTargets unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidTargets if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidTargets unless lines.size == FIELD_NAMES.size

    values = {}
    lines.each_with_index do |line, index|
      name, value, extra = line.split("\t", -1)
      raise InvalidTargets if extra || name != FIELD_NAMES.fetch(index)

      values[name] = value
    end
    validate!(values)
    digests = values.values_at('target_digest_1', 'target_digest_2').freeze
    Result.new(
      platform: values.fetch('platform'),
      digests: digests,
      sha256: Digest::SHA256.hexdigest(text),
      values: values.freeze
    )
  rescue ArgumentError, KeyError
    raise InvalidTargets
  end

  def self.load(manifest_path:, checksum_path:, expected_sha256:, expected_uid: 0)
    manifest = canonical_artifact_path!(manifest_path, 'fbig-recovered-thread-targets-v1.tsv')
    checksum = canonical_artifact_path!(checksum_path, 'fbig-recovered-thread-targets-v1.tsv.sha256')
    raise InvalidTargets unless manifest.dirname == checksum.dirname
    raise InvalidTargets unless expected_sha256.to_s.match?(SHA256_PATTERN)

    verify_directory!(manifest.dirname, expected_uid)
    manifest_bytes = read_locked_artifact!(manifest, expected_uid)
    checksum_bytes = read_locked_artifact!(checksum, expected_uid)
    actual_sha256 = Digest::SHA256.hexdigest(manifest_bytes)
    raise InvalidTargets unless actual_sha256 == expected_sha256
    raise InvalidTargets unless checksum_bytes == "#{actual_sha256}  #{manifest.basename}\n"

    parse(manifest_bytes)
  rescue SystemCallError
    raise InvalidTargets
  end

  class << self
    private

    def validate!(values)
      raise InvalidTargets unless values.fetch('schema_version') == '1'
      raise InvalidTargets unless values.fetch('platform') == 'instagram'
      raise InvalidTargets unless values.fetch('target_count') == '2'

      SHA256_FIELDS.each do |field|
        raise InvalidTargets unless values.fetch(field).match?(SHA256_PATTERN)
      end
      digests = values.values_at('target_digest_1', 'target_digest_2')
      raise InvalidTargets unless digests == digests.sort_by(&:b) && digests.uniq.size == 2
      raise InvalidTargets unless values.fetch('source_acceptance_id').match?(/\A[a-z0-9][a-z0-9.-]{1,127}\z/)
      raise InvalidTargets unless values.fetch('source_repository_commit').match?(/\A[0-9a-f]{40}\z/)
      raise InvalidTargets unless
        values.fetch('source_image_digest').match?(%r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z})
      raise InvalidTargets unless values.fetch('source_invocation_id').match?(/\A[0-9a-f]{32}\z/)
    end

    def canonical_artifact_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidTargets unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      stat = File.lstat(path)
      valid = stat.directory? && !stat.symlink? && stat.uid == expected_uid && (stat.mode & 0o777) == 0o700
      raise InvalidTargets unless valid
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
        raise InvalidTargets unless valid

        bytes = file.read
      end
      path_stat = File.lstat(path)
      raise InvalidTargets if path_stat.symlink?
      raise InvalidTargets unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino

      bytes
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
