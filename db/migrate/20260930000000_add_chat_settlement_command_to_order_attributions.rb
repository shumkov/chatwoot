class AddChatSettlementCommandToOrderAttributions < ActiveRecord::Migration[7.1]
  def change
    add_column :umi_shopify_order_attributions, :settlement_command_message_id, :bigint
    add_index :umi_shopify_order_attributions, :settlement_command_message_id, name: 'index_umi_order_attributions_on_settlement_command'
  end
end
