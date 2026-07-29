require 'fileutils'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'UMI FB/IG production-first binding generator' do
  let(:repository_root) { File.expand_path('../../..', __dir__) }
  let(:program) do
    File.join(repository_root, 'script/umi_fbig/support/fbig_production_first_binding.rb')
  end
  let(:programs) do
    {
      'history' => 'history_attempt.sh',
      'profile' => 'profile_attempt.sh',
      'delivery_audit' => 'delivery_audit.sh',
      'delivery_checkpoint' => 'delivery_checkpoint.sh',
      'final_audit' => 'final_audit.sh'
    }
  end

  it 'emits every protected program binding in the exact field order consumed by that program' do
    Dir.mktmpdir do |root|
      programs.each do |kind, template|
        output = File.join(root, kind)
        FileUtils.mkdir_p(output, mode: 0o700)
        File.chmod(0o700, output)
        source = File.binread(File.join(repository_root, 'script/umi_fbig/programs', template))
        body = source.match(/readonly BINDING_FIELDS=\(\n(?<fields>.*?)\n\)/m)[:fields]
        fields = body.split
        basename = "fbig-#{kind.tr('_', '-')}-binding-v1.tsv"
        env = {
          'UMI_FBIG_EXPECTED_UID' => Process.uid.to_s,
          'UMI_FBIG_BINDING_KIND' => kind,
          'UMI_FBIG_BINDING_BASENAME' => basename,
          'UMI_FBIG_BINDING_OUTPUT_DIR' => output
        }
        fields.each do |field|
          next if field == 'schema_version'

          env["UMI_FBIG_BIND_#{field.upcase}"] =
            field == 'authorization_mode' ? 'production_first' : "value-#{field}"
        end

        _stdout, stderr, status = Open3.capture3(env, Gem.ruby, program)

        expect(status).to be_success, "#{kind}: #{stderr}"
        artifact = File.join(output, basename)
        expect(File.binread(artifact).lines.map { |line| line.split("\t", 2).first }).to eq(fields)
        expect(File.stat(artifact).mode & 0o777).to eq(0o400)
        expect(File.stat("#{artifact}.sha256").mode & 0o777).to eq(0o400)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
