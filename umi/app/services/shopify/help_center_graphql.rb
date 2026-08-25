# frozen_string_literal: true

# UMI patch: the Shopify GraphQL calls the Help Center translation work shares —
# the sync, the importer and the status report all need the same three things:
# a client built from the account's integration hook, the set of help-blog
# articles keyed by the Chatwoot article they mirror, and a query helper that
# treats a GraphQL error as a failure rather than as empty data.
#
# Translations have no REST surface, which is why this exists alongside the REST
# client the English article sync uses.
class Umi::Shopify::HelpCenterGraphql
  # A GraphQL error arrives with HTTP 200. Returning an empty hash would read to
  # every caller as "Shopify has nothing", which is indistinguishable from a
  # missing article and would silently strand a translation.
  class QueryFailed < StandardError; end

  # The corpus fits in one page many times over. If it ever stops fitting, the
  # articles past the cut would look absent rather than unfetched.
  class TooManyResults < StandardError; end

  PAGE_SIZE = 250

  def self.for_account(account_id)
    hook = Integrations::Hook.find_by(account_id: account_id, app_id: 'shopify')
    return nil if hook.blank? || hook.access_token.blank?

    new(hook)
  end

  attr_reader :hook

  def initialize(hook)
    @hook = hook
  end

  def call(query, **variables)
    response = client.query(query: query, variables: variables.presence, response_as_struct: false)
    body = response.body || {}
    raise QueryFailed, Array(body['errors']).pluck('message').join('; ') if body['errors'].present?

    body['data'] || {}
  end

  # Everything under `first:` in one go, with a loud failure rather than a quiet
  # truncation. Returns the connection's nodes.
  def nodes(query, path, **variables)
    connection = call(query, **variables)[path] || {}
    raise TooManyResults, "#{path} exceeded one page of #{PAGE_SIZE}" if connection.dig('pageInfo', 'hasNextPage')

    connection['nodes'] || []
  end

  def scope?(name)
    hook.settings.to_h['scope'].to_s.split(',').map(&:strip).include?(name)
  end

  # Shopify article gid => the Chatwoot article id it mirrors, for the help blog
  # only. Matched on the same custom.chatwoot_id metafield the English sync writes.
  def article_gids
    @article_gids ||= nodes(ARTICLES_QUERY, 'articles').each_with_object({}) do |node, acc|
      next unless node.dig('blog', 'handle') == blog_handle

      chatwoot_id = node.dig('metafield', 'value')
      acc[node['id']] = chatwoot_id.to_s if chatwoot_id.present?
    end
  end

  def shop_locale?(locale)
    Array(call(SHOP_LOCALES_QUERY)['shopLocales']).any? { |entry| entry['locale'] == locale.to_s }
  end

  def blog_handle
    ENV.fetch('UMI_HC_BLOG_HANDLE', 'help')
  end

  private

  def client
    @client ||= Umi::Shopify::ClientFactory.graphql_client_for(hook)
  end

  SHOP_LOCALES_QUERY = <<~GRAPHQL
    query ShopLocales { shopLocales { locale published } }
  GRAPHQL

  ARTICLES_QUERY = <<~GRAPHQL
    query HelpArticles {
      articles(first: 250) {
        nodes {
          id
          blog { handle }
          metafield(namespace: "custom", key: "chatwoot_id") { value }
        }
        pageInfo { hasNextPage }
      }
    }
  GRAPHQL
end
