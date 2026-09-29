# frozen_string_literal: true

module Umi::Funnel::CustomerAutoResolution
  def perform(account:)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(account.id)

    conversation_scope(account).limit(Limits::BULK_ACTIONS_LIMIT).each do |conversation|
      conversation.with_lock do
        next unless conversation_scope(account).exists?(id: conversation.id)

        MessageTemplates::Template::AutoResolve.new(conversation: conversation).perform if account.auto_resolve_message.present?
        conversation.add_labels(account.auto_resolve_label) if account.auto_resolve_label.present?
        conversation.resolved!
      end
    end
  end
end
