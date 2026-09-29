# frozen_string_literal: true

module Umi::Funnel::CustomerCaptainResolution
  private

  def perform_time_based(inbox)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(inbox.account_id)

    Current.executed_by = inbox.captain_assistant
    resolvable_pending_conversations(inbox).each do |conversation|
      conversation.with_lock do
        next unless still_resolvable_after_evaluation?(conversation)

        create_resolution_message(conversation, inbox)
        conversation.resolved!
      end
    end
  end

  def resolve_conversation(conversation, inbox, reason)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(inbox.account_id)

    conversation.with_lock do
      next unless still_resolvable_after_evaluation?(conversation)

      super
    end
  end

  def handoff_conversation(conversation, inbox, reason)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(inbox.account_id)

    conversation.with_lock do
      next unless still_resolvable_after_evaluation?(conversation)

      super
    end
  end
end
