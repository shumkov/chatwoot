# frozen_string_literal: true

Rails.application.reloader.to_prepare do # rubocop:disable Metrics/BlockLength
  raise 'UMI customer context: contact update entry point changed' unless Api::V1::Accounts::ContactsController.method_defined?(:update)
  raise 'UMI customer context: label entry point changed' unless Conversation.method_defined?(:update_labels)

  [Api::V1::Widget::MessagesController, Public::Api::V1::Inboxes::MessagesController].each do |controller|
    raise 'UMI customer context: customer message lookup changed' unless controller.private_method_defined?(:set_message)
  end

  Contact.include(Umi::Funnel::CustomerContact) unless Contact.include?(Umi::Funnel::CustomerContact)
  Conversation.prepend(Umi::Funnel::CustomerConversation) unless Conversation.include?(Umi::Funnel::CustomerConversation)
  [Api::V1::Widget::BaseController, Public::Api::V1::InboxesController].each do |controller|
    controller.include(Umi::Funnel::CustomerBoundary) unless controller.include?(Umi::Funnel::CustomerBoundary)
  end
  {
    Api::V1::Accounts::ContactsController => Umi::Funnel::CustomerContacts,
    Api::V1::Widget::MessagesController => Umi::Funnel::CustomerWidgetMessages,
    Public::Api::V1::Inboxes::MessagesController => Umi::Funnel::CustomerPublicMessages,
    ActionCableListener => Umi::Funnel::CustomerBroadcast,
    Message => Umi::Funnel::CustomerMessageLifecycle,
    Api::V1::Accounts::ConversationsController => Umi::Funnel::CustomerResolution,
    Api::V1::Widget::ConversationsController => Umi::Funnel::CustomerResolution,
    Public::Api::V1::Inboxes::ConversationsController => Umi::Funnel::CustomerResolution,
    Conversations::ReopenSnoozedConversationsJob => Umi::Funnel::CustomerSnoozeLifecycle,
    Conversations::ResolutionJob => Umi::Funnel::CustomerAutoResolution,
    ContactIdentifyAction => Umi::Funnel::CustomerIdentify,
    Api::V1::Widget::ContactsController => Umi::Funnel::CustomerWidgetContact,
    ContactMergeAction => Umi::Funnel::CustomerMerge,
    ActionService => Umi::Funnel::CustomerLabelActions,
    BulkActionsJob => Umi::Funnel::CustomerBulkActions,
    Api::V1::Accounts::BulkActionsController => Umi::Funnel::CustomerBulkBoundary,
    Api::V1::Widget::LabelsController => Umi::Funnel::CustomerWidgetLabels,
    Api::V1::Accounts::LabelsController => Umi::Funnel::CustomerDefinitions,
    Api::V1::Accounts::CustomAttributeDefinitionsController => Umi::Funnel::CustomerDefinitions,
    Api::V1::Accounts::Conversations::LabelsController => Umi::Funnel::CustomerLabelErrors
  }.each { |target, extension| target.prepend(extension) unless target.include?(extension) }
  raise 'UMI customer context: tag cache callback changed' unless Conversation.method_defined?(:save_cached_tag_list) ||
                                                                  Conversation.private_method_defined?(:save_cached_tag_list)

  if defined?(Captain::InboxPendingConversationsResolutionJob)
    target = Captain::InboxPendingConversationsResolutionJob
    target.prepend(Umi::Funnel::CustomerCaptainResolution) unless target.include?(Umi::Funnel::CustomerCaptainResolution)
  end
end
