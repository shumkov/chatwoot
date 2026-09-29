# frozen_string_literal: true

module Umi::Funnel::CustomerLabelActions
  def remove_label(labels)
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@conversation.account_id)

    @conversation.remove_umi_labels!(labels)
  end
end
