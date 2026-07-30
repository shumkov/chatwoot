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

    context 'when the article is featured' do
      let(:attrs) { super().merge('featured' => true, 'featured_position' => 20) }

      it 'appends the `featured` tag alongside the category tag' do
        expect(payload[:tags]).to eq('Returns & Exchanges, featured')
      end

      it 'sets the custom.featured_position metafield' do
        mf = payload[:metafields].find { |m| m[:key] == 'featured_position' }
        expect(mf).to include(namespace: 'custom', type: 'number_integer', value: '20')
      end
    end

    # Un-featuring drops the `featured` tag from the payload; since Shopify overwrites
    # the whole tag string on PUT, the tag-filtered Explore FAQ excludes the article on
    # the next sync — no metafield delete needed (the stale featured_position is inert).
    context 'when the article is no longer featured' do
      let(:attrs) { super().merge('featured' => false, 'featured_position' => nil) }

      it 'omits the `featured` tag, keeping only the category' do
        expect(payload[:tags]).to eq('Returns & Exchanges')
        expect(payload[:tags]).not_to include('featured')
      end

      it 'omits the featured_position metafield' do
        keys = payload[:metafields].map { |m| "#{m[:namespace]}.#{m[:key]}" }
        expect(keys).not_to include('custom.featured_position')
      end
    end

    # Shopify rejects the whole article with a 422 ("must be a single line text
    # string") when any single_line_text_field carries a line break, so an article
    # whose description is a markdown list can never sync.
    context 'when the description spans multiple lines' do
      let(:attrs) do
        super().merge(
          'description' => "- Within 14 days of delivery\n\n- Unworn, with tags attached\n\n- Refund to original payment"
        )
      end

      it 'sends a single-line description_tag' do
        mf = payload[:metafields].find { |m| m[:key] == 'description_tag' }
        expect(mf[:value]).not_to include("\n")
        expect(mf[:value]).to eq('- Within 14 days of delivery - Unworn, with tags attached - Refund to original payment')
      end
    end

    # The single-line guarantee is a property of the type, not of any one field, so it
    # holds for every value declared single_line_text_field however the source is shaped.
    context 'when several source fields span multiple lines' do
      let(:attrs) do
        super().merge('title' => "Returns\r\nPolicy", 'description' => "a\u2028b", 'slug' => "s\nlug")
      end

      it 'emits no line separator of any kind in a single_line_text_field' do
        values = payload[:metafields].select { |m| m[:type] == 'single_line_text_field' }.map { |m| m[:value] }

        expect(values.size).to be >= 3
        expect(values).to all(match(/\A[^\n\r\u2028\u2029]*\z/))
      end
    end

    # A description pasted from a word processor carries separators outside the ASCII
    # \s class, which a strip- or \s-based collapse would leave embedded in the value.
    context 'when the description carries unicode separators' do
      let(:attrs) { super().merge('description' => "Ship\u2028fast\u00A0and safe") }

      it 'collapses unicode whitespace too' do
        mf = payload[:metafields].find { |m| m[:key] == 'description_tag' }
        expect(mf[:value]).to eq('Ship fast and safe')
      end
    end

    context 'when the title spans multiple lines' do
      let(:attrs) { super().merge('title' => "Returns\n& Exchanges") }

      it 'sends a single-line title_tag' do
        mf = payload[:metafields].find { |m| m[:key] == 'title_tag' }
        expect(mf[:value]).to eq('Returns & Exchanges')
      end
    end

    # Normalization has to run before the 320-char cut, otherwise collapsing a run of
    # whitespace that straddles the boundary yields a different (shorter) string than
    # the same text collapsed first.
    context 'when a whitespace run straddles the 320-character limit' do
      let(:attrs) { super().merge('description' => "#{'a' * 315}\n\n\n\n\n#{'b' * 40}") }

      it 'collapses first, then truncates to 320' do
        mf = payload[:metafields].find { |m| m[:key] == 'description_tag' }
        expect(mf[:value].length).to eq(320)
        expect(mf[:value]).to eq("#{'a' * 315} #{'b' * 4}")
      end
    end

    # Shopify treats `tags` as a comma-separated list, so a comma inside a category
    # name silently becomes two tags and the real category never matches.
    context 'when the category name contains a comma' do
      let(:attrs) { super().merge('category_name' => 'Wholesale, Press & Influencers') }

      it 'sends the category as one tag, not two' do
        expect(payload[:tags].split(',').map(&:strip)).to eq(['Wholesale Press & Influencers'])
      end

      context 'when the comma has no space after it' do
        let(:attrs) { super().merge('category_name' => 'Wholesale,Press') }

        it 'keeps the words separated rather than running them together' do
          expect(payload[:tags]).to eq('Wholesale Press')
        end
      end
    end
  end

  # The Context.setup serialization (Zeitwerk-reload race) moved to the shared
  # Umi::Shopify::ClientFactory with the client construction; its concurrency
  # examples live in spec/services/umi/shopify/client_factory_spec.rb.
  describe '#client' do
    let(:service) { described_class.new('account_id' => 1) }
    let(:hook) { instance_double(Integrations::Hook, reference_id: 'shop.myshopify.com', access_token: 'token') }

    it 'builds the client through the shared factory' do
      client = instance_double(ShopifyAPI::Clients::Rest::Admin)
      allow(service).to receive(:hook).and_return(hook)
      allow(Umi::Shopify::ClientFactory).to receive(:client_for).with(hook).and_return(client)

      expect(service.send(:client)).to eq(client)
    end
  end
end
