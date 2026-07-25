require 'rails_helper'
require 'tmpdir'

RSpec.describe Umi::Fbig::ProfileTargetManifest do
  let(:bytes) do
    (1..6).map { |id| "#{id}\t#{id + 10}\t#{id + 100}\n" }.join
  end

  it 'parses exactly six unique rows in numeric ContactInbox order' do
    rows = described_class.parse(bytes)

    expect(rows.size).to eq(6)
    expect(rows.first).to have_attributes(contact_inbox_id: 1, contact_id: 11, source_id: '101')
  end

  it 'rejects reordered, duplicate, malformed, or noncanonical rows' do
    invalid = [
      bytes.lines.reverse.join,
      bytes.sub("2\t12\t102", "1\t12\t102"),
      bytes.sub("2\t12\t102", "2\t12\t101"),
      bytes.sub("2\t12\t102", "02\t12\t102"),
      bytes.lines.first(5).join,
      bytes.delete_suffix("\n")
    ]

    invalid.each do |value|
      expect { described_class.parse(value) }.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'loads the fixed, locked sidecar only when its bound digest matches' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'fbig-profile-targets-v1.tsv')
      File.binwrite(path, bytes)
      File.chmod(0o700, directory)
      File.chmod(0o400, path)

      rows = described_class.load(
        path: path,
        expected_sha256: Digest::SHA256.hexdigest(bytes),
        expected_uid: Process.uid
      )

      expect(rows.size).to eq(6)
      expect do
        described_class.load(path: path, expected_sha256: '0' * 64, expected_uid: Process.uid)
      end.to raise_error(described_class::InvalidManifest)
    end
  end
end
