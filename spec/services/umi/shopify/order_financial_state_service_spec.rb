# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::OrderFinancialStateService do
  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:state) { described_class.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '123') }
  let(:row) do
    { classification: 'paid', review_reasons: [], currency: 'THB', original_order_value: '12000.0', current_order_value: '4000.0',
      captured: '4000.0', refunded: '0.0', net_cash: '4000.0', last_payment_at: '2026-09-20T10:00:00Z',
      paid_basket: { 'items' => [{ 'id' => 5, 'variant_id' => 7, 'current_quantity' => 1 }] } }
  end
  let(:report) { { shop_domain: hook.reference_id, observed_finished_at: Time.current.iso8601, rows: [row] } }
  let(:reader) { instance_double(Umi::Shopify::PaidOrderReport, perform: report) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      example.run
    end
  end

  before { allow(Umi::Shopify::PaidOrderReport).to receive(:new).and_return(reader) }

  it 'keeps the paid basket and occurrence when a later refund changes retained cash' do
    described_class.new(state).perform
    paid = state.reload.paid_event
    expect(paid.payload).to include('value' => '4000.0', 'order_origin' => 'unknown')
    expect(paid.occurred_at).to eq(Time.iso8601(row[:last_payment_at]))
    row.merge!(classification: 'partially_refunded', refunded: '1000.0', net_cash: '3000.0', current_order_value: '3000.0')
    described_class.new(state).perform
    expect(state.reload.paid_event_id).to eq(paid.id)
    expect(state.snapshot).to include('net_cash' => '3000.0')
    expect(state.snapshot['first_paid_snapshot']).to include('current_order_value' => '4000.0', 'paid_basket' => row[:paid_basket])
    expect(paid.reload.payload['value']).to eq('4000.0')
    expect(Umi::ConversionDelivery.count).to eq(2)
  end

  %w[unpaid no_sale partial_payment test_order needs_review refunded partially_refunded].each do |classification|
    it "does not invent a paid event from #{classification}" do
      row[:classification] = classification
      described_class.new(state).perform
      expect(state.reload.paid_event_id).to be_nil
      expect(Umi::ConversationEvent.where(event_type: 'order_paid')).to be_empty
      expect(state.snapshot['paid_history_unknown']).to be(true) if %w[refunded partially_refunded].include?(classification)
    end
  end

  it 'keeps the pending row when queue enqueue fails' do
    allow(Umi::Shopify::OrderFinancialReconcileJob).to receive(:perform_later).and_raise(StandardError)
    expect(state).to be_persisted
    expect(Umi::ShopifyOrderFinancialState.pending).to include(state)
  end

  it 'keeps notifications arriving during the authoritative read pending' do
    state
    allow(reader).to receive(:perform) do
      Umi::ShopifyOrderFinancialState.find(state.id).update!(reconciliation_requested_at: 1.second.from_now)
      report
    end
    described_class.new(state).perform
    expect(Umi::ShopifyOrderFinancialState.pending).to include(state)
  end

  it 'retains API failure without fabricating zero money or a completed reconciliation' do
    allow(reader).to receive(:perform).and_raise(Timeout::Error)
    expect { described_class.new(state).perform }.to raise_error(Timeout::Error)
    expect(state.reload).to have_attributes(snapshot: {}, reconciled_at: nil, last_error: 'Timeout::Error')
  end

  it 'attaches paid-first evidence only after verified same-shop attribution arrives' do
    described_class.new(state).perform
    conversation = create(:conversation, account: account)
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '123',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id,
                                         attribution_state: 'verified', token_nonce: SecureRandom.hex)
    described_class.new(state).perform
    expect(state.reload.paid_event.contact_id).to eq(conversation.contact_id)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('purchased')
  end

  it 'removes paid tombstones and deliveries when shop erasure follows customer erasure' do
    conversation = create(:conversation, account: account)
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '123',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id,
                                         attribution_state: 'verified', token_nonce: SecureRandom.hex)
    described_class.new(state).perform
    paid = state.reload.paid_event
    Umi::Shopify::CustomerRedactionService.new(conversation.contact).perform
    Umi::Funnel::Privacy.redact_shop!(hook.reference_id)
    expect(Umi::ConversationEvent.exists?(paid.id)).to be(false)
    expect(Umi::ConversionDelivery.where(conversation_event_id: paid.id)).to be_empty
  end

  it 'cannot resurrect identity after customer erasure' do
    conversation = create(:conversation, account: account)
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '123',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id,
                                         attribution_state: 'verified', token_nonce: SecureRandom.hex)
    described_class.new(state).perform
    paid = state.reload.paid_event
    Umi::Shopify::CustomerRedactionService.new(conversation.contact).perform
    described_class.new(state).perform
    expect(state.reload.redacted_at).to be_present
    expect(paid.reload).to have_attributes(contact_id: nil, conversation_id: nil)
    expect(paid.payload.keys).not_to include('order_id', 'shop_domain')
  end
end
