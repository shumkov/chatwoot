# frozen_string_literal: true

class Umi::Funnel::CustomerContextSync
  INTERVAL = 15.minutes

  def initialize(contact_id, client: nil)
    @contact_id = contact_id
    @client = client
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def perform
    @contact = Contact.find_by(id: @contact_id)
    return unless @contact && self.class.eligible?(@contact)

    @expected = self.class.version(@contact)
    @profile_id = @expected.fetch('profile_id')
    @client ||= Umi::Funnel::KlaviyoClient.new
    properties = read_properties
    return unless properties

    decisions = role_decisions(properties)
    writes = decisions.select { |_key, decision| decision['write'] }.transform_values { |decision| decision['value'] }
    if writes.any?
      properties = write_and_readback(writes, properties)
      return unless properties

      decisions = role_decisions(properties)
      raise Umi::Funnel::KlaviyoClient::Error, 'Role changed during readback' if decisions.values.any? { |decision| decision['write'] }
    end
    acknowledge(properties, decisions)
  rescue ActiveRecord::RecordNotFound
    nil
  rescue Umi::Funnel::KlaviyoClient::Error => e
    record_error(e)
    raise
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def self.candidate?(contact)
    Umi::Funnel::Configuration.customer_context_enabled?(contact.account_id) &&
      contact.account_id.to_s == ENV['UMI_FUNNEL_KLAVIYO_ACCOUNT_ID'] && !contact.additional_attributes['umi_profile_redacted']
  end

  def self.refreshable?(contact)
    candidate?(contact) && (eligible?(contact) || Umi::Funnel::ProfileBinding.identifiers(contact).any?)
  end

  def self.eligible?(contact)
    candidate?(contact) && contact.additional_attributes['umi_klaviyo_profile_id'].present? &&
      contact.additional_attributes['umi_klaviyo_binding'].present?
  end

  def self.version(contact)
    { 'profile_id' => contact.additional_attributes['umi_klaviyo_profile_id'],
      'binding' => contact.additional_attributes['umi_klaviyo_binding'],
      'identifiers' => Umi::Funnel::ProfileBinding.identifiers(contact),
      'roles' => contact.additional_attributes.dig('umi_klaviyo_sync', 'roles').to_h }
  end

  private

  def read_properties
    profile = @client.profile(@profile_id, properties: true)
    return unless current?

    validate_identity!(profile)
    profile.fetch('attributes').fetch('properties')
  end

  def write_and_readback(writes, properties)
    return unless record_submission(writes, properties)

    @client.update_roles(@profile_id, writes)
    properties = read_properties
    return unless properties
    raise Umi::Funnel::KlaviyoClient::Error, 'Role readback differs' unless writes.all? { |key, value| role_value(properties, key) == value }

    properties
  end

  def record_submission(writes, properties)
    fields = @expected.fetch('roles').deep_dup
    writes.each do |key, value|
      fields.fetch(key).merge!('baseline_known' => true, 'baseline' => role_value(properties, key))
      fields.fetch(key)['submitted'] = { 'value' => value, 'revision' => fields.fetch(key).fetch('pending').fetch('revision'),
                                         'identity' => @expected.except('roles') }
    end
    Umi::Funnel::CustomerMutation.new(@contact, source: 'remote').perform(
      sync: { 'expected' => @expected, 'metadata' => { 'roles' => fields } }
    )
    @expected = @expected.merge('roles' => fields)
    current?
  end

  def current?
    @contact.reload
    self.class.eligible?(@contact) && self.class.version(@contact) == @expected
  end

  def validate_identity!(profile)
    return if Umi::Funnel::ProfileBinding.matches?(@contact, profile, @profile_id)

    raise Umi::Funnel::KlaviyoClient::Error, 'Profile identity changed'
  end

  def role_value(properties, key)
    return 'unknown' unless properties.key?(key)
    return 'yes' if properties[key] == true
    return 'no' if properties[key] == false

    raise Umi::Funnel::KlaviyoClient::Error, "Invalid boolean property #{key}"
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def role_decisions(properties)
    Umi::Funnel::Configuration::ROLES.keys.index_with do |key|
      remote = role_value(properties, key)
      field = @expected.fetch('roles').fetch(key, {})
      pending = field['pending']
      decision = { 'value' => remote }
      next decision unless pending && remote != pending['value']
      next decision if pending['source'] == 'ai' && remote == 'no'

      if writable_role?(field, remote)
        decision = { 'value' => pending.fetch('value'), 'write' => true }
      elsif field['baseline_known'] && pending['source'] == 'operator'
        decision['conflict'] = { 'local' => pending.fetch('value'), 'remote' => remote, 'actor_id' => pending['actor_id'] }
      end
      decision
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def writable_role?(field, remote)
    submitted = field['submitted']
    return true if submitted && submitted['identity'] == @expected.except('roles') && submitted['value'] == remote

    remote == (field['baseline_known'] ? field['baseline'] : 'unknown')
  end

  # rubocop:disable Metrics/AbcSize
  def acknowledge(properties, decisions)
    fields = @expected.fetch('roles').deep_dup
    decisions.each do |key, decision|
      field = fields[key] ||= {}
      field['baseline_known'] = true
      field['baseline'] = decision.fetch('value')
      field['conflict'] = decision['conflict'].merge('observed_at' => Time.current.utc.iso8601) if decision['conflict']
      field.delete('pending')
      field.delete('submitted')
    end
    metadata = { 'roles' => fields, 'checked_at' => Time.current.utc.iso8601, 'next_sync_at' => INTERVAL.from_now.utc.iso8601, 'error' => nil }
    metadata['service'] = service_snapshot(properties)
    Umi::Funnel::CustomerMutation.new(@contact, source: 'remote').perform(
      roles: decisions.transform_values { |decision| decision.fetch('value') }, snapshot: paid_snapshot(properties),
      sync: { 'expected' => @expected, 'metadata' => metadata, 'conflicts' => decisions.filter_map do |key, value|
        [key, value['conflict']] if value['conflict']
      end.to_h }
    )
  end
  # rubocop:enable Metrics/AbcSize

  def service_snapshot(properties)
    value = properties['umi_service_recovery_state']
    return { 'state' => 'unknown' } if value.nil?

    raise Umi::Funnel::KlaviyoClient::Error, 'Invalid service snapshot' unless %w[clear hold unknown].include?(value)

    at = Time.iso8601(properties.fetch('umi_service_snapshot_at').to_s)
    { 'state' => value, 'observed_at' => at.utc.iso8601 }
  rescue KeyError, ArgumentError
    { 'state' => 'unknown' }
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def paid_snapshot(properties)
    at = Time.iso8601(properties.fetch('umi_payment_snapshot_at').to_s)
    return { 'status' => 'stale' } unless at > 2.hours.ago && at <= Time.current

    lifecycle = properties.fetch('umi_buyer_lifecycle')
    count = properties.fetch('umi_paid_order_count')
    complete = properties.fetch('umi_paid_history_complete')
    valid = %w[non_buyer client repeat unclassified].include?(lifecycle) && [true, false].include?(complete) &&
            (count.nil? || (count.is_a?(Integer) && count >= 0))
    raise Umi::Funnel::KlaviyoClient::Error, 'Invalid paid snapshot' unless valid

    { 'buyer_lifecycle' => lifecycle, 'paid_order_count' => count, 'paid_history_complete' => complete,
      'payment_snapshot_at' => at.utc.iso8601 }
  rescue KeyError, ArgumentError
    { 'status' => 'stale' }
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def record_error(error)
    return unless @expected

    delay = error.is_a?(Umi::Funnel::KlaviyoClient::RateLimited) ? error.retry_after.seconds : INTERVAL
    Umi::Funnel::CustomerMutation.new(@contact, source: 'remote').perform(
      snapshot: { 'status' => 'stale' },
      sync: { 'expected' => @expected, 'metadata' => { 'error' => error.class.name, 'failed_at' => Time.current.utc.iso8601,
                                                       'next_sync_at' => delay.from_now.utc.iso8601 } }
    )
  end
end
