# frozen_string_literal: true

# UMI patch: bring Help Center translations that live only in Shopify back into
# Chatwoot, so the sync has a source to push from.
#
# UMI's Thai FAQ was written straight onto the Shopify articles with
# `translationsRegister` before Chatwoot had a Thai portal, which is exactly why
# it kept going stale (docs/UMI-HELP-CENTER-THAI-SPEC.md §1). This reads it back
# and files it as Chatwoot articles in the translation locale, linked to their
# English roots.
#
# It translates nothing. Every value written here is the value already in
# Shopify, and the body is proved lossless before it is stored: the markdown this
# derives is re-rendered with Chatwoot's own renderer and must come back
# equivalent to the HTML Shopify holds. An article that fails that check is
# refused and reported, never imported on a guess.
#
# Dry run by default. `apply: true` is the only thing that writes.
class Umi::HelpCenter::TranslationImportService
  Result = Struct.new(:imported, :unchanged, :refused, :skipped, :notes, keyword_init: true) do
    def refused?
      refused.any?
    end

    def report_lines(applied:)
      ["  #{applied ? 'imported' : 'would import'}: #{imported.length}",
       "  already current:   #{unchanged.length}",
       "  skipped:           #{skipped.length}",
       "  REFUSED:           #{refused.length}"] +
        notes.map { |note| "  note: #{note}" } +
        skipped.map { |line| "  skip: #{line}" } +
        refused.map { |line| "  REFUSED: #{line}" }
    end
  end

  # `status:` exists because the portal's locale route is public the moment
  # articles exist under it — chat.umi.store/hc/<portal>/<locale> already answers
  # 200 with an empty shell. Importing as `draft` lets a whole locale be staged
  # and read through before a single reader can reach it.
  def initialize(portal:, locale:, apply: false, status: 'published')
    @portal = portal
    @locale = locale.to_s
    @apply = apply
    @status = status.to_s
    @result = Result.new(imported: [], unchanged: [], refused: [], skipped: [], notes: [])
  end

  def perform
    if shopify.nil?
      @result.notes << 'shopify integration hook missing or has no token'
      return @result
    end

    # Read Shopify once, up front. Left to the per-article rescue below, an
    # unreachable Shopify would be re-tried 48 times and reported as 48 separate
    # article failures rather than as the one thing that is actually wrong.
    shopify_translations
    plan_categories
    source_articles.each { |article| import_article(article) }
    @result
  rescue StandardError => e
    @result.notes << "could not read translations from shopify: #{e.class}: #{e.message}"
    @result
  end

  private

  attr_reader :portal, :locale

  def apply?
    @apply
  end

  def source_articles
    portal.articles.where(locale: Umi::Shopify::HelpCenterLocales.source).order(:id)
  end

  def import_article(article)
    translation = shopify_translations[article.id.to_s]
    return skip(article, 'no shopify translation for this locale') if translation.blank?
    return skip(article, 'shopify translation has no title') if translation['title'].blank?

    content = markdown_for(article, translation)
    return if content.nil? # refused, already recorded

    write(article, translation, content)
  rescue StandardError => e
    refuse(article, "#{e.class}: #{e.message}")
  end

  # The body is the only field that needs deriving; everything else is stored as
  # plain text and comes back unchanged.
  def markdown_for(article, translation)
    html = translation['body_html'].to_s
    return '' if html.blank?

    markdown = Umi::HelpCenter::HtmlToMarkdown.convert(html)
    rendered = ChatwootMarkdownRenderer.new(markdown).render_article.to_s
    return markdown if Umi::HelpCenter::HtmlToMarkdown.equivalent?(rendered, html)

    refuse(article, "body does not round-trip; the markdown would not re-render to the #{locale} HTML now in Shopify")
    nil
  rescue Umi::HelpCenter::HtmlToMarkdown::UnsupportedNode => e
    refuse(article, e.message)
    nil
  end

  def write(article, translation, content)
    existing = existing_translation(article)
    attributes = attributes_for(article, translation, content)

    if existing && attributes.all? { |key, value| existing.public_send(key) == value }
      @result.unchanged << label(article)
      return
    end

    record_description_note(article, translation)
    @result.imported << label(article)
    return unless apply?

    persist(article, existing, attributes)
  end

  def persist(article, existing, attributes)
    if existing
      existing.update!(attributes)
    else
      portal.articles.create!(
        attributes.merge(
          account_id: portal.account_id,
          author_id: article.author_id,
          associated_article_id: article.id,
          category_id: translated_category_id(article),
          position: article.position,
          # ensure_article_slug runs `parameterize`, which reduces a Thai title
          # to an empty string, so the slug is derived from the English one.
          slug: "#{article.slug}-#{locale}"
        )
      )
    end
  end

  def attributes_for(article, translation, content)
    {
      title: translation['title'].to_s,
      content: content,
      # Only where the English article has a description of its own. Where it
      # does not, Shopify's summary is a translation of a truncated-mid-word
      # English fallback (spec §2.5); leaving this blank lets the same fallback
      # recompute a clean cut from real prose in this locale.
      description: article.description.presence && summary_text(translation),
      # The string, not the symbol: this hash is also compared field by field
      # against the stored record to decide whether anything actually changed.
      status: @status
    }
  end

  def summary_text(translation)
    Nokogiri::HTML::DocumentFragment.parse(translation['summary_html'].to_s).text.strip.presence
  end

  def record_description_note(article, translation)
    return if article.description.present?
    return if translation['summary_html'].blank?

    @result.notes << "#{label(article)}: summary will be recomputed from the #{locale} body " \
                     "(was #{summary_text(translation).to_s.truncate(60).inspect})"
  end

  def existing_translation(article)
    portal.articles.find_by(associated_article_id: article.id, locale: locale)
  end

  # An article takes its locale from its category (Article#ensure_locale_in_article),
  # so a translated article filed under an English category would be dragged back
  # to English. Each source category therefore gets a counterpart in this locale.
  #
  # Counterpart names stay in the source language: they are not customer-visible
  # on the storefront (which groups by blog tag and takes its headings from the
  # theme's `category_labels`), and inventing translations here would put words in
  # the translator's mouth. Rename them in the dashboard whenever convenient.
  def plan_categories
    missing = source_categories.reject { |category| translated_category(category) }
    return if missing.empty?

    @result.notes << "#{apply? ? 'created' : 'would create'} #{missing.length} #{locale} " \
                     "categories (#{missing.map(&:name).join(', ')}) — names left in the source language"
    missing.each { |category| create_category(category) } if apply?
  end

  def source_categories
    portal.categories.where(locale: Umi::Shopify::HelpCenterLocales.source).order(:position, :id)
  end

  def translated_category(category)
    portal.categories.find_by(associated_category_id: category.id, locale: locale)
  end

  def translated_category_id(article)
    return nil if article.category_id.blank?

    translated_category(article.category)&.id
  end

  def create_category(category)
    portal.categories.create!(
      account_id: portal.account_id, name: category.name, description: category.description,
      slug: "#{category.slug}-#{locale}", locale: locale, position: category.position,
      associated_category_id: category.id
    )
  end

  # ---- Shopify ----

  # chatwoot article id => { key => translated value }
  def shopify_translations
    @shopify_translations ||= begin
      gids = shopify.article_gids
      shopify.nodes(TRANSLATIONS_QUERY, 'translatableResources', locale: locale).each_with_object({}) do |node, acc|
        chatwoot_id = gids[node['resourceId']]
        next if chatwoot_id.nil?

        acc[chatwoot_id] = (node['translations'] || []).to_h { |entry| [entry['key'], entry['value']] }
      end
    end
  end

  def shopify
    return @shopify if defined?(@shopify)

    @shopify = Umi::Shopify::HelpCenterGraphql.for_account(portal.account_id)
  end

  # ---- reporting ----

  def label(article)
    "##{article.id} #{article.title}"
  end

  def skip(article, reason)
    @result.skipped << "#{label(article)} — #{reason}"
  end

  def refuse(article, reason)
    @result.refused << "#{label(article)} — #{reason}"
  end

  TRANSLATIONS_QUERY = <<~GRAPHQL
    query ArticleTranslations($locale: String!) {
      translatableResources(first: 250, resourceType: ARTICLE) {
        nodes {
          resourceId
          translations(locale: $locale) { key value }
        }
        pageInfo { hasNextPage }
      }
    }
  GRAPHQL
end
