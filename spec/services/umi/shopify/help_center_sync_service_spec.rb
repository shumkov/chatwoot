# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::HelpCenterSyncService do
  describe '.slugify' do
    it 'lowercases, strips punctuation, and dashes spaces' do
      expect(described_class.slugify('How do I place an order?')).to eq('how-do-i-place-an-order')
      expect(described_class.slugify('Returns & Exchanges')).to eq('returns-exchanges')
    end

    it 'trims leading and trailing dashes' do
      expect(described_class.slugify('- Note -')).to eq('note')
      expect(described_class.slugify('& Returns')).to eq('returns')
    end
  end

  describe '#article_payload' do
    subject(:payload) { described_class.new(attrs).article_payload(published: true) }

    let(:attrs) do
      {
        'event' => 'upserted', 'id' => 23, 'title' => 'Returns & Exchanges',
        'content' => 'You can **return** items within *14 days*.',
        'description' => 'Returns basics', 'slug' => 'returns-5-1b',
        'status' => 'published', 'position' => 2,
        'category_name' => 'Returns & Exchanges', 'category_slug' => 'returns'
      }
    end

    it 'maps title, handle, tags, and published flag' do
      expect(payload[:title]).to eq('Returns & Exchanges')
      expect(payload[:handle]).to eq('returns-exchanges')
      expect(payload[:tags]).to eq('Returns & Exchanges')
      expect(payload[:published]).to be(true)
    end

    it 'renders the body with Chatwoot’s own markdown renderer' do
      expect(payload[:body_html]).to include('<strong>return</strong>')
      expect(payload[:body_html]).to include('<em>14 days</em>')
    end

    it 'sets the chatwoot_id and SEO metafields' do
      keys = payload[:metafields].map { |m| "#{m[:namespace]}.#{m[:key]}" }
      expect(keys).to include('custom.chatwoot_id', 'custom.chatwoot_slug', 'global.title_tag')
      cw_id = payload[:metafields].find { |m| m[:key] == 'chatwoot_id' }
      expect(cw_id[:value]).to eq('23')
    end

    context 'when the article has no category' do
      let(:attrs) { super().merge('category_name' => nil, 'category_slug' => nil) }

      it 'sends an empty tag rather than a phantom default' do
        expect(payload[:tags]).to eq('')
      end

      it 'omits the chatwoot_category_slug metafield' do
        keys = payload[:metafields].map { |m| "#{m[:namespace]}.#{m[:key]}" }
        expect(keys).not_to include('custom.chatwoot_category_slug')
      end
    end

    context 'when the description is blank' do
      let(:attrs) { super().merge('description' => '', 'content' => "## Heading\n\nVisit <a href='x'>here</a> for **details**.") }

      it 'builds the summary from plain text with markup and HTML stripped' do
        expect(payload[:summary_html]).not_to include('<a ')
        expect(payload[:summary_html]).not_to include('##')
        expect(payload[:summary_html]).to include('Heading')
      end
    end
  end

  # ShopifyAPI::Context.setup reloads the gem's shared Zeitwerk loader on every
  # call, so two threads running it at once raced the loader and raised
  # Zeitwerk::SetupRequired. The client must serialize setup across threads.
  describe '#client Shopify context guard' do
    let(:service) { described_class.new('account_id' => 1) }
    let(:hook) { instance_double(Integrations::Hook, reference_id: 'shop.myshopify.com', access_token: 'token') }

    before do
      allow(service).to receive(:hook).and_return(hook)
      allow(ShopifyAPI::Context).to receive(:setup)
      allow(ShopifyAPI::Auth::Session).to receive(:new).and_return(instance_double(ShopifyAPI::Auth::Session))
      allow(ShopifyAPI::Clients::Rest::Admin).to receive(:new).and_return(instance_double(ShopifyAPI::Clients::Rest::Admin))
    end

    it 'configures the Shopify context before building the REST client' do
      expect(ShopifyAPI::Context).to receive(:setup)

      service.send(:client)
    end

    # Pins the mutex: many threads run setup at once. With the mutex, setup never
    # executes in two threads simultaneously (max concurrency 1); drop the
    # CONTEXT_SETUP_MUTEX and concurrent threads overlap inside setup, which is the
    # shared-loader reload race that raised Zeitwerk::SetupRequired.
    it 'never runs the global Context.setup concurrently' do
      lock = Mutex.new
      in_flight = 0
      max_in_flight = 0

      allow(ShopifyAPI::Context).to receive(:setup) do
        lock.synchronize do
          in_flight += 1
          max_in_flight = [max_in_flight, in_flight].max
        end
        sleep 0.01 # hold the "reload" open so an unguarded overlap is observable
        lock.synchronize { in_flight -= 1 }
      end

      Array.new(8) { described_class.new('account_id' => 1) }
           .map { |svc| Thread.new { svc.send(:ensure_shopify_context!) } }
           .each(&:join)

      expect(max_in_flight).to eq(1)
    end
  end
end
