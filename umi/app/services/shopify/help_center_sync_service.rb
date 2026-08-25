# frozen_string_literal: true

# UMI patch: pushes a single Chatwoot Help Center article to the Shopify "help"
# blog using the account's existing Shopify integration token (Integrations::Hook
# app_id "shopify"). Mirrors the API-client pattern in
# Api::V1::Accounts::Integrations::ShopifyController.
#
# Idempotent: articles are matched by the custom.chatwoot_id metafield and, as a
# fallback, by handle — so replays, reconciles, and a dropped/unavailable
# metafield never duplicate.
class Umi::Shopify::HelpCenterSyncService
  def initialize(attrs)
    @attrs = attrs.respond_to?(:with_indifferent_access) ? attrs.with_indifferent_access : attrs
  end

  def perform
    return log_skip('no shopify integration hook') if hook.blank? || hook.access_token.blank?
    return log_skip('shopify token missing write_content scope; reconnect the integration') unless write_scope?

    dispatch
  rescue ShopifyAPI::Errors::HttpResponseError => e
    handle_http_error(e)
  end

  # ---- pure helpers (unit-testable without Shopify) ----

  def self.slugify(value)
    value.to_s.downcase.unicode_normalize(:nfkd)
         .gsub(/[^\w\s-]/, '').strip
         .gsub(/\s+/, '-').squeeze('-')
         .gsub(/\A-|-\z/, '')
  end

  def article_payload(published:)
    {
      title: @attrs[:title],
      author: ENV.fetch('UMI_HC_ARTICLE_AUTHOR', 'UMI'),
      body_html: rendered_body,
      summary_html: summary_html,
      handle: self.class.slugify(@attrs[:title]),
      tags: article_tags,
      published: published,
      metafields: metafields
    }
  end

  # Category tag (topical grouping) + `featured` when the article is in the storefront
  # featured set. Shopify overwrites all tags on PUT, so un-featuring drops it next sync.
  #
  # Shopify parses `tags` as a comma-separated list, so a comma inside a category name
  # splits it into two unrelated tags and the category the storefront filters on never
  # matches. Commas become spaces rather than being dropped, so "Wholesale, Press &
  # Influencers" stays one readable tag instead of running the words together.
  def article_tags
    category = @attrs[:category_name].to_s.tr(',', ' ').squish.presence
    [category, ('featured' if @attrs[:featured])].compact.join(', ')
  end

  private

  def dispatch
    case @attrs[:event]
    when 'upserted'    then upsert_article(published: true)
    when 'unpublished' then upsert_article(published: false)
    when 'deleted'     then destroy_article
    else log_skip("unknown event #{@attrs[:event]}")
    end
  end

  # 429 / 5xx are transient — re-raise so Sidekiq retries. 4xx (401/403/404/409/
  # 422…) are permanent: surface once and stop, so a poison job doesn't retry
  # forever and die silently in the Dead set.
  def handle_http_error(error)
    raise if retryable_http_error?(error)

    ChatwootExceptionTracker.new(error, account: hook&.account).capture_exception
    log_skip("shopify #{http_status(error) || '?'} error for article #{@attrs[:id]}: #{error.message}")
  end

  def upsert_article(published:)
    payload = article_payload(published: published)
    existing = find_owned_article

    if existing
      client.put(path: "blogs/#{blog_id}/articles/#{existing['id']}.json",
                 body: { article: payload.merge(id: existing['id']) })
      # Only manage the rename 301 while published — a draft handle is not public,
      # so redirecting an old URL to it would 301 visitors to a 404.
      ensure_rename_redirect(existing['handle'], payload[:handle]) if published
      log_done('update')
    elsif blog_articles.any? { |a| a['handle'] == payload[:handle] }
      # The handle is owned by an article without our chatwoot_id — creating would
      # duplicate (Shopify auto-suffixes) and updating would hijack it. Skip + alert.
      Rails.logger.warn("[umi-hc-sync] handle '#{payload[:handle]}' already taken by a non-UMI " \
                        "article — skipping article #{@attrs[:id]} to avoid overwrite/duplicate")
    else
      create_article(payload)
    end
  end

  def create_article(payload)
    created = client.post(path: "blogs/#{blog_id}/articles.json", body: { article: payload }).body['article']
    raise "Shopify create returned no article id for chatwoot article #{@attrs[:id]}" if created.nil? || created['id'].blank?

    log_done('create')
  end

  def destroy_article
    existing = find_owned_article
    return log_skip('already absent in shopify') if existing.nil?

    # Create the redirect before deleting so a retry (if the delete fails) still
    # re-attempts both steps — ensure_redirect is idempotent.
    ensure_redirect(article_url(existing['handle']), ENV.fetch('UMI_HC_DELETE_REDIRECT', '/pages/help'))
    client.delete(path: "blogs/#{blog_id}/articles/#{existing['id']}.json")
    log_done('delete')
  end

  # ---- mapping ----

  def rendered_body
    Umi::Shopify::HelpCenterContent.body_html(@attrs[:content])
  end

  def summary_html
    Umi::Shopify::HelpCenterContent.summary_html(@attrs[:description], @attrs[:content])
  end

  def metafields
    [
      number_mf('chatwoot_id', @attrs[:id]),
      text_mf('custom', 'chatwoot_slug', @attrs[:slug]),
      text_mf('custom', 'chatwoot_category_slug', @attrs[:category_slug]),
      (number_mf('chatwoot_position', @attrs[:position]) if @attrs[:position].present?),
      (number_mf('featured_position', @attrs[:featured_position]) if @attrs[:featured] && @attrs[:featured_position].present?),
      text_mf('global', 'title_tag', @attrs[:title]),
      (text_mf('global', 'description_tag', @attrs[:description], limit: 320) if @attrs[:description].present?)
    ].compact
  end

  def text_mf(namespace, key, value, limit: nil)
    normalized = Umi::Shopify::HelpCenterContent.single_line(value, limit: limit)
    return nil if normalized.nil?

    { namespace: namespace, key: key, type: 'single_line_text_field', value: normalized }
  end

  def number_mf(key, value)
    { namespace: 'custom', key: key, type: 'number_integer', value: value.to_s }
  end

  # ---- Shopify lookups ----

  def blog_id
    @blog_id ||= find_or_create_blog
  end

  def find_or_create_blog
    handle = ENV.fetch('UMI_HC_BLOG_HANDLE', 'help')
    blogs = client.get(path: 'blogs.json', query: { limit: 250 }).body['blogs'] || []
    blog = blogs.find { |b| b['handle'] == handle }
    return blog['id'] if blog

    # The blog is expected to pre-exist (renamed help-center -> help per the deploy
    # steps); creating it here is a fresh-install fallback. Log loudly so an
    # unexpected create (e.g. a misnamed live blog) is visible rather than silent.
    Rails.logger.warn("[umi-hc-sync] '#{handle}' blog not found — creating it. " \
                      "If the store already has the FAQ blog, rename its handle to '#{handle}'.")
    created = client.post(path: 'blogs.json',
                          body: { blog: { title: ENV.fetch('UMI_HC_BLOG_TITLE', 'Help Center') } }).body['blog']
    client.put(path: "blogs/#{created['id']}.json", body: { blog: { id: created['id'], handle: handle } }) if created['handle'] != handle
    created['id']
  end

  # The Shopify article we own for this Chatwoot article, matched by the stable
  # custom.chatwoot_id metafield. O(N) over the blog's articles — fine at FAQ
  # corpus size (~50); reads only the first page (limit 250).
  def find_owned_article
    blog_articles.find { |a| article_matches_chatwoot_id?(a) }
  end

  def blog_articles
    @blog_articles ||= client.get(path: "blogs/#{blog_id}/articles.json", query: { limit: 250 }).body['articles'] || []
  end

  def article_matches_chatwoot_id?(article)
    # Article metafields are addressed by article id (not nested under the blog) in
    # the REST Admin API: articles/<id>/metafields.json.
    mfs = client.get(path: "articles/#{article['id']}/metafields.json").body['metafields'] || []
    mfs.any? { |m| m['namespace'] == 'custom' && m['key'] == 'chatwoot_id' && m['value'].to_s == @attrs[:id].to_s }
  rescue ShopifyAPI::Errors::HttpResponseError => e
    # 404 → treat as no-match and fall back to the handle guard. Auth/permission/
    # transient errors must surface, not silently degrade idempotency, so re-raise.
    raise unless http_status(e) == 404

    false
  end

  # ---- redirects (covered by write_content / write_online_store_navigation) ----

  def ensure_rename_redirect(old_handle, new_handle)
    return if old_handle.blank? || old_handle == new_handle

    ensure_redirect(article_url(old_handle), article_url(new_handle))
  end

  def ensure_redirect(from_path, to_path)
    return if from_path == to_path

    existing = (client.get(path: 'redirects.json', query: { path: from_path, limit: 1 }).body['redirects'] || []).first
    if existing
      return if existing['target'] == to_path

      client.put(path: "redirects/#{existing['id']}.json",
                 body: { redirect: { id: existing['id'], path: from_path, target: to_path } })
    else
      client.post(path: 'redirects.json', body: { redirect: { path: from_path, target: to_path } })
    end
  end

  def article_url(handle)
    "/blogs/#{ENV.fetch('UMI_HC_BLOG_HANDLE', 'help')}/#{handle}"
  end

  # ---- integration / client ----

  def hook
    @hook ||= Integrations::Hook.find_by(account_id: @attrs[:account_id], app_id: 'shopify')
  end

  def write_scope?
    hook.settings.to_h['scope'].to_s.split(',').map(&:strip).include?('write_content')
  end

  def retryable_http_error?(error)
    status = http_status(error)
    status.nil? || status == 429 || status >= 500
  end

  def http_status(error)
    error.code if error.respond_to?(:code)
  end

  # Context.setup serialization (the Zeitwerk-reload race) lives in the shared
  # factory — every UMI Shopify service must build its client there so one mutex
  # guards all of them.
  def client
    @client ||= Umi::Shopify::ClientFactory.client_for(hook)
  end

  def log_skip(reason)
    Rails.logger.info("[umi-hc-sync] skip article #{@attrs[:id]} (#{@attrs[:event]}): #{reason}")
  end

  def log_done(action)
    Rails.logger.info("[umi-hc-sync] #{action} article #{@attrs[:id]} \"#{@attrs[:title]}\"")
  end
end
