# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::OrderAttributionService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, :with_email, account: account, email: 'buyer@example.com') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:claim) do
    {
      'account_id' => account.id,
      'conversation_id' => conversation.id,
      'contact_id' => contact.id,
      'nonce' => 'nonce-1',
      'raw' => '{"nonce":"nonce-1"}'
    }
  end
  let(:perform_order) do
    lambda do |order_id:, email: 'buyer@example.com', note_attributes: [{ 'name' => '__cw', 'value' => 'signed-token' }],
                   webhook_id: "webhook-#{order_id}", phone: nil, billing_address: nil, shipping_address: nil|
      described_class.new(
        payload: {
          'id' => order_id,
          'email' => email,
          'phone' => phone,
          'billing_address' => billing_address,
          'shipping_address' => shipping_address,
          'note_attributes' => note_attributes
        },
        shop_domain: hook.reference_id,
        webhook_id: webhook_id
      ).perform
    end
  end

  before do
    allow(Redis::Alfred).to receive(:get).and_return(nil)
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(Redis::Alfred).to receive(:delete)
    allow(Umi::Shopify::OrderLinkTokenService).to receive(:peek).and_return(claim)
    allow(Umi::Shopify::OrderLinkTokenService).to receive(:consume).and_return(true)
    allow(Umi::Shopify::OrderLinkTokenService).to receive(:restore).and_return(true)
  end

  it 'stores a verified attribution when the order email matches the token contact' do
    perform_order.call(order_id: '1001', email: 'buyer@example.com')

    attribution = Umi::ShopifyOrderAttribution.last
    expect(attribution).to have_attributes(
      shopify_order_id: '1001',
      attribution_state: 'verified',
      match_method: 'email',
      conversation_id: conversation.id,
      contact_id: contact.id
    )
  end

  it 'stores an unverified candidate without linking a mismatched identity' do
    perform_order.call(order_id: '1002', email: 'other@example.com')

    attribution = Umi::ShopifyOrderAttribution.last
    expect(attribution).to have_attributes(
      attribution_state: 'unverified',
      match_method: 'email_mismatch',
      conversation_id: nil,
      contact_id: nil,
      candidate_conversation_id: conversation.id,
      candidate_contact_id: contact.id
    )
  end

  it 'does nothing for a storefront order without the conversation carrier' do
    perform_order.call(order_id: '1003', email: 'buyer@example.com', note_attributes: [])

    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
    expect(Umi::Shopify::OrderLinkTokenService).not_to have_received(:consume)
  end

  it 'consumes a valid token presented to the wrong account as a terminal outcome' do
    allow(Umi::Shopify::OrderLinkTokenService).to receive(:peek).and_return(claim.merge('account_id' => account.id + 1))

    expect { perform_order.call(order_id: '1004', email: 'buyer@example.com') }
      .to raise_error(described_class::Permanent, 'token_account_mismatch')

    expect(Umi::Shopify::OrderLinkTokenService).to have_received(:consume).with(hash_including('nonce' => 'nonce-1'))
    expect(Umi::Shopify::OrderLinkTokenService).not_to have_received(:restore)
  end

  it 'restores the consumed token when durable attribution fails' do
    allow(Umi::ShopifyOrderAttribution).to receive(:create!).and_raise(StandardError, 'database unavailable')

    expect { perform_order.call(order_id: '1005', email: 'buyer@example.com') }.to raise_error('database unavailable')

    expect(Umi::Shopify::OrderLinkTokenService).to have_received(:restore).with(hash_including('nonce' => 'nonce-1'))
  end

  it 'carries the token on the private double-underscore attribute Shopify hides from the storefront' do
    # A single underscore is the line item property convention and leaves a cart attribute public,
    # readable by every app on the storefront origin through /cart.js. The name is also the contract
    # with the theme, which posts exactly this attribute.
    expect(described_class::CART_ATTRIBUTE).to eq('__cw')
  end

  it 'ignores a token sent on the old public attribute name' do
    # Nothing should still be writing `_cw`: the rewrite has never been enabled, so no link has ever
    # carried a token and no cart has ever held one. Reading it anyway would keep the leak alive by
    # making a public carrier work.
    expect(
      perform_order.call(order_id: '1010', note_attributes: [{ 'name' => '_cw', 'value' => 'signed-token' }])
    ).to eq(:unlinked)

    expect(Umi::Shopify::OrderLinkTokenService).not_to have_received(:peek)
  end

  it 'rejects duplicate carrier attributes rather than choosing one' do
    expect do
      perform_order.call(
        order_id: '1006',
        email: 'buyer@example.com',
        note_attributes: [
          { 'name' => '__cw', 'value' => 'signed-token' },
          { 'name' => '__cw', 'value' => 'another-token' }
        ]
      )
    end.to raise_error(described_class::Permanent, 'carrier_ambiguous')

    expect(Umi::Shopify::OrderLinkTokenService).not_to have_received(:peek)
  end

  it 'acknowledges a replayed delivery without creating a second attribution row' do
    allow(Redis::Alfred).to receive(:get).and_return(nil, 'done')

    expect(perform_order.call(order_id: '1007')).to eq(:verified)
    expect(perform_order.call(order_id: '1007')).to eq(:duplicate)
    expect(Umi::ShopifyOrderAttribution.where(shopify_order_id: '1007').count).to eq(1)
  end

  it 'returns duplicate for a second delivery of the same order id' do
    expect(perform_order.call(order_id: '1008', webhook_id: 'webhook-1008-a')).to eq(:verified)
    expect(perform_order.call(order_id: '1008', webhook_id: 'webhook-1008-b')).to eq(:duplicate)

    expect(Umi::ShopifyOrderAttribution.where(shopify_order_id: '1008').count).to eq(1)
    expect(Umi::Shopify::OrderLinkTokenService).to have_received(:consume).once
  end

  it 'marks conflicting valid phone identities unavailable instead of guessing' do
    contact.update!(email: nil, phone_number: '+66812345678')

    expect(
      perform_order.call(
        order_id: '1009',
        email: nil,
        phone: '+66812345678',
        billing_address: { phone: '+66887654321' }
      )
    ).to eq(:unavailable)

    expect(Umi::ShopifyOrderAttribution.last).to have_attributes(
      attribution_state: 'unavailable',
      match_method: 'phone_ambiguous',
      conversation_id: nil,
      contact_id: nil,
      candidate_contact_id: contact.id
    )
  end

  it 'falls back to the billing phone when the root order phone is absent' do
    contact.update!(email: nil, phone_number: '+66812345678')

    expect(
      perform_order.call(
        order_id: '1010',
        email: nil,
        billing_address: { phone: '+66812345678' }
      )
    ).to eq(:verified)

    expect(Umi::ShopifyOrderAttribution.last).to have_attributes(
      attribution_state: 'verified',
      match_method: 'phone',
      conversation_id: conversation.id,
      contact_id: contact.id
    )
  end
end
