# frozen_string_literal: true

# UMI patch: report the state of a Help Center locale — which translations are
# missing, which have fallen behind their source article, and what the sync would
# actually change in Shopify if it ran now.
#
# This is the half of docs/UMI-HELP-CENTER-THAI-SPEC.md (§7) that closes the
# leak: the sync makes a translation fixable in Chatwoot, this makes the need for
# a fix visible.
#
# Drift is measured in Chatwoot, not from Shopify's `outdated` flag. Any save of
# a translation pins the current digest and clears that flag, so an unrelated
# typo fix would erase the warning while the translation was still a version
# behind. Comparing timestamps cannot be cleared by accident: it clears only when
# somebody opens the translation, looks at it, and saves. It over-approximates on
# purpose — a source typo fix flags the translation — which is the safe direction
# to be wrong in.
#
# Shopify's own flag is reported alongside as an independent cross-check. It is
# never used to decide drift.
class Umi::HelpCenter::TranslationStatusService
  Row = Struct.new(:article_id, :title, :state, :source_updated_at, :translation_updated_at,
                   :shopify_outdated_keys, :pending_keys, keyword_init: true) do
    def drifted?
      state == :behind
    end

    def missing?
      state == :missing
    end

    def to_line
      format('  %<id>-5s %<state>-9s %<source>-26s %<translation>-26s %<title>s',
             id: article_id, state: state, source: source_updated_at&.iso8601,
             translation: translation_updated_at&.iso8601 || '-', title: title.to_s.truncate(50))
    end
  end

  def initialize(portal:, locale:, check_shopify: true)
    @portal = portal
    @locale = locale.to_s
    @check_shopify = check_shopify
  end

  def rows
    @rows ||= source_articles.map { |article| row_for(article) }
  end

  def drifted
    rows.select(&:drifted?)
  end

  def missing
    rows.select(&:missing?)
  end

  def shopify_outdated
    rows.reject { |row| row.shopify_outdated_keys.blank? }
  end

  # Articles where the value the sync would send differs from the value Shopify
  # holds. Empty means running the sync would change nothing — which is the proof
  # that seeding a locale does not rewrite translations somebody wrote by hand.
  def pending
    rows.reject { |row| row.pending_keys.blank? }
  end

  HEADER = '  id    state     source updated             translation updated        title'

  def report_lines
    [HEADER] + rows.map(&:to_line) + [''] + summary_lines
  end

  private

  def summary_lines
    ["  missing translation: #{missing.length}",
     "  behind source:       #{drifted.length}",
     "  shopify says outdated (advisory cross-check): #{shopify_outdated.length}"] +
      shopify_outdated.map { |row| "    ##{row.article_id} #{row.shopify_outdated_keys.join(', ')}" } +
      ["  the sync would change in shopify: #{pending.length}"] +
      pending.map { |row| "    ##{row.article_id} #{row.pending_keys.join(', ')} — #{row.title.to_s.truncate(50)}" }
  end

  attr_reader :portal, :locale

  def source_articles
    portal.articles.where(locale: Umi::Shopify::HelpCenterLocales.source).order(:id)
  end

  def row_for(article)
    translation = translations[article.id]
    Row.new(
      article_id: article.id,
      title: article.title,
      state: state_for(article, translation),
      source_updated_at: article.updated_at,
      translation_updated_at: translation&.updated_at,
      shopify_outdated_keys: shopify_state.dig(article.id.to_s, :outdated),
      pending_keys: pending_keys_for(article, translation)
    )
  end

  def state_for(article, translation)
    return :missing if translation.nil?
    return :behind if article.updated_at > translation.updated_at

    :current
  end

  def translations
    @translations ||= portal.articles.where(locale: locale)
                            .where.not(associated_article_id: nil)
                            .index_by(&:associated_article_id)
  end

  # What the sync would send for this article, against what Shopify holds. Keys
  # the source article does not expose are excluded: they have no digest, so the
  # sync could not write them even if it wanted to.
  def pending_keys_for(article, translation)
    return nil if translation.nil?

    state = shopify_state[article.id.to_s]
    return nil if state.nil?

    proposed_values(translation).filter_map do |key, value|
      next unless state[:source_keys].include?(key)

      key if changed?(key, value, state[:values][key])
    end
  end

  def proposed_values(translation)
    Umi::Shopify::ArticleTranslationSyncService.new(
      'locale' => locale, 'title' => translation.title,
      'content' => translation.content, 'description' => translation.description
    ).translation_values
  end

  def changed?(key, proposed, current)
    if key.end_with?('_html')
      !Umi::HelpCenter::HtmlToMarkdown.equivalent?(proposed, current)
    else
      proposed != current
    end
  end

  # ---- Shopify (cross-check + diff source) ----

  # chatwoot article id => { source_keys:, values:, outdated: }
  def shopify_state
    @shopify_state ||= fetch_shopify_state
  rescue StandardError => e
    Rails.logger.warn("[umi-hc-translation] shopify cross-check unavailable: #{e.message}")
    @shopify_state = {}
  end

  def fetch_shopify_state
    return {} if !@check_shopify || shopify.nil?

    gids = shopify.article_gids
    shopify.nodes(TRANSLATIONS_QUERY, 'translatableResources', locale: locale).each_with_object({}) do |node, acc|
      chatwoot_id = gids[node['resourceId']]
      next if chatwoot_id.nil?

      acc[chatwoot_id] = state_for_node(node)
    end
  end

  def state_for_node(node)
    entries = node['translations'] || []
    {
      source_keys: (node['translatableContent'] || []).pluck('key'),
      values: entries.to_h { |entry| [entry['key'], entry['value']] },
      outdated: entries.select { |entry| entry['outdated'] }.pluck('key').presence
    }
  end

  def shopify
    return @shopify if defined?(@shopify)

    @shopify = Umi::Shopify::HelpCenterGraphql.for_account(portal.account_id)
  end

  TRANSLATIONS_QUERY = <<~GRAPHQL
    query ArticleTranslationState($locale: String!) {
      translatableResources(first: 250, resourceType: ARTICLE) {
        nodes {
          resourceId
          translatableContent { key }
          translations(locale: $locale) { key value outdated }
        }
        pageInfo { hasNextPage }
      }
    }
  GRAPHQL
end
