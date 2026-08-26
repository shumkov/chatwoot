# frozen_string_literal: true

require 'rails_helper'

# The headline invariant of the Thai Help Center work: a translated article must
# reach Shopify as a *translation of* the English article, never as a second
# article. It used to be kept out of the sync entirely because a second article
# would fight the English one for the same handle.
RSpec.describe Umi::ShopifyHelpCenterSyncable do
  let(:account) { create(:account) }
  # Chatwoot validates a category's locale against the portal's allowed_locales,
  # so adding the locale to the portal is a real prerequisite, not paperwork.
  let(:portal) do
    create(:portal, account: account, slug: 'umi-help',
                    config: { 'allowed_locales' => %w[en th fr], 'default_locale' => 'en' })
  end
  let(:english_category) { create(:category, portal: portal, account: account, locale: 'en', slug: 'sizing') }
  let(:thai_category) do
    create(:category, portal: portal, account: account, locale: 'th', slug: 'sizing-th',
                      associated_category_id: english_category.id)
  end
  let(:english) do
    create(:article, account: account, portal: portal, category: english_category, locale: 'en',
                     title: 'How do I find my size?')
  end

  def thai_article(**overrides)
    create(:article, { account: account, portal: portal, category: thai_category, locale: 'th',
                       title: 'ฉันจะทราบขนาดของฉันได้อย่างไร', associated_article_id: english.id }.merge(overrides))
  end

  def enqueued_payloads
    enqueued_jobs.select { |job| job[:job] == Umi::Shopify::HelpCenterSyncJob }
                 .map { |job| job[:args].first }
  end

  describe 'which articles enqueue a sync' do
    it 'enqueues for the source locale, carrying its own id as the root' do
      english
      expect(enqueued_payloads.last).to include('locale' => 'en', 'root_id' => english.id, 'event' => 'upserted')
    end

    it 'enqueues for a translation locale, carrying the English article as the root' do
      english
      thai = thai_article
      payload = enqueued_payloads.last

      expect(payload).to include('locale' => 'th', 'id' => thai.id, 'root_id' => english.id)
    end

    # Without a root there is no Shopify article to attach the translation to.
    # Linking it later is an update, which fires the callback again.
    it 'enqueues nothing for a translation that is not linked to a source article' do
      english
      clear_enqueued_jobs
      create(:article, account: account, portal: portal, category: thai_category, locale: 'th', title: 'ไม่มีต้นทาง')

      expect(enqueued_payloads).to be_empty
    end

    it 'enqueues nothing for a locale that is not configured to sync' do
      english
      clear_enqueued_jobs
      french_category = create(:category, portal: portal, account: account, locale: 'fr', slug: 'sizing-fr')
      create(:article, account: account, portal: portal, category: french_category, locale: 'fr',
                       title: 'Comment trouver ma taille ?', associated_article_id: english.id)

      expect(enqueued_payloads).to be_empty
    end

    it 'enqueues nothing for a portal that is not the Help Center' do
      other = create(:portal, account: account, slug: 'not-the-help-center')
      create(:article, account: account, portal: other, locale: 'en', title: 'Elsewhere')

      expect(enqueued_payloads).to be_empty
    end
  end

  # This is what stops the sync from clearing Shopify's `outdated` flag on a
  # translation nobody has looked at: an English edit pushes English only.
  describe 'when the English article changes' do
    it 'enqueues no work for its translations' do
      thai_article
      clear_enqueued_jobs

      english.update!(content: 'Updated English body.')

      expect(enqueued_payloads.map { |payload| payload['locale'] }).to eq(['en'])
    end
  end

  describe 'lifecycle events for a translation' do
    it 'sends unpublished when the translation goes back to draft' do
      thai = thai_article
      clear_enqueued_jobs

      thai.update!(status: :draft)

      expect(enqueued_payloads.last).to include('event' => 'unpublished', 'locale' => 'th')
    end

    it 'sends deleted when the translation is destroyed' do
      thai = thai_article
      clear_enqueued_jobs

      thai.destroy!

      expect(enqueued_payloads.last).to include('event' => 'deleted', 'locale' => 'th')
    end
  end

  describe Umi::Shopify::HelpCenterSyncJob do
    def expect_routed_to(service, attrs)
      allow(service).to receive(:new).and_return(instance_double(service, perform: nil))
      described_class.perform_now(attrs)
      expect(service).to have_received(:new).with(hash_including(attrs))
    end

    it 'routes the source locale to the article sync' do
      expect_routed_to(Umi::Shopify::HelpCenterSyncService, 'locale' => 'en', 'event' => 'upserted', 'id' => 1)
    end

    it 'routes a translation locale to the translation sync, so no second article is created' do
      expect_routed_to(Umi::Shopify::ArticleTranslationSyncService,
                       'locale' => 'th', 'event' => 'upserted', 'id' => 2, 'root_id' => 1)
    end

    # A locale it does not recognise must not fall through to the article sync:
    # that would mint a second Shopify article competing for the English handle,
    # which is the failure the old locale gate existed to prevent. The model gate
    # should never enqueue one, so reaching here at all is a bug — drop it loudly
    # rather than acting on a guess.
    it 'drops a locale it cannot route rather than guessing' do
      allow(Umi::Shopify::HelpCenterSyncService).to receive(:new)
      allow(Umi::Shopify::ArticleTranslationSyncService).to receive(:new)

      described_class.perform_now('locale' => 'fr', 'event' => 'upserted', 'id' => 3)

      expect(Umi::Shopify::HelpCenterSyncService).not_to have_received(:new)
      expect(Umi::Shopify::ArticleTranslationSyncService).not_to have_received(:new)
    end
  end
end
