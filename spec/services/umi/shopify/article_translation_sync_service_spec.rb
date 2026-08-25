# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Shopify::ArticleTranslationSyncService do
  # A stand-in for the Shopify GraphQL client that answers each operation by name
  # and records what it was asked to do, so the specs assert on the mutation the
  # sync actually sends rather than on its own internals.
  fake_client = Class.new do
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def query(query:, variables: nil, **)
      name = query[/(?:query|mutation)\s+(\w+)/, 1]
      @calls << { name: name, variables: variables }
      Struct.new(:body).new({ 'data' => @responses.fetch(name).call(variables) })
    end
  end
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, account: account, app_id: 'shopify') }
  let(:article_gid) { 'gid://shopify/Article/999' }

  let(:default_responses) do
    {
      'ShopLocales' => ->(_) { { 'shopLocales' => [{ 'locale' => 'th', 'published' => false }] } },
      'HelpArticles' => lambda { |_|
        { 'articles' => { 'nodes' => [{ 'id' => article_gid, 'blog' => { 'handle' => 'help' },
                                        'metafield' => { 'value' => '42' } }],
                          'pageInfo' => { 'hasNextPage' => false } } }
      },
      'ArticleTranslatableContent' => lambda { |_|
        { 'translatableResource' => { 'translatableContent' => [
          { 'key' => 'title', 'digest' => 'd-title' },
          { 'key' => 'body_html', 'digest' => 'd-body' },
          { 'key' => 'summary_html', 'digest' => 'd-summary' },
          { 'key' => 'handle', 'digest' => 'd-handle' },
          { 'key' => 'meta_title', 'digest' => 'd-metatitle' },
          { 'key' => 'meta_description', 'digest' => 'd-metadesc' }
        ] } }
      },
      'RegisterArticleTranslations' => ->(_) { { 'translationsRegister' => { 'userErrors' => [] } } },
      'RemoveArticleTranslations' => ->(_) { { 'translationsRemove' => { 'userErrors' => [] } } }
    }
  end

  let(:attrs) do
    {
      'event' => 'upserted', 'id' => 77, 'root_id' => 42, 'account_id' => account.id,
      'locale' => 'th', 'title' => 'ฉันจะทราบขนาดของฉันได้อย่างไร',
      'content' => 'หน้าผลิตภัณฑ์แต่ละหน้ามี [ตารางขนาด](https://umi.store/pages/size-guide)',
      'description' => 'ตารางขนาดเป็นเซนติเมตร', 'status' => 'published'
    }
  end

  def client_with(overrides = {})
    FakeGraphqlClient.new(default_responses.merge(overrides)).tap do |client|
      allow(Umi::Shopify::ClientFactory).to receive(:graphql_client_for).and_return(client)
    end
  end

  before do
    stub_const('FakeGraphqlClient', fake_client)
    hook.update!(settings: { 'scope' => 'read_content,write_content,read_translations,write_translations' })
  end

  describe '#translation_values' do
    subject(:values) { described_class.new(attrs).translation_values }

    it 'maps the Chatwoot fields onto Shopify’s translatable keys' do
      expect(values.keys).to contain_exactly('title', 'body_html', 'summary_html', 'meta_title', 'meta_description')
    end

    it 'renders the body with Chatwoot’s own renderer, so both languages render alike' do
      expect(values['body_html']).to include('<a href="https://umi.store/pages/size-guide">ตารางขนาด</a>')
    end

    it 'mirrors the article title into meta_title, as the English sync does' do
      expect(values['meta_title']).to eq(attrs['title'])
    end

    # Translating the handle would fork the Thai URLs away from the English ones.
    it 'never offers a handle' do
      expect(values).not_to have_key('handle')
    end

    context 'when the article has no description' do
      let(:attrs) { super().merge('description' => nil) }

      it 'falls back to a cut of the body for the summary and offers no meta_description' do
        expect(values['summary_html']).to start_with('<p>หน้าผลิตภัณฑ์')
        expect(values).not_to have_key('meta_description')
      end
    end
  end

  describe '#translation_inputs' do
    # The English article only carries a description_tag metafield when it has a
    # description, so meta_description is missing from a third of the corpus.
    # A key with no digest cannot be pinned, so it must not be sent at all.
    it 'skips keys the source article does not expose' do
      inputs = described_class.new(attrs).translation_inputs('title' => 'd1', 'body_html' => 'd2')

      expect(inputs.map { |input| input[:key] }).to contain_exactly('title', 'body_html')
    end

    it 'pins each value to the digest of the English key it translates' do
      inputs = described_class.new(attrs).translation_inputs('title' => 'd-title')

      expect(inputs.first).to include(locale: 'th', key: 'title', translatableContentDigest: 'd-title')
    end
  end

  describe '#perform' do
    it 'registers the translation against the source article, not a new article' do
      client = client_with
      described_class.new(attrs).perform

      register = client.calls.find { |call| call[:name] == 'RegisterArticleTranslations' }
      expect(register[:variables][:resourceId]).to eq(article_gid)
      expect(register[:variables][:translations].map { |t| t[:key] })
        .to contain_exactly('title', 'body_html', 'summary_html', 'meta_title', 'meta_description')
    end

    # An article the portal no longer publishes must not keep serving translated
    # copy from the storefront.
    %w[unpublished deleted].each do |event|
      it "removes the locale's translations on #{event}" do
        client = client_with
        described_class.new(attrs.merge('event' => event)).perform

        remove = client.calls.find { |call| call[:name] == 'RemoveArticleTranslations' }
        expect(remove[:variables]).to include(resourceId: article_gid, locales: ['th'])
        expect(client.calls.map { |call| call[:name] }).not_to include('RegisterArticleTranslations')
      end
    end

    # Dropping the translation here would strand it: the source article is very
    # likely seconds away, so the job has to come back and try again.
    it 'raises a retryable error when the English article has not reached Shopify yet' do
      client_with('HelpArticles' => lambda { |_|
        { 'articles' => { 'nodes' => [], 'pageInfo' => { 'hasNextPage' => false } } }
      })

      expect { described_class.new(attrs).perform }.to raise_error(described_class::SourceArticleMissing)
    end

    it 'writes nothing when the token has not been reconnected with write_translations' do
      hook.update!(settings: { 'scope' => 'read_content,write_content' })
      client = client_with

      described_class.new(attrs).perform

      expect(client.calls).to be_empty
    end

    # Shopify accepts a write into a locale the shop does not have and then
    # discards it, so without this guard the sync would look like it worked.
    it 'writes nothing when the locale is not enabled on the shop' do
      client = client_with('ShopLocales' => ->(_) { { 'shopLocales' => [{ 'locale' => 'en', 'published' => true }] } })

      described_class.new(attrs).perform

      expect(client.calls.map { |call| call[:name] }).not_to include('RegisterArticleTranslations')
    end

    # The English article can be updated between reading the digest and writing
    # the translation. One re-read resolves it; silently giving up would leave
    # the translation unwritten.
    it 're-reads the digests and retries once when Shopify says the digest moved' do
      attempts = 0
      client = client_with('RegisterArticleTranslations' => lambda { |_|
        attempts += 1
        errors = attempts == 1 ? [{ 'field' => %w[translations 0 translatableContentDigest], 'message' => 'Digest is invalid' }] : []
        { 'translationsRegister' => { 'userErrors' => errors } }
      })

      described_class.new(attrs).perform

      expect(attempts).to eq(2)
      expect(client.calls.count { |call| call[:name] == 'ArticleTranslatableContent' }).to eq(2)
    end

    it 'stops after the retry rather than looping on a persistent rejection' do
      client = client_with('RegisterArticleTranslations' => lambda { |_|
        { 'translationsRegister' => { 'userErrors' => [{ 'field' => ['translations'], 'message' => 'Digest is invalid' }] } }
      })

      described_class.new(attrs).perform

      expect(client.calls.count { |call| call[:name] == 'RegisterArticleTranslations' }).to eq(2)
    end
  end
end
