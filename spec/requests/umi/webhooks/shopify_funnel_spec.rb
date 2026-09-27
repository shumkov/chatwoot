# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Webhooks::ShopifyFunnel, type: :request do
  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:secret) { 'test-secret' }
  let(:payload) { { id: 123, shop_domain: hook.reference_id }.to_json }
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Shopify-Topic' => 'orders/paid', 'X-Shopify-Shop-Domain' => hook.reference_id,
      'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, payload)) }
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      example.run
    end
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
  end

  it 'persists and deduplicates signed paid notifications without fetching Shopify inline' do
    expect(Umi::Shopify::PaidOrderReport).not_to receive(:new)
    2.times { post '/webhooks/shopify', params: payload, headers: headers }
    expect(response).to have_http_status(:ok)
    expect(Umi::ShopifyOrderFinancialState.count).to eq(1)
  end

  it 'still runs order-create attribution before requesting financial reconciliation' do
    headers['X-Shopify-Topic'] = 'orders/create'
    service = instance_double(Umi::Shopify::OrderAttributionService, perform: :unlinked)
    expect(Umi::Shopify::OrderAttributionService).to receive(:new).and_return(service)
    post '/webhooks/shopify', params: payload, headers: headers
    expect(response).to have_http_status(:ok)
    expect(Umi::ShopifyOrderFinancialState.count).to eq(1)
  end

  it 'rejects invalid HMAC without persisting a pending payment' do
    headers['X-Shopify-Hmac-SHA256'] = 'invalid'
    post '/webhooks/shopify', params: payload, headers: headers
    expect(response).to have_http_status(:unauthorized)
    expect(Umi::ShopifyOrderFinancialState.count).to eq(0)
  end

  it 'acknowledges a durable payment notification despite a queue failure' do
    allow(Umi::Shopify::OrderFinancialReconcileJob).to receive(:perform_later).and_raise(StandardError)
    post '/webhooks/shopify', params: payload, headers: headers
    expect(response).to have_http_status(:ok)
    expect(Umi::ShopifyOrderFinancialState.pending.count).to eq(1)
  end
end
