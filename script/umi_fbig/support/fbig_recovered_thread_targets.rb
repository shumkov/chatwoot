# frozen_string_literal: true

require 'digest'
require 'pathname'

# These checks are deliberately linear and fail closed at each filesystem boundary.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
EXPECTED_ACCEPTANCE_ID = 'candidate-7a6929e3-c6348a23060d-r2'
EXPECTED_REPOSITORY_COMMIT = '7a6929e331d62c8b33801119c3fff13e74acfb51'
EXPECTED_IMAGE_DIGEST =
  'ghcr.io/shumkov/chatwoot@sha256:c6348a23060d69a5a440b2f7a4bf20486b8ecec3a0d326969f2d18edc19908f7'
EXPECTED_INVOCATION_ID = 'a65dcb24ec6a46e9b989357ebdd448e5'
OUTPUT_BASENAME = 'fbig-recovered-thread-targets-v1.tsv'

def fail_closed!
  raise 'recovered-thread source evidence is invalid'
end

def protected_bytes(path, expected_uid)
  candidate = Pathname.new(path.to_s)
  fail_closed! unless candidate.absolute? && candidate.cleanpath.to_s == path.to_s
  directory = File.lstat(candidate.dirname)
  fail_closed! unless
    directory.directory? && !directory.symlink? && directory.uid == expected_uid &&
    (directory.mode & 0o777) == 0o700

  bytes = nil
  opened = nil
  File.open(candidate, 'rb') do |file|
    opened = file.stat
    fail_closed! unless
      opened.file? && opened.uid == expected_uid && opened.nlink == 1 &&
      (opened.mode & 0o777) == 0o400
    bytes = file.read
  end
  current = File.lstat(candidate)
  fail_closed! if current.symlink? || current.dev != opened.dev || current.ino != opened.ino
  bytes
rescue SystemCallError
  fail_closed!
end

def verify_checksum!(path, bytes, expected_uid)
  checksum_path = "#{path}.sha256"
  checksum = protected_bytes(checksum_path, expected_uid)
  expected = "#{Digest::SHA256.hexdigest(bytes)}  #{File.basename(path)}\n"
  fail_closed! unless checksum == expected
end

def manifest_values(bytes)
  text = bytes.dup.force_encoding(Encoding::UTF_8)
  fail_closed! unless text.valid_encoding? && text.end_with?("\n") && text.exclude?("\r") && text.exclude?("\0")
  pairs = text.lines(chomp: true).map do |line|
    fields = line.split("\t", -1)
    fail_closed! unless fields.size == 2
    fields
  end
  fail_closed! unless pairs.map(&:first).uniq.size == pairs.size
  pairs.to_h
end

def stage_values(line, stage)
  marker = "[UMI-FBIG] stage=#{stage} "
  offset = line.index(marker)
  return unless offset

  fields = line.byteslice(offset + marker.bytesize..).to_s.strip.split
  pairs = fields.map { |field| field.split('=', 2) }
  fail_closed! unless pairs.all? { |pair| pair.size == 2 } && pairs.map(&:first).uniq.size == pairs.size
  pairs.to_h
end

def publish!(directory, basename, bytes)
  output = directory.join(basename)
  checksum = directory.join("#{basename}.sha256")
  fail_closed! if output.exist? || output.symlink? || checksum.exist? || checksum.symlink?

  [[output, bytes], [checksum, "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n"]].each do |path, content|
    temporary = directory.join(".#{path.basename}.#{Process.pid}.tmp")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.binmode
      file.write(content)
      file.flush
      file.fsync
    end
    File.chmod(0o400, temporary)
    File.link(temporary, path)
    File.unlink(temporary)
  end
  File.open(directory, File::RDONLY, &:fsync)
end

