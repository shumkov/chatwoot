# frozen_string_literal: true

class Umi::Funnel::ClassificationJob < ApplicationJob
  queue_as :low
  discard_on(StandardError) { |job, error| Rails.logger.error("[umi-funnel] classification job #{job.arguments.first}: #{error.class}") }

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    Umi::Funnel::ConversationClassifier.new(conversation).perform if conversation
  end
end
