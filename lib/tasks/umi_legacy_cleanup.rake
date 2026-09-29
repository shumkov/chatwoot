# frozen_string_literal: true

namespace :umi do
  namespace :legacy_cleanup do
    %w[inventory apply restore prune].each do |operation|
      desc "#{operation.capitalize} the fixed account 1 stage-one legacy cleanup"
      task operation => :environment do
        cleanup = Umi::Funnel::LegacyCleanup.new(review_sentinel_confirmed: ENV['REVIEW_SENTINEL_CONFIRMED'] == 'true')
        puts JSON.generate(cleanup.public_send(operation))
      end
    end
  end
end
