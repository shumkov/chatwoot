# frozen_string_literal: true

class Umi::ShopifyOrderFinancialState < ApplicationRecord
  self.table_name = 'umi_shopify_order_financial_states'
  belongs_to :account
  belongs_to :paid_event, class_name: 'Umi::ConversationEvent', optional: true
  validates :shop_domain, :shopify_order_id, :reconciliation_requested_at, presence: true
  validates :shopify_order_id, format: { with: /\A[1-9]\d*\z/ }
  before_validation { self.shop_domain = shop_domain.to_s.downcase }
  scope :pending, -> { where('reconciled_at IS NULL OR reconciliation_requested_at > reconciled_at') }
end
