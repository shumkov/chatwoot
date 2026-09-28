class AddManualShopifyLinks < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/MethodLength
  def change
    change_column_null :umi_shopify_order_attributions, :token_nonce, true
    add_column :umi_shopify_order_attributions, :source, :string, null: false, default: 'storefront'
    add_column :umi_shopify_order_attributions, :shopify_customer_id, :string
    add_column :umi_shopify_order_attributions, :linked_by_id, :bigint
    add_column :umi_shopify_order_attributions, :linked_at, :datetime

    create_table :umi_shopify_draft_links do |t|
      t.bigint :account_id, null: false
      t.string :shop_domain, null: false
      t.string :shopify_draft_id, null: false
      t.bigint :contact_id
      t.bigint :conversation_id
      t.string :shopify_customer_id
      t.string :shopify_order_id
      t.string :name
      t.string :status, null: false, default: 'pending'
      t.bigint :linked_by_id
      t.datetime :linked_at
      t.datetime :last_checked_at
      t.string :last_error
      t.datetime :redacted_at
      t.timestamps
      t.index [:account_id, :shop_domain, :shopify_draft_id], unique: true, name: 'umi_draft_links_identity'
      t.index [:account_id, :conversation_id]
    end
  end
  # rubocop:enable Metrics/MethodLength
end
