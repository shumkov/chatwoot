# frozen_string_literal: true

require 'digest'
require 'pathname'

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::ProfileTargetManifest
  Row = Data.define(:contact_inbox_id, :contact_id, :source_id)
  MAX_ROWS = 10_000
  MAX_LINE_BYTES = 256
  MAX_BYTES = MAX_ROWS * MAX_LINE_BYTES

  class InvalidManifest < StandardError; end

  def self.parse(bytes)
    raise InvalidManifest if bytes.to_s.bytesize > MAX_BYTES

    text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    raise InvalidManifest unless text.valid_encoding? && text.end_with?("\n")
    raise InvalidManifest if text.include?("\r") || text.include?("\0")

    raw_lines = text.lines
    raise InvalidManifest if raw_lines.empty? || raw_lines.size > MAX_ROWS
    raise InvalidManifest if raw_lines.any? { |line| line.bytesize > MAX_LINE_BYTES }

    rows = raw_lines.map do |raw_line|
      line = raw_line.chomp
      values = line.split("\t", -1)
      raise InvalidManifest unless values.size == 3 && values.all? { |value| value.match?(/\A[1-9][0-9]*\z/) }

      Row.new(
        contact_inbox_id: Integer(values.fetch(0), 10),
        contact_id: Integer(values.fetch(1), 10),
        source_id: values.fetch(2)
      )
    end
    raise InvalidManifest unless rows.map(&:contact_inbox_id) == rows.map(&:contact_inbox_id).sort
    raise InvalidManifest unless rows.map(&:contact_inbox_id).uniq.size == rows.size
    raise InvalidManifest unless rows.map(&:source_id).uniq.size == rows.size

    rows.freeze
  rescue ArgumentError
    raise InvalidManifest
  end

  def self.load(path:, expected_sha256:, expected_uid: 0)
    pathname = Pathname.new(path.to_s)
    valid_path = pathname.absolute? &&
                 pathname.cleanpath.to_s == path.to_s &&
                 pathname.basename.to_s == 'fbig-profile-targets-v1.tsv'
    raise InvalidManifest unless valid_path && expected_sha256.to_s.match?(/\A[0-9a-f]{64}\z/)

    directory_stat = File.lstat(pathname.dirname)
    valid_directory = directory_stat.directory? &&
                      !directory_stat.symlink? &&
                      directory_stat.uid == expected_uid &&
                      (directory_stat.mode & 0o777) == 0o700
    raise InvalidManifest unless valid_directory

    bytes = nil
    opened_stat = nil
    File.open(pathname, 'rb') do |file|
      opened_stat = file.stat
      valid_file = opened_stat.file? &&
                   opened_stat.uid == expected_uid &&
                   opened_stat.nlink == 1 &&
                   (opened_stat.mode & 0o777) == 0o400
      raise InvalidManifest unless valid_file

      bytes = file.read(MAX_BYTES + 1)
    end
    raise InvalidManifest if bytes.bytesize > MAX_BYTES

    path_stat = File.lstat(pathname)
    raise InvalidManifest if path_stat.symlink?
    raise InvalidManifest unless path_stat.dev == opened_stat.dev && path_stat.ino == opened_stat.ino
    raise InvalidManifest unless Digest::SHA256.hexdigest(bytes) == expected_sha256

    parse(bytes)
  rescue SystemCallError
    raise InvalidManifest
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
