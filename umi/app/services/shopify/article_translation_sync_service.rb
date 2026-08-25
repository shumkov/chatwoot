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

  META_DESCRIPTION_LIMIT = 320

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

  # The translated values, keyed exactly as Shopify's translatable keys. Body and
  # summary go through the same helpers as the English article so the two
  # languages render identically on the same page.
  def translation_values
    {
      'title' => Umi::Shopify::HelpCenterContent.single_line(@attrs[:title]),
      'body_html' => Umi::Shopify::HelpCenterContent.body_html(@attrs[:content]).presence,
      'summary_html' => Umi::Shopify::HelpCenterContent.summary_html(@attrs[:description], @attrs[:content]).presence,
      'meta_title' => Umi::Shopify::HelpCenterContent.single_line(@attrs[:title]),
      'meta_description' => Umi::Shopify::HelpCenterContent.single_line(@attrs[:description], limit: META_DESCRIPTION_LIMIT)
    }.compact
  end

  # One TranslationInput per key the translation has *and* the source exposes.
  # A key the source lacks has no digest to pin against, so it cannot be written.
  def translation_inputs(digests)
    translation_values.filter_map do |key, value|
      digest = digests[key]
      next if digest.blank?

      { locale: locale, key: key, value: value, translatableContentDigest: digest }
    end
  end

  private

  def dispatch
    case @attrs[:event]
    when 'upserted'               then register_translations
    when 'unpublished', 'deleted' then remove_translations
    else log_skip("unknown event #{@attrs[:event]}")
    end
  end

  # A draft, archived or deleted translation must not keep serving content the
  # portal no longer publishes, so its translation is removed rather than frozen.
  def remove_translations
    gid = source_article_gid
    return log_skip('source article absent in shopify; nothing to remove') if gid.nil?

    data = shopify.call(REMOVE_MUTATION, resourceId: gid, keys: TRANSLATABLE_KEYS, locales: [locale])
    errors = data.dig('translationsRemove', 'userErrors') || []
    return log_error("translationsRemove rejected: #{format_errors(errors)}") if errors.any?

    log_done('remove', TRANSLATABLE_KEYS.length)
  end

  def register_translations
    gid = source_article_gid
    raise SourceArticleMissing, "no shopify article for chatwoot article #{root_id}" if gid.nil?

    inputs = translation_inputs(source_digests(gid))
    return log_skip('no translatable values to register') if inputs.empty?

    errors = register(gid, inputs)
    # A digest goes stale when the English article is updated between the read
    # and the write. Re-read once — the second attempt races nothing in practice.
    if digest_error?(errors)
      Rails.logger.info("[umi-hc-translation] digest moved for article #{root_id}; re-reading and retrying")
      inputs = translation_inputs(source_digests(gid, refresh: true))
      errors = register(gid, inputs)
    end
    return log_error("translationsRegister rejected: #{format_errors(errors)}") if errors.any?

    log_done('register', inputs.length)
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

  def source_digests(gid, refresh: false)
    return @source_digests if defined?(@source_digests) && !refresh

    content = shopify.call(TRANSLATABLE_CONTENT_QUERY, id: gid).dig('translatableResource', 'translatableContent') || []
    @source_digests = content.to_h { |entry| [entry['key'], entry['digest']] }
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

  def log_done(action, count)
    Rails.logger.info("[umi-hc-translation] #{action} #{count} #{locale} field(s) for article #{@attrs[:id]} " \
                      "\"#{@attrs[:title]}\" (source #{root_id})")
  end

  TRANSLATABLE_CONTENT_QUERY = <<~GRAPHQL
    query ArticleTranslatableContent($id: ID!) {
      translatableResource(resourceId: $id) {
        translatableContent { key digest }
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
