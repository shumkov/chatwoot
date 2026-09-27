# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Website paid customer links' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:state) { Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '1001') }
  let(:contact) { create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 123 }) }
  let(:row) do
    { classification: 'paid', currency: 'THB', current_order_value: '4000.0', captured: '4000.0', refunded: '0.0', net_cash: '4000.0',
      shopify_customer_id: '123', last_payment_at: 1.hour.ago.utc.iso8601 }
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601 do
      example.run
    end
  end

  before do
    reader = instance_double(Umi::Shopify::PaidOrderReport, perform: { shop_domain: hook.reference_id,
                                                                       observed_finished_at: Time.current.iso8601, rows: [row] })
    allow(Umi::Shopify::PaidOrderReport).to receive(:new).and_return(reader)
  end

  it 'links a website payment to an existing exact customer without manufacturing a conversation' do
    contact
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(state.reload.paid_event).to have_attributes(contact_id: contact.id, conversation_id: nil)
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
    expect(contact.conversations.count).to eq(0)
  end

  it 'links a late synced customer locally to the same original paid occurrence' do
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    original = state.reload.paid_event_id
    delivery = state.paid_event.conversion_deliveries.find_by!(destination: 'klaviyo')
    with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'true' do
      Umi::Funnel::DeliveryJob.perform_now(delivery.id)
    end
    expect(delivery.reload.reason).to eq('identity_unlinked')
    contact
    expect(Umi::Shopify::PaidOrderReport).not_to receive(:new)
    Umi::Funnel::PaidCustomerLink.reconcile
    expect(state.reload.paid_event).to have_attributes(id: original, contact_id: contact.id, conversation_id: nil)
  end

  it 'holds duplicate exact IDs instead of taking the first customer' do
    contact
    create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => '123' })
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(state.reload.paid_event.contact_id).to be_nil
    expect(state.snapshot['identity_hold']).to eq('customer_ambiguous')
  end

  it 'allows a later verified conversation only for the same website-linked contact' do
    contact
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    conversation = create(:conversation, account: account, contact: contact)
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                         conversation_id: conversation.id, contact_id: contact.id, attribution_state: 'verified', token_nonce: 'test')
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(state.reload.paid_event).to have_attributes(contact_id: contact.id, conversation_id: conversation.id)
  end

  it 'erases an unpaid website state before clearing the contact customer ID' do
    contact
    row[:classification] = 'unpaid'
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    Umi::Shopify::CustomerRedactionService.new(contact).perform
    expect(state.reload).to have_attributes(snapshot: {}, paid_event_id: nil)
    expect(state.redacted_at).to be_present
    row[:classification] = 'paid'
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(state.reload.paid_event_id).to be_nil
  end

  it 'holds an exact customer that disagrees with verified conversation attribution' do
    contact
    conversation = create(:conversation, account: account)
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id,
                                         attribution_state: 'verified', token_nonce: 'conflict')
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(state.reload.paid_event).to have_attributes(contact_id: nil, conversation_id: nil)
    expect(state.snapshot['identity_hold']).to eq('attribution_conflict')
  end

  it 'does not borrow a customer from another account or attach after erasure' do
    create(:contact, additional_attributes: { 'shopify_customer_id' => 123 })
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(state.reload.snapshot['identity_hold']).to eq('customer_missing')
    expect(state.paid_event.contact_id).to be_nil
    contact
    Umi::Shopify::CustomerRedactionService.new(contact).perform
    create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 123 })
    Umi::Funnel::PaidCustomerLink.reconcile
    expect(state.reload).to have_attributes(paid_event_id: nil, snapshot: {})
  end

  it 'never replaces an attached contact or conversation and keeps identity outside payment evidence' do
    contact
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    event = state.reload.paid_event
    original_value = event.payload['value']
    expect(state.snapshot['first_paid_snapshot']).not_to have_key('shopify_customer_id')
    another = create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 456 })
    row[:shopify_customer_id] = '456'
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(event.reload.contact_id).to eq(contact.id)
    expect(state.reload.snapshot['identity_hold']).to eq('customer_changed')
    expect { event.update!(contact_id: another.id) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(event.reload.payload['value']).to eq(original_value)
  end

  it 'delivers one website paid metric to a bound existing profile without adding chat attribution' do
    contact.update!(email: 'person@example.test', additional_attributes: { 'shopify_customer_id' => 123, 'umi_klaviyo_profile_id' => 'PROFILE1' })
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    event = state.reload.paid_event
    client = instance_double(Umi::Funnel::KlaviyoClient, profile: { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email } },
                                                         create_event: { state: 'accepted' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    delivery = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'true', UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      2.times { Umi::Funnel::DeliveryJob.perform_now(delivery.id) }
    end
    expect(delivery.reload).to have_attributes(state: 'accepted', attempt_count: 1)
    expect(delivery.payload.dig('data', 'attributes')).to include('value' => 4000.0, 'value_currency' => 'THB')
    expect(client).to have_received(:create_event).once
    expect(event.reload.conversation_id).to be_nil
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
    expect(contact.conversations.count).to eq(0)
  end

  it 'keeps contradictory attribution visible when a later order read omits the customer ID' do
    contact
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    original = state.reload.paid_event
    conversation = create(:conversation, account: account)
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                         conversation_id: conversation.id, contact_id: conversation.contact_id,
                                         attribution_state: 'verified', token_nonce: 'missing-id-conflict')
    row.delete(:shopify_customer_id)
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    expect(original.reload).to have_attributes(contact_id: contact.id, conversation_id: nil)
    expect(state.reload.snapshot['identity_hold']).to eq('attribution_conflict')
  end

  it 'holds an already linked paid delivery when a later customer conflicts with its original identity' do
    contact.update!(email: 'person@example.test', additional_attributes: { 'shopify_customer_id' => 123, 'umi_klaviyo_profile_id' => 'PROFILE1' })
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    event = state.reload.paid_event
    create(:contact, account: account, additional_attributes: { 'shopify_customer_id' => 456 })
    row[:shopify_customer_id] = '456'
    Umi::Shopify::OrderFinancialStateService.new(state).perform
    delivery = event.conversion_deliveries.find_by!(destination: 'klaviyo')
    client = instance_double(Umi::Funnel::KlaviyoClient, profile: { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email } },
                                                         create_event: { state: 'accepted' })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_KLAVIYO_ENABLED: 'true', UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      expect { Umi::Funnel::DeliveryAutomation.enqueue }.not_to have_enqueued_job(Umi::Funnel::DeliveryJob).with(delivery.id)
      Umi::Funnel::DeliveryJob.perform_now(delivery.id)
      Umi::Funnel::DeliveryService.new(delivery).dispatch
    end
    expect(delivery.reload).to have_attributes(state: 'pending', reason: 'financial_identity_conflict', attempt_count: 0)
    expect(client).not_to have_received(:create_event)
    expect(event.reload.contact_id).to eq(contact.id)
  end
end
