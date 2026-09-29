# frozen_string_literal: true

class Umi::Funnel::SettlementCommandJob < ApplicationJob
  queue_as :low

  def perform(message_id)
    message = Message.find_by(id: message_id)
    Umi::Funnel::SettlementCommand.new(message).perform if message
  end
end
