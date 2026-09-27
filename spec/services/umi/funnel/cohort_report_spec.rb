# frozen_string_literal: true

require 'rails_helper'

# Recorded events are immutable; these fixtures exercise imported, corrupted and redacted evidence.
# rubocop:disable Rails/SkipsModelValidations

RSpec.describe Umi::Funnel::CohortReport do
  let(:account) { create(:account) }
  let(:start) { Time.iso8601('2026-09-05T10:00:00Z') }
  let(:conversation) { create(:conversation, account: account, created_at: start) }
  let(:params) do
    { account_id: account.id, from: '2026-09-05T00:00:00Z', until_time: '2026-09-10T00:00:00Z',
      as_of: '2026-09-15T00:00:00Z', horizon_days: 7 }
  end
  let!(:source) do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'message_received', occurrence_key: 'message:101', occurred_at: start,
                                   observed_at: start, provenance: 'live', payload: { message_id: 101, inbox_id: conversation.inbox_id,
                                                                                      channel_type: 'Channel::FacebookPage',
                                                                                      messaging_channel: 'messenger',
                                                                                      page_id: '123', ad_id: '456' })
  end
  let(:qualified) do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'conversation_qualified', occurrence_key: "conversation:#{conversation.id}:qualified",
                                   occurred_at: start + 1.day, observed_at: start + 1.day, provenance: 'operator',
                                   payload: { qualification_reason: 'private customer details must not appear' })
  end
  let(:paid) do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'order_paid', occurrence_key: 'shopify:umi.myshopify.com:order:1001:paid',
                                   occurred_at: start + 2.days, observed_at: start + 2.days, provenance: 'shopify',
                                   payload: { shop_domain: 'umi.myshopify.com', order_id: '1001', currency: 'THB', value: '4000.0',
                                              time_basis: 'last_successful_payment_at_observed_full_payment', order_origin: 'unknown' })
  end
  let(:attribution) do
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: '1001',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id,
                                         attribution_state: 'verified', token_nonce: SecureRandom.hex)
  end
  let(:state) do
    Umi::ShopifyOrderFinancialState.create!(account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: '1001',
                                            reconciliation_requested_at: start + 10.days, reconciled_at: start + 10.days, paid_event: paid,
                                            snapshot: { classification: 'partially_refunded', currency: 'THB', refunded: '1000.0', net_cash: '3000.0',
                                                        observed_at: (start + 10.days).iso8601,
                                                        first_paid_snapshot: { classification: 'paid', currency: 'THB', current_order_value: '4000.0',
                                                                               last_payment_at: paid.occurred_at.iso8601 } })
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: '', UMI_FUNNEL_STARTED_AT: '2026-09-01T00:00:00Z' do
      travel_to(Time.iso8601('2026-09-27T12:00:00Z')) { example.run }
    end
  end

  it 'keeps original paid value separate from latest cash and unknown advertising spend' do
    qualified
    attribution
    state
    report = described_class.perform(**params)
    row = report[:rows].sole
    mature = row[:mature]

    expect(mature).to include(conversations: 1, qualified_conversations: 1, paid_conversations: 1,
                              qualified_then_paid_conversations: 1, paid_orders: 1, paid_value_by_currency: { 'THB' => '4000.0' })
    expect(mature[:latest_cash_snapshot]['THB']).to include(known_refunded_total: '1000.0', known_net_cash_total: '3000.0',
                                                            covered_orders: 1, complete: true)
    expect(mature[:rates][:paid]).to include(numerator: 1, denominator: 1, ratio: '1.0')
    expect(row).to include(ad_id: '456', spend: { status: 'unknown', value: nil }, roas: nil)
    expect(report).to include(knowledge_basis: 'current_records_at_generation', historical_restatement_possible: true,
                              cash_time_basis: 'latest_observed_not_historical', refunds_within_outcome_window: nil)
    expect(JSON.generate(report)).not_to include('private customer details', 'scoped_user_id', 'shopify_order_id', 'contact_id', 'conversation_id')
  end

  it 'chooses the first message before filtering acquisition dates, not a new ad touch in the window' do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'message_received', occurrence_key: 'message:99', occurred_at: start - 2.days,
                                   observed_at: start - 2.days, provenance: 'live', payload: { message_id: 99, ad_id: 'earlier' })
    expect(described_class.perform(**params)[:rows]).to be_empty
  end

  it 'uses the lowest source message ID for equal-time first touches and ignores mutable sidebar labels' do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'message_received', occurrence_key: 'message:100', occurred_at: start,
                                   observed_at: start, provenance: 'live', payload: source.payload.merge('message_id' => 100, 'ad_id' => 'first'))
    conversation.update!(custom_attributes: { 'meta_ad_id' => 'latest' }, label_list: ['source-paid-ads'])
    expect(described_class.perform(**params)[:rows].sole[:ad_id]).to eq('first')
  end

  %w[recovered historical].each do |provenance|
    it "does not acquire a conversation from #{provenance} history" do
      source.update_columns(provenance: provenance)
      expect(described_class.perform(**params)[:rows]).to be_empty
    end
  end

  it 'does not treat an old thread first observed after activation as new acquisition' do
    conversation.update!(created_at: Time.iso8601('2026-08-01T00:00:00Z'))
    expect(described_class.perform(**params)[:rows]).to be_empty
  end

  it 'omits redacted or orphaned members without exposing their frozen ad identity' do
    conversation.contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
    expect(described_class.perform(**params)[:rows]).to be_empty
    conversation.contact.update!(additional_attributes: {})
    source.update_columns(conversation_id: nil, contact_id: nil, redacted_at: Time.current)
    expect(described_class.perform(**params)[:rows]).to be_empty
  end

  it 'keeps missing ad evidence unknown and uses Bangkok dates' do
    source.update_columns(payload: source.payload.except('ad_id'), occurred_at: Time.iso8601('2026-09-05T18:00:00Z'))
    row = described_class.perform(**params)[:rows].sole
    expect(row).to include(cohort_date: '2026-09-06', ad_id: nil, ad_evidence: 'unknown')
  end

  it 'marks a three-day-younger conversation immature and does not compare its rate with mature cohorts' do
    younger = create(:conversation, account: account, created_at: start + 3.days)
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: younger.id, contact_id: younger.contact_id,
                                   event_type: 'message_received', occurrence_key: 'message:102', occurred_at: start + 3.days,
                                   observed_at: start + 3.days, provenance: 'live', payload: source.payload.merge('message_id' => 102))
    report = described_class.perform(**params, as_of: '2026-09-14T00:00:00Z')
    older, newer = report[:rows]
    expect(older[:mature]).to include(conversations: 1)
    expect(older[:mature][:rates][:paid][:ratio]).to eq('0.0')
    expect(newer[:immature]).to include(conversations: 1)
    expect(newer[:immature][:rates][:paid]).to include(ratio: nil, reason: 'incomplete_followup')
    expect(newer[:mature][:rates][:qualified][:ratio]).to be_nil
  end

  it 'includes payment at the exact horizon and excludes payment immediately after it' do
    attribution
    state
    paid.update_columns(occurred_at: start + 7.days)
    state.update!(snapshot: state.snapshot.deep_merge('first_paid_snapshot' => { 'last_payment_at' => (start + 7.days).iso8601 }))
    expect(described_class.perform(**params)[:rows].sole[:mature][:paid_orders]).to eq(1)
    paid.update_columns(occurred_at: start + 7.days + 1.second)
    state.update!(snapshot: state.snapshot.deep_merge('first_paid_snapshot' => { 'last_payment_at' => paid.occurred_at.iso8601 }))
    expect(described_class.perform(**params)[:rows].sole[:mature][:paid_orders]).to eq(0)
  end

  it 'excludes the acquisition end boundary' do
    source.update_columns(occurred_at: Time.iso8601(params[:until_time]))
    expect(described_class.perform(**params)[:rows]).to be_empty
  end

  it 'counts two orders once each but only one paying conversation and keeps currencies separate' do
    attribution
    state
    second = Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                            event_type: 'order_paid', occurrence_key: 'shopify:umi.myshopify.com:order:1002:paid',
                                            occurred_at: paid.occurred_at, observed_at: paid.observed_at, provenance: 'shopify',
                                            payload: paid.payload.merge('order_id' => '1002', 'currency' => 'USD', 'value' => '10.0'))
    Umi::ShopifyOrderAttribution.create!(attribution.attributes.except('id', 'created_at', 'updated_at').merge(
                                           'shopify_order_id' => '1002', 'token_nonce' => SecureRandom.hex
                                         ))
    Umi::ShopifyOrderFinancialState.create!(state.attributes.except('id', 'created_at', 'updated_at').merge(
                                              'shopify_order_id' => '1002', 'paid_event_id' => second.id,
                                              'snapshot' => { 'first_paid_snapshot' => { 'classification' => 'paid', 'currency' => 'USD',
                                                                                         'current_order_value' => '10.0',
                                                                                         'last_payment_at' => second.occurred_at.iso8601 } }
                                            ))
    mature = described_class.perform(**params)[:rows].sole[:mature]
    expect(mature).to include(paid_conversations: 1, paid_orders: 2, paid_value_by_currency: { 'THB' => '4000.0', 'USD' => '10.0' })
    expect(mature[:latest_cash_snapshot]['USD']).to include(unavailable_orders: 1, complete: false)
  end

  %w[missing_verified_link missing_financial_state missing_first_paid_snapshot].each do |reason|
    it "marks #{reason} as incomplete evidence rather than a zero-percent conversion result" do
      paid
      attribution unless reason == 'missing_verified_link'
      state.update!(snapshot: state.snapshot.except('first_paid_snapshot')) if reason == 'missing_first_paid_snapshot'
      mature = described_class.perform(**params)[:rows].sole[:mature]
      expect(mature).to include(paid_orders: 0, paid_evidence_complete: false, paid_totals_basis: 'lower_bound')
      expect(mature[:incomplete_paid_evidence]).to eq(total: 1, reasons: { reason => 1 })
      expect(mature[:rates][:paid]).to include(ratio: nil, reason: 'incomplete_paid_evidence')
    end
  end

  it 'does not let another shop attribution credit an order to a campaign' do
    state
    attribution.update!(shop_domain: 'other.myshopify.com')
    result = described_class.perform(**params)
    expect(result[:rows].sole[:mature][:paid_orders]).to eq(0)
    expect(result[:coverage][:unlinked_unverified]).to eq(1)
  end

  it 'preserves the original milestone across correction, inactivity and explicit requalification' do
    qualified
    %w[not_sales inactive qualified].each_with_index do |status, index|
      Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                     event_type: 'classification_changed', occurrence_key: "classification:#{index}",
                                     occurred_at: start + (index + 2).days, observed_at: start + (index + 2).days,
                                     provenance: 'operator', payload: { status: status })
      mature = described_class.perform(**params)[:rows].sole[:mature]
      expect(mature[:recorded_qualified_milestones]).to eq(1)
      expect(mature[:qualified_conversations]).to eq(status == 'qualified' ? 1 : 0)
    end
  end

  it 'counts a sale without qualification but does not call payment before qualification a qualified conversion' do
    attribution
    state
    expect(described_class.perform(**params)[:rows].sole[:mature]).to include(paid_conversations: 1, qualified_then_paid_conversations: 0)
    qualified.update_columns(occurred_at: paid.occurred_at + 1.day)
    expect(described_class.perform(**params)[:rows].sole[:mature][:qualified_then_paid_conversations]).to eq(0)
  end

  it 'labels late observed and linked outcomes as current knowledge for an older occurrence cutoff' do
    attribution
    state
    paid.update_columns(observed_at: Time.iso8601('2026-09-25T00:00:00Z'))
    expect(described_class.perform(**params)[:rows].sole[:mature][:paid_orders]).to eq(1)
    paid.update_columns(observed_at: 1.second.from_now)
    expect(described_class.perform(**params)[:rows].sole[:mature][:paid_orders]).to eq(0)
  end

  it 'exposes stale financial snapshots and unknown paid history without inventing historical refunds' do
    attribution
    state.update!(last_error: 'Timeout::Error', reconciliation_requested_at: Time.current)
    cash = described_class.perform(**params)[:rows].sole[:mature][:latest_cash_snapshot]['THB']
    expect(cash).to include(complete: false, pending_reconciliation_orders: 1, financial_error_orders: 1, known_net_cash_total: '3000.0')
    state.update!(paid_event_id: nil, snapshot: { paid_history_unknown: true, observed_at: Time.current.iso8601 })
    paid.destroy!
    report = described_class.perform(**params)
    expect(report[:coverage][:cohort_paid_history_unknown]).to eq(1)
    expect(report[:rows].sole[:mature][:paid_orders]).to eq(0)
  end

  it 'fails visibly on malformed immutable paid money instead of silently summing partial revenue' do
    attribution
    state
    paid.update_columns(payload: paid.payload.merge('value' => 'NaN'))
    expect { described_class.perform(**params) }.to raise_error(ArgumentError, /paid/i)
  end

  it 'does not include another account outcomes or repeat a duplicate order occurrence in money totals' do
    attribution
    state
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'order_paid', occurrence_key: 'duplicate-import', occurred_at: paid.occurred_at,
                                   observed_at: paid.observed_at, provenance: 'shopify', payload: paid.payload)
    other = create(:account)
    Umi::ConversationEvent.record!(account_id: other.id, event_type: 'order_paid', occurrence_key: 'other-account',
                                   occurred_at: start + 2.days, observed_at: start + 2.days, provenance: 'shopify', payload: {})
    expect(described_class.perform(**params)[:rows].sole[:mature]).to include(paid_orders: 1, paid_value_by_currency: { 'THB' => '4000.0' })
  end

  it 'uses the financial state paid occurrence even when an identical import has a lower event ID' do
    original = paid
    duplicate = Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                               event_type: 'order_paid', occurrence_key: 'canonical-later', occurred_at: original.occurred_at,
                                               observed_at: original.observed_at, provenance: 'shopify', payload: original.payload)
    attribution
    state.update!(paid_event_id: duplicate.id)
    expect(described_class.perform(**params)[:rows].sole[:mature]).to include(paid_orders: 1, paid_evidence_complete: true)
  end

  it 'does not include a future-observed unknown-history snapshot in current coverage' do
    attribution
    state.update!(paid_event_id: nil, snapshot: { paid_history_unknown: true, observed_at: 1.second.from_now.iso8601 })
    paid.destroy!
    expect(described_class.perform(**params)[:coverage][:cohort_paid_history_unknown]).to eq(0)
  end

  it 'excludes orders before acquisition while retaining their account coverage separately' do
    attribution
    state
    paid.update_columns(occurred_at: start - 1.hour)
    result = described_class.perform(**params)
    expect(result[:rows].sole[:mature][:paid_orders]).to eq(0)
    expect(result[:coverage][:verified_in_cohort]).to eq(1)
  end

  it 'counts a redacted order only in coverage and does not reveal retained identity' do
    attribution
    state
    Umi::Funnel::Privacy.redact_events!(Umi::ConversationEvent.where(id: paid.id))
    result = described_class.perform(**params)
    expect(result[:coverage][:redacted_unusable]).to eq(1)
    expect(result[:rows].sole[:mature][:paid_orders]).to eq(0)
  end

  it 'shows unusable cash as unavailable while preserving a verified original purchase' do
    attribution
    state.update!(snapshot: state.snapshot.merge('classification' => 'needs_review'))
    mature = described_class.perform(**params)[:rows].sole[:mature]
    expect(mature[:paid_orders]).to eq(1)
    expect(mature[:latest_cash_snapshot]['THB']).to include(covered_orders: 0, unavailable_orders: 1, complete: false)
  end

  it 'fails on contradictory first-paid value instead of reporting a partial revenue sum' do
    attribution
    state.update!(snapshot: state.snapshot.deep_merge('first_paid_snapshot' => { 'current_order_value' => '12000.0' }))
    expect { described_class.perform(**params) }.to raise_error(ArgumentError, /paid/i)
  end

  it 'fails on conflicting duplicate order evidence' do
    attribution
    state
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'order_paid', occurrence_key: 'conflicting-import', occurred_at: paid.occurred_at,
                                   observed_at: paid.observed_at, provenance: 'shopify', payload: paid.payload.merge('value' => '5000.0'))
    expect { described_class.perform(**params) }.to raise_error(ArgumentError, /conflict/i)
  end

  [{ horizon_days: 0 }, { horizon_days: '7.5' }, { horizon_days: 91 }, { account_id: '1x' },
   { from: '2026-08-01T00:00:00Z' }, { until_time: '2026-09-05T00:00:00Z' },
   { as_of: '2026-09-28T00:00:00Z' }, { from: '2026-09-05T00:00:00+00:00' }].each do |invalid|
    it "rejects invalid report parameters #{invalid.inspect}" do
      expect { described_class.perform(**params, **invalid) }.to raise_error(ArgumentError)
    end
  end
end

# rubocop:enable Rails/SkipsModelValidations
