# frozen_string_literal: true

class Umi::Shopify::OrderAttributionCanaryJob < ApplicationJob
  queue_as :low

  PAGE_LIMIT = 250

  def perform
    summary = Integrations::Hook.where(app_id: 'shopify', status: :enabled).find_each.with_object({ orders: 0, tagged: 0 }) do |hook, totals|
      check_hook(hook, totals)
    end

    raise "Shopify order-link canary found no tagged orders in the last #{window_days} days" if summary[:tagged].zero?

    touch_heartbeat
    Rails.logger.info("[umi-shopify-order-link] canary passed orders=#{summary[:orders]} tagged=#{summary[:tagged]}")
    summary
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    Rails.logger.error("[umi-shopify-order-link] canary failed: #{e.message}")
    nil
  end

  private

  def check_hook(hook, totals)
    client = Umi::Shopify::ClientFactory.client_for(hook)
    cursor = nil
    pages = 0

    loop do
      pages += 1
      raise "canary exceeded #{max_pages} pages for account #{hook.account_id}" if pages > max_pages

      response = client.get(path: 'orders.json', query: query_for(cursor))
      orders = response.body['orders'] || []
      totals[:orders] += orders.length
      totals[:tagged] += orders.count { |order| tagged?(order) }
      cursor = response.next_page_info
      break if cursor.blank?
    end
  end

  def query_for(cursor)
    return { limit: PAGE_LIMIT, page_info: cursor } if cursor.present?

    {
      status: 'any',
      created_at_min: window_start.utc.iso8601,
      limit: PAGE_LIMIT,
      fields: 'id,note_attributes'
    }
  end

  def tagged?(order)
    Array(order['note_attributes']).any? do |attribute|
      attribute['name'].to_s == '_cw' && attribute['value'].to_s.present?
    end
  end

  def touch_heartbeat
    path = ENV.fetch('UMI_SHOPIFY_ORDER_LINK_CANARY_HEARTBEAT', '/var/lib/netdata/umi-shopify-order-link.canary')
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
  end

  def window_days
    ENV.fetch('UMI_SHOPIFY_ORDER_LINK_CANARY_DAYS', '7').to_i
  end

  def window_start
    window_days.days.ago
  end

  def max_pages
    ENV.fetch('UMI_SHOPIFY_ORDER_LINK_CANARY_MAX_PAGES', '20').to_i
  end
end
