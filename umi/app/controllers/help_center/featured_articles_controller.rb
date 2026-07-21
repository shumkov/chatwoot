# frozen_string_literal: true

# UMI: dashboard endpoints backing the Help Center "Featured" manager. Lists the
# portal's featured articles (ordered) and sets the whole ordered set in one call
# (add / drag-reorder / remove all express themselves as the posted `ids` array).
#
# Admin-only and portal-scoped (S1/S2 from the featured-FAQ spec review): ids are
# resolved through the portal in Umi::FeaturedArticles, so an agent can't feature an
# article in another account/portal (which would push a `featured` tag to another
# store's Shopify).
class Umi::HelpCenter::FeaturedArticlesController < Api::V1::Accounts::BaseController
  before_action :set_portal
  before_action :ensure_administrator

  def index
    render json: featured_payload
  end

  def update
    Umi::FeaturedArticles.set(@portal, params.permit(ids: [])[:ids])
    render json: featured_payload
  end

  private

  def set_portal
    @portal = Current.account.portals.find_by!(slug: params[:portal_id])
  end

  def ensure_administrator
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end

  def featured_payload
    articles = @portal.articles.featured.order_by_featured_position.includes(:category)
    { payload: articles.map { |article| article_json(article) } }
  end

  def article_json(article)
    {
      id: article.id,
      title: article.title,
      slug: article.slug,
      category: article.category&.name,
      featured_position: article.featured_position
    }
  end
end
