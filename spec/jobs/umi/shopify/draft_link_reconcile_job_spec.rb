# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::DraftLinkReconcileJob do
  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:conversation) { create(:conversation, account: account) }
  let(:reader) { instance_double(Umi::Shopify::CommerceReader) }
  let!(:link) do
    Umi::ShopifyDraftLink.create!(account: account, shop_domain: hook.reference_id, shopify_draft_id: '10',
                                  contact_id: conversation.contact_id, conversation_id: conversation.id, shopify_customer_id: '42')
  end
  let(:order) do
    { 'kind' => 'order', 'id' => '20', 'customer' => { 'id' => '42' }, 'name' => '#1001', 'amount' => '1000', 'currency' => 'THB' }
  end

  before do
    allow(Umi::Shopify::CommerceReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:fetch).with('draft', '10').and_return({ 'order_id' => '20', 'customer' => { 'id' => '42' } })
    allow(reader).to receive(:fetch).with('order', '20').and_return(order)
  end

  it 'follows a completed draft without treating its resulting unpaid order as a paid conversion' do
    described_class.perform_now(link.id)
    described_class.perform_now(link.id)
    expect(link.reload).to have_attributes(status: 'resolved', shopify_order_id: '20')
    expect(Umi::ShopifyOrderAttribution.sole).to have_attributes(shopify_order_id: '20', conversation_id: conversation.id)
    expect(Umi::ConversationEvent.where(event_type: 'order_paid')).to be_empty
  end

  it 'does not attach an order when Shopify changed the customer on the draft' do
    allow(reader).to receive(:fetch).with('draft', '10').and_return({ 'order_id' => '20', 'customer' => { 'id' => '99' } })
    described_class.perform_now(link.id)
    expect(link.reload).to have_attributes(status: 'conflict', last_error: 'customer_mismatch')
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
  end

  it 'does not revive a draft that the operator unlinked during the Shopify read' do
    allow(reader).to receive(:fetch).with('draft', '10') do
      link.update!(status: 'unlinked')
      { 'order_id' => '20', 'customer' => { 'id' => '42' } }
    end
    described_class.perform_now(link.id)
    expect(link.reload.status).to eq('unlinked')
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
  end

  it 'does not revive an erased draft that completes later' do
    Umi::Shopify::CustomerRedactionService.new(conversation.contact).perform
    described_class.perform_now(link.id)
    expect(link.reload.redacted_at).to be_present
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
    expect(reader).not_to have_received(:fetch)
  end

  it 'does not restore an explicitly removed order when its pending draft later resolves' do
    service = Umi::Shopify::ManualLinkService.new(conversation: conversation, actor: create(:user, account: account))
    attribution = service.link(order)
    service.unlink('order', order.fetch('id'))

    described_class.perform_now(link.id)

    expect(attribution.reload.attribution_state).to eq('unlinked')
    expect(link.reload).to have_attributes(status: 'conflict', last_error: 'stale_preview')
  end
end
