# frozen_string_literal: true

class Umi::Shopify::ManualLinkService
  def self.link_customer(contact, customer)
    contact.with_lock do
      raise Umi::Shopify::CommerceError, 'redacted' if contact.additional_attributes['umi_profile_redacted']

      previous = contact.additional_attributes['shopify_customer_id'].to_s
      next if previous == customer.fetch('id')

      if previous.present? && (Umi::ShopifyOrderAttribution.verified.exists?(contact_id: contact.id) ||
          Umi::ShopifyDraftLink.active.exists?(contact_id: contact.id) ||
          Umi::ConversationEvent.exists?(contact_id: contact.id, event_type: 'order_paid', redacted_at: nil))
        raise Umi::Shopify::CommerceError, 'customer_in_use'
      end

      attributes = contact.additional_attributes.except(*Umi::Shopify::CustomerContactMapper::SHOPIFY_KEYS)
      contact.update!(additional_attributes: attributes.merge('shopify_customer_id' => customer.fetch('id')))
    end
  end

  def initialize(conversation:, actor:)
    @conversation = conversation
    @contact = conversation.contact
    @actor = actor
    @hook = Integrations::Hook.where(account_id: conversation.account_id, app_id: 'shopify', status: :enabled).sole
  end

  # rubocop:disable Metrics/MethodLength
  def link(object, draft: nil)
    result = if object.fetch('kind') == 'draft'
               @contact.with_lock do
                 validate_identity!(object)
                 link_draft!(object)
               end
             else
               with_order_lock(object.fetch('id')) do |state|
                 @contact.with_lock do
                   validate_identity!(object)
                   validate_paid_owner!(state)
                   validate_draft!(draft, object) if draft
                   link_order!(object, resolving_draft: draft.present?).tap do
                     draft&.update!(status: 'resolved', shopify_order_id: object.fetch('id'), last_error: nil, last_checked_at: Time.current)
                   end
                 end
               end
             end
    if object['kind'] == 'order'
      Umi::Shopify::OrderFinancialStateService.request(account_id: @conversation.account_id, shop_domain: @hook.reference_id, order_id: object['id'])
      Umi::Funnel::CommerceProjection.refresh(@conversation)
    end
    result
  end
  # rubocop:enable Metrics/MethodLength

  def unlink(kind, id)
    draft = draft_scope.find_by!(shopify_draft_id: id) if kind == 'draft'
    order_id = kind == 'order' ? id : draft.shopify_order_id
    if order_id
      with_order_lock(order_id) do |state|
        @contact.with_lock do
          raise Umi::Shopify::CommerceError, 'paid_link_correction_required' if state.paid_event&.conversation_id

          link = order_scope.find_by!(shopify_order_id: order_id)
          link.update!(conversation_id: nil, contact_id: nil, candidate_contact_id: nil, candidate_conversation_id: nil,
                       attribution_state: 'unlinked')
          draft_scope.where(shopify_order_id: order_id).find_each { |linked_draft| linked_draft.update!(status: 'unlinked') }
          Umi::Funnel::CommerceProjection.refresh(@conversation)
        end
      end
    else
      unlink_draft!(draft)
    end
  end

  private

  def unlink_draft!(draft)
    @contact.with_lock do
      draft.with_lock do
        current_owner = draft.contact_id == @contact.id && draft.conversation_id == @conversation.id
        if !current_owner || draft.redacted_at || draft.status == 'unlinked' || draft.shopify_order_id.present?
          raise Umi::Shopify::CommerceError, 'stale_preview'
        end

        draft.update!(status: 'unlinked')
      end
    end
  end

  def with_order_lock(order_id)
    Umi::ShopifyOrderFinancialState.transaction do
      state = Umi::ShopifyOrderFinancialState.create_or_find_by!(account_id: @conversation.account_id,
                                                                 shop_domain: @hook.reference_id.downcase, shopify_order_id: order_id) do |row|
        row.reconciliation_requested_at = Time.current
      end
      state.class.connection.execute("SELECT pg_advisory_xact_lock(74219, #{state.id.to_i})")
      state.reload
      raise Umi::Shopify::CommerceError, 'redacted' if state.redacted_at

      yield state
    end
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def validate_identity!(object)
    @conversation.reload
    raise Umi::Shopify::CommerceError, 'customer_mismatch' unless @conversation.contact_id == @contact.id
    raise Umi::Shopify::CommerceError, 'redacted' if @contact.additional_attributes['umi_profile_redacted']

    customer = object['customer']
    existing = @contact.additional_attributes['shopify_customer_id'].to_s
    raise Umi::Shopify::CommerceError, 'customer_mismatch' if customer && existing.present? && existing != customer.fetch('id')

    self.class.link_customer(@contact, customer) if customer && existing.empty?
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def validate_paid_owner!(state)
    event = state.paid_event
    return unless event
    return if (!event.contact_id || event.contact_id == @contact.id) && (!event.conversation_id || event.conversation_id == @conversation.id)

    raise Umi::Shopify::CommerceError, 'paid_link_correction_required'
  end

  def validate_draft!(draft, object)
    draft.reload
    unless draft.redacted_at.nil? && draft.status == 'pending' && draft.contact_id == @contact.id && draft.conversation_id == @conversation.id
      raise Umi::Shopify::CommerceError, 'stale_preview'
    end
    raise Umi::Shopify::CommerceError, 'customer_mismatch' unless draft.shopify_customer_id == object.dig('customer', 'id')
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def link_order!(object, resolving_draft: false)
    row = Umi::ShopifyOrderAttribution.create_or_find_by!(account_id: @conversation.account_id, shopify_order_id: object.fetch('id')) do |link|
      link.assign_attributes(shop_domain: @hook.reference_id.downcase, source: 'operator', attribution_state: 'unlinked')
    end
    row.with_lock do
      raise Umi::Shopify::CommerceError, 'redacted' if row.redacted_at
      raise Umi::Shopify::CommerceError, 'customer_mismatch' unless row.shop_domain == @hook.reference_id.downcase

      if resolving_draft && row.source == 'operator' && row.attribution_state == 'unlinked' && row.linked_at
        raise Umi::Shopify::CommerceError, 'stale_preview'
      end

      if row.attribution_state == 'verified'
        raise Umi::Shopify::CommerceError, 'already_linked' unless row.conversation_id == @conversation.id && row.contact_id == @contact.id

        next
      end
      row.update!(source: 'operator', attribution_state: 'verified', match_method: 'operator', contact_id: @contact.id,
                  conversation_id: @conversation.id, shopify_customer_id: object.dig('customer', 'id'),
                  shopify_order_name: object['name'], order_total: object['amount'], currency: object['currency'],
                  linked_by_id: @actor&.id, linked_at: Time.current)
    end
    row
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def link_draft!(object)
    row = Umi::ShopifyDraftLink.create_or_find_by!(account_id: @conversation.account_id, shop_domain: @hook.reference_id.downcase,
                                                   shopify_draft_id: object.fetch('id'))
    row.with_lock do
      raise Umi::Shopify::CommerceError, 'redacted' if row.redacted_at

      if row.conversation_id && row.status != 'unlinked'
        raise Umi::Shopify::CommerceError, 'already_linked' unless row.conversation_id == @conversation.id && row.contact_id == @contact.id

        next
      end
      row.update!(conversation_id: @conversation.id, contact_id: @contact.id, shopify_customer_id: object.dig('customer', 'id'),
                  name: object['name'], status: 'pending', shopify_order_id: nil, linked_by_id: @actor&.id, linked_at: Time.current, last_error: nil)
    end
    row
  end

  def order_scope
    Umi::ShopifyOrderAttribution.where(account_id: @conversation.account_id, shop_domain: @hook.reference_id.downcase,
                                       conversation_id: @conversation.id, contact_id: @contact.id)
  end

  def draft_scope
    Umi::ShopifyDraftLink.active.where(account_id: @conversation.account_id, shop_domain: @hook.reference_id.downcase,
                                       conversation_id: @conversation.id, contact_id: @contact.id)
  end
end
