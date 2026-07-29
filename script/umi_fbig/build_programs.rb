# frozen_string_literal: true

require 'digest'
require 'open3'
require 'tempfile'

PROGRAMS = {
  'acceptance' => 'acceptance.sh',
  'acceptance_control' => 'acceptance_control.sh',
  'delivery_audit' => 'delivery_audit.sh',
  'delivery_checkpoint' => 'delivery_checkpoint.sh',
  'final_audit' => 'final_audit.sh',
  'history_attempt' => 'history_attempt.sh',
  'profile_attempt' => 'profile_attempt.sh'
}.freeze
SUPPORT_PROGRAMS = {
  'profile_wrapper' => File.join('support', 'fbig_profile_attempt.sh'),
  'storage_artifact' => File.join('support', 'fbig_storage_artifact.py'),
  'recovered_thread_targets' => File.join('support', 'fbig_recovered_thread_targets.rb'),
  'production_first_request' => File.join('support', 'fbig_production_first_request.rb'),
  'production_first_binding' => File.join('support', 'fbig_production_first_binding.rb'),
  'production_first_authorize' => File.join('support', 'fbig_production_first_authorize.rb'),
  'production_first_history_revise' => File.join('support', 'fbig_production_first_history_revise.rb'),
  'production_first_profile_approve' => File.join('support', 'fbig_production_first_profile_approve.rb')
}.freeze

# Program validation handles three executable formats explicitly.
# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
def fsync_directory(path)
  File.open(path, File::RDONLY, &:fsync)
end

def verify_root_output_directory!(path)
  abort("output directory is a link: #{path}") if File.lstat(path).symlink?
  return unless Process.uid.zero?

  abort("output directory is not canonical: #{path}") unless File.realpath(path) == path
  verify_root_output_ancestors!(path)
end

def verify_root_output_ancestors!(path)
  current = path
  loop do
    stat = File.stat(current)
    abort("output ancestor is not root-owned: #{current}") unless stat.uid.zero? && stat.gid.zero?
    abort("output ancestor is writable by group/world: #{current}") unless stat.mode.nobits?(0o022)
    break if current == '/'

    current = File.dirname(current)
  end
end

def publish_file(path, bytes)
  temporary = "#{path}.#{Process.pid}.tmp"
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.binmode
    file.write(bytes)
    file.flush
    file.fsync
  end
  File.chmod(0o400, temporary)
  File.link(temporary, path)
  File.unlink(temporary)
  fsync_directory(File.dirname(path))
rescue StandardError
  File.unlink(temporary) if temporary && File.exist?(temporary)
  raise
end

def validate_program(bytes, extension)
  Tempfile.create(['umi-fbig-program', extension]) do |file|
    file.binmode
    file.write(bytes)
    file.flush
    if extension == '.sh'
      %w[bash shellcheck].each do |command|
        arguments = command == 'bash' ? ['-n', file.path] : [file.path]
        stdout, stderr, status = Open3.capture3(command, *arguments)
        abort("#{command} rejected generated program:\n#{stdout}#{stderr}") unless status.success?
      end
    elsif extension == '.py'
      source = 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")'
      stdout, stderr, status = Open3.capture3('python3', '-c', source, file.path)
      abort("python3 rejected generated program:\n#{stdout}#{stderr}") unless status.success?
    else
      stdout, stderr, status = Open3.capture3('ruby', '-c', file.path)
      abort("ruby rejected generated program:\n#{stdout}#{stderr}") unless status.success?
    end
  end
end

output_directory = File.expand_path(ARGV.fetch(0))
if File.exist?(output_directory) || File.symlink?(output_directory)
  verify_root_output_directory!(output_directory)
else
  parent = File.dirname(output_directory)
  abort("output parent does not exist: #{parent}") unless File.directory?(parent)

  verify_root_output_directory!(parent)
  Dir.mkdir(output_directory, 0o700)
end
File.chmod(0o700, output_directory)
verify_root_output_directory!(output_directory)

common = File.binread(File.join(__dir__, 'programs/common.sh'))
outputs = PROGRAMS.transform_values do |template|
  [File.join(__dir__, 'programs', template), true, '.sh']
end.merge(
  SUPPORT_PROGRAMS.transform_values do |template|
    [File.join(__dir__, template), false, File.extname(template)]
  end
)
collisions = outputs.filter_map do |logical_name, (_template, _prepend_common, extension)|
  name = "fbig-#{logical_name.tr('_', '-')}#{extension}"
  path = File.join(output_directory, name)
  checksum_path = "#{path}.sha256"
  path if File.exist?(path) || File.exist?(checksum_path)
end
abort("program already exists: #{collisions.first}") unless collisions.empty?

outputs.each do |logical_name, (template, prepend_common, extension)|
  name = "fbig-#{logical_name.tr('_', '-')}#{extension}"
  path = File.join(output_directory, name)
  bytes = (prepend_common ? common : '') + File.binread(template)
  validate_program(bytes, extension)
  publish_file(path, bytes)
  checksum = "#{Digest::SHA256.hexdigest(bytes)}  #{name}\n"
  publish_file("#{path}.sha256", checksum)
  puts logical_name
end
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
