# frozen_string_literal: true

class Umi::Shopify::DraftCommand
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def self.parse!(source)
    raise ArgumentError, 'Staff command is unavailable' unless Umi::Shopify::ProductSource.staff_source?(source)

    content = source.content.to_s
    raise ArgumentError, 'Use one complete private command' if content.match?(/[\r\n\u2028\u2029]/)

    qr = content.match(%r{\A/payment-qr (draft|order):([1-9]\d*)\z})
    return { type: 'qr', kind: qr[1], id: qr[2] } if qr

    match = content.match(%r{\A/draft-order[ \t]+(preview[ \t]+)?(.+?)[ \t]+market=([A-Z]{2})[ \t]*\z})
    raise ArgumentError, 'Provide a complete basket and explicit market' unless match

    items = match[2].split(/[ \t]+/).map do |part|
      item = part.match(/\A([1-9]\d*):([1-9]\d*)\z/)
      raise ArgumentError, 'Invalid draft basket' unless item

      [item[1], item[2].to_i]
    end
    raise ArgumentError, 'Duplicate variants in draft basket' unless items.map(&:first).uniq.length == items.length

    { type: 'draft', preview: match[1].present?, market: match[3], items: items.to_h }
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def self.read!(hook, id, command, marker, customer_id)
    draft = fetch_draft!(hook, id)
    validate_draft!(draft, id, command, marker, customer_id)
    object(draft)
  end

  def self.fetch_draft!(hook, id)
    raise ArgumentError, 'Invalid draft ID' unless id.match?(%r{\Agid://shopify/DraftOrder/[1-9]\d*\z})

    client = Umi::Shopify::ClientFactory.graphql_client_for(hook)
    response = client.query(query: <<~GRAPHQL, variables: { id: id }).body
      query($id: ID!) { draftOrder(id: $id) {
        id name updatedAt status order { id } customer { id displayName email phone }
        tags customAttributes { key value } totalPriceSet { presentmentMoney { amount currencyCode } }
        lineItems(first: 250) { nodes { quantity variant { id } } pageInfo { hasNextPage } }
      } }
    GRAPHQL
    raise Umi::Shopify::CommerceError, 'shopify_unavailable' if response['errors'].present?

    response.dig('data', 'draftOrder')
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def self.validate_draft!(draft, id, command, marker, customer_id)
    raise ArgumentError, 'Draft is not open' unless draft && draft['id'] == id && draft['status'] == 'OPEN' && draft['order'].nil?
    raise ArgumentError, 'Draft customer changed' unless draft.dig('customer', 'id') == customer_id

    attributes = draft.fetch('customAttributes').to_h { |item| [item.fetch('key'), item.fetch('value')] }
    unless draft.fetch('tags').include?(marker) && attributes['umi_chatwoot_source'] == marker && attributes['umi_market'] == command[:market]
      raise ArgumentError, 'Draft source or market does not match command'
    end

    validate_items!(draft.fetch('lineItems'), command[:items])
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def self.validate_items!(lines, expected)
    items = lines.fetch('nodes').map { |item| [item.dig('variant', 'id')&.split('/')&.last, item.fetch('quantity')] }
    return if !lines.dig('pageInfo', 'hasNextPage') && items.size == expected.size && items.to_h == expected

    raise ArgumentError, 'Draft basket does not match command'
  end

  def self.object(draft)
    customer = draft['customer']&.then do |value|
      { 'id' => value.fetch('id').split('/').last, 'name' => value['displayName'], 'email' => value['email'], 'phone' => value['phone'] }
    end
    money = draft.fetch('totalPriceSet').fetch('presentmentMoney')
    { 'kind' => 'draft', 'id' => draft.fetch('id').split('/').last, 'name' => draft.fetch('name'), 'updated_at' => draft.fetch('updatedAt'),
      'customer' => customer, 'status' => 'OPEN', 'amount' => money.fetch('amount'), 'currency' => money.fetch('currencyCode') }
  end
end
