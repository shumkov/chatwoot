require 'rails_helper'

RSpec.describe 'Staff draft and payment preparation', type: :request do
  let(:account) { create(:account) }
  let(:bridge) { create(:user, account: account, role: :administrator) }
  let(:staff) { create(:user, account: account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:source) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: staff, private: true, message_type: :outgoing,
                     content: '/draft-order 123:2 market=TH')
  end
  let(:path) { "/api/v1/accounts/#{account.id}/umi/shopify/conversations/#{conversation.display_id}/draft_commands" }
  let(:headers) { bridge.create_new_auth_token }
  let(:marker) { "umi-cw-a#{account.id}-c#{conversation.display_id}-m#{source.id}" }
  let(:draft) do
    { 'id' => 'gid://shopify/DraftOrder/99', 'name' => '#D99', 'updatedAt' => Time.current.iso8601, 'status' => 'OPEN', 'order' => nil,
      'customer' => nil, 'tags' => [marker], 'customAttributes' => [{ 'key' => 'umi_chatwoot_source', 'value' => marker },
                                                                    { 'key' => 'umi_market', 'value' => 'TH' }],
      'totalPriceSet' => { 'presentmentMoney' => { 'amount' => '2000.00', 'currencyCode' => 'THB' } },
      'lineItems' => { 'nodes' => [{ 'quantity' => 2, 'variant' => { 'id' => 'gid://shopify/ProductVariant/123' } }],
                       'pageInfo' => { 'hasNextPage' => false } } }
  end
  let(:client) { instance_double(ShopifyAPI::Clients::Graphql::Admin) }
  let(:payload) { { source_message_id: source.id, contact_id: conversation.contact_id, draft_order_id: draft['id'] } }

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(SendReplyJob).to receive(:perform_later)
    allow(Umi::Shopify::DraftLinkReconcileJob).to receive(:perform_later)
    allow(Umi::Shopify::ClientFactory).to receive(:graphql_client_for).and_return(client)
    allow(client).to receive(:query).and_return(instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'data' => { 'draftOrder' => draft } }))
    ENV['UMI_COMMERCE_BRIDGE_USER_ID'] = bridge.id.to_s
    ENV['UMI_COMMERCE_ACCOUNT_ID'] = account.id.to_s
    ENV['UMI_COMMERCE_META_INBOX_ID'] = inbox.id.to_s
  end

  around do |example|
    with_modified_env UMI_COMMERCE_BRIDGE_USER_ID: nil, UMI_COMMERCE_ACCOUNT_ID: nil, UMI_COMMERCE_META_INBOX_ID: nil do
      example.run
    end
  end

  it 'links the exact unpaid source basket once and records the real staff requester rather than the API principal' do
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response.parsed_body).to include('status' => 'ready', 'contact_id' => conversation.contact_id, 'customer_id' => nil)
    2.times { post path, params: payload, headers: headers, as: :json }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include('status' => 'linked', 'draft_order_id' => draft['id'])
    expect(Umi::ShopifyDraftLink.where(shopify_draft_id: '99').sole).to have_attributes(linked_by_id: staff.id, status: 'pending')
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
    expect(client).to have_received(:query).with(hash_including(query: a_string_starting_with('query'))).twice
  end

  it 'refuses changed contact, basket, customer, marker, completed draft and preview-only sources' do
    post path, params: payload.merge(contact_id: 0), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    changes = [{ 'tags' => [] }, { 'customer' => { 'id' => 'gid://shopify/Customer/42' } }, { 'status' => 'COMPLETED' },
               { 'lineItems' => { 'nodes' => [], 'pageInfo' => { 'hasNextPage' => false } } }]
    changes.each do |change|
      allow(client).to receive(:query).and_return(instance_double(ShopifyAPI::Clients::HttpResponse,
                                                                  body: { 'data' => { 'draftOrder' => draft.merge(change) } }))
      post path, params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity), response.body
    end
    source.update!(content: '/draft-order preview 123:2 market=TH')
    post path, params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Umi::ShopifyDraftLink.count).to eq(0)
  end

  it 'provides QR binding only for a purchase already linked to this exact conversation and customer' do
    source.update!(content: '/payment-qr draft:99')
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    link = Umi::ShopifyDraftLink.create!(account: account, shop_domain: hook.reference_id, shopify_draft_id: '99',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id, status: 'pending')
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response.parsed_body['linked_purchase']).to eq('kind' => 'draft', 'id' => '99', 'customer_id' => nil)
    link.update!(status: 'resolved')
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(client).not_to have_received(:query)
  end

  it 'binds order QR preparation to the verified order owner and current Shopify customer' do
    source.update!(content: '/payment-qr order:99')
    conversation.contact.update!(additional_attributes: { 'shopify_customer_id' => '42' })
    link = Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '99',
                                                source: 'operator', attribution_state: 'verified', conversation_id: conversation.id,
                                                contact_id: conversation.contact_id, shopify_customer_id: '42')
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response.parsed_body['linked_purchase']).to eq('kind' => 'order', 'id' => '99', 'customer_id' => 'gid://shopify/Customer/42')
    [{ shopify_customer_id: '43' }, { conversation_id: nil }, { contact_id: nil }, { redacted_at: Time.current },
     { attribution_state: 'unverified' }].each do |change|
      link.update!(change)
      get path, params: { source_message_id: source.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity), response.body
      link.update!(shopify_customer_id: '42', conversation_id: conversation.id, contact_id: conversation.contact_id,
                   redacted_at: nil, attribution_state: 'verified')
    end
    expect(client).not_to have_received(:query)
  end

  it 'accepts draft and QR commands from the operator whose token the bridge uses' do
    source.update!(sender: bridge)
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response).to have_http_status(:ok)
    source.update!(content: '/payment-qr draft:99')
    Umi::ShopifyDraftLink.create!(account: account, shop_domain: hook.reference_id, shopify_draft_id: '99',
                                  conversation_id: conversation.id, contact_id: conversation.contact_id, status: 'pending')
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response).to have_http_status(:ok)
    source.update!(content_attributes: { shumabit_bridge: true })
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects public, generated, deleted, removed staff and unconfigured service identities' do
    [{ private: false }, { content_attributes: { shumabit_bridge: true } },
     { content_attributes: { deleted: true } }].each do |change|
      source.update!(change)
      get path, params: { source_message_id: source.id }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      source.update!(sender: staff, private: true, content_attributes: {})
    end
    get path, params: { source_message_id: source.id }, headers: create(:user, account: account, role: :administrator).create_new_auth_token
    expect(response).to have_http_status(:forbidden)
    account.account_users.find_by!(user_id: staff.id).destroy!
    get path, params: { source_message_id: source.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
