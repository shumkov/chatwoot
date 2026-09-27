# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength

class CreateUmiFunnelEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :umi_conversation_events do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :conversation_id, index: true
      t.bigint :contact_id, index: true
      t.string :event_type, :occurrence_key, :provenance, null: false
      t.datetime :occurred_at, :redacted_at
      t.datetime :observed_at, null: false
      t.jsonb :evidence_message_ids, default: [], null: false
      t.jsonb :payload, default: {}, null: false
      t.timestamps
      t.index [:account_id, :occurrence_key], unique: true, name: 'idx_umi_event_occurrence'
      t.index [:account_id, :event_type, :occurred_at], name: 'idx_umi_event_type_time'
    end
    create_table :umi_conversion_deliveries do |t|
      t.references :conversation_event, null: false, foreign_key: { to_table: :umi_conversation_events, on_delete: :cascade }, index: false
      t.string :destination, null: false
      t.string :state, default: 'pending', null: false
      t.jsonb :payload, default: {}, null: false
      t.string :destination_key, :reason, :provider_reference, :last_error
      t.integer :attempt_count, default: 0, null: false
      t.datetime :attempted_at, :accepted_at, :confirmed_at
      t.timestamps
      t.index [:conversation_event_id, :destination], unique: true, name: 'idx_umi_event_destination'
      t.index [:destination, :state], name: 'idx_umi_delivery_state'
    end
    create_table :umi_shopify_order_financial_states do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :shop_domain, :shopify_order_id, null: false
      t.datetime :reconciliation_requested_at, null: false
      t.datetime :reconciled_at, :redacted_at
      t.string :last_error
      t.jsonb :snapshot, default: {}, null: false
      t.bigint :paid_event_id
      t.timestamps
      t.index [:account_id, :shop_domain, :shopify_order_id], unique: true, name: 'idx_umi_financial_order'
      t.index :paid_event_id, unique: true
    end
    add_foreign_key :umi_shopify_order_financial_states, :umi_conversation_events, column: :paid_event_id, on_delete: :nullify
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
