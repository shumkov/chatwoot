# frozen_string_literal: true

class Umi::ShopifyOrderAttribution < ApplicationRecord
  self.table_name = 'umi_shopify_order_attributions'

  STATES = %w[unlinked verified unverified unavailable].freeze

  belongs_to :account

  validates :shop_domain, :shopify_order_id, :attribution_state, :token_nonce, presence: true
  validates :attribution_state, inclusion: { in: STATES }

  scope :verified, -> { where(attribution_state: 'verified', redacted_at: nil).where.not(conversation_id: nil).where.not(contact_id: nil) }

  def self.detach_for(contact)
    where(contact_id: contact.id).or(where(candidate_contact_id: contact.id)).find_each do |attribution|
      attribution.update!(
        conversation_id: nil,
        candidate_conversation_id: nil,
        contact_id: nil,
        candidate_contact_id: nil,
        redacted_at: Time.current
      )
    end
  end
end