begin
  expected_uid = Integer(ENV.fetch('UMI_FBIG_EXPECTED_UID', '0'), 10)
  binding_path = ENV.fetch('UMI_FBIG_R2_ACCEPTANCE_BINDING_PATH')
  launch_path = ENV.fetch('UMI_FBIG_R2_LAUNCH_MANIFEST_PATH')
  log_path = ENV.fetch('UMI_FBIG_R2_PROBE_LOG_PATH')
  summary_path = ENV.fetch('UMI_FBIG_R2_PROBE_SUMMARY_PATH')
  output_directory = Pathname.new(ENV.fetch('UMI_FBIG_RECOVERED_TARGET_OUTPUT_DIR'))

  binding_bytes = protected_bytes(binding_path, expected_uid)
  launch_bytes = protected_bytes(launch_path, expected_uid)
  log_bytes = protected_bytes(log_path, expected_uid)
  summary_bytes = protected_bytes(summary_path, expected_uid)
  verify_checksum!(binding_path, binding_bytes, expected_uid)
  verify_checksum!(launch_path, launch_bytes, expected_uid)
  binding = manifest_values(binding_bytes)
  launch = manifest_values(launch_bytes)
  fail_closed! unless
    binding.fetch('acceptance_id') == EXPECTED_ACCEPTANCE_ID &&
    binding.fetch('candidate_commit') == EXPECTED_REPOSITORY_COMMIT &&
    binding.fetch('candidate_image') == EXPECTED_IMAGE_DIGEST &&
    launch.fetch('invocation_id') == EXPECTED_INVOCATION_ID

  summary_text = summary_bytes.dup.force_encoding(Encoding::UTF_8)
  fail_closed! unless summary_text.valid_encoding?
  summary_lines = summary_text.lines.filter_map { |line| stage_values(line, 'history_import_summary') }
  fail_closed! unless summary_lines.one?
  summary = summary_lines.first
  fail_closed! unless summary.fetch('failed_threads') == '2' &&
                      summary.fetch('instagram_failed_threads') == '2'

  log_text = log_bytes.dup.force_encoding(Encoding::UTF_8)
  fail_closed! unless log_text.valid_encoding?
  failures = log_text.lines.filter_map { |line| stage_values(line, 'thread_failed') }.select do |fields|
    fields['platform'] == 'instagram' &&
      fields['error'] == 'Koala::Facebook::ClientError'
  end
  fail_closed! unless failures.size == 2
  thread_ids = failures.map { |fields| fields.fetch('thread_id') }
  fail_closed! unless thread_ids.uniq.size == 2
  digests = thread_ids.map do |thread_id|
    Umi::Fbig::RecoveredThreadTargets.digest(platform: 'instagram', thread_id: thread_id)
  end.sort_by(&:b)
  fail_closed! unless digests.uniq.size == 2

  output_stat = File.lstat(output_directory)
  fail_closed! unless
    output_directory.absolute? && output_directory.cleanpath.to_s == output_directory.to_s &&
    output_stat.directory? && !output_stat.symlink? && output_stat.uid == expected_uid &&
    (output_stat.mode & 0o777) == 0o700
  values = {
    'schema_version' => '1',
    'platform' => 'instagram',
    'target_count' => '2',
    'target_digest_1' => digests.fetch(0),
    'target_digest_2' => digests.fetch(1),
    'source_acceptance_id' => EXPECTED_ACCEPTANCE_ID,
    'source_repository_commit' => EXPECTED_REPOSITORY_COMMIT,
    'source_image_digest' => EXPECTED_IMAGE_DIGEST,
    'source_invocation_id' => EXPECTED_INVOCATION_ID,
    'source_acceptance_binding_sha256' => Digest::SHA256.hexdigest(binding_bytes),
    'source_launch_manifest_sha256' => Digest::SHA256.hexdigest(launch_bytes),
    'source_probe_log_sha256' => Digest::SHA256.hexdigest(log_bytes),
    'source_probe_summary_sha256' => Digest::SHA256.hexdigest(summary_bytes),
    'generator_sha256' => Digest::SHA256.file(__FILE__).hexdigest
  }
  bytes = Umi::Fbig::RecoveredThreadTargets::FIELD_NAMES.map do |field|
    "#{field}\t#{values.fetch(field)}\n"
  end.join
  Umi::Fbig::RecoveredThreadTargets.parse(bytes)
  publish!(output_directory, OUTPUT_BASENAME, bytes)
rescue StandardError
  warn 'recovered-thread target generation failed'
  exit 1
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
