# frozen_string_literal: true

class Umi::CustomerAcknowledgementJob < ApplicationJob
  queue_as :high

  def perform(message_id, generation, mode)
    settings = Umi::CustomerAcknowledgement.configuration
    return unless settings && settings.fetch('started_at') == generation

    message = Message.find_by(id: message_id)
    return unless message && settings.fetch('inbox_ids').include?(message.inbox_id)

    Umi::CustomerAcknowledgement.new(message, settings).perform(mode)
  end
end
