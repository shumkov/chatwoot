# frozen_string_literal: true

class Umi::ShopifyDraftLink < ApplicationRecord
  self.table_name = 'umi_shopify_draft_links'
  belongs_to :account
  validates :shop_domain, :shopify_draft_id, presence: true
  validates :status, inclusion: { in: %w[pending resolved unavailable conflict unlinked] }
  scope :active, -> { where(redacted_at: nil).where.not(status: 'unlinked') }

  def self.detach(scope)
    scope.find_each do |link|
      link.update!(contact_id: nil, conversation_id: nil, shopify_customer_id: nil, linked_by_id: nil,
                   name: nil, last_error: nil, redacted_at: Time.current)
    end
  end
end
