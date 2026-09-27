# frozen_string_literal: true

namespace :umi do
  namespace :funnel do
    desc 'Report current Shopify order payments (ACCOUNT_ID and comma-separated ORDER_IDS required)'
    task paid_orders: :environment do
      report = Umi::Shopify::PaidOrderReport.new(account_id: ENV.fetch('ACCOUNT_ID', nil),
                                                 order_ids: ENV.fetch('ORDER_IDS', '').split(',', -1)).perform
      puts JSON.generate(report)
    end
  end
end
