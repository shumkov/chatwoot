# frozen_string_literal: true

module Umi::Funnel::CustomerSnoozeLifecycle
  def perform
    Conversation.where(status: :snoozed).where(snoozed_until: 3.days.ago..Time.current).find_each(batch_size: 100) do |conversation|
      unless Umi::Funnel::Configuration.customer_context_enabled?(conversation.account_id)
        conversation.open!
        next
      end

      conversation.with_lock do
        next unless conversation.snoozed? && conversation.snoozed_until&.between?(3.days.ago, Time.current)

        conversation.open!
      end
    end
  end
end
