# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
class Umi::Fbig::CoordinatedBackupManifest
  class InvalidManifest < StandardError; end

  FIELD_NAMES = %w[
    schema_version backup_id production_database_name image_digest account_id
    inbox_id facebook_page_id instagram_business_id database_dump_sha256
    database_restore_list_sha256 storage_archive_sha256 storage_manifest_sha256
    messenger_history_state_sha256 instagram_history_state_sha256 created_at
  ].freeze
  COMPONENTS = {
    'database_dump_sha256' => 'database.dump',
    'database_restore_list_sha256' => 'database.restore.list',
    'storage_archive_sha256' => 'storage.tar',
    'storage_manifest_sha256' => 'storage.manifest',
    'messenger_history_state_sha256' => 'fbig-history-backup-messenger-state-v1.tsv',
    'instagram_history_state_sha256' => 'fbig-history-backup-instagram-state-v1.tsv'
  }.freeze
  ALLOWED_BASENAMES = %w[
    fbig-coordinated-backup-v1.tsv
    fbig-coordinated-pre-profile-backup-v1.tsv
  ].freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/

  attr_reader :values, :sha256

  FIELD_NAMES.each { |name| define_method(name) { values.fetch(name) } }
  %w[account_id inbox_id facebook_page_id instagram_business_id].each do |field|
    define_method(field) { Integer(values.fetch(field), 10) }
  end

  def initialize(values, sha256)
    @values = values
    @sha256 = sha256
  end

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    basename = Pathname.new(manifest_path.to_s).basename.to_s
    raise InvalidManifest unless ALLOWED_BASENAMES.include?(basename)

    manifest = canonical_path!(manifest_path, basename)
    checksum = canonical_path!(checksum_path, "#{basename}.sha256")
    raise InvalidManifest unless manifest.dirname == checksum.dirname

    verify_directory!(manifest.dirname, expected_uid)
    bytes = read_artifact!(manifest, expected_uid)
    checksum_bytes = read_artifact!(checksum, expected_uid)
    sha256 = Digest::SHA256.hexdigest(bytes)
    raise InvalidManifest unless checksum_bytes == "#{sha256}  #{manifest.basename}\n"

    parsed = parse(bytes)
    COMPONENTS.each do |field, component_basename|
      component = manifest.dirname.join(component_basename)
      raise InvalidManifest unless digest_artifact!(component, expected_uid) == parsed.public_send(field)
    end
    validate_history_snapshots!(manifest.dirname, parsed, expected_uid)
    parsed
  rescue SystemCallError, Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot
    raise InvalidManifest
  end

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidManifest unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidManifest if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidManifest unless lines.size == FIELD_NAMES.size

    values = {}
    lines.each_with_index do |line, index|
      field, value, extra = line.split("\t", -1)
      raise InvalidManifest if extra || field != FIELD_NAMES.fetch(index) || value.empty?

      values[field] = value
    end
    validate!(values)
    new(values.freeze, Digest::SHA256.hexdigest(text))
  rescue ArgumentError, KeyError
    raise InvalidManifest
  end

  class << self
    private

    def validate!(values)
      raise InvalidManifest unless values.fetch('schema_version') == '1'
      raise InvalidManifest unless values.fetch('backup_id').match?(/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z/)
      raise InvalidManifest unless values.fetch('production_database_name').match?(/\A[a-z_][a-z0-9_]*\z/)
      raise InvalidManifest unless
        values.fetch('image_digest').match?(%r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z})

      %w[account_id inbox_id facebook_page_id instagram_business_id].each do |field|
        raise InvalidManifest unless values.fetch(field).match?(/\A[1-9][0-9]*\z/)
      end
      raise InvalidManifest unless values.fetch('inbox_id') == '2'

      COMPONENTS.each_key do |field|
        raise InvalidManifest unless values.fetch(field).match?(SHA256_PATTERN)
      end
      timestamp = Time.iso8601(values.fetch('created_at'))
      raise InvalidManifest unless timestamp.utc_offset.zero? &&
                                   timestamp.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == values.fetch('created_at')
    end

    def validate_history_snapshots!(directory, manifest, expected_uid)
      %w[messenger instagram].each do |platform|
        basename = "fbig-history-backup-#{platform}-state-v1.tsv"
        snapshot = Umi::Fbig::HistoryStateSnapshot.load(
          path: directory.join(basename),
          checksum_path: directory.join("#{basename}.sha256"),
          expected_uid: expected_uid
        )
        raise InvalidManifest unless
          snapshot.account_id == manifest.account_id && snapshot.inbox_id == manifest.inbox_id &&
          snapshot.platforms == [platform]
      end
    end

    def canonical_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidManifest unless
        path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      stat = File.lstat(path)
      raise InvalidManifest unless
        stat.directory? && !stat.symlink? && stat.uid == expected_uid &&
        (stat.mode & 0o777) == 0o700
    end

    def read_artifact!(path, expected_uid)
      bytes = nil
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        raise InvalidManifest unless
          opened_stat.file? && opened_stat.uid == expected_uid && opened_stat.nlink == 1 &&
          (opened_stat.mode & 0o777) == 0o400

        bytes = file.read
      end
      path_stat = File.lstat(path)
      raise InvalidManifest if path_stat.symlink?
      raise InvalidManifest unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino

      bytes
    end

    def digest_artifact!(path, expected_uid)
      digest = Digest::SHA256.new
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        raise InvalidManifest unless
          opened_stat.file? && opened_stat.uid == expected_uid && opened_stat.nlink == 1 &&
          (opened_stat.mode & 0o777) == 0o400

        while (chunk = file.read(1024 * 1024))
          digest << chunk
        end
      end
      path_stat = File.lstat(path)
      raise InvalidManifest if path_stat.symlink?
      raise InvalidManifest unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino

      digest.hexdigest
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
