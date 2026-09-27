# frozen_string_literal: true

namespace :umi do
  namespace :funnel do
    desc 'Export conversation cohorts (ACCOUNT_ID, FROM, UNTIL, AS_OF UTC ISO8601, HORIZON_DAYS required)'
    task cohorts: :environment do
      report = Umi::Funnel::CohortReport.perform(account_id: ENV.fetch('ACCOUNT_ID'), from: ENV.fetch('FROM'), until_time: ENV.fetch('UNTIL'),
                                                 as_of: ENV.fetch('AS_OF'), horizon_days: ENV.fetch('HORIZON_DAYS'))
      puts JSON.generate(report)
    end
  end
end
