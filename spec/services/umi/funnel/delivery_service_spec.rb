# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::DeliveryService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:contact) { conversation.contact }
  let(:occurred_at) { 1.hour.ago.change(usec: 0) }
  let(:messaging_channel) { 'messenger' }
  let(:event) do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: contact.id,
                                   event_type: 'conversation_qualified', occurrence_key: "conversation:#{conversation.id}:qualified",
                                   occurred_at: occurred_at, observed_at: Time.current, provenance: 'operator',
                                   payload: { 'messaging_channel' => messaging_channel, 'page_id' => '123', 'scoped_user_id' => '456',
                                              'instagram_id' => '987',
                                              'qualification_reason' => 'Requested fitting' })
  end
  let(:delivery) { event.conversion_deliveries.find_by!(destination: 'meta') }
  let(:service) { described_class.new(delivery) }
  let(:klaviyo) { instance_double(Umi::Funnel::KlaviyoClient) }
  let(:profile) { { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email, 'phone_number' => contact.phone_number } } }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_META_ACCOUNT_ID: account.id.to_s, UMI_FUNNEL_META_PAGE_ID: '123', UMI_FUNNEL_META_DATASET_ID: '789',
                      UMI_FUNNEL_META_ACCESS_TOKEN: 'meta-secret', UMI_FUNNEL_META_ENABLED: 'false',
                      UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s, UMI_KLAVIYO_PRIVATE_API_KEY: 'klaviyo-secret',
                      UMI_FUNNEL_KLAVIYO_ENABLED: 'false' do
      example.run
    end
  end

  it 'prepares an occurrence-time Messenger qualification without sending it' do
    service.prepare

    expect(delivery.reload.destination_key).to eq('123:789')
    expect(delivery.payload['data']).to eq([{ 'event_name' => 'QualifiedLead', 'event_time' => occurred_at.to_i,
                                              'action_source' => 'business_messaging', 'messaging_channel' => 'messenger',
                                              'user_data' => { 'page_id' => '123', 'page_scoped_user_id' => '456' } }])
    expect(delivery.state).to eq('pending')
    expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
  end

  it 'leaves disabled delivery pending without making a provider call' do
    service.prepare
    service.dispatch

    expect(delivery.reload).to have_attributes(state: 'pending', attempt_count: 0, reason: 'dispatch_disabled')
  end

  context 'when a qualified lead comes from Instagram' do
    let(:messaging_channel) { 'instagram' }

    around do |example|
      with_modified_env UMI_FUNNEL_META_INSTAGRAM_ID: '987' do
        example.run
      end
    end

    it 'prepares Instagram qualification instead of excluding the active advertising channel' do
      service.prepare

      expect(delivery.reload).to have_attributes(state: 'pending', reason: nil, destination_key: '987:789')
      expect(delivery.payload['data']).to eq([{ 'event_name' => 'QualifiedLead', 'event_time' => occurred_at.to_i,
                                                'action_source' => 'business_messaging', 'messaging_channel' => 'instagram',
                                                'user_data' => { 'ig_account_id' => '987', 'ig_sid' => '456' } }])
      expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
    end

    it 'does not send an Instagram qualification for a different business account' do
      with_modified_env UMI_FUNNEL_META_INSTAGRAM_ID: '999', UMI_FUNNEL_META_ENABLED: 'true' do
        service.dispatch
      end

      expect(delivery.reload).to have_attributes(state: 'excluded', reason: 'channel_identity_mismatch', attempt_count: 0)
      expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
    end
  end

  context 'when a qualification comes from an unsupported messaging channel' do
    let(:messaging_channel) { 'other' }

    it 'does not export it' do
      with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
        service.dispatch
      end

      expect(delivery.reload).to have_attributes(state: 'excluded', reason: 'channel_not_enabled', attempt_count: 0)
      expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
    end
  end

  it 'commits the claim before sending once and does not send an accepted event again' do
    service.prepare
    client = instance_double(Umi::Funnel::MetaClient)
    allow(Umi::Funnel::MetaClient).to receive(:new).and_return(client)
    allow(client).to receive(:send_events) do
      expect(Umi::ConversionDelivery.find(delivery.id)).to have_attributes(state: 'sending', attempt_count: 1)
      { state: 'accepted', reference: 'receipt' }
    end
    with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
      service.dispatch
      service.dispatch
    end

    expect(client).to have_received(:send_events).once
    expect(delivery.reload).to have_attributes(state: 'accepted', provider_reference: 'receipt')
    expect(delivery.confirmed_at).to be_nil
  end

  it 'does not send an old frozen payload after the source identity changes at claim' do
    service.prepare
    original = delivery.payload.deep_dup
    calls = 0
    allow(service).to receive(:provider_payload).and_wrap_original do |method, *args|
      calls += 1
      result = method.call(*args)
      result.first['data'].first['user_data']['page_scoped_user_id'] = '999' if calls == 2
      result
    end
    client = instance_double(Umi::Funnel::MetaClient, send_events: { state: 'accepted' })
    allow(Umi::Funnel::MetaClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
      service.dispatch
    end
    expect(delivery.reload).to have_attributes(state: 'pending', reason: 'prepared_source_changed', attempt_count: 0, payload: original)
    expect(client).not_to have_received(:send_events)
  end

  it 'keeps a lost response unknown and never retries it' do
    service.prepare
    client = instance_double(Umi::Funnel::MetaClient, send_events: { state: 'unknown', error: 'Net::ReadTimeout' })
    allow(Umi::Funnel::MetaClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
      service.dispatch
      service.dispatch
    end

    expect(delivery.reload).to have_attributes(state: 'unknown', last_error: 'Net::ReadTimeout')
    expect(client).to have_received(:send_events).once
  end

  it 'holds a sending row after a process crash without resending' do
    service.prepare
    delivery.update!(state: 'sending', attempted_at: 1.hour.ago, attempt_count: 1)
    with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
      service.dispatch
      service.hold_interrupted
    end

    expect(delivery.reload.state).to eq('unknown')
    expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
  end

  it 'refuses to silently redirect an already prepared event to another dataset' do
    service.prepare
    with_modified_env UMI_FUNNEL_META_DATASET_ID: '999', UMI_FUNNEL_META_ENABLED: 'true' do
      expect { service.dispatch }.to raise_error(ArgumentError, /destination/)
    end
    expect(delivery.reload.attempt_count).to eq(0)
    expect(delivery.destination_key).to eq('123:789')
  end

  it 'excludes a pre-activation paid occurrence even when observed just now' do
    event = Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, event_type: 'order_paid',
                                           occurrence_key: 'shopify:shop:order:1001:paid', occurred_at: 10.days.ago,
                                           observed_at: Time.current, provenance: 'shopify',
                                           payload: { 'order_id' => '1001', 'shop_domain' => 'shop', 'value' => '4000.0', 'currency' => 'THB' })
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    described_class.new(row).prepare

    expect(row.reload).to have_attributes(state: 'excluded', reason: 'pre_boundary')
  end

  [nil, 1.day.from_now].each do |time|
    context "when occurrence time is #{time.inspect}" do
      let(:occurred_at) { time }

      it 'does not replace missing or future event time with now' do
        service.prepare
        expect(delivery.reload.state).to eq('excluded')
      end
    end
  end

  it 'excludes older Messenger events rather than changing their timestamp' do
    with_modified_env UMI_FUNNEL_STARTED_AT: 30.days.ago.utc.iso8601 do
      allow(event).to receive(:occurred_at).and_return(8.days.ago)
      delivery
      allow(delivery).to receive(:conversation_event).and_return(event)
      service.prepare
    end
    expect(delivery.reload.reason).to eq('event_too_old')
  end

  it 'rechecks erasure before claiming a previously prepared event' do
    service.prepare
    Umi::Shopify::CustomerRedactionService.new(contact).perform
    with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
      service.dispatch
    end

    expect(delivery.reload).to have_attributes(state: 'excluded', payload: {}, attempt_count: 0)
    expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
  end

  it 'does not export a qualification corrected after it was prepared' do
    service.prepare
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, conversation_id: conversation.id,
                                   event_type: 'classification_changed', occurrence_key: 'classification:correction', occurred_at: Time.current,
                                   observed_at: Time.current, provenance: 'operator', payload: { 'status' => 'not_sales' })
    with_modified_env UMI_FUNNEL_META_ENABLED: 'true' do
      service.dispatch
    end

    expect(delivery.reload).to have_attributes(state: 'excluded', reason: 'qualification_corrected', attempt_count: 0)
  end

  it 'keeps an anonymous Klaviyo occurrence pending for later verified binding' do
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    described_class.new(row).prepare
    expect(row.reload).to have_attributes(state: 'pending', reason: 'profile_unbound')

    contact.update!(email: 'person@example.com', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(klaviyo)
    allow(klaviyo).to receive(:profile).with('PROFILE1').and_return(profile)
    described_class.new(row).prepare
    attrs = row.reload.payload.dig('data', 'attributes')
    expect(attrs.dig('profile', 'data')).to eq('type' => 'profile', 'id' => 'PROFILE1', 'attributes' => {})
    expect(attrs['unique_id']).to eq("umi-funnel-#{account.id}-#{event.id}")
    expect(attrs['time']).to eq(occurred_at.utc.iso8601)
    expect(attrs.dig('metric', 'data', 'attributes', 'name')).to eq('UMI Conversation Qualified')
    expect(row.reason).to be_nil
  end

  it 'rechecks changed Klaviyo identity before any send' do
    contact.update!(email: 'person@example.com', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(klaviyo)
    allow(klaviyo).to receive(:profile).and_return(profile)
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    described_class.new(row).prepare
    allow(klaviyo).to receive(:profile).and_return(profile.merge('attributes' => { 'email' => 'different@example.com' }))
    with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'true' do
      described_class.new(row).dispatch
    end
    expect(row.reload).to have_attributes(state: 'pending', reason: 'profile_identity_conflict', attempt_count: 0)
  end

  it 'confirms Klaviyo only after exact profile, metric and occurrence readback' do
    contact.update!(email: 'person@example.com', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(klaviyo)
    allow(klaviyo).to receive(:profile).and_return(profile)
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    delivery_service = described_class.new(row)
    delivery_service.prepare
    row.update!(state: 'accepted', accepted_at: Time.current)
    remote_event = { 'id' => 'REMOTE1', 'attributes' => { 'datetime' => occurred_at.iso8601,
                                                          'event_properties' => { 'umi_event_id' => event.id.to_s } },
                     'relationships' => { 'profile' => { 'data' => { 'id' => 'PROFILE1' } }, 'metric' => { 'data' => { 'id' => 'METRIC1' } } } }
    page = { 'data' => [remote_event], 'included' => [{ 'type' => 'metric', 'id' => 'METRIC1',
                                                        'attributes' => { 'name' => 'UMI Conversation Qualified' } }], 'links' => {} }
    allow(klaviyo).to receive(:events).and_return(page)
    delivery_service.confirm

    expect(row.reload).to have_attributes(state: 'confirmed', provider_reference: 'REMOTE1')
  end

  it 'preserves the downstream erasure marker when erasure overlaps empty readback' do
    contact.update!(email: 'person@example.com', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(klaviyo)
    allow(klaviyo).to receive(:profile).and_return(profile)
    row = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    delivery_service = described_class.new(row)
    delivery_service.prepare
    row.update!(state: 'accepted', accepted_at: Time.current)
    allow(klaviyo).to receive(:events) do
      Umi::Shopify::CustomerRedactionService.new(contact).perform
      { 'data' => [], 'included' => [], 'links' => {} }
    end
    delivery_service.confirm

    expect(row.reload).to have_attributes(reason: 'erasure_required', payload: {})
  end

  it 'exports the original kept-item paid value after a later partial refund' do
    contact.update!(email: 'person@example.com', additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    hook = create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com')
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                         conversation_id: conversation.id, contact_id: contact.id,
                                         attribution_state: 'verified', token_nonce: 'paid-test')
    order = { 'id' => 1001, 'created_at' => 1.day.ago.iso8601, 'updated_at' => occurred_at.iso8601, 'financial_status' => 'paid',
              'test' => false, 'currency' => 'THB', 'total_price' => '12000.00', 'current_total_price' => '4000.00' }
    sale = { 'id' => 2001, 'kind' => 'sale', 'status' => 'success', 'currency' => 'THB', 'amount' => '4000.00',
             'processed_at' => occurred_at.iso8601 }
    transactions = [sale]
    shopify = instance_double(ShopifyAPI::Clients::Rest::Admin)
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).and_return(shopify)
    allow(shopify).to receive(:get).with(path: 'orders/1001', query: anything)
                                   .and_return(ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'order' => order }))
    allow(shopify).to receive(:get).with(path: 'orders/1001/transactions', query: anything)
                                   .and_return(ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {},
                                                                                     body: { 'transactions' => transactions }))
    state = Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '1001')
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    paid = state.reload.paid_event
    order['financial_status'] = 'partially_refunded'
    order['current_total_price'] = '3000.00'
    transactions << sale.merge('id' => 2002, 'kind' => 'refund', 'amount' => '1000.00')
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(klaviyo)
    allow(klaviyo).to receive(:profile).and_return(profile)
    allow(klaviyo).to receive(:create_event).and_return(state: 'accepted')
    row = paid.conversion_deliveries.find_by!(destination: 'klaviyo')
    with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'true' do
      described_class.new(row).dispatch
    end

    expect(row.reload.state).to eq('accepted')
    expect(row.payload.dig('data', 'attributes')).to include('value' => 4000.0, 'value_currency' => 'THB', 'time' => occurred_at.utc.iso8601)
    expect(state.reload.snapshot['net_cash']).to eq('3000.0')
    expect(paid.reload.payload['value']).to eq('4000.0')
    expect(klaviyo).to have_received(:create_event).once
  end
end
