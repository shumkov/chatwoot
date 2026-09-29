# frozen_string_literal: true

module Umi::Funnel::CustomerContacts
  def create
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(Current.account.id)

    validate_umi_contact_input!
    roles = params[:custom_attributes]&.slice(*Umi::Funnel::Configuration::ROLES.keys)&.to_unsafe_h || {}
    Contact.transaction do
      super
      Umi::Funnel::CustomerMutation.new(@contact, source: 'operator', actor: Current.user).perform(roles: roles)
    end
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end

  def update
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@contact.account_id)

    validate_umi_contact_input!
    @contact.with_lock do
      roles = params[:custom_attributes]&.slice(*Umi::Funnel::Configuration::ROLES.keys)&.to_unsafe_h || {}
      Umi::Funnel::CustomerMutation.new(@contact, source: 'operator', actor: Current.user).perform(roles: roles)
      super
    end
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end

  def destroy_custom_attributes
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@contact.account_id)

    keys = Array(params[:custom_attributes])
    raise ArgumentError, 'Customer payment history is managed automatically' if keys.intersect?(Umi::Funnel::Configuration::DERIVED_FIELDS)

    @contact.with_lock do
      roles = keys.intersection(Umi::Funnel::Configuration::ROLES.keys).index_with { 'unknown' }
      Umi::Funnel::CustomerMutation.new(@contact, source: 'operator', actor: Current.user).perform(roles: roles)
      @contact.update!(custom_attributes: @contact.custom_attributes.except(*(keys - roles.keys)))
    end
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end

  private

  def permitted_params
    values = super
    return values unless Umi::Funnel::Configuration.customer_context_enabled?(Current.account.id)
    return values unless values[:custom_attributes]

    values[:custom_attributes] = values[:custom_attributes].except(*Umi::Funnel::Configuration::ROLES.keys)
    values
  end

  def validate_umi_contact_input!
    custom = params[:custom_attributes].respond_to?(:keys) ? params[:custom_attributes].keys : []
    additional = params[:additional_attributes].respond_to?(:keys) ? params[:additional_attributes].keys : []
    owned = Umi::Funnel::Configuration::DERIVED_FIELDS + Umi::Funnel::Configuration::TECHNICAL_KEYS
    return unless custom.intersect?(owned) || additional.intersect?(Umi::Funnel::Configuration::TECHNICAL_KEYS)

    raise ArgumentError, 'Customer payment history and identity are managed automatically'
  end
end
