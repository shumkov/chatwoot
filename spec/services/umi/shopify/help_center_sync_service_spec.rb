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
  # call, so running it per job across Sidekiq's concurrent threads raced the
  # loader and raised Zeitwerk::SetupRequired. The client must configure the
  # global context at most once per process.
  describe '#client Shopify context guard' do
    let(:service) { described_class.new('account_id' => 1) }
    let(:hook) { instance_double(Integrations::Hook, reference_id: 'shop.myshopify.com', access_token: 'token') }

    before do
      allow(service).to receive(:hook).and_return(hook)
      allow(ShopifyAPI::Auth::Session).to receive(:new).and_return(instance_double(ShopifyAPI::Auth::Session))
      allow(ShopifyAPI::Clients::Rest::Admin).to receive(:new).and_return(instance_double(ShopifyAPI::Clients::Rest::Admin))
    end

    it 'does not re-run the global Context.setup once it is already configured' do
      allow(ShopifyAPI::Context).to receive(:setup?).and_return(true)
      expect(ShopifyAPI::Context).not_to receive(:setup)

      service.send(:client)
    end

    it 'configures the context once when it is not yet set up' do
      allow(ShopifyAPI::Context).to receive(:setup?).and_return(false)
      expect(ShopifyAPI::Context).to receive(:setup).once

      service.send(:client)
    end

    # Pins the mutex, not just the branch: many threads race the first-time setup.
    # With the mutex, ShopifyAPI::Context.setup runs exactly once; without it,
    # concurrent threads all see setup? == false and re-run it, re-triggering the
    # shared-loader reload race.
    it 'runs the global Context.setup exactly once under concurrent first access' do
      configured = false
      count_lock = Mutex.new
      setup_calls = 0

      allow(ShopifyAPI::Context).to receive(:setup?) { configured }
      allow(ShopifyAPI::Context).to receive(:setup) do
        sleep 0.01 # widen the window so an unguarded reload would collide
        count_lock.synchronize { setup_calls += 1 }
        configured = true
      end

      Array.new(8) { described_class.new('account_id' => 1) }
           .map { |svc| Thread.new { svc.send(:ensure_shopify_context!) } }
           .each(&:join)

      expect(setup_calls).to eq(1)
    end
  end
end
