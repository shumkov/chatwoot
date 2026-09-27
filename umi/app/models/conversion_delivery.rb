# frozen_string_literal: true

class Umi::ConversionDelivery < ApplicationRecord
  self.table_name = 'umi_conversion_deliveries'
  belongs_to :conversation_event, class_name: 'Umi::ConversationEvent'
  validates :destination, inclusion: { in: %w[meta klaviyo] }
  validates :state, inclusion: { in: %w[pending excluded sending accepted confirmed rejected unknown] }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :reason, :last_error, :provider_reference, length: { maximum: 255 }
end
