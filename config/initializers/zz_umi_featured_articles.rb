# UMI patch: "featured" Help Center articles (storefront FAQ shortlist).
#
# Rebase-safe (per CONTRIBUTING-UMI golden rule #1): this initializer includes a
# concern and prepends a controller override at boot instead of editing core files.
# Logic lives in the umi/ overlay (Umi:: namespace, autoloaded via push_dir in
# config/application.rb):
#   umi/app/models/article_featurable.rb                          -> Umi::ArticleFeaturable
#   umi/app/controllers/public/api/v1/portals/articles_controller.rb
#                                                                  -> Umi::Public::Api::V1::Portals::ArticlesController
#
# Kept separate from zz_umi_shopify_help_center.rb because it is an independently
# removable patch (its remove-when — upstream native tags / featured-article flag —
# differs from the sync patch's).
Rails.application.config.to_prepare do
  # 1) meta.featured / meta.featured_position axis + scopes on Article.
  Article.include(Umi::ArticleFeaturable) if defined?(Article) && Article.ancestors.exclude?(Umi::ArticleFeaturable)

  # 2) featured filter + sort on the public articles endpoint.
  if defined?(Public::Api::V1::Portals::ArticlesController)
    klass = Public::Api::V1::Portals::ArticlesController
    umi_mod = Umi::Public::Api::V1::Portals::ArticlesController
    klass.prepend(umi_mod) if klass.ancestors.exclude?(umi_mod)
  else
    Rails.logger.error('[umi-featured] Public::Api::V1::Portals::ArticlesController undefined — ' \
                       'upstream moved/renamed it; featured filter/sort patch skipped.')
  end
end
