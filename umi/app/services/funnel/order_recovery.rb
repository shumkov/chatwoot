# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize

class Umi::Funnel::OrderRecovery
  def self.perform(account_id:, since:)
    raise ArgumentError, 'Funnel account disabled' unless Umi::Funnel::Configuration.enabled?(account_id)

    start = Time.iso8601(since)
    finish = Time.current
    raise ArgumentError, 'Recovery window must be within the last 90 days' unless start.between?(finish - 90.days, finish)

    hook = Integrations::Hook.where(account_id: account_id, app_id: 'shopify', status: :enabled).sole
    client = Umi::Shopify::ClientFactory.client_for(hook)
    query = { status: 'any', updated_at_min: start.utc.iso8601, updated_at_max: finish.utc.iso8601, limit: 250, fields: 'id' }
    count = 0
    loop do
      response = client.get(path: 'orders', query: query)
      response.body.fetch('orders').each do |order|
        Umi::Shopify::OrderFinancialStateService.request(account_id: account_id, shop_domain: hook.reference_id, order_id: order.fetch('id'))
        count += 1
      end
      break if response.next_page_info.blank?

      query = { page_info: response.next_page_info, limit: 250, fields: 'id' }
    end
    { requested: count, completed_discovery: true }
  end
end

# rubocop:enable Metrics/AbcSize
