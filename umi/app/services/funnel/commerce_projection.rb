# frozen_string_literal: true

class Umi::Funnel::CommerceProjection
  UNPAID_STATUSES = %w[unpaid partial_payment].freeze

  def self.refresh(conversation)
    conversation.contact.with_lock do
      conversation.with_lock { new(conversation).perform }
    end
  end

  def initialize(conversation)
    @conversation = conversation
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def perform
    return if @conversation.contact.additional_attributes['umi_profile_redacted']

    links = Umi::ShopifyOrderAttribution.verified.where(account_id: @conversation.account_id,
                                                        conversation_id: @conversation.id, contact_id: @conversation.contact_id)
    states_by_order = Umi::ShopifyOrderFinancialState.where(account_id: @conversation.account_id, redacted_at: nil,
                                                            shopify_order_id: links.select(:shopify_order_id))
                                                     .includes(:paid_event).index_by { |state| [state.shop_domain, state.shopify_order_id] }
    states = links.map { |link| states_by_order[[link.shop_domain, link.shopify_order_id]] }
    known_states = states.compact
    status = if known_states.any? { |state| paid?(state) }
               'purchased'
             elsif known_states.any? { |state| UNPAID_STATUSES.include?(state.snapshot['classification']) }
               'order_placed'
             elsif states.any? { |state| state.nil? || state.last_error || state.snapshot.empty? }
               @conversation.custom_attributes['umi_sales_status'] || classification
             else
               classification
             end
    @conversation.project_umi_sales_status!(status)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  private

  def paid?(state)
    event = state.paid_event
    event && !event.redacted_at && event.conversation_id == @conversation.id && event.contact_id == @conversation.contact_id
  end

  def classification
    Umi::ConversationEvent.where(account_id: @conversation.account_id, conversation_id: @conversation.id,
                                 contact_id: @conversation.contact_id, event_type: 'classification_changed', redacted_at: nil)
                          .order(id: :desc).first&.payload&.fetch('status') || 'unevaluated'
  end
end
