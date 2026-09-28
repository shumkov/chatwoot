# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
class Umi::Funnel::PaidCustomerLink
  def self.reconcile
    Umi::ShopifyOrderFinancialState.where(account_id: Umi::Funnel::Configuration.account_ids, redacted_at: nil)
                                   .where.not(paid_event_id: nil).find_each do |state|
      next if state.paid_event.contact_id && state.paid_event.conversation_id

      new(state).with_identity(state.snapshot.deep_dup) do |row, attribution, contact|
        state.with_lock do
          next if state.redacted_at || !state.paid_event || state.paid_event.redacted_at
          next unless state.snapshot['shopify_customer_id'] == row['shopify_customer_id']

          attach(state.paid_event, contact, attribution)
          state.update!(snapshot: state.snapshot.merge(row.slice('identity_hold')))
        end
      end
    end
  end

  def self.attach(event, contact, attribution)
    return unless contact && !contact.additional_attributes['umi_profile_redacted']

    event.with_lock do
      next if event.redacted_at || (event.contact_id && event.contact_id != contact.id)

      conversation = Conversation.find_by(id: attribution&.conversation_id, account_id: event.account_id, contact_id: contact.id)
      attrs = {}
      attrs[:contact_id] = contact.id unless event.contact_id
      attrs[:conversation_id] = conversation.id if conversation && !event.conversation_id
      event.update!(attrs) if attrs.present?
      conversation.with_lock { conversation.project_umi_sales_status!('purchased') } if conversation && event.conversation_id == conversation.id
    end
  end

  def initialize(state)
    @state = state
  end

  def with_identity(row)
    hook = Integrations::Hook.where(account_id: @state.account_id, app_id: 'shopify', status: :enabled).sole
    raise ArgumentError, 'Financial shop mismatch' unless hook.reference_id.downcase == @state.shop_domain

    _, contact, = resolve(row)
    owner_id = @state.paid_event&.contact_id
    contact = Contact.find_by(id: owner_id, account_id: @state.account_id) if owner_id
    operation = lambda do
      if contact&.additional_attributes&.[]('umi_profile_redacted')
        Umi::Funnel::Privacy.redact_financial_states!(Umi::ShopifyOrderFinancialState.where(id: @state.id))
        next
      end
      attribution, current, reason = resolve(row)
      # A changed match needs a later pass with that contact's lock.
      current = nil if current&.id != contact&.id
      reason ||= 'customer_changed' if current.nil? && contact
      row['identity_hold'] = reason
      yield(row, attribution, current)
    end
    contact ? contact.with_lock(&operation) : operation.call
  end

  private

  def resolve(row)
    attribution = Umi::ShopifyOrderAttribution.verified.find_by(account_id: @state.account_id, shop_domain: @state.shop_domain,
                                                                shopify_order_id: @state.shopify_order_id)
    attributed = Contact.find_by(id: attribution&.contact_id, account_id: @state.account_id)
    return [nil, nil, 'attribution_conflict'] if attribution && @state.paid_event&.contact_id && @state.paid_event.contact_id != attributed&.id

    customer_id = row['shopify_customer_id']
    return [attribution, attributed, attributed ? nil : 'customer_unknown'] if customer_id.blank?

    if attribution&.source == 'operator' && attribution.shopify_customer_id == customer_id &&
       attributed&.additional_attributes&.[]('shopify_customer_id').to_s == customer_id
      return [nil, nil, 'customer_redacted'] if attributed.additional_attributes['umi_profile_redacted']

      return [attribution, attributed, nil]
    end

    contacts = Contact.where(account_id: @state.account_id).where("additional_attributes ->> 'shopify_customer_id' = ?", customer_id).limit(2).to_a
    return [nil, nil, 'customer_missing'] if contacts.empty?
    return [nil, nil, 'customer_ambiguous'] if contacts.size != 1

    contact = contacts.first
    return [nil, nil, 'customer_redacted'] if contact.additional_attributes['umi_profile_redacted']
    return [nil, nil, 'attribution_conflict'] if attribution && attributed&.id != contact.id
    return [nil, nil, 'customer_changed'] if @state.paid_event&.contact_id && @state.paid_event.contact_id != contact.id

    [attribution, contact, nil]
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
