# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::OrderAttributionCanaryJob do
  let(:hook) { create(:integrations_hook, :shopify, reference_id: 'umi.myshopify.com') }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }
  let(:response) do
    Struct.new(:body, :next_page_info).new(
      { 'orders' => [{ 'id' => 1, 'note_attributes' => [{ 'name' => '_cw', 'value' => 'token' }] }] }, nil
    )
  end

  it 'touches the heartbeat only after observing a tagged recent order' do
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).with(hook).and_return(client)
    allow(client).to receive(:get).and_return(response)

    heartbeat = Rails.root.join('tmp/umi-order-link-canary-test')
    with_modified_env 'UMI_SHOPIFY_ORDER_LINK_CANARY_HEARTBEAT' => heartbeat.to_s do
      expect(described_class.perform_now).to eq(orders: 1, tagged: 1)
    end

    expect(heartbeat).to exist
    FileUtils.rm_f(heartbeat)
  end
end
