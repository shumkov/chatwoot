require 'rails_helper'

describe Umi::Fbig::HistoryImportGraphClient do
  let(:channel) { instance_double(Channel::FacebookPage, page_id: 'page-1', page_access_token: 'token') }
  let(:api) { double }
  let(:sleeper) { class_double(Kernel, sleep: nil) }
  let(:random) { class_double(Random, rand: 0.5) }
  let(:client) do
    described_class.new(channel, delay_ms: 0, max_conversation_pages: 2, max_message_pages: 2,
                                 sleeper: sleeper, random: random)
  end
  let(:page_class) do
    Class.new(Array) do
      attr_accessor :paging, :next_page_result

      def next_page
        next_page_result
      end
    end
  end

  before do
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
  end

  def page(items, next_url: nil)
    page_class.new(items).tap do |result|
      result.paging = next_url ? { 'next' => next_url } : {}
    end
  end

  it 'exhausts conversation pages with participants in the field set' do
    first = page([{ 'id' => 'thread-1' }], next_url: 'https://graph.facebook.com/next?after=secret')
    second = page([{ 'id' => 'thread-2' }])
    first.next_page_result = second
    allow(api).to receive(:get_connections)
      .with('page-1', 'conversations',
            { platform: 'messenger', fields: 'id,updated_time,participants', limit: 50 })
      .and_return(first)

    yielded = []
    pages = client.each_thread('messenger') { |thread| yielded << thread['id'] }

    expect(yielded).to eq(%w[thread-1 thread-2])
    expect(pages).to eq(2)
  end

  it 'returns every message and the number of pages read' do
    first = page([{ 'id' => 'mid-1' }], next_url: 'https://graph.facebook.com/next?after=one')
    second = page([{ 'id' => 'mid-2' }])
    first.next_page_result = second
    allow(api).to receive(:get_connections)
      .with('thread-1', 'messages', { fields: 'id,created_time,from', limit: 50 })
      .and_return(first)

    result = client.messages('thread-1')

    expect(result.items.pluck('id')).to eq(%w[mid-1 mid-2])
    expect(result.pages).to eq(2)
  end

  it 'fails loudly without exposing a repeated cursor' do
    first = page([], next_url: 'https://graph.facebook.com/next?after=secret')
    second = page([], next_url: 'https://graph.facebook.com/next?after=secret')
    first.next_page_result = second
    allow(api).to receive(:get_connections).and_return(first)

    expect { client.messages('thread-1') }.to raise_error(described_class::PaginationError) do |error|
      expect(error.message).to include('repeated message cursor')
      expect(error.message).not_to include('secret')
    end
  end

  it 'fails loudly when unread pages exceed the ceiling' do
    first = page([], next_url: 'https://graph.facebook.com/next?after=one')
    second = page([], next_url: 'https://graph.facebook.com/next?after=two')
    first.next_page_result = second
    allow(api).to receive(:get_connections).and_return(first)

    expect { client.messages('thread-1') }
      .to raise_error(described_class::PaginationError, /message page ceiling reached/)
  end

  it 'retries server failures with bounded backoff' do
    attempts = 0
    allow(api).to receive(:get_object) do
      attempts += 1
      raise Koala::Facebook::ServerError.new(500, '') if attempts < 3

      { 'id' => 'mid-1' }
    end

    expect(client.detail('mid-1')).to eq('id' => 'mid-1')
    expect(api).to have_received(:get_object).exactly(3).times
    expect(random).to have_received(:rand).twice
  end

  it 'does not retry authentication failures' do
    allow(api).to receive(:get_object)
      .and_raise(Koala::Facebook::AuthenticationError.new(401, 'bad token'))

    expect { client.detail('mid-1') }.to raise_error(described_class::AuthenticationError)
    expect(api).to have_received(:get_object).once
  end

  it 'classifies exhausted rate-limit retries without exposing the response' do
    allow(api).to receive(:get_object)
      .and_raise(Koala::Facebook::ClientError.new(429, 'secret response', { 'code' => 613, 'message' => 'secret' }))

    expect { client.detail('mid-1') }.to raise_error(described_class::RequestError) do |error|
      expect(error.reason).to eq(:rate_limit)
      expect(error.message).not_to include('secret')
    end
    expect(api).to have_received(:get_object).exactly(3).times
  end

  it 'returns nil for permanently unavailable detail' do
    allow(api).to receive(:get_object)
      .and_raise(Koala::Facebook::ClientError.new(400, '', { 'code' => 100, 'message' => 'unavailable' }))

    expect(client.detail('mid-1')).to be_nil
  end
end
