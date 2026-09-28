# frozen_string_literal: true

class Umi::Funnel::Privacy
  def self.redact_contact!(contact, shopify_customer_id: nil)
    events = Umi::ConversationEvent.where(account_id: contact.account_id, contact_id: contact.id)
    order_ids = Umi::ShopifyOrderAttribution.where(account_id: contact.account_id).where(contact_id: contact.id)
                                            .or(Umi::ShopifyOrderAttribution.where(account_id: contact.account_id, candidate_contact_id: contact.id))
                                            .pluck(:shop_domain, :shopify_order_id)
    if shopify_customer_id.present?
      redact_financial_states!(Umi::ShopifyOrderFinancialState.where(account_id: contact.account_id)
                                                            .where("snapshot ->> 'shopify_customer_id' = ?", shopify_customer_id.to_s))
    end
    order_ids.each do |shop, order_id|
      redact_financial_states!(Umi::ShopifyOrderFinancialState.where(account_id: contact.account_id, shop_domain: shop, shopify_order_id: order_id))
    end
    redact_events!(events)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
  def self.redact_customer_orders!(account_id:, shop_domain:, customer_id:, order_ids:)
    raise ArgumentError, 'Invalid orders to redact' unless order_ids.is_a?(Array) && order_ids.all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }

    Umi::ShopifyOrderFinancialState.transaction do
      if customer_id.to_s.match?(/\A[1-9]\d*\z/)
        redact_attributions!(Umi::ShopifyOrderAttribution.where(account_id: account_id, shop_domain: shop_domain,
                                                                shopify_customer_id: customer_id.to_s))
        Umi::ShopifyDraftLink.detach(Umi::ShopifyDraftLink.where(account_id: account_id, shop_domain: shop_domain,
                                                                 shopify_customer_id: customer_id.to_s))
      end
      scope = Umi::ShopifyOrderFinancialState.where(account_id: account_id, shop_domain: shop_domain)
      redact_financial_states!(scope.where("snapshot ->> 'shopify_customer_id' = ?", customer_id.to_s)) if customer_id.to_s.match?(/\A[1-9]\d*\z/)
      order_ids.map(&:to_s).uniq.each do |id|
        state = scope.create_or_find_by!(shopify_order_id: id) do |row|
          row.assign_attributes(reconciliation_requested_at: Time.current, redacted_at: Time.current)
        end
        redact_financial_states!(scope.where(id: state.id))
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

  def self.redact_financial_states!(states)
    states.find_each do |state|
      contact = Contact.find_by(id: state.paid_event&.contact_id, account_id: state.account_id)
      operation = lambda do
        state.with_lock do
          redact_events!(Umi::ConversationEvent.where(id: state.paid_event_id)) if state.paid_event_id
          state.update!(redacted_at: Time.current, snapshot: {}, paid_event_id: nil)
        end
      end
      contact ? contact.with_lock(&operation) : operation.call
    end
  end

  def self.redact_events!(events)
    events.find_each do |event|
      event.conversion_deliveries.find_each do |delivery|
        attrs = { payload: {}, reason: 'redacted' }
        attrs[:state] = 'excluded' if %w[pending excluded rejected].include?(delivery.state)
        attrs[:reason] = 'erasure_required' if %w[sending accepted confirmed unknown].include?(delivery.state)
        delivery.update!(attrs)
      end
      payload = event.event_type == 'order_paid' ? event.payload.slice('currency', 'value', 'time_basis', 'order_origin') : {}
      event.update!(contact_id: nil, conversation_id: nil, evidence_message_ids: [], payload: payload, redacted_at: Time.current)
      Umi::ShopifyOrderFinancialState.where(paid_event_id: event.id).find_each do |state|
        state.update!(paid_event_id: nil, redacted_at: Time.current, snapshot: {})
      end
    end
  end

  # rubocop:disable Metrics/AbcSize
  def self.redact_orphans!
    links = Umi::ShopifyOrderAttribution.verified
    redact_attributions!(links.where.not(contact_id: Contact.select(:id)))
    redact_attributions!(links.where.not(conversation_id: Conversation.select(:id)))
    drafts = Umi::ShopifyDraftLink.where(redacted_at: nil)
    Umi::ShopifyDraftLink.detach(drafts.where.not(contact_id: Contact.select(:id)))
    Umi::ShopifyDraftLink.detach(drafts.where.not(conversation_id: Conversation.select(:id)))
    events = Umi::ConversationEvent.where(redacted_at: nil)
    events.where.not(contact_id: nil).where.not(contact_id: Contact.select(:id)).find_each do |event|
      redact_events!(Umi::ConversationEvent.where(id: event.id))
    end
    events.where.not(conversation_id: nil).where.not(conversation_id: Conversation.select(:id)).find_each do |event|
      redact_events!(Umi::ConversationEvent.where(id: event.id))
    end
  end
  # rubocop:enable Metrics/AbcSize

  def self.redact_shop!(shop)
    Umi::ShopifyDraftLink.where(shop_domain: shop).delete_all
    Umi::ShopifyOrderFinancialState.where(shop_domain: shop).delete_all
    prefix = Umi::ConversationEvent.sanitize_sql_like("shopify:#{shop}:order:")
    Umi::ConversationEvent.where(event_type: 'order_paid').where('occurrence_key LIKE ?', "#{prefix}%").destroy_all
  end

  def self.redact_attributions!(links)
    links.find_each do |link|
      contact = Contact.find_by(id: link.contact_id)
      operation = lambda do
        states = Umi::ShopifyOrderFinancialState.where(account_id: link.account_id, shop_domain: link.shop_domain,
                                                       shopify_order_id: link.shopify_order_id)
        states.create_or_find_by!({}) do |state|
          state.reconciliation_requested_at = Time.current
          state.redacted_at = Time.current
        end
        redact_financial_states!(states)
        link.update!(contact_id: nil, conversation_id: nil, candidate_contact_id: nil, candidate_conversation_id: nil,
                     shopify_customer_id: nil, linked_by_id: nil, redacted_at: Time.current)
      end
      contact ? contact.with_lock(&operation) : Umi::ShopifyOrderAttribution.transaction(&operation)
    end
  end
end
