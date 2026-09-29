# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::Report do
  it 'reports customer stages, explicit roles and synchronization coverage without exporting identities' do
    account = create(:account)
    now = Time.iso8601('2026-10-02T02:00:00Z')
    travel_to now do
      create(:contact, account: account, email: 'private-report@example.test',
                       custom_attributes: { umi_funnel_stage: 'repeat', umi_vip: 'yes', umi_wholesale: 'no' },
                       additional_attributes: { umi_klaviyo_profile_id: 'private-profile-id', umi_klaviyo_binding: { source: 'email' },
                                                umi_klaviyo_sync: { status: 'fresh', buyer_lifecycle: 'repeat',
                                                                    payment_snapshot_at: 1.hour.ago.iso8601, checked_at: 5.minutes.ago.iso8601,
                                                                    roles: { umi_vip: { pending: { value: 'yes' } } } } })
      create(:contact, account: account)
      create(:contact, account: account, additional_attributes: { umi_profile_redacted: true },
                       custom_attributes: { umi_funnel_stage: 'repeat', umi_vip: 'yes' })
      create(:contact)

      report = described_class.perform(account_id: account.id, since: now - 7.days, until_time: now)
      context = report.fetch(:customer_context)
      expect(context).to include(scope: 'all_account_contacts', contacts_count: 2, identity: { bound: 1, unbound: 1 })
      expect(context[:stages]).to include('repeat' => 1, 'unclassified' => 1, 'client' => 0)
      expect(context[:roles]).to include('umi_vip' => { 'yes' => 1, 'no' => 0, 'unknown' => 1 },
                                         'umi_wholesale' => { 'yes' => 0, 'no' => 1, 'unknown' => 1 })
      expect(context[:sync]).to eq(fresh: 1, stale: 0, unknown: 1, error: 0, pending: 1)
      expect(context[:observation_age_seconds][:profile]).to eq(known: 1, unknown: 1, oldest: 300)
      expect(context[:observation_age_seconds][:payment]).to eq(known: 1, unknown: 1, oldest: 3600)
      expect(JSON.generate(context)).not_to match(/private-report|private-profile-id|example.test|pending.*value|contact_id/)
    end
  end

  it 'shows stale retained facts and incomplete observations instead of claiming synchronization is fresh' do
    account = create(:account)
    now = Time.iso8601('2026-10-02T02:00:00Z')
    travel_to now do
      [
        { status: 'fresh', buyer_lifecycle: 'client', payment_snapshot_at: 2.hours.ago.iso8601 },
        { status: 'fresh', buyer_lifecycle: 'non_buyer', payment_snapshot_at: 1.hour.ago.iso8601,
          segments: { complete: true, observed_at: 15.minutes.ago.iso8601 } },
        { status: 'stale', error: 'private-provider-error', payment_snapshot_at: 1.hour.ago.iso8601, checked_at: 'bad' },
        { status: 'fresh', buyer_lifecycle: 'repeat', payment_snapshot_at: 1.minute.from_now.iso8601 },
        { status: 'fresh', buyer_lifecycle: 'non_buyer', payment_snapshot_at: 1.hour.ago.iso8601,
          segments: { complete: false, observed_at: 1.minute.ago.iso8601 } }
      ].each do |state|
        create(:contact, account: account, custom_attributes: { umi_funnel_stage: 'client' },
                         additional_attributes: { umi_klaviyo_sync: state })
      end

      context = described_class.perform(account_id: account.id, since: now - 7.days, until_time: now).fetch(:customer_context)
      expect(context[:sync]).to eq(fresh: 0, stale: 5, unknown: 0, error: 1, pending: 0)
      expect(context[:stages]['client']).to eq(5)
      expect(context[:observation_age_seconds][:payment]).to eq(known: 4, unknown: 1, oldest: 7200)
      expect(context[:observation_age_seconds][:profile]).to eq(known: 0, unknown: 5, oldest: nil)
      expect(JSON.generate(context)).not_to include('private-provider-error')
    end
  end

  it 'counts a payment exactly at Friday midnight in only the following weekly report' do
    account = create(:account)
    boundary = Time.iso8601('2026-10-01T17:00:00Z')
    Umi::ConversationEvent.record!(account_id: account.id, event_type: 'order_paid', provenance: 'shopify',
                                   occurrence_key: 'payment-at-week-boundary', observed_at: boundary, occurred_at: boundary,
                                   evidence_message_ids: [], payload: { currency: 'THB', value: '100' })

    previous = described_class.perform(account_id: account.id, since: boundary - 7.days, until_time: boundary)
    following = described_class.perform(account_id: account.id, since: boundary, until_time: boundary + 7.days)

    expect(previous[:paid_occurrences]).to eq(0)
    expect(previous[:paid_outcomes_by_currency]).to eq({})
    expect(following[:paid_occurrences]).to eq(1)
    expect(following[:paid_outcomes_by_currency].fetch('THB').to_d).to eq(100.to_d)
  end
end
