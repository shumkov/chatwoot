# frozen_string_literal: true

module Umi::Funnel::CustomerDefinitions
  def update
    if umi_owned_definition? && umi_definition_shape_changed?
      return render_could_not_create_error('Managed customer definitions cannot be changed here')
    end

    super
  end

  def destroy
    return render_could_not_create_error('Managed customer definitions cannot be deleted here') if umi_owned_definition?

    super
  end

  private

  def umi_definition_shape_changed?
    if @label
      params.dig(:label, :title).present? && params.dig(:label, :title) != @label.title
    else
      shape = params.require(:custom_attribute_definition).permit(:attribute_display_name, :attribute_key, :attribute_model,
                                                                  :attribute_display_type, attribute_values: [])
      shape.to_h.any? { |key, value| @custom_attribute_definition.public_send(key) != value }
    end
  end

  def umi_owned_definition?
    return false unless Umi::Funnel::Configuration.customer_context_enabled?(Current.account.id)

    if @label
      Umi::Funnel::Configuration::PROTECTED_LABELS.include?(@label.title) ||
        Umi::Funnel::Configuration::PROTECTED_LABELS.include?(params.dig(:label, :title))
    else
      keys = Umi::Funnel::Configuration::CONTACT_FIELDS + ['umi_sales_status']
      keys.include?(@custom_attribute_definition.attribute_key) || keys.include?(params.dig(:custom_attribute_definition, :attribute_key))
    end
  end
end
