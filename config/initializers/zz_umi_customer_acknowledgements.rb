# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  raise 'UMI acknowledgements: native response classification changed' unless Message.private_method_defined?(:human_response?)
  unless Messages::SendEmailNotificationService.instance_methods(false).include?(:perform)
    raise 'UMI acknowledgements: native email notification service changed'
  end

  Message.include(Umi::CustomerAcknowledgementMessage) unless Message.include?(Umi::CustomerAcknowledgementMessage)
  Conversation.include(Umi::CustomerAcknowledgementConversation) unless Conversation.include?(Umi::CustomerAcknowledgementConversation)
  unless Messages::SendEmailNotificationService <= Umi::CustomerAcknowledgementEmailNotification
    Messages::SendEmailNotificationService.prepend(Umi::CustomerAcknowledgementEmailNotification)
  end
end
