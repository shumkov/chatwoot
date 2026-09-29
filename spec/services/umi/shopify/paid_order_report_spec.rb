# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::PaidOrderReport do
  subject(:report) { service.perform }

  let(:service) { described_class.new(account_id: account.id, order_ids: ['1001']) }
  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }
  let(:order) do
    { 'id' => 1001, 'created_at' => '2026-09-01T10:00:00+07:00', 'updated_at' => '2026-09-19T10:00:00+07:00',
      'financial_status' => 'paid', 'test' => false, 'cancelled_at' => nil, 'currency' => 'THB',
      'total_price' => '4491.00', 'current_total_price' => '4491.00' }
  end
  let(:sale) do
    { 'id' => 2001, 'kind' => 'sale', 'status' => 'success', 'currency' => 'THB', 'amount' => '4491.00',
      'amount_rounding' => nil, 'processed_at' => '2026-09-19T10:00:00+07:00' }
  end
  let(:transactions) { [sale] }
  let(:order_response) { ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'order' => order }) }
  let(:transaction_response) { ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'transactions' => transactions }) }

  before do
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).with(hook).and_return(client)
    allow(client).to receive(:get).with(path: 'orders/1001', query: { fields: described_class::ORDER_FIELDS }).and_return(order_response)
    allow(client).to receive(:get).with(path: 'orders/1001/transactions',
                                        query: { in_shop_currency: true,
                                                 fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS }).and_return(transaction_response)
  end

  it 'preserves the difference between absent checkout evidence and an explicitly null checkout' do
    expect(report[:rows].sole[:order_source]).to eq({})
    order.merge!('checkout_id' => nil, 'source_name' => 'shopify_draft_order')
    expect(service.perform[:rows].sole[:order_source]).to eq('checkout_id' => nil, 'source_name' => 'shopify_draft_order')
  end

  it 'distinguishes operator-confirmed attribution from a storefront link' do
    conversation = create(:conversation, account: account)
    Umi::ShopifyOrderAttribution.create!(account_id: account.id, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                         source: 'operator', attribution_state: 'verified', conversation_id: conversation.id,
                                         contact_id: conversation.contact_id)

    expect(report[:rows].sole).to include(conversation_id: conversation.id, attribution_source: 'operator')
  end

  it 'keeps only a positive Shopify customer ID from the private customer object' do
    order['customer'] = { 'id' => 321, 'email' => 'private@example.test', 'first_name' => 'Private' }
    row = report[:rows].sole
    expect(row[:shopify_customer_id]).to eq('321')
    expect(row.to_json).not_to include('private@example.test', 'Private', 'first_name')
  end

  it 'retains only numeric basket identifiers and observed amounts for paid orders' do
    order.merge!('line_items' => [{ 'id' => 5, 'variant_id' => 7, 'current_quantity' => 2, 'title' => 'Private product text' }],
                 'current_subtotal_price' => '4000.00', 'current_total_discounts' => '100.00', 'current_total_tax' => '491.00',
                 'total_shipping_price_set' => { 'shop_money' => { 'amount' => '0.00', 'currency_code' => 'THB' } })
    expect(report[:rows].sole[:paid_basket]).to eq('items' => [{ 'id' => 5, 'variant_id' => 7, 'current_quantity' => 2 }],
                                                   'current_subtotal_price' => '4000.0', 'current_total_discounts' => '100.0',
                                                   'current_total_tax' => '491.0', 'shipping' => '0.0')
  end

  it 'reports pickup payment eighteen days after reservation using the successful transaction time' do
    transactions.unshift(sale.merge('id' => 2000, 'status' => 'pending', 'processed_at' => order['created_at']))

    expect(report[:rows].sole).to include(classification: 'paid', original_order_value: '4491.0', current_order_value: '4491.0',
                                          captured: '4491.0', refunded: '0.0', net_cash: '4491.0',
                                          order_created_at: '2026-09-01T03:00:00Z', last_payment_at: '2026-09-19T03:00:00Z')
    expect(report[:totals_by_currency]['THB']).to include(paid_orders: 1, paid_value: '4491.0', captured: '4491.0')
  end

  it 'does not turn a voided TBYB reservation and pending deposit into a sale' do
    order.merge!('financial_status' => 'voided', 'total_price' => '7980.00', 'current_total_price' => '0.00')
    transactions.replace([sale.merge('status' => 'pending', 'amount' => '3990.00'),
                          sale.merge('id' => 2002, 'kind' => 'void', 'amount' => '0.00')])

    expect(report[:rows].sole).to include(classification: 'no_sale', original_order_value: '7980.0', current_order_value: '0.0',
                                          captured: '0.0', last_payment_at: nil)
    expect(report[:totals_by_currency]['THB']).to include(paid_orders: 0, paid_value: '0.0')
  end

  it 'uses the final kept basket rather than the original fitting reservation' do
    order.merge!('total_price' => '12000.00', 'current_total_price' => '4000.00')
    sale['amount'] = '4000.00'

    expect(report[:rows].sole).to include(classification: 'paid', original_order_value: '12000.0', current_order_value: '4000.0')
    expect(report[:totals_by_currency]['THB'][:paid_value]).to eq('4000.0')
  end

  it 'counts captures once without adding their authorizations, pending attempts or failures' do
    sale['kind'] = 'capture'
    transactions.push(sale.merge('id' => 2002, 'kind' => 'authorization'), sale.merge('id' => 2003, 'status' => 'failure'),
                      sale.merge('id' => 2004, 'status' => 'pending'))

    expect(report[:rows].sole).to include(classification: 'paid', captured: '4491.0')
  end

  it 're-reads a pending order on a later invocation of the same service' do
    order['financial_status'] = 'pending'
    sale['status'] = 'pending'
    expect(service.perform[:rows].sole).to include(classification: 'unpaid', captured: '0.0')
    order['financial_status'] = 'paid'
    sale['status'] = 'success'
    expect(service.perform[:rows].sole).to include(classification: 'paid', captured: '4491.0')
    expect(client).to have_received(:get).with(path: 'orders/1001/transactions',
                                               query: { in_shop_currency: true,
                                                        fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS }).twice
  end

  %w[pending authorized partially_paid].each do |status|
    it "shows a #{status} deposit as cash without counting a paid sale" do
      order['financial_status'] = status
      sale['amount'] = '1000.00'

      expect(report[:rows].sole).to include(classification: 'partial_payment', captured: '1000.0')
      expect(report[:totals_by_currency]['THB']).to include(paid_orders: 0, paid_value: '0.0', net_cash: '1000.0')
    end
  end

  it 'reconciles a full successful refund even for a cancelled order' do
    order.merge!('financial_status' => 'refunded', 'cancelled_at' => '2026-09-20T10:00:00+07:00')
    transactions << sale.merge('id' => 2002, 'kind' => 'refund')

    expect(report[:rows].sole).to include(classification: 'refunded', refunded: '4491.0', net_cash: '0.0')
    expect(report[:totals_by_currency]['THB']).to include(paid_orders: 0, captured: '4491.0', refunded: '4491.0')
  end

  it 'reports partial refunds as observed cash without reconstructing the paid basket' do
    order.merge!('financial_status' => 'partially_refunded', 'current_total_price' => '2000.00')
    transactions << sale.merge('id' => 2002, 'kind' => 'refund', 'amount' => '1000.00')

    expect(report[:rows].sole).to include(classification: 'partially_refunded', refunded: '1000.0', net_cash: '3491.0')
    expect(report[:totals_by_currency]['THB'][:paid_value]).to eq('0.0')
  end

  it 'keeps pending refunds out of actual cash while requesting review' do
    transactions << sale.merge('id' => 2002, 'kind' => 'refund', 'status' => 'pending')

    expect(report[:rows].sole).to include(classification: 'needs_review', refunded: '0.0', net_cash: '4491.0',
                                          review_reasons: include('pending_refund'))
    expect(report[:totals_by_currency]).to be_empty
  end

  it 'counts test orders only in their own classification' do
    order['test'] = true

    expect(report[:rows].sole[:classification]).to eq('test_order')
    expect(report[:counts]).to eq('test_order' => 1)
    expect(report[:totals_by_currency]).to be_empty
  end

  it 'recognizes free orders with no movement as no sale' do
    order.merge!('total_price' => '0.00', 'current_total_price' => '0.00')
    transactions.clear

    expect(report[:rows].sole).to include(classification: 'no_sale', captured: '0.0')
  end

  [nil, '', 'garbage', 'NaN', 'Infinity', '-1.00'].each do |amount|
    it "leaves invalid captured money #{amount.inspect} unknown and excluded" do
      sale['amount'] = amount

      expect(report[:rows].sole).to include(classification: 'needs_review', captured: nil, net_cash: nil,
                                            review_reasons: include('invalid_transaction_amount'))
      expect(report[:totals_by_currency]).to be_empty
    end
  end

  %w[total_price current_total_price].each do |field|
    it "does not substitute for missing #{field}" do
      order.delete(field)

      expect(report[:rows].sole).to include(classification: 'needs_review', review_reasons: include("invalid_#{field}"))
      expect(report[:totals_by_currency]).to be_empty
    end
  end

  [nil, '', 'not-time'].each do |time|
    it "does not infer successful payment time from #{time.inspect}" do
      sale['processed_at'] = time

      expect(report[:rows].sole).to include(classification: 'needs_review', last_payment_at: nil,
                                            review_reasons: include('invalid_transaction_time'))
    end
  end

  it 'selects the latest payment timestamp by instant rather than transaction order' do
    sale['amount'] = '2000.00'
    transactions << sale.merge('id' => 2002, 'amount' => '2491.00', 'processed_at' => '2026-09-18T23:00:00-05:00')

    expect(report[:rows].sole[:last_payment_at]).to eq('2026-09-19T04:00:00Z')
  end

  [nil, '', 'invalid'].each do |currency|
    it "requests review for unknown currency #{currency.inspect}" do
      order['currency'] = currency

      expect(report[:rows].sole).to include(classification: 'needs_review', review_reasons: include('unknown_currency'))
      expect(report[:totals_by_currency]).to be_empty
    end
  end

  it 'does not combine mismatched transaction and order currencies' do
    sale['currency'] = 'USD'

    expect(report[:rows].sole).to include(classification: 'needs_review', captured: nil, net_cash: nil,
                                          review_reasons: include('transaction_currency_mismatch'))
    expect(report[:totals_by_currency]).to be_empty
  end

  it 'requests review for nonzero cash rounding without inventing rounding rules' do
    sale['amount_rounding'] = '0.01'

    expect(report[:rows].sole).to include(classification: 'needs_review', review_reasons: include('nonzero_cash_rounding'))
  end

  it 'does not count duplicated transactions twice' do
    transactions << sale.dup

    expect(report[:rows].sole).to include(classification: 'needs_review', captured: nil,
                                          review_reasons: include('duplicate_transaction_id'))
  end

  [
    [{ 'financial_status' => 'paid' }, '4000.00'],
    [{ 'financial_status' => 'pending' }, '4491.00'],
    [{ 'financial_status' => 'refunded' }, '4491.00'],
    [{ 'financial_status' => 'partially_refunded' }, '4491.00'],
    [{ 'financial_status' => 'voided' }, '4491.00'],
    [{ 'financial_status' => 'mystery' }, '4491.00'],
    [{ 'current_total_price' => '0.00' }, '4491.00'],
    [{ 'cancelled_at' => '2026-09-20T03:00:00Z' }, '4491.00']
  ].each do |attributes, captured|
    it "requests review for inconsistent order state #{attributes.inspect}" do
      order.merge!(attributes)
      sale['amount'] = captured

      expect(report[:rows].sole[:classification]).to eq('needs_review')
      expect(report[:rows].sole[:review_reasons]).not_to be_empty
      expect(report[:totals_by_currency]).to be_empty
    end
  end

  %w[refunded partially_refunded].each do |status|
    it "requests review when a #{status} zero-value order has no successful money movement" do
      order.merge!('financial_status' => status, 'current_total_price' => '0.00')
      transactions.clear

      expect(report[:rows].sole).to include(classification: 'needs_review', review_reasons: include('refund_status_mismatch'))
      expect(report[:totals_by_currency]).to be_empty
    end
  end

  it 'requests review when a cancelled positive-value paid order has no successful capture' do
    order['cancelled_at'] = '2026-09-20T03:00:00Z'
    transactions.clear

    expect(report[:rows].sole).to include(classification: 'needs_review', review_reasons: include('payment_status_mismatch'))
    expect(report[:totals_by_currency]).to be_empty
  end

  it 'deduplicates requested IDs before reading or counting them' do
    result = described_class.new(account_id: account.id.to_s, order_ids: %w[1001 1001]).perform

    expect(result[:rows].size).to eq(1)
    expect(result[:counts]).to eq('paid' => 1)
    expect(client).to have_received(:get).with(path: 'orders/1001/transactions',
                                               query: { in_shop_currency: true,
                                                        fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS }).once
  end

  [nil, 0, -1, '1oops', '1.2'].each do |account_id|
    it "rejects invalid account ID #{account_id.inspect} before an API call" do
      expect { described_class.new(account_id: account_id, order_ids: ['1001']).perform }.to raise_error(ArgumentError)
      expect(client).not_to have_received(:get)
    end
  end

  [nil, [], [''], ['0'], ['-1'], ['1.2'], ['1oops'], (1..51).to_a].each do |ids|
    it "rejects invalid order IDs #{ids.inspect} before an API call" do
      expect { described_class.new(account_id: account.id, order_ids: ids).perform }.to raise_error(ArgumentError)
      expect(client).not_to have_received(:get)
    end
  end

  it 'fails loudly when the integration is disabled' do
    hook.update!(status: :disabled)

    expect { report }.to raise_error(ActiveRecord::RecordNotFound)
    expect(client).not_to have_received(:get)
  end

  it 'fails loudly if multiple enabled integrations exist' do
    duplicate = hook.dup
    duplicate.save!(validate: false)

    expect { report }.to raise_error(ActiveRecord::SoleRecordExceeded)
    expect(client).not_to have_received(:get)
  end

  it 'propagates an API failure without retrying' do
    allow(client).to receive(:get).with(path: 'orders/1001/transactions',
                                        query: { in_shop_currency: true,
                                                 fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS }).and_raise(Timeout::Error)

    expect { report }.to raise_error(Timeout::Error)
    expect(client).to have_received(:get).with(path: 'orders/1001/transactions',
                                               query: { in_shop_currency: true,
                                                        fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS }).once
  end

  it 'rejects an unexpectedly partial transaction response' do
    allow(transaction_response).to receive(:next_page_info).and_return('next-page')

    expect { report }.to raise_error(described_class::IncompleteTransactions)
  end

  it 'never serializes customer, receipt, authorization or token data' do
    order.merge!('customer' => { 'email' => 'private@example.com' }, 'note_attributes' => [{ 'value' => 'secret-token' }])
    sale.merge!('receipt' => { 'card_number' => 'secret-card' }, 'authorization' => 'secret-authorization')

    expect(report.to_json).not_to match(/private@example|secret-token|secret-card|secret-authorization/)
    expect(report).to include(account_id: account.id, shop_domain: hook.reference_id,
                              observed_started_at: be_present, observed_finished_at: be_present)
  end

  context 'with an existing attribution' do
    let(:contact) { create(:contact, account: account) }
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let!(:attribution) do
      Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001',
                                           attribution_state: 'verified', conversation_id: conversation.id, contact_id: contact.id,
                                           candidate_conversation_id: conversation.id, candidate_contact_id: contact.id,
                                           token_nonce: 'synthetic-nonce')
    end

    it 'reads a verified link without mutating attribution records' do
      expect { report }.not_to(change { attribution.reload.attributes })
      expect(report[:rows].sole[:conversation_id]).to eq(conversation.id)
    end

    [{ attribution_state: 'unverified' }, { redacted_at: Time.current }, { shop_domain: 'other.myshopify.com' }].each do |attributes|
      it "leaves attribution unknown for #{attributes.keys.join(', ')}" do
        attribution.update!(attributes)

        expect(report[:rows].sole[:conversation_id]).to be_nil
      end
    end

    it 'does not use another account attribution' do
      attribution.update!(account: create(:account))

      expect(report[:rows].sole[:conversation_id]).to be_nil
    end
  end

  it 'leaves absent attribution unknown' do
    expect(report[:rows].sole[:conversation_id]).to be_nil
    expect(Umi::ShopifyOrderAttribution.count).to eq(0)
  end
end
