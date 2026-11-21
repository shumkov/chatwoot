# frozen_string_literal: true

# UMI patch: the agent contacts API merges caller-supplied additional_attributes,
# so a request can bind a Shopify customer like any other binder. A request that
# sets a non-blank shopify_customer_id the contact does not carry yet is refused
# with 422 customer_bound_elsewhere while another contact carries that customer
# (Umi::Shopify::CustomerBinding). Every other request, including edits of
# contacts that already share a customer, takes the untouched upstream path.
#
# The guarded path runs the rest of the action inside this transaction, so
# nothing it wrote may outlive an error response: the refusal is raised (it
# also rolls back writes made before it by any wrapper outside this module),
# and an error rendered further in — Umi::Funnel::CustomerContacts rescues its
# own validation errors after the core write — rolls the transaction back.
module Umi::Shopify::ContactBindingGuard
  def self.prepended(base)
    base.rescue_from Umi::Shopify::CommerceError, with: :render_customer_binding_error
  end

  def create
    customer_id = requested_shopify_customer_id
    return super if customer_id.nil?

    Contact.transaction(requires_new: true) do
      Umi::Shopify::CustomerBinding.lock!(Current.account.id, [customer_id])
      bound = Umi::Shopify::CustomerBinding.bound_customer_ids(Current.account.id, [customer_id])
      raise Umi::Shopify::CommerceError, 'customer_bound_elsewhere' if bound.any?

      super
      raise ActiveRecord::Rollback if error_rendered?
    end
  end

  def update
    customer_id = requested_shopify_customer_id
    return super if customer_id.nil?

    Contact.transaction(requires_new: true) do
      # Contact row lock before the customer lock; a refresh of the customer
      # the contact already carries needs no customer lock.
      @contact.lock!
      if @contact.additional_attributes['shopify_customer_id'].to_s != customer_id &&
         Umi::Shopify::CustomerBinding.bound_elsewhere?(@contact, customer_id)
        raise Umi::Shopify::CommerceError, 'customer_bound_elsewhere'
      end

      super
      raise ActiveRecord::Rollback if error_rendered?
    end
  end

  private

  def requested_shopify_customer_id
    attributes = params[:additional_attributes]
    return unless attributes.respond_to?(:key?)

    attributes[:shopify_customer_id].to_s.presence
  end

  def error_rendered?
    performed? && !response.successful?
  end

  def render_customer_binding_error(error)
    render_could_not_create_error(error.message)
  end
end
