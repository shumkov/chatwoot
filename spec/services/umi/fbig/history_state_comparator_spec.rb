require 'rails_helper'

# rubocop:disable Metrics/MethodLength
RSpec.describe Umi::Fbig::HistoryStateComparator do
  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: '1000', instagram_id: '2000')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) { create(:contact, account: account, name: 'Existing contact') }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'participant-1') }

  before do
    allow(ActiveRecord::Base).to receive(:transaction).and_wrap_original do |method, *args, **options, &block|
      if options[:isolation] == :repeatable_read
        method.call(requires_new: options[:requires_new], &block)
      else
        method.call(*args, **options, &block)
      end
    end
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    contact_inbox
  end

  it 'attributes committed rows to the exact platform and validates normal importer counters' do
    before = snapshot
    create_imported_message!
    after = snapshot
    stats = {
      imported_contacts: 0,
      imported_archives: 1,
      imported_incoming: 1,
      imported_outgoing: 0,
      imported_messages: 1,
      imported_attachments: 1,
      marker_normalizations: 0
    }

    result = described_class.compare(before: before, after: after, summary_stats: stats)

    expect(result).to be_success
    expect(result.protected_changes).to eq(0)
    expect(result.deleted_rows).to eq(0)
    expect(result.unattributed_changes).to eq(0)
    expect(result.per_platform.fetch('messenger')).to include(
      contacts_created: 0,
      contacts_reused: 1,
      contact_inboxes_created: 0,
      contact_inboxes_reused: 1,
      archives_created: 1,
      messages_created: 1,
      incoming_created: 1,
      outgoing_created: 0,
      attachments_created: 1,
      active_storage_attachments_created: 1,
      active_storage_blobs_created: 1
    )
    expect(result.per_platform.fetch('instagram')).to include(
      archives_created: 0,
      messages_created: 0
    )
  end

  it 'blocks protected drift and summary counters that do not equal the live delta' do
    create_imported_message!
    before = snapshot
    Message.find_by!(source_id: 'mid-1').update!(content: 'unexpected rewrite')
    after = snapshot

    result = described_class.compare(
      before: before,
      after: after,
      summary_stats: {
        imported_contacts: 0,
        imported_archives: 0,
        imported_incoming: 0,
        imported_outgoing: 1,
        imported_messages: 0,
        imported_attachments: 0,
        marker_normalizations: 0
      }
    )

    expect(result).not_to be_success
    expect(result.protected_changes).to eq(1)
    expect(result.counter_mismatches).to include('imported_outgoing')
  end

  it 'isolates importer evidence from concurrent live contact enrichment' do
    create_imported_message!
    before = snapshot
    contact.update!(
      name: 'Live webhook name',
      email: 'live@example.test',
      additional_attributes: { 'social_instagram_user_name' => 'live_username' },
      last_activity_at: 1.minute.from_now
    )
    after = snapshot

    result = described_class.compare(
      before: before,
      after: after,
      summary_stats: {
        imported_contacts: 0,
        imported_archives: 0,
        imported_incoming: 0,
        imported_outgoing: 0,
        imported_messages: 0,
        imported_attachments: 0,
        marker_normalizations: 0,
        history_evidence_changes_applied: 0
      },
      require_zero_writes: true
    )

    expect(result).to be_success
    expect(result.zero_write_observed).to be(true)
  end

  it 'proves a terminal platform pass wrote exactly zero importer-owned rows' do
    before = snapshot
    after = snapshot

    result = described_class.compare(
      before: before,
      after: after,
      summary_stats: {
        imported_contacts: 0,
        imported_archives: 0,
        imported_incoming: 0,
        imported_outgoing: 0,
        imported_messages: 0,
        imported_attachments: 0,
        marker_normalizations: 0
      },
      require_zero_writes: true
    )

    expect(result).to be_success
    expect(result.zero_write_observed).to be(true)
    expect(result.per_platform.values).to all(include(messages_created: 0))
  end

  it 'parses exactly one terminal importer summary and rejects ambiguous evidence' do
    bytes = <<~SUMMARY
      [UMI-FBIG] stage=history_import_summary imported_contacts=1 imported_archives=2 imported_incoming=3 imported_outgoing=4 imported_messages=7 imported_attachments=5 marker_normalizations=6 history_evidence_changes_applied=1
    SUMMARY

    expect(described_class.parse_summary(bytes)).to include(
      imported_contacts: 1,
      imported_messages: 7,
      history_evidence_changes_applied: 1
    )
    expect do
      described_class.parse_summary("#{bytes}#{bytes}")
    end.to raise_error(Umi::Fbig::HistoryStateSnapshot::InvalidSnapshot)
  end

  private

  def snapshot
    Umi::Fbig::HistoryStateSnapshot.capture(inbox, platforms: %w[messenger instagram])
  end

  def create_imported_message!
    original_contact_updated_at = contact.updated_at
    archive = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :resolved,
      identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1",
      additional_attributes: {
        'umi_history_import' => {
          'schema_version' => 1,
          'platform' => 'messenger',
          'thread_id' => 'thread-1',
          'configuration' => {
            'since' => 'all',
            'before' => '2026-07-25T19:00:00Z',
            'outbound_policy' => 'pre_presence'
          }
        }
      }
    )
    message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: archive,
      sender: contact,
      message_type: :incoming,
      source_id: 'mid-1',
      additional_attributes: {
        'umi_history_import' => true,
        'umi_history_schema_version' => 1,
        'umi_history_platform' => 'messenger',
        'umi_history_thread_id' => 'thread-1'
      }
    )
    attachment = Attachment.create!(account: account, message: message, file_type: :file)
    attachment.file.attach(
      io: StringIO.new('attachment bytes'),
      filename: 'file.txt',
      content_type: 'text/plain'
    )
    contact.update!(updated_at: original_contact_updated_at)
  end
end
# rubocop:enable Metrics/MethodLength
