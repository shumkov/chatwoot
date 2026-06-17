# frozen_string_literal: true

# UMI patch: pushes a single Chatwoot Help Center article to the Shopify "help"
# blog using the account's existing Shopify integration token (Integrations::Hook
# app_id "shopify"). Mirrors the API-client pattern in
# Api::V1::Accounts::Integrations::ShopifyController.
#
# Idempotent: articles are matched by the custom.chatwoot_id metafield, so
# replays and reconciles never duplicate.
class Shopify::HelpCenterSyncService
  API_VERSION = '2025-01'

  def initialize(attrs)
    @attrs = attrs.respond_to?(:with_indifferent_access) ? attrs.with_indifferent_access : attrs
  end

  def perform
    return log_skip('no shopify integration hook') if hook.blank? || hook.access_token.blank?
    return log_skip('shopify token missing write_content scope; reconnect the integration') unless write_scope?

    case @attrs[:event]
    when 'upserted'     then upsert(published: true)
    when 'unpublished'  then upsert(published: false)
    when 'deleted'      then destroy_article
    else log_skip("unknown event #{@attrs[:event]}")
    end
  rescue ShopifyAPI::Errors::HttpResponseError => e
    Rails.logger.error("[umi-hc-sync] Shopify API error for article #{@attrs[:id]}: #{e.message}")
    raise
  end

  # ---- pure helpers (unit-testable without Shopify) ----

  def self.slugify(value)
    value.to_s.downcase.unicode_normalize(:nfkd)
         .gsub(/[^\w\s-]/, '').strip
         .gsub(/\s+/, '-').gsub(/-+/, '-')
  end

  def article_payload(published:)
    {
      title: @attrs[:title],
      author: ENV.fetch('UMI_HC_ARTICLE_AUTHOR', 'UMI'),
      body_html: rendered_body,
      summary_html: summary_html,
      handle: self.class.slugify(@attrs[:title]),
      tags: @attrs[:category_name].presence || 'General',
      published: published,
      metafields: metafields
    }
  end

  private

  def upsert(published:)
    existing = find_article_by_chatwoot_id
    payload = article_payload(published: published)

    if existing.nil?
      client.post(path: "blogs/#{blog_id}/articles.json", body: { article: payload })
      log_done('create')
    else
      client.put(path: "blogs/#{blog_id}/articles/#{existing['id']}.json",
                 body: { article: payload.merge(id: existing['id']) })
      ensure_rename_redirect(existing['handle'], payload[:handle])
      log_done('update')
    end
  end

  def destroy_article
    existing = find_article_by_chatwoot_id
    return log_skip('already absent in shopify') if existing.nil?

    client.delete(path: "blogs/#{blog_id}/articles/#{existing['id']}.json")
    ensure_redirect(article_url(existing['handle']), ENV.fetch('UMI_HC_DELETE_REDIRECT', '/pages/help'))
    log_done('delete')
  end

  # ---- mapping ----

  def rendered_body
    ChatwootMarkdownRenderer.new(@attrs[:content].to_s).render_article.to_s
  end

  def summary_html
    desc = @attrs[:description].to_s.strip
    return "<p>#{ERB::Util.html_escape(desc)}</p>" if desc.present?

    plain = @attrs[:content].to_s.gsub(/[#*_>`\[\]()]/, ' ').gsub(/\s+/, ' ').strip
    plain.present? ? "<p>#{ERB::Util.html_escape(plain[0, 160])}</p>" : ''
  end

  def metafields
    fields = [
      { namespace: 'custom', key: 'chatwoot_id', type: 'number_integer', value: @attrs[:id].to_s }
    ]
    fields << text_mf('custom', 'chatwoot_slug', @attrs[:slug])
    fields << text_mf('custom', 'chatwoot_category_slug', @attrs[:category_slug])
    fields << { namespace: 'custom', key: 'chatwoot_position', type: 'number_integer', value: @attrs[:position].to_s } if @attrs[:position].present?
    fields << text_mf('global', 'title_tag', @attrs[:title])
    fields << text_mf('global', 'description_tag', @attrs[:description].to_s[0, 320]) if @attrs[:description].present?
    fields.compact
  end

  def text_mf(namespace, key, value)
    return nil if value.blank?

    { namespace: namespace, key: key, type: 'single_line_text_field', value: value.to_s }
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

    created = client.post(path: 'blogs.json',
                          body: { blog: { title: ENV.fetch('UMI_HC_BLOG_TITLE', 'Help Center') } }).body['blog']
    if created['handle'] != handle
      client.put(path: "blogs/#{created['id']}.json", body: { blog: { id: created['id'], handle: handle } })
    end
    created['id']
  end

  # Scan the blog's articles and read each one's metafields to match by
  # chatwoot_id. O(N) — fine at FAQ corpus size (~50).
  def find_article_by_chatwoot_id
    articles = client.get(path: "blogs/#{blog_id}/articles.json", query: { limit: 250 }).body['articles'] || []
    articles.find do |a|
      mfs = client.get(path: "blogs/#{blog_id}/articles/#{a['id']}/metafields.json").body['metafields'] || []
      mfs.any? { |m| m['namespace'] == 'custom' && m['key'] == 'chatwoot_id' && m['value'].to_s == @attrs[:id].to_s }
    end
  end

  # ---- redirects (covered by write_content scope) ----

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

  def client
    @client ||= begin
      ShopifyAPI::Context.setup(
        api_key: GlobalConfigService.load('SHOPIFY_CLIENT_ID', nil),
        api_secret_key: GlobalConfigService.load('SHOPIFY_CLIENT_SECRET', nil),
        api_version: API_VERSION,
        scope: '',
        is_embedded: true,
        is_private: false
      )
      session = ShopifyAPI::Auth::Session.new(shop: hook.reference_id, access_token: hook.access_token)
      ShopifyAPI::Clients::Rest::Admin.new(session: session)
    end
  end

  def log_skip(reason)
    Rails.logger.info("[umi-hc-sync] skip article #{@attrs[:id]} (#{@attrs[:event]}): #{reason}")
  end

  def log_done(action)
    Rails.logger.info("[umi-hc-sync] #{action} article #{@attrs[:id]} \"#{@attrs[:title]}\"")
  end
end
