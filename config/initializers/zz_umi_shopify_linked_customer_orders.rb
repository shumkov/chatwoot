# frozen_string_literal: true

# UMI patch: the orders sidebar prefers the contact's stored shopify_customer_id
# over re-deriving the customer from email/phone. Rationale in
# umi/app/controllers/shopify/prefer_linked_customer.rb.
#
# Order against the on-touch link prepend (zz_umi_shopify_contacts.rb) is not
# load-bearing — both arrangements behave identically. Ahead of it, a linked
# contact returns before the link code runs; behind it, the link code runs but
# stands down because linkable_contact? requires the id to be absent.

Rails.application.config.to_prepare do
  controller = 'Api::V1::Accounts::Integrations::ShopifyController'

  # Fail loud rather than silently reverting to email/phone-only matching: if
  # upstream renames or removes fetch_customers, this patch would no-op and every
  # linked contact would quietly go back to an empty sidebar. Reconcile on rebase.
  if !defined?(Api::V1::Accounts::Integrations::ShopifyController)
    Rails.logger.error("[umi-shopify-linked-orders] #{controller} is undefined — upstream moved or renamed it; " \
                       'the stored shopify_customer_id is not used.')
  elsif !Api::V1::Accounts::Integrations::ShopifyController.private_method_defined?(:fetch_customers)
    Rails.logger.error("[umi-shopify-linked-orders] #{controller}#fetch_customers is gone — upstream changed how it " \
                       'resolves the Shopify customer; the stored shopify_customer_id is not used.')
  elsif Api::V1::Accounts::Integrations::ShopifyController.ancestors.exclude?(Umi::Shopify::PreferLinkedCustomer)
    Api::V1::Accounts::Integrations::ShopifyController.prepend(Umi::Shopify::PreferLinkedCustomer)
  end
end
