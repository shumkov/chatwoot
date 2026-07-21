# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::FeaturedArticles do
  let(:portal) { create(:portal) }

  def article(meta = {})
    create(:article, portal: portal, meta: meta)
  end

  describe '.set' do
    it 'features the given ids in order, assigning positions 10, 20, 30…' do
      a = article
      b = article
      c = article

      described_class.set(portal, [c.id, a.id, b.id])

      expect(c.reload.featured_position).to eq(10)
      expect(a.reload.featured_position).to eq(20)
      expect(b.reload.featured_position).to eq(30)
      expect(portal.articles.featured.order_by_featured_position.map(&:id)).to eq([c.id, a.id, b.id])
    end

    it 'un-features articles no longer in the list' do
      a = article('featured' => true, 'featured_position' => 10)
      b = article('featured' => true, 'featured_position' => 20)

      described_class.set(portal, [a.id])

      expect(a.reload.featured?).to be(true)
      expect(b.reload.featured?).to be(false)
      expect(b.reload.meta).not_to have_key('featured_position')
    end

    # C1: the write must go through the model so after_commit enqueues the sync.
    it 'writes through update! so the Shopify sync callback fires' do
      a = article
      expect_any_instance_of(Article).to receive(:update!).at_least(:once).and_call_original # rubocop:disable RSpec/AnyInstance
      described_class.set(portal, [a.id])
    end

    # S1: a foreign / other-portal id must be ignored, never featured.
    it 'ignores ids outside the portal' do
      other = create(:article, meta: {})
      mine = article

      described_class.set(portal, [mine.id, other.id])

      expect(mine.reload.featured?).to be(true)
      expect(other.reload.featured?).to be(false)
    end

    it 'skips missing / deleted ids without aborting the rest' do
      a = article
      described_class.set(portal, [a.id, 999_999_999])
      expect(a.reload.featured?).to be(true)
    end

    it 'clears the whole featured set when given an empty list' do
      a = article('featured' => true, 'featured_position' => 10)
      described_class.set(portal, [])
      expect(a.reload.featured?).to be(false)
    end
  end
end
