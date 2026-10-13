# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/BlockLength
class Umi::Funnel::WeeklyActivityReport
  def initialize(account:, since:, until_time:, as_of:)
    @account = account
    @from = since
    @until = until_time
    @as_of = as_of
    raise ArgumentError, 'Invalid weekly report window' unless @from < @until && @until <= @as_of

    @events = Umi::ConversationEvent.where(account_id: account.id, redacted_at: nil).where(observed_at: ..Time.current)
    @period = @events.where(occurred_at: @from...@until)
  end

  def perform
    messages = @period.where(event_type: 'message_received').order(:occurred_at, :id).to_a
    qualified = @period.where(event_type: 'conversation_qualified').order(:occurred_at, :id).to_a
    @conversations = @account.conversations.where(id: (messages + qualified).map(&:conversation_id)).includes(:contact).index_by(&:id)
    conversation_evidence = messages.select { |event| usable_identity?(event) }.group_by(&:conversation_id).map do |id, events|
      { conversation_id: id, display_id: @conversations.fetch(id).display_id,
        customer_display_name: @conversations.fetch(id).contact.name,
        ad_referrals: events.filter_map do |event|
          next if event.payload['ad_id'].blank?

          { message_id: event.payload['message_id'], ad_id: event.payload['ad_id'], ad_name: ad_title(event),
            occurred_at: event.occurred_at.iso8601(6) }
        end,
        incoming_message_ids: events.flat_map { |event| event.payload['message_id'] }.compact.uniq,
        event_ids: events.map(&:id) }
    end
    qualifying = qualified.select { |event| usable_identity?(event) }.group_by(&:conversation_id).filter_map do |id, events|
      correction = @events.where(conversation_id: id, contact_id: @conversations.fetch(id).contact_id, event_type: 'classification_changed')
                          .where(occurred_at: events.first.occurred_at..@as_of)
                          .where("payload ->> 'status' IN (?)", %w[qualified not_sales unevaluated])
                          .order(:occurred_at, :id).last
      next if correction && correction.payload['status'] != 'qualified'

      { conversation_id: id, display_id: @conversations.fetch(id).display_id, event_ids: events.map(&:id) }
    end
    orders, redacted = payment_evidence
    verified = orders.select { |row| row[:attribution_verified] }
    { period: { from: @from.iso8601, until: @until.iso8601 }, outcome_cutoff: @as_of.iso8601,
      knowledge_basis: 'current_records_at_generation', historical_restatement_possible: true,
      membership_basis: 'raw_recorded_activity_requires_business_audit', conversations: conversation_evidence.size,
      conversation_evidence: conversation_evidence, qualified_conversations: qualifying.size, qualification_evidence: qualifying,
      paid_orders: orders.size, verified_chat_paid_orders: verified.size,
      verified_chat_paid_value_by_currency: verified.group_by { |row| row[:currency] }.transform_values do |rows|
        rows.sum { |row| BigDecimal(row[:value]) }.to_s('F')
      end,
      paid_order_evidence: orders, workflow_candidates: workflow_candidates(orders),
      coverage: { redacted_paid_events: redacted, observation_boundary: Umi::Funnel::Configuration.started_at.iso8601,
                  period_complete: @from >= Umi::Funnel::Configuration.started_at } }
  end

  private

  def workflow_candidates(orders)
    events = @period.where(id: orders.pluck(:event_id)).where.not(contact_id: nil).order(:id).group_by(&:contact_id)
    messages = Message.where(account_id: @account.id, created_at: @from...@until, message_type: %i[incoming outgoing])
    @account.conversations.where(contact_id: @account.contacts.where(id: events.keys), id: messages.select(:conversation_id))
            .includes(:contact).order(:id).filter_map do |conversation|
      next if conversation.contact.additional_attributes['umi_profile_redacted']

      { conversation_id: conversation.id, display_id: conversation.display_id,
        event_ids: events.fetch(conversation.contact_id).map(&:id) }
    end
  end

  def usable_identity?(event)
    conversation = @conversations[event.conversation_id]
    conversation && event.contact_id == conversation.contact_id && !conversation.contact.additional_attributes['umi_profile_redacted']
  end

  def ad_title(event)
    message = Message.find_by(id: event.payload['message_id'], account_id: @account.id, conversation_id: event.conversation_id)
    return unless message && Umi::FbigAdAttribution.valid_source?(message, @conversations.fetch(event.conversation_id))

    referral = message.content_attributes['referral']
    referral.dig('ads_context_data', 'ad_title').presence if referral['ad_id'].to_s == event.payload['ad_id'].to_s
  end

  def payment_evidence
    orders = {}
    redacted = @period.unscope(where: :redacted_at).where(event_type: 'order_paid').where.not(redacted_at: nil).count
    @period.where(event_type: 'order_paid').order(:occurred_at, :id).each do |event|
      contact = @account.contacts.find_by(id: event.contact_id)
      if contact&.additional_attributes&.[]('umi_profile_redacted')
        redacted += 1
        next
      end
      shop, id = event.payload.values_at('shop_domain', 'order_id').map(&:to_s)
      shop = shop.downcase
      amount, currency = event.payload.values_at('value', 'currency')
      value = BigDecimal(amount.to_s)
      unless shop.present? && id.match?(/\A[1-9]\d*\z/) && value.finite? && value.positive? && currency.to_s.match?(/\A[A-Z]{3}\z/)
        raise ArgumentError, 'Malformed paid order evidence'
      end

      key = [shop, id]
      if orders[key]
        unless orders[key].values_at(:value, :currency, :occurred_at) == [value.to_s('F'), currency, event.occurred_at.iso8601(6)]
          raise ArgumentError, 'Conflicting paid order evidence'
        end

        next
      end
      link = Umi::ShopifyOrderAttribution.find_by(account_id: @account.id, shop_domain: shop, shopify_order_id: id)
      state = Umi::ShopifyOrderFinancialState.find_by(account_id: @account.id, shop_domain: shop, shopify_order_id: id)
      if link&.redacted_at || state&.redacted_at
        redacted += 1
        next
      end

      reason = attribution_reason(event, link, state, value, currency)
      orders[key] = { event_id: event.id, shop_domain: shop, shopify_order_id: id, value: value.to_s('F'), currency: currency,
                      occurred_at: event.occurred_at.iso8601(6), observed_at: event.observed_at.iso8601(6),
                      attribution_verified: reason.nil?, attribution_reason: reason,
                      conversation_id: event.conversation_id,
                      display_id: @account.conversations.find_by(id: event.conversation_id)&.display_id,
                      attribution_state: link&.attribution_state, attribution_linked_at: link&.linked_at&.iso8601(6),
                      attribution_updated_at: link&.updated_at&.iso8601(6), settlement_command_message_id: link&.settlement_command_message_id,
                      financial_classification: state&.snapshot&.[]('classification'),
                      order_source: state&.snapshot&.fetch('order_source', {})&.slice('checkout_id', 'source_name') }
    end
    [orders.values, redacted]
  end

  def attribution_reason(event, link, state, amount, currency)
    return 'missing_verified_link' unless link && link.attribution_state == 'verified' && link.conversation_id && link.contact_id
    return 'identity_mismatch' unless link.conversation_id == event.conversation_id && link.contact_id == event.contact_id &&
                                      @account.conversations.exists?(id: event.conversation_id, contact_id: event.contact_id)
    return 'missing_financial_state' unless state&.paid_event

    canonical = state.paid_event
    return 'financial_evidence_mismatch' unless canonical.event_type == 'order_paid' && canonical.redacted_at.nil? &&
                                                canonical.account_id == @account.id && canonical.occurred_at == event.occurred_at &&
                                                canonical.conversation_id == event.conversation_id && canonical.contact_id == event.contact_id &&
                                                canonical.payload.slice('shop_domain', 'order_id', 'value', 'currency') ==
                                                event.payload.slice('shop_domain', 'order_id', 'value', 'currency')

    first = state.snapshot['first_paid_snapshot']
    return 'missing_first_paid_snapshot' unless first
    return if first['classification'] == 'paid' && first['currency'] == currency &&
              BigDecimal(first.fetch('current_order_value').to_s) == amount && Time.iso8601(first.fetch('last_payment_at')) == event.occurred_at

    'financial_evidence_mismatch'
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/BlockLength
