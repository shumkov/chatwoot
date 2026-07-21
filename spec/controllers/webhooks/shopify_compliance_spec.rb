# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi Shopify compliance webhooks', type: :request do
  let(:secret) { 'shpss_test_secret' }
  let(:account) { create(:account) }
  let(:shop_domain) { 'test-store.myshopify.com' }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: shop_domain) }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
  end

  def post_webhook(topic, payload, webhook_id = nil)
    body = payload.to_json
    hmac = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body))
    headers = {
      'CONTENT_TYPE' => 'application/json',
      'X-Shopify-Topic' => topic,
      'X-Shopify-Hmac-SHA256' => hmac
    }
    headers['X-Shopify-Webhook-Id'] = webhook_id if webhook_id
    post '/webhooks/shopify', params: body, headers: headers
  end

  describe 'customers/redact' do
    it 'destroys a contact without conversations, matched by shopify_customer_id' do
      contact = create(:contact, account: account, email: 'other@example.com',
                                 additional_attributes: { 'shopify_customer_id' => 9001 })

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9001, email: 'stale@example.com' })

      expect(response).to have_http_status(:ok)
      expect(Contact.exists?(contact.id)).to be(false)
    end

    it 'anonymizes a contact with conversations instead of destroying the record' do
      contact = create(:contact, account: account, email: 'gone@example.com', phone_number: '+66812345678',
                                 additional_attributes: { 'shopify_customer_id' => 9002, 'company_name' => 'ACME', 'city' => 'Bangkok' })
      create(:conversation, account: account, contact: contact)

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9002 })

      contact.reload
      expect(contact.name).to eq('Redacted customer')
      expect(contact.email).to be_nil
      expect(contact.phone_number).to be_nil
      expect(contact.additional_attributes.keys).to eq(['company_name'])
      expect(contact.conversations.count).to eq(1)
    end

    # Shared phones are common; a phone-only match may be a different person —
    # never destroy on it.
    it 'only strips shopify attributes on a phone-only match' do
      contact = create(:contact, account: account, phone_number: '+66811111111', email: nil,
                                 additional_attributes: { 'shopify_orders_count' => 2, 'company_name' => 'ACME' })

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 404, phone: '+66811111111' })

      contact.reload
      expect(Contact.exists?(contact.id)).to be(true)
      expect(contact.additional_attributes).to eq('company_name' => 'ACME')
    end

    it 'still returns 200 when nothing matches' do
      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 123_456 })

      expect(response).to have_http_status(:ok)
    end

    # A 200 tells Shopify never to redeliver; the handler must not 500 into
    # Shopify's retry/flagging machinery, but the failure must reach the tracker.
    it 'returns 200 and reports when the redaction itself raises' do
      create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 9003 })
      tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
      allow_any_instance_of(Contact).to receive(:destroy!).and_raise(StandardError, 'boom') # rubocop:disable RSpec/AnyInstance

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9003 })

      expect(response).to have_http_status(:ok)
      expect(tracker).to have_received(:capture_exception)
    end

    it 'falls back to the single account when the hook is gone and the shop domain is the pinned one' do
      contact = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 9004 })
      hook.destroy!

      with_modified_env UMI_SHOPIFY_SHOP_DOMAIN: shop_domain do
        post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9004 })
      end

      expect(response).to have_http_status(:ok)
      expect(Contact.exists?(contact.id)).to be(false)
    end

    # All webhooks for the app share one signing secret — without the domain
    # pin, any shop that installed the app could redact contacts in the one
    # account by sending correctly-signed payloads for its own shop.
    it 'never falls back for an unknown shop domain (hookless), and reports' do
      contact = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 9005 })
      hook.destroy!
      tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

      with_modified_env UMI_SHOPIFY_SHOP_DOMAIN: shop_domain do
        post_webhook('customers/redact', shop_domain: 'attacker-shop.myshopify.com', customer: { id: 9005 })
      end

      expect(response).to have_http_status(:ok)
      expect(Contact.exists?(contact.id)).to be(true)
      expect(tracker).to have_received(:capture_exception)
    end

    # The HMAC proves origin, not freshness: a captured delivery must not be
    # replayable against a future contact reusing the same identity.
    it 'drops a replayed delivery (same X-Shopify-Webhook-Id)' do
      contact = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 9006 })
      webhook_id = SecureRandom.uuid

      post_webhook('customers/redact', { shop_domain: shop_domain, customer: { id: 9006 } }, webhook_id)
      expect(Contact.exists?(contact.id)).to be(false)

      replayed = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 9006 })
      post_webhook('customers/redact', { shop_domain: shop_domain, customer: { id: 9006 } }, webhook_id)

      expect(response).to have_http_status(:ok)
      expect(Contact.exists?(replayed.id)).to be(true)
    end
  end

  describe 'customers/data_request' do
    it 'reports to the exception tracker (manual export runbook) and returns 200' do
      tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

      post_webhook('customers/data_request', shop_domain: shop_domain, customer: { id: 9001 })

      expect(response).to have_http_status(:ok)
      expect(tracker).to have_received(:capture_exception)
    end
  end

  describe 'passthrough' do
    it 'keeps the core shop/redact behavior (hook destroyed)' do
      post_webhook('shop/redact', shop_domain: shop_domain)

      expect(response).to have_http_status(:ok)
      expect(Integrations::Hook.exists?(hook.id)).to be(false)
    end

    it 'rejects an invalid HMAC' do
      post '/webhooks/shopify', params: { shop_domain: shop_domain }.to_json, headers: {
        'CONTENT_TYPE' => 'application/json',
        'X-Shopify-Topic' => 'customers/redact',
        'X-Shopify-Hmac-SHA256' => 'nope'
      }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
