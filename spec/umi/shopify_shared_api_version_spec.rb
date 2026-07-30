# frozen_string_literal: true

require 'rails_helper'

# ShopifyAPI::Context is process-global, so every caller that runs Context.setup
# decides the Admin API version for the whole process until the next one runs.
# Upstream's orders-sidebar controller pinned its own version literal, which meant
# a Puma process flip-flopped between it and the version the UMI jobs pin.
RSpec.describe Umi::ShopifySharedApiVersion do
  let(:controller) { Api::V1::Accounts::Integrations::ShopifyController.new }

  it 'prepends the shared-version module onto the core controller' do
    expect(Api::V1::Accounts::Integrations::ShopifyController.ancestors).to include(described_class)
  end

  it 'configures the context with the shared version constant' do
    allow(controller).to receive_messages(client_id: 'id', client_secret: 'secret')
    allow(ShopifyAPI::Context).to receive(:setup)

    controller.send(:setup_shopify_context)

    expect(ShopifyAPI::Context).to have_received(:setup)
      .with(hash_including(api_version: Umi::Shopify::ClientFactory::API_VERSION))
  end

  # The override must not re-derive credentials or scope: they resolve to the same
  # values today, but sourcing them here would diverge the moment either side changes
  # how it looks them up — and the controller's own values are what upstream tests stub.
  it 'passes through the controller’s own credentials and scopes' do
    allow(controller).to receive_messages(client_id: 'id', client_secret: 'secret')
    allow(ShopifyAPI::Context).to receive(:setup)

    controller.send(:setup_shopify_context)

    expect(ShopifyAPI::Context).to have_received(:setup).with(
      hash_including(api_key: 'id', api_secret_key: 'secret', scope: Shopify::IntegrationHelper::REQUIRED_SCOPES.join(','))
    )
  end

  it 'serialises the setup through the factory lock' do
    allow(controller).to receive_messages(client_id: 'id', client_secret: 'secret')
    allow(ShopifyAPI::Context).to receive(:setup)
    allow(Umi::Shopify::ClientFactory).to receive(:synchronize_context_setup).and_yield

    controller.send(:setup_shopify_context)

    expect(Umi::Shopify::ClientFactory).to have_received(:synchronize_context_setup)
  end

  # Upstream returned early when the integration is unconfigured rather than calling
  # Context.setup with nil credentials; the override has to keep doing that.
  it 'stays inert when the Shopify credentials are not configured' do
    allow(controller).to receive_messages(client_id: nil, client_secret: nil)
    allow(ShopifyAPI::Context).to receive(:setup)

    controller.send(:setup_shopify_context)

    expect(ShopifyAPI::Context).not_to have_received(:setup)
  end

  # The guard in the initializer is what keeps an upstream rename from silently
  # restoring the split-brain, so the method it hooks has to still be there.
  it 'hooks a private method upstream still defines' do
    expect(Api::V1::Accounts::Integrations::ShopifyController.private_method_defined?(:setup_shopify_context)).to be(true)
  end
end
