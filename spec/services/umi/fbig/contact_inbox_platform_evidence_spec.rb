require 'rails_helper'

RSpec.describe Umi::Fbig::ContactInboxPlatformEvidence do
  let(:account) { create(:account) }
  let(:channel) { build(:channel_facebook_page, account: account, inbox: nil) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '101') }
  let(:history_configuration) do
    {
      'since' => 'all',
      'before' => '2026-07-28T15:39:00Z',
      'outbound_policy' => 'pre_presence'
    }
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
  end

  it 'classifies a native Instagram conversation as Instagram-only evidence' do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { 'type' => 'instagram_direct_message' }
    )

    expect(described_class.classify(contact_inbox)).to eq(:instagram)
  end

  it 'classifies an exact Instagram history archive as Instagram-only evidence' do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      identifier: "umi-fbig-history:#{inbox.id}:instagram:thread-1",
      additional_attributes: {
        'type' => 'instagram_direct_message',
        'umi_history_import' => {
          'schema_version' => Umi::Fbig::HistoryImportService::SCHEMA_VERSION,
          'platform' => 'instagram',
          'thread_id' => 'thread-1',
          'configuration' => history_configuration
        }
      }
    )

    expect(described_class.classify(contact_inbox)).to eq(:instagram)
  end

  it 'classifies native and exact-history Messenger conversations as Messenger evidence' do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1",
      additional_attributes: {
        'umi_history_import' => {
          'schema_version' => Umi::Fbig::HistoryImportService::SCHEMA_VERSION,
          'platform' => 'messenger',
          'thread_id' => 'thread-1',
          'configuration' => history_configuration
        }
      }
    )

    expect(described_class.classify(contact_inbox)).to eq(:messenger)
  end

  it 'classifies a ContactInbox with no linked conversation as unknown' do
    expect(described_class.classify(contact_inbox)).to eq(:unknown)
  end

  it 'classifies linked Instagram and Messenger conversations as ambiguous' do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { 'type' => 'instagram_direct_message' }
    )
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )

    expect(described_class.classify(contact_inbox)).to eq(:ambiguous)
  end

  it 'classifies a history marker that conflicts with the conversation type as ambiguous' do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      identifier: "umi-fbig-history:#{inbox.id}:instagram:thread-1",
      additional_attributes: {
        'umi_history_import' => {
          'schema_version' => Umi::Fbig::HistoryImportService::SCHEMA_VERSION,
          'platform' => 'instagram',
          'thread_id' => 'thread-1',
          'configuration' => history_configuration
        }
      }
    )

    expect(described_class.classify(contact_inbox)).to eq(:ambiguous)
  end
end
