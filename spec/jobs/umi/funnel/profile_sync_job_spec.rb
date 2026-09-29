# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer profile scheduling', type: :job do
  let(:account) { create(:account) }
  let(:contact) do
    create(:contact, account: account, email: 'person@example.com', phone_number: nil,
                     additional_attributes: { 'umi_klaviyo_profile_id' => 'P1', 'umi_klaviyo_binding' => { 'generation' => 'one' } })
  end

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      example.run
    end
  end

  it 'deduplicates queued jobs after a successful refresh' do
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    expect(client).to receive(:profile).once.and_return('id' => 'P1', 'attributes' => { 'email' => contact.email, 'properties' => {} })
    2.times { Umi::Funnel::ProfileSyncJob.perform_now(contact.id) }
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'checked_at')).to be_present
  end

  it 'schedules a new pending role after commit without remote-origin echo' do
    contact
    clear_enqueued_jobs
    Umi::Funnel::CustomerMutation.new(contact, source: 'operator').perform(roles: { umi_vip: 'yes' })
    expect(enqueued_jobs.count { |job| job[:job] == Umi::Funnel::ProfileSyncJob }).to eq(1)
    clear_enqueued_jobs
    Umi::Funnel::CustomerMutation.new(contact, source: 'remote').perform(roles: { umi_vip: 'no' })
    expect(enqueued_jobs.count { |job| job[:job] == Umi::Funnel::ProfileSyncJob }).to eq(0)
  end

  it 'keeps Retry-After durable and does not run the queued duplicate early' do
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    expect(client).to receive(:profile).once.and_raise(Umi::Funnel::KlaviyoClient::RateLimited.new('900'))
    2.times { Umi::Funnel::ProfileSyncJob.perform_now(contact.id) }
    due = Time.iso8601(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'next_sync_at'))
    expect(due).to be_within(2.seconds).of(15.minutes.from_now)
  end

  it 'does not contact Klaviyo for an erased or unverified binding' do
    contact.update!(additional_attributes: contact.additional_attributes.merge('umi_profile_redacted' => true))
    expect(Umi::Funnel::KlaviyoClient).not_to receive(:new)
    Umi::Funnel::ProfileSyncJob.perform_now(contact.id)
  end

  context 'when the contact has not been linked yet' do
    let(:discovered) { { 'id' => 'P1', 'attributes' => { 'email' => contact.email, 'phone_number' => contact.phone_number } } }
    let(:client) { instance_double(Umi::Funnel::KlaviyoClient) }

    before do
      contact.update!(additional_attributes: {})
      allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
      allow(client).to receive(:profiles).and_return('data' => [discovered], 'links' => { 'next' => nil })
      allow(client).to receive(:profile).and_return(discovered.deep_merge('attributes' => { 'properties' => { 'umi_vip' => true } }))
    end

    it 'discovers an exact existing buyer in the background after the first incoming message' do
      conversation = create(:conversation, account: account, contact: contact)
      clear_enqueued_jobs
      create(:message, :incoming, account: account, conversation: conversation)
      expect(enqueued_jobs.count { |job| job[:job] == Umi::Funnel::ProfileSyncJob }).to eq(1)
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true)
      expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to eq('P1')
      expect(contact.custom_attributes['umi_vip']).to eq('yes')
      expect(client).to have_received(:profiles).with('email' => 'person@example.com')
    end

    it 'discovers after a committed identity edit and retains justified pending roles at first binding' do
      Umi::Funnel::CustomerMutation.new(contact, source: 'operator').perform(roles: { umi_wholesale: 'yes' })
      clear_enqueued_jobs
      contact.update!(email: 'new@example.com')
      expect(enqueued_jobs.count { |job| job[:job] == Umi::Funnel::ProfileSyncJob }).to eq(1)
      discovered['attributes']['email'] = 'new@example.com'
      after_patch = discovered.deep_merge('attributes' => { 'properties' => { 'umi_vip' => true, 'umi_wholesale' => true } })
      allow(client).to receive(:profile).and_return(discovered.deep_merge('attributes' => { 'properties' => {} }), after_patch)
      expect(client).to receive(:update_roles).with('P1', { 'umi_wholesale' => 'yes' })
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true)
      expect(contact.reload.custom_attributes['umi_wholesale']).to eq('yes')
      expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_wholesale', 'pending')).to be_nil
    end

    it 'observes unmatched identity without hammering discovery on duplicate inbound jobs' do
      conversation = create(:conversation, account: account, contact: contact)
      allow(client).to receive(:profiles).and_return('data' => [], 'links' => { 'next' => nil })
      2.times { Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true) }
      expect(client).to have_received(:profiles).once
      expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to be_nil
      expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'error')).to include('identity_unresolved')
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(conversation.messages.last.content).to include('Customer identity unresolved')
    end

    it 'holds ambiguous and conflicting profiles without choosing one or patching roles' do
      allow(client).to receive(:profiles).and_return('data' => [discovered, discovered.merge('id' => 'P2')], 'links' => { 'next' => nil })
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true)
      expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to be_nil
      expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'error')).to include('identity_unresolved')
      contact.update!(email: 'changed@example.com', phone_number: '+66812345678')
      allow(client).to receive(:profiles).and_return('data' => [discovered.deep_merge('attributes' => { 'phone_number' => '+66899999999' })],
                                                     'links' => { 'next' => nil })
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true)
      expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to be_nil
      expect(client).not_to have_received(:profile)
    end

    it 'does not restore an erased customer or guess identifiers during discovery' do
      contact.update!(email: nil, phone_number: nil)
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true)
      expect(client).not_to have_received(:profiles)
      contact.update!(email: 'person@example.com')
      allow(client).to receive(:profiles) do
        contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
        { 'data' => [discovered], 'links' => { 'next' => nil } }
      end
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true)
      expect(contact.reload.additional_attributes).to eq('umi_profile_redacted' => true)
    end

    it 'respects Retry-After on unbound discovery even when another incoming message arrives' do
      allow(client).to receive(:profiles).and_raise(Umi::Funnel::KlaviyoClient::RateLimited.new('900'))
      clear_enqueued_jobs
      2.times { Umi::Funnel::ProfileSyncJob.perform_now(contact.id, force: true) }
      expect(client).to have_received(:profiles).once
      due = Time.iso8601(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'next_sync_at'))
      expect(due).to be_within(2.seconds).of(15.minutes.from_now)
      deferred = enqueued_jobs.select { |job| job[:job] == Umi::Funnel::ProfileSyncJob && job[:at] }
      expect(deferred.size).to eq(1)
      expect(deferred.first[:at]).to be_within(2).of(due.to_f)
    end
  end
end
