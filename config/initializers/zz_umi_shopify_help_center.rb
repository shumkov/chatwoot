# UMI patch: mirror Chatwoot Help Center articles -> Shopify "help" blog.
#
# Rebase-safe (per CONTRIBUTING-UMI golden rule #1): this initializer reopens
# Article and extends the Shopify integration scopes at boot instead of editing
# core files. The actual sync logic lives in autoloaded classes in the umi/ overlay
# (wired under the Umi:: namespace via push_dir in config/application.rb):
#   umi/app/models/shopify_help_center_syncable.rb       -> Umi::ShopifyHelpCenterSyncable
#   umi/app/jobs/shopify/help_center_sync_job.rb         -> Umi::Shopify::HelpCenterSyncJob
#   umi/app/services/shopify/help_center_sync_service.rb -> Umi::Shopify::HelpCenterSyncService
#
# Source of truth is Chatwoot; Shopify is a read-only mirror. The article body
# is rendered with Chatwoot's own ChatwootMarkdownRenderer#render_article so the
# storefront HTML matches the portal exactly.
#
# Articles written in a translation locale ride the same hooks but land as Shopify
# *translations* of the English article rather than as articles of their own —
# see docs/UMI-HELP-CENTER-THAI-SPEC.md and
#   umi/app/services/shopify/help_center_locales.rb
#   umi/app/services/shopify/article_translation_sync_service.rb
#
# Config (all optional, sensible defaults):
#   UMI_HC_PORTAL_SLUG      (default "umi-help")  only this portal syncs
#   UMI_HC_LOCALE           (default "en")        the source locale
#   UMI_HC_TRANSLATION_LOCALES (default "th")     locales synced as translations
#   UMI_HC_BLOG_HANDLE      (default "help")      target Shopify blog handle
#   UMI_HC_BLOG_TITLE       (default "Help Center")
#   UMI_HC_ARTICLE_AUTHOR   (default "UMI")
#   UMI_HC_DELETE_REDIRECT  (default "/pages/help")
#
# Requires the Shopify integration to be (re-)connected with the scopes added
# below. Without write_content the sync no-ops and logs a one-line notice.
#
# Scopes added:
#   read_content / write_content                 -> blog + article read/write
#   read_online_store_navigation /               -> URL redirects (the 301s on
#   write_online_store_navigation                   rename and delete)
#   read_translations / write_translations       -> article translations
#                                                   (translationsRegister)
# Shopify's docs disagree on whether redirects fall under "content" or
# "online_store_navigation"; both are requested so the 301s work regardless.
Rails.application.config.to_prepare do
  # 1) Expand the Shopify OAuth scopes so the stored token can write blog content
  #    and URL redirects.
  #
  # Upstream value as of v4.14.2 (app/helpers/shopify/integration_helper.rb):
  #   %w[read_customers read_orders read_fulfillments]
  # If upstream renames REQUIRED_SCOPES or changes it from an Array, this patch
  # no-ops and logs loudly instead of silently degrading — re-reconcile on rebase.
  if defined?(Shopify::IntegrationHelper)
    current = Shopify::IntegrationHelper::REQUIRED_SCOPES
    if current.is_a?(Array)
      desired = %w[read_content write_content read_online_store_navigation write_online_store_navigation
                   read_translations write_translations]
      unless desired.all? { |scope| current.include?(scope) }
        merged = (current + desired).uniq.freeze
        Shopify::IntegrationHelper.send(:remove_const, :REQUIRED_SCOPES)
        Shopify::IntegrationHelper.const_set(:REQUIRED_SCOPES, merged)
      end
    else
      Rails.logger.error('[umi-hc-sync] Shopify::IntegrationHelper::REQUIRED_SCOPES is not an Array — ' \
                         'upstream changed its shape; UMI scope patch skipped. Reconcile zz_umi_shopify_help_center.rb.')
    end
  else
    Rails.logger.error('[umi-hc-sync] Shopify::IntegrationHelper is undefined — upstream moved/renamed it; UMI scope patch skipped.')
  end

  # 2) Mirror article lifecycle (create/update/destroy) to Shopify.
  Article.include(Umi::ShopifyHelpCenterSyncable) if defined?(Article) && Article.ancestors.exclude?(Umi::ShopifyHelpCenterSyncable)
end
