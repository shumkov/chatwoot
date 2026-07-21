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
end
