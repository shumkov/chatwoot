# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Rake::Task do
  subject(:task) { described_class['umi:funnel:paid_orders'] }

  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account) }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }
  let(:order) do
    { 'id' => 1001, 'created_at' => '2026-09-01T00:00:00Z', 'updated_at' => '2026-09-01T00:00:00Z',
      'financial_status' => 'pending', 'test' => false, 'currency' => 'THB', 'total_price' => '100.00', 'current_total_price' => '100.00' }
  end

  before do
    task.reenable
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).with(hook).and_return(client)
    allow(client).to receive(:get).with(path: 'orders/1001', query: { fields: Umi::Shopify::PaidOrderReport::ORDER_FIELDS })
                                  .and_return(ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'order' => order }))
    allow(client).to receive(:get).with(path: 'orders/1001/transactions',
                                        query: { in_shop_currency: true,
                                                 fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS })
                                  .and_return(ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'transactions' => [] }))
  end

  it 'prints completed JSON from the report service' do
    with_modified_env ACCOUNT_ID: account.id.to_s, ORDER_IDS: '1001,1001' do
      expect { task.invoke }.to output(satisfy { |output| JSON.parse(output)['counts'] == { 'unpaid' => 1 } }).to_stdout
    end
  end

  [{ ACCOUNT_ID: nil, ORDER_IDS: '1001' }, { ACCOUNT_ID: '1', ORDER_IDS: nil }, { ACCOUNT_ID: '1', ORDER_IDS: '1001,' }].each do |env|
    it "requires valid explicit arguments #{env.inspect}" do
      with_modified_env(**env) do
        expect { task.invoke }.to raise_error(ArgumentError)
      end
      expect(client).not_to have_received(:get)
    end
  end

  it 'prints no partial report when the API fails' do
    allow(client).to receive(:get).with(path: 'orders/1001/transactions',
                                        query: { in_shop_currency: true,
                                                 fields: Umi::Shopify::PaidOrderReport::TRANSACTION_FIELDS }).and_raise(Timeout::Error)

    with_modified_env ACCOUNT_ID: account.id.to_s, ORDER_IDS: '1001' do
      expect { expect { task.invoke }.to raise_error(Timeout::Error) }.not_to output.to_stdout
    end
  end
end
