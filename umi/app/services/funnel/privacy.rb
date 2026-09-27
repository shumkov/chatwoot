# frozen_string_literal: true

class Umi::Funnel::Privacy
  def self.redact_contact!(contact)
    events = Umi::ConversationEvent.where(account_id: contact.account_id, contact_id: contact.id)
    order_ids = Umi::ShopifyOrderAttribution.where(account_id: contact.account_id).where(contact_id: contact.id)
                                            .or(Umi::ShopifyOrderAttribution.where(account_id: contact.account_id, candidate_contact_id: contact.id))
                                            .pluck(:shop_domain, :shopify_order_id)
    order_ids.each do |shop, order_id|
      Umi::ShopifyOrderFinancialState.where(account_id: contact.account_id, shop_domain: shop, shopify_order_id: order_id)
                                     .find_each { |state| state.update!(redacted_at: Time.current, paid_event_id: nil, snapshot: {}) }
    end
    redact_events!(events)
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

  def self.redact_orphans!
    events = Umi::ConversationEvent.where(redacted_at: nil)
    events.where.not(contact_id: nil).where.not(contact_id: Contact.select(:id)).find_each do |event|
      redact_events!(Umi::ConversationEvent.where(id: event.id))
    end
    events.where.not(conversation_id: nil).where.not(conversation_id: Conversation.select(:id)).find_each do |event|
      redact_events!(Umi::ConversationEvent.where(id: event.id))
    end
  end

  def self.redact_shop!(shop)
    Umi::ShopifyOrderFinancialState.where(shop_domain: shop).delete_all
    prefix = Umi::ConversationEvent.sanitize_sql_like("shopify:#{shop}:order:")
    Umi::ConversationEvent.where(event_type: 'order_paid').where('occurrence_key LIKE ?', "#{prefix}%").destroy_all
  end
end
