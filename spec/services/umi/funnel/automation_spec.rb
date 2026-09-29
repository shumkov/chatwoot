# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Funnel automation' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:contact) { conversation.contact }
  let(:event) do
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, conversation_id: conversation.id,
                                   event_type: 'conversation_qualified', occurrence_key: "conversation:#{conversation.id}:qualified",
                                   occurred_at: 1.hour.ago, observed_at: Time.current, provenance: 'operator',
                                   payload: { 'messaging_channel' => 'messenger', 'page_id' => '123', 'scoped_user_id' => '456' })
  end
  let(:delivery) { event.conversion_deliveries.find_by!(destination: 'meta') }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_META_ENABLED: 'true', UMI_FUNNEL_META_ACCOUNT_ID: account.id.to_s,
                      UMI_FUNNEL_META_PAGE_ID: '123', UMI_FUNNEL_META_DATASET_ID: '789', UMI_FUNNEL_META_ACCESS_TOKEN: 'synthetic',
                      UMI_FUNNEL_KLAVIYO_ENABLED: 'true', UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s,
                      UMI_KLAVIYO_PRIVATE_API_KEY: 'synthetic' do
      example.run
    end
  end

  it 'schedules pending outcomes and sends one POST despite duplicate jobs' do
    delivery
    request = stub_request(:post, 'https://graph.facebook.com/v23.0/789/events').to_return(status: 200, body: '{"events_received":1}')
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to have_enqueued_job(Umi::Funnel::DeliveryJob).with(delivery.id)
    2.times { Umi::Funnel::DeliveryJob.perform_now(delivery.id) }
    expect(request).to have_been_requested.once
    expect(delivery.reload.state).to eq('accepted')
  end

  it 'exports a qualified conversation to a unique existing profile without manual binding' do
    contact.update!(email: 'person@example.test', phone_number: nil)
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    profile = { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email } }
    lookup = stub_request(:get, 'https://a.klaviyo.com/api/profiles')
             .with(query: { 'filter' => 'equals(email,"person@example.test")', 'fields[profile]' => 'email,phone_number', 'page[size]' => '2' })
             .to_return(status: 200, body: { data: [profile], links: { next: nil } }.to_json)
    stub_request(:get, 'https://a.klaviyo.com/api/profiles/PROFILE1')
      .with(query: { 'fields[profile]' => 'email,phone_number' }).to_return(status: 200, body: { data: profile }.to_json)
    send_event = stub_request(:post, 'https://a.klaviyo.com/api/events').to_return(status: 202)

    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to have_enqueued_job(Umi::Funnel::DeliveryJob).with(row.id)
    2.times { Umi::Funnel::DeliveryJob.perform_now(row.id) }

    expect(row.reload).to have_attributes(state: 'accepted', destination_key: 'PROFILE1', attempt_count: 1)
    expect(contact.reload.additional_attributes['umi_klaviyo_binding']).to include('source' => 'exact_identifier_match')
    expect(contact.additional_attributes['umi_klaviyo_binding']).not_to have_key('actor_id')
    expect(lookup).to have_been_requested.once
    expect(send_event).to have_been_requested.once
    expect(a_request(:post, %r{/profiles})).not_to have_been_made
  end

  it 'rotates already-unbound identities so the 101st deliverable outcome can run' do
    contact.update!(email: nil, phone_number: nil)
    rows = Array.new(100) do |index|
      source = Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, event_type: 'order_paid',
                                              occurrence_key: "unresolved:#{index}", occurred_at: 1.hour.ago, observed_at: Time.current,
                                              provenance: 'shopify', payload: { currency: 'THB', value: '1.0' })
      source.conversion_deliveries.find_by!(destination: 'meta').update!(state: 'excluded')
      source.conversion_deliveries.find_by!(destination: 'klaviyo')
    end
    identified = create(:contact, account: account, email: 'identified@example.test', phone_number: nil)
    source = Umi::ConversationEvent.record!(account_id: account.id, contact_id: identified.id, event_type: 'order_paid',
                                            occurrence_key: 'ready:101', occurred_at: 1.hour.ago, observed_at: Time.current,
                                            provenance: 'shopify', payload: { currency: 'THB', value: '1.0' })
    source.conversion_deliveries.find_by!(destination: 'meta').update!(state: 'excluded')
    ready = source.conversion_deliveries.find_by!(destination: 'klaviyo')
    rows.each { |row| row.update!(reason: 'profile_unbound', updated_at: 1.hour.ago) }
    ready.update!(updated_at: 30.minutes.ago)

    expect { Umi::Funnel::DeliveryAutomation.enqueue }.not_to have_enqueued_job(Umi::Funnel::DeliveryJob).with(ready.id)
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to have_enqueued_job(Umi::Funnel::DeliveryJob).with(ready.id)
    expect(a_request(:any, /klaviyo/)).not_to have_been_made
  end

  it 'leaves a frozen recipient unchanged when a fresh lookup finds another profile' do
    contact.update!(email: 'person@example.test', phone_number: nil)
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    row.update!(destination_key: 'ORIGINAL', payload: { 'frozen' => true })
    client = instance_double(Umi::Funnel::KlaviyoClient,
                             profiles: { 'data' => [{ 'id' => 'OTHER', 'attributes' => { 'email' => contact.email } }] })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)

    Umi::Funnel::DeliveryJob.perform_now(row.id)

    expect(row.reload).to have_attributes(reason: 'preparation_failed', destination_key: 'ORIGINAL', payload: { 'frozen' => true }, attempt_count: 0)
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
    expect(a_request(:post, /klaviyo/)).not_to have_been_made
  end

  it 'does not restore identity or export when erasure overlaps automatic profile lookup' do
    contact.update!(email: 'person@example.test', phone_number: nil)
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    profile = { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email } }
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profiles) do
      Umi::Shopify::CustomerRedactionService.new(Contact.find(contact.id)).perform
      { 'data' => [profile] }
    end

    Umi::Funnel::DeliveryJob.perform_now(row.id)

    expect(row.reload).to have_attributes(state: 'excluded', attempt_count: 0, payload: {})
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
    expect(a_request(:post, /klaviyo/)).not_to have_been_made
  end

  it 'does not look up an unbound profile when the destination is disabled after enqueue' do
    contact.update!(email: 'person@example.test')
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'false' do
      Umi::Funnel::DeliveryJob.perform_now(row.id)
    end
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
    expect(a_request(:any, /klaviyo/)).not_to have_been_made
  end

  it 'checks disabled destination after enqueue' do
    delivery
    with_modified_env UMI_FUNNEL_META_ENABLED: 'false' do
      Umi::Funnel::DeliveryJob.perform_now(delivery.id)
    end
    expect(delivery.reload.attempt_count).to eq(0)
    expect(a_request(:post, /facebook/)).not_to have_been_made
  end

  it 'holds preparation errors instead of repeatedly scheduling a broken destination' do
    delivery
    with_modified_env UMI_FUNNEL_META_DATASET_ID: nil do
      Umi::Funnel::DeliveryJob.perform_now(delivery.id)
    end
    expect(delivery.reload).to have_attributes(state: 'pending', reason: 'preparation_failed', last_error: 'KeyError')
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.not_to have_enqueued_job(Umi::Funnel::DeliveryJob).with(delivery.id)
    Umi::Funnel::DeliveryService.new(delivery).prepare
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to have_enqueued_job(Umi::Funnel::DeliveryJob).with(delivery.id)
  end

  it 'does not repeatedly fetch missing or conflicting profile identities' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    Umi::Funnel::DeliveryAutomation.enqueue
    expect(row.reload.reason).to eq('profile_unbound')
    expect(a_request(:get, /klaviyo/)).not_to have_been_made
    contact.update!(additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    row.update!(reason: 'profile_identity_conflict')
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.not_to have_enqueued_job(Umi::Funnel::DeliveryJob).with(row.id)
  end

  it 'reserves only three due readbacks and never resends an accepted event' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    row.update!(state: 'accepted', destination_key: 'PROFILE1', accepted_at: Time.current.change(usec: 0))
    client = instance_double(Umi::Funnel::KlaviyoClient, events: { 'data' => [], 'links' => {} })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    [5.minutes, 30.minutes, 2.hours].each_with_index do |delay, index|
      travel_to(row.accepted_at + delay) do
        2.times { Umi::Funnel::ReadbackJob.perform_now(row.id) }
        expect(row.reload.readback_attempt_count).to eq(index + 1)
      end
    end
    travel_to(row.accepted_at + 1.day) do
      expect { Umi::Funnel::DeliveryAutomation.enqueue }.not_to have_enqueued_job(Umi::Funnel::ReadbackJob)
      Umi::Funnel::ReadbackJob.perform_now(row.id)
    end
    expect(client).to have_received(:events).exactly(3).times
    expect(row.reload.state).to eq('accepted')
    expect(a_request(:post, /klaviyo/)).not_to have_been_made
  end

  it 'consumes a failed readback slot and preserves erasure during the failed read' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    row.update!(state: 'accepted', destination_key: 'PROFILE1', accepted_at: 10.minutes.ago)
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:events) do
      Umi::Shopify::CustomerRedactionService.new(contact).perform
      raise Umi::Funnel::KlaviyoClient::Error, 'sanitized'
    end
    Umi::Funnel::ReadbackJob.perform_now(row.id)
    expect(row.reload).to have_attributes(readback_attempt_count: 1, reason: 'erasure_required', payload: {})
  end

  it 'checks a disabled account before a queued job can fetch a bound profile' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    contact.update!(additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: '' do
      Umi::Funnel::DeliveryJob.perform_now(row.id)
    end
    expect(row.reload).to have_attributes(reason: 'account_disabled', attempt_count: 0)
    expect(a_request(:any, /klaviyo/)).not_to have_been_made
  end

  it 'recovers a lost enqueue on the next scan and leaves terminal states alone' do
    delivery
    allow(Umi::Funnel::DeliveryJob).to receive(:perform_later).and_raise(StandardError)
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to raise_error(StandardError)
    allow(Umi::Funnel::DeliveryJob).to receive(:perform_later).and_call_original
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to have_enqueued_job(Umi::Funnel::DeliveryJob).with(delivery.id)
    %w[sending unknown rejected excluded accepted confirmed].each do |state|
      delivery.update!(state: state)
      expect { Umi::Funnel::DeliveryAutomation.enqueue }.not_to have_enqueued_job(Umi::Funnel::DeliveryJob).with(delivery.id)
    end
  end

  it 'keeps a preparation read failure held until an explicit successful preview' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    contact.update!(email: 'person@example.test', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profile).and_raise(Umi::Funnel::KlaviyoClient::Error, 'private provider body')
    discarded = []
    listener = ->(*args) { discarded << args.last[:error].message }
    ActiveSupport::Notifications.subscribed(listener, 'discard.active_job') do
      2.times { Umi::Funnel::DeliveryJob.perform_now(row.id) }
    end
    expect(discarded.join).not_to include('private provider body')
    expect(client).to have_received(:profile).once
    expect(row.reload).to have_attributes(reason: 'preparation_failed', last_error: 'Umi::Funnel::KlaviyoClient::Error', attempt_count: 0)
    allow(client).to receive(:profile).and_return('id' => 'PROFILE1', 'attributes' => { 'email' => contact.email })
    Umi::Funnel::DeliveryService.new(row).prepare
    expect(row.reload.reason).to be_nil
    expect(row.last_error).to be_nil
    expect { Umi::Funnel::DeliveryAutomation.enqueue }.to have_enqueued_job(Umi::Funnel::DeliveryJob).with(row.id)
  end

  it 'consumes a reserved slot after process loss and caps each readback at ten pages' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    row.update!(state: 'accepted', destination_key: 'PROFILE1', accepted_at: 10.minutes.ago)
    service = Umi::Funnel::DeliveryService.new(row)
    allow(service).to receive(:confirm).and_raise(Interrupt)
    expect { service.confirm_scheduled }.to raise_error(Interrupt)
    expect(row.reload.readback_attempt_count).to eq(1)
    client = instance_double(Umi::Funnel::KlaviyoClient,
                             events: { 'data' => [], 'links' => { 'next' => 'https://a.test?page%5Bcursor%5D=next' } })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    Umi::Funnel::ReadbackJob.perform_now(row.id)
    expect(client).not_to have_received(:events)
    travel_to(row.accepted_at + 31.minutes) { Umi::Funnel::ReadbackJob.perform_now(row.id) }
    expect(client).to have_received(:events).exactly(10).times
    expect(row.reload).to have_attributes(state: 'accepted', reason: 'readback_page_limit', readback_attempt_count: 2)
  end

  it 'limits dispatch and due readback enqueues to one hundred oldest rows each' do
    delivery
    101.times do |index|
      source = Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, event_type: 'order_paid',
                                              occurrence_key: "paid:#{index}", occurred_at: 1.hour.ago, observed_at: Time.current,
                                              provenance: 'shopify', payload: { currency: 'THB', value: '1.0' })
      source.conversion_deliveries.find_by!(destination: 'klaviyo').update!(state: 'accepted', destination_key: 'PROFILE1',
                                                                            accepted_at: 10.minutes.ago)
    end
    dispatches = have_enqueued_job(Umi::Funnel::DeliveryJob).exactly(100).times
    readbacks = have_enqueued_job(Umi::Funnel::ReadbackJob).exactly(100).times
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      expect { Umi::Funnel::DeliveryAutomation.enqueue }.to dispatches.and(readbacks)
    end
  end

  it 'reports preparation holds and exhausted accepted readbacks without treating them as confirmed' do
    delivery.update!(reason: 'preparation_failed', last_error: 'KeyError')
    event.conversion_deliveries.find_by!(destination: 'klaviyo').update!(state: 'accepted', accepted_at: 1.day.ago, readback_attempt_count: 3)
    result = Umi::Funnel::Report.perform(account_id: account.id, since: 1.day.ago)
    expect(result).to include(preparation_holds: 1, exhausted_readbacks: 1)
  end

  it 'does not let an overlapping successful profile read clear another automatic job preparation hold' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    contact.update!(email: 'person@example.test', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    client = instance_double(Umi::Funnel::KlaviyoClient, create_event: { state: 'accepted' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profile) do
      Umi::Funnel::DeliveryService.new(Umi::ConversionDelivery.find(row.id)).hold_preparation(Umi::Funnel::KlaviyoClient::Error.new)
      { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email } }
    end
    Umi::Funnel::DeliveryJob.perform_now(row.id)
    expect(row.reload).to have_attributes(state: 'pending', reason: 'preparation_failed', attempt_count: 0)
    expect(client).not_to have_received(:create_event)
  end
end
