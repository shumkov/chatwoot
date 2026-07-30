# frozen_string_literal: true

# UMI patch: make the core Shopify orders-sidebar controller share the fork's single
# Admin API version instead of its own hardcoded one.
#
# ShopifyAPI::Context is process-global singleton state. Upstream's controller calls
# Context.setup on every `orders` request with its own literal version, while the UMI
# jobs call it through Umi::Shopify::ClientFactory — so in a Puma process the two
# stomp each other and whichever ran last decides the version for everything. Pinning
# in one place is the only way the pin means anything.
#
# Taking the factory's lock also closes a second hole: Context.setup reloads the
# shopify_api gem's shared Zeitwerk loader, so concurrent setups race it. Every UMI
# caller goes through that mutex; this controller was the one that did not.
#
# Everything except the version and the lock is upstream's, deliberately: the override
# keeps calling the controller's own client_id/client_secret and REQUIRED_SCOPES rather
# than sourcing credentials itself. They resolve to the same values in production, but
# re-deriving them here would silently diverge the moment either side changes how it
# looks them up.
module Umi::ShopifySharedApiVersion
  private

  def setup_shopify_context
    return if client_id.blank? || client_secret.blank?

    Umi::Shopify::ClientFactory.synchronize_context_setup do
      ShopifyAPI::Context.setup(
        api_key: client_id,
        api_secret_key: client_secret,
        api_version: Umi::Shopify::ClientFactory::API_VERSION,
        # Qualified, not the bare constant: inside this module `REQUIRED_SCOPES` would
        # resolve lexically here rather than against the helper the controller includes.
        # This is also the constant zz_umi_shopify_help_center.rb expands, so the
        # content/redirect scopes stay part of it.
        scope: Shopify::IntegrationHelper::REQUIRED_SCOPES.join(','),
        is_embedded: true,
        is_private: false
      )
    end
  end
end

Rails.application.config.to_prepare do
  controller = 'Api::V1::Accounts::Integrations::ShopifyController'

  # Fail loud rather than silently leaving the controller on its own version: if
  # upstream renames or removes setup_shopify_context, this patch would no-op and the
  # split-brain would come back invisibly. Reconcile on rebase.
  if !defined?(Api::V1::Accounts::Integrations::ShopifyController)
    Rails.logger.error("[umi-shopify-api-version] #{controller} is undefined — upstream moved or renamed it; " \
                       'the shared API version pin is not applied.')
  elsif !Api::V1::Accounts::Integrations::ShopifyController.private_method_defined?(:setup_shopify_context)
    Rails.logger.error("[umi-shopify-api-version] #{controller}#setup_shopify_context is gone — upstream changed how " \
                       'it configures ShopifyAPI::Context; the shared API version pin is not applied.')
  elsif Api::V1::Accounts::Integrations::ShopifyController.ancestors.exclude?(Umi::ShopifySharedApiVersion)
    Api::V1::Accounts::Integrations::ShopifyController.prepend(Umi::ShopifySharedApiVersion)
  end
end
