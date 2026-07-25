require 'rails_helper'
require 'tmpdir'

# A non-StandardError models process death after durable object upload.
# rubocop:disable Lint/InheritException, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Umi::Fbig::AvatarIntentStore do
  let(:contact) { create(:contact) }
  let(:image_file) { Tempfile.new(['avatar-intent', '.png'], binmode: true) }
  let(:image_result) do
    SafeFetch::Result.new(tempfile: image_file, filename: 'profile.png', content_type: 'image/png')
  end

  before do
    stub_const('SimulatedAvatarProcessCrash', Class.new(Exception))
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
  end

  after do
    image_file.close!
  end

  it 'recovers an exact importer blob after a crash following object upload and preserves unlisted blobs' do
    inbox = create(:inbox, account: contact.account)
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '1234')
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      store = described_class.new(directory: directory, expected_uid: Process.uid)
      unrelated = ActiveStorage::Blob.create_and_upload!(
        io: Rails.root.join('spec/assets/avatar.png').open,
        filename: 'unrelated.png',
        content_type: 'image/png'
      )
      service = Umi::Fbig::HistoryImportProfileService.new(
        intent_store: store,
        after_avatar_upload: -> { raise SimulatedAvatarProcessCrash }
      )
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)

      expect do
        service.attach_avatar(
          contact: contact,
          url: 'https://cdn.example/profile.png',
          remaining_budget_bytes: 15.megabytes,
          avatar_intent: {
            platform: 'instagram',
            source_id: '1234',
            contact_inbox_id: contact_inbox.id
          }
        )
      end.to raise_error(SimulatedAvatarProcessCrash)

      staged = ActiveStorage::Blob.where.not(id: unrelated.id).find_by!(filename: 'profile.png')
      expect(staged.service.exist?(staged.key)).to be(true)
      expect(staged.key).to match(/\A[0-9a-f]{48}\z/)
      expect(Pathname.new(directory).join('intent-1.tsv').binread).to eq(
        [
          "schema_version\t1",
          "sequence\t1",
          "blob_key\t#{staged.key}",
          "contact_inbox_id\t#{contact_inbox.id}",
          "source_id_sha256\t#{Umi::Fbig::TypedValueDigest.hexdigest('1234')}"
        ].join("\n") << "\n"
      )

      result = store.reconcile!

      expect(result.statuses).to eq(attached: 0, absent: 1)
      expect(result.entries.first).to have_attributes(
        sequence: 1,
        blob_key: staged.key,
        outcome: 'absent',
        blob_id: 0,
        attachment_id: 0,
        object_sha256: '-'
      )
      expect(ActiveStorage::Blob.exists?(staged.id)).to be(false)
      expect(unrelated.reload.service.exist?(unrelated.key)).to be(true)
    end
  end

  it 'recovers the exact unattached blob row after a crash before object upload' do
    inbox = create(:inbox, account: contact.account)
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '1234')
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      store = described_class.new(directory: directory, expected_uid: Process.uid)
      service = Umi::Fbig::HistoryImportProfileService.new(
        intent_store: store,
        after_avatar_blob_save: -> { raise SimulatedAvatarProcessCrash }
      )
      allow(SafeFetch).to receive(:fetch).and_yield(image_result)

      expect do
        service.attach_avatar(
          contact: contact,
          url: 'https://cdn.example/profile.png',
          remaining_budget_bytes: 15.megabytes,
          avatar_intent: {
            platform: 'instagram',
            source_id: '1234',
            contact_inbox_id: contact_inbox.id
          }
        )
      end.to raise_error(SimulatedAvatarProcessCrash)

      staged = ActiveStorage::Blob.find_by!(filename: 'profile.png')
      expect(staged.service.exist?(staged.key)).to be(false)

      result = store.reconcile!

      expect(result.statuses).to eq(attached: 0, absent: 1)
      expect(result.entries.first).to have_attributes(
        blob_key: staged.key,
        outcome: 'absent',
        blob_id: 0,
        attachment_id: 0
      )
      expect(ActiveStorage::Blob.exists?(staged.id)).to be(false)
      expect(staged.service.exist?(staged.key)).to be(false)
    end
  end

  it 'retains an attachment only when it belongs to the intent current target contact' do
    inbox = create(:inbox, account: contact.account)
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '1234')
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      store = described_class.new(directory: directory, expected_uid: Process.uid)
      intent = store.create!(source_id: '1234', contact_inbox_id: contact_inbox.id)
      blob = ActiveStorage::Blob.create_and_upload!(
        key: intent.blob_key,
        io: Rails.root.join('spec/assets/avatar.png').open,
        filename: 'profile.png',
        content_type: 'image/png'
      )
      attachment = ActiveStorage::Attachment.create!(
        name: 'avatar',
        record_type: 'Contact',
        record_id: contact.id,
        blob: blob
      )

      result = store.reconcile!

      expect(result.statuses).to eq(attached: 1, absent: 0)
      expect(result.entries.first).to have_attributes(
        outcome: 'attached',
        blob_id: blob.id,
        attachment_id: attachment.id,
        object_sha256: Digest::SHA256.file(Rails.root.join('spec/assets/avatar.png')).hexdigest
      )
    end
  end

  it 'rejects malformed or unexpected files instead of scanning or deleting unlisted keys' do
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      store = described_class.new(directory: directory, expected_uid: Process.uid)
      File.binwrite(Pathname.new(directory).join('unexpected'), 'do not touch')

      expect { store.reconcile! }.to raise_error(described_class::InvalidStore)
      expect(Pathname.new(directory).join('unexpected')).to exist
    end
  end

  it 'renews before every recovery entry and stops before the next cleanup on lease loss' do
    inbox = create(:inbox, account: contact.account)
    first = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '1234')
    second_contact = create(:contact, account: contact.account)
    second = create(:contact_inbox, inbox: inbox, contact: second_contact, source_id: '5678')
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      store = described_class.new(directory: directory, expected_uid: Process.uid)
      store.create!(source_id: first.source_id, contact_inbox_id: first.id)
      store.create!(source_id: second.source_id, contact_inbox_id: second.id)
      renewals = 0
      renewer = lambda do
        renewals += 1
        renewals == 1
      end

      expect { store.reconcile!(renewer: renewer) }.to raise_error(described_class::LeaseLost)
      expect(renewals).to eq(2)
    end
  end
end
# rubocop:enable Lint/InheritException, RSpec/ExampleLength, RSpec/MultipleExpectations
