# frozen_string_literal: true

# UMI patch: a "featured" axis on Help Center articles, orthogonal to the single
# category_id — so an article can be featured on the storefront (Assistance drawer
# + Explore FAQ) while keeping its topical category. Curated in Chatwoot; projected
# to Shopify by the help-center sync (featured -> tag, featured_position -> metafield).
#
# Stored in the article's meta jsonb (no migration): meta["featured"] (bool) and
# meta["featured_position"] (int, portal-global order for the featured set; lower
# first). Included into Article by config/initializers/zz_umi_featured_articles.rb.
module Umi::ArticleFeaturable
  extend ActiveSupport::Concern

  included do
    scope :featured, -> { where("meta->>'featured' = 'true'") }

    # Order the featured set by meta.featured_position. The value is cast defensively:
    # a non-numeric or empty position sorts last rather than raising a Postgres cast
    # error that would 500 the shared public articles endpoint. id is the tiebreaker
    # so two equal positions order deterministically across requests.
    scope :order_by_featured_position, lambda {
      reorder(Arel.sql(
                "CASE WHEN meta->>'featured_position' ~ '^-?[0-9]+$' " \
                "THEN (meta->>'featured_position')::int END ASC NULLS LAST, articles.id ASC"
              ))
    }
  end

  def featured?
    meta.is_a?(Hash) && meta['featured'].to_s == 'true'
  end

  def featured_position
    return nil unless meta.is_a?(Hash)

    Integer(meta['featured_position'], exception: false)
  end
end
