# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shopify conversation linking', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:reader) { instance_double(Umi::Shopify::CommerceReader) }
  let(:base) { "/api/v1/accounts/#{account.id}/umi/shopify/conversations/#{conversation.display_id}" }
  let(:object) do
    { 'kind' => 'order', 'id' => '123', 'name' => '#1001', 'updated_at' => '2026-09-28T01:00:00Z',
      'customer' => nil, 'amount' => '1000', 'currency' => 'THB', 'status' => 'PAID' }
  end

  before { allow(Umi::Shopify::CommerceReader).to receive(:new).and_return(reader) }

  it 'previews and links a customerless PromptPay order without sending a message' do
    allow(reader).to receive(:reference).with('https://umi.myshopify.com/admin/orders/123').and_return(%w[order 123])
    allow(reader).to receive(:fetch).with('order', '123').and_return(object)
    post "#{base}/preview", params: { reference: 'https://umi.myshopify.com/admin/orders/123' }, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
    expect do
      post "#{base}/links", params: { reference: 'https://umi.myshopify.com/admin/orders/123', updated_at: object['updated_at'] },
                            headers: user.create_new_auth_token, as: :json
    end.not_to change(Message, :count)
    expect(response).to have_http_status(:ok)
    expect(Umi::ShopifyOrderAttribution.sole.conversation_id).to eq(conversation.id)
  end

  it 'rejects a changed Shopify record before creating a link' do
    allow(reader).to receive(:reference).and_return(%w[order 123])
    allow(reader).to receive(:fetch).and_return(object)
    post "#{base}/links", params: { reference: 'https://umi.myshopify.com/admin/orders/123', updated_at: 'old' },
                          headers: user.create_new_auth_token, as: :json
    expect(response.parsed_body['error']).to eq('stale_preview')
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
  end

  it 'does not let an agent outside the inbox read the customer history' do
    outsider = create(:user, account: account, role: :agent)
    get base, headers: outsider.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body['error']).to eq('You are not authorized to do this action')
  end

  it 'keeps order linking available when draft access is missing and the contact has no email or phone' do
    conversation.contact.update!(email: nil, phone_number: nil)
    allow(reader).to receive(:draft_access?).and_return(false)
    allow(reader).to receive(:history).with(nil, kind: 'order', after: nil).and_return({ items: [], cursor: nil })
    get base, headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('draft_access' => false, 'linked' => [])
  end

  it 'keeps saved purchase links visible when Shopify is unavailable' do
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '123', source: 'operator',
                                         attribution_state: 'verified', contact_id: conversation.contact_id, conversation_id: conversation.id)
    conversation.contact.update!(additional_attributes: { 'shopify_customer_id' => '42' })
    allow(reader).to receive(:draft_access?).and_raise(Umi::Shopify::CommerceError, 'shopify_unavailable')
    get base, headers: user.create_new_auth_token
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['linked'].first['id']).to eq('123')
    expect(response.parsed_body['error']).to eq('shopify_unavailable')
  end
end
