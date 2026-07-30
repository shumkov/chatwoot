# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ClientFactory do
  let(:hook) { instance_double(Integrations::Hook, reference_id: 'shop.myshopify.com', access_token: 'token') }

  before do
    allow(ShopifyAPI::Context).to receive(:setup)
    allow(ShopifyAPI::Auth::Session).to receive(:new).and_return(instance_double(ShopifyAPI::Auth::Session))
    allow(ShopifyAPI::Clients::Rest::Admin).to receive(:new).and_return(instance_double(ShopifyAPI::Clients::Rest::Admin))
  end

  describe '.client_for' do
    it 'configures the Shopify context before building the REST client' do
      expect(ShopifyAPI::Context).to receive(:setup)

      described_class.client_for(hook)
    end

    it 'builds the client from the hook shop and token' do
      described_class.client_for(hook)

      expect(ShopifyAPI::Auth::Session).to have_received(:new).with(shop: 'shop.myshopify.com', access_token: 'token')
    end
  end

  # ShopifyAPI::Context.setup reloads the gem's shared Zeitwerk loader on every
  # call, so two threads running it at once raced the loader and raised
  # Zeitwerk::SetupRequired. The factory owns the single mutex serializing setup
  # for every UMI Shopify service (relocated here from the help-center sync
  # service when the client construction moved into this factory).
  describe '.ensure_shopify_context!' do
    it 'never runs the global Context.setup concurrently' do
      lock = Mutex.new
      in_flight = 0
      max_in_flight = 0

      allow(ShopifyAPI::Context).to receive(:setup) do
        lock.synchronize do
          in_flight += 1
          max_in_flight = [max_in_flight, in_flight].max
        end
        sleep 0.01 # hold the "reload" open so an unguarded overlap is observable
        lock.synchronize { in_flight -= 1 }
      end

      Array.new(8) { Thread.new { described_class.ensure_shopify_context! } }.each(&:join)

      expect(max_in_flight).to eq(1)
    end
  end

  # Context.setup raises UnsupportedVersionError for a version the installed gem does
  # not list, which would take down every Shopify call in the process at boot. This
  # pins that contract across gem upgrades and downgrades.
  #
  # It deliberately does NOT prove the version is still supported by *Shopify*: the gem
  # lists versions long past their 12-month support window, and Shopify answers an
  # expired request by silently serving the oldest version it still supports. Only the
  # `x-shopify-api-version` response header can catch that, which is why the drift check
  # belongs in the reconcile task rather than here.
  describe 'API_VERSION' do
    it 'is a version the installed shopify_api gem supports' do
      expect(ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS).to include(described_class::API_VERSION)
    end

    it 'is a dated version rather than "unstable"' do
      expect(described_class::API_VERSION).to match(/\A\d{4}-\d{2}\z/)
    end
  end
end
