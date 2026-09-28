# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Funnel::Report
  def self.perform(account_id:, since:, until_time: Time.current)
    account = Account.find(account_id)
    events = Umi::ConversationEvent.where(account_id: account.id).where(observed_at: since..until_time)
    states = Umi::ShopifyOrderFinancialState.where(account_id: account.id, redacted_at: nil)
    currencies = {}
    states.find_each do |state|
      row = state.snapshot
      next if row.empty? || %w[needs_review test_order].include?(row['classification'])

      currency = currencies[row.fetch('currency')] ||= { captured: BigDecimal(0), refunded: BigDecimal(0), net_cash: BigDecimal(0) }
      currency.each_key { |key| currency[key] += BigDecimal(row.fetch(key.to_s)) }
    end
    paid = events.where(event_type: 'order_paid')
    { as_of: Time.current.utc.iso8601, occurrence_window: { observed_from: since.iso8601, observed_until: until_time.iso8601 },
      current_state_scope: 'all_account_records',
      observed_conversations: events.where(event_type: 'message_received').distinct.count(:conversation_id),
      qualified_occurrences: events.where(event_type: 'conversation_qualified').count, paid_occurrences: paid.count,
      paid_outcomes_by_currency: paid.group("payload ->> 'currency'").sum("(payload ->> 'value')::numeric").transform_values(&:to_s),
      current_classification: account.conversations.group("custom_attributes ->> 'umi_sales_status'").count,
      classifier_outcomes: events.where(event_type: 'classification_evaluated', redacted_at: nil).group("payload ->> 'outcome'").count,
      current_cash_by_currency: currencies.transform_values { |amounts| amounts.transform_values { |amount| amount.to_s('F') } },
      paid_with_verified_attribution: paid.where.not(conversation_id: nil).where(redacted_at: nil).count,
      paid_history_unknown: states.where("snapshot ->> 'paid_history_unknown' = 'true'").count,
      pending_financial_reconciliation: states.pending.count,
      paid_identity_holds: states.where("snapshot ->> 'identity_hold' IS NOT NULL").group("snapshot ->> 'identity_hold'").count,
      preparation_holds: Umi::ConversionDelivery.where(conversation_event_id: events.select(:id), state: 'pending',
                                                       reason: %w[preparation_failed profile_identity_conflict financial_identity_conflict]).count,
      exhausted_readbacks: Umi::ConversionDelivery.where(conversation_event_id: events.select(:id), destination: 'klaviyo',
                                                         state: 'accepted').where('readback_attempt_count >= 3').count,
      financial_errors: states.where.not(last_error: nil).count,
      delivery_states: Umi::ConversionDelivery.where(conversation_event_id: events.select(:id)).group(:destination, :state).count
                                              .map { |(destination, state), count| { destination: destination, state: state, count: count } },
      erasure_required: Umi::ConversionDelivery.where(conversation_event_id: events.select(:id), reason: 'erasure_required').count }
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
