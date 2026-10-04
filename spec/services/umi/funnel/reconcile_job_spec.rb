# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::ReconcileJob do
  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      example.run
    end
  end

  it 'does not turn a terminal failed reconciliation into an endless periodic retry' do
    failed = Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '100')
    failed.update!(last_error: 'Timeout::Error')
    expect(Umi::Shopify::OrderFinancialReconcileJob).not_to receive(:perform_later)
    described_class.perform_now
  end

  it 'rearms a failed reconciliation only on a fresh notification or explicit request' do
    failed = Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '100')
    failed.update!(last_error: 'Timeout::Error')
    Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '100')
    expect(failed.reload.last_error).to be_nil
  end

  it 'schedules payments and deliveries before surfacing a classifier configuration failure' do
    state = Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: '100')
    allow(Umi::Funnel::ConversationClassifier).to receive(:enqueue).and_raise(KeyError)
    expect(Umi::Funnel::DeliveryAutomation).to receive(:enqueue)
    expect(Umi::Shopify::OrderFinancialReconcileJob).to receive(:perform_later).with(state.id)
    expect { described_class.perform_now }.to raise_error(KeyError)
  end

  it 'repairs a failed message callback from committed source messages' do
    allow(Umi::Funnel::EventRecorder).to receive(:capture_message).and_raise(StandardError)
    message = create(:message, account: account)
    expect(Umi::ConversationEvent.count).to eq(0)
    allow(Umi::Funnel::EventRecorder).to receive(:capture_message).and_call_original
    described_class.perform_now
    described_class.perform_now
    expect(Umi::ConversationEvent.where(occurrence_key: "message:#{message.id}").count).to eq(1)
  end

  it 'exhausts discovery pagination with a fixed updated-at window' do
    since = 2.days.ago.utc.iso8601
    client = instance_double(ShopifyAPI::Clients::Rest::Admin)
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).with(hook).and_return(client)
    first = instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'orders' => [{ 'id' => 10 }] }, next_page_info: 'page-two')
    second = instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'orders' => [{ 'id' => 20 }] }, next_page_info: nil)
    allow(client).to receive(:get).with(path: 'orders', query: hash_including(status: 'any', fields: 'id', updated_at_min: since))
                                  .and_return(first)
    allow(client).to receive(:get).with(path: 'orders', query: { page_info: 'page-two', limit: 250, fields: 'id' }).and_return(second)
    result = Umi::Funnel::OrderRecovery.perform(account_id: account.id, since: since)
    expect(result).to eq(requested: 2, completed_discovery: true)
    expect(Umi::ShopifyOrderFinancialState.pluck(:shopify_order_id)).to contain_exactly('10', '20')
  end

  it 'reports money separately from qualification counts without personal details' do
    conversation = create(:conversation, account: account)
    create(:message, account: account, conversation: conversation)
    result = Umi::Funnel::Report.perform(account_id: account.id, since: 1.day.ago)
    expect(result).to include(observed_conversations: 1, qualified_occurrences: 0, paid_occurrences: 0, current_cash_by_currency: {})
    expect(result.to_json).not_to include(conversation.contact.email)
  end

  it 'fails visibly on an incompatible sales status definition' do
    create(:custom_attribute_definition, account: account, attribute_key: 'umi_sales_status', attribute_display_type: :text)
    expect { Umi::Funnel::Configuration.provision!(account) }.to raise_error(ArgumentError, /Incompatible/)
  end

  it 'rejects malformed enabled configuration and requires an explicit observation boundary' do
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: '1,wat' do
      expect { Umi::Funnel::Configuration.account_ids }.to raise_error(ArgumentError)
    end
    with_modified_env UMI_FUNNEL_STARTED_AT: nil do
      expect { Umi::Funnel::Configuration.account_ids }.to raise_error(KeyError)
    end
  end

  it 'queues only due verified customers in oldest-attempt order without sending provider requests' do
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      old = create(:contact, account: account, additional_attributes: {
                     'umi_klaviyo_profile_id' => 'OLD', 'umi_klaviyo_binding' => { 'generation' => 'old' },
                     'umi_klaviyo_sync' => { 'checked_at' => 1.hour.ago.iso8601, 'next_sync_at' => 45.minutes.ago.iso8601 }
                   })
      new_contact = create(:contact, account: account, additional_attributes: {
                             'umi_klaviyo_profile_id' => 'NEW', 'umi_klaviyo_binding' => { 'generation' => 'new' }
                           })
      create(:contact, account: account, additional_attributes: {
               'umi_klaviyo_profile_id' => 'FRESH', 'umi_klaviyo_binding' => { 'generation' => 'fresh' },
               'umi_klaviyo_sync' => { 'next_sync_at' => 10.minutes.from_now.iso8601 }
             })
      clear_enqueued_jobs
      expect(Umi::Funnel::KlaviyoClient).not_to receive(:new)
      Umi::Funnel::ProfileSyncJob.enqueue_due
      jobs = enqueued_jobs.select { |job| job[:job] == Umi::Funnel::ProfileSyncJob }
      expect(jobs.map { |job| job[:args].first }).to eq([new_contact.id, old.id])
      expect(enqueued_jobs.count { |job| job[:job] == Umi::Funnel::SegmentRefreshJob }).to eq(1)
    end
  end
end
