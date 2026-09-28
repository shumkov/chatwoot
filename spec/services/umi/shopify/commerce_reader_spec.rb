# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::CommerceReader do
  subject(:reader) { described_class.new(hook) }

  let(:hook) { create(:integrations_hook, :shopify, reference_id: 'umi.myshopify.com') }
  let(:client) { instance_double(ShopifyAPI::Clients::Graphql::Admin) }

  before { allow(Umi::Shopify::ClientFactory).to receive(:graphql_client_for).and_return(client) }

  it 'extracts typed IDs from Admin links without fetching the pasted URL' do
    expect(reader.reference('https://umi.myshopify.com/admin/orders/123')).to eq(%w[order 123])
    expect(reader.reference('https://admin.shopify.com/store/umi/draft_orders/456')).to eq(%w[draft 456])
    expect(reader.reference('https://admin.shopify.com/store/umi/customers/789')).to eq(%w[customer 789])
  end

  it 'rejects invoice links, display numbers and non-Shopify hosts' do
    ['#123', '123', 'https://umi.store/checkouts/abc', 'https://example.com/admin/orders/123',
     'http://umi.myshopify.com/admin/orders/123'].each do |url|
      expect { reader.reference(url) }.to raise_error(Umi::Shopify::CommerceError, 'invalid_reference')
    end
  end

  it 'does not display drafts returned for another customer even if Shopify ignores its search filter' do
    body = { 'data' => { 'draftOrders' => {
      'nodes' => [{ 'customer' => { 'id' => 'gid://shopify/Customer/99' } }], 'pageInfo' => { 'hasNextPage' => false }
    } } }
    allow(client).to receive(:query).and_return(instance_double(ShopifyAPI::Clients::HttpResponse, body: body))
    expect(reader.history('42', kind: 'draft')).to eq({ items: [], cursor: nil })
  end

  it 'surfaces access errors instead of showing a deleted record' do
    allow(client).to receive(:query).and_return(instance_double(ShopifyAPI::Clients::HttpResponse,
                                                                body: { 'errors' => [{ 'extensions' => { 'code' => 'ACCESS_DENIED' } }] }))
    expect { reader.fetch('draft', '10') }.to raise_error(Umi::Shopify::CommerceError, 'access_denied')
  end
end
