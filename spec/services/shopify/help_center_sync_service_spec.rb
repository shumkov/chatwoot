# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shopify::HelpCenterSyncService do
  describe '.slugify' do
    it 'lowercases, strips punctuation, and dashes spaces' do
      expect(described_class.slugify('How do I place an order?')).to eq('how-do-i-place-an-order')
      expect(described_class.slugify('Returns & Exchanges')).to eq('returns-exchanges')
    end
  end

  describe '#article_payload' do
    let(:attrs) do
      {
        'event' => 'upserted', 'id' => 23, 'title' => 'Returns & Exchanges',
        'content' => 'You can **return** items within *14 days*.',
        'description' => 'Returns basics', 'slug' => 'returns-5-1b',
        'status' => 'published', 'position' => 2,
        'category_name' => 'Returns & Exchanges', 'category_slug' => 'returns'
      }
    end
    subject(:payload) { described_class.new(attrs).article_payload(published: true) }

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
  end
end
