# frozen_string_literal: true

class Umi::Shopify::PaidOrderReport
  class IncompleteTransactions < StandardError; end

  ORDER_FIELDS = 'id,created_at,updated_at,financial_status,test,cancelled_at,currency,total_price,current_total_price,' \
                 'line_items,current_subtotal_price,current_total_discounts,current_total_tax,total_shipping_price_set'
  TRANSACTION_FIELDS = 'id,kind,status,currency,amount,amount_rounding,processed_at'
  MONEY_FIELDS = %i[captured refunded net_cash paid_value].freeze

  def initialize(account_id:, order_ids:)
    @account_id = positive_id(account_id)
    raise ArgumentError, 'Provide 1–50 distinct positive order IDs' unless order_ids.is_a?(Array)

    @order_ids = order_ids.map { |id| positive_id(id).to_s }.uniq
    raise ArgumentError, 'Provide 1–50 distinct positive order IDs' unless @order_ids.size.between?(1, 50)
  end

  def perform
    started_at = Time.current.utc.iso8601
    hook = Integrations::Hook.where(account_id: @account_id, app_id: 'shopify', status: :enabled).sole
    client = Umi::Shopify::ClientFactory.client_for(hook)
    rows = @order_ids.map { |id| read_order(client, hook.reference_id, id) }
    { account_id: @account_id, shop_domain: hook.reference_id, observed_started_at: started_at,
      observed_finished_at: Time.current.utc.iso8601, rows: rows,
      counts: rows.pluck(:classification).tally, totals_by_currency: totals(rows) }
  end

  private

  def positive_id(value)
    raise ArgumentError, 'IDs must be positive integers' unless value.to_s.match?(/\A[1-9]\d*\z/)

    value.to_i
  end

  def read_order(client, shop, id)
    order = client.get(path: "orders/#{id}", query: { fields: ORDER_FIELDS }).body.fetch('order')
    response = client.get(path: "orders/#{id}/transactions", query: { in_shop_currency: true, fields: TRANSACTION_FIELDS })
    raise IncompleteTransactions, 'Transaction list is incomplete' if response.next_page_info.present?
    raise ArgumentError, 'Order response ID mismatch' unless order.fetch('id').to_s == id

    row = build_row(order, response.body.fetch('transactions'))
    row[:paid_basket] = paid_basket(order) if row[:classification] == 'paid'
    row.merge(
      order_id: id,
      conversation_id: Umi::ShopifyOrderAttribution.verified.find_by(account_id: @account_id, shop_domain: shop,
                                                                     shopify_order_id: id)&.conversation_id
    )
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def paid_basket(order)
    basket = {}
    basket['items'] = order['line_items'].map { |item| item.slice('id', 'variant_id', 'current_quantity') } if order['line_items'].is_a?(Array)
    %w[current_subtotal_price current_total_discounts current_total_tax].each do |key|
      value = BigDecimal(order[key].to_s, exception: false)
      basket[key] = value.to_s('F') if value&.finite? && !value.negative?
    end
    shipping = order.dig('total_shipping_price_set', 'shop_money')
    value = BigDecimal(shipping.to_h['amount'].to_s, exception: false)
    basket['shipping'] = value.to_s('F') if value&.finite? && !value.negative? && shipping['currency_code'] == order['currency']
    basket
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def build_row(order, transactions)
    reasons = []
    original = money(order['total_price'], reasons, 'invalid_total_price')
    current = money(order['current_total_price'], reasons, 'invalid_current_total_price')
    currency = order['currency']
    reasons << 'unknown_currency' unless currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/)
    movement = money_movement(transactions, currency, reasons)
    row = { original_order_value: original&.to_s('F'), current_order_value: current&.to_s('F'), currency: currency,
            financial_status: order['financial_status'], order_created_at: timestamp(order['created_at'], reasons, 'invalid_order_time'),
            order_updated_at: timestamp(order['updated_at'], reasons, 'invalid_order_time'), last_payment_at: movement[:last_payment_at] }
    classification = classify(order, current, movement, reasons)
    row.merge(movement.slice(:captured, :refunded, :net_cash).transform_values { |amount| amount&.to_s('F') })
       .merge(classification: classification, review_reasons: reasons.uniq)
  end

  def money(value, reasons, reason)
    amount = BigDecimal(value.to_s, exception: false)
    return amount if amount&.finite? && !amount.negative?

    reasons << reason
    nil
  end

  def timestamp(value, reasons, reason)
    Time.iso8601(value).utc.iso8601
  rescue ArgumentError, TypeError
    reasons << reason
    nil
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def money_movement(transactions, currency, reasons)
    ids = transactions.map { |transaction| transaction['id'].to_s }
    reasons << 'duplicate_transaction_id' if ids.uniq.size != ids.size
    reasons << 'missing_transaction_id' if ids.any?(&:blank?)
    movements = transactions.map { |transaction| transaction_movement(transaction, currency, reasons) }
    captured = sum_movement(movements, 'capture')
    refunded = sum_movement(movements, 'refund')
    captured = refunded = nil if reasons.intersect?(%w[duplicate_transaction_id missing_transaction_id transaction_currency_mismatch])
    payment_times = movements.select { |movement| movement[:kind] == 'capture' }.pluck(:time)
    { captured: captured, refunded: refunded, net_cash: captured && refunded ? captured - refunded : nil,
      last_payment_at: payment_times.empty? || payment_times.include?(nil) ? nil : payment_times.max }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def transaction_movement(transaction, currency, reasons)
    amount = money(transaction['amount'], reasons, 'invalid_transaction_amount')
    reasons << 'transaction_currency_mismatch' unless transaction['currency'].present? && transaction['currency'] == currency
    if transaction['amount_rounding'].present?
      rounding = money(transaction['amount_rounding'], reasons, 'invalid_cash_rounding')
      reasons << 'nonzero_cash_rounding' if rounding && !rounding.zero?
    end
    reasons << 'pending_refund' if transaction['kind'] == 'refund' && transaction['status'] == 'pending'
    return {} unless transaction['status'] == 'success' && %w[sale capture refund].include?(transaction['kind'])

    { kind: transaction['kind'] == 'refund' ? 'refund' : 'capture', amount: amount,
      time: timestamp(transaction['processed_at'], reasons, 'invalid_transaction_time') }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def sum_movement(movements, kind)
    amounts = movements.select { |movement| movement[:kind] == kind }.pluck(:amount)
    amounts.include?(nil) ? nil : amounts.sum(BigDecimal(0))
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def classify(order, current, movement, reasons)
    return 'test_order' if order['test'] == true
    return 'needs_review' if reasons.any?

    captured, refunded = movement.values_at(:captured, :refunded)
    status = order['financial_status']
    return 'refunded' if status == 'refunded' && captured.positive? && captured == refunded
    return review(reasons, 'cancelled_with_money') if order['cancelled_at'].present? && (captured.positive? || refunded.positive?)
    return review(reasons, 'unknown_financial_status') unless %w[pending authorized partially_paid paid voided refunded
                                                                 partially_refunded].include?(status)
    return refund_classification(status, captured, refunded, reasons) if %w[refunded partially_refunded].include?(status) || refunded.positive?

    cancelled_unpaid = order['cancelled_at'].present? && status != 'paid'
    return 'no_sale' if captured.zero? && refunded.zero? && (current.zero? || status == 'voided' || cancelled_unpaid)

    return payment_classification(status, current, captured, reasons)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def refund_classification(status, captured, refunded, reasons)
    return 'partially_refunded' if status == 'partially_refunded' && captured > refunded && refunded.positive?

    review(reasons, 'refund_status_mismatch')
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def payment_classification(status, current, captured, reasons)
    return 'paid' if status == 'paid' && current.positive? && captured == current

    if %w[pending authorized partially_paid].include?(status)
      return 'unpaid' if captured.zero?
      return 'partial_payment' if captured.positive? && captured < current
    end
    review(reasons, 'payment_status_mismatch')
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def review(reasons, reason)
    reasons << reason
    'needs_review'
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def totals(rows)
    excluded = %w[test_order needs_review]
    resolved = rows.reject { |row| excluded.include?(row[:classification]) }
    resolved.group_by { |row| row[:currency] }.transform_values do |currency_rows|
      paid = currency_rows.select { |row| row[:classification] == 'paid' }
      result = { paid_orders: paid.size, paid_value: paid.sum(BigDecimal(0)) { |row| BigDecimal(row[:current_order_value]) } }
      %i[captured refunded net_cash].each do |field|
        result[field] = currency_rows.sum(BigDecimal(0)) { |row| BigDecimal(row[field]) }
      end
      MONEY_FIELDS.each { |field| result[field] = result[field].to_s('F') }
      result
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end
