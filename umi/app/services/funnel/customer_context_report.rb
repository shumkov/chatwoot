# frozen_string_literal: true

class Umi::Funnel::CustomerContextReport
  def self.perform(account:, as_of: Time.current)
    new(account, as_of).perform
  end

  def initialize(account, as_of)
    @account = account
    @as_of = as_of
    @report = {
      scope: 'all_account_contacts', observed_at: as_of.utc.iso8601, contacts_count: 0,
      stages: Umi::Funnel::Configuration::STAGES.index_with(0),
      roles: Umi::Funnel::Configuration::ROLES.keys.index_with { Umi::Funnel::Configuration::ROLE_VALUES.index_with(0) },
      identity: { bound: 0, unbound: 0 }, sync: { fresh: 0, stale: 0, unknown: 0, error: 0, pending: 0 },
      observation_age_seconds: %i[profile payment segments].index_with { { known: 0, unknown: 0, oldest: nil } }
    }
  end

  def perform
    @account.contacts.select(:id, :custom_attributes, :additional_attributes).find_each do |contact|
      next if contact.additional_attributes['umi_profile_redacted']

      count_contact(contact)
    end
    @report
  end

  private

  # rubocop:disable Metrics/AbcSize
  def count_contact(contact)
    attributes = contact.custom_attributes
    metadata = contact.additional_attributes
    state = metadata.fetch('umi_klaviyo_sync', {})
    @report[:contacts_count] += 1
    @report[:stages][attributes.fetch('umi_funnel_stage', 'unclassified')] += 1
    @report[:roles].each do |key, counts|
      counts[attributes.fetch(key, 'unknown')] += 1
    end
    bound = metadata['umi_klaviyo_profile_id'].present? && metadata['umi_klaviyo_binding'].present?
    @report[:identity][bound ? :bound : :unbound] += 1
    @report[:sync][freshness(state)] += 1
    @report[:sync][:error] += 1 if state['error'].present?
    @report[:sync][:pending] += 1 if state.fetch('roles', {}).values.any? { |role| role['pending'].present? }
    record_age(:profile, state['checked_at'])
    record_age(:payment, state['payment_snapshot_at'])
    record_age(:segments, state.dig('segments', 'observed_at'))
  end
  # rubocop:enable Metrics/AbcSize

  def freshness(state) # rubocop:disable Metrics/CyclomaticComplexity
    return :unknown if state.empty?
    return :stale unless state['status'] == 'fresh' && state['error'].blank?
    return :stale unless recent?(state['payment_snapshot_at'], 2.hours)
    return :fresh unless state['buyer_lifecycle'] == 'non_buyer'

    membership = state.fetch('segments', {})
    membership['complete'] && recent?(membership['observed_at'], 15.minutes) ? :fresh : :stale
  end

  def recent?(timestamp, lifetime)
    age = age_seconds(timestamp)
    age && age < lifetime
  end

  def record_age(source, timestamp)
    row = @report[:observation_age_seconds].fetch(source)
    age = age_seconds(timestamp)
    row[age ? :known : :unknown] += 1
    row[:oldest] = [row[:oldest] || 0, age.floor].max if age
  end

  def age_seconds(timestamp)
    age = @as_of - Time.iso8601(timestamp.to_s)
    age if age >= 0
  rescue ArgumentError
    nil
  end
end
