# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::CustomerContactMapper do
  def map(overrides = {})
    described_class.map({
      'id' => 9001, 'email' => 'Somchai@Example.com', 'phone' => '+66812345678',
      'first_name' => 'Somchai', 'last_name' => 'P', 'orders_count' => 3,
      'total_spent' => '199.00', 'currency' => 'THB', 'tags' => 'vip',
      'updated_at' => '2026-07-01T10:00:00+07:00',
      'email_marketing_consent' => { 'state' => 'subscribed' },
      'sms_marketing_consent' => { 'state' => 'not_subscribed' },
      'default_address' => { 'city' => 'Bangkok', 'country_code' => 'TH', 'phone' => '+66899999999' }
    }.merge(overrides))
  end

  it 'maps identity, name, type and the shopify-owned attributes' do
    attrs = map.attributes

    expect(attrs[:email]).to eq('somchai@example.com')
    expect(attrs[:phone_number]).to eq('+66812345678')
    expect(attrs[:name]).to eq('Somchai P')
    expect(attrs[:contact_type]).to eq('customer')
    expect(attrs[:location]).to eq('Bangkok')
    expect(attrs[:country_code]).to eq('TH')
    expect(attrs[:additional_attributes]).to include(
      'shopify_customer_id' => 9001, 'shopify_orders_count' => 3, 'shopify_total_spent' => '199.00',
      'shopify_accepts_email_marketing' => true, 'shopify_accepts_sms_marketing' => false,
      'city' => 'Bangkok', 'country' => 'TH'
    )
  end

  it 'skips a customer with neither valid email nor valid phone' do
    result = map('email' => nil, 'phone' => nil, 'default_address' => {})

    expect(result.attributes).to be_nil
  end

  it 'drops an invalid email but keeps the row via phone, counting the drop' do
    result = map('email' => 'not-an-email')

    expect(result.attributes[:email]).to be_nil
    expect(result.attributes[:phone_number]).to eq('+66812345678')
    expect(result.dropped_email).to be(true)
  end

  # Thai local formats are never guessed into +66 — a wrong guess poisons
  # caller-ID matching. The default-address phone is the fallback.
  it 'drops non-E.164 phones without guessing, falling back to the address phone' do
    result = map('phone' => '0812345678', 'default_address' => { 'phone' => '+66899999999' })

    expect(result.attributes[:phone_number]).to eq('+66899999999')
  end

  it 'counts a fully unusable phone as dropped' do
    result = map('phone' => '081-234-5678', 'default_address' => { 'phone' => 'call me' })

    expect(result.attributes[:phone_number]).to be_nil
    expect(result.dropped_phone).to be(true)
  end

  it 'falls back to the email local part, then the phone, for the name' do
    expect(map('first_name' => nil, 'last_name' => nil).attributes[:name]).to eq('somchai')
    expect(map('first_name' => nil, 'last_name' => nil, 'email' => nil).attributes[:name]).to eq('+66812345678')
  end

  # nil (not a dropped key): the enrich merge uses nil to DELETE a stale stored
  # value when a tag/consent is cleared in Shopify; create paths compact.
  it 'emits nil for absent consent/tags so enrichment can clear stale values' do
    attrs = map('email_marketing_consent' => nil, 'tags' => '').attributes

    expect(attrs[:additional_attributes]).to have_key('shopify_accepts_email_marketing')
    expect(attrs[:additional_attributes]['shopify_accepts_email_marketing']).to be_nil
    expect(attrs[:additional_attributes]['shopify_tags']).to be_nil
  end
end
