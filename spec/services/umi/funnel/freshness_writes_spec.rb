# frozen_string_literal: true

require 'rails_helper'

# Every linked customer is re-checked against Klaviyo every few minutes. A check that only moves
# bookkeeping timestamps must not fan out into a projection job, a contact.updated dispatch and an
# agent broadcast per customer, while any real change must still reach CRM notes and agents at once.
RSpec.describe 'Funnel freshness-only customer writes', type: :job do
  let(:start) { Time.zone.parse('2026-11-12T10:00:00Z') }
  let(:account) { create(:account) }
  let(:contact) do
    create(:contact, account: account, email: 'person@example.com', phone_number: nil,
                     additional_attributes: { 'umi_klaviyo_profile_id' => 'P1', 'umi_klaviyo_binding' => { 'generation' => 'one' } })
  end
  let(:properties) do
    { 'umi_buyer_lifecycle' => 'client', 'umi_paid_order_count' => 1, 'umi_paid_history_complete' => true,
      'umi_payment_snapshot_at' => start.iso8601, 'umi_service_recovery_state' => 'hold', 'umi_service_snapshot_at' => start.iso8601 }
  end
  let(:client) { instance_double(Umi::Funnel::KlaviyoClient) }
  let(:sync) { Umi::Funnel::CustomerContextSync.new(contact.id, client: client) }
  # Jobs a contact write fans out into: CRM projection, the contact.updated event pipeline and the agent push.
  let(:fan_out) do
    lambda do
      enqueued_jobs.filter_map do |job|
        args = job[:args]
        next 'projection' if job[:job] == Umi::Funnel::CustomerProjectionJob
        next 'dispatch' if job[:job] == EventDispatcherJob && args.first == 'contact.updated'
        next 'broadcast' if job[:job] == ActionCableBroadcastJob && args.second == 'contact.updated'
      end.tally
    end
  end
  let(:all_fan_out) { { 'projection' => 1, 'dispatch' => 1, 'broadcast' => 1 } }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s,
                      UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      travel_to(start) { example.run }
    end
  end

  before do
    allow(client).to receive(:profile).with('P1', properties: true) do
      { 'id' => 'P1', 'attributes' => { 'email' => contact.email, 'properties' => properties } }
    end
  end

  describe 'timestamp-only writes' do
    it 'persists a profile check that only advances Klaviyo snapshot times without fan-out or touching updated_at' do
      sync.perform
      updated_at = contact.reload.updated_at
      clear_enqueued_jobs
      travel 20.minutes
      properties.merge!('umi_payment_snapshot_at' => Time.current.iso8601, 'umi_service_snapshot_at' => Time.current.iso8601)
      sync.perform

      expect(fan_out.call).to eq({})
      state = contact.reload.additional_attributes['umi_klaviyo_sync']
      expect(state).to include('checked_at' => Time.current.utc.iso8601, 'next_sync_at' => 15.minutes.from_now.utc.iso8601,
                               'payment_snapshot_at' => Time.current.utc.iso8601)
      expect(state['service']).to eq('state' => 'hold', 'observed_at' => Time.current.utc.iso8601)
      expect(contact.custom_attributes['umi_payment_snapshot_at']).to eq(Time.current.utc.iso8601)
      expect(contact.updated_at).to eq(updated_at)
    end

    it 'persists a repeated failure of the same kind without fan-out' do
      sync.perform
      allow(client).to receive(:profile).and_raise(Umi::Funnel::KlaviyoClient::Error, 'down')
      expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)
      clear_enqueued_jobs
      travel 15.minutes
      expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)

      expect(fan_out.call).to eq({})
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'failed_at')).to eq(Time.current.utc.iso8601)
    end

    it 'persists a repeated unresolved identity discovery without fan-out' do
      contact.update!(additional_attributes: {})
      allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
      allow(client).to receive(:profiles).and_return('data' => [], 'links' => { 'next' => nil })
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id)
      clear_enqueued_jobs
      travel 20.minutes
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id)

      expect(client).to have_received(:profiles).twice
      expect(fan_out.call).to eq({})
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'checked_at')).to eq(Time.current.utc.iso8601)
    end

    it 'leaves the mutated contact clean, as a save would' do
      sync.perform
      travel 20.minutes
      mutated = contact.reload
      clear_enqueued_jobs
      Umi::Funnel::CustomerMutation.new(mutated, source: 'remote').perform(
        sync: { 'expected' => Umi::Funnel::CustomerContextSync.version(mutated), 'metadata' => { 'checked_at' => Time.current.utc.iso8601 } }
      )
      expect(fan_out.call).to eq({})
      expect(mutated).not_to be_changed
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'checked_at')).to eq(Time.current.utc.iso8601)
    end
  end

  describe 'real changes keep the full save' do
    before do
      sync.perform
      clear_enqueued_jobs
      travel 20.minutes
      properties.merge!('umi_payment_snapshot_at' => Time.current.iso8601, 'umi_service_snapshot_at' => Time.current.iso8601)
    end

    it 'fans out the first-ever sync' do
      other = create(:contact, account: account, email: 'other@example.com',
                               additional_attributes: { 'umi_klaviyo_profile_id' => 'P2', 'umi_klaviyo_binding' => { 'generation' => 'one' } })
      allow(client).to receive(:profile).with('P2', properties: true)
                                        .and_return('id' => 'P2', 'attributes' => { 'email' => other.email, 'properties' => properties })
      clear_enqueued_jobs
      Umi::Funnel::CustomerContextSync.new(other.id, client: client).perform
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'fans out a paid-order count change' do
      properties['umi_paid_order_count'] = 2
      sync.perform
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'fans out a service reservation state change' do
      properties['umi_service_recovery_state'] = 'clear'
      sync.perform
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'fans out a fresh-to-stale profile status flip' do
      properties['umi_payment_snapshot_at'] = 3.hours.ago.iso8601
      sync.perform
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'status')).to eq('stale')
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'fans out the first failure and the recovery' do
      allow(client).to receive(:profile).and_raise(Umi::Funnel::KlaviyoClient::Error, 'down')
      expect { sync.perform }.to raise_error(Umi::Funnel::KlaviyoClient::Error)
      expect(fan_out.call).to eq(all_fan_out)

      clear_enqueued_jobs
      travel 15.minutes
      properties['umi_payment_snapshot_at'] = Time.current.iso8601
      allow(client).to receive(:profile).and_return('id' => 'P1', 'attributes' => { 'email' => contact.email, 'properties' => properties })
      sync.perform
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'error')).to be_nil
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'fans out a role submission and its acknowledgement' do
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
      clear_enqueued_jobs
      allow(client).to receive(:update_roles).with('P1', { 'umi_vip' => 'yes' }) { properties['umi_vip'] = true }
      sync.perform
      expect(fan_out.call).to eq('projection' => 2, 'dispatch' => 2, 'broadcast' => 2)
    end

    it 'fans out a role conflict acknowledgement and still writes its note' do
      conversation = create(:conversation, account: account, contact: contact)
      properties['umi_vip'] = false
      sync.perform
      travel 20.minutes
      properties['umi_payment_snapshot_at'] = Time.current.iso8601
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: { umi_vip: 'yes' })
      properties.delete('umi_vip')
      clear_enqueued_jobs
      sync.perform
      expect(fan_out.call).to eq(all_fan_out)
      expect(conversation.messages.where(private: true).last.content).to include('Customer role umi_vip')
    end

    it 'fans out a first service observation time even when the service state stays the same' do
      properties.delete('umi_service_recovery_state')
      sync.perform
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'service')).to eq('state' => 'unknown')
      travel 20.minutes
      properties.merge!('umi_payment_snapshot_at' => Time.current.iso8601, 'umi_service_recovery_state' => 'unknown')
      clear_enqueued_jobs
      sync.perform
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'service')).to include('state' => 'unknown', 'observed_at' => anything)
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'fans out a write that adds a key the freshness rules do not know' do
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'remote').perform(
        sync: { 'expected' => Umi::Funnel::CustomerContextSync.version(contact), 'metadata' => { 'checked_at' => Time.current.utc.iso8601,
                                                                                                 'future_key' => 'value' } }
      )
      expect(fan_out.call).to eq(all_fan_out)
    end

    it 'keeps dispatching a mutation that changes nothing, as operator edits rely on today' do
      Umi::Funnel::CustomerMutation.new(contact.reload, source: 'operator').perform(roles: {})
      expect(fan_out.call).to eq('dispatch' => 1, 'broadcast' => 1)
    end

    it 'fans out a discovery that observes changed identifiers' do
      contact.update!(additional_attributes: {})
      allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
      allow(client).to receive(:profiles).and_return('data' => [], 'links' => { 'next' => nil })
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id)
      travel 20.minutes
      contact.update_columns(phone_number: '+66812345678') # rubocop:disable Rails/SkipsModelValidations
      clear_enqueued_jobs
      Umi::Funnel::ProfileSyncJob.perform_now(contact.id)
      expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'identity_identifiers')).to include('phone_number' => '+66812345678')
      expect(fan_out.call).to eq(all_fan_out)
    end
  end

  describe 'reconcile re-projection of open conversations' do
    let!(:conversation) { create(:conversation, account: account, contact: contact) }
    let(:notes) { conversation.messages.where(private: true).order(:id) }

    it 'retires a fresh service reservation line once the reservation snapshot ages out' do
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(notes.last.content).to include('Service reservation: hold (fresh).')
      count = notes.count

      travel 2.hours + 1.minute
      properties['umi_payment_snapshot_at'] = Time.current.iso8601
      clear_enqueued_jobs
      sync.perform
      expect(fan_out.call).to eq({})

      Umi::Funnel::ReconcileJob.perform_now
      expect(enqueued_jobs.select { |job| job[:job] == Umi::Funnel::CustomerProjectionJob }.pluck(:args)).to eq([[contact.id]])
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(conversation.reload.additional_attributes.dig('umi_customer_projection', 'service', 'freshness')).to eq('stale')
      expect(notes.count).to eq(count + 1)
      expect(notes.last.content).not_to include('Service reservation')
    end

    it 'restores the fresh service reservation line when only the reservation snapshot advances' do
      properties['umi_service_snapshot_at'] = 3.hours.ago.iso8601
      sync.perform
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(notes.pluck(:content).join).not_to include('Service reservation')

      travel 20.minutes
      properties.merge!('umi_payment_snapshot_at' => Time.current.iso8601, 'umi_service_snapshot_at' => Time.current.iso8601)
      clear_enqueued_jobs
      sync.perform
      expect(fan_out.call).to eq({})

      perform_enqueued_jobs(only: Umi::Funnel::CustomerProjectionJob) { Umi::Funnel::ReconcileJob.perform_now }
      expect(notes.last.content).to include('Service reservation: hold (fresh).')
    end

    it 're-projects only linked, unerased customers with open conversations' do
      resolved = create(:contact, account: account, email: 'resolved@example.com', additional_attributes: {
                          'umi_klaviyo_profile_id' => 'P2', 'umi_klaviyo_binding' => { 'generation' => 'one' }
                        })
      create(:conversation, account: account, contact: resolved, status: :resolved)
      unlinked = create(:contact, account: account)
      create(:conversation, account: account, contact: unlinked)
      erased = create(:contact, account: account, additional_attributes: {
                        'umi_klaviyo_profile_id' => 'P3', 'umi_klaviyo_binding' => { 'generation' => 'one' }, 'umi_profile_redacted' => true
                      })
      create(:conversation, account: account, contact: erased)
      clear_enqueued_jobs

      Umi::Funnel::ReconcileJob.perform_now
      expect(enqueued_jobs.select { |job| job[:job] == Umi::Funnel::CustomerProjectionJob }.pluck(:args)).to eq([[contact.id]])
    end
  end
end
