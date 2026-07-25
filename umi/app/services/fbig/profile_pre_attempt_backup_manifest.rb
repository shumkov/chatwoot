# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProfilePreAttemptBackupManifest
  class InvalidManifest < StandardError; end

  FIELD_NAMES = %w[
    schema_version backup_id production_database_name image_digest database_dump_sha256
    database_restore_list_sha256 storage_archive_sha256 storage_manifest_sha256 created_at
  ].freeze
  COMPONENTS = {
    'database_dump_sha256' => 'database.dump',
    'database_restore_list_sha256' => 'database.restore.list',
    'storage_archive_sha256' => 'storage.tar',
    'storage_manifest_sha256' => 'storage.manifest'
  }.freeze

  attr_reader :values, :sha256, :directory

  FIELD_NAMES.each { |name| define_method(name) { values.fetch(name) } }

  def self.load(manifest_path:, checksum_path:, expected_uid: 0)
    manifest = Pathname.new(manifest_path.to_s)
    checksum = Pathname.new(checksum_path.to_s)
    raise InvalidManifest unless manifest.absolute? &&
                                 manifest.cleanpath.to_s == manifest_path.to_s &&
                                 manifest.basename.to_s == 'fbig-profile-pre-attempt-backup-v1.tsv' &&
                                 checksum == Pathname.new("#{manifest_path}.sha256")

    directory_stat = File.lstat(manifest.dirname)
    raise InvalidManifest unless directory_stat.directory? &&
                                 !directory_stat.symlink? &&
                                 directory_stat.uid == expected_uid &&
                                 (directory_stat.mode & 0o777) == 0o700

    bytes = read_locked!(manifest, expected_uid)
    checksum_bytes = read_locked!(checksum, expected_uid)
    digest = Digest::SHA256.hexdigest(bytes)
    raise InvalidManifest unless checksum_bytes == "#{digest}  #{manifest.basename}\n"

    parsed = parse(bytes, digest, manifest.dirname)
    expected_directory = "fbig-profile-pre-attempt-#{parsed.backup_id}"
    raise InvalidManifest unless manifest.dirname.basename.to_s == expected_directory

    COMPONENTS.each do |field, basename|
      component = manifest.dirname.join(basename)
      raise InvalidManifest unless digest_locked!(component, expected_uid) == parsed.public_send(field)
    end
    parsed
  rescue SystemCallError
    raise InvalidManifest
  end

  def self.parse(bytes, digest = nil, directory = nil)
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
    new(values.freeze, digest || Digest::SHA256.hexdigest(text), directory)
  end

  def initialize(values, sha256, directory)
    @values = values
    @sha256 = sha256
    @directory = directory
  end

  class << self
    private

    def validate!(values)
      raise InvalidManifest unless values.fetch('schema_version') == '1'
      raise InvalidManifest unless values.fetch('backup_id').match?(/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z/)
      raise InvalidManifest unless values.fetch('production_database_name').match?(/\A[a-z_][a-z0-9_]*\z/)
      raise InvalidManifest unless values.fetch('image_digest').match?(
        %r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z}
      )

      COMPONENTS.each_key do |field|
        raise InvalidManifest unless values.fetch(field).match?(/\A[0-9a-f]{64}\z/)
      end
      parsed = Time.iso8601(values.fetch('created_at'))
      raise InvalidManifest unless parsed.utc_offset.zero? &&
                                   parsed.utc.strftime('%Y-%m-%dT%H:%M:%SZ') == values.fetch('created_at')
    rescue ArgumentError
      raise InvalidManifest
    end

    def read_locked!(path, expected_uid)
      stat = File.lstat(path)
      raise InvalidManifest unless stat.file? &&
                                   !stat.symlink? &&
                                   stat.uid == expected_uid &&
                                   stat.nlink == 1 &&
                                   (stat.mode & 0o777) == 0o400

      File.binread(path)
    end

    def digest_locked!(path, expected_uid)
      digest = Digest::SHA256.new
      opened_stat = nil
      File.open(path, 'rb') do |file|
        opened_stat = file.stat
        raise InvalidManifest unless opened_stat.file? &&
                                     opened_stat.uid == expected_uid &&
                                     opened_stat.nlink == 1 &&
                                     (opened_stat.mode & 0o777) == 0o400

        while (chunk = file.read(1.megabyte))
          digest << chunk
        end
      end
      stat = File.lstat(path)
      raise InvalidManifest if stat.symlink?
      raise InvalidManifest unless stat.dev == opened_stat.dev && stat.ino == opened_stat.ino

      digest.hexdigest
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
