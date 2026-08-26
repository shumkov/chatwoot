# frozen_string_literal: true

require 'rails_helper'

# The leak this whole change exists to close is "English changed, the translation
# silently did not". Shopify's own `outdated` flag cannot carry that signal —
# saving any translation pins the current digest and clears it — so drift is
# decided here, from Chatwoot's timestamps.
RSpec.describe Umi::HelpCenter::TranslationStatusService do
  let(:account) { create(:account) }
  let(:portal) do
    create(:portal, account: account, slug: 'umi-help',
                    config: { 'allowed_locales' => %w[en th], 'default_locale' => 'en' })
  end
  let(:thai_category) { create(:category, portal: portal, account: account, locale: 'th', slug: 'sizing-th') }

  def english(title: 'How do I find my size?')
    create(:article, account: account, portal: portal, locale: 'en', title: title)
  end

  def thai_for(article, **overrides)
    create(:article, { account: account, portal: portal, category: thai_category, locale: 'th',
                       title: 'ไทย', associated_article_id: article.id }.merge(overrides))
  end

  def status
    described_class.new(portal: portal, locale: 'th', check_shopify: false)
  end

  it 'reports an English article with no counterpart as missing' do
    article = english
    expect(status.missing.map(&:article_id)).to eq([article.id])
  end

  it 'reports a translation saved after its source as current' do
    article = english
    thai_for(article)

    expect(status.rows.first.state).to eq(:current)
    expect(status.drifted).to be_empty
  end

  # The whole point: this is the state 33 of 48 articles were in, unnoticed.
  it 'reports a translation as behind once the English article is edited' do
    article = english
    thai_for(article)
    travel_to(1.hour.from_now) { article.update!(content: 'Updated English body.') }

    expect(status.drifted.map(&:article_id)).to eq([article.id])
  end

  # Clearing drift has to mean somebody looked at the translation. Re-saving it
  # is exactly that, and it is the only thing that clears the flag.
  it 'clears the flag when the translation is saved again' do
    article = english
    thai = thai_for(article)
    travel_to(1.hour.from_now) { article.update!(content: 'Updated English body.') }
    travel_to(2.hours.from_now) { thai.update!(content: 'เนื้อหาใหม่') }

    expect(status.drifted).to be_empty
  end

  it 'ignores translations that are not linked to a source article' do
    english
    create(:article, account: account, portal: portal, category: thai_category, locale: 'th', title: 'ลอย')

    expect(status.missing.length).to eq(1)
  end

  # The report is the operator's only view of this; a Shopify outage must not
  # take the Chatwoot-side answer down with it.
  it 'still answers when Shopify cannot be reached' do
    article = english
    thai_for(article)
    allow(Umi::Shopify::ClientFactory).to receive(:graphql_client_for).and_raise(StandardError, 'boom')
    create(:integrations_hook, account: account, app_id: 'shopify')

    result = described_class.new(portal: portal, locale: 'th')
    expect(result.rows.first.state).to eq(:current)
    expect(result.shopify_outdated).to be_empty
  end
end
