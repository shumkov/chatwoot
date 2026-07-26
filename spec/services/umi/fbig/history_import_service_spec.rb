require 'rails_helper'

# rubocop:disable Rails/SkipsModelValidations, RSpec/ExampleLength, RSpec/MultipleExpectations
describe Umi::Fbig::HistoryImportService do
  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: 'page-1', instagram_id: 'instagram-1')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:graph_client) { instance_double(Umi::Fbig::HistoryImportGraphClient) }
  let(:before_time) { Time.zone.parse('2025-02-01 00:00:00 UTC') }
  let(:max_download_bytes) { 100.megabytes }
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
    allow(graph_client).to receive(:profile).and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: nil,
        unavailable_reason: :profile_unavailable
      )
    )
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
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
      mids_scanned: 2,
      in_scope_mids_scanned: 2,
      out_of_scope_mids: 0,
      candidate_incoming: 1,
      candidate_outbound: 1,
      details_fetched: 2,
      imported_messages: 0,
      projected_archives: 1
    )
    expect(result.attachments_downloadable).to eq('unknown')
    expect(result.write_complete).to be_nil
  end

  it 'separates raw listings from the strict pre-cutoff conservation set' do
    cutoff_and_later = [
      { 'id' => 'mid-at-cutoff', 'created_time' => before_time.iso8601, 'from' => { 'id' => 'person-1' } },
      { 'id' => 'mid-after-cutoff', 'created_time' => (before_time + 1.second).iso8601, 'from' => { 'id' => 'person-1' } }
    ]
    allow(graph_client).to receive(:messages).and_return(
      Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: listings + cutoff_and_later, pages: 1)
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats).to include(
      mids_scanned: 4,
      in_scope_mids_scanned: 2,
      out_of_scope_mids: 2,
      candidate_incoming: 1,
      candidate_outbound: 1
    )
    expect(graph_client).not_to have_received(:detail).with('mid-at-cutoff')
    expect(graph_client).not_to have_received(:detail).with('mid-after-cutoff')
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    }
    described_class.new(inbox, **arguments).perform

    expect { described_class.new(inbox, **arguments).perform }
      .not_to(change { [Contact.count, ContactInbox.count, Conversation.count, Message.count] })

    changed_arguments = arguments.merge(before: before_time - 1.day)
    expect { described_class.new(inbox, **changed_arguments).perform }
      .to raise_error(described_class::ConfigurationError)
    expect(graph_client).to have_received(:each_thread).twice
  end

  it 'accepts an acknowledged expansion from a contained predecessor interval to all history' do
    predecessor_arguments = {
      since: Time.zone.parse('2025-01-01 00:00:00 UTC'),
      before: before_time - 1.day,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'pre_presence',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    }
    described_class.new(inbox, **predecessor_arguments).perform
    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    preserved_attributes = archive.additional_attributes.deep_dup.merge(
      'operator_metadata' => { 'reviewed' => true }
    )
    archive.update!(additional_attributes: preserved_attributes)
    preserved_messages = archive.messages.order(:id).map do |message|
      message.attributes.except('updated_at')
    end
    expanded_result = nil

    expect do
      expanded_result = described_class.new(
        inbox,
        **predecessor_arguments,
        since: nil,
        before: before_time,
        ack_expand_existing: true
      ).perform
    end.not_to raise_error

    expect(expanded_result).to be_success
    expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(
      'since' => 'all',
      'before' => before_time.iso8601,
      'outbound_policy' => 'pre_presence'
    )
    expect(archive.additional_attributes['operator_metadata']).to eq('reviewed' => true)
    expect(archive.messages.order(:id).map { |message| message.attributes.except('updated_at') }).to eq(preserved_messages)
  end

  # rubocop:disable RSpec/MultipleMemoizedHelpers
  context 'when existing archives use an earlier import configuration' do
    let(:predecessor_since) { Time.zone.parse('2025-01-01 00:00:00 UTC') }
    let(:predecessor_before) { before_time - 1.day }
    let(:predecessor_configuration) do
      {
        'since' => predecessor_since.iso8601,
        'before' => predecessor_before.iso8601,
        'outbound_policy' => 'pre_presence'
      }
    end
    let(:target_configuration) do
      {
        'since' => 'all',
        'before' => before_time.iso8601,
        'outbound_policy' => 'pre_presence'
      }
    end
    let(:predecessor_arguments) do
      {
        since: predecessor_since,
        before: predecessor_before,
        dry_run: false,
        platforms: ['messenger'],
        outbound_policy: 'pre_presence',
        graph_client: graph_client,
        max_download_bytes: max_download_bytes
      }
    end
    let(:target_arguments) do
      {
        since: nil,
        before: before_time,
        dry_run: false,
        platforms: ['messenger'],
        outbound_policy: 'pre_presence',
        ack_expand_existing: true,
        graph_client: graph_client,
        max_download_bytes: max_download_bytes
      }
    end
    let(:archive) do
      Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    end

    before do
      described_class.new(inbox, **predecessor_arguments).perform
    end

    it 'requires the explicit expansion acknowledgement before contacting Meta' do
      expect do
        described_class.new(inbox, **target_arguments, ack_expand_existing: false).perform
      end.to raise_error(described_class::ConfigurationError, /ACK_EXPAND_EXISTING/)
      expect(graph_client).to have_received(:each_thread).once
    end

    it 'accepts a crash-resume mixture and counts a locally valid archive omitted by Meta' do
      second_archive = archive.dup
      second_archive.uuid = SecureRandom.uuid
      second_archive.display_id = nil
      second_archive.identifier = "umi-fbig-history:#{inbox.id}:messenger:thread-2"
      second_attributes = archive.additional_attributes.deep_dup
      second_attributes['umi_history_import']['thread_id'] = 'thread-2'
      second_attributes['umi_history_import']['configuration'] = target_configuration
      second_archive.additional_attributes = second_attributes
      second_archive.save!
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: second_archive,
        message_type: :incoming,
        sender: second_archive.contact,
        source_id: 'mid-thread-2',
        additional_attributes: { 'umi_history_import' => true }
      )
      second_archive.update!(
        status: Conversation.statuses.fetch('resolved'),
        waiting_since: nil,
        created_at: archive.created_at,
        updated_at: archive.updated_at,
        last_activity_at: archive.last_activity_at,
        agent_last_seen_at: archive.agent_last_seen_at
      )

      result = described_class.new(inbox, **target_arguments).perform

      expect(result).to be_success
      expect(result.stats[:predecessor_archive_not_returned]).to eq(1)
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(target_configuration)
      expect(second_archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(target_configuration)
    end

    it 'preflights and counts an archive omitted by Meta during a dry expansion without requiring apply acknowledgement' do
      second_archive = archive.dup
      second_archive.uuid = SecureRandom.uuid
      second_archive.display_id = nil
      second_archive.identifier = "umi-fbig-history:#{inbox.id}:messenger:thread-2"
      second_attributes = archive.additional_attributes.deep_dup
      second_attributes['umi_history_import']['thread_id'] = 'thread-2'
      second_archive.additional_attributes = second_attributes
      second_archive.save!
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: second_archive,
        message_type: :incoming,
        sender: second_archive.contact,
        source_id: 'mid-thread-2',
        additional_attributes: { 'umi_history_import' => true }
      )
      second_archive.update!(
        status: Conversation.statuses.fetch('resolved'),
        waiting_since: nil,
        created_at: archive.created_at,
        updated_at: archive.updated_at,
        last_activity_at: archive.last_activity_at,
        agent_last_seen_at: archive.agent_last_seen_at
      )

      result = described_class.new(
        inbox,
        **target_arguments,
        dry_run: true,
        ack_expand_existing: false,
        max_download_bytes: nil,
        profile_mode: 'defer'
      ).perform

      expect(result.stats[:predecessor_archive_not_returned]).to eq(1)
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)
      expect(second_archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)
    end

    it 'rejects multiple predecessor configurations before contacting Meta' do
      second_archive = archive.dup
      second_archive.uuid = SecureRandom.uuid
      second_archive.display_id = nil
      second_archive.identifier = "umi-fbig-history:#{inbox.id}:messenger:thread-2"
      second_attributes = archive.additional_attributes.deep_dup
      second_attributes['umi_history_import']['thread_id'] = 'thread-2'
      second_attributes['umi_history_import']['configuration'] = predecessor_configuration.merge(
        'since' => (predecessor_since - 1.day).iso8601
      )
      second_archive.additional_attributes = second_attributes
      second_archive.save!
      second_archive.update!(waiting_since: nil)

      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /one predecessor/)
      expect(graph_client).to have_received(:each_thread).once
    end

    it 'rejects a changed outbound policy before contacting Meta' do
      marker = archive.additional_attributes.deep_dup
      marker['umi_history_import']['configuration']['outbound_policy'] = 'all'
      archive.update!(additional_attributes: marker)

      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /outbound policy/)
      expect(graph_client).to have_received(:each_thread).once
    end

    it 'rejects narrower target intervals, including a finite target after an all-history predecessor' do
      narrower_arguments = target_arguments.merge(
        since: predecessor_since + 1.day,
        before: predecessor_before
      )
      expect { described_class.new(inbox, **narrower_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /contain/)

      marker = archive.additional_attributes.deep_dup
      marker['umi_history_import']['configuration']['since'] = 'all'
      archive.update!(additional_attributes: marker)
      finite_arguments = target_arguments.merge(since: predecessor_since - 1.day)

      expect { described_class.new(inbox, **finite_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /contain/)
      expect(graph_client).to have_received(:each_thread).once
    end

    it 'rejects malformed markers and deterministic-prefix impostors before contacting Meta' do
      marker = archive.additional_attributes.deep_dup
      marker['umi_history_import'].delete('configuration')
      archive.update!(additional_attributes: marker)

      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /marker/)

      marker['umi_history_import']['configuration'] = predecessor_configuration
      archive.update!(
        identifier: "#{archive.identifier}:impostor",
        additional_attributes: marker
      )

      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /identifier/)

      archive.update!(identifier: 'renamed-history-archive')
      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /identifier/)

      marker['umi_history_import']['platform'] = 'instagram'
      archive.update!(
        identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1",
        additional_attributes: marker
      )
      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /wrong history platform/)
      expect(graph_client).to have_received(:each_thread).once
    end

    it 'rejects duplicate deterministic identifiers before contacting Meta' do
      duplicate = archive.dup
      duplicate.uuid = SecureRandom.uuid
      duplicate.display_id = nil
      duplicate.save!

      expect { described_class.new(inbox, **target_arguments).perform }
        .to raise_error(described_class::ConfigurationError, /duplicate/)
      expect(graph_client).to have_received(:each_thread).once
    end

    it 'rejects a returned archive whose Meta participant differs from the preflight ContactInbox identity' do
      thread['participants']['data'][1]['id'] = 'person-2'

      result = described_class.new(inbox, **target_arguments).perform

      expect(result).not_to be_success
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)
    end

    it 'rolls back every marker update when an archive changes after the scan' do
      second_archive = archive.dup
      second_archive.uuid = SecureRandom.uuid
      second_archive.display_id = nil
      second_archive.identifier = "umi-fbig-history:#{inbox.id}:messenger:thread-2"
      second_attributes = archive.additional_attributes.deep_dup
      second_attributes['umi_history_import']['thread_id'] = 'thread-2'
      second_archive.additional_attributes = second_attributes
      second_archive.save!
      second_archive.update!(waiting_since: nil)

      allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
        block.call(thread)
        second_archive.update!(status: Conversation.statuses.fetch('open'))
        1
      end

      result = described_class.new(inbox, **target_arguments).perform

      expect(result).not_to be_success
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)
      expect(second_archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)
    end

    it 'rolls back every marker update when ContactInbox identity changes after the scan' do
      contact_inbox = archive.contact_inbox
      allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
        block.call(thread)
        contact_inbox.update!(source_id: 'person-concurrently-changed')
        1
      end

      result = described_class.new(inbox, **target_arguments).perform

      expect(result).not_to be_success
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)
    end

    it 'does not validate or advance an unselected Instagram archive' do
      instagram_archive = archive.dup
      instagram_archive.uuid = SecureRandom.uuid
      instagram_archive.display_id = nil
      instagram_archive.identifier = "umi-fbig-history:#{inbox.id}:instagram:thread-ig"
      instagram_attributes = archive.additional_attributes.deep_dup
      instagram_attributes['type'] = 'instagram_direct_message'
      instagram_attributes['umi_history_import']['platform'] = 'instagram'
      instagram_attributes['umi_history_import']['thread_id'] = 'thread-ig'
      instagram_attributes['umi_history_import'].delete('configuration')
      instagram_archive.additional_attributes = instagram_attributes
      instagram_archive.save!

      result = described_class.new(inbox, **target_arguments).perform

      expect(result).to be_success
      expect(instagram_archive.reload.additional_attributes).to eq(instagram_attributes)
    end

    it 'keeps appended messages rerunnable when marker normalization is interrupted' do
      listings.unshift(
        { 'id' => 'mid-old', 'created_time' => '2024-12-31T03:04:05+0000', 'from' => { 'id' => 'person-1' } }
      )
      details['mid-old'] = {
        'id' => 'mid-old',
        'created_time' => '2024-12-31T03:04:05+0000',
        'from' => { 'id' => 'person-1' },
        'to' => { 'data' => [{ 'id' => 'page-1' }] },
        'message' => 'older incoming'
      }
      interrupted = described_class.new(inbox, **target_arguments)
      allow(interrupted).to receive(:normalize_platform_configuration!).and_raise('interrupted after history persistence')

      first_result = interrupted.perform

      expect(first_result).not_to be_success
      expect(Message.exists?(source_id: 'mid-old')).to be(true)
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(predecessor_configuration)

      rerun_result = described_class.new(inbox, **target_arguments).perform

      expect(rerun_result).to be_success
      expect(Message.where(source_id: 'mid-old').count).to eq(1)
      expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to eq(target_configuration)
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers

  # rubocop:disable RSpec/MultipleMemoizedHelpers
  context 'when an existing Instagram contact has no absent messages' do
    let(:instagram_participant_id) { 'ig-user-1234' }
    let(:profile_payload) { { 'id' => instagram_participant_id, 'name' => 'Profile Person' } }
    let(:profile_graph_client) do
      instance_double(Umi::Fbig::HistoryImportGraphClient)
    end
    let!(:contact) { create(:contact, account: account, name: 'Instagram user 1234') }
    let!(:contact_inbox) do
      create(:contact_inbox, contact: contact, inbox: inbox, source_id: instagram_participant_id)
    end
    let!(:live_conversation) do
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: { 'type' => 'instagram_direct_message' }
      )
    end

    before do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: live_conversation,
        sender: contact,
        message_type: :incoming,
        source_id: 'mid-in',
        created_at: Time.zone.parse('2025-01-02 03:04:05 UTC')
      )

      thread['participants']['data'][0]['id'] = 'instagram-1'
      thread['participants']['data'][1]['id'] = instagram_participant_id
      listings.replace([listings.first])
      listings.first['from']['id'] = instagram_participant_id
      allow(profile_graph_client).to receive(:each_thread) do |_platform, **, &block|
        block.call(thread)
        1
      end
      allow(profile_graph_client).to receive(:messages)
        .and_return(Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: listings, pages: 1))
      allow(profile_graph_client).to receive(:detail)
      allow(profile_graph_client).to receive(:profile).and_return(profile_payload)
    end

    it 'replaces the exact importer-generated placeholder from available profile evidence without creating history rows' do
      counts_before = [Contact.count, ContactInbox.count, Conversation.count, Message.count]

      result = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: false,
        platforms: ['instagram'],
        outbound_policy: 'pre_presence',
        graph_client: profile_graph_client,
        max_download_bytes: max_download_bytes
      ).perform

      expect([Contact.count, ContactInbox.count, Conversation.count, Message.count]).to eq(counts_before)
      expect(result).to be_success
      expect(contact.reload.name).to eq('Profile Person')
      expect(result.stats).to include(profile_requests: 1, profile_successes: 1, profile_changes_applied: 1)

      rerun = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: false,
        platforms: ['instagram'],
        outbound_policy: 'pre_presence',
        graph_client: profile_graph_client,
        max_download_bytes: max_download_bytes
      ).perform

      expect(rerun).to be_success
      expect(rerun.stats[:profile_changes_applied]).to eq(0)
    end

    it 'preserves custom, near-match, and different-suffix names' do
      [
        'Agent-chosen name',
        'Instagram user 1234 — VIP',
        'Instagram user 5678'
      ].each do |preserved_name|
        contact.update!(name: preserved_name)

        described_class.new(
          inbox,
          since: nil,
          before: before_time,
          dry_run: false,
          platforms: ['instagram'],
          outbound_policy: 'pre_presence',
          graph_client: profile_graph_client,
          max_download_bytes: max_download_bytes
        ).perform

        expect(contact.reload.name).to eq(preserved_name)
      end
    end

    it 'preserves the exact placeholder when neither profile nor participant supplies a name candidate' do
      profile_payload.delete('name')
      thread['participants']['data'][1].delete('name')

      described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: false,
        platforms: ['instagram'],
        outbound_policy: 'pre_presence',
        graph_client: profile_graph_client,
        max_download_bytes: max_download_bytes
      ).perform

      expect(contact.reload.name).to eq('Instagram user 1234')
    end

    it 'projects the exact placeholder repair in dry run without changing the contact' do
      result = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: true,
        platforms: ['instagram'],
        outbound_policy: nil,
        graph_client: profile_graph_client
      ).perform

      expect(result.stats[:profile_changes_projected]).to eq(1)
      expect(contact.reload.name).to eq('Instagram user 1234')
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers

  it 'counts a permanently ambiguous new thread without blocking marker normalization or creating rows' do
    thread['participants']['data'] << { 'id' => 'person-2', 'name' => 'Another Person' }
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    )

    counts_before = [Contact.count, Conversation.count, Message.count]
    result = service.perform

    expect([Contact.count, Conversation.count, Message.count]).to eq(counts_before)
    expect(result.stats[:ambiguous_participants]).to eq(1)
    expect(result).to be_success
    expect(result.degraded).to be(true)
  end

  it 'does not request a profile or create rows for a new thread without an absent message candidate' do
    allow(graph_client).to receive(:messages)
      .and_return(Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: [], pages: 1))
    allow(graph_client).to receive(:profile)

    counts_before = [Contact.count, ContactInbox.count, Conversation.count, Message.count]
    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).to be_success
    expect([Contact.count, ContactInbox.count, Conversation.count, Message.count]).to eq(counts_before)
    expect(graph_client).not_to have_received(:profile)
  end

  it 'imports payload evidence in deferred profile mode without profile or avatar work' do
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.last['from']['id'] = 'instagram-1'
    listings.first['from']['username'] = 'observed_username'
    details['mid-in']['from']['username'] = 'detail_username'
    details['mid-in']['to']['data'][0]['id'] = 'instagram-1'
    details['mid-out']['from']['id'] = 'instagram-1'
    allow(graph_client).to receive(:profile)
    allow(SafeFetch).to receive(:fetch)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['instagram'],
      outbound_policy: 'pre_presence',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes,
      profile_mode: 'defer'
    ).perform

    contact = ContactInbox.find_by!(inbox: inbox, source_id: 'person-1').contact
    expect(result).to be_success
    expect(contact.name).to eq('Historical Person')
    expect(contact.additional_attributes).to include(
      'social_profiles' => include('instagram' => 'observed_username'),
      'social_instagram_user_name' => 'observed_username'
    )
    expect(result.stats.values_at(
             :profile_requests,
             :profile_successes,
             :profile_unavailable,
             :profile_errors,
             :profile_changes_projected,
             :profile_changes_applied,
             :avatars_offered,
             :avatars_preserved,
             :avatars_attached,
             :avatar_bytes
           )).to all(be_zero)
    expect(result.stats[:history_evidence_changes_applied]).to eq(1)
    expect(result.stats[:instagram_history_evidence_changes_applied]).to eq(1)
    expect(result.stats[:messenger_history_evidence_changes_applied]).to eq(0)
    expect(graph_client).not_to have_received(:profile)
    expect(SafeFetch).not_to have_received(:fetch)
  end

  it 're-resolves a relinked ContactInbox before applying deferred payload evidence' do
    original_contact = create(:contact, account: account, name: 'Instagram user on-1')
    current_contact = create(:contact, account: account, name: 'Instagram user on-1')
    contact_inbox = create(:contact_inbox, contact: original_contact, inbox: inbox, source_id: 'person-1')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: original_contact,
      contact_inbox: contact_inbox,
      additional_attributes: { 'type' => 'instagram_direct_message' }
    )
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: original_contact,
      message_type: :incoming,
      source_id: 'mid-in',
      created_at: Time.zone.parse('2025-01-02 03:04:05 UTC')
    )
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.replace([listings.first])
    profile_service = Umi::Fbig::HistoryImportProfileService.new
    allow(profile_service).to receive(:plan).and_wrap_original do |method, **arguments|
      plan = method.call(**arguments)
      contact_inbox.update_columns(contact_id: current_contact.id)
      plan
    end

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['instagram'],
      outbound_policy: 'pre_presence',
      graph_client: graph_client,
      profile_service: profile_service,
      max_download_bytes: max_download_bytes,
      profile_mode: 'defer'
    ).perform

    expect(result).to be_success
    expect(original_contact.reload.name).to eq('Instagram user on-1')
    expect(current_contact.reload.name).to eq('Historical Person')
  end

  it 'creates a new contact from profile evidence atomically with its first historical message' do
    profile_result = Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
      attributes: { 'id' => 'person-1', 'first_name' => 'Profile', 'last_name' => 'Person' },
      unavailable_reason: nil
    )
    allow(graph_client).to receive(:profile).with('messenger', 'person-1').and_return(profile_result)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    expect(result).to be_success
    expect(archive.contact.name).to eq('Profile Person')
    expect(archive.messages.count).to eq(2)
    expect(result.stats).to include(profile_requests: 1, profile_successes: 1, profile_changes_applied: 1)
  end

  it 'fills a blank Instagram username from validated incoming detail evidence with one profile request' do
    contact = create(:contact, account: account, name: 'Existing Person')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.last['from']['id'] = 'instagram-1'
    details['mid-in']['from']['username'] = 'detail_username'
    details['mid-in']['to']['data'][0]['id'] = 'instagram-1'
    details['mid-out']['from']['id'] = 'instagram-1'
    allow(graph_client).to receive(:profile).with('instagram', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'name' => 'Profile Person' },
        unavailable_reason: nil
      )
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['instagram'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).to be_success
    expect(contact.reload.additional_attributes).to include(
      'social_profiles' => include('instagram' => 'detail_username'),
      'social_instagram_user_name' => 'detail_username'
    )
    expect(graph_client).to have_received(:profile).with('instagram', 'person-1').once
    expect(result.stats).to include(profile_requests: 1, profile_successes: 1)
  end

  it 'applies profile, listing, and detail evidence once with profile username precedence' do
    contact = create(:contact, account: account, name: 'Existing Person')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.first['from']['username'] = 'listing_username'
    listings.last['from']['id'] = 'instagram-1'
    details['mid-in']['from']['username'] = 'detail_username'
    details['mid-in']['to']['data'][0]['id'] = 'instagram-1'
    details['mid-out']['from']['id'] = 'instagram-1'
    allow(graph_client).to receive(:profile).with('instagram', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'username' => 'profile_username' },
        unavailable_reason: nil
      )
    )
    profile_service = Umi::Fbig::HistoryImportProfileService.new(sleeper: ->(_delay) {})
    allow(profile_service).to receive(:apply!).and_call_original

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['instagram'],
      outbound_policy: 'all',
      graph_client: graph_client,
      profile_service: profile_service,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).to be_success
    expect(result.stats[:profile_changes_applied]).to eq(1)
    expect(contact.reload.additional_attributes).to include(
      'social_profiles' => include('instagram' => 'profile_username'),
      'social_instagram_user_name' => 'profile_username'
    )
    expect(profile_service).to have_received(:apply!).once
    expect(graph_client).to have_received(:profile).with('instagram', 'person-1').once
  end

  it 'projects combined profile and detail evidence once in dry run' do
    contact = create(:contact, account: account, name: 'Instagram user on-1')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.last['from']['id'] = 'instagram-1'
    details['mid-in']['from']['username'] = 'detail_username'
    details['mid-in']['to']['data'][0]['id'] = 'instagram-1'
    details['mid-out']['from']['id'] = 'instagram-1'
    allow(graph_client).to receive(:profile).with('instagram', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'name' => 'Profile Person' },
        unavailable_reason: nil
      )
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['instagram'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats[:profile_changes_projected]).to eq(1)
    expect(contact.reload.additional_attributes).to eq({})
    expect(graph_client).to have_received(:profile).with('instagram', 'person-1').once
  end

  [
    [false, :profile_changes_applied, 'Profile Person'],
    [true, :profile_changes_projected, 'Instagram user on-1']
  ].each do |dry_run, profile_change_stat, expected_name|
    it "preserves existing profile enrichment when classification fails in #{dry_run ? 'dry-run' : 'apply'} mode" do
      contact = create(:contact, account: account, name: 'Instagram user on-1')
      create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
      thread['participants']['data'][0]['id'] = 'instagram-1'
      listings.first['from']['id'] = 'unexpected-sender'
      listings.last['from']['id'] = 'instagram-1'
      allow(graph_client).to receive(:profile).with('instagram', 'person-1').and_return(
        Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
          attributes: { 'id' => 'person-1', 'name' => 'Profile Person' },
          unavailable_reason: nil
        )
      )

      result = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: dry_run,
        platforms: ['instagram'],
        outbound_policy: dry_run ? nil : 'all',
        graph_client: graph_client,
        max_download_bytes: dry_run ? nil : max_download_bytes
      ).perform

      expect(result).not_to be_success
      expect(result.stats[profile_change_stat]).to eq(1)
      expect(contact.reload.name).to eq(expected_name)
      expect(graph_client).to have_received(:profile).with('instagram', 'person-1').once
    end
  end

  it 'applies initial profile evidence when detail preparation later fails' do
    contact = create(:contact, account: account, name: 'Instagram user on-1')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    thread['participants']['data'][0]['id'] = 'instagram-1'
    listings.last['from']['id'] = 'instagram-1'
    allow(graph_client).to receive(:profile).with('instagram', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'name' => 'Profile Person' },
        unavailable_reason: nil
      )
    )
    allow(graph_client).to receive(:detail).with('mid-in').and_raise(
      Umi::Fbig::HistoryImportGraphClient::RequestError,
      :retry_exhausted
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['instagram'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).not_to be_success
    expect(contact.reload.name).to eq('Profile Person')
    expect(result.stats[:profile_changes_applied]).to eq(1)
    expect(graph_client).to have_received(:profile).with('instagram', 'person-1').once
  end

  it 'projects an existing avatar candidate in dry run without downloading or writing it' do
    contact = create(:contact, account: account, name: 'Existing Person')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    allow(graph_client).to receive(:messages)
      .and_return(Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: [], pages: 1))
    allow(graph_client).to receive(:profile).with('messenger', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'profile_pic' => 'https://cdn.example/existing.png' },
        unavailable_reason: nil
      )
    )
    allow(SafeFetch).to receive(:fetch)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats[:avatars_offered]).to eq(1)
    expect(SafeFetch).not_to have_received(:fetch)
    expect(contact.reload.avatar).not_to be_attached
  end

  it 'projects a new-contact avatar candidate in dry run without downloading or writing it' do
    allow(graph_client).to receive(:profile).with('messenger', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'profile_pic' => 'https://cdn.example/new.png' },
        unavailable_reason: nil
      )
    )
    allow(SafeFetch).to receive(:fetch)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats[:avatars_offered]).to eq(1)
    expect(SafeFetch).not_to have_received(:fetch)
    expect(ContactInbox.exists?(inbox_id: inbox.id, source_id: 'person-1')).to be(false)
  end

  it 'deduplicates one new-contact avatar URL across threads in dry run' do
    second_thread = thread.deep_dup
    second_thread['id'] = 'thread-2'
    second_listing = listings.first.deep_dup
    second_listing['id'] = 'mid-in-2'
    second_detail = details['mid-in'].deep_merge('id' => 'mid-in-2')
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(thread)
      block.call(second_thread)
      1
    end
    allow(graph_client).to receive(:messages) do |thread_id, **|
      items = thread_id == 'thread-2' ? [second_listing] : [listings.first]
      Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: items, pages: 1)
    end
    allow(graph_client).to receive(:detail) do |mid|
      mid == 'mid-in-2' ? second_detail : details.fetch(mid)
    end
    allow(graph_client).to receive(:profile).with('messenger', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'profile_pic' => 'https://cdn.example/new.png' },
        unavailable_reason: nil
      )
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats[:avatars_offered]).to eq(1)
    expect(graph_client).to have_received(:profile).with('messenger', 'person-1').once
  end

  it 'projects one existing-contact scalar change across repeated threads in dry run' do
    contact = create(:contact, account: account, name: 'Instagram user on-1')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    second_thread = thread.deep_dup
    second_thread['id'] = 'thread-2'
    thread['participants']['data'][0]['id'] = 'instagram-1'
    second_thread['participants']['data'][0]['id'] = 'instagram-1'
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(thread)
      block.call(second_thread)
      1
    end
    allow(graph_client).to receive(:messages)
      .and_return(Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: [], pages: 1))
    allow(graph_client).to receive(:profile).with('instagram', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1', 'name' => 'Profile Person' },
        unavailable_reason: nil
      )
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['instagram'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats[:profile_changes_projected]).to eq(1)
    expect(contact.reload.name).to eq('Instagram user on-1')
    expect(graph_client).to have_received(:profile).with('instagram', 'person-1').once
  end

  it 'projects one prospective-contact scalar change across repeated threads in dry run' do
    second_thread = thread.deep_dup
    second_thread['id'] = 'thread-2'
    second_listing = listings.first.deep_dup
    second_listing['id'] = 'mid-in-2'
    second_detail = details['mid-in'].deep_merge('id' => 'mid-in-2')
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(thread)
      block.call(second_thread)
      1
    end
    allow(graph_client).to receive(:messages) do |thread_id, **|
      items = thread_id == 'thread-2' ? [second_listing] : [listings.first]
      Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: items, pages: 1)
    end
    allow(graph_client).to receive(:detail) do |mid|
      mid == 'mid-in-2' ? second_detail : details.fetch(mid)
    end

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: true,
      platforms: ['messenger'],
      outbound_policy: nil,
      graph_client: graph_client
    ).perform

    expect(result.stats[:profile_changes_projected]).to eq(1)
    expect(ContactInbox.exists?(inbox_id: inbox.id, source_id: 'person-1')).to be(false)
    expect(graph_client).to have_received(:profile).with('messenger', 'person-1').once
  end

  it 'imports messages after an expected unavailable profile and reports only degradation' do
    unavailable = Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
      attributes: nil,
      unavailable_reason: :profile_unavailable
    )
    allow(graph_client).to receive(:profile).with('messenger', 'person-1').and_return(unavailable)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).to be_success
    expect(result.degraded).to be(true)
    expect(result.stats).to include(profile_requests: 1, profile_unavailable: 1, imported_messages: 2)
  end

  [
    [Umi::Fbig::HistoryImportGraphClient::ProfileError, :identity_mismatch],
    [Umi::Fbig::HistoryImportGraphClient::RequestError, :retry_exhausted]
  ].each do |error_class, reason|
    it "imports eligible messages without merging or queueing an existing contact after #{error_class.name.demodulize}" do
      contact = create(:contact, account: account, name: 'Existing Name', additional_attributes: { 'owner' => 'agent' })
      create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
      profile_service = instance_double(Umi::Fbig::HistoryImportProfileService)
      fallback_plan = Umi::Fbig::HistoryImportProfileService::Plan.new(
        platform: :messenger,
        source_id: 'person-1',
        name_candidate: 'Historical Person',
        instagram_username: nil,
        instagram_optional_attributes: {},
        contact_attributes: { name: 'Changed Name', additional_attributes: { 'owner' => 'agent' } },
        avatar_candidate: Umi::Fbig::HistoryImportProfileService::AvatarCandidate.new(
          url: 'https://cdn.example/should-not-be-queued.png'
        )
      )
      allow(profile_service).to receive(:validate_apply_configuration!).and_return(true)
      allow(profile_service).to receive(:plan).and_return(fallback_plan)
      allow(profile_service).to receive(:apply!).and_return(
        Umi::Fbig::HistoryImportProfileService::ApplyResult.new(
          status: :updated,
          changed: true,
          contact_attributes: fallback_plan.contact_attributes
        )
      )
      allow(profile_service).to receive(:attach_avatar).and_return(
        Umi::Fbig::HistoryImportProfileService::AvatarResult.new(
          status: :attached,
          bytes_used: 1,
          mirror_jobs: 0,
          incomplete: false,
          degraded: false,
          cleanup_failed: false
        )
      )
      allow(graph_client).to receive(:profile).and_raise(error_class, reason)

      result = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: false,
        platforms: ['messenger'],
        outbound_policy: 'all',
        graph_client: graph_client,
        profile_service: profile_service,
        max_download_bytes: max_download_bytes
      ).perform

      expect(result).not_to be_success
      expect(result.stats).to include(profile_requests: 1, profile_errors: 1, imported_messages: 2, platforms_history_complete: 1)
      expect(contact.reload).to have_attributes(name: 'Existing Name', additional_attributes: { 'owner' => 'agent' })
      expect(profile_service).not_to have_received(:plan)
      expect(profile_service).not_to have_received(:apply!)
      expect(profile_service).not_to have_received(:attach_avatar)
      expect(graph_client).to have_received(:profile).with('messenger', 'person-1').once
    end

    it "caches #{error_class.name.demodulize} for repeated threads from one participant" do
      contact = create(:contact, account: account, name: 'Existing Name')
      create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
      second_thread = thread.deep_dup
      second_thread['id'] = 'thread-2'
      allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
        block.call(thread)
        block.call(second_thread)
        1
      end
      allow(graph_client).to receive(:messages)
        .and_return(Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: [], pages: 1))
      allow(graph_client).to receive(:profile).and_raise(error_class, reason)

      result = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: false,
        platforms: ['messenger'],
        outbound_policy: 'all',
        graph_client: graph_client,
        max_download_bytes: max_download_bytes
      ).perform

      expect(result).not_to be_success
      expect(result.stats).to include(profile_requests: 1, profile_errors: 1, threads_scanned: 2)
      expect(graph_client).to have_received(:profile).with('messenger', 'person-1').once
    end
  end

  it 'imports structurally complete history after a profile request error but exits nonzero' do
    allow(graph_client).to receive(:profile)
      .and_raise(Umi::Fbig::HistoryImportGraphClient::RequestError, :retry_exhausted)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).not_to be_success
    expect(result.stats).to include(profile_errors: 1, imported_messages: 2, platforms_history_complete: 1)
    expect(Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1").contact.name)
      .to eq('Historical Person')
  end

  it 'treats profile authentication failure as a platform-blocking history failure' do
    allow(graph_client).to receive(:profile)
      .and_raise(Umi::Fbig::HistoryImportGraphClient::AuthenticationError)
    counts_before = [Contact.count, ContactInbox.count, Conversation.count, Message.count, ActiveStorage::Blob.count]

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).not_to be_success
    expect(result.stats).to include(authentication_failures: 1, imported_messages: 0, platforms_history_complete: 0)
    expect([Contact.count, ContactInbox.count, Conversation.count, Message.count, ActiveStorage::Blob.count]).to eq(counts_before)
  end

  it 'normalizes structurally complete history after a profile contract error but exits nonzero' do
    predecessor_arguments = {
      since: Time.zone.parse('2025-01-01 00:00:00 UTC'),
      before: before_time - 1.day,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    }
    allow(graph_client).to receive(:profile).and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(attributes: {}, unavailable_reason: nil)
    )
    described_class.new(inbox, **predecessor_arguments).perform
    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    allow(graph_client).to receive(:profile).and_raise(Umi::Fbig::HistoryImportGraphClient::ProfileError, :identity_mismatch)

    result = described_class.new(
      inbox,
      **predecessor_arguments,
      since: nil,
      before: before_time,
      ack_expand_existing: true
    ).perform

    expect(result).not_to be_success
    expect(result.stats).to include(profile_errors: 1, marker_normalizations: 1, platforms_history_complete: 1)
    expect(archive.reload.additional_attributes.dig('umi_history_import', 'configuration')).to include(
      'since' => 'all',
      'before' => before_time.iso8601
    )
  end

  it 'spends the shared budget on message attachments before starting the global avatar phase' do
    messenger_contact = create(:contact, account: account, name: 'Existing Person')
    create(:contact_inbox, contact: messenger_contact, inbox: inbox, source_id: 'person-1')
    instagram_contact = create(:contact, account: account, name: 'Instagram Person')
    create(:contact_inbox, contact: instagram_contact, inbox: inbox, source_id: 'instagram-person-1')
    instagram_thread = thread.deep_dup
    instagram_thread['id'] = 'instagram-thread-1'
    instagram_thread['participants']['data'][0]['id'] = 'instagram-1'
    instagram_thread['participants']['data'][1]['id'] = 'instagram-person-1'
    instagram_listings = listings.map(&:deep_dup)
    instagram_listings[0]['id'] = 'instagram-mid-in'
    instagram_listings[0]['from']['id'] = 'instagram-person-1'
    instagram_listings[1]['id'] = 'instagram-mid-out'
    instagram_listings[1]['from']['id'] = 'instagram-1'
    instagram_details = {
      'instagram-mid-in' => details['mid-in'].deep_merge(
        'id' => 'instagram-mid-in',
        'from' => { 'id' => 'instagram-person-1' },
        'to' => { 'data' => [{ 'id' => 'instagram-1' }] }
      ),
      'instagram-mid-out' => details['mid-out'].deep_merge(
        'id' => 'instagram-mid-out',
        'from' => { 'id' => 'instagram-1' },
        'to' => { 'data' => [{ 'id' => 'instagram-person-1' }] }
      )
    }
    allow(graph_client).to receive(:each_thread) do |platform, **, &block|
      block.call(platform == 'instagram' ? instagram_thread : thread)
      1
    end
    allow(graph_client).to receive(:messages) do |thread_id, **|
      items = thread_id == 'instagram-thread-1' ? instagram_listings : listings
      Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: items, pages: 1)
    end
    allow(graph_client).to receive(:detail) do |mid|
      instagram_details.fetch(mid) { details.fetch(mid) }
    end
    events = []
    remaining_budgets = []
    attachment_service = instance_double(Umi::Fbig::HistoryImportAttachmentService)
    attachment_plan = Umi::Fbig::HistoryImportAttachmentService::Plan.new(
      descriptors: [Umi::Fbig::HistoryImportAttachmentService::Descriptor.new(file_type: :image, url: 'hidden')],
      omissions: {}
    )
    blob = instance_double(ActiveStorage::Blob, byte_size: 10, service: Object.new)
    stage_result = Umi::Fbig::HistoryImportAttachmentService::StageResult.new(
      attachments: [
        Umi::Fbig::HistoryImportAttachmentService::StagedAttachment.new(blob: blob, file_type: :image, extension: 'png')
      ],
      omissions: {}
    )
    allow(attachment_service).to receive(:plan).and_return(attachment_plan)
    allow(attachment_service).to receive(:stage) do |remaining_budget_bytes:, **|
      events << :attachment
      remaining_budgets << [:attachment, remaining_budget_bytes]
      stage_result
    end
    allow(attachment_service).to receive(:persist!).and_return(1)
    allow(attachment_service).to receive(:cleanup_all_unattached!).and_return(true)
    profile_service = instance_double(Umi::Fbig::HistoryImportProfileService)
    allow(profile_service).to receive(:validate_apply_configuration!).and_return(true)
    allow(profile_service).to receive(:plan) do |platform:, source_id:, contact:, **|
      Umi::Fbig::HistoryImportProfileService::Plan.new(
        platform: platform.to_sym,
        source_id: source_id,
        name_candidate: contact.name,
        instagram_username: nil,
        instagram_optional_attributes: {},
        contact_attributes: { name: contact.name, additional_attributes: contact.additional_attributes },
        avatar_candidate: Umi::Fbig::HistoryImportProfileService::AvatarCandidate.new(url: 'hidden')
      )
    end
    allow(profile_service).to receive(:apply!).and_return(
      Umi::Fbig::HistoryImportProfileService::ApplyResult.new(
        status: :unchanged,
        changed: false,
        contact_attributes: {}
      )
    )
    allow(profile_service).to receive(:attach_avatar) do |remaining_budget_bytes:, **|
      events << :avatar
      remaining_budgets << [:avatar, remaining_budget_bytes]
      Umi::Fbig::HistoryImportProfileService::AvatarResult.new(
        status: :attached,
        bytes_used: 5,
        mirror_jobs: 0,
        incomplete: false,
        degraded: false,
        cleanup_failed: false
      )
    end
    allow(graph_client).to receive(:profile).and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(attributes: { 'profile_pic' => 'hidden' }, unavailable_reason: nil)
    )

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: %w[messenger instagram],
      outbound_policy: 'all',
      graph_client: graph_client,
      attachment_service: attachment_service,
      profile_service: profile_service,
      max_download_bytes: 100
    ).perform

    expect(result).to be_success
    expect(events).to eq(%i[attachment attachment attachment attachment avatar avatar])
    expect(remaining_budgets).to eq(
      [
        [:attachment, 100],
        [:attachment, 90],
        [:attachment, 80],
        [:attachment, 70],
        [:avatar, 60],
        [:avatar, 55]
      ]
    )
    expect(result.stats).to include(
      attachment_bytes: 40,
      avatar_bytes: 10,
      total_download_bytes: 50,
      avatars_attached: 2,
      platforms_history_complete: 2
    )
  end

  it 'tries a later platform avatar for a shared contact after a permanent first-candidate failure' do
    shared_contact = create(:contact, account: account, name: 'Shared Person')
    create(:contact_inbox, contact: shared_contact, inbox: inbox, source_id: 'person-1')
    create(:contact_inbox, contact: shared_contact, inbox: inbox, source_id: 'instagram-person-1')
    instagram_thread = thread.deep_dup
    instagram_thread['id'] = 'instagram-thread-1'
    instagram_thread['participants']['data'][0]['id'] = 'instagram-1'
    instagram_thread['participants']['data'][1]['id'] = 'instagram-person-1'
    instagram_listings = listings.map(&:deep_dup)
    instagram_listings[0]['id'] = 'instagram-mid-in'
    instagram_listings[0]['from']['id'] = 'instagram-person-1'
    instagram_listings[1]['id'] = 'instagram-mid-out'
    instagram_listings[1]['from']['id'] = 'instagram-1'
    instagram_details = {
      'instagram-mid-in' => details['mid-in'].deep_merge(
        'id' => 'instagram-mid-in',
        'from' => { 'id' => 'instagram-person-1' },
        'to' => { 'data' => [{ 'id' => 'instagram-1' }] }
      ),
      'instagram-mid-out' => details['mid-out'].deep_merge(
        'id' => 'instagram-mid-out',
        'from' => { 'id' => 'instagram-1' },
        'to' => { 'data' => [{ 'id' => 'instagram-person-1' }] }
      )
    }
    allow(graph_client).to receive(:each_thread) do |platform, **, &block|
      block.call(platform == 'instagram' ? instagram_thread : thread)
      1
    end
    allow(graph_client).to receive(:messages) do |thread_id, **|
      platform_listings = thread_id == 'instagram-thread-1' ? instagram_listings : listings
      Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: platform_listings, pages: 1)
    end
    allow(graph_client).to receive(:detail) do |mid|
      instagram_details.fetch(mid) { details.fetch(mid) }
    end
    allow(graph_client).to receive(:profile) do |platform, source_id|
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: {
          'id' => source_id,
          'profile_pic' => "https://cdn.example/#{platform}.png"
        },
        unavailable_reason: nil
      )
    end
    profile_service = instance_double(Umi::Fbig::HistoryImportProfileService)
    allow(profile_service).to receive(:validate_apply_configuration!).and_return(true)
    allow(profile_service).to receive(:plan) do |platform:, source_id:, contact:, profile:, **|
      Umi::Fbig::HistoryImportProfileService::Plan.new(
        platform: platform.to_sym,
        source_id: source_id,
        name_candidate: contact.name,
        instagram_username: nil,
        instagram_optional_attributes: {},
        contact_attributes: { name: contact.name, additional_attributes: contact.additional_attributes },
        avatar_candidate: Umi::Fbig::HistoryImportProfileService::AvatarCandidate.new(url: profile.fetch('profile_pic'))
      )
    end
    allow(profile_service).to receive(:apply!).and_return(
      Umi::Fbig::HistoryImportProfileService::ApplyResult.new(
        status: :unchanged,
        changed: false,
        contact_attributes: {}
      )
    )
    avatar_attempts = []
    allow(profile_service).to receive(:attach_avatar) do |url:, **|
      avatar_attempts << url
      status = url.end_with?('/messenger.png') ? :invalid_url : :attached
      Umi::Fbig::HistoryImportProfileService::AvatarResult.new(
        status: status,
        bytes_used: 0,
        mirror_jobs: 0,
        incomplete: false,
        degraded: status == :invalid_url,
        cleanup_failed: false
      )
    end

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: %w[messenger instagram],
      outbound_policy: 'all',
      graph_client: graph_client,
      profile_service: profile_service,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).to be_success
    expect(avatar_attempts).to eq(
      %w[https://cdn.example/messenger.png https://cdn.example/instagram.png]
    )
    expect(result.stats).to include(avatars_offered: 2, avatars_unavailable: 1, avatars_attached: 1)
  end

  it 'makes no profile or avatar writes on an exact rerun after successful enrichment' do
    image_file = Tempfile.new(['history-profile-avatar', '.png'], binmode: true)
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    avatar_url = 'https://cdn.example/profile.png'
    fetch_result = SafeFetch::Result.new(
      tempfile: image_file,
      filename: 'profile.png',
      content_type: 'image/png'
    )
    allow(SafeFetch).to receive(:fetch).with(
      avatar_url,
      max_bytes: Umi::Fbig::HistoryImportProfileService::MAX_AVATAR_BYTES,
      allowed_content_type_prefixes: [],
      allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES
    ).and_yield(fetch_result)
    allow(graph_client).to receive(:profile).with('messenger', 'person-1').and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: {
          'id' => 'person-1',
          'first_name' => 'Profile',
          'last_name' => 'Person',
          'profile_pic' => avatar_url
        },
        unavailable_reason: nil
      )
    )
    arguments = {
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    }

    first_result = described_class.new(inbox, **arguments).perform
    contact = ContactInbox.find_by!(inbox: inbox, source_id: 'person-1').contact
    baseline = [
      contact.reload.attributes.slice('name', 'additional_attributes', 'updated_at'),
      ActiveStorage::Attachment.where(record_type: 'Contact', record_id: contact.id, name: 'avatar').count,
      ActiveStorage::Blob.count
    ]

    rerun_result = described_class.new(inbox, **arguments).perform

    expect(first_result.stats).to include(profile_changes_applied: 1, avatars_attached: 1)
    expect(rerun_result).to be_success
    expect(rerun_result.stats).to include(profile_changes_applied: 0, avatars_attached: 0, avatars_preserved: 1)
    expect(
      [
        contact.reload.attributes.slice('name', 'additional_attributes', 'updated_at'),
        ActiveStorage::Attachment.where(record_type: 'Contact', record_id: contact.id, name: 'avatar').count,
        ActiveStorage::Blob.count
      ]
    ).to eq(baseline)
    expect(SafeFetch).to have_received(:fetch).once
  ensure
    image_file&.close!
  end

  it 'skips every queued avatar when history persistence is incomplete' do
    contact = create(:contact, account: account, name: 'Existing Person')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'person-1')
    allow(graph_client).to receive(:profile).and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(attributes: { 'profile_pic' => 'hidden' }, unavailable_reason: nil)
    )
    allow(graph_client).to receive(:detail).and_return(nil)
    profile_service = instance_double(Umi::Fbig::HistoryImportProfileService)
    profile_plan = Umi::Fbig::HistoryImportProfileService::Plan.new(
      platform: :messenger,
      source_id: 'person-1',
      name_candidate: 'Existing Person',
      instagram_username: nil,
      instagram_optional_attributes: {},
      contact_attributes: { name: 'Existing Person', additional_attributes: {} },
      avatar_candidate: Umi::Fbig::HistoryImportProfileService::AvatarCandidate.new(url: 'hidden')
    )
    allow(profile_service).to receive(:validate_apply_configuration!).and_return(true)
    allow(profile_service).to receive(:plan).and_return(profile_plan)
    allow(profile_service).to receive(:apply!).and_return(
      Umi::Fbig::HistoryImportProfileService::ApplyResult.new(
        status: :unchanged,
        changed: false,
        contact_attributes: profile_plan.contact_attributes
      )
    )
    allow(profile_service).to receive(:attach_avatar)

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      profile_service: profile_service,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).not_to be_success
    expect(result.stats[:avatars_skipped_history_incomplete]).to eq(1)
    expect(profile_service).not_to have_received(:attach_avatar)
  end

  it 'counts every queued avatar URL skipped by incomplete history' do
    shared_contact = create(:contact, account: account, name: 'Existing Person')
    create(:contact_inbox, contact: shared_contact, inbox: inbox, source_id: 'person-1')
    create(:contact_inbox, contact: shared_contact, inbox: inbox, source_id: 'instagram-person-1')
    instagram_thread = thread.deep_dup
    instagram_thread['id'] = 'instagram-thread-1'
    instagram_thread['participants']['data'][0]['id'] = 'instagram-1'
    instagram_thread['participants']['data'][1]['id'] = 'instagram-person-1'
    allow(graph_client).to receive(:each_thread) do |platform, **, &block|
      block.call(platform == 'instagram' ? instagram_thread : thread)
      1
    end
    allow(graph_client).to receive(:messages) do |thread_id, **|
      items = thread_id == 'instagram-thread-1' ? [] : [listings.first]
      Umi::Fbig::HistoryImportGraphClient::PageResult.new(items: items, pages: 1)
    end
    allow(graph_client).to receive(:detail).with('mid-in').and_return(nil)
    allow(graph_client).to receive(:profile) do |platform, source_id|
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: {
          'id' => source_id,
          'profile_pic' => "https://cdn.example/#{platform}.png"
        },
        unavailable_reason: nil
      )
    end

    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: %w[messenger instagram],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    ).perform

    expect(result).not_to be_success
    expect(result.stats).to include(avatars_offered: 2, avatars_skipped_history_incomplete: 2)
  end

  it 'imports a thread whose downloaded attachment exactly fills the remaining budget' do
    image_file = Tempfile.new(['history-budget', '.png'], binmode: true)
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    fetch_result = SafeFetch::Result.new(
      tempfile: image_file,
      filename: 'historical-image.png',
      content_type: 'image/png'
    )
    details['mid-in']['attachments'] = {
      'data' => [{ 'image_data' => { 'url' => 'https://cdn.example/history.png' } }]
    }
    listings.replace([listings.first])
    allow(SafeFetch).to receive(:fetch).and_yield(fetch_result)
    result = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      max_download_bytes: image_file.size
    ).perform

    expect(result).to be_success
    expect(result.stats).to include(
      download_budget_exhaustions: 0,
      attachment_bytes: image_file.size,
      imported_messages: 1,
      imported_attachments: 1,
      platforms_history_complete: 1
    )
    expect(Message.find_by!(source_id: 'mid-in').attachments.count).to eq(1)
  ensure
    image_file&.close!
  end

  it 'accounts bytes consumed by a transient attachment-stage failure before rethrowing it' do
    attachment_service = instance_double(Umi::Fbig::HistoryImportAttachmentService)
    error = Umi::Fbig::HistoryImportAttachmentService::TransientError.new('transport failed', bytes_used: 7)
    listing = described_class::NormalizedListing.new(payload: { 'id' => 'mid-1' }, created_at: before_time)
    candidate = described_class::Candidate.new(listing: listing, direction: :incoming)
    item = described_class::PreparedMessage.new(candidate: candidate, detail: {}, attachment_plan: :plan, stage_result: nil)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      attachment_service: attachment_service,
      max_download_bytes: 100
    )
    service.instance_variable_set(:@last_renewed_at, Time.current)
    allow(attachment_service).to receive(:stage).and_raise(error)
    allow(attachment_service).to receive(:cleanup_all_unattached!).with([]).and_return(true)

    expect { service.send(:stage_prepared, 'messenger', 'thread-1', [item]) }.to raise_error(error)
    expect(service.instance_variable_get(:@remaining_download_bytes)).to eq(93)
    expect(service.instance_variable_get(:@stats)).to include(attachment_bytes: 7, total_download_bytes: 7)
  end

  it 'records budget exhaustion even when cleanup failure replaces the budget error' do
    attachment_service = instance_double(Umi::Fbig::HistoryImportAttachmentService)
    error = Umi::Fbig::HistoryImportAttachmentService::CleanupError.new(
      'storage unavailable',
      bytes_used: 8,
      budget_exhausted: true
    )
    listing = described_class::NormalizedListing.new(payload: { 'id' => 'mid-1' }, created_at: before_time)
    candidate = described_class::Candidate.new(listing: listing, direction: :incoming)
    item = described_class::PreparedMessage.new(candidate: candidate, detail: {}, attachment_plan: :plan, stage_result: nil)
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'all',
      graph_client: graph_client,
      attachment_service: attachment_service,
      max_download_bytes: 8
    )
    service.instance_variable_set(:@last_renewed_at, Time.current)
    allow(attachment_service).to receive(:stage).and_raise(error)
    allow(attachment_service).to receive(:cleanup_all_unattached!).with([]).and_return(true)

    expect { service.send(:stage_prepared, 'messenger', 'thread-1', [item]) }.to raise_error(error)
    expect(service.instance_variable_get(:@remaining_download_bytes)).to eq(0)
    expect(service.instance_variable_get(:@stats)).to include(
      attachment_bytes: 8,
      total_download_bytes: 8,
      download_budget_exhaustions: 1
    )
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    )

    result = service.perform

    expect(Message.exists?(source_id: 'mid-in')).to be(false)
    expect(Message.exists?(source_id: 'mid-out')).to be(true)
    expect(result.stats[:content_unavailable]).to eq(1)
    expect(result.write_complete).to be(false)
    expect(result).not_to be_success
  end

  it 'accepts only the exact pre-presence contentless set after platform exhaustion' do
    details['mid-in']['message'] = nil
    accepted = {
      'messenger' => Umi::Fbig::ContentlessFingerprint::Result.new(
        count: 1,
        fingerprint: '5dac2c90779ae9e355777801e0dd9439a069de72474f4c279059dc435c756bc4'
      )
    }
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'pre_presence',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes,
      accepted_contentless: accepted,
      profile_mode: 'defer'
    )

    result = service.perform

    expect(result).to be_success
    expect(result.degraded).to be(true)
    expect(Message.exists?(source_id: 'mid-in')).to be(false)
    expect(Message.exists?(source_id: 'mid-out')).to be(true)
    expect(result.stats).to include(
      messenger_contentless_details: 1,
      messenger_contentless_fingerprint: accepted.fetch('messenger').fingerprint,
      contentless_acceptance_mismatches: 0
    )
    expect(result.stats.values_at(:profile_requests, :profile_changes_applied, :avatars_offered, :avatar_bytes)).to all(be_zero)
  end

  it 'retains committed rows but blocks marker normalization when the accepted contentless fingerprint drifts' do
    details['mid-in']['message'] = nil
    accepted = {
      'messenger' => Umi::Fbig::ContentlessFingerprint.build(platform: 'messenger', mids: [])
    }
    service = described_class.new(
      inbox,
      since: nil,
      before: before_time,
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'pre_presence',
      graph_client: graph_client,
      max_download_bytes: max_download_bytes,
      accepted_contentless: accepted
    )

    result = service.perform

    expect(Message.exists?(source_id: 'mid-out')).to be(true)
    expect(result.stats).to include(contentless_acceptance_mismatches: 1, marker_normalizations: 0)
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    }
    described_class.new(inbox, **arguments).perform
    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:messenger:thread-1")
    archive.update!(additional_attributes: archive.additional_attributes.merge('type' => 'instagram_direct_message'))

    expect { described_class.new(inbox, **arguments).perform }
      .to raise_error(described_class::ConfigurationError, /import-only/)
    expect(graph_client).to have_received(:each_thread).once
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
      graph_client: graph_client,
      max_download_bytes: max_download_bytes
    }
    described_class.new(inbox, **arguments).perform
    archive = Conversation.find_by!(identifier: "umi-fbig-history:#{inbox.id}:instagram:thread-1")
    archive.update!(additional_attributes: archive.additional_attributes.except('type'))

    expect { described_class.new(inbox, **arguments).perform }
      .to raise_error(described_class::ConfigurationError, /import-only/)
    expect(graph_client).to have_received(:each_thread).once
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
      clock: clock,
      max_download_bytes: max_download_bytes
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
      clock: clock,
      max_download_bytes: max_download_bytes
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
      clock: clock,
      max_download_bytes: max_download_bytes
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

  describe 'profile read caching' do
    it 'reads a successful profile at most once per platform and participant during a service run' do
      profile_client = double
      profile_result = Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => 'person-1' },
        unavailable_reason: nil
      )
      allow(profile_client).to receive(:profile).and_return(profile_result)
      service = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: true,
        platforms: ['instagram'],
        outbound_policy: nil,
        graph_client: profile_client
      )

      first = service.send(:profile_for, 'instagram', 'person-1')
      second = service.send(:profile_for, 'instagram', 'person-1')

      expect(first).to be(profile_result)
      expect(second).to be(profile_result)
      expect(profile_client).to have_received(:profile).with('instagram', 'person-1').once
    end

    it 'reads an unavailable profile at most once per platform and participant during a service run' do
      profile_client = double
      unavailable_result = Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: nil,
        unavailable_reason: :profile_unavailable
      )
      allow(profile_client).to receive(:profile).and_return(unavailable_result)
      service = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: true,
        platforms: ['messenger'],
        outbound_policy: nil,
        graph_client: profile_client
      )

      first = service.send(:profile_for, 'messenger', 'person-1')
      second = service.send(:profile_for, 'messenger', 'person-1')

      expect(first).to be(unavailable_result)
      expect(second).to be(unavailable_result)
      expect(profile_client).to have_received(:profile).with('messenger', 'person-1').once
    end

    it 'uses the platform as part of the run-local profile cache key' do
      profile_client = double
      results = %w[messenger instagram].index_with do |platform|
        Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
          attributes: { 'id' => 'person-1', 'platform' => platform },
          unavailable_reason: nil
        )
      end
      allow(profile_client).to receive(:profile) { |platform, _participant_id| results.fetch(platform) }
      service = described_class.new(
        inbox,
        since: nil,
        before: before_time,
        dry_run: true,
        platforms: %w[messenger instagram],
        outbound_policy: nil,
        graph_client: profile_client
      )

      expect(service.send(:profile_for, 'messenger', 'person-1')).to be(results.fetch('messenger'))
      expect(service.send(:profile_for, 'instagram', 'person-1')).to be(results.fetch('instagram'))
      expect(profile_client).to have_received(:profile).twice
    end
  end
end
# rubocop:enable Rails/SkipsModelValidations, RSpec/ExampleLength, RSpec/MultipleExpectations
