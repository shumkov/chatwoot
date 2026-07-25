require 'rails_helper'

RSpec.describe Umi::Fbig::ProfilePreAttemptBackupManifest do
  let(:backup_id) { '20260725T010203Z-0123456789abcdef' }
  let(:components) do
    {
      'database.dump' => 'postgres dump',
      'database.restore.list' => "TABLE public.contacts\n",
      'storage.tar' => 'storage archive',
      'storage.manifest' => "avatar/key\t12\t#{'a' * 64}\n"
    }
  end
  let(:values) do
    {
      'schema_version' => '1',
      'backup_id' => backup_id,
      'production_database_name' => 'chatwoot_production',
      'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
      'database_dump_sha256' => Digest::SHA256.hexdigest(components.fetch('database.dump')),
      'database_restore_list_sha256' => Digest::SHA256.hexdigest(components.fetch('database.restore.list')),
      'storage_archive_sha256' => Digest::SHA256.hexdigest(components.fetch('storage.tar')),
      'storage_manifest_sha256' => Digest::SHA256.hexdigest(components.fetch('storage.manifest')),
      'created_at' => '2026-07-25T01:02:03Z'
    }
  end
  let(:bytes) do
    described_class::FIELD_NAMES.map { |name| "#{name}\t#{values.fetch(name)}\n" }.join
  end

  it 'parses the exact nine-field backup contract' do
    manifest = described_class.parse(bytes)

    expect(manifest).to have_attributes(
      backup_id: backup_id,
      production_database_name: 'chatwoot_production',
      database_dump_sha256: Digest::SHA256.hexdigest('postgres dump')
    )
  end

  it 'loads only the sealed directory and recursively verifies every component digest' do
    Dir.mktmpdir do |parent|
      directory = Pathname.new(parent).join("fbig-profile-pre-attempt-#{backup_id}")
      directory.mkdir(0o700)
      manifest_path = directory.join('fbig-profile-pre-attempt-backup-v1.tsv')
      checksum_path = directory.join('fbig-profile-pre-attempt-backup-v1.tsv.sha256')
      File.binwrite(manifest_path, bytes)
      File.binwrite(checksum_path, "#{Digest::SHA256.hexdigest(bytes)}  #{manifest_path.basename}\n")
      components.each { |name, content| File.binwrite(directory.join(name), content) }
      directory.children.each { |path| File.chmod(0o400, path) }
      allow(File).to receive(:binread).and_call_original

      loaded = described_class.load(
        manifest_path: manifest_path.to_s,
        checksum_path: checksum_path.to_s,
        expected_uid: Process.uid
      )
      expect(loaded.directory).to eq(directory)
      expect(File).not_to have_received(:binread).with(directory.join('storage.tar'))

      File.chmod(0o600, directory.join('storage.tar'))
      File.binwrite(directory.join('storage.tar'), 'tampered')
      File.chmod(0o400, directory.join('storage.tar'))
      expect do
        described_class.load(
          manifest_path: manifest_path.to_s,
          checksum_path: checksum_path.to_s,
          expected_uid: Process.uid
        )
      end.to raise_error(described_class::InvalidManifest)
    end
  end

  it 'rejects a backup id that does not match its sealed directory' do
    Dir.mktmpdir do |parent|
      directory = Pathname.new(parent).join('fbig-profile-pre-attempt-20260725T010204Z-0123456789abcdef')
      directory.mkdir(0o700)
      manifest_path = directory.join('fbig-profile-pre-attempt-backup-v1.tsv')
      checksum_path = directory.join('fbig-profile-pre-attempt-backup-v1.tsv.sha256')
      File.binwrite(manifest_path, bytes)
      File.binwrite(checksum_path, "#{Digest::SHA256.hexdigest(bytes)}  #{manifest_path.basename}\n")
      components.each { |name, content| File.binwrite(directory.join(name), content) }
      directory.children.each { |path| File.chmod(0o400, path) }

      expect do
        described_class.load(
          manifest_path: manifest_path.to_s,
          checksum_path: checksum_path.to_s,
          expected_uid: Process.uid
        )
      end.to raise_error(described_class::InvalidManifest)
    end
  end
end
