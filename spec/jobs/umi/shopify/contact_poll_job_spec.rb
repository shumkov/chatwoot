# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ContactPollJob do
  let(:account) { create(:account) }
  let!(:hook) do
    create(:integrations_hook, :shopify, account: account,
                                         settings: { 'scope' => 'read_customers', 'umi_contact_sync_watermark' => watermark })
  end
  let(:watermark) { '2026-07-20T00:00:00Z' }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }

  def page_response(customers, next_page_info: nil)
    instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'customers' => customers }, next_page_info: next_page_info)
  end

  before { allow(Umi::Shopify::ClientFactory).to receive(:client_for).and_return(client) }

  after { Redis::Alfred.delete(Umi::Shopify::SyncLock.key(account.id)) }

  it 'fetches changes since the watermark (with overlap) and advances it to the run start' do
    expect(client).to receive(:get)
      .with(path: 'customers.json', query: { limit: 250, updated_at_min: '2026-07-19T23:55:00Z' })
      .and_return(page_response([{ 'id' => 1, 'email' => 'new@example.com', 'first_name' => 'N',
                                   'updated_at' => '2026-07-20T09:00:00Z' }]))

    described_class.perform_now

    expect(account.contacts.from_email('new@example.com')).to be_present
    new_watermark = hook.reload.settings['umi_contact_sync_watermark']
    expect(Time.zone.parse(new_watermark)).to be > Time.zone.parse(watermark)
    expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
  end

  # Cursor pages must carry ONLY page_info + limit — Shopify 400s when a filter
  # param rides along with a cursor.
  it 'omits updated_at_min on cursor pages' do
    expect(client).to receive(:get)
      .with(path: 'customers.json', query: { limit: 250, updated_at_min: '2026-07-19T23:55:00Z' })
      .and_return(page_response([], next_page_info: 'cursor-2'))
    expect(client).to receive(:get)
      .with(path: 'customers.json', query: { limit: 250, page_info: 'cursor-2' })
      .and_return(page_response([]))

    described_class.perform_now
  end

  context 'without a watermark' do
    let(:watermark) { nil }

    # The only symptom of a dead backfill chain or wiped settings — must stay
    # loud on every run.
    it 'error-logs and never calls Shopify (backfill needed, poll refuses to run from epoch)' do
      allow(Rails.logger).to receive(:error).and_call_original

      described_class.perform_now

      expect(Umi::Shopify::ClientFactory).not_to have_received(:client_for)
      expect(Rails.logger).to have_received(:error).with(/no watermark — backfill needed/)
    end
  end

  it 'skips disabled hooks' do
    hook.update!(status: :disabled)

    described_class.perform_now

    expect(Umi::Shopify::ClientFactory).not_to have_received(:client_for)
  end

  # A run that outlived its lock TTL lost ownership to a newer tick — its older
  # run_started_at must not regress the watermark the new run writes.
  it 'does not advance the watermark when the run outlived its lock' do
    allow(client).to receive(:get)
      .with(path: 'customers.json', query: { limit: 250, updated_at_min: '2026-07-19T23:55:00Z' })
      .and_return(page_response([]))
    allow(Umi::Shopify::SyncLock).to receive(:acquire).and_return(true)
    allow(Umi::Shopify::SyncLock).to receive(:held_by?).and_return(false)
    allow(Umi::Shopify::SyncLock).to receive(:release)

    described_class.perform_now

    expect(hook.reload.settings['umi_contact_sync_watermark']).to eq(watermark)
  end

  it 'skips the tick when the sync lock is held (backfill or previous poll running)' do
    Umi::Shopify::SyncLock.acquire(account.id, 'other-run', ttl: 60)

    described_class.perform_now

    expect(Umi::Shopify::ClientFactory).not_to have_received(:client_for)
    expect(hook.reload.settings['umi_contact_sync_watermark']).to eq(watermark)
  end

  it 'does not advance the watermark when a page fails, and reports' do
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
    allow(client).to receive(:get).and_raise(StandardError, 'boom')

    described_class.perform_now

    expect(hook.reload.settings['umi_contact_sync_watermark']).to eq(watermark)
    expect(tracker).to have_received(:capture_exception)
    expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
  end

  # A store-wide bulk edit bumps updated_at on the whole base; the poll must not
  # crawl it through the per-record path. Partial watermark advancement is
  # impossible (REST results are id-ordered), so the run aborts without advancing.
  it 'aborts without advancing when the page cap is exceeded' do
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
    allow(client).to receive(:get).and_return(page_response([], next_page_info: 'more'))

    with_modified_env UMI_SHOPIFY_CONTACT_SYNC_POLL_MAX_PAGES: '2' do
      described_class.perform_now
    end

    expect(client).to have_received(:get).at_most(3).times
    expect(hook.reload.settings['umi_contact_sync_watermark']).to eq(watermark)
    expect(tracker).to have_received(:capture_exception)
  end
end
