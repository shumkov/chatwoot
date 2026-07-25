# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::AvatarStagingManifest
  class InvalidManifest < StandardError; end

  BASENAME = 'fbig-profile-avatar-staging-v1.tsv'
  HASH_PATTERN = /\A[0-9a-f]{64}\z/
  KEY_PATTERN = /\A[0-9a-f]{48}\z/
  MAX_ENTRIES = Umi::Fbig::AvatarIntentStore::MAX_INTENTS
  MAX_BYTES = Umi::Fbig::ProfileStateSnapshot::MAX_BYTES
  MAX_LINE_BYTES = Umi::Fbig::ProfileStateSnapshot::MAX_LINE_BYTES

  attr_reader :bytes, :source_state_sha256, :entries, :sha256

  def self.build(source_state_sha256:, entries:)
    bytes = [
      "schema_version\t1",
      "source_state_sha256\t#{source_state_sha256}",
      "entry_count\t#{entries.size}",
      *entries.map do |entry|
        [
          'intent',
          entry.sequence,
          entry.blob_key,
          entry.contact_inbox_id,
          entry.source_id_sha256,
          entry.outcome,
          entry.blob_id,
          entry.attachment_id,
          entry.object_sha256
        ].join("\t")
      end
    ].join("\n") << "\n"
    parse(bytes)
  end

  def self.parse(bytes)
    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidManifest unless text.valid_encoding? && text.end_with?("\n") && text.bytesize <= MAX_BYTES
    raise InvalidManifest if text.include?("\r") || text.include?("\0")

    lines = text.lines(chomp: true)
    raise InvalidManifest if lines.size < 3 || lines.any? { |line| line.bytesize > MAX_LINE_BYTES }

    headers = lines.first(3).map { |line| line.split("\t", -1) }
    raise InvalidManifest unless headers.map(&:first) == %w[schema_version source_state_sha256 entry_count] &&
                                 headers.all? { |parts| parts.size == 2 } &&
                                 headers.dig(0, 1) == '1' &&
                                 headers.dig(1, 1).match?(HASH_PATTERN) &&
                                 headers.dig(2, 1).match?(/\A(?:0|[1-9][0-9]*)\z/)

    entry_count = Integer(headers.dig(2, 1), 10)
    raise InvalidManifest if entry_count > MAX_ENTRIES || lines.size != entry_count + 3

    entries = lines.drop(3).map { |line| parse_entry(line) }
    raise InvalidManifest unless entries.map(&:sequence) == (1..entry_count).to_a

    new(
      bytes: text.freeze,
      source_state_sha256: headers.dig(1, 1),
      entries: entries.freeze,
      sha256: Digest::SHA256.hexdigest(text)
    )
  rescue ArgumentError
    raise InvalidManifest
  end

  def self.load(path:, checksum_path:, expected_uid: 0)
    manifest = canonical_path!(path, BASENAME)
    checksum = canonical_path!(checksum_path, "#{BASENAME}.sha256")
    raise InvalidManifest unless manifest.dirname == checksum.dirname

    verify_directory!(manifest.dirname, expected_uid)
    bytes = read_artifact!(manifest, expected_uid)
    checksum_bytes = read_artifact!(checksum, expected_uid)
    raise InvalidManifest unless checksum_bytes == "#{Digest::SHA256.hexdigest(bytes)}  #{BASENAME}\n"

    parse(bytes)
  rescue SystemCallError
    raise InvalidManifest
  end

  def self.seal!(directory:, source_state_sha256:, entries:, expected_uid: 0)
    directory_path = Pathname.new(directory.to_s)
    verify_directory!(directory_path, expected_uid)
    artifact = build(source_state_sha256: source_state_sha256, entries: entries)
    manifest = directory_path.join(BASENAME)
    checksum = directory_path.join("#{BASENAME}.sha256")
    raise InvalidManifest if manifest.exist? || checksum.exist?

    token = SecureRandom.hex(16)
    temporary_manifest = directory_path.join(".#{BASENAME}.#{token}.tmp")
    temporary_checksum = directory_path.join(".#{BASENAME}.sha256.#{token}.tmp")
    write_temporary!(temporary_manifest, artifact.bytes)
    write_temporary!(temporary_checksum, "#{artifact.sha256}  #{BASENAME}\n")
    File.rename(temporary_manifest, manifest)
    File.rename(temporary_checksum, checksum)
    fsync_directory!(directory_path)
    artifact
  rescue SystemCallError
    raise InvalidManifest
  ensure
    [temporary_manifest, temporary_checksum].compact.each do |path|
      File.unlink(path) if path.exist?
    end
  end

  def initialize(bytes:, source_state_sha256:, entries:, sha256:)
    @bytes = bytes
    @source_state_sha256 = source_state_sha256
    @entries = entries
    @sha256 = sha256
  end

  class << self
    private

    def parse_entry(line)
      values = line.split("\t", -1)
      raise InvalidManifest unless values.size == 9 &&
                                   values.first == 'intent' &&
                                   values[1].match?(/\A[1-9][0-9]*\z/) &&
                                   values[2].match?(KEY_PATTERN) &&
                                   values[3].match?(/\A[1-9][0-9]*\z/) &&
                                   values[4].match?(HASH_PATTERN)

      outcome = values[5]
      blob_id = canonical_nonnegative!(values[6])
      attachment_id = canonical_nonnegative!(values[7])
      if outcome == 'attached'
        raise InvalidManifest unless blob_id.positive? && attachment_id.positive? && values[8].match?(HASH_PATTERN)
      elsif outcome == 'absent'
        raise InvalidManifest unless blob_id.zero? && attachment_id.zero? && values[8] == '-'
      else
        raise InvalidManifest
      end

      Umi::Fbig::AvatarIntentStore::Entry.new(
        sequence: Integer(values[1], 10),
        blob_key: values[2],
        contact_inbox_id: Integer(values[3], 10),
        source_id_sha256: values[4],
        outcome: outcome,
        blob_id: blob_id,
        attachment_id: attachment_id,
        object_sha256: values[8]
      )
    end

    def canonical_nonnegative!(value)
      raise InvalidManifest unless value.match?(/\A(?:0|[1-9][0-9]*)\z/)

      Integer(value, 10)
    end

    def canonical_path!(value, basename)
      path = Pathname.new(value.to_s)
      raise InvalidManifest unless path.absolute? && path.cleanpath.to_s == value.to_s && path.basename.to_s == basename

      path
    end

    def verify_directory!(path, expected_uid)
      raise InvalidManifest unless path.absolute? && path.cleanpath == path

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

    def write_temporary!(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.chmod(0o400, path)
    end

    def fsync_directory!(directory)
      File.open(directory, File::RDONLY, &:fsync)
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
