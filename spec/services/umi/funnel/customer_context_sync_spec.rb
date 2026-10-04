# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Klaviyo customer context sync', type: :model do
  let(:account) { create(:account) }
  let(:contact) do
    create(:contact, account: account, email: 'person@example.com', phone_number: nil,
                     additional_attributes: { 'umi_klaviyo_profile_id' => 'P1', 'umi_klaviyo_binding' => { 'generation' => 'one' } })
  end
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:properties) do
    { 'umi_buyer_lifecycle' => 'non_buyer', 'umi_paid_order_count' => 0, 'umi_paid_history_complete' => true,
      'umi_payment_snapshot_at' => Time.current.iso8601 }
  end
  let(:profile) { { 'id' => 'P1', 'attributes' => { 'email' => contact.email, 'properties' => properties } } }
  let(:client) { instance_double(Umi::Funnel::KlaviyoClient) }
  let(:sync) { Umi::Funnel::CustomerContextSync.new(contact.id, client: client) }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      example.run
    end
  end

  before { allow(client).to receive(:profile).with('P1', properties: true).and_return(profile) }

  it 'imports a model role alongside influencer and keeps explicit operator corrections two-way' do
    properties.merge!('umi_model' => true, 'umi_influencer' => true)
    conversation
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.custom_attributes).to include('umi_model' => 'yes', 'umi_influencer' => 'yes')
    expect(conversation.reload.label_list).to include('model', 'influencer')
    { 'no' => false, 'unknown' => nil, 'yes' => true }.each do |value, remote|
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_model: value })
      expect(client).to receive(:update_roles).with('P1', { 'umi_model' => value }) do
        remote.nil? ? properties.delete('umi_model') : properties['umi_model'] = remote
      end
      sync.perform
      expect(contact.reload.custom_attributes['umi_model']).to eq(value)
      expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_model', 'pending')).to be_nil
    end
  end

  it 'shows barter history without adding paid orders and avoids notes for timestamp-only refreshes' do
    conversation
    properties['umi_barter_history'] = true
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.custom_attributes).to include('umi_barter_history' => true, 'umi_paid_order_count' => 0)
    expect(conversation.reload.label_list).to include('barter')
    expect(conversation.messages.where(private: true).last.content).to include('Barter history: yes (order marked barter).')
    count = conversation.messages.where(private: true).count
    properties['umi_payment_snapshot_at'] = 1.minute.ago.utc.iso8601
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).count).to eq(count)
  end

  [false, nil, :absent].each do |value|
    it "removes the barter label when a fresh provider snapshot has #{value.inspect} barter history" do
      conversation
      properties.merge!('umi_barter_history' => true, 'umi_payment_snapshot_at' => 5.minutes.ago.utc.iso8601)
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(conversation.reload.label_list).to include('barter')
      value == :absent ? properties.delete('umi_barter_history') : properties['umi_barter_history'] = value
      properties['umi_payment_snapshot_at'] = Time.current.utc.iso8601
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(contact.reload.custom_attributes['umi_barter_history']).to eq(value == false ? false : nil)
      expect(conversation.reload.label_list).not_to include('barter')
      summary = value == false ? 'Barter history: no tagged orders.' : 'Barter history: unknown.'
      expect(conversation.messages.where(private: true).last.content).to include(summary)
    end
  end

  it 'retains verified barter history when the shared source snapshot expires' do
    conversation
    properties['umi_barter_history'] = true
    sync.perform
    properties.merge!('umi_barter_history' => false, 'umi_payment_snapshot_at' => 3.hours.ago.utc.iso8601)
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.custom_attributes['umi_barter_history']).to be(true)
    expect(conversation.reload.label_list).to include('barter')
    expect(conversation.messages.where(private: true).last.content).to include('Customer data is stale; last verified facts retained.')
  end

  it 'rejects a non-boolean barter fact instead of treating text as a positive' do
    properties['umi_barter_history'] = 'true'
    expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error, 'Invalid barter history')
    expect(contact.reload.custom_attributes['umi_barter_history']).to be_nil
  end

  %w[client repeat].product([false, true]).each do |previous_stage, count_present|
    it "clears a previous #{previous_stage} when Klaviyo returns unknown history with #{count_present ? 'null' : 'omitted'} count" do
      properties.merge!('umi_buyer_lifecycle' => previous_stage, 'umi_paid_order_count' => previous_stage == 'repeat' ? 2 : 1)
      conversation
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(conversation.reload.label_list).to include(previous_stage)

      properties.merge!('umi_buyer_lifecycle' => 'unclassified', 'umi_paid_history_complete' => false)
      count_present ? properties['umi_paid_order_count'] = nil : properties.delete('umi_paid_order_count')
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)

      expect(contact.reload.custom_attributes).to include('umi_funnel_stage' => 'unclassified', 'umi_paid_order_count' => nil,
                                                          'umi_paid_history_complete' => false)
      expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('fresh')
      expect(conversation.reload.label_list & %w[client repeat]).to be_empty
      expect(conversation.messages.where(private: true).last.content).to include('Customer: unclassified.', 'Payment history unknown.')
    end
  end

  %w[client repeat non_buyer].each do |stage|
    it "keeps a #{stage} snapshot with an omitted count stale" do
      properties['umi_buyer_lifecycle'] = stage
      properties.delete('umi_paid_order_count')
      sync.perform
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('stale')
      expect(contact.custom_attributes['umi_funnel_stage']).to be_nil
    end
  end

  it 'does not accept an omitted unknown count from an expired payment snapshot' do
    properties.merge!('umi_buyer_lifecycle' => 'unclassified', 'umi_paid_history_complete' => false,
                      'umi_payment_snapshot_at' => 3.hours.ago.utc.iso8601)
    properties.delete('umi_paid_order_count')
    sync.perform
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('stale')
    expect(contact.custom_attributes['umi_funnel_stage']).to be_nil
  end

  it 'shows service changes privately without adding labels or repeating hourly timestamps' do
    conversation
    properties.merge!('umi_service_recovery_state' => 'hold', 'umi_service_snapshot_at' => 5.minutes.ago.utc.iso8601)
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'service', 'state')).to eq('hold')
    expect(conversation.messages.where(private: true).last.content).to include('Service reservation: hold (fresh).')
    expect(contact.custom_attributes.keys.grep(/service/)).to be_empty
    expect(conversation.reload.label_list.grep(/service/)).to be_empty
    count = conversation.messages.where(private: true).count
    properties['umi_service_snapshot_at'] = Time.current.utc.iso8601
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).count).to eq(count)
    properties['umi_service_recovery_state'] = 'clear'
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).count).to eq(count + 1)
    expect(conversation.messages.where(private: true).last.content).to include('Service reservation: clear (fresh).')
  end

  it 'shows an expired clear service observation as stale and absent service evidence as unknown' do
    conversation
    properties.merge!('umi_service_recovery_state' => 'clear', 'umi_service_snapshot_at' => 3.hours.ago.utc.iso8601)
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).last.content).to include('Service reservation: clear (stale).')
    properties.except!('umi_service_recovery_state', 'umi_service_snapshot_at')
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).last.content).to include('Service reservation: unknown (unknown).')
  end

  it 'roundtrips yes, false and explicit unset with a confirmed baseline and no echo' do
    sync.perform
    { 'yes' => true, 'no' => false, 'unknown' => nil }.each do |value, remote|
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: value })
      expect(client).to receive(:update_roles).with('P1', { 'umi_vip' => value }) do
        remote.nil? ? properties.delete('umi_vip') : properties['umi_vip'] = remote
      end
      sync.perform
      field = contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip')
      expect(field).to include('baseline_known' => true, 'baseline' => value)
      expect(field['pending']).to be_nil
      expect(contact.custom_attributes['umi_vip']).to eq(value)
    end
    expect(client).not_to receive(:update_roles)
    sync.perform
  end

  it 'takes an explicit first remote value and lets remote false veto a pending AI positive' do
    conversation
    Umi::Funnel::CustomerMutation.new(contact, source: 'ai', conversation: conversation).perform(roles: { umi_influencer: 'yes' })
    properties['umi_influencer'] = false
    expect(client).not_to receive(:update_roles)
    sync.perform
    expect(contact.reload.custom_attributes['umi_influencer']).to eq('no')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_influencer', 'pending')).to be_nil
  end

  it 'keeps a fresh manual edit when a stale poll returns' do
    allow(client).to receive(:profile) do
      Umi::Funnel::CustomerMutation.new(contact, source: 'operator').perform(roles: { umi_vip: 'yes' })
      profile
    end
    expect(client).not_to receive(:update_roles)
    sync.perform
    expect(contact.reload.custom_attributes['umi_vip']).to eq('yes')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending', 'value')).to eq('yes')
  end

  it 'accepts a concurrent manual remote change over baseline and records both values once' do
    conversation
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    properties['umi_vip'] = false
    expect(client).not_to receive(:update_roles)
    2.times { sync.perform }
    expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
    notes = conversation.messages.select { |message| message.content_attributes.dig('umi_customer_summary', 'kind') == 'role_conflict' }
    expect(notes.count).to eq(1)
    expect(notes.first.content).to include('yes', 'no')
  end

  it 'never acknowledges a newer edit made during PATCH' do
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    allow(client).to receive(:update_roles) do
      properties['umi_vip'] = true
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'no' })
    end
    sync.perform
    expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending', 'value')).to eq('no')
  end

  it 'does not write after identity changes during GET' do
    allow(client).to receive(:profile) do
      contact.update!(additional_attributes: { 'umi_klaviyo_profile_id' => 'P2', 'umi_klaviyo_binding' => { 'generation' => 'two' } })
      profile
    end
    expect(client).not_to receive(:update_roles)
    sync.perform
    expect(contact.reload.additional_attributes['umi_klaviyo_sync']).to be_nil
  end

  [true, false].each do |known_baseline|
    [true, false].each do |ambiguous_patch|
      it "preserves the next operator edit after an older PATCH (baseline=#{known_baseline}, timeout=#{ambiguous_patch})" do
        sync.perform if known_baseline
        Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
        allow(client).to receive(:update_roles) do
          properties['umi_vip'] = true
          Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'no' })
          raise Umi::Funnel::KlaviyoClient::Error, 'timeout' if ambiguous_patch
        end
        if ambiguous_patch
          expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)
        else
          sync.perform
        end

        expect(client).to receive(:update_roles).with('P1', { 'umi_vip' => 'no' }) { properties['umi_vip'] = false }
        sync.perform
        expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
        expect(properties['umi_vip']).to be(false)
        expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending')).to be_nil
      end
    end
  end

  it 'keeps a profile failure visible after a segment refresh until the profile actually recovers' do
    properties.merge!('umi_buyer_lifecycle' => 'client', 'umi_paid_order_count' => 1)
    conversation
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    allow(client).to receive(:profile).and_raise(Umi::Funnel::KlaviyoClient::Error, 'network')
    expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    segments = { 'complete' => true, 'chooser' => false, 'seeker' => false, 'observed_at' => Time.current.iso8601 }
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'remote').perform(
      snapshot: { 'segments' => segments },
      sync: { 'expected' => Umi::Funnel::CustomerContextSync.version(contact), 'metadata' => { 'segments' => segments } }
    )
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('stale')
    expect(conversation.messages.where(private: true).count).to eq(2)

    allow(client).to receive(:profile).and_return(profile)
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('fresh')
    expect(conversation.messages.where(private: true).count).to eq(3)
  end

  it 'retains a newer operator value when its own follow-up PATCH fails before applying' do
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    allow(client).to receive(:update_roles) do
      properties['umi_vip'] = true
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'no' })
    end
    sync.perform
    allow(client).to receive(:update_roles).with('P1', { 'umi_vip' => 'no' }).and_raise(Umi::Funnel::KlaviyoClient::Error, 'timeout')
    expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)

    expect(client).to receive(:update_roles).with('P1', { 'umi_vip' => 'no' }) { properties['umi_vip'] = false }
    sync.perform
    expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
    expect(properties['umi_vip']).to be(false)
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending')).to be_nil
  end

  it 'preserves pending on an ambiguous PATCH then confirms with GET without repeating the write' do
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    allow(client).to receive(:update_roles) do
      properties['umi_vip'] = true
      raise Umi::Funnel::KlaviyoClient::Error, 'timeout'
    end
    expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending')).to be_present
    expect(client).not_to receive(:update_roles)
    sync.perform
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending')).to be_nil
  end

  it 'lets a current purchase replace observed seeker immediately' do
    segments = { 'complete' => true, 'chooser' => true, 'seeker' => true, 'observed_at' => Time.current.iso8601 }
    contact.update!(additional_attributes: contact.additional_attributes.merge('umi_klaviyo_sync' => { 'segments' => segments }))
    sync.perform
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('seeker')
    properties.merge!('umi_buyer_lifecycle' => 'client', 'umi_paid_order_count' => 1)
    sync.perform
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('client')
  end

  it 'uses the final readback for an unrelated role changed during PATCH' do
    properties['umi_wholesale'] = false
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    allow(client).to receive(:update_roles) { properties.merge!('umi_vip' => true, 'umi_wholesale' => true) }
    sync.perform
    expect(contact.reload.custom_attributes['umi_wholesale']).to eq('yes')
  end

  it 'does not acknowledge a newer edit made during the final readback' do
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    reads = 0
    allow(client).to receive(:profile) do
      reads += 1
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'no' }) if reads == 2
      profile
    end
    allow(client).to receive(:update_roles) { properties['umi_vip'] = true }
    sync.perform
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending', 'value')).to eq('no')
  end

  it 'takes an explicit first remote value over a manual edit without claiming a baseline conflict' do
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    properties['umi_vip'] = false
    expect(client).not_to receive(:update_roles)
    sync.perform
    expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'baseline')).to eq('no')
  end

  it 'sends a justified local role when the first remote value is absent' do
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    expect(client).to receive(:update_roles).with('P1', { 'umi_vip' => 'yes' }) { properties['umi_vip'] = true }
    sync.perform
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending')).to be_nil
  end

  it 'writes one stale transition and one recovery note but none for unchanged polls' do
    properties.merge!('umi_buyer_lifecycle' => 'client', 'umi_paid_order_count' => 1)
    conversation
    sync.perform
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).count).to eq(1)
    allow(client).to receive(:profile).and_raise(Umi::Funnel::KlaviyoClient::Error, 'network')
    2.times do
      expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    end
    expect(conversation.messages.where(private: true).count).to eq(2)
    allow(client).to receive(:profile).and_return(profile)
    2.times do
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    end
    expect(conversation.messages.where(private: true).count).to eq(3)
  end

  it 'reconciles a contact-only manual conflict and retains evidence without inventing a conversation' do
    sync.perform
    actor = create(:user, account: account)
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator', actor: actor).perform(roles: { umi_vip: 'yes' })
    properties['umi_vip'] = false
    sync.perform
    expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
    field = contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip')
    expect(field['pending']).to be_nil
    expect(field['conflict']).to include('local' => 'yes', 'remote' => 'no', 'actor_id' => actor.id)
    expect(field['conflict']['observed_at']).to be_present
    expect(contact.conversations).to be_empty
  end

  it 'keeps stale acquisition evidence visibly stale after fresh non-buyer payment reads' do
    contact.update!(custom_attributes: { 'umi_funnel_stage' => 'seeker' }, additional_attributes: contact.additional_attributes.merge(
      'umi_klaviyo_sync' => { 'segments' => { 'complete' => true, 'seeker' => true, 'observed_at' => 1.hour.ago.iso8601 } }
    ))
    sync.perform
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('seeker')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('stale')
    properties.merge!('umi_buyer_lifecycle' => 'client', 'umi_paid_order_count' => 1)
    sync.perform
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('client')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('fresh')
  end

  it 'removes private role conflict content through the existing customer erasure boundary' do
    conversation
    sync.perform
    Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
    properties['umi_vip'] = false
    sync.perform
    expect(conversation.messages.map(&:content).join).to include('local yes; Klaviyo no')
    contact.with_lock { Umi::Funnel::Privacy.redact_customer_context!(contact) }
    expect(conversation.messages.reload.map(&:content).join).not_to include('local yes; Klaviyo no')
  end

  it 'preserves newer segment evidence committed just before the profile acknowledgement lock' do
    contact.update!(additional_attributes: contact.additional_attributes.merge(
      'umi_klaviyo_sync' => { 'segments' => { 'complete' => true, 'chooser' => true, 'observed_at' => Time.current.iso8601 } }
    ))
    changed = false
    allow(Umi::Funnel::CustomerMutation).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      writer = original.call(*args, **kwargs)
      allow(writer).to receive(:perform).and_wrap_original do |perform, **values|
        unless changed
          changed = true
          current = Contact.find(contact.id)
          state = current.additional_attributes.fetch('umi_klaviyo_sync').merge(
            'segments' => { 'complete' => true, 'seeker' => true, 'observed_at' => Time.current.iso8601 }
          )
          current.update!(additional_attributes: current.additional_attributes.merge('umi_klaviyo_sync' => state))
        end
        perform.call(**values)
      end
      writer
    end
    sync.perform
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('seeker')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'segments', 'seeker')).to be(true)
  end
end
