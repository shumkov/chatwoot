# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::OrderLinkTokenService do
  let(:storage) { {} }

  before do
    allow(Redis::Alfred).to receive(:set) do |key, value, **options|
      next false if options[:nx] && storage.key?(key)

      storage[key] = value
      true
    end
    allow(Redis::Alfred).to receive(:get) { |key| storage[key] }
    allow(Redis::Alfred).to receive(:delete) { |key| storage.delete(key) }
    allow(Redis::Alfred).to receive(:with) do |&block|
      store = storage
      redis = Object.new
      redis.define_singleton_method(:getdel) do |namespaced_key|
        store.delete(namespaced_key.split(':', 2).last)
      end
      connection = Struct.new(:full_namespace, :redis).new('test', redis)
      block.call(connection)
    end
  end

  it 'signs a claim and allows exactly one atomic consume' do
    token = described_class.mint(account_id: 1, conversation_id: 2, contact_id: 3)
    claim = described_class.peek(token)

    expect(claim).to include('account_id' => 1, 'conversation_id' => 2, 'contact_id' => 3)
    expect(described_class.consume(claim)).to be(true)
    expect { described_class.peek(token) }.to raise_error(described_class::Replay)
  end

  it 'can restore a claim after a transient database failure' do
    token = described_class.mint(account_id: 1, conversation_id: 2, contact_id: 3)
    claim = described_class.peek(token)
    described_class.consume(claim)

    described_class.restore(claim)

    expect(described_class.peek(token)).to include('nonce' => claim['nonce'])
  end

  it 'does not overwrite a live claim while restoring' do
    token = described_class.mint(account_id: 1, conversation_id: 2, contact_id: 3)
    claim = described_class.peek(token)
    described_class.consume(claim)
    storage[described_class.claim_key(claim['nonce'])] = 'live-claim'

    expect(described_class.restore(claim)).to be(false)
    expect(storage[described_class.claim_key(claim['nonce'])]).to eq('live-claim')
  end

  it 'discards a minted claim when the message rewrite is not applied' do
    token = described_class.mint(account_id: 1, conversation_id: 2, contact_id: 3)

    expect(described_class.discard(token)).to be(true)
    expect { described_class.peek(token) }.to raise_error(described_class::Replay)
  end
end
