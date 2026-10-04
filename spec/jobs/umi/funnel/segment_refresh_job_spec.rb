# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Configured customer segment refresh', type: :job do
  let(:account) { create(:account) }
  let(:contact) do
    create(:contact, account: account, email: 'person@example.com', phone_number: nil,
                     additional_attributes: { 'umi_klaviyo_profile_id' => 'P1', 'umi_klaviyo_binding' => { 'generation' => 'one' },
                                              'umi_klaviyo_sync' => { 'buyer_lifecycle' => 'non_buyer',
                                                                      'payment_snapshot_at' => Time.current.iso8601 } })
  end
  let(:client) { instance_double(Umi::Funnel::KlaviyoClient) }
  let(:metrics) do
    [['site', 'Active on Site', 'api'], ['product', 'Viewed Product', 'api'], ['cart', 'Added to Cart', 'shopify'],
     ['checkout', 'Checkout Started', 'shopify']]
      .map do |id, name, integration|
      { 'id' => id, 'attributes' => { 'name' => name, 'integration' => { 'key' => integration } } }
    end
  end
  let(:job) { Umi::Funnel::SegmentRefreshJob.new }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      example.run
    end
  end

  before do
    contact
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:metrics).and_return(metrics)
    # These definitions mirror the infra segment owner; the job must compare the actual remote definition.
    stage = { 'type' => 'profile-property', 'property' => "properties['umi_buyer_lifecycle']",
              'filter' => { 'type' => 'string', 'operator' => 'equals', 'value' => 'non_buyer' } }
    fresh = { 'type' => 'profile-property', 'property' => "properties['umi_payment_snapshot_at']",
              'filter' => { 'type' => 'date', 'operator' => 'in-the-last', 'quantity' => 2, 'unit' => 'hour' } }
    activity = %w[site product cart checkout].index_with do |id|
      { 'type' => 'profile-metric', 'metric_id' => id, 'measurement' => 'count',
        'measurement_filter' => { 'type' => 'numeric', 'operator' => 'greater-than', 'value' => 0 },
        'timeframe_filter' => { 'type' => 'date', 'operator' => 'in-the-last', 'quantity' => 30, 'unit' => 'day' }, 'metric_filters' => nil }
    end
    chooser_groups = [[stage], [fresh], activity.values_at('site', 'product'), *%w[cart checkout].map do |id|
      [activity.fetch(id).deep_merge('measurement_filter' => { 'operator' => 'equals' })]
    end]
    seeker_groups = [[stage], [fresh], activity.values_at('cart', 'checkout')]
    [['SS6aWp', 'Chooser', chooser_groups], ['RUy6Wc', 'Seeker', seeker_groups]].each do |id, name, groups|
      definition = { 'condition_groups' => groups.map { |conditions| { 'conditions' => conditions } } }
      allow(client).to receive(:segment).with(id).and_return(
        'id' => id, 'attributes' => { 'name' => "UMI - #{name}", 'definition' => definition }
      )
    end
    allow(client).to receive(:segment_profiles).with('SS6aWp').and_yield('id' => 'P1')
    allow(client).to receive(:segment_profiles).with('RUy6Wc').and_yield('id' => 'P1')
  end

  it 'publishes both complete observations together with seeker precedence and configured IDs' do
    job.perform(account.id)
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('seeker')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'segments')).to include('complete' => true, 'chooser' => true, 'seeker' => true,
                                                                                         'chooser_id' => 'SS6aWp', 'seeker_id' => 'RUy6Wc')
  end

  it 'does not publish the first scan when the second pagination fails' do
    allow(client).to receive(:segment_profiles).with('RUy6Wc').and_raise(Umi::Funnel::KlaviyoClient::Error, 'second page failed')
    job.perform(account.id)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'segments')).to be_nil
    expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'error')).to be_present
  end

  it 'keeps healthy segment membership fresh across normal five-minute scheduler ticks' do
    start = Time.current.change(usec: 0)
    travel_to(start) do
      allow(client).to receive(:segment_profiles).with('RUy6Wc') do |&block|
        travel 1.second
        block.call('id' => 'P1')
      end
      [0, 5, 10, 15].each do |minute|
        travel_to(start + minute.minutes)
        job.perform(account.id)
      end
      travel_to(start + 15.minutes + 2.seconds)
      profile = { 'id' => 'P1', 'attributes' => { 'email' => contact.email, 'properties' => {
        'umi_buyer_lifecycle' => 'non_buyer', 'umi_paid_order_count' => 0, 'umi_paid_history_complete' => true,
        'umi_payment_snapshot_at' => Time.current.iso8601
      } } }
      allow(client).to receive(:profile).with('P1', properties: true).and_return(profile)
      Umi::Funnel::CustomerContextSync.new(contact.id, client: client).perform

      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('fresh')
      expect(contact.custom_attributes['umi_funnel_stage']).to eq('seeker')
    end
  end

  it 'rejects changed definitions before treating membership as acquisition evidence' do
    allow(client).to receive(:segment).with('SS6aWp').and_return('id' => 'SS6aWp', 'attributes' => { 'name' => 'UMI - Chooser', 'definition' => {} })
    expect(client).not_to receive(:segment_profiles)
    job.perform(account.id)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'segments')).to be_nil
  end

  it 'does not apply membership to a replacement customer after a slow request' do
    allow(client).to receive(:segment_profiles).with('RUy6Wc') do |&block|
      contact.update!(additional_attributes: { 'umi_klaviyo_profile_id' => 'P2', 'umi_klaviyo_binding' => { 'generation' => 'two' } })
      block.call('id' => 'P1')
    end
    job.perform(account.id)
    expect(contact.reload.additional_attributes['umi_klaviyo_sync']).to be_nil
  end

  it 'does not label a stale non-buyer as a new seeker' do
    state = contact.additional_attributes['umi_klaviyo_sync'].merge('payment_snapshot_at' => 3.hours.ago.iso8601)
    contact.update!(additional_attributes: contact.additional_attributes.merge('umi_klaviyo_sync' => state))
    job.perform(account.id)
    expect(contact.reload.custom_attributes['umi_funnel_stage']).not_to eq('seeker')
  end

  it 'cannot downgrade a purchase committed between observation preparation and the shared writer lock' do
    changed = false
    allow(Umi::Funnel::CustomerMutation).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      writer = original.call(*args, **kwargs)
      allow(writer).to receive(:perform).and_wrap_original do |perform, **values|
        if values.dig(:sync, 'metadata', 'segments') && !changed
          changed = true
          Umi::Funnel::CustomerMutation.new(contact.reload, source: 'system').perform(
            snapshot: { 'buyer_lifecycle' => 'client', 'paid_order_count' => 1, 'paid_history_complete' => true,
                        'payment_snapshot_at' => Time.current.iso8601 }
          )
        end
        perform.call(**values)
      end
      writer
    end
    job.perform(account.id)
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('client')
    expect(contact.custom_attributes['umi_paid_order_count']).to eq(1)
  end

  context 'when a genuine qualification has been confirmed by Klaviyo' do
    let(:client) { Umi::Funnel::KlaviyoClient.new(api_key: 'synthetic') }
    let(:event_type) { 'conversation_qualified' }
    let(:provenance) { 'classifier' }
    let(:occurred_at) { 1.hour.ago }
    let(:confirmation) { { state: 'confirmed', confirmed_at: Time.current, provider_reference: 'event-receipt' } }
    let(:qualification) do
      Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, event_type: event_type,
                                     occurrence_key: 'qualified:one', occurred_at: occurred_at, observed_at: Time.current,
                                     provenance: provenance, payload: {})
    end
    let(:recent_definition) do
      { 'condition_groups' => [{ 'conditions' => [{
        'type' => 'profile-metric', 'metric_id' => 'qualified', 'measurement' => 'count',
        'measurement_filter' => { 'type' => 'numeric', 'operator' => 'greater-than', 'value' => 0 },
        'timeframe_filter' => { 'type' => 'date', 'operator' => 'in-the-last', 'quantity' => 30, 'unit' => 'day' }, 'metric_filters' => nil
      }] }] }
    end
    let(:recent_segment) do
      { 'id' => 'RECENT', 'attributes' => { 'name' => 'UMI - Recent conversation intent', 'definition' => recent_definition } }
    end
    let(:creation) do
      stub_request(:post, 'https://a.klaviyo.com/api/segments').with(body: {
                                                                       data: { type: 'segment',
                                                                               attributes: { name: 'UMI - Recent conversation intent',
                                                                                             definition: recent_definition } }
                                                                     }).to_return(status: 201, body: { data: recent_segment }.to_json)
    end

    around do |example|
      with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                        UMI_FUNNEL_KLAVIYO_ENABLED: 'true' do
        example.run
      end
    end

    before do
      allow(client).to receive(:segment).with('RECENT').and_call_original
      qualification.conversion_deliveries.find_by!(destination: 'klaviyo').update!(confirmation)
      creation
      metrics << { 'id' => 'qualified', 'attributes' => { 'name' => 'UMI Conversation Qualified', 'integration' => { 'key' => 'api' } } }
      stub_request(:get, 'https://a.klaviyo.com/api/segments')
        .with(query: { 'filter' => 'equals(name,"UMI - Recent conversation intent")', 'fields[segment]' => 'name,definition' })
        .to_return(body: { data: [], links: { next: nil } }.to_json)
      stub_request(:get, 'https://a.klaviyo.com/api/segments/RECENT')
        .with(query: { 'fields[segment]' => 'name,definition' }).to_return(body: { data: recent_segment }.to_json)
    end

    it 'creates and verifies the recent-conversation audience on the ordinary refresh after provider confirmation' do
      job.perform(account.id)

      expect(creation).to have_been_requested.once
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent')).to include(
        'status' => 'ready', 'segment_id' => 'RECENT', 'metric_id' => 'qualified'
      )
    end

    { event_type: 'order_paid', provenance: 'recovered' }.each do |field, value|
      context "with #{field}=#{value.inspect}" do
        let(field) { value }

        it 'waits for a genuine confirmed qualification without creating an audience' do
          job.perform(account.id)
          expect(creation).not_to have_been_requested
          expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('awaiting_qualification')
        end
      end
    end

    [-72, 1].each do |hours|
      context "with qualification #{hours} hours from now" do
        let(:occurred_at) { hours.hours.from_now }

        it 'does not create from pre-collection or future evidence' do
          job.perform(account.id)
          expect(creation).not_to have_been_requested
          expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('awaiting_qualification')
        end
      end
    end

    { state: 'accepted', confirmed_at: nil, provider_reference: nil }.each do |field, value|
      it "does not create an audience for incomplete confirmation #{field}=#{value.inspect}" do
        qualification.conversion_deliveries.find_by!(destination: 'klaviyo').update!(field => value)
        job.perform(account.id)
        expect(creation).not_to have_been_requested
        expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('awaiting_qualification')
      end
    end

    it 'does not use an erased qualification' do
      qualification.update!(redacted_at: Time.current, payload: {})
      job.perform(account.id)
      expect(creation).not_to have_been_requested
    end

    it 'does not use another account confirmation' do
      qualification.conversion_deliveries.find_by!(destination: 'klaviyo').destroy!
      other = create(:account)
      event = Umi::ConversationEvent.record!(account_id: other.id, event_type: 'conversation_qualified', occurrence_key: 'other:qualified',
                                             occurred_at: 1.hour.ago, observed_at: Time.current, provenance: 'classifier', payload: {})
      event.conversion_deliveries.find_by!(destination: 'klaviyo').update!(state: 'confirmed', confirmed_at: Time.current,
                                                                           provider_reference: 'other-receipt')
      job.perform(account.id)
      expect(creation).not_to have_been_requested
    end

    it 'requires the currently enabled funnel and export before provisioning' do
      with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'false' do
        job.perform(account.id)
      end
      expect(creation).not_to have_been_requested
      expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('seeker')
    end

    it 'waits for the genuine metric and rejects duplicate metrics without failing membership refresh' do
      metric = metrics.pop
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('awaiting_metric')
      travel 6.minutes
      metrics.push(metric, metric.merge('id' => 'duplicate'))
      job.perform(account.id)
      state = account.reload.custom_attributes.fetch('umi_segment_refresh')
      expect(state['error']).to be_nil
      expect(state.dig('recent_intent', 'last_error')).to eq('Ambiguous qualification metric')
      expect(creation).not_to have_been_requested
      expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('seeker')
    end

    it 'adopts an existing exact segment and verifies its ID without posting' do
      allow(client).to receive(:segments).and_return([recent_segment])
      expect(client).to receive(:segment).with('RECENT').and_call_original
      job.perform(account.id)
      expect(creation).not_to have_been_requested
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('ready')
    end

    it 'rejects duplicate names and definition drift without overwriting operator audiences' do
      allow(client).to receive(:segments).and_return([recent_segment, recent_segment.merge('id' => 'OTHER')])
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'last_error')).to eq('Duplicate recent-intent segments')
      travel 16.minutes
      allow(client).to receive(:segments).and_return([recent_segment.merge('attributes' => recent_segment['attributes'].merge('definition' => {}))])
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'last_error')).to eq('Recent-intent definition differs')
      expect(creation).not_to have_been_requested
    end

    it 'keeps the created ID if readback fails and retries only GET on the next due refresh' do
      readback = stub_request(:get, 'https://a.klaviyo.com/api/segments/RECENT')
                 .with(query: { 'fields[segment]' => 'name,definition' })
                 .to_return(status: 503).then.to_return(body: { data: recent_segment }.to_json)
      job.perform(account.id)
      state = account.reload.custom_attributes.fetch('umi_segment_refresh')
      expect(state['error']).to be_nil
      expect(state['recent_intent']).to include('status' => 'error', 'segment_id' => 'RECENT', 'last_error' => 'Klaviyo HTTP_503')
      travel 16.minutes
      job.perform(account.id)
      expect(creation).to have_been_requested.once
      expect(readback).to have_been_requested.twice
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('ready')
    end

    it 'never recreates a saved segment that was deleted at the provider' do
      job.perform(account.id)
      travel 6.minutes
      stub_request(:get, 'https://a.klaviyo.com/api/segments/RECENT').with(query: { 'fields[segment]' => 'name,definition' })
                                                                     .to_return(status: 404)
      job.perform(account.id)
      expect(creation).to have_been_requested.once
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'last_error')).to eq('Klaviyo HTTP_404')
    end

    it 'preserves one attempt through ambiguous creation and adopts the later discovered segment' do
      stub_request(:post, 'https://a.klaviyo.com/api/segments').to_timeout
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'create_attempted_at')).to be_present
      travel 16.minutes
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('creation_unknown')
      travel 6.minutes
      allow(client).to receive(:segments).and_return([recent_segment])
      job.perform(account.id)
      expect(creation).to have_been_requested.once
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('ready')
    end

    it 'does not post again after an interrupted creation claim' do
      account.update!(custom_attributes: { 'umi_segment_refresh' => { 'recent_intent' => {
                        'status' => 'creating', 'create_attempted_at' => 1.hour.ago.iso8601
                      } } })
      2.times do
        job.perform(account.id)
        travel 6.minutes
      end
      expect(creation).not_to have_been_requested
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('creation_unknown')
    end

    it 'rechecks the durable claim after discovery so a stale worker cannot post twice' do
      allow(client).to receive(:segments) do
        current = Account.find(account.id)
        state = current.custom_attributes.fetch('umi_segment_refresh')
        recent = state.fetch('recent_intent').merge('status' => 'creating', 'create_attempted_at' => Time.current.iso8601)
        current.update!(custom_attributes: current.custom_attributes.merge('umi_segment_refresh' => state.merge('recent_intent' => recent)))
        []
      end
      job.perform(account.id)
      expect(creation).not_to have_been_requested
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'create_attempted_at')).to be_present
    end

    it 'does not create when another worker records a rate-limit cooldown during discovery' do
      allow(client).to receive(:segments) do
        current = Account.find(account.id)
        state = current.custom_attributes.fetch('umi_segment_refresh')
        recent = state.fetch('recent_intent').merge('status' => 'error', 'create_attempted_at' => nil,
                                                    'last_error' => 'Klaviyo HTTP_429', 'next_check_at' => 10.minutes.from_now.iso8601)
        current.update!(custom_attributes: current.custom_attributes.merge('umi_segment_refresh' => state.merge('recent_intent' => recent)))
        []
      end
      job.perform(account.id)
      expect(creation).not_to have_been_requested
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'last_error')).to eq('Klaviyo HTTP_429')
    end

    it 'releases only a rate-limited create claim and honors its cooldown without staling membership' do
      stub_request(:post, 'https://a.klaviyo.com/api/segments').to_return(status: 429, headers: { 'Retry-After' => '600' })
                                                               .then.to_return(status: 201, body: { data: recent_segment }.to_json)
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'create_attempted_at')).to be_nil
      travel 6.minutes
      job.perform(account.id)
      expect(creation).to have_been_requested.once
      travel 6.minutes
      job.perform(account.id)
      expect(creation).to have_been_requested.twice
      state = account.reload.custom_attributes.fetch('umi_segment_refresh')
      expect(state['error']).to be_nil
      expect(state.dig('recent_intent', 'status')).to eq('ready')
    end

    it 'persists the rate-limit cooldown in the same write that releases its create claim' do
      stub_request(:post, 'https://a.klaviyo.com/api/segments').to_return(status: 429, headers: { 'Retry-After' => '600' })
      allow(job).to receive(:record_recent_intent).and_wrap_original do |original, values|
        original.call(values).tap do
          if values.key?('create_attempted_at') && values['create_attempted_at'].nil?
            saved = Account.find(account.id).custom_attributes.dig('umi_segment_refresh', 'recent_intent')
            expect(saved['last_error']).to eq('Klaviyo HTTP_429')
            expect(Time.iso8601(saved.fetch('next_check_at'))).to be > 9.minutes.from_now
          end
        end
      end
      job.perform(account.id)
      expect(creation).to have_been_requested.once
    end

    it 'holds an explicit creation rejection instead of repeating a bad request' do
      stub_request(:post, 'https://a.klaviyo.com/api/segments').to_return(status: 403)
      job.perform(account.id)
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'last_error')).to eq('Klaviyo HTTP_403')
      travel 16.minutes
      job.perform(account.id)
      expect(creation).to have_been_requested.once
    end

    it 'keeps a ready account audience after its originating contact evidence is erased' do
      job.perform(account.id)
      qualification.update!(redacted_at: Time.current, payload: {})
      travel 6.minutes
      job.perform(account.id)
      expect(creation).to have_been_requested.once
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent', 'status')).to eq('ready')
    end

    it 'resolves an ambiguous account audience after its original qualification is erased without another POST' do
      account.update!(custom_attributes: { 'umi_segment_refresh' => { 'recent_intent' => {
                        'status' => 'creation_unknown', 'create_attempted_at' => 1.hour.ago.iso8601
                      } } })
      qualification.update!(redacted_at: Time.current, payload: {})
      allow(client).to receive(:segments).and_return([recent_segment])
      expect(client).to receive(:segment).with('RECENT').and_call_original

      job.perform(account.id)

      expect(creation).not_to have_been_requested
      expect(account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent')).to include('status' => 'ready', 'segment_id' => 'RECENT')
    end
  end
end
