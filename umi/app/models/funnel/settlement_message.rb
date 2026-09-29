# frozen_string_literal: true

module Umi::Funnel::SettlementMessage
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_umi_settlement_command
  end

  private

  def enqueue_umi_settlement_command
    return unless content_attributes.dig(Umi::Funnel::SettlementCommand::KEY, 'status') == 'pending'

    Umi::Funnel::SettlementCommandJob.perform_later(id)
  rescue StandardError => e
    Rails.logger.error("[umi-funnel] settlement enqueue failed: #{e.class}")
  end
end
