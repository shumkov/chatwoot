# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::Report do
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
