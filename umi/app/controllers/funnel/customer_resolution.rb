# frozen_string_literal: true

module Umi::Funnel::CustomerResolution
  def toggle_status
    target = @conversation || conversation
    return super unless target && Umi::Funnel::Configuration.customer_context_enabled?(target.account_id)

    target.with_lock { super }
  end
end
