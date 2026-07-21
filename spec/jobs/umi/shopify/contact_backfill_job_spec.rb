# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ContactBackfillJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, settings: { 'scope' => 'read_customers,read_orders' }) }
  let(:run_id) { 'run-1' }
  let(:run_started_at) { '2026-07-21T00:00:00Z' }
  let(:client) { instance_double(ShopifyAPI::Clients::Rest::Admin) }

  def page_response(customers, next_page_info: nil)
    instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'customers' => customers }, next_page_info: next_page_info)
  end

  def count_response(count)
    instance_double(ShopifyAPI::Clients::HttpResponse, body: { 'count' => count })
  end

  def customer(id, email)
    { 'id' => id, 'email' => email, 'first_name' => 'C', 'updated_at' => '2026-07-01T00:00:00Z' }
  end

  before do
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).and_return(client)
    Umi::Shopify::SyncLock.acquire(account.id, run_id, ttl: 60)
  end

  after { Redis::Alfred.delete(Umi::Shopify::SyncLock.key(account.id)) }

  it 'syncs a page and self-enqueues the next cursor' do
    allow(client).to receive(:get).with(path: 'customers/count.json').and_return(count_response(300))
    allow(client).to receive(:get).with(path: 'customers.json', query: { limit: 250 })
                                  .and_return(page_response([customer(1, 'a@example.com')], next_page_info: 'cursor-2'))

    expect do
      described_class.perform_now(account.id, run_id, run_started_at)
    end.to have_enqueued_job(described_class).with(account.id, run_id, run_started_at, 'cursor-2')

    expect(account.contacts.from_email('a@example.com')).to be_present
    expect(hook.reload.settings['umi_contact_sync_watermark']).to be_nil # not the final page
  end

  it 'writes the watermark and releases the lock on the final page' do
    allow(client).to receive(:get).with(path: 'customers.json', query: { limit: 250, page_info: 'cursor-9' })
                                  .and_return(page_response([customer(2, 'b@example.com')]))

    described_class.perform_now(account.id, run_id, run_started_at, 'cursor-9')

    expect(hook.reload.settings['umi_contact_sync_watermark']).to eq(run_started_at)
    expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
  end

  it 'aborts before page one when the customer count exceeds the ceiling' do
    allow(client).to receive(:get).with(path: 'customers/count.json').and_return(count_response(50_000))

    with_modified_env UMI_SHOPIFY_CONTACT_SYNC_MAX_CUSTOMERS: '20000' do
      expect { described_class.perform_now(account.id, run_id, run_started_at) }
        .not_to have_enqueued_job(described_class)
    end

    expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
  end

  # The lock TTL expired and another run may own the account: the stale chain
  # must abort loudly, not interleave writes with the new owner.
  it 'aborts loudly when the lock is lost' do
    Redis::Alfred.delete(Umi::Shopify::SyncLock.key(account.id))
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

    expect { described_class.perform_now(account.id, run_id, run_started_at, 'cursor-3') }
      .not_to have_enqueued_job(described_class)

    expect(tracker).to have_received(:capture_exception)
  end

  context 'with shopify errors' do
    let(:http_error) do
      ShopifyAPI::Errors::HttpResponseError.new(
        response: ShopifyAPI::Clients::HttpResponse.new(code: code, headers: {}, body: '{}')
      )
    end

    before do
      allow(client).to receive(:get).with(path: 'customers.json', query: { limit: 250, page_info: 'cursor-3' })
                                    .and_raise(http_error)
    end

    context 'when transient (429)' do
      let(:code) { 429 }

      # The global Sidekiq retry cap (3) is far too short for a Shopify blip;
      # the chain carries its own retry_on with long backoff.
      it 'retries the same cursor via retry_on' do
        expect { described_class.perform_now(account.id, run_id, run_started_at, 'cursor-3') }
          .to have_enqueued_job(described_class).with(account.id, run_id, run_started_at, 'cursor-3')
      end

      it 'releases the lock and reports when retries are exhausted' do
        tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
        allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

        job = described_class.new(account.id, run_id, run_started_at, 'cursor-3')
        job.executions = 8
        # retry_on tracks attempts per exception class, not via the plain
        # executions counter.
        job.exception_executions = { '[Umi::Shopify::ContactBackfillJob::RetryableError]' => 8 }
        job.perform_now

        expect(tracker).to have_received(:capture_exception)
        expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
      end
    end

    context 'when permanent (401)' do
      let(:code) { 401 }

      it 'stops the chain loudly and releases the lock without retry' do
        tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
        allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

        expect { described_class.perform_now(account.id, run_id, run_started_at, 'cursor-3') }
          .not_to have_enqueued_job(described_class)

        expect(tracker).to have_received(:capture_exception)
        expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
      end
    end
  end

  # A chain that can never proceed must not strand the lock for the 6h TTL
  # (polls would skip as "lock held" the whole time) and must page.
  it 'aborts on a scope-lacking hook, releasing the lock and reporting' do
    hook.update!(settings: { 'scope' => 'read_orders' })
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

    expect(Umi::Shopify::ClientFactory).not_to receive(:client_for)
    described_class.perform_now(account.id, run_id, run_started_at)

    expect(tracker).to have_received(:capture_exception)
    expect(Redis::Alfred.get(Umi::Shopify::SyncLock.key(account.id))).to be_nil
  end

  # shopify_api does not wrap connection-level failures; they must ride the
  # same long-backoff retry as a 429, not fall through to Sidekiq's 3 retries.
  it 'retries transport-level errors via retry_on' do
    allow(client).to receive(:get).with(path: 'customers.json', query: { limit: 250, page_info: 'cursor-3' })
                                  .and_raise(SocketError, 'getaddrinfo failed')

    expect { described_class.perform_now(account.id, run_id, run_started_at, 'cursor-3') }
      .to have_enqueued_job(described_class).with(account.id, run_id, run_started_at, 'cursor-3')
  end
end
