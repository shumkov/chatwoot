# frozen_string_literal: true

module Umi::Funnel::CustomerWidgetContact
  def destroy_custom_attributes
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@contact.account_id)

    @contact.with_lock { super }
  end
end
