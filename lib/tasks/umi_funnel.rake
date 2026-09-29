# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

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

namespace :umi do
  namespace :funnel do
    desc 'Classify conversation (internal CONVERSATION_ID, ACCOUNT_ID, ACTOR_ID, STATUS, REASON, MESSAGE_IDS; cite IDs rather than personal details)'
    task qualify: :environment do
      account = Account.find(ENV.fetch('ACCOUNT_ID'))
      event = Umi::Funnel::ConversationTransition.new(conversation: account.conversations.find(ENV.fetch('CONVERSATION_ID')),
                                                      actor: account.users.find(ENV.fetch('ACTOR_ID')), status: ENV.fetch('STATUS'),
                                                      reason: ENV.fetch('REASON'),
                                                      evidence_message_ids: ENV.fetch('MESSAGE_IDS', '').split(',')).perform
      puts JSON.generate(event_id: event.id, status: event.payload.fetch('status'))
    end

    desc 'Request Shopify reconciliation (ACCOUNT_ID and either ORDER_IDS or SINCE UTC ISO8601 within 90 days)'
    task reconcile: :environment do
      account = Account.find(ENV.fetch('ACCOUNT_ID'))
      if ENV['ORDER_IDS'].present? && ENV['SINCE'].present?
        raise ArgumentError, 'Provide either ORDER_IDS or SINCE'
      elsif ENV['ORDER_IDS'].present?
        ids = ENV.fetch('ORDER_IDS').split(',', -1).uniq
        raise ArgumentError, 'Provide 1–50 positive order IDs' unless ids.size.between?(1, 50) && ids.all? { |id| id.match?(/\A[1-9]\d*\z/) }

        hook = account.hooks.where(app_id: 'shopify', status: :enabled).sole
        ids.each { |id| Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: hook.reference_id, order_id: id) }
        puts JSON.generate(requested: ids.size)
      else
        puts JSON.generate(Umi::Funnel::OrderRecovery.perform(account_id: account.id, since: ENV.fetch('SINCE')))
      end
    end

    desc 'Operational response aggregates (ACCOUNT_ID, SINCE, UNTIL; optional AS_OF, INBOX_ID)'
    task operations: :environment do
      puts JSON.generate(Umi::Funnel::OperationalReport.perform(account_id: ENV.fetch('ACCOUNT_ID'), since: ENV.fetch('SINCE'),
                                                                until_time: ENV.fetch('UNTIL'), as_of: ENV.fetch('AS_OF') { Time.current },
                                                                inbox_id: ENV['INBOX_ID'].presence))
    end

    desc 'Aggregate funnel report (ACCOUNT_ID and SINCE ISO8601 required, optional UNTIL)'
    task report: :environment do
      puts JSON.generate(Umi::Funnel::Report.perform(account_id: ENV.fetch('ACCOUNT_ID'), since: Time.iso8601(ENV.fetch('SINCE')),
                                                     until_time: ENV['UNTIL'] ? Time.iso8601(ENV.fetch('UNTIL')) : Time.current))
    end
  end
end

# rubocop:enable Metrics/BlockLength
