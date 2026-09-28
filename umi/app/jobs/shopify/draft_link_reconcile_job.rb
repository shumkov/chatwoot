# frozen_string_literal: true

class Umi::Shopify::DraftLinkReconcileJob < ApplicationJob
  queue_as :low

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def perform(id, refresh: false)
    link = Umi::ShopifyDraftLink.find_by(id: id)
    return unless link && !link.redacted_at && (link.status == 'pending' || (refresh && %w[unavailable conflict].include?(link.status)))

    conversation = Conversation.find_by(id: link.conversation_id, account_id: link.account_id, contact_id: link.contact_id)
    unless conversation
      Umi::ShopifyDraftLink.detach(Umi::ShopifyDraftLink.where(id: id))
      return
    end
    hook = Integrations::Hook.where(account_id: link.account_id, reference_id: link.shop_domain, app_id: 'shopify', status: :enabled).sole
    reader = Umi::Shopify::CommerceReader.new(hook)
    draft = reader.fetch('draft', link.shopify_draft_id)
    active = prepare_draft(link, conversation.contact, draft)
    return unless active && draft['order_id']

    order = reader.fetch('order', draft['order_id'])
    Umi::Shopify::ManualLinkService.new(conversation: conversation, actor: User.find_by(id: link.linked_by_id)).link(order, draft: link)
  rescue Umi::Shopify::CommerceError => e
    record_error(link, e.message)
    raise if e.message == 'shopify_unavailable'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  private

  def prepare_draft(link, contact, draft)
    contact.with_lock do
      link.reload
      next false if link.redacted_at || link.status == 'unlinked' || link.status == 'resolved'
      raise Umi::Shopify::CommerceError, 'customer_mismatch' unless link.shopify_customer_id == draft.dig('customer', 'id')

      link.update!(status: 'pending', last_checked_at: Time.current, last_error: nil)
      true
    end
  end

  def record_error(link, error)
    link.with_lock do
      unless link.redacted_at || %w[unlinked resolved].include?(link.status)
        status = case error
                 when 'unavailable' then 'unavailable'
                 when 'customer_mismatch', 'already_linked', 'paid_link_correction_required', 'stale_preview' then 'conflict'
                 else link.status
                 end
        link.update!(status: status, last_error: error, last_checked_at: Time.current)
      end
    end
  end
end
