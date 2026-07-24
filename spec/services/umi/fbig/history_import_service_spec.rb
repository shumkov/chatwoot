require 'rails_helper'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
describe Umi::Fbig::HistoryImportService do
  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: 'page-1', instagram_id: 'instagram-1')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:graph_client) { instance_double(Umi::Fbig::HistoryImportGraphClient) }
  let(:before_time) { Time.zone.parse('2025-02-01 00:00:00 UTC') }
  let(:thread) do
    {
      'id' => 'thread-1',
      'participants' => {
        'data' => [
          { 'id' => 'page-1', 'name' => 'Business' },
          { 'id' => 'person-1', 'name' => 'Historical Person' }
        ]
      }
    }
  end
  let(:listings) do
    [
      { 'id' => 'mid-in', 'created_time' => '2025-01-02T03:04:05+0000', 'from' => { 'id' => 'person-1' } },
      { 'id' => 'mid-out', 'created_time' => '2025-01-03T04:05:06+0000', 'from' => { 'id' => 'page-1' } }
    ]
  end
  let(:details) do
    {
      'mid-in' => {
        'id' => 'mid-in',
        'created_time' => '2025-01-02T03:04:05+0000',
        'from' => { 'id' => 'person-1' },
        'to' => { 'data' => [{ 'id' => 'page-1' }] },
        'message' => 'old incoming',
        'reply_to' => { 'mid' => 'prior-mid' }
      },
      'mid-out' => {
        'id' => 'mid-out',
        'created_time' => '2025-01-03T04:05:06+0000',
        'from' => { 'id' => 'page-1' },
        'to' => { 'data' => [{ 'id' => 'person-1' }] },
        'message' => 'old outbound'
      }
    }
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(thread)
      1
    end
    allow(graph_client).to receive(:messages)
      .and_return(Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: listings, pages: 1))
    allow(graph_client).to receive(:detail) { |mid| details.fetch(mid) }
  end

  after do
    Redis::Alfred.delete(Umi::Fbig::HistoryImportLock.key(channel.id))
  end

  it 'loads mirror storage before classifying downloaded attachment jobs' do
    expect { ActiveStorage::Service::MirrorService }.not_to raise_error
  end

  it 'directly imports a resolved historical archive without product events' do
    inbox
    inbox.update!(
      greeting_enabled: true,
      greeting_message: 'This greeting must stay inert',
      working_hours_enabled: true,
      out_of_office_message: 'This out-of-office reply must stay inert'
    )
    create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['This automation must stay inert'] }]
    )
    dispatched_events = []
    result = nil
    allow(Rails.configuration.dispatcher).to receive(:dispatch) { |*arguments| dispatched_events << arguments }
    clear_enqueued_jobs
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    )

    expect { result = service.perform }
      .to change(Contact, :count).by(1)
      .and change(ContactInbox, :count).by(1)
      .and change(Conversation, :count).by(1)
      .and change(Message, :count).by(2)

    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    incoming, outgoing = archive.messages.to_a
    expect(archive).to have_attributes(
      status: 'resolved',
      assignee_id: nil,
      team_id: nil,
      waiting_since: nil,
      first_reply_created_at: nil,
      created_at: Time.zone.parse('2025-01-02 03:04:05 UTC'),
      last_activity_at: Time.zone.parse('2025-01-03 04:05:06 UTC'),
      agent_last_seen_at: Time.zone.parse('2025-01-03 04:05:06 UTC')
    )
    expect(incoming).to have_attributes(
      source_id: 'mid-in',
      message_type: 'incoming',
      status: 'sent',
      sender: archive.contact,
      created_at: Time.zone.parse('2025-01-02 03:04:05 UTC'),
      processed_message_content: 'old incoming'
    )
    expect(incoming.content_attributes['in_reply_to_external_id']).to eq('prior-mid')
    expect(outgoing).to have_attributes(source_id: 'mid-out', message_type: 'outgoing', status: 'delivered', sender: nil)
    expect(outgoing.content_attributes['external_echo']).to be true
    expect(outgoing.additional_attributes['umi_history_import']).to be true
    expect(dispatched_events).to be_empty
    expect(enqueued_jobs).to be_empty
    expect(Notification.where(account: account)).to be_empty
    expect(result).to be_success
  end

  it 'performs the complete classification in dry-run mode without writes' do
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    )

    counts_before = [Contact.count, ContactInbox.count, Conversation.count, Message.count, ActiveStorage::Blob.count]
    result = service.perform

    expect([Contact.count, ContactInbox.count, Conversation.count, Message.count, ActiveStorage::Blob.count]).to eq(counts_before)
    expect(result.stats).to include(
      candidate_incoming: 1,
      candidate_outbound: 1,
      details_fetched: 2,
      imported_messages: 0,
      projected_archives: 1
    )
    expect(result.attachments_downloadable).to eq('unknown')
    expect(result.write_complete).to be_nil
  end

  it 'uses platform-scoped native presence for the pre-presence outbound policy' do
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    live_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: live_conversation, sender: nil,
                     message_type: :outgoing, created_at: Time.zone.parse('2025-01-03 04:05:06 UTC'))
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'pre_presence',
      graph_client: graph_client
    )

    service.perform

    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    expect(archive.messages.pluck(:source_id)).to eq(['mid-in'])
  end

  it 'is idempotent on an exact rerun and rejects a changed configuration before scanning' do
    arguments = {
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    }
    described_class.new(inbox, **arguments).perform

    expect { described_class.new(inbox, **arguments).perform }
      .not_to(change { [Contact.count, ContactInbox.count, Conversation.count, Message.count] })

    changed_arguments = arguments.merge(before: before_time - 1.day)
    expect { described_class.new(inbox, **changed_arguments).perform }
      .to raise_error(described_class::ConfigurationError)
    expect(graph_client).to have_received(:each_thread).twice
  end

  it 'fails an ambiguous thread without creating a partial archive' do
    thread['participants']['data'] << { 'id' => 'person-2', 'name' => 'Another Person' }
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    )

    counts_before = [Contact.count, Conversation.count, Message.count]
    result = service.perform

    expect([Contact.count, Conversation.count, Message.count]).to eq(counts_before)
    expect(result.stats[:ambiguous_participants]).to eq(1)
    expect(result).not_to be_success
  end

  it 'rejects detail payloads that cross the listing trust boundary' do
    details['mid-in']['to']['data'] = [{ 'id' => 'another-page' }]
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    )

    count_before = Message.count
    result = service.perform

    expect(Message.count).to eq(count_before)
    expect(result.stats[:failed_threads]).to eq(1)
    expect(result).not_to be_success
  end

  it 'keeps a visible marker when a historical attachment shape is unsupported' do
    details['mid-in']['message'] = nil
    details['mid-in']['attachments'] = {
      'data' => [{ 'audio_data' => { 'url' => 'https://cdn.example/audio.mp3' } }]
    }
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    )

    service.perform

    message = Message.find_by!(source_id: 'mid-in')
    expect(message.content).to eq('[Historical attachment unavailable: 1]')
    expect(message.additional_attributes['attachment_omissions']).to eq('unsupported_shape' => 1)
  end

  it 'leaves contentless details absent so a later rerun can recover them' do
    details['mid-in']['message'] = nil
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    )

    result = service.perform

    expect(Message.exists?(source_id: 'mid-in')).to be(false)
    expect(Message.exists?(source_id: 'mid-out')).to be(true)
    expect(result.stats[:content_unavailable]).to eq(1)
    expect(result.write_complete).to be(false)
    expect(result).not_to be_success
  end

  it 'keeps attachment omission markers within the message content limit' do
    details['mid-in']['message'] = 'a' * 150_000
    details['mid-in']['attachments'] = {
      'data' => [{ 'audio_data' => { 'url' => 'https://cdn.example/audio.mp3' } }]
    }
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    )

    service.perform

    content = Message.find_by!(source_id: 'mid-in').content
    expect(content.length).to eq(150_000)
    expect(content).to end_with('[Historical attachment unavailable: 1]')
  end

  it 'rejects an archive whose conversation type no longer matches its platform' do
    arguments = {
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client
    }
    described_class.new(inbox, **arguments).perform
    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    archive.update!(additional_attributes: archive.additional_attributes.merge('type' => 'instagram_direct_message'))

    result = described_class.new(inbox, **arguments).perform

    expect(result.stats[:failed_threads]).to eq(1)
    expect(result).not_to be_success
  end

  it 'rejects an Instagram archive whose direct-message type is removed' do
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.last['from']['id'] = 'instagram-1'
    details['mid-in']['to']['data'][0]['id'] = 'instagram-1'
    details['mid-out']['from']['id'] = 'instagram-1'
    arguments = {
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['instagram'],
      outbound_policy: 'all',
      graph_client: graph_client
    }
    described_class.new(inbox, **arguments).perform
    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:instagram:thread-1")
    archive.update!(additional_attributes: archive.additional_attributes.except('type'))

    result = described_class.new(inbox, **arguments).perform

    expect(result.stats[:failed_threads]).to eq(1)
    expect(result).not_to be_success
  end

  it 'rejects another writer while the channel lock is held' do
    inbox
    Umi::Fbig::HistoryImportLock.acquire(channel.id, 'other-run')
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    )

    expect { service.perform }.to raise_error(described_class::LockError)
    expect(graph_client).not_to have_received(:each_thread)
  end

  it 'stops scanning all platforms after an authentication failure' do
    allow(graph_client).to receive(:each_thread)
      .and_raise(Umi::Fbig::HistoryImportGraphClient::AuthenticationError)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: %w[messenger instagram],
      outbound_policy: nil,
      graph_client: graph_client
    )

    result = service.perform

    expect(graph_client).to have_received(:each_thread).once
    expect(result.stats[:authentication_failures]).to eq(1)
    expect(result.scan_complete).to be(false)
    expect(result).not_to be_success
  end

  it 'fails before writing when the lease is lost during detail retrieval' do
    now = Time.zone.parse('2025-02-02 00:00:00 UTC')
    clock = -> { now }
    allow(graph_client).to receive(:detail) do |mid|
      now += 16.minutes
      details.fetch(mid)
    end
    allow(Umi::Fbig::HistoryImportLock).to receive(:renew).and_return(false)
    attachment_service = instance_double(Umi::Fbig::HistoryImportAttachmentService)
    allow(attachment_service).to receive(:plan)
      .and_return(Umi::Fbig::HistoryImportAttachmentService::Plan.new(descriptors: [], omissions: {}))
    allow(attachment_service).to receive(:stage)
    allow(attachment_service).to receive(:cleanup_all_unattached!)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      attachment_service: attachment_service,
      clock: clock
    )

    expect { service.perform }.to raise_error(described_class::LockError)
      .and not_change(Contact, :count)
      .and not_change(Conversation, :count)
      .and not_change(Message, :count)
    expect(Umi::Fbig::HistoryImportLock).to have_received(:renew).once
    expect(attachment_service).not_to have_received(:stage)
  end

  it 'cleans the current staged result when the lease is lost after download' do
    now = Time.zone.parse('2025-02-02 00:00:00 UTC')
    clock = -> { now }
    attachment_service = instance_double(Umi::Fbig::HistoryImportAttachmentService)
    plan = Umi::Fbig::HistoryImportAttachmentService::Plan.new(descriptors: [], omissions: {})
    stage_result = Umi::Fbig::HistoryImportAttachmentService::StageResult.new(attachments: [], omissions: {})
    allow(attachment_service).to receive(:plan).and_return(plan)
    allow(attachment_service).to receive(:stage) do
      now += 16.minutes
      stage_result
    end
    allow(attachment_service).to receive(:cleanup_all_unattached!)
    allow(Umi::Fbig::HistoryImportLock).to receive(:renew).and_return(false)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      attachment_service: attachment_service,
      clock: clock
    )

    expect { service.perform }.to raise_error(described_class::LockError)
    expect(attachment_service).to have_received(:cleanup_all_unattached!).with([stage_result])
  end

  it 'rolls back the thread when the lease is lost during message persistence' do
    now = Time.zone.parse('2025-02-02 00:00:00 UTC')
    clock = -> { now }
    attachment_service = instance_double(Umi::Fbig::HistoryImportAttachmentService)
    plan = Umi::Fbig::HistoryImportAttachmentService::Plan.new(descriptors: [], omissions: {})
    stage_result = Umi::Fbig::HistoryImportAttachmentService::StageResult.new(attachments: [], omissions: {})
    allow(attachment_service).to receive(:plan).and_return(plan)
    allow(attachment_service).to receive(:stage).and_return(stage_result)
    allow(attachment_service).to receive(:persist!) do
      now += 16.minutes
      0
    end
    allow(attachment_service).to receive(:cleanup_all_unattached!).and_return(true)
    allow(Umi::Fbig::HistoryImportLock).to receive(:renew).and_return(true, false)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      attachment_service: attachment_service,
      clock: clock
    )

    expect { service.perform }.to raise_error(described_class::LockError)
      .and not_change(Contact, :count)
      .and not_change(Conversation, :count)
      .and not_change(Message, :count)
  end

  it 'caps logs containing pseudonymous thread and message identifiers' do
    stub_const("#{described_class}::DETAIL_LOG_LIMIT", 1)
    second_thread = thread.deep_dup
    second_thread['id'] = 'thread-2'
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(thread)
      block.call(second_thread)
      1
    end
    logger = instance_double(ActiveSupport::Logger, info: nil)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client,
      logger: logger
    )

    result = service.perform

    expect(logger).to have_received(:info).once
    expect(result.stats[:detail_logs_suppressed]).to eq(1)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
