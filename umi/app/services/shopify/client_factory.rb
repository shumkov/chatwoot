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
  API_VERSION = '2025-01'
  CONTEXT_SETUP_MUTEX = Mutex.new

  class << self
    def hook_for(account_id)
      Integrations::Hook.find_by(account_id: account_id, app_id: 'shopify')
    end

    def client_for(hook)
      ensure_shopify_context!
      ShopifyAPI::Clients::Rest::Admin.new(
        session: ShopifyAPI::Auth::Session.new(shop: hook.reference_id, access_token: hook.access_token)
      )
    end

    def ensure_shopify_context!
      CONTEXT_SETUP_MUTEX.synchronize do
        ShopifyAPI::Context.setup(
          api_key: GlobalConfigService.load('SHOPIFY_CLIENT_ID', nil),
          api_secret_key: GlobalConfigService.load('SHOPIFY_CLIENT_SECRET', nil),
          api_version: API_VERSION, scope: '', is_embedded: true, is_private: false
        )
      end
    end
  end
end
