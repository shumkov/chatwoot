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
end
