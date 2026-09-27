# frozen_string_literal: true

class Umi::Funnel::DeliveryAutomation
  PENDING_REASONS = [nil, 'dispatch_disabled', 'account_disabled', 'identity_unlinked', 'profile_unbound'].freeze
  READBACK_DELAYS = [5.minutes, 30.minutes, 2.hours].freeze
  LIMIT = 100

  def self.enabled?(destination)
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("UMI_FUNNEL_#{destination.upcase}_ENABLED", false))
  end

  def self.enqueue
    destinations = %w[meta klaviyo].select { |destination| enabled?(destination) }
    scope = Umi::ConversionDelivery.joins(:conversation_event)
                                   .where(umi_conversation_events: { account_id: Umi::Funnel::Configuration.account_ids, redacted_at: nil },
                                          destination: destinations)
    scheduled = 0
    scope.where(state: 'pending', reason: PENDING_REASONS).find_each do |delivery|
      next unless Umi::Funnel::DeliveryService.new(delivery).ready_for_schedule?

      Umi::Funnel::DeliveryJob.perform_later(delivery.id)
      scheduled += 1
      break if scheduled == LIMIT
    end
    due = READBACK_DELAYS.each_with_index.map do |delay, index|
      scope.where(destination: 'klaviyo', state: 'accepted', readback_attempt_count: index).where(accepted_at: ..(Time.current - delay))
    end.reduce(:or)
    due.order(:id).limit(LIMIT).each { |delivery| Umi::Funnel::ReadbackJob.perform_later(delivery.id) }
  end
end
