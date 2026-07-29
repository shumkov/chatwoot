# frozen_string_literal: true

require 'digest'
require 'pathname'

# Strict artifact parsing is intentionally explicit at every trust boundary.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProductionFirstHistoryApproval
  class InvalidApproval < StandardError; end

  FIELD_NAMES = %w[
    schema_version authorization_mode repository_commit image_digest production_database
    account_id inbox_id facebook_page_id instagram_business_id since before outbound_policy profile_mode
    coordinated_backup_manifest_sha256 production_first_authorization_sha256
    recovered_thread_targets_sha256 placeholder_targets_sha256 unrecoverable_sidecar_sha256
    messenger_count messenger_fingerprint instagram_count instagram_fingerprint
    messenger_unavailable_message_thread_count messenger_unavailable_message_thread_fingerprint
    instagram_unavailable_message_thread_count instagram_unavailable_message_thread_fingerprint
    r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
    revision_platform predecessor_approval_sha256 predecessor_attempt_result_sha256
    predecessor_run_summary_sha256 predecessor_delta_sha256 approved_by approved_at
  ].freeze
  SHA256_FIELDS = %w[
    coordinated_backup_manifest_sha256 production_first_authorization_sha256 recovered_thread_targets_sha256
    placeholder_targets_sha256 unrecoverable_sidecar_sha256 messenger_fingerprint instagram_fingerprint
    messenger_unavailable_message_thread_fingerprint instagram_unavailable_message_thread_fingerprint
    r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256 r2_probe_summary_sha256
  ].freeze
  PREDECESSOR_FIELDS = %w[
    predecessor_approval_sha256 predecessor_attempt_result_sha256 predecessor_run_summary_sha256
    predecessor_delta_sha256
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
    manifest = canonical_path!(manifest_path, 'fbig-production-first-history-approval-v1.tsv')
    checksum = canonical_path!(checksum_path, 'fbig-production-first-history-approval-v1.tsv.sha256')
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
    self.class.send(:canonical_time!, values.fetch('before'))
  end

  def accepted_contentless(platforms)
    platforms.index_with do |platform|
      Umi::Fbig::ContentlessFingerprint::Result.new(
        count: Integer(values.fetch("#{platform}_count"), 10),
        fingerprint: values.fetch("#{platform}_fingerprint")
      )
    end
  end

  def accepted_unavailable_message_threads(platforms)
    platforms.index_with do |platform|
      Umi::Fbig::UnavailableMessageThreadFingerprint::Result.new(
        count: Integer(values.fetch("#{platform}_unavailable_message_thread_count"), 10),
        fingerprint: values.fetch("#{platform}_unavailable_message_thread_fingerprint")
      )
    end
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
      %w[messenger instagram].each do |platform|
        empty = Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: platform, records: [])
        exact!(values, "#{platform}_unavailable_message_thread_count", '0')
        exact!(values, "#{platform}_unavailable_message_thread_fingerprint", empty.fingerprint)
      end
      revision = values.fetch('revision_platform')
      raise InvalidApproval unless revision.in?(%w[none messenger instagram])

      predecessors = PREDECESSOR_FIELDS.map { |field| values.fetch(field) }
      valid_predecessors = if revision == 'none'
                             predecessors.all?('none')
                           else
                             predecessors.all? { |value| value.match?(SHA256_PATTERN) }
                           end
      raise InvalidApproval unless valid_predecessors
      raise InvalidApproval if values.fetch('approved_by').blank? || values.fetch('approved_by').bytesize > 255

      canonical_time!(values.fetch('approved_at'))
    end

    def exact!(values, field, expected)
      raise InvalidApproval unless values.fetch(field) == expected
    end

    def pattern!(values, field, pattern)
      raise InvalidApproval unless values.fetch(field).match?(pattern)
    end

    def canonical_time!(value)
      parsed = Time.iso8601(value)
      raise InvalidApproval unless parsed.utc_offset.zero? && parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == value

      parsed.utc
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
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
