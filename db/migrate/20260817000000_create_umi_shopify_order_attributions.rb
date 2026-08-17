# frozen_string_literal: true

class CreateUmiShopifyOrderAttributions < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/MethodLength
  def change
    create_table :umi_shopify_order_attributions do |t|
      t.bigint :account_id, null: false
      t.string :shop_domain, null: false
      t.bigint :candidate_conversation_id
      t.bigint :candidate_contact_id
      t.bigint :conversation_id
      t.bigint :contact_id
      t.string :shopify_order_id, null: false
      t.string :shopify_order_name
      t.decimal :order_total, precision: 20, scale: 2
      t.string :currency, limit: 3
      t.string :attribution_state, null: false
      t.string :match_method
      t.string :token_nonce, null: false
      t.string :webhook_id
      t.datetime :redacted_at
      t.timestamps

      t.index %i[account_id shopify_order_id], unique: true, name: 'idx_umi_order_attributions_order'
      t.index %i[account_id token_nonce], unique: true, name: 'idx_umi_order_attributions_token'
      t.index %i[account_id attribution_state], name: 'idx_umi_order_attributions_state'
      t.index :conversation_id, name: 'idx_umi_order_attributions_conversation'
      t.index :contact_id, name: 'idx_umi_order_attributions_contact'
      t.index :candidate_contact_id, name: 'idx_umi_order_attributions_candidate_contact'
      t.index :webhook_id, name: 'idx_umi_order_attributions_webhook'
    end

    add_foreign_key :umi_shopify_order_attributions, :accounts, column: :account_id, on_delete: :cascade
  end
  # rubocop:enable Metrics/MethodLength
end
