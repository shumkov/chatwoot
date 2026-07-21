# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ContactSyncWatermark do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :shopify, account: account, settings: { 'scope' => 'read_customers' }) }
  let(:timestamp) { '2026-07-21T00:00:00Z' }

  describe '.write' do
    it 'merges the watermark into the freshly loaded hook settings' do
      expect(described_class.write(hook.id, timestamp)).to be(true)

      expect(hook.reload.settings['umi_contact_sync_watermark']).to eq(timestamp)
      expect(hook.settings['scope']).to eq('read_customers')
    end

    # An OAuth reconnect destroys and recreates the hook; update! on a stale
    # instance would silently update zero rows. The write must fail loud, and a
    # missing watermark means the poll refuses to run (backfill needed).
    it 'reports and returns false when the hook is gone' do
      hook_id = hook.id
      hook.destroy!

      tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)

      expect(described_class.write(hook_id, timestamp)).to be(false)
      expect(tracker).to have_received(:capture_exception)
    end
  end

  describe '.read' do
    it 'returns nil when never written' do
      expect(described_class.read(hook)).to be_nil
    end
  end
end
