# frozen_string_literal: true

module Umi::Funnel::CustomerBulkBoundary
  def create
    if params[:type].to_s.camelize == 'Conversation' && Umi::Funnel::Configuration.customer_context_enabled?(Current.account.id)
      labels = params[:labels] || {}
      if (Array(labels[:add]) + Array(labels[:remove])).intersect?(Umi::Funnel::Configuration::PROTECTED_LABELS)
        return render_could_not_create_error('Customer, sales and source labels are managed automatically')
      end
    end
    super
  end
end
