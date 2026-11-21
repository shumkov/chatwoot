# frozen_string_literal: true

# UMI patch: one Shopify customer is carried by at most one contact.
# Design and lock-order proof: docs/UMI-SHOPIFY-SINGLE-BINDING-SPEC.md.
#
# The UMI binders (ManualLinkService, PersistCustomerLink, ContactSyncService)
# call Umi::Shopify::CustomerBinding directly. This wires the two upstream
# contact writers that merge caller-supplied additional_attributes: the agent
# contacts API is guarded, and the widget contact endpoint drops sync-owned
# Shopify keys from visitor input. Fail loud if upstream moves either entry
# point, since the guard would otherwise vanish silently.
Rails.application.config.to_prepare do
  # Checked on the classes' own methods: other UMI prepends define create,
  # update and permitted_params too and would hide an upstream removal.
  contacts = Api::V1::Accounts::ContactsController
  unless (%i[create update] - contacts.public_instance_methods(false)).empty?
    raise 'UMI single Shopify binding: contacts API create/update entry point changed'
  end

  contacts.prepend(Umi::Shopify::ContactBindingGuard) unless contacts.include?(Umi::Shopify::ContactBindingGuard)

  widget = Api::V1::Widget::ContactsController
  raise 'UMI single Shopify binding: widget contact params changed' unless widget.private_instance_methods(false).include?(:permitted_params)

  widget.prepend(Umi::Shopify::WidgetContactKeys) unless widget.include?(Umi::Shopify::WidgetContactKeys)
end
