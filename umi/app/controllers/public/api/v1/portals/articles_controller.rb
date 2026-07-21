# frozen_string_literal: true

# UMI patch: extend the public Help Center articles endpoint with a "featured"
# filter and sort, so the storefront Assistance drawer can request the curated set:
#   GET /hc/:slug/:locale/articles.json?featured=true&sort=featured
#
# Rebase-safe: prepended onto the core controller (mirrors the enterprise overlay
# that prepends search_articles) by config/initializers/zz_umi_featured_articles.rb
# instead of editing the core file. `featured` is read straight from params (a read,
# not mass-assignment) so no list_params permit edit is needed.
module Umi::Public::Api::V1::Portals::ArticlesController
  private

  def order_by_sort_param
    @articles = @articles.featured if ActiveModel::Type::Boolean.new.cast(params[:featured])

    if params[:sort].to_s == 'featured'
      @articles = @articles.order_by_featured_position
    else
      super
    end
  end
end
