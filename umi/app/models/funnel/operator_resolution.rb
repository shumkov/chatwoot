# frozen_string_literal: true

module Umi::Funnel::OperatorResolution
  extend ActiveSupport::Concern

  KEYS = %w[umi_operator_resolved_at umi_operator_resolved_message_id].freeze

  included do
    before_update :stamp_umi_operator_resolution
  end

  private

  def stamp_umi_operator_resolution
    return unless will_save_change_to_status? && resolved? && Umi::Funnel::Configuration.account_ids.include?(account_id)

    # Commit the boundary with the status, before asynchronous reporting can lag behind a reopen.
    self.additional_attributes = additional_attributes.merge(
      'umi_operator_resolved_at' => Time.current.utc.iso8601(6),
      'umi_operator_resolved_message_id' => messages.maximum(:id) || 0
    )
  end
end
