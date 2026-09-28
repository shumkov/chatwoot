# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ManualLinkService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(conversation: conversation, actor: actor) }
  let(:order) do
    { 'kind' => 'order', 'id' => '123', 'name' => '#1001', 'updated_at' => '2026-09-28T01:00:00Z',
      'customer' => { 'id' => '42', 'name' => 'Customer' }, 'amount' => '1000', 'currency' => 'THB', 'status' => 'PENDING' }
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      example.run
    end
  end

  it 'links a manual Shopify order without email, phone or a checkout token' do
    conversation.contact.update!(email: nil, phone_number: nil)
    link = service.link(order)
    expect(link).to have_attributes(source: 'operator', contact_id: conversation.contact_id, conversation_id: conversation.id, token_nonce: nil)
    expect(conversation.contact.reload.additional_attributes['shopify_customer_id']).to eq('42')
    expect(service.link(order).id).to eq(link.id)
    expect(Umi::ShopifyOrderFinancialState.where(shopify_order_id: '123').count).to eq(1)
  end

  it 'refuses to silently change an existing customer' do
    conversation.contact.update!(additional_attributes: { 'shopify_customer_id' => '99' })
    expect { service.link(order) }.to raise_error(Umi::Shopify::CommerceError, 'customer_mismatch')
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
  end

  it 'restores classification after removing the last unpaid purchase' do
    link = service.link(order)
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_changed', occurrence_key: 'classification:test', provenance: 'operator',
                                   observed_at: Time.current, payload: { status: 'engaged' })
    Umi::ShopifyOrderFinancialState.find_by!(shopify_order_id: '123').update!(snapshot: { 'classification' => 'unpaid' })
    Umi::Funnel::CommerceProjection.refresh(conversation)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('order_placed')
    service.unlink('order', link.shopify_order_id)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('engaged')
    expect(link.reload.attribution_state).to eq('unlinked')
    expect(link.redacted_at).to be_nil
  end

  it 'keeps a recorded payment immutable and couples its draft reference to the order' do
    link = service.link(order)
    draft = Umi::ShopifyDraftLink.create!(account: account, shop_domain: hook.reference_id, shopify_draft_id: '10',
                                          shopify_order_id: '123', status: 'resolved', contact_id: conversation.contact_id,
                                          conversation_id: conversation.id)
    event = Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                           event_type: 'order_paid', occurrence_key: 'paid:test', provenance: 'shopify', observed_at: Time.current)
    Umi::ShopifyOrderFinancialState.find_by!(shopify_order_id: '123').update!(paid_event: event)
    expect { service.unlink('draft', '10') }.to raise_error(Umi::Shopify::CommerceError, 'paid_link_correction_required')
    expect(link.reload.conversation_id).to eq(conversation.id)
    expect(draft.reload.status).to eq('resolved')
  end

  it 'unlinks a resolved unpaid draft and its order together' do
    link = service.link(order)
    draft = Umi::ShopifyDraftLink.create!(account: account, shop_domain: hook.reference_id, shopify_draft_id: '10',
                                          shopify_order_id: '123', status: 'resolved', contact_id: conversation.contact_id,
                                          conversation_id: conversation.id)
    service.unlink('draft', '10')
    expect(link.reload.attribution_state).to eq('unlinked')
    expect(draft.reload.status).to eq('unlinked')
  end

  it 'uses explicit order identity to distinguish two contacts sharing a Shopify customer' do
    service.link(order)
    create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => '42' })
    state = Umi::ShopifyOrderFinancialState.find_by!(shopify_order_id: '123')
    Umi::Funnel::PaidCustomerLink.new(state).with_identity({ 'shopify_customer_id' => '42' }) do |snapshot, attribution, contact|
      expect(snapshot['identity_hold']).to be_nil
      expect(contact.id).to eq(conversation.contact_id)
      expect(attribution.conversation_id).to eq(conversation.id)
    end
  end

  it 'does not attach the same order to another conversation or revive an erased order' do
    link = service.link(order)
    other = create(:conversation, account: account, contact: conversation.contact)
    expect { described_class.new(conversation: other, actor: actor).link(order) }.to raise_error(Umi::Shopify::CommerceError, 'already_linked')
    link.update!(redacted_at: Time.current)
    expect { service.link(order) }.to raise_error(Umi::Shopify::CommerceError, 'redacted')
  end

  it 'clears stale Shopify enrichment when changing a customer without dependent purchases' do
    contact = conversation.contact
    contact.update!(additional_attributes: { 'shopify_customer_id' => '99', 'shopify_total_spent' => 9000, 'shopify_accepts_email_marketing' => true,
                                             'other' => 'preserved' })
    described_class.link_customer(contact, { 'id' => '42' })
    expect(contact.reload.additional_attributes).to eq({ 'shopify_customer_id' => '42', 'other' => 'preserved' })
  end

  it 'cannot revive an unlinked order erased before its first financial read' do
    link = service.link(order)
    service.unlink('order', '123')
    Umi::Funnel::Privacy.redact_customer_orders!(account_id: account.id, shop_domain: hook.reference_id, customer_id: '42', order_ids: [])
    expect(link.reload.redacted_at).to be_present
    expect(link.shopify_customer_id).to be_nil
    expect(link.linked_by_id).to be_nil
    expect { service.link(order) }.to raise_error(Umi::Shopify::CommerceError, 'redacted')
  end

  it 'lets an operator remove a relinked draft when its previous order belongs elsewhere' do
    service.link(order)
    draft_object = order.merge('kind' => 'draft', 'id' => '10', 'name' => '#D10')
    draft = service.link(draft_object)
    draft.update!(status: 'resolved', shopify_order_id: '123')
    service.unlink('draft', '10')
    other = create(:conversation, account: account, contact: conversation.contact)
    described_class.new(conversation: other, actor: actor).link(order)
    service.link(draft_object)
    draft.reload.update!(status: 'conflict')
    expect { service.unlink('draft', '10') }.not_to raise_error
    expect(draft.reload.status).to eq('unlinked')
  end

  it 'does not remove a draft moved to another conversation while an old screen waits' do
    account = create(:account)
    actor = create(:user, account: account)
    create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com')
    old_chat = create(:conversation, account: account)
    new_chat = create(:conversation, account: account)
    old_contact = old_chat.contact
    old_service = described_class.new(conversation: old_chat, actor: actor)
    new_service = described_class.new(conversation: new_chat, actor: actor)
    draft = { 'kind' => 'draft', 'id' => '101', 'name' => '#D101', 'customer' => { 'id' => '42' } }
    link = old_service.link(draft)
    moved = false
    allow(old_contact).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      unless moved
        moved = true
        old_service.unlink('draft', '101')
        new_service.link(draft)
      end
      original.call(*args, &block)
    end
    expect { old_service.unlink('draft', '101') }.to raise_error(Umi::Shopify::CommerceError, 'stale_preview')
    expect(moved).to be(true)
    expect(link.reload).to have_attributes(status: 'pending', conversation_id: new_chat.id)
  end
end
