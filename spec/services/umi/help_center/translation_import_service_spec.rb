# frozen_string_literal: true

require 'rails_helper'

# The import moves someone's hand-written translation from Shopify into Chatwoot.
# The failure that matters is not "it did not run" but "it ran and quietly
# changed the wording", so these pin refusal behaviour as hard as they pin
# success.
RSpec.describe Umi::HelpCenter::TranslationImportService do
  fake_client = Class.new do
    def initialize(responses)
      @responses = responses
    end

    def query(query:, **)
      Struct.new(:body).new({ 'data' => @responses.fetch(query[/query\s+(\w+)/, 1]) })
    end
  end
  let(:account) { create(:account) }
  let(:portal) do
    create(:portal, account: account, slug: 'umi-help',
                    config: { 'allowed_locales' => %w[en th], 'default_locale' => 'en' })
  end
  let(:category) { create(:category, portal: portal, account: account, locale: 'en', name: 'Sizing', slug: 'sizing') }

  let(:english) do
    create(:article, account: account, portal: portal, category: category, locale: 'en',
                     title: 'How do I find my size?', content: 'Each product page has a [size table](https://umi.store/s).',
                     description: 'Each product page has a size table.')
  end

  let(:thai_body) { %(<p>หน้าผลิตภัณฑ์แต่ละหน้ามี<a href="https://umi.store/s">ตารางขนาด</a></p>\n) }

  def stub_shopify(translations)
    responses = {
      'HelpArticles' => { 'articles' => {
        'nodes' => [{ 'id' => 'gid://shopify/Article/1', 'blog' => { 'handle' => 'help' },
                      'metafield' => { 'value' => english.id.to_s } }],
        'pageInfo' => { 'hasNextPage' => false }
      } },
      'ArticleTranslations' => { 'translatableResources' => {
        'nodes' => [{ 'resourceId' => 'gid://shopify/Article/1',
                      'translations' => translations.map { |k, v| { 'key' => k, 'value' => v } } }],
        'pageInfo' => { 'hasNextPage' => false }
      } }
    }
    allow(Umi::Shopify::ClientFactory).to receive(:graphql_client_for).and_return(FakeImportClient.new(responses))
  end

  def run(apply: false)
    described_class.new(portal: portal, locale: 'th', apply: apply).perform
  end

  before do
    stub_const('FakeImportClient', fake_client)
    create(:integrations_hook, account: account, app_id: 'shopify')
    english
    stub_shopify('title' => 'ฉันจะทราบขนาดของฉันได้อย่างไร', 'body_html' => thai_body,
                 'summary_html' => '<p>หน้าผลิตภัณฑ์แต่ละหน้ามีตารางขนาด</p>')
  end

  describe 'dry run' do
    it 'reports what it would do and writes nothing' do
      result = run

      expect(result.imported).to eq(["##{english.id} How do I find my size?"])
      expect(portal.articles.where(locale: 'th')).to be_empty
      expect(portal.categories.where(locale: 'th')).to be_empty
    end
  end

  describe 'apply' do
    it 'files the translation as a th article linked to the English one' do
      run(apply: true)
      thai = portal.articles.find_by(locale: 'th')

      expect(thai.associated_article_id).to eq(english.id)
      expect(thai.title).to eq('ฉันจะทราบขนาดของฉันได้อย่างไร')
    end

    # Chatwoot takes an article's locale from its category, so a th article filed
    # under the English category would be dragged back to English.
    it 'creates a th counterpart category linked to the English one' do
      run(apply: true)
      thai_category = portal.categories.find_by(locale: 'th')

      expect(thai_category.associated_category_id).to eq(category.id)
      expect(portal.articles.find_by(locale: 'th').category_id).to eq(thai_category.id)
    end

    # The stored markdown must re-render to the HTML Shopify already serves,
    # or the first sync after the import would rewrite somebody's translation.
    it 'stores markdown that re-renders to the Thai already in Shopify' do
      run(apply: true)
      thai = portal.articles.find_by(locale: 'th')
      rendered = ChatwootMarkdownRenderer.new(thai.content).render_article.to_s

      expect(Umi::HelpCenter::HtmlToMarkdown.equivalent?(rendered, thai_body)).to be(true)
    end

    it 'is idempotent — a second run changes nothing' do
      run(apply: true)
      result = run(apply: true)

      expect(result.imported).to be_empty
      expect(result.unchanged.length).to eq(1)
      expect(portal.articles.where(locale: 'th').count).to eq(1)
    end
  end

  describe 'when the English article has no description of its own' do
    before { english.update!(description: nil) }

    # Shopify's summary for these is a translation of a truncated-mid-word
    # English fallback. Storing it would enshrine that; leaving it blank lets the
    # same fallback recompute a clean cut from real Thai prose.
    it 'leaves the description blank and says so in the report' do
      result = run(apply: true)

      expect(portal.articles.find_by(locale: 'th').description).to be_blank
      expect(result.notes.join).to include('summary will be recomputed')
    end
  end

  describe 'refusals' do
    it 'refuses an article whose body it cannot convert, rather than importing part of it' do
      stub_shopify('title' => 'ไทย', 'body_html' => '<table><tr><td>x</td></tr></table>')

      result = run(apply: true)

      expect(result.refused.join).to include('unsupported block element <table>')
      expect(portal.articles.where(locale: 'th')).to be_empty
    end

    it 'skips an English article Shopify has no translation for' do
      stub_shopify({})

      result = run(apply: true)

      expect(result.skipped.join).to include('no shopify translation')
      expect(portal.articles.where(locale: 'th')).to be_empty
    end
  end
end
