# frozen_string_literal: true

module Umi::Funnel::CustomerContact
  extend ActiveSupport::Concern

  included do
    after_update_commit :enqueue_umi_customer_projection
  end

  private

  def enqueue_umi_customer_projection
    return unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)
    return unless saved_change_to_custom_attributes? || saved_change_to_additional_attributes?

    Umi::Funnel::CustomerProjectionJob.perform_later(id)
  end
end
