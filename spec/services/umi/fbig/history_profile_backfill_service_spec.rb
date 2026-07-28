require 'rails_helper'

# rubocop:disable Rails/SkipsModelValidations, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Umi::Fbig::HistoryProfileBackfillService do
  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: '1000', instagram_id: '2000')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:graph_client) { instance_double(Umi::Fbig::HistoryImportGraphClient) }
  let(:history_configuration) do
    {
      'since' => 'all',
      'before' => '2026-07-24T19:00:00Z',
      'outbound_policy' => 'pre_presence'
    }
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
  end

  after do
    Redis::Alfred.delete(Umi::Fbig::HistoryImportLock.key(channel.id))
  end

  it 'profiles the union of current participants, importer-owned archives, and Instagram seeds without reading messages' do
    stable_contact = create(:contact, account: account, name: 'Instagram user 101')
    stable_contact_inbox = create(:contact_inbox, contact: stable_contact, inbox: inbox, source_id: '101')
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: stable_contact,
      contact_inbox: stable_contact_inbox,
      identifier: "umi-fbig-history:#{inbox.id}:instagram:thread-stable",
      status: :resolved,
      additional_attributes: {
        'type' => 'instagram_direct_message',
        'umi_history_import' => {
          'schema_version' => 1,
          'platform' => 'instagram',
          'thread_id' => 'thread-stable',
          'configuration' => history_configuration
        }
      }
    )
    current_contact = create(:contact, account: account, name: 'Instagram user 202')
    create(:contact_inbox, contact: current_contact, inbox: inbox, source_id: '202')
    seed_contact = create(:contact, account: account, name: 'Instagram user 303')
    seed_contact_inbox = create(:contact_inbox, contact: seed_contact, inbox: inbox, source_id: '303')
    seed = Umi::Fbig::ProfileTargetManifest::Row.new(
      contact_inbox_id: seed_contact_inbox.id,
      contact_id: seed_contact.id,
      source_id: '303'
    )
    thread = {
      'id' => 'thread-current',
      'participants' => {
        'data' => [
          { 'id' => '2000', 'name' => 'Business' },
          { 'id' => '202', 'name' => 'Current Participant' }
        ]
      }
    }
    allow(graph_client).to receive(:each_thread) do |platform, **, &block|
      block.call(thread) if platform == 'instagram'
      1
    end
    allow(graph_client).to receive(:profile) do |_platform, source_id|
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => source_id, 'name' => "Profile #{source_id}" },
        unavailable_reason: nil
      )
    end
    allow(graph_client).to receive(:messages)
    allow(graph_client).to receive(:detail)
    counts_before = [Contact.count, ContactInbox.count, Conversation.count, Message.count, Attachment.count]

    result = described_class.new(
      inbox,
      dry_run: false,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: [seed],
      graph_client: graph_client,
      max_download_bytes: 100.megabytes,
      max_rate_limit_wait_seconds: 2_000
    ).perform

    expect(result).to be_success
    expect([Contact.count, ContactInbox.count, Conversation.count, Message.count, Attachment.count]).to eq(counts_before)
    expect(result.stats).to include(
      stable_instagram_targets: 2,
      lookup_targets: 3,
      instagram_lookup_targets: 3,
      instagram_targets_success: 2,
      profile_requests: 3,
      profile_successes: 3,
      instagram_placeholders_remaining: 0,
      instagram_placeholders_remaining_fingerprint: Digest::SHA256.hexdigest(''),
      seed_targets_complete: 1,
      seed_targets_repaired: 1,
      scalar_changes_applied: 3,
      exit_failures: 0
    )
    expect(stable_contact.reload.name).to eq('Profile 101')
    expect(current_contact.reload.name).to eq('Profile 202')
    expect(seed_contact.reload.name).to eq('Profile 303')
    expect(graph_client).not_to have_received(:messages)
    expect(graph_client).not_to have_received(:detail)
  end

  it 'captures and finalizes profile evidence while it still owns the writer lock' do
    contact = create(:contact, account: account, name: 'Instagram user 202')
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: '202')
    thread = {
      'id' => 'thread-current',
      'participants' => {
        'data' => [
          { 'id' => '2000', 'name' => 'Business' },
          { 'id' => '202', 'name' => 'Current Participant' }
        ]
      }
    }
    events = []
    evidence = instance_double(Umi::Fbig::ProfileRunEvidence)
    allow(evidence).to receive(:start!) do
      expect(Redis::Alfred.get(Umi::Fbig::HistoryImportLock.key(channel.id))).to be_present
      events << :prestate
    end
    evidence_result = Umi::Fbig::ProfileRunEvidence::Result.new(
      prestate: nil,
      poststate: nil,
      staging: nil,
      comparison: nil,
      reconciliation: Umi::Fbig::AvatarIntentStore::ReconcileResult.new(
        statuses: { attached: 0, absent: 0 },
        entries: []
      )
    )
    allow(evidence).to receive(:finish!) do
      expect(Redis::Alfred.get(Umi::Fbig::HistoryImportLock.key(channel.id))).to be_present
      events << :evidence
      evidence_result
    end
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      events << :meta
      block.call(thread)
      1
    end
    allow(graph_client).to receive(:profile).and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => '202', 'name' => 'Profile 202' },
        unavailable_reason: nil
      )
    )
    allow(Umi::Fbig::HistoryImportLock).to receive(:release).and_wrap_original do |method, *arguments|
      events << :release
      method.call(*arguments)
    end

    result = described_class.new(
      inbox,
      dry_run: true,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: [],
      graph_client: graph_client,
      max_rate_limit_wait_seconds: 2_000,
      run_evidence: evidence
    ).perform

    expect(result).to be_success
    expect(events).to eq(%i[prestate meta evidence release])
    expect(evidence).to have_received(:start!).once
    expect(evidence).to have_received(:finish!).once
  end

  it 'does not profile stable targets after the participant scan becomes incomplete' do
    seed_contact = create(:contact, account: account, name: 'Instagram user 303')
    seed_contact_inbox = create(:contact_inbox, contact: seed_contact, inbox: inbox, source_id: '303')
    seed = Umi::Fbig::ProfileTargetManifest::Row.new(
      contact_inbox_id: seed_contact_inbox.id,
      contact_id: seed_contact.id,
      source_id: '303'
    )
    allow(graph_client).to receive(:each_thread)
      .and_raise(Umi::Fbig::HistoryImportGraphClient::PaginationError, 'conversation page ceiling reached')
    allow(graph_client).to receive(:profile)

    result = described_class.new(
      inbox,
      dry_run: true,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: [seed],
      graph_client: graph_client,
      max_rate_limit_wait_seconds: 2_000
    ).perform

    expect(result).not_to be_success
    expect(result.stats).to include(profile_requests: 0, exit_failures: 1)
    expect(graph_client).not_to have_received(:profile)
  end

  it 'skips one ambiguous participant while continuing to profile valid and stable targets' do
    seed_contact = create(:contact, account: account, name: 'Instagram user 303')
    seed_contact_inbox = create(:contact_inbox, contact: seed_contact, inbox: inbox, source_id: '303')
    current_contact = create(:contact, account: account, name: 'Instagram user 202')
    create(:contact_inbox, contact: current_contact, inbox: inbox, source_id: '202')
    seed = Umi::Fbig::ProfileTargetManifest::Row.new(
      contact_inbox_id: seed_contact_inbox.id,
      contact_id: seed_contact.id,
      source_id: '303'
    )
    ambiguous = {
      'id' => 'thread-ambiguous',
      'participants' => {
        'data' => [
          { 'id' => '2000', 'name' => 'Business' },
          { 'id' => '201', 'name' => 'First' },
          { 'id' => '999', 'name' => 'Second' }
        ]
      }
    }
    valid = {
      'id' => 'thread-valid',
      'participants' => {
        'data' => [
          { 'id' => '2000', 'name' => 'Business' },
          { 'id' => '202', 'name' => 'Current Participant' }
        ]
      }
    }
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(ambiguous)
      block.call(valid)
      1
    end
    allow(graph_client).to receive(:profile) do |_platform, source_id|
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => source_id, 'name' => "Profile #{source_id}" },
        unavailable_reason: nil
      )
    end

    result = described_class.new(
      inbox,
      dry_run: true,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: [seed],
      graph_client: graph_client,
      max_rate_limit_wait_seconds: 2_000
    ).perform

    expect(result).to be_success
    expect(result.degraded).to be(true)
    expect(result.stats).to include(
      ambiguous_participants: 1,
      profile_requests: 2,
      profile_successes: 2,
      exit_failures: 0
    )
  end

  it 'stops all later profile requests after a blocking profile contract failure' do
    first_contact = create(:contact, account: account, name: 'Instagram user 101')
    second_contact = create(:contact, account: account, name: 'Instagram user 202')
    first_contact_inbox = create(:contact_inbox, contact: first_contact, inbox: inbox, source_id: '101')
    second_contact_inbox = create(:contact_inbox, contact: second_contact, inbox: inbox, source_id: '202')
    seeds = [
      Umi::Fbig::ProfileTargetManifest::Row.new(
        contact_inbox_id: first_contact_inbox.id,
        contact_id: first_contact.id,
        source_id: '101'
      ),
      Umi::Fbig::ProfileTargetManifest::Row.new(
        contact_inbox_id: second_contact_inbox.id,
        contact_id: second_contact.id,
        source_id: '202'
      )
    ]
    threads = %w[101 202].map do |source_id|
      {
        'id' => "thread-#{source_id}",
        'participants' => {
          'data' => [
            { 'id' => '2000', 'name' => 'Business' },
            { 'id' => source_id, 'name' => "Participant #{source_id}" }
          ]
        }
      }
    end
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      threads.each(&block)
      1
    end
    allow(graph_client).to receive(:profile)
      .with('instagram', '101')
      .and_raise(Umi::Fbig::HistoryImportGraphClient::ProfileError, :contract_error)

    result = described_class.new(
      inbox,
      dry_run: true,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: seeds,
      graph_client: graph_client,
      max_rate_limit_wait_seconds: 2_000
    ).perform

    expect(result).not_to be_success
    expect(result.stats).to include(
      profile_requests: 1,
      profile_errors: 1,
      seed_targets: 2,
      seed_targets_complete: 1,
      seed_targets_blocked: 1,
      exit_failures: 1
    )
    expect(graph_client).to have_received(:profile).once
    expect(graph_client).not_to have_received(:profile).with('instagram', '202')
  end

  it 'reports preserved and blank-name outcomes for every Instagram seed' do
    preserved_contact = create(:contact, account: account, name: 'Agent-edited name')
    blank_contact = create(:contact, account: account, name: 'Instagram user 202')
    preserved_contact_inbox = create(:contact_inbox, contact: preserved_contact, inbox: inbox, source_id: '101')
    blank_contact_inbox = create(:contact_inbox, contact: blank_contact, inbox: inbox, source_id: '202')
    seeds = [
      Umi::Fbig::ProfileTargetManifest::Row.new(
        contact_inbox_id: preserved_contact_inbox.id,
        contact_id: preserved_contact.id,
        source_id: '101'
      ),
      Umi::Fbig::ProfileTargetManifest::Row.new(
        contact_inbox_id: blank_contact_inbox.id,
        contact_id: blank_contact.id,
        source_id: '202'
      )
    ]
    allow(graph_client).to receive(:each_thread).and_return(1)
    allow(graph_client).to receive(:profile) do |_platform, source_id|
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => source_id, 'name' => '' },
        unavailable_reason: nil
      )
    end

    result = described_class.new(
      inbox,
      dry_run: true,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: seeds,
      graph_client: graph_client,
      max_rate_limit_wait_seconds: 2_000
    ).perform

    expect(result).to be_success
    expect(result.degraded).to be(true)
    expect(result.stats).to include(
      seed_targets: 2,
      seed_targets_complete: 2,
      seed_targets_preserved: 1,
      seed_targets_blank_name: 1,
      instagram_placeholders_remaining: 1,
      instagram_placeholders_blank_name: 1,
      instagram_placeholders_unavailable: 0,
      instagram_placeholders_unclassified: 0
    )
    identity = Digest::SHA256.hexdigest(
      [blank_contact_inbox.id, blank_contact.id, blank_contact_inbox.source_id].join(':')
    )
    fingerprint = Digest::SHA256.hexdigest(identity)
    expect(result.stats.values_at(
             :instagram_placeholders_remaining_fingerprint,
             :instagram_placeholders_classified_fingerprint,
             :instagram_placeholders_blank_name_fingerprint
           )).to all(eq(fingerprint))
  end

  it 'attaches an avatar to the current contact after a ContactInbox relink during download' do
    old_contact = create(:contact, account: account, name: 'Instagram user 202')
    new_contact = create(:contact, account: account, name: 'Merged contact')
    contact_inbox = create(:contact_inbox, contact: old_contact, inbox: inbox, source_id: '202')
    thread = {
      'id' => 'thread-current',
      'participants' => {
        'data' => [
          { 'id' => '2000', 'name' => 'Business' },
          { 'id' => '202', 'name' => 'Current Participant' }
        ]
      }
    }
    allow(graph_client).to receive(:each_thread) do |_platform, **, &block|
      block.call(thread)
      1
    end
    allow(graph_client).to receive(:profile).and_return(
      Umi::Fbig::HistoryImportGraphClient::ProfileResult.new(
        attributes: { 'id' => '202', 'name' => 'Profile 202', 'profile_pic' => 'https://cdn.example/avatar.png' },
        unavailable_reason: nil
      )
    )
    image_file = Tempfile.new(['profile-relink', '.png'], binmode: true)
    image_file.write(File.binread(Rails.root.join('spec/assets/avatar.png')))
    image_file.rewind
    image_result = SafeFetch::Result.new(tempfile: image_file, filename: 'avatar.png', content_type: 'image/png')
    allow(SafeFetch).to receive(:fetch) do |*_arguments, &block|
      contact_inbox.update_columns(contact_id: new_contact.id)
      block.call(image_result)
    end

    result = described_class.new(
      inbox,
      dry_run: false,
      platforms: ['instagram'],
      history_configuration: history_configuration,
      seed_targets: [],
      graph_client: graph_client,
      max_download_bytes: 15.megabytes,
      max_rate_limit_wait_seconds: 2_000
    ).perform

    expect(result).to be_success
    expect(old_contact.reload.avatar).not_to be_attached
    expect(new_contact.reload.avatar).to be_attached
  ensure
    image_file&.close!
  end
end
# rubocop:enable Rails/SkipsModelValidations, RSpec/ExampleLength, RSpec/MultipleExpectations
