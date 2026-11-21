# frozen_string_literal: true

require 'rails_helper'

# Two writers binding the same Shopify customer at the same moment must not
# both succeed: the check and the write of each run under one per-customer
# lock, so the second writer sees the first one's binding and stands down.
RSpec.describe 'Concurrent Shopify customer binding' do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false

  let(:shopify_customer) { { 'id' => 42, 'email' => 'buyer@example.com', 'first_name' => 'Buyer', 'updated_at' => '2026-11-22T00:00:00Z' } }

  # Keep both sessions and their synchronization visible in one example each.
  [
    ['a sync create', ->(_account) {}],
    ['a sync enrich of another contact', ->(account) { Contact.create!(account: account, name: 'Buyer', email: 'buyer@example.com') }]
  ].each do |label, prepare|
    it "binds the customer to exactly one contact when a panel link races #{label}" do
      account = create(:account)
      panel_contact = create(:contact, account: account)
      prepare.call(account)
      writing = Queue.new
      release = Queue.new
      allow(panel_contact).to receive(:update!).and_wrap_original do |original, *args, &block|
        writing << true
        release.pop
        original.call(*args, &block)
      end

      panel = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Umi::Shopify::ManualLinkService.link_customer(panel_contact, { 'id' => '42' })
        end
      end
      Timeout.timeout(10) { writing.pop }

      sync_pid = Queue.new
      sync = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          sync_pid << connection.select_value('SELECT pg_backend_pid()')
          Umi::Shopify::ContactSyncService.new(account: account, customers: [shopify_customer], mode: :per_record).perform
        end
      end
      pid = Timeout.timeout(10) { sync_pid.pop }
      Timeout.timeout(10) do
        while sync.alive?
          break if ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{pid.to_i}")

          sleep 0.01
        end
      end
      release << true
      counters = Timeout.timeout(10) { sync.value }
      Timeout.timeout(10) { panel.value }

      bound = Contact.where(account_id: account.id).where("additional_attributes ->> 'shopify_customer_id' = '42'").pluck(:id)
      expect(bound).to eq([panel_contact.id])
      expect(counters[:bound_elsewhere]).to eq(1)
    ensure
      release << true if release
      [panel, sync].compact.each { |thread| thread.join(10) }
      perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
        account&.contacts&.destroy_all
        account&.destroy!
      end
    end
  end
end
