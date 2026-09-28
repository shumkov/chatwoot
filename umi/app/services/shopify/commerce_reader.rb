# frozen_string_literal: true

class Umi::Shopify::CommerceReader
  CUSTOMER_FIELDS = 'id displayName email phone'
  ORDER_FIELDS = "id name createdAt updatedAt displayFinancialStatus customer { #{CUSTOMER_FIELDS} } " \
                 'totalPriceSet { presentmentMoney { amount currencyCode } }'.freeze
  DRAFT_FIELDS = "id name createdAt updatedAt status customer { #{CUSTOMER_FIELDS} } " \
                 'totalPriceSet { presentmentMoney { amount currencyCode } } order { id }'.freeze

  def initialize(hook)
    @hook = hook
    @client = Umi::Shopify::ClientFactory.graphql_client_for(hook)
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def reference(url)
    uri = URI.parse(url.to_s)
    raise Umi::Shopify::CommerceError, 'invalid_reference' unless uri.scheme == 'https' && uri.userinfo.nil?

    path = if uri.host == @hook.reference_id
             uri.path.delete_prefix('/admin')
           elsif uri.host == 'admin.shopify.com'
             uri.path.sub(%r{\A/store/[^/]+}, '')
           end
    match = path&.match(%r{\A/(customers|orders|draft_orders)/([1-9]\d*)/?\z})
    raise Umi::Shopify::CommerceError, 'invalid_reference' unless match

    [{ 'customers' => 'customer', 'orders' => 'order', 'draft_orders' => 'draft' }.fetch(match[1]), match[2]]
  rescue URI::InvalidURIError
    raise Umi::Shopify::CommerceError, 'invalid_reference'
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def fetch(kind, id)
    type, fields = { 'customer' => ['Customer', CUSTOMER_FIELDS], 'order' => ['Order', ORDER_FIELDS],
                     'draft' => ['DraftOrder', DRAFT_FIELDS] }.fetch(kind)
    raise Umi::Shopify::CommerceError, 'invalid_reference' unless id.to_s.match?(/\A[1-9]\d*\z/)

    result = query("query($id: ID!) { node(id: $id) { __typename ... on #{type} { #{fields} } } }", { id: "gid://shopify/#{type}/#{id}" })['node']
    raise Umi::Shopify::CommerceError, 'unavailable' unless result && result['__typename'] == type

    kind == 'customer' ? customer(result) : object(result, kind)
  end

  def customers(search, after: nil)
    if search.to_s.start_with?('https://')
      kind, id = reference(search)
      raise Umi::Shopify::CommerceError, 'invalid_reference' unless kind == 'customer'

      return { items: [fetch(kind, id)], cursor: nil }
    end
    return { items: [], cursor: nil } if search.to_s.strip.empty?

    data = query("query($search: String!, $after: String) { customers(first: 20, query: $search, after: $after) {
      nodes { #{CUSTOMER_FIELDS} } pageInfo { hasNextPage endCursor } } }", { search: search.to_s.strip.first(256), after: after })
    page(data.fetch('customers')) { |node| customer(node) }
  end

  def history(customer_id, kind:, after: nil)
    return { items: [], cursor: nil } if customer_id.blank?

    root, fields, sort = kind == 'draft' ? ['draftOrders', DRAFT_FIELDS, 'UPDATED_AT'] : ['orders', ORDER_FIELDS, 'CREATED_AT']
    data = query("query($search: String!, $after: String) { #{root}(first: 20, query: $search, after: $after, sortKey: #{sort}, reverse: true) {
      nodes { #{fields} } pageInfo { hasNextPage endCursor } } }", { search: "customer_id:#{customer_id}", after: after })
    connection = data.fetch(root)
    connection['nodes'] = connection.fetch('nodes').select { |node| numeric_id(node.dig('customer', 'id')) == customer_id.to_s }
    page(connection) { |node| object(node, kind) }
  end

  def draft_access?
    installation = query('query { currentAppInstallation { accessScopes { handle } } }').fetch('currentAppInstallation')
    installation.fetch('accessScopes').any? { |scope| scope['handle'] == 'read_draft_orders' }
  end

  private

  def query(document, variables = {})
    body = @client.query(query: document, variables: variables).body
    if body['errors'].present?
      denied = body['errors'].any? { |error| error.dig('extensions', 'code') == 'ACCESS_DENIED' }
      raise Umi::Shopify::CommerceError, denied ? 'access_denied' : 'shopify_unavailable'
    end
    body.fetch('data')
  rescue ShopifyAPI::Errors::HttpResponseError, Timeout::Error, SocketError
    raise Umi::Shopify::CommerceError, 'shopify_unavailable'
  end

  def page(connection, &)
    { items: connection.fetch('nodes').map(&),
      cursor: connection.dig('pageInfo', 'hasNextPage') ? connection.dig('pageInfo', 'endCursor') : nil }
  end

  def numeric_id(gid)
    gid&.split('/')&.last
  end

  def customer(node)
    return nil unless node

    { 'id' => numeric_id(node.fetch('id')), 'name' => node['displayName'], 'email' => node['email'], 'phone' => node['phone'] }
  end

  def object(node, kind)
    money = node.fetch('totalPriceSet').fetch('presentmentMoney')
    id = numeric_id(node.fetch('id'))
    { 'kind' => kind, 'id' => id, 'name' => node.fetch('name'), 'updated_at' => node.fetch('updatedAt'), 'created_at' => node['createdAt'],
      'customer' => customer(node['customer']), 'status' => node['displayFinancialStatus'] || node['status'],
      'amount' => money.fetch('amount'), 'currency' => money.fetch('currencyCode'), 'order_id' => numeric_id(node.dig('order', 'id')),
      'admin_url' => "https://#{@hook.reference_id}/admin/#{kind == 'draft' ? 'draft_orders' : 'orders'}/#{id}" }
  end
end
