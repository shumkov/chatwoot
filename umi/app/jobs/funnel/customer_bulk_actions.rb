# frozen_string_literal: true

module Umi::Funnel::CustomerBulkActions
  def bulk_update
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@account.id)

    labels = @params[:labels] || {}
    added = Array(labels[:add])
    removed = Array(labels[:remove])
    if (added + removed).intersect?(Umi::Funnel::Configuration::PROTECTED_LABELS)
      raise ArgumentError, 'Customer, sales and source labels are managed automatically'
    end

    records.each do |conversation|
      conversation.with_lock do
        conversation.label_list = (conversation.label_list - removed) | added
        bulk_snoozed_until(conversation)
        conversation.assign_attributes(available_params(@params) || {})
        conversation.save!
      end
    end
  end
end
