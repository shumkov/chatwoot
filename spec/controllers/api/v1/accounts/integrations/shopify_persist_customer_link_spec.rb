# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi Shopify on-touch customer link', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, email: 'somchai@example.com', phone_number: '+66812345678') }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }

  before do
    create(:integrations_hook, :shopify, account: account)
    allow(ShopifyAPI::Clients::Rest::Admin).to receive(:new).and_return(client)
    allow(client).to receive(:get).with(hash_including(path: 'orders.json'))
                                  .and_return(instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'orders' => [] }))
  end

  def fetch_orders
    get "/api/v1/accounts/#{account.id}/integrations/shopify/orders",
        params: { contact_id: contact.id }, headers: agent.create_new_auth_token, as: :json
  end

  def stub_customer_search(customers)
    allow(client).to receive(:get).with(hash_including(path: 'customers/search.json'))
                                  .and_return(instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'customers' => customers }))
  end

  it 'persists the customer id on an exact email match (case-insensitive)' do
    stub_customer_search([{ 'id' => 42, 'email' => 'Somchai@Example.com', 'phone' => nil }])

    fetch_orders

    expect(response).to have_http_status(:ok)
    expect(contact.reload.additional_attributes['shopify_customer_id']).to eq(42)
  end

  # The sidebar's loose email-OR-phone search can return someone else first; a
  # durable link needs an exact match, unlike the transient render.
  it 'does not persist from a non-exact match' do
    stub_customer_search([{ 'id' => 43, 'email' => 'different@example.com', 'phone' => '+66999999999' }])

    fetch_orders

    expect(contact.reload.additional_attributes['shopify_customer_id']).to be_nil
  end

  it 'does not overwrite an existing link' do
    contact.update!(additional_attributes: { 'shopify_customer_id' => 41 })
    stub_customer_search([{ 'id' => 42, 'email' => 'somchai@example.com', 'phone' => nil }])

    fetch_orders

    expect(contact.reload.additional_attributes['shopify_customer_id']).to eq(41)
  end

  it 'never breaks the orders response when persistence fails' do
    stub_customer_search([{ 'id' => 42, 'email' => 'somchai@example.com', 'phone' => nil }])
    allow_any_instance_of(Contact).to receive(:update!).and_raise(StandardError, 'boom') # rubocop:disable RSpec/AnyInstance

    fetch_orders

    expect(response).to have_http_status(:ok)
  end
end
