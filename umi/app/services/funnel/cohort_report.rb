# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Funnel::CohortReport
  QUALIFICATION_STATUSES = %w[qualified not_sales unevaluated].freeze
  DIMENSIONS = %w[inbox_id channel_type messaging_channel page_id ad_id].freeze
  LIMITATIONS = %w[service_kind_reservation_attendance_no_show qualification_reason_codes historical_refunds
                   historical_linkage_snapshots advertising_spend business_hours_sla ad_comment_ownership].freeze

  def self.perform(**arguments)
    new(**arguments).perform
  end

  def initialize(account_id:, from:, until_time:, as_of:, horizon_days:)
    @generated_at = Time.current
    raise ArgumentError, 'Account ID must be positive' unless account_id.to_s.match?(/\A[1-9]\d*\z/)
    raise ArgumentError, 'Horizon must be 1–90 integer days' unless horizon_days.to_s.match?(/\A\d+\z/) && horizon_days.to_i.between?(1, 90)

    @account = Account.find(account_id)
    @from, @until_time, @as_of = [from, until_time, as_of].map { |value| utc_time(value) }
    @boundary = Umi::Funnel::Configuration.started_at
    @horizon_days = horizon_days.to_i
    unless @boundary <= @from && @from < @until_time && @until_time <= @as_of && @as_of <= @generated_at && @until_time - @from <= 90.days
      raise ArgumentError, 'Invalid cohort time window'
    end

    @events = Umi::ConversationEvent.where(account_id: @account.id).where(observed_at: ..@generated_at)
    @members = {}
    @rows = {}
    @coverage = { verified_in_cohort: 0, verified_outside_cohort: 0, unlinked_unverified: 0, redacted_unusable: 0,
                  cohort_paid_history_unknown: 0 }
  end

  def perform
    assign_members
    count_qualifications
    count_payments
    count_unknown_history
    { schema_version: 1, account_id: @account.id, generated_at: @generated_at.utc.iso8601,
      parameters: { from: @from.iso8601, until: @until_time.iso8601, as_of: @as_of.iso8601, horizon_days: @horizon_days },
      observation_boundary: @boundary.iso8601, cohort_timezone: 'Asia/Bangkok',
      knowledge_basis: 'current_records_at_generation', historical_restatement_possible: true,
      cash_time_basis: 'latest_observed_not_historical', refunds_within_outcome_window: nil, net_paid_within_outcome_window: nil,
      rows: @rows.sort_by { |key, _| key.map(&:to_s) }.map { |_, row| finish_row(row) },
      coverage: @coverage.merge(scope: 'current_account_paid_occurrences_from_through_as_of',
                                cohort_membership_independent_of_outcome_horizon: true), limitations: LIMITATIONS }
  end

  private

  def utc_time(value)
    raise ArgumentError, 'Timestamp must use explicit UTC ISO8601 Z' unless value.is_a?(String) && value.end_with?('Z')

    Time.iso8601(value)
  end

  def assign_members
    live = @events.where(event_type: 'message_received', provenance: 'live', redacted_at: nil).where(occurred_at: @boundary..)
    candidates = live.where(occurred_at: @from...@until_time).select(:conversation_id)
    first = live.where(conversation_id: candidates).select('DISTINCT ON (conversation_id) id')
                .order(Arel.sql("conversation_id, occurred_at, (payload ->> 'message_id')::bigint, id"))
    @events.where(id: first).find_in_batches(batch_size: 500) do |events|
      conversations = @account.conversations.where(id: events.map(&:conversation_id)).includes(:contact).index_by(&:id)
      events.each do |event|
        conversation = conversations[event.conversation_id]
        next unless valid_identity?(event, conversation) && conversation.created_at >= @boundary
        next unless event.occurred_at >= @from && event.occurred_at < @until_time

        dimensions = DIMENSIONS.index_with { |key| event.payload[key].presence }.symbolize_keys
        dimensions[:cohort_date] = event.occurred_at.in_time_zone('Asia/Bangkok').to_date.iso8601
        row = @rows[[dimensions[:cohort_date], *DIMENSIONS.map do |key|
          dimensions[key.to_sym]
        end]] ||= dimensions.merge(ad_evidence: dimensions[:ad_id] ? 'recorded_ad' : 'unknown',
                                   mature: empty_metrics, immature: empty_metrics)
        maturity = event.occurred_at + @horizon_days.days <= @as_of ? :mature : :immature
        row[maturity][:conversations] += 1
        @members[event.conversation_id] = { contact_id: event.contact_id, start: event.occurred_at,
                                            deadline: [event.occurred_at + @horizon_days.days, @as_of].min, metrics: row[maturity] }
      end
    end
  end

  def valid_identity?(event, conversation)
    conversation && conversation.contact_id == event.contact_id && conversation.contact&.account_id == @account.id &&
      !conversation.contact.additional_attributes['umi_profile_redacted']
  end

  def empty_metrics
    { conversations: 0, recorded_qualified_milestones: 0, invalidated_qualifications: 0, qualified_conversations: 0,
      paid_conversations: 0, qualified_then_paid_conversations: 0, paid_orders: 0, paid_value_by_currency: {},
      incomplete_paid_evidence: { total: 0, reasons: {} }, latest_cash_snapshot: {} }
  end

  def count_qualifications
    @members.keys.each_slice(500) do |ids|
      events = @events.where(conversation_id: ids, redacted_at: nil, event_type: %w[conversation_qualified classification_changed])
                      .where(occurred_at: ..@as_of).order(:occurred_at, :id).group_by(&:conversation_id)
      events.each do |id, history|
        member = @members.fetch(id)
        history.select! { |event| event.contact_id == member[:contact_id] }
        milestone = history.find { |event| event.event_type == 'conversation_qualified' && in_interval?(event, member) }
        next unless milestone

        metrics = member[:metrics]
        metrics[:recorded_qualified_milestones] += 1
        correction = history.reverse.find do |event|
          event.event_type == 'classification_changed' && QUALIFICATION_STATUSES.include?(event.payload['status'])
        end
        if correction && correction.payload['status'] != 'qualified'
          metrics[:invalidated_qualifications] += 1
        else
          metrics[:qualified_conversations] += 1
          member[:qualified_at] = milestone.occurred_at
        end
      end
    end
  end

  def in_interval?(event, member)
    member && event.contact_id == member[:contact_id] && event.occurred_at.between?(member[:start], member[:deadline])
  end

  def count_payments
    seen = {}
    @events.where(event_type: 'order_paid').where(occurred_at: @from..@as_of).find_in_batches do |events|
      orders = events.filter_map { |event| event.payload['order_id'] }
      states = Umi::ShopifyOrderFinancialState.where(account_id: @account.id, shopify_order_id: orders).includes(:paid_event).index_by do |state|
        [state.shop_domain.downcase, state.shopify_order_id]
      end
      links = Umi::ShopifyOrderAttribution.where(account_id: @account.id, shopify_order_id: orders).verified.index_by do |link|
        [link.shop_domain.downcase, link.shopify_order_id]
      end
      conversations = @account.conversations.where(id: events.map(&:conversation_id)).includes(:contact).index_by(&:id)
      events.each { |event| count_payment(event, states, links, conversations, seen) }
    end
  end

  def count_payment(event, states, links, conversations, seen)
    if event.redacted_at
      key = [:redacted, event.occurrence_key]
      @coverage[:redacted_unusable] += 1 unless seen[key]
      seen[key] = true
      return
    end

    key, amount, currency = paid_facts(event)
    facts = [amount, currency, event.occurred_at, event.conversation_id, event.contact_id]
    raise ArgumentError, 'Conflicting paid order evidence' if seen[key] && seen[key] != facts
    return if seen[key]

    seen[key] = facts
    state = states[key]
    link = links[key]
    identity = valid_identity?(event, conversations[event.conversation_id])
    verified = identity && link && link.conversation_id == event.conversation_id && link.contact_id == event.contact_id
    member = @members[event.conversation_id]
    category = if !identity && event.conversation_id
                 :redacted_unusable
               elsif !verified
                 :unlinked_unverified
               else
                 member ? :verified_in_cohort : :verified_outside_cohort
               end
    @coverage[category] += 1
    return unless in_interval?(event, member)

    reason = if !verified
               'missing_verified_link'
             elsif !state || state.redacted_at || !matching_paid_occurrence?(state, event)
               'missing_financial_state'
             elsif state.snapshot['first_paid_snapshot'].blank?
               'missing_first_paid_snapshot'
             end
    if reason
      incomplete = member[:metrics][:incomplete_paid_evidence]
      incomplete[:total] += 1
      incomplete[:reasons][reason] = incomplete[:reasons].fetch(reason, 0) + 1
      return
    end

    validate_first_paid!(event, state, amount, currency)
    metrics = member[:metrics]
    metrics[:paid_orders] += 1
    metrics[:paid_value_by_currency][currency] = metrics[:paid_value_by_currency].fetch(currency, BigDecimal(0)) + amount
    metrics[:paid_conversations] += 1 unless member[:paid]
    member[:paid] = true
    if member[:qualified_at] && event.occurred_at >= member[:qualified_at] && !member[:qualified_then_paid]
      metrics[:qualified_then_paid_conversations] += 1
      member[:qualified_then_paid] = true
    end
    count_cash(metrics, state, currency)
  end

  def matching_paid_occurrence?(state, event)
    canonical = state.paid_event
    return false unless canonical && canonical.account_id == @account.id && canonical.event_type == 'order_paid' &&
                        canonical.redacted_at.nil? && canonical.observed_at <= @generated_at
    return true if canonical.id == event.id
    return true if paid_facts(canonical) == paid_facts(event) && canonical.occurred_at == event.occurred_at &&
                   canonical.conversation_id == event.conversation_id && canonical.contact_id == event.contact_id

    raise ArgumentError, 'Conflicting paid order evidence'
  end

  def paid_facts(event)
    payload = event.payload
    amount = BigDecimal(payload.fetch('value').to_s)
    currency = payload.fetch('currency')
    shop = payload.fetch('shop_domain').to_s.downcase
    order = payload.fetch('order_id').to_s
    unless amount.finite? && amount.positive? && currency.match?(/\A[A-Z]{3}\z/) && shop.present? && order.match?(/\A[1-9]\d*\z/)
      raise ArgumentError, 'Malformed paid order evidence'
    end

    [[shop, order], amount, currency]
  rescue KeyError, TypeError, NoMethodError, ArgumentError
    raise ArgumentError, 'Malformed paid order evidence'
  end

  def validate_first_paid!(event, state, amount, currency)
    first = state.snapshot.fetch('first_paid_snapshot')
    return if first['classification'] == 'paid' && first['currency'] == currency &&
              BigDecimal(first.fetch('current_order_value').to_s) == amount && Time.iso8601(first.fetch('last_payment_at')) == event.occurred_at

    raise ArgumentError, 'Contradictory first paid snapshot'
  rescue KeyError, TypeError, NoMethodError, ArgumentError
    raise ArgumentError, 'Contradictory first paid snapshot'
  end

  def count_cash(metrics, state, currency)
    cash = metrics[:latest_cash_snapshot][currency] ||= { known_refunded_total: BigDecimal(0), known_net_cash_total: BigDecimal(0),
                                                          covered_orders: 0, unavailable_orders: 0, pending_reconciliation_orders: 0,
                                                          financial_error_orders: 0, oldest_snapshot_observed_at: nil,
                                                          newest_snapshot_observed_at: nil }
    cash[:pending_reconciliation_orders] += 1 if state.reconciled_at.nil? || state.reconciliation_requested_at > state.reconciled_at
    cash[:financial_error_orders] += 1 if state.last_error.present?
    snapshot = parse_cash(state.snapshot, currency)
    unless snapshot
      cash[:unavailable_orders] += 1
      return
    end

    refunded, net, observed = snapshot
    cash[:covered_orders] += 1
    cash[:known_refunded_total] += refunded
    cash[:known_net_cash_total] += net
    cash[:oldest_snapshot_observed_at] = [cash[:oldest_snapshot_observed_at], observed].compact.min
    cash[:newest_snapshot_observed_at] = [cash[:newest_snapshot_observed_at], observed].compact.max
  end

  def parse_cash(snapshot, currency)
    return if snapshot['currency'] != currency || %w[test_order needs_review].include?(snapshot['classification'])

    refunded, net = %w[refunded net_cash].map { |key| BigDecimal(snapshot.fetch(key).to_s) }
    observed = Time.iso8601(snapshot.fetch('observed_at'))
    return unless refunded.finite? && refunded >= 0 && net.finite? && observed <= @generated_at

    [refunded, net, observed]
  rescue KeyError, TypeError, ArgumentError
    nil
  end

  def count_unknown_history
    links = Umi::ShopifyOrderAttribution.where(account_id: @account.id, conversation_id: @members.keys).verified
    links.find_in_batches do |batch|
      states = Umi::ShopifyOrderFinancialState.where(account_id: @account.id, redacted_at: nil, paid_event_id: nil,
                                                     shopify_order_id: batch.map(&:shopify_order_id))
                                              .where("snapshot ->> 'paid_history_unknown' = 'true'")
                                              .select { |state| observed_snapshot?(state.snapshot) }.index_by do |state|
        [state.shop_domain.downcase,
         state.shopify_order_id]
      end
      @coverage[:cohort_paid_history_unknown] += batch.count do |link|
        link.contact_id == @members.fetch(link.conversation_id)[:contact_id] && states.key?([link.shop_domain.downcase, link.shopify_order_id])
      end
    end
  end

  def observed_snapshot?(snapshot)
    Time.iso8601(snapshot.fetch('observed_at')) <= @generated_at
  rescue KeyError, TypeError, ArgumentError
    false
  end

  def finish_row(row)
    %i[mature immature].each do |maturity|
      metrics = row[maturity]
      complete = metrics[:incomplete_paid_evidence][:total].zero?
      metrics[:paid_evidence_complete] = complete
      metrics[:paid_totals_basis] = complete ? 'complete_for_recorded_verified_evidence' : 'lower_bound'
      metrics[:paid_value_by_currency].transform_values! { |amount| amount.to_s('F') }
      metrics[:latest_cash_snapshot].each_value do |cash|
        cash[:complete] = cash[:unavailable_orders].zero? && cash[:pending_reconciliation_orders].zero? && cash[:financial_error_orders].zero?
        cash[:known_refunded_total] = cash[:known_refunded_total].to_s('F')
        cash[:known_net_cash_total] = cash[:known_net_cash_total].to_s('F')
        cash[:oldest_snapshot_observed_at] = cash[:oldest_snapshot_observed_at]&.utc&.iso8601
        cash[:newest_snapshot_observed_at] = cash[:newest_snapshot_observed_at]&.utc&.iso8601
      end
      reason = maturity == :immature ? 'incomplete_followup' : nil
      paid_reason = reason || (complete ? nil : 'incomplete_paid_evidence')
      metrics[:rates] = { qualified: rate(metrics[:qualified_conversations], metrics[:conversations], reason),
                          paid: rate(metrics[:paid_conversations], metrics[:conversations], paid_reason),
                          qualified_then_paid: rate(metrics[:qualified_then_paid_conversations], metrics[:qualified_conversations], paid_reason) }
    end
    row.merge(spend: { status: 'unknown', value: nil }, spend_window: { from: @from.iso8601, until: @until_time.iso8601 },
              roas: nil, cost_per_paid_conversation: nil, cost_per_paid_order: nil)
  end

  def rate(numerator, denominator, reason)
    result = { numerator: numerator, denominator: denominator,
               ratio: reason || denominator.zero? ? nil : (BigDecimal(numerator) / denominator).round(6).to_s('F') }
    result[:reason] = reason if reason
    result
  end
end

# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
