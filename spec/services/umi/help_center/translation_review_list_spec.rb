# frozen_string_literal: true

require 'rails_helper'

# The reconciler replaces a translation when English moves, which is correct and
# is also the one case where a machine-authored string supersedes a human's. This
# is the loop that puts it back in front of a person, so what it has to get right
# is being *usable* by a translator — not merely being present.
RSpec.describe Umi::HelpCenter::TranslationReviewList do
  subject(:list) { described_class.new(portal: portal, locale: 'th') }

  let(:account) { create(:account) }
  let(:portal) do
    create(:portal, account: account, slug: 'umi-help',
                    config: { 'allowed_locales' => %w[en th], 'default_locale' => 'en' })
  end
  let(:thai_category) { create(:category, portal: portal, account: account, locale: 'th', slug: 'sizing-th') }
  let(:english) do
    create(:article, account: account, portal: portal, locale: 'en', title: 'Can I return an item?')
  end

  def thai_with(pending)
    create(:article, account: account, portal: portal, category: thai_category, locale: 'th',
                     title: 'ฉันคืนสินค้าได้ไหม', associated_article_id: english.id,
                     slug: 'can-i-return-an-item-th', meta: { described_class::META_KEY => pending })
  end

  describe '#entries' do
    it 'is empty when nothing has been superseded' do
      thai_with([])
      expect(list.entries).to be_empty
    end

    it 'names the English article, so the translator knows what she is looking at' do
      thai_with([{ 'key' => 'title', 'was' => 'เก่า', 'now' => 'ใหม่', 'at' => '2026-08-26T00:00:00Z' }])

      expect(list.entries.first.source_title).to eq('Can I return an item?')
    end

    # She has to judge a sentence, not markup.
    it 'strips HTML so both values can be read' do
      thai_with([{ 'key' => 'body_html', 'was' => '<p>ข้อความเก่า</p>', 'now' => "<p>ข้อความ\nใหม่</p>" }])
      entry = list.entries.first

      expect(entry.was).to eq('ข้อความเก่า')
      expect(entry.now).to eq('ข้อความ ใหม่')
    end

    # A list she cannot act on is a list that does not get worked.
    it 'links to the article she would edit' do
      thai_with([{ 'key' => 'title', 'was' => 'เก่า', 'now' => 'ใหม่' }])

      expect(list.entries.first.url)
        .to end_with("/app/accounts/#{account.id}/portals/umi-help/th/articles/edit/can-i-return-an-item-th")
    end

    it 'reports every superseded field, not just the first' do
      thai_with([{ 'key' => 'title', 'was' => 'ก', 'now' => 'ข' },
                 { 'key' => 'body_html', 'was' => 'ค', 'now' => 'ง' }])

      expect(list.entries.map(&:key)).to eq(%w[title body_html])
    end

    it 'ignores translations that were never linked to a source article' do
      create(:article, account: account, portal: portal, category: thai_category, locale: 'th',
                       title: 'ลอย', meta: { described_class::META_KEY => [{ 'key' => 'title' }] })

      expect(list.entries).to be_empty
    end
  end

  describe '.clear!' do
    # Signing off has to shrink the list, or it grows until it is ignored.
    it 'removes the pending items and reports how many' do
      thai = thai_with([{ 'key' => 'title', 'was' => 'ก', 'now' => 'ข' }])

      expect(described_class.clear!(thai)).to eq(1)
      expect(list.entries).to be_empty
    end

    it 'is a no-op on an article with nothing pending' do
      expect(described_class.clear!(thai_with([]))).to eq(0)
    end

    # Clearing must not look like an edit: re-firing the sync would re-register
    # the translation, and moving updated_at would clear the drift flag as a side
    # effect of a bookkeeping write.
    it 'does not touch updated_at or re-enqueue the sync' do
      thai = thai_with([{ 'key' => 'title', 'was' => 'ก', 'now' => 'ข' }])
      before = thai.updated_at
      clear_enqueued_jobs

      described_class.clear!(thai)

      expect(thai.reload.updated_at).to eq(before)
      expect(enqueued_jobs.select { |job| job[:job] == Umi::Shopify::HelpCenterSyncJob }).to be_empty
    end
  end
end
