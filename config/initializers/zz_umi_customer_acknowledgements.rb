# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  raise 'UMI acknowledgements: native response classification changed' unless Message.private_method_defined?(:human_response?)

  Message.include(Umi::CustomerAcknowledgementMessage) unless Message.include?(Umi::CustomerAcknowledgementMessage)
  Conversation.include(Umi::CustomerAcknowledgementConversation) unless Conversation.include?(Umi::CustomerAcknowledgementConversation)
end
