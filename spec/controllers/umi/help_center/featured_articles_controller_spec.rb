# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi Featured Articles API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let!(:portal) { create(:portal, name: 'help', slug: 'help-portal', account_id: account.id) }
  let!(:article_a) { create(:article, portal: portal, account_id: account.id, author_id: admin.id, title: 'A') }
  let!(:article_b) { create(:article, portal: portal, account_id: account.id, author_id: admin.id, title: 'B') }

  let(:url) { "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/featured_articles" }

  describe 'GET featured_articles' do
    it 'is unauthorized without authentication' do
      get url
      expect(response).to have_http_status(:unauthorized)
    end

    it 'is not allowed for a non-admin agent' do
      get url, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
    end

    it 'lists featured articles in featured_position order for an admin' do
      Umi::FeaturedArticles.set(portal, [article_b.id, article_a.id])

      get url, headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].map { |a| a['id'] }).to eq([article_b.id, article_a.id])
    end
  end

  describe 'POST featured_articles' do
    it 'sets the featured set in order for an admin' do
      post url, params: { ids: [article_a.id, article_b.id] }, headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(article_a.reload.featured_position).to eq(10)
      expect(article_b.reload.featured_position).to eq(20)
      expect(response.parsed_body['payload'].map { |a| a['id'] }).to eq([article_a.id, article_b.id])
    end

    it 'does not let a non-admin agent change the featured set' do
      post url, params: { ids: [article_a.id] }, headers: agent.create_new_auth_token

      expect(response).not_to have_http_status(:success)
      expect(article_a.reload.featured?).to be(false)
    end
  end
end
