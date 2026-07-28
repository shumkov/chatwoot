require 'rails_helper'

# rubocop:disable RSpec/MultipleExpectations
RSpec.describe Umi::Fbig::HistoryStateSnapshot do
  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: '1000', instagram_id: '2000')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) do
    create(:contact, account: account, name: 'Private Customer', additional_attributes: { 'owner_note' => 'private note' })
  end
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'private-source-id') }
  let(:archive) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :resolved,
      identifier: "umi-fbig-history:#{inbox.id}:messenger:private-thread-id",
      additional_attributes: {
        'umi_history_import' => {
          'schema_version' => 1,
          'platform' => 'messenger',
          'thread_id' => 'private-thread-id',
          'configuration' => {
            'since' => 'all',
            'before' => '2026-07-25T19:00:00Z',
            'outbound_policy' => 'pre_presence'
          }
        }
      }
    )
  end
  let(:message) do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: archive,
      sender: contact,
      message_type: :incoming,
      source_id: 'private-mid',
      content: 'private message body',
      additional_attributes: {
        'umi_history_import' => true,
        'umi_history_schema_version' => 1,
        'umi_history_platform' => 'messenger',
        'umi_history_thread_id' => 'private-thread-id'
      }
    )
  end

  before do
    allow(ActiveRecord::Base).to receive(:transaction).and_wrap_original do |method, *args, **options, &block|
      if options[:isolation] == :repeatable_read
        method.call(requires_new: options[:requires_new], &block)
      else
        method.call(*args, **options, &block)
      end
    end
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    attachment = Attachment.create!(
      account: account,
      message: message,
      file_type: :file,
      external_url: 'https://example.test/private-file'
    )
    attachment.file.attach(
      io: StringIO.new('private attachment bytes'),
      filename: 'private.txt',
      content_type: 'text/plain'
    )
  end

  it 'captures the complete importer graph as deterministic PII-free rows' do
    artifact = described_class.capture(inbox, platforms: %w[messenger instagram])
    parsed = described_class.parse(artifact.bytes)

    expect(parsed).to have_attributes(account_id: account.id, inbox_id: inbox.id)
    expect(parsed.platforms).to eq(%w[messenger instagram])
    expect(parsed.rows.map(&:entity)).to include(
      'contact',
      'contact_inbox',
      'archive',
      'message',
      'attachment',
      'active_storage_attachment',
      'active_storage_blob'
    )
    expect(parsed.rows.select { |row| row.platform == 'messenger' }.map(&:entity)).to include(
      'archive',
      'message',
      'attachment',
      'active_storage_attachment',
      'active_storage_blob'
    )
    expect(parsed.rows.map(&:key)).to eq(parsed.rows.map(&:key).sort)
    expect(parsed.rows.map(&:key).uniq.size).to eq(parsed.rows.size)
    expect(artifact.bytes).not_to include(
      'Private Customer',
      'private note',
      'private-source-id',
      'private-thread-id',
      'private-mid',
      'private message body',
      'private-file',
      'private attachment bytes'
    )
    expect(artifact.sha256).to eq(Digest::SHA256.hexdigest(artifact.bytes))
    expect(ActiveRecord::Base).to have_received(:transaction).with(
      isolation: :repeatable_read,
      requires_new: true
    )
  end

  it 'rejects an oversized graph before materializing snapshot rows' do
    stub_const("#{described_class}::MAX_ROWS", 1)
    allow(described_class).to receive(:capture_rows)

    expect do
      described_class.capture(inbox, platforms: %w[messenger])
    end.to raise_error(described_class::InvalidSnapshot)
    expect(described_class).not_to have_received(:capture_rows)
  end

  it 'seals and reloads fixed production prestate and poststate artifacts' do
    Dir.mktmpdir do |directory|
      File.chmod(0o700, directory)
      prestate = described_class.capture_and_seal!(
        inbox,
        platforms: %w[messenger],
        directory: directory,
        basename: 'fbig-history-production-prestate-v1.tsv',
        expected_uid: Process.uid
      )
      loaded = described_class.load(
        path: Pathname.new(directory).join('fbig-history-production-prestate-v1.tsv').to_s,
        checksum_path: Pathname.new(directory).join('fbig-history-production-prestate-v1.tsv.sha256').to_s,
        expected_uid: Process.uid
      )

      expect(loaded.sha256).to eq(prestate.sha256)
      expect(loaded.rows.map(&:key)).to eq(prestate.rows.map(&:key))

      poststate = described_class.capture_and_seal!(
        inbox,
        platforms: %w[messenger],
        directory: directory,
        basename: 'fbig-history-production-poststate-v1.tsv',
        expected_uid: Process.uid
      )
      expect(poststate.sha256).to eq(Digest::SHA256.hexdigest(poststate.bytes))
    end
  end

  it 'rejects malformed or out-of-scope rows rather than weakening the snapshot' do
    artifact = described_class.capture(inbox, platforms: %w[messenger])
    malformed = artifact.bytes.sub("\tshared\t", "\tunknown\t")

    expect { described_class.parse(malformed) }.to raise_error(described_class::InvalidSnapshot)
    expect do
      described_class.capture(inbox, platforms: %w[messenger invalid])
    end.to raise_error(described_class::InvalidSnapshot)
  end
end
# rubocop:enable RSpec/MultipleExpectations
