# frozen_string_literal: true

module Umi::CustomerAcknowledgementConversation
  extend ActiveSupport::Concern

  included do
    before_update :close_umi_acknowledgement_wait
  end

  private

  def close_umi_acknowledgement_wait
    return unless will_save_change_to_status? && (resolved? || snoozed?)

    settings = Umi::CustomerAcknowledgement.configuration
    return unless settings
    return unless settings.fetch('inbox_ids').include?(inbox_id)

    self.additional_attributes = additional_attributes.merge(Umi::CustomerAcknowledgement::BOUNDARY => messages.maximum(:id) || 0)
  end
end
