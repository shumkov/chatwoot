# frozen_string_literal: true

class Umi::CustomerAcknowledgementJob < ApplicationJob
  queue_as :high

  def perform(message_id, generation, mode)
    settings = Umi::CustomerAcknowledgement.configuration
    return unless settings

    message = Message.find_by(id: message_id)
    return unless message && settings.fetch('inbox_ids').include?(message.inbox_id)
    return unless Umi::CustomerAcknowledgement.generation_for(settings, message.inbox_id) == generation

    Umi::CustomerAcknowledgement.new(message, settings).perform(mode)
  end
end
