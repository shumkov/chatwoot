# frozen_string_literal: true

class AddUmiDeliveryReadbackAttempts < ActiveRecord::Migration[7.1]
  def change
    add_column :umi_conversion_deliveries, :readback_attempt_count, :integer, null: false, default: 0
  end
end
