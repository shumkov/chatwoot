# frozen_string_literal: true

module Umi::Funnel::CustomerWidgetLabels
  def create
    return super unless conversation && Umi::Funnel::Configuration.customer_context_enabled?(conversation.account_id)

    conversation.add_labels([permitted_params[:label]]) if label_defined_in_account?
    head :no_content
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end

  def destroy
    return super unless conversation && Umi::Funnel::Configuration.customer_context_enabled?(conversation.account_id)

    conversation.remove_umi_labels!([permitted_params[:id]])
    head :no_content
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end
end
