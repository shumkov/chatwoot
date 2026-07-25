require 'rails_helper'

RSpec.describe Umi::Fbig::AvatarStagingManifest do
  let(:source_state_sha256) { 'a' * 64 }
  let(:entries) do
    [
      Umi::Fbig::AvatarIntentStore::Entry.new(
        sequence: 1,
        blob_key: 'b' * 48,
        contact_inbox_id: 20,
        source_id_sha256: 'c' * 64,
        outcome: 'attached',
        blob_id: 30,
        attachment_id: 40,
        object_sha256: 'd' * 64
      ),
      Umi::Fbig::AvatarIntentStore::Entry.new(
        sequence: 2,
        blob_key: 'e' * 48,
        contact_inbox_id: 21,
        source_id_sha256: 'f' * 64,
        outcome: 'absent',
        blob_id: 0,
        attachment_id: 0,
        object_sha256: '-'
      )
    ]
  end

  it 'serializes and parses the exact staging disposition contract' do
    manifest = described_class.build(source_state_sha256: source_state_sha256, entries: entries)
    parsed = described_class.parse(manifest.bytes)

    expect(parsed.source_state_sha256).to eq(source_state_sha256)
    expect(parsed.entries.map(&:outcome)).to eq(%w[attached absent])
    expect(parsed.bytes).to eq(manifest.bytes)
  end

  it 'rejects sequence gaps, partial terminal tuples, and source-state drift' do
    bytes = described_class.build(source_state_sha256: source_state_sha256, entries: entries).bytes
    gap = bytes.sub("intent\t2\t", "intent\t3\t")
    partial = bytes.sub("\tabsent\t0\t0\t-\n", "\tabsent\t30\t0\t-\n")
    invalid_source = bytes.sub("source_state_sha256\t#{source_state_sha256}", "source_state_sha256\t-")

    [gap, partial, invalid_source].each do |invalid|
      expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'seals and reloads a fixed-basename checksummed artifact' do
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      sealed = described_class.seal!(
        directory: directory,
        source_state_sha256: source_state_sha256,
        entries: entries,
        expected_uid: Process.uid
      )

      loaded = described_class.load(
        path: Pathname.new(directory).join('fbig-profile-avatar-staging-v1.tsv').to_s,
        checksum_path: Pathname.new(directory).join('fbig-profile-avatar-staging-v1.tsv.sha256').to_s,
        expected_uid: Process.uid
      )

      expect(loaded.sha256).to eq(sealed.sha256)
      expect(loaded.entries.size).to eq(2)
    end
  end
end
