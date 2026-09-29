# frozen_string_literal: true

class Umi::Funnel::DeliveryAutomation
  PENDING_REASONS = [nil, 'dispatch_disabled', 'account_disabled', 'identity_unlinked', 'profile_unbound', 'purchase_channel_disabled',
                     'chat_settlement_unconfirmed', 'chat_settlement_canceled', 'purchase_evidence_missing', 'financial_observation_stale',
                     'purchase_source_unknown', 'website_checkout', 'prepared_source_changed', 'payment_not_verified',
                     'financial_identity_conflict', 'channel_identity_mismatch'].freeze
  READBACK_DELAYS = [5.minutes, 30.minutes, 2.hours].freeze
  LIMIT = 100

  def self.enabled?(destination)
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("UMI_FUNNEL_#{destination.upcase}_ENABLED", false))
  end

  def self.enqueue # rubocop:disable Metrics/AbcSize
    destinations = %w[meta klaviyo].select { |destination| enabled?(destination) }
    scope = Umi::ConversionDelivery.joins(:conversation_event)
                                   .where(umi_conversation_events: { account_id: Umi::Funnel::Configuration.account_ids, redacted_at: nil },
                                          destination: destinations)
    scope.where(state: 'pending', reason: PENDING_REASONS).order(:updated_at, :id).limit(LIMIT).each do |delivery|
      Umi::Funnel::DeliveryJob.perform_later(delivery.id) if Umi::Funnel::DeliveryService.new(delivery).ready_for_schedule?
    ensure
      delivery.touch # rubocop:disable Rails/SkipsModelValidations
    end
    due = READBACK_DELAYS.each_with_index.map do |delay, index|
      scope.where(destination: 'klaviyo', state: 'accepted', readback_attempt_count: index).where(accepted_at: ..(Time.current - delay))
    end.reduce(:or)
    due.order(:id).limit(LIMIT).each { |delivery| Umi::Funnel::ReadbackJob.perform_later(delivery.id) }
  end
end
