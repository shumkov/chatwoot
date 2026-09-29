# frozen_string_literal: true

module Umi::Funnel::CustomerMessageLifecycle
  private

  def reopen_conversation
    return super unless incoming?

    return super unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    Conversation.find(conversation.id).with_lock do
      conversation.reload
      super
    end
  end

  def mark_pending_conversation_as_open_for_human_response
    return super if private?

    return super unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    Conversation.find(conversation.id).with_lock do
      conversation.reload
      super
    end
  end
end
