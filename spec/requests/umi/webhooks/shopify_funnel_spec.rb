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

  it 'tombstones listed orders before any order read or customer sync can resurrect an erased payment' do
    pending = Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '1001')
    body = { shop_domain: hook.reference_id, customer: { id: 321 }, orders_to_redact: [1001, 1002] }.to_json
    signed = headers.merge('X-Shopify-Topic' => 'customers/redact',
                           'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)))
    expect(Umi::Shopify::PaidOrderReport).not_to receive(:new)
    post '/webhooks/shopify', params: body, headers: signed
    expect(response).to have_http_status(:ok)
    states = Umi::ShopifyOrderFinancialState.where(account_id: account.id).order(:shopify_order_id)
    expect(states.pluck(:shopify_order_id)).to eq(%w[1001 1002])
    expect(states.pluck(:snapshot)).to eq([{}, {}])
    expect(states.pluck(:redacted_at)).to all(be_present)
    Umi::Shopify::OrderFinancialStateService.new(pending).perform
    later = Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '1002')
    Umi::Shopify::OrderFinancialStateService.new(later).perform
    expect(Umi::ConversationEvent.where(event_type: 'order_paid')).to be_empty
  end

  it 'erases website-only customer financial evidence even when the contact is destroyed' do
    contact = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 321 })
    state = Umi::ShopifyOrderFinancialState.create!(account_id: account.id, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                                    snapshot: { shopify_customer_id: '321' }, reconciliation_requested_at: Time.current)
    body = { shop_domain: hook.reference_id, customer: { id: 321 }, orders_to_redact: [] }.to_json
    signed = headers.merge('X-Shopify-Topic' => 'customers/redact',
                           'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)))
    post '/webhooks/shopify', params: body, headers: signed
    expect(Contact.exists?(contact.id)).to be(false)
    expect(state.reload.redacted_at).to be_present
    expect(state.snapshot).to eq({})
  end

  it 'does not partially erase valid orders from a malformed order list' do
    body = { shop_domain: hook.reference_id, customer: { id: 321 }, orders_to_redact: [1001, 'bad'] }.to_json
    signed = headers.merge('X-Shopify-Topic' => 'customers/redact',
                           'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)))
    expect(ChatwootExceptionTracker).to receive(:new).with(an_instance_of(ArgumentError)).and_call_original
    post '/webhooks/shopify', params: body, headers: signed
    expect(response).to have_http_status(:ok)
    expect(Umi::ShopifyOrderFinancialState.count).to eq(0)
  end

  it 'scopes signed erasure order IDs to the resolved shop and account' do
    other = Umi::ShopifyOrderFinancialState.create!(account: create(:account), shop_domain: 'other.myshopify.com', shopify_order_id: '1001',
                                                    snapshot: { shopify_customer_id: '321' }, reconciliation_requested_at: Time.current)
    body = { shop_domain: hook.reference_id, customer: { id: 321 }, orders_to_redact: [1001] }.to_json
    signed = headers.merge('X-Shopify-Topic' => 'customers/redact',
                           'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)))
    post '/webhooks/shopify', params: body, headers: signed
    expect(other.reload.redacted_at).to be_nil
    expect(Umi::ShopifyOrderFinancialState.find_by!(account_id: account.id).redacted_at).to be_present
  end
end
