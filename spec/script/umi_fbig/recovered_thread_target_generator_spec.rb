require 'digest'
require 'fileutils'
require 'open3'
require 'rails_helper'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe 'UMI FB/IG recovered-thread target generator' do
  let(:repository_root) { File.expand_path('../../..', __dir__) }
  let(:program) { File.join(repository_root, 'script/umi_fbig/support/fbig_recovered_thread_targets.rb') }

  def seal(directory, basename, bytes, checksum: false)
    path = File.join(directory, basename)
    File.binwrite(path, bytes)
    File.chmod(0o400, path)
    return path unless checksum

    checksum_path = "#{path}.sha256"
    File.binwrite(checksum_path, "#{Digest::SHA256.hexdigest(bytes)}  #{basename}\n")
    File.chmod(0o400, checksum_path)
    path
  end

  it 'derives exactly two digests from retained R2 failures without leaking raw ids' do
    Dir.mktmpdir do |root|
      source = File.join(root, 'source')
      output = File.join(root, 'output')
      FileUtils.mkdir_p([source, output], mode: 0o700)
      File.chmod(0o700, source)
      File.chmod(0o700, output)
      binding = seal(
        source,
        'binding.tsv',
        <<~TSV,
          acceptance_id	candidate-7a6929e3-c6348a23060d-r2
          candidate_commit	7a6929e331d62c8b33801119c3fff13e74acfb51
          candidate_image	ghcr.io/shumkov/chatwoot@sha256:c6348a23060d69a5a440b2f7a4bf20486b8ecec3a0d326969f2d18edc19908f7
        TSV
        checksum: true
      )
      launch = seal(
        source,
        'launch.tsv',
        "invocation_id\ta65dcb24ec6a46e9b989357ebdd448e5\n",
        checksum: true
      )
      first_id = 'private-instagram-thread-one'
      second_id = 'private-instagram-thread-two'
      log = seal(
        source,
        'probe.log',
        <<~LOG
          [UMI-FBIG] stage=thread_failed platform=instagram thread_id=#{first_id} reason=exception error=Koala::Facebook::ClientError
          [UMI-FBIG] stage=thread_failed platform=instagram thread_id=#{second_id} reason=exception error=Koala::Facebook::ClientError
        LOG
      )
      summary = seal(
        source,
        'summary.tsv',
        "[UMI-FBIG] stage=history_import_summary failed_threads=2 instagram_failed_threads=2\n"
      )
      env = {
        'UMI_FBIG_EXPECTED_UID' => Process.uid.to_s,
        'UMI_FBIG_R2_ACCEPTANCE_BINDING_PATH' => binding,
        'UMI_FBIG_R2_LAUNCH_MANIFEST_PATH' => launch,
        'UMI_FBIG_R2_PROBE_LOG_PATH' => log,
        'UMI_FBIG_R2_PROBE_SUMMARY_PATH' => summary,
        'UMI_FBIG_RECOVERED_TARGET_OUTPUT_DIR' => output
      }

      stdout, stderr, status = Open3.capture3(env, Gem.ruby, 'bin/rails', 'runner', program, chdir: repository_root)

      expect(status).to be_success, stderr
      expect(stdout).not_to include(first_id, second_id)
      expect(stderr).not_to include(first_id, second_id)
      bytes = File.binread(File.join(output, 'fbig-recovered-thread-targets-v1.tsv'))
      targets = Umi::Fbig::RecoveredThreadTargets.parse(bytes)
      expect(targets.digests).to contain_exactly(
        Umi::Fbig::RecoveredThreadTargets.digest(platform: 'instagram', thread_id: first_id),
        Umi::Fbig::RecoveredThreadTargets.digest(platform: 'instagram', thread_id: second_id)
      )
      expect(bytes).not_to include(first_id, second_id)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
