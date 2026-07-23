require 'rails_helper'

describe Umi::Fbig::HistoryImportLock do
  let(:channel_id) { 42 }
  let(:key) { described_class.key(channel_id) }

  after { Redis::Alfred.delete(key) }

  it 'allows one owner and rejects a concurrent owner' do
    expect(described_class.acquire(channel_id, 'run-1', ttl: 60)).to be_truthy
    expect(described_class.acquire(channel_id, 'run-2', ttl: 60)).to be_falsey
    expect(Redis::Alfred.get(key)).to eq('run-1')
  end

  it 'renews only the current owner lease' do
    described_class.acquire(channel_id, 'run-1', ttl: 60)

    expect(described_class.renew(channel_id, 'run-1', ttl: 120)).to be true
    expect(Redis::Alfred.ttl(key)).to be_between(1, 120)
    expect(described_class.renew(channel_id, 'run-2', ttl: 180)).to be false
    expect(Redis::Alfred.get(key)).to eq('run-1')
    expect(Redis::Alfred.ttl(key)).to be <= 120
  end

  it 'releases only the current owner lease' do
    described_class.acquire(channel_id, 'run-1', ttl: 60)

    described_class.release(channel_id, 'run-2')
    expect(Redis::Alfred.get(key)).to eq('run-1')

    described_class.release(channel_id, 'run-1')
    expect(Redis::Alfred.get(key)).to be_nil
  end
end
