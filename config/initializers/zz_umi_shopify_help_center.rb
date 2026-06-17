# UMI patch: mirror Chatwoot Help Center articles -> Shopify "help" blog.
#
# Rebase-safe (per CONTRIBUTING-UMI golden rule #1): this initializer reopens
# Article and extends the Shopify integration scopes at boot instead of editing
# core files. The actual sync logic lives in autoloaded classes:
#   app/models/concerns/umi/shopify_help_center_syncable.rb
#   app/jobs/shopify/help_center_sync_job.rb
#   app/services/shopify/help_center_sync_service.rb
#
# Source of truth is Chatwoot; Shopify is a read-only mirror. The article body
# is rendered with Chatwoot's own ChatwootMarkdownRenderer#render_article so the
# storefront HTML matches the portal exactly.
#
# Config (all optional, sensible defaults):
#   UMI_HC_PORTAL_SLUG      (default "umi-help")  only this portal syncs
#   UMI_HC_BLOG_HANDLE      (default "help")      target Shopify blog handle
#   UMI_HC_BLOG_TITLE       (default "Help Center")
#   UMI_HC_ARTICLE_AUTHOR   (default "UMI")
#   UMI_HC_DELETE_REDIRECT  (default "/pages/help")
#
# Requires the Shopify integration to be (re-)connected with read_content +
# write_content scopes (added below). Without write_content the sync no-ops and
# logs a one-line notice.
Rails.application.config.to_prepare do
  # 1) Expand the Shopify OAuth scopes so the stored token can write blog content.
  if defined?(Shopify::IntegrationHelper)
    desired = %w[read_content write_content]
    current = Shopify::IntegrationHelper::REQUIRED_SCOPES
    unless desired.all? { |scope| current.include?(scope) }
      merged = (current + desired).uniq.freeze
      Shopify::IntegrationHelper.send(:remove_const, :REQUIRED_SCOPES)
      Shopify::IntegrationHelper.const_set(:REQUIRED_SCOPES, merged)
    end
  end

  # 2) Mirror article lifecycle (create/update/destroy) to Shopify.
  if defined?(Article) && !Article.include?(Umi::ShopifyHelpCenterSyncable)
    Article.include(Umi::ShopifyHelpCenterSyncable)
  end
end
