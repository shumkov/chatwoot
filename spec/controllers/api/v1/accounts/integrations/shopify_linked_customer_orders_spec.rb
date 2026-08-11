# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi Shopify orders for a linked contact', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, email: 'somchai@example.com', phone_number: '+66812345678') }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }

  before do
    create(:integrations_hook, :shopify, account: account)
    allow(ShopifyAPI::Clients::Rest::Admin).to receive(:new).and_return(client)

    # The email/phone search deliberately answers with a *different* customer
    # than the stored link, and each customer has its own order, so the rendered
    # order names which path resolved the customer. A patch that never reads the
    # stored id renders the searched customer's order and the examples fail.
    allow(client).to receive(:get).with(hash_including(path: 'customers/search.json')).and_return(
      instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'customers' => [{ 'id' => 999, 'email' => contact.email, 'phone' => nil }] })
    )
    allow(client).to receive(:get).with(hash_including(path: 'orders.json', query: hash_including(customer_id: 777))).and_return(
      instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'orders' => [{ 'id' => 'order-of-linked-customer' }] })
    )
    allow(client).to receive(:get).with(hash_including(path: 'orders.json', query: hash_including(customer_id: 999))).and_return(
      instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'orders' => [{ 'id' => 'order-of-searched-customer' }] })
    )
  end

  def fetch_orders
    get "/api/v1/accounts/#{account.id}/integrations/shopify/orders",
        params: { contact_id: contact.id }, headers: agent.create_new_auth_token, as: :json
  end

  # The sync and the on-touch link store the id Shopify itself gave us; it is a
  # stronger identity than re-deriving the customer from the contact's current
  # email/phone, which the agent can edit and which Shopify may hold in another shape.
  it 'renders the linked customer’s orders' do
    contact.update!(additional_attributes: { 'shopify_customer_id' => 777 })

    fetch_orders

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['orders'].pluck('id')).to eq(['order-of-linked-customer'])
  end

  it 'skips the customer search entirely when the contact is linked' do
    contact.update!(additional_attributes: { 'shopify_customer_id' => 777 })

    fetch_orders

    expect(client).not_to have_received(:get).with(hash_including(path: 'customers/search.json'))
  end

  it 'falls back to the email/phone search when no customer is linked' do
    fetch_orders

    expect(response.parsed_body['orders'].pluck('id')).to eq(['order-of-searched-customer'])
  end

  # additional_attributes is jsonb: the key can exist while holding nothing, and
  # an empty string would otherwise be sent to Shopify as customer_id=.
  it 'falls back to the search when the stored link is blank' do
    contact.update!(additional_attributes: { 'shopify_customer_id' => '' })

    fetch_orders

    expect(response.parsed_body['orders'].pluck('id')).to eq(['order-of-searched-customer'])
  end

  it 'prepends the override onto the core controller' do
    expect(Api::V1::Accounts::Integrations::ShopifyController.ancestors).to include(Umi::Shopify::PreferLinkedCustomer)
  end

  # The initializer's guard only means something while upstream still defines the
  # method the override replaces.
  it 'hooks a private method upstream still defines' do
    expect(Api::V1::Accounts::Integrations::ShopifyController.private_method_defined?(:fetch_customers)).to be(true)
  end
end
