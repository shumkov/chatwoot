# frozen_string_literal: true

module Umi::Funnel::CustomerIdentify
  private

  def update_contact
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@contact.account_id)

    @contact.with_lock { super }
  end
end
