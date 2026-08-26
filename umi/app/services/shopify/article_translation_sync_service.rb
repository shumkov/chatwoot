# frozen_string_literal: true

# UMI patch: pushes a Chatwoot Help Center article written in a translation
# locale onto the *English* Shopify article as a translation, never as a second
# article. Design + rationale: docs/UMI-HELP-CENTER-THAI-SPEC.md.
#
# Shopify pins each translation to a `translatableContentDigest` of the English
# source, so the digests are read immediately before every write. Registering
# with the current digest is also what clears Shopify's `outdated` flag, which is
# why a correct write needs no separate staleness step.
#
# Only keys the source article actually exposes are written — `meta_description`
# exists only where the English article has a description.
#
# Config:
#   UMI_HC_TRANSLATION_LOCALES (default "th") — locales that sync as translations
#   UMI_HC_BLOG_HANDLE         (default "help") — the blog the source article lives in
class Umi::Shopify::ArticleTranslationSyncService
  # Raised when the English article has not reached Shopify yet. Retryable on
  # purpose: a translation committed moments before its source is an ordering
  # race that resolves itself, and dropping it would strand the translation.
  class SourceArticleMissing < StandardError; end

  # Every translatable key on a Shopify ARTICLE that Chatwoot has an opinion
  # about. `handle` is deliberately absent: translating it would fork the Thai
  # URLs away from the English ones for no gain.
  TRANSLATABLE_KEYS = %w[title body_html summary_html meta_title meta_description].freeze

  def initialize(attrs)
    @attrs = attrs.respond_to?(:with_indifferent_access) ? attrs.with_indifferent_access : attrs
  end

  def perform
    return log_skip('no shopify integration hook') if shopify.nil?
    return log_skip('shopify token missing write_translations scope; reconnect the integration') unless shopify.scope?('write_translations')
    return log_skip("root article id missing for #{locale} translation") if root_id.blank?
    # Shopify accepts a write into a locale the shop does not have and then
    # discards it, so without this the sync would look like it worked.
    return log_skip("locale '#{locale}' is not enabled on the shop") unless shopify.shop_locale?(locale)

    dispatch
  rescue ShopifyAPI::Errors::HttpResponseError => e
    handle_http_error(e)
  end

  # ---- pure helpers (unit-testable without Shopify) ----

  # The values this locale should hold, and the decision about which of them may
  # actually be written, both live in the reconciler — see it for the rule.
  def translation_values
    reconciler.values
  end

  # One TranslationInput per key the reconciler says to write. A key the source
  # article does not expose has no digest to pin against and so cannot be written
  # at all, whatever the rule says about it.
  def translation_inputs(digests, state = {})
    translation_values.filter_map do |key, value|
      digest = digests[key]
      next if digest.blank?
      next unless write?(key, value, state)

      { locale: locale, key: key, value: value, translatableContentDigest: digest }
    end
  end

  def write?(key, value, state)
    reconciler.write?(key, value, state)
  end

  def reconciler
    @reconciler ||= Umi::Shopify::TranslationReconciler.new(
      title: @attrs[:title], content: @attrs[:content], description: @attrs[:description]
    )
  end

  private

  def dispatch
    case @attrs[:event]
    when 'upserted'               then register_translations
    when 'unpublished', 'deleted' then remove_translations
    else log_skip("unknown event #{@attrs[:event]}")
    end
  end

  # Unpublishing or deleting a translation in Chatwoot leaves the storefront
  # serving copy the portal no longer publishes — a real divergence. Deleting the
  # Shopify translation closes it, and is off by default anyway, because the cost
  # of the two mistakes is not symmetric.
  #
  # The mutation is per-field (`translationKeys` is required), but this passes
  # every key, so it erases the whole locale for the article — including values a
  # human wrote in Translate & Adapt that this sync never touched. On a locale
  # populated by hand before Chatwoot owned it, which is the state a first rollout
  # is in, one mis-saved draft would take the whole article's translation with it.
  # Reconciling is not deleting.
  #
  # Narrowing this to the article's *backed* keys (see #backed?) would make
  # unpublish mean unpublish without touching anything Chatwoot does not own —
  # same predicate, both directions. Not wired up; the report is the mitigation.
  #
  # So the divergence is reported by `umi:help_center:translation_status` instead,
  # and removal happens only where an operator has turned it on deliberately.
  def remove_translations
    unless removal_enabled?
      return log_skip("#{locale} translation left in place (UMI_HC_TRANSLATION_REMOVE is not enabled); " \
                      'the storefront still serves it — translation_status reports the divergence')
    end

    gid = source_article_gid
    return log_skip('source article absent in shopify; nothing to remove') if gid.nil?

    data = shopify.call(REMOVE_MUTATION, resourceId: gid, keys: TRANSLATABLE_KEYS, locales: [locale])
    errors = data.dig('translationsRemove', 'userErrors') || []
    return log_error("translationsRemove rejected: #{format_errors(errors)}") if errors.any?

    log_done('remove', TRANSLATABLE_KEYS)
  end

  def removal_enabled?
    ENV.fetch('UMI_HC_TRANSLATION_REMOVE', 'false') == 'true'
  end

  def register_translations
    gid = source_article_gid
    raise SourceArticleMissing, "no shopify article for chatwoot article #{root_id}" if gid.nil?

    digests, held = source_state(gid)
    inputs = translation_inputs(digests, held)
    # The common steady state, not an error: everything Shopify holds is current
    # and nothing in Chatwoot has moved. A run that writes nothing is the sync
    # agreeing with the store.
    return log_skip('nothing to write — every field is present and current') if inputs.empty?

    errors = register(gid, inputs)
    # A digest goes stale when the English article is updated between the read
    # and the write. Re-read once — the second attempt races nothing in practice.
    if digest_error?(errors)
      Rails.logger.info("[umi-hc-translation] digest moved for article #{root_id}; re-reading and retrying")
      digests, held = source_state(gid, refresh: true)
      inputs = translation_inputs(digests, held)
      errors = register(gid, inputs)
    end
    return log_error("translationsRegister rejected: #{format_errors(errors)}") if errors.any?

    flag_for_review(inputs, held)
    log_done('register', inputs.pluck(:key))
  end

  # An outdated field held a translation somebody wrote against English that has
  # since changed, so replacing it supersedes a person's work with a derived
  # string. That is the only case worth a translator's time: a field that was
  # absent had nothing to review, and a field written because the Chatwoot
  # article changed *is* the translator's own edit.
  def flag_for_review(inputs, held)
    superseded = inputs.filter_map do |input|
      current = held[input[:key]] || {}
      next unless current[:outdated] && current[:value].present?

      { 'key' => input[:key], 'was' => current[:value], 'now' => input[:value], 'at' => Time.current.iso8601 }
    end
    return if superseded.empty?

    stamp_for_review(superseded)
  end

  def stamp_for_review(entries)
    article = Article.find_by(id: @attrs[:id])
    return if article.nil?

    key = Umi::HelpCenter::TranslationReviewList::META_KEY
    meta = article.meta.is_a?(Hash) ? article.meta.dup : {}
    meta[key] = Array(meta[key]) + entries
    # Not `update!`: stamping this must not re-fire the sync, and must not move
    # updated_at, which is what the drift report reads.
    article.update_columns(meta: meta) # rubocop:disable Rails/SkipsModelValidations
  end

  def register(gid, inputs)
    data = shopify.call(REGISTER_MUTATION, resourceId: gid, translations: inputs)
    data.dig('translationsRegister', 'userErrors') || []
  end

  def digest_error?(errors)
    errors.any? { |error| "#{error['field']} #{error['message']}".downcase.include?('digest') }
  end

  def format_errors(errors)
    errors.map { |error| "#{Array(error['field']).join('.')}: #{error['message']}" }.join('; ')
  end

  # ---- Shopify lookups ----

  def source_article_gid
    return @source_article_gid if defined?(@source_article_gid)

    @source_article_gid = shopify.article_gids.key(root_id.to_s)
  end

  # The digests to pin against and what the locale already holds, in one read.
  # They have to come from the same response: deciding whether to write from a
  # stale view of the translations, then pinning to a fresh digest, is how a
  # reconciler talks itself into an overwrite.
  def source_state(gid, refresh: false)
    return @source_state if defined?(@source_state) && !refresh

    resource = shopify.call(TRANSLATABLE_CONTENT_QUERY, id: gid, locale: locale)['translatableResource'] || {}
    @source_state = [digests_from(resource), held_translations_from(resource)]
  end

  def digests_from(resource)
    (resource['translatableContent'] || []).to_h { |entry| [entry['key'], entry['digest']] }
  end

  def held_translations_from(resource)
    (resource['translations'] || []).to_h do |entry|
      [entry['key'], { value: entry['value'], outdated: entry['outdated'] }]
    end
  end

  def shopify
    return @shopify if defined?(@shopify)

    @shopify = Umi::Shopify::HelpCenterGraphql.for_account(@attrs[:account_id])
  end

  # 429 / 5xx are transient — re-raise so Sidekiq retries. 4xx are permanent:
  # surface once and stop, so a poison job doesn't retry forever and die silently
  # in the Dead set. Same policy as the English article sync.
  def handle_http_error(error)
    status = error.respond_to?(:code) ? error.code : nil
    raise if status.nil? || status == 429 || status >= 500

    ChatwootExceptionTracker.new(error, account: shopify&.hook&.account).capture_exception
    log_skip("shopify #{status} error: #{error.message}")
  end

  def locale
    @attrs[:locale].to_s
  end

  def root_id
    @attrs[:root_id]
  end

  def log_skip(reason)
    Rails.logger.info("[umi-hc-translation] skip article #{@attrs[:id]} (#{@attrs[:event]}, #{locale}): #{reason}")
  end

  def log_error(reason)
    Rails.logger.error("[umi-hc-translation] article #{@attrs[:id]} (#{locale}): #{reason}")
    ChatwootExceptionTracker.new(StandardError.new(reason), account: shopify&.hook&.account).capture_exception
  end

  def log_done(action, keys)
    detail = keys.is_a?(Array) ? "#{keys.length} field(s) (#{keys.join(', ')})" : "#{keys} field(s)"
    Rails.logger.info("[umi-hc-translation] #{action} #{detail} in #{locale} for article #{@attrs[:id]} " \
                      "\"#{@attrs[:title]}\" (source #{root_id})")
  end

  TRANSLATABLE_CONTENT_QUERY = <<~GRAPHQL
    query ArticleTranslatableContent($id: ID!, $locale: String!) {
      translatableResource(resourceId: $id) {
        translatableContent { key digest }
        translations(locale: $locale) { key value outdated }
      }
    }
  GRAPHQL

  REGISTER_MUTATION = <<~GRAPHQL
    mutation RegisterArticleTranslations($resourceId: ID!, $translations: [TranslationInput!]!) {
      translationsRegister(resourceId: $resourceId, translations: $translations) {
        userErrors { field message }
        translations { key locale }
      }
    }
  GRAPHQL

  REMOVE_MUTATION = <<~GRAPHQL
    mutation RemoveArticleTranslations($resourceId: ID!, $keys: [String!]!, $locales: [String!]!) {
      translationsRemove(resourceId: $resourceId, translationKeys: $keys, locales: $locales) {
        userErrors { field message }
        translations { key }
      }
    }
  GRAPHQL
end
