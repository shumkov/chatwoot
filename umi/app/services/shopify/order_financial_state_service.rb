# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Shopify::OrderFinancialStateService
  SNAPSHOT_FIELDS = %w[classification review_reasons currency original_order_value current_order_value captured refunded net_cash
                       last_payment_at order_created_at order_updated_at paid_basket shopify_customer_id order_source].freeze

  def self.request(account_id:, shop_domain:, order_id:)
    return unless Umi::Funnel::Configuration.enabled?(account_id)

    raise ArgumentError, 'Invalid order ID' unless order_id.to_s.match?(/\A[1-9]\d*\z/)

    shop = shop_domain.to_s.downcase
    Integrations::Hook.where(account_id: account_id, app_id: 'shopify', reference_id: shop, status: :enabled).sole
    state = Umi::ShopifyOrderFinancialState.create_or_find_by!(account_id: account_id, shop_domain: shop, shopify_order_id: order_id.to_s) do |row|
      row.reconciliation_requested_at = Time.current
    end
    state.with_lock { state.update!(reconciliation_requested_at: Time.current, last_error: nil) }
    begin
      Umi::Shopify::OrderFinancialReconcileJob.perform_later(state.id)
    rescue StandardError => e
      Rails.logger.error("[umi-funnel] financial enqueue failed: #{e.class}")
    end
    state
  end

  def initialize(state)
    @state = state
  end

  def perform
    return unless Umi::Funnel::Configuration.enabled?(@state.account_id)

    Umi::ShopifyOrderFinancialState.transaction do
      # A separate advisory lock serializes reads without blocking webhook requests on the row.
      Umi::ShopifyOrderFinancialState.connection.execute("SELECT pg_advisory_xact_lock(74219, #{@state.id.to_i})")
      @state.reload
      next if @state.redacted_at

      erased = Umi::ShopifyOrderAttribution.where(account_id: @state.account_id, shop_domain: @state.shop_domain,
                                                  shopify_order_id: @state.shopify_order_id).where.not(redacted_at: nil).exists?
      if erased
        @state.update!(redacted_at: Time.current, snapshot: {}, paid_event_id: nil)
        next
      end

      cutoff = @state.reconciliation_requested_at
      report = Umi::Shopify::PaidOrderReport.new(account_id: @state.account_id, order_ids: [@state.shopify_order_id]).perform
      raise ArgumentError, 'Financial shop mismatch' unless report[:shop_domain].downcase == @state.shop_domain

      row = report.fetch(:rows).sole.deep_stringify_keys.slice(*SNAPSHOT_FIELDS).merge('observed_at' => report.fetch(:observed_finished_at))
      Umi::Funnel::PaidCustomerLink.new(@state).with_identity(row) do |snapshot, attribution, contact|
        persist!(snapshot, cutoff, attribution, contact)
      end
    end
  rescue StandardError => e
    Umi::ShopifyOrderFinancialState.find(@state.id).update!(last_error: e.class.name.to_s.first(255)) if @state.persisted?
    raise
  end

  private

  def persist!(row, cutoff, attribution, contact)
    @state.with_lock do
      next if @state.redacted_at

      if contact&.additional_attributes&.[]('umi_profile_redacted')
        @state.update!(redacted_at: Time.current, paid_event_id: nil, snapshot: {})
        next
      end
      conversation = Conversation.find_by(id: attribution&.conversation_id, account_id: @state.account_id, contact_id: contact&.id) if attribution
      if attribution && !conversation
        Umi::Funnel::Privacy.redact_attributions!(Umi::ShopifyOrderAttribution.where(id: attribution.id))
        next
      end
      prior = @state.snapshot['first_paid_snapshot']
      row['first_paid_snapshot'] = prior if prior
      if row['classification'] == 'paid'
        row['first_paid_snapshot'] ||= row.except('first_paid_snapshot', 'shopify_customer_id', 'identity_hold').deep_dup
        event = paid_event!(row, conversation, contact)
        @state.paid_event = event
      elsif !@state.paid_event_id && (@state.snapshot['paid_history_unknown'] || %w[refunded partially_refunded].include?(row['classification']))
        row['paid_history_unknown'] = true
      end
      Umi::Funnel::PaidCustomerLink.attach(@state.paid_event, contact, attribution) if @state.paid_event
      @state.update!(snapshot: row, reconciled_at: cutoff, last_error: nil)
      Umi::Funnel::CommerceProjection.refresh(conversation) if conversation
    end
  end

  def paid_event!(row, conversation, contact)
    Umi::ConversationEvent.record!(account_id: @state.account_id, conversation_id: conversation&.id, contact_id: contact&.id,
                                   event_type: 'order_paid', occurrence_key: "shopify:#{@state.shop_domain}:order:#{@state.shopify_order_id}:paid",
                                   occurred_at: Time.iso8601(row.fetch('last_payment_at')), observed_at: Time.current, provenance: 'shopify',
                                   payload: { shop_domain: @state.shop_domain, order_id: @state.shopify_order_id, currency: row.fetch('currency'),
                                              value: row.fetch('current_order_value'), order_origin: 'unknown',
                                              time_basis: 'last_successful_payment_at_observed_full_payment' })
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
