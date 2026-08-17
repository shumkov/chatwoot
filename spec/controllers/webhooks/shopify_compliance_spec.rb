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
      'X-Shopify-Hmac-SHA256' => hmac,
      'X-Shopify-Shop-Domain' => payload[:shop_domain] || payload['shop_domain']
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
      attribution = Umi::ShopifyOrderAttribution.create!(
        account: account,
        candidate_contact_id: contact.id,
        shop_domain: shop_domain,
        shopify_order_id: 'redact-9002',
        token_nonce: 'nonce-redact-9002',
        attribution_state: 'unverified'
      )

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9002 })

      contact.reload
      expect(contact.name).to eq('Redacted customer')
      expect(contact.email).to be_nil
      expect(contact.phone_number).to be_nil
      expect(contact.additional_attributes.keys).to contain_exactly('company_name', 'umi_profile_redacted')
      expect(contact.conversations.count).to eq(1)
      expect(attribution.reload).to have_attributes(
        candidate_conversation_id: nil,
        candidate_contact_id: nil,
        conversation_id: nil,
        contact_id: nil
      )
    end

    # A contact who reached UMI on Instagram carries their handle and their
    # profile photo. Blanking the name while keeping those leaves the person
    # identifiable, so erasure has to reach them too. The tombstone is what
    # stops profile enrichment re-deriving the handle from Meta afterwards.
    it 'erases the Instagram handle and avatar, and tombstones the contact against re-enrichment' do
      contact = create(:contact, account: account, email: 'ig@example.com',
                                 additional_attributes: {
                                   'shopify_customer_id' => 9003,
                                   'social_instagram_user_name' => 'ploy.bkk',
                                   'social_profiles' => { 'instagram' => 'ploy.bkk' },
                                   'umi_profile_name' => 'ploy.bkk',
                                   'umi_profile_checked_at' => '2026-08-06T00:00:00Z'
                                 })
      contact.avatar.attach(io: Rails.root.join('spec/assets/avatar.png').open,
                            filename: 'avatar.png', content_type: 'image/png')
      create(:conversation, account: account, contact: contact)

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9003 })

      contact.reload
      expect(contact.name).to eq('Redacted customer')
      expect(contact.avatar).not_to be_attached
      expect(contact.additional_attributes.keys).to contain_exactly('umi_profile_redacted')
      expect(contact.additional_attributes['umi_profile_redacted']).to be(true)
      expect(contact.last_name).to eq('')
      expect(contact.custom_attributes).to eq({})
    end

    # Enrichment ledgers the before/after of every name it writes, so it holds
    # this customer's name and handle. Leaving it to the nightly sweep would
    # make erasure depend on another job running.
    it 'purges the enrichment ledger rows that hold the customer name' do
      contact = create(:contact, account: account, email: 'led@example.com',
                                 additional_attributes: { 'shopify_customer_id' => 9004 })
      create(:conversation, account: account, contact: contact)
      Umi::ProfileLedgerEntry.create!(run_id: 'r', contact_id: contact.id, attribute_name: 'name',
                                      old_value: 'Instagram user 4355', new_value: 'ploy.bkk',
                                      evidence_source: 'participants', created_at: Time.current)

      post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9004 })

      expect(Umi::ProfileLedgerEntry.where(contact_id: contact.id)).to be_empty
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

    it 'rolls back a partial erasure and enqueues a durable retry when attribution purge fails' do
      contact = create(:contact, account: account, email: 'retry@example.com',
                                 additional_attributes: { 'shopify_customer_id' => 9007 })
      create(:conversation, account: account, contact: contact)
      allow(Umi::FbigAdAttribution).to receive(:purge_for).and_raise(StandardError, 'attribution database unavailable')

      expect do
        post_webhook('customers/redact', shop_domain: shop_domain, customer: { id: 9007 })
      end.to have_enqueued_job(Umi::Shopify::CustomerRedactionRetryJob).with(contact.id)

      expect(response).to have_http_status(:ok)
      expect(contact.reload.name).not_to eq('Redacted customer')
      expect(contact.email).to eq('retry@example.com')
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

  describe 'orders/create' do
    let(:contact) { create(:contact, :with_email, account: account, email: 'buyer@example.com') }
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let(:claim) do
      {
        'account_id' => account.id,
        'conversation_id' => conversation.id,
        'contact_id' => contact.id,
        'nonce' => 'nonce-webhook',
        'raw' => '{"nonce":"nonce-webhook"}'
      }
    end

    before do
      allow(Redis::Alfred).to receive(:get).and_return(nil)
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Redis::Alfred).to receive(:delete)
      allow(Umi::Shopify::OrderLinkTokenService).to receive(:peek).and_return(claim)
      allow(Umi::Shopify::OrderLinkTokenService).to receive(:consume).and_return(true)
    end

    it 'runs through the existing HMAC-verified webhook endpoint' do
      post_webhook(
        'orders/create',
        {
          shop_domain: shop_domain,
          id: 1001,
          email: 'buyer@example.com',
          note_attributes: [{ name: '_cw', value: 'signed-token' }]
        },
        'orders-create-1001'
      )

      expect(response).to have_http_status(:ok)
      expect(Umi::ShopifyOrderAttribution.last).to have_attributes(
        shopify_order_id: '1001', attribution_state: 'verified', conversation_id: conversation.id
      )
    end

    it 'acknowledges an invalid token without creating an attribution row' do
      allow(Umi::Shopify::OrderLinkTokenService).to receive(:peek).and_raise(
        Umi::Shopify::OrderLinkTokenService::InvalidToken
      )

      post_webhook(
        'orders/create',
        { shop_domain: shop_domain, id: 1002, note_attributes: [{ name: '_cw', value: 'bad-token' }] },
        'orders-create-1002'
      )

      expect(response).to have_http_status(:ok)
      expect(Umi::ShopifyOrderAttribution.exists?(shopify_order_id: '1002')).to be(false)
    end
  end

  describe 'passthrough' do
    it 'keeps the core shop/redact behavior (hook destroyed)' do
      Umi::ShopifyOrderAttribution.create!(
        account: account,
        shop_domain: shop_domain,
        shopify_order_id: 'shop-redact-1',
        token_nonce: 'shop-redact-nonce-1',
        attribution_state: 'unlinked'
      )

      post_webhook('shop/redact', shop_domain: shop_domain)

      expect(response).to have_http_status(:ok)
      expect(Integrations::Hook.exists?(hook.id)).to be(false)
      expect(Umi::ShopifyOrderAttribution.where(shop_domain: shop_domain)).to be_empty
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
