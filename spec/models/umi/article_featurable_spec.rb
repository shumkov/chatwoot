# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::ArticleFeaturable do
  let(:portal) { create(:portal) }

  def article_with(meta)
    create(:article, portal: portal, meta: meta)
  end

  describe '.featured' do
    it 'matches a jsonb boolean true and the string "true", excluding false/absent' do
      bool_true = article_with('featured' => true, 'featured_position' => 10)
      str_true = article_with('featured' => 'true', 'featured_position' => 20)
      not_featured = article_with('featured' => false)
      absent = article_with({})

      ids = portal.articles.featured.pluck(:id)
      expect(ids).to contain_exactly(bool_true.id, str_true.id)
      expect(ids).not_to include(not_featured.id, absent.id)
    end
  end

  describe '.order_by_featured_position' do
    it 'orders by numeric position, not by insertion or id' do
      a30 = article_with('featured' => true, 'featured_position' => 30)
      a10 = article_with('featured' => true, 'featured_position' => 10)
      a20 = article_with('featured' => true, 'featured_position' => 20)

      expect(portal.articles.featured.order_by_featured_position.map(&:id)).to eq([a10.id, a20.id, a30.id])
    end

    # R2: a malformed or missing featured_position must sort last, never raise a
    # Postgres cast error that would 500 the shared public articles endpoint.
    it 'sorts malformed / missing positions last without raising a cast error' do
      good = article_with('featured' => true, 'featured_position' => 10)
      bad = article_with('featured' => true, 'featured_position' => 'oops')
      missing = article_with('featured' => true)

      result = nil
      expect { result = portal.articles.featured.order_by_featured_position.to_a }.not_to raise_error
      expect(result.first).to eq(good)
      expect(result.map(&:id)).to include(bad.id, missing.id)
    end

    it 'breaks ties on id deterministically' do
      first = article_with('featured' => true, 'featured_position' => 10)
      second = article_with('featured' => true, 'featured_position' => 10)

      expect(portal.articles.featured.order_by_featured_position.map(&:id)).to eq([first.id, second.id])
    end
  end

  describe '#featured? and #featured_position' do
    it 'reads the meta flags' do
      article = article_with('featured' => true, 'featured_position' => 15)
      expect(article.featured?).to be(true)
      expect(article.featured_position).to eq(15)
    end

    it 'is false / nil when meta is empty' do
      article = article_with({})
      expect(article.featured?).to be(false)
      expect(article.featured_position).to be_nil
    end
  end
end
