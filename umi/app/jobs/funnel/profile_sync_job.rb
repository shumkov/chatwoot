# frozen_string_literal: true

class Umi::Funnel::ProfileSyncJob < MutexApplicationJob
  queue_as :low
  BATCH_SIZE = 250

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def perform(contact_id, force: false)
    contact = Contact.find_by(id: contact_id)
    return unless contact && Umi::Funnel::CustomerContextSync.refreshable?(contact)

    discover(contact) if contact.additional_attributes['umi_klaviyo_profile_id'].blank?
    return unless Umi::Funnel::CustomerContextSync.eligible?(contact.reload)

    profile_id = contact.additional_attributes.fetch('umi_klaviyo_profile_id')
    with_lock("umi-profile-sync:#{contact.account_id}:#{profile_id}", 2.minutes) do
      contact.reload
      next unless Umi::Funnel::CustomerContextSync.eligible?(contact) && contact.additional_attributes['umi_klaviyo_profile_id'] == profile_id

      state = contact.additional_attributes.fetch('umi_klaviyo_sync', {})
      next if state['next_sync_at'].present? && Time.iso8601(state['next_sync_at']) > Time.current &&
              (!force || state['error'] == Umi::Funnel::KlaviyoClient::RateLimited.name)

      Umi::Funnel::CustomerContextSync.new(contact.id).perform
    end
  rescue ActiveRecord::RecordNotFound
    nil
  rescue Umi::Funnel::KlaviyoClient::Error, MutexApplicationJob::LockAcquisitionError => e
    Rails.logger.warn("[umi-funnel] profile refresh #{contact_id}: #{e.class.name}")
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def self.enqueue_due
    account_id = ENV['UMI_FUNNEL_KLAVIYO_ACCOUNT_ID'].to_i
    return unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    scope = Contact.where(account_id: account_id)
                   .where("additional_attributes ->> 'umi_klaviyo_profile_id' IS NOT NULL")
                   .where("additional_attributes -> 'umi_klaviyo_binding' IS NOT NULL")
                   .where("COALESCE(additional_attributes ->> 'umi_profile_redacted', 'false') != 'true'")
    due = scope.where("(additional_attributes #>> '{umi_klaviyo_sync,next_sync_at}') IS NULL OR " \
                      "(additional_attributes #>> '{umi_klaviyo_sync,next_sync_at}')::timestamptz <= ?", Time.current)
    due.order(Arel.sql("additional_attributes #>> '{umi_klaviyo_sync,checked_at}' ASC NULLS FIRST"), :id)
       .limit(BATCH_SIZE).pluck(:id).each { |id| perform_later(id) }
    Umi::Funnel::SegmentRefreshJob.perform_later(account_id)
    Rails.logger.info("[umi-funnel] profile refresh capacity linked=#{scope.count} per_15m=#{BATCH_SIZE * 3} due=#{due.count}")
  end

  private

  def discover(contact) # rubocop:disable Metrics/AbcSize
    with_lock("umi-profile-discovery:#{contact.account_id}:#{contact.id}", 2.minutes) do
      contact.reload
      next unless Umi::Funnel::CustomerContextSync.refreshable?(contact) && contact.additional_attributes['umi_klaviyo_profile_id'].blank?
      next unless discovery_due?(contact)

      expected = Umi::Funnel::CustomerContextSync.version(contact).except('roles')
      begin
        Umi::Funnel::ProfileBinding.new(contact: contact).resolve { Umi::Funnel::CustomerContextSync.candidate?(contact) }
        observe_discovery(contact, expected, 'identity_unresolved') unless Umi::Funnel::CustomerContextSync.eligible?(contact)
      rescue Umi::Funnel::KlaviyoClient::RateLimited => e
        observe_discovery(contact, expected, e.class.name, delay: e.retry_after.seconds)
        self.class.set(wait: e.retry_after.seconds).perform_later(contact.id, force: true)
      rescue Umi::Funnel::KlaviyoClient::Error, ArgumentError => e
        observe_discovery(contact, expected, "identity_unresolved: #{e.class.name}")
      end
    end
  end

  def discovery_due?(contact)
    state = contact.additional_attributes.fetch('umi_klaviyo_sync', {})
    return true if state['next_sync_at'].blank? || Time.iso8601(state['next_sync_at']) <= Time.current
    return false if state['error'] == Umi::Funnel::KlaviyoClient::RateLimited.name

    state['identity_identifiers'] != Umi::Funnel::ProfileBinding.identifiers(contact)
  end

  def observe_discovery(contact, expected, error, delay: 15.minutes)
    metadata = { 'error' => error, 'checked_at' => Time.current.utc.iso8601, 'next_sync_at' => delay.from_now.utc.iso8601,
                 'identity_identifiers' => expected.fetch('identifiers') }
    Umi::Funnel::CustomerMutation.new(contact, source: 'remote').perform(
      snapshot: { 'status' => 'stale' }, sync: { 'expected' => expected, 'metadata' => metadata }
    )
  end
end
