# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::ShopifyOrderAttribution do
  let(:account) { create(:account) }

  it 'reports only live verified rows with both durable links' do
    live = described_class.create!(
      account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: 'live', token_nonce: 'nonce-live',
      attribution_state: 'verified', conversation_id: 10, contact_id: 20
    )
    described_class.create!(
      account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: 'missing-contact',
      token_nonce: 'nonce-missing-contact', attribution_state: 'verified', conversation_id: 10
    )
    described_class.create!(
      account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: 'redacted', token_nonce: 'nonce-redacted',
      attribution_state: 'verified', conversation_id: 10, contact_id: 20, redacted_at: Time.current
    )

    expect(described_class.verified).to contain_exactly(live)
  end
end
