# frozen_string_literal: true

module Umi::Funnel::CustomerContact
  extend ActiveSupport::Concern

  included do
    after_update_commit :enqueue_umi_customer_projection
    after_update_commit :enqueue_umi_profile_refresh
  end

  private

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def enqueue_umi_profile_refresh
    return unless Umi::Funnel::CustomerContextSync.refreshable?(self)

    if saved_change_to_email? || saved_change_to_phone_number?
      Umi::Funnel::ProfileSyncJob.perform_later(id, force: true)
      return
    end
    return unless saved_change_to_additional_attributes?

    before, after = saved_change_to_additional_attributes
    binding_changed = before.values_at('umi_klaviyo_profile_id',
                                       'umi_klaviyo_binding') != after.values_at('umi_klaviyo_profile_id', 'umi_klaviyo_binding')
    pending_changed = Umi::Funnel::Configuration::ROLES.keys.any? do |key|
      pending = after.dig('umi_klaviyo_sync', 'roles', key, 'pending')
      pending && pending != before.dig('umi_klaviyo_sync', 'roles', key, 'pending')
    end
    Umi::Funnel::ProfileSyncJob.perform_later(id, force: true) if binding_changed || pending_changed
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def enqueue_umi_customer_projection
    return unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)
    return unless saved_change_to_custom_attributes? || saved_change_to_additional_attributes?

    Umi::Funnel::CustomerProjectionJob.perform_later(id)
  end
end
