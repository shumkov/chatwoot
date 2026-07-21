# frozen_string_literal: true

# UMI: sets a portal's storefront-featured article set to exactly `ordered_ids`,
# in order. Backs the dashboard "Featured" manager (add / drag-reorder / remove).
#
# Correctness requirements (from the featured-FAQ spec review):
# - Writes meta via per-record `update!` (never bulk update_all / update_column) so
#   the `after_commit` Shopify sync fires for every change — otherwise un-featuring
#   would never remove the `featured` tag from Shopify and the article would stay on
#   the Explore FAQ forever.
# - Ids are portal-scoped (`portal.articles`), so a foreign/other-account id can't be
#   featured (which would otherwise push a `featured` tag to another store's Shopify).
# - Missing/deleted ids are skipped, not fatal, so one stale id can't abort the save.
class Umi::FeaturedArticles
  def self.set(portal, ordered_ids)
    new(portal, ordered_ids).set
  end

  def initialize(portal, ordered_ids)
    @portal = portal
    @ordered_ids = Array(ordered_ids).map(&:to_i).uniq
  end

  def set
    ActiveRecord::Base.transaction do
      feature_in_order
      unfeature_the_rest
    end
    @portal.articles.featured.order_by_featured_position
  end

  private

  def feature_in_order
    by_id = @portal.articles.where(id: @ordered_ids).index_by(&:id)
    @ordered_ids.each_with_index do |id, index|
      article = by_id[id]
      next if article.nil? # skip foreign / deleted ids rather than abort

      write_meta(article, featured: true, position: (index + 1) * 10)
    end
  end

  def unfeature_the_rest
    @portal.articles.featured.where.not(id: @ordered_ids).find_each do |article|
      write_meta(article, featured: false, position: nil)
    end
  end

  def write_meta(article, featured:, position:)
    meta = (article.meta || {}).dup
    if featured
      meta['featured'] = true
      meta['featured_position'] = position
    else
      meta['featured'] = false
      meta.delete('featured_position')
    end
    article.update!(meta: meta)
  end
end
