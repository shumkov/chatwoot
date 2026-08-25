# frozen_string_literal: true

# UMI patch: shared construction of Shopify REST Admin clients from an account's
# Shopify Integrations::Hook, used by the help-center sync and the customer →
# contact sync.
#
# Owns the single process-wide Context.setup mutex. ShopifyAPI::Context.setup
# reloads the shopify_api gem's shared Zeitwerk loader on every call, so two
# Sidekiq threads running it concurrently race the loader mid-reload and raise
# Zeitwerk::SetupRequired. Every UMI service must build its client through this
# factory: a second service holding its own mutex would let two setups overlap
# again. (Context.setup? raises until the first setup, so it cannot be used as a
# guard; re-running setup is what core ShopifyController does per request.)
module Umi::Shopify::ClientFactory
  # The single Shopify Admin API version for the whole app — the core orders-sidebar
  # controller reads it too, via config/initializers/zz_umi_shopify_api_version.rb.
  # ShopifyAPI::Context is process-global, so two callers pinning different versions
  # would leave whichever ran last in effect for every request in that process.
  #
  # Shopify supports a version for 12 months and serves the *oldest supported* version
  # to callers asking for an expired one — silently, and a quarter later it moves again.
  # Pin a supported version and let `rake umi:help_center:verify` compare this constant
  # against the `x-shopify-api-version` response header, so drift alarms instead of
  # changing behaviour unannounced. 2026-01 is supported until 2027-01-16.
  API_VERSION = '2026-01'
  CONTEXT_SETUP_MUTEX = Mutex.new

  class << self
    def hook_for(account_id)
      Integrations::Hook.find_by(account_id: account_id, app_id: 'shopify')
    end

    def client_for(hook)
      ensure_shopify_context!
      ShopifyAPI::Clients::Rest::Admin.new(session: session_for(hook))
    end

    # Translations have no REST surface — `translationsRegister` and
    # `translationsRemove` are GraphQL-only — so the help-center translation sync
    # needs this alongside the REST client the article sync uses.
    def graphql_client_for(hook)
      ensure_shopify_context!
      ShopifyAPI::Clients::Graphql::Admin.new(session: session_for(hook))
    end

    def session_for(hook)
      ShopifyAPI::Auth::Session.new(shop: hook.reference_id, access_token: hook.access_token)
    end

    def ensure_shopify_context!
      synchronize_context_setup do
        ShopifyAPI::Context.setup(
          api_key: GlobalConfigService.load('SHOPIFY_CLIENT_ID', nil),
          api_secret_key: GlobalConfigService.load('SHOPIFY_CLIENT_SECRET', nil),
          api_version: API_VERSION, scope: '', is_embedded: true, is_private: false
        )
      end
    end

    # Context.setup is process-global and reloads the gem's shared Zeitwerk loader, so
    # every caller in the process has to take the same lock — including ones outside
    # this factory that build their own setup call.
    def synchronize_context_setup(&)
      CONTEXT_SETUP_MUTEX.synchronize(&)
    end
  end
end
