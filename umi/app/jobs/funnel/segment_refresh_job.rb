# frozen_string_literal: true

class Umi::Funnel::SegmentRefreshJob < MutexApplicationJob
  queue_as :low
  SEGMENTS = { 'chooser' => 'SS6aWp', 'seeker' => 'RUy6Wc' }.freeze
  METRICS = { 'site' => ['Active on Site', 'api'], 'product' => ['Viewed Product', 'api'],
              'cart' => ['Added to Cart', 'shopify'], 'checkout' => ['Checkout Started', 'shopify'] }.freeze
  RECENT_INTENT_NAME = 'UMI - Recent conversation intent'

  # rubocop:disable Metrics/AbcSize
  def perform(account_id)
    return unless account_id.to_s == ENV['UMI_FUNNEL_KLAVIYO_ACCOUNT_ID'] && Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    with_lock("umi-segment-refresh:#{account_id}", 15.minutes) do
      @account = Account.find(account_id)
      state = @account.custom_attributes.fetch('umi_segment_refresh', {})
      next if state['next_sync_at'].present? && Time.iso8601(state['next_sync_at']) > Time.current

      refresh
    end
  rescue Umi::Funnel::KlaviyoClient::Error => e
    delay = e.is_a?(Umi::Funnel::KlaviyoClient::RateLimited) ? e.retry_after.seconds : 15.minutes
    record_status('error' => e.class.name, 'failed_at' => Time.current.utc.iso8601, 'next_sync_at' => delay.from_now.utc.iso8601)
    Rails.logger.warn("[umi-funnel] segment refresh #{account_id}: #{e.class.name}")
  rescue MutexApplicationJob::LockAcquisitionError
    nil
  end
  # rubocop:enable Metrics/AbcSize

  private

  # rubocop:disable Metrics/AbcSize
  def refresh
    client = Umi::Funnel::KlaviyoClient.new
    metrics = client.metrics
    validate_segments!(client, metrics)
    contacts = Contact.where(account_id: @account.id).select { |contact| Umi::Funnel::CustomerContextSync.eligible?(contact) }
    versions = contacts.to_h { |contact| [contact.id, Umi::Funnel::CustomerContextSync.version(contact)] }
    linked = versions.values.pluck('profile_id').to_set
    observations = SEGMENTS.transform_values do |id|
      members = Set.new
      client.segment_profiles(id) { |profile| members << profile.fetch('id') if linked.include?(profile.fetch('id')) }
      members
    end
    observed_at = Time.current.utc.iso8601
    contacts.each { |contact| publish(contact, versions.fetch(contact.id), observations, observed_at) }
    record_status('error' => nil, 'checked_at' => observed_at, 'next_sync_at' => 5.minutes.from_now.utc.iso8601)
    refresh_recent_intent(client, metrics)
  end
  # rubocop:enable Metrics/AbcSize

  def validate_segments!(client, metrics)
    expected = definitions(metrics)
    SEGMENTS.each do |name, id|
      segment = client.segment(id)
      next if segment['id'] == id && segment.dig('attributes', 'name') == "UMI - #{name.capitalize}" &&
              segment.dig('attributes', 'definition') == expected.fetch(name)

      raise Umi::Funnel::KlaviyoClient::Error, 'Configured segment definition differs'
    end
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def refresh_recent_intent(client, metrics)
    return unless Umi::Funnel::Configuration.enabled?(@account.id) && Umi::Funnel::DeliveryAutomation.enabled?('klaviyo')

    state = @account.reload.custom_attributes.dig('umi_segment_refresh', 'recent_intent').to_h
    return if state['next_check_at'].present? && Time.iso8601(state['next_check_at']) > Time.current
    unless state['segment_id'].present? || state['create_attempted_at'].present? || confirmed_qualification?
      return record_recent_intent('status' => 'awaiting_qualification')
    end

    matches = metrics.select do |metric|
      metric.dig('attributes', 'name') == Umi::Funnel::DeliveryService::METRICS.fetch('conversation_qualified') &&
        metric.dig('attributes', 'integration', 'key') == 'api'
    end
    return record_recent_intent('status' => 'awaiting_metric') if matches.empty?

    raise Umi::Funnel::KlaviyoClient::Error, 'Ambiguous qualification metric' unless matches.one?

    metric_id = matches.first.fetch('id')
    definition = { condition_groups: [{ conditions: [activity_condition(metric_id)] }] }.deep_stringify_keys
    record_recent_intent('metric_id' => metric_id) if state['metric_id'] != metric_id
    id = state['segment_id']
    if id.blank?
      segments = client.segments(name: RECENT_INTENT_NAME)
      raise Umi::Funnel::KlaviyoClient::Error, 'Duplicate recent-intent segments' if segments.many?

      segment = segments.first
      if segment
        validate_recent_intent!(segment, definition)
        id = segment.fetch('id')
        record_recent_intent('segment_id' => id, 'status' => 'awaiting_readback')
      elsif state['create_attempted_at'].present?
        return record_recent_intent('status' => 'creation_unknown')
      else
        id = create_recent_intent(client, definition)
        return unless id
      end
    end
    segment = client.segment(id)
    raise Umi::Funnel::KlaviyoClient::Error, 'Recent-intent segment ID differs' unless segment['id'] == id

    validate_recent_intent!(segment, definition)
    record_recent_intent('status' => 'ready', 'last_error' => nil, 'next_check_at' => nil)
  rescue Umi::Funnel::KlaviyoClient::Error => e
    delay = e.is_a?(Umi::Funnel::KlaviyoClient::RateLimited) ? e.retry_after.seconds : 15.minutes
    record_recent_intent('status' => 'error', 'last_error' => e.message, 'next_check_at' => delay.from_now.utc.iso8601)
    Rails.logger.warn("[umi-funnel] recent-intent segment #{@account.id}: #{e.class.name}")
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def confirmed_qualification?
    Umi::ConversionDelivery.joins(:conversation_event)
                           .where(destination: 'klaviyo', state: 'confirmed')
                           .where.not(confirmed_at: nil).where.not(provider_reference: nil)
                           .exists?(umi_conversation_events: { account_id: @account.id, event_type: 'conversation_qualified', redacted_at: nil,
                                                               provenance: %w[operator classifier],
                                                               occurred_at: Umi::Funnel::Configuration.started_at..Time.current })
  end

  def create_recent_intent(client, definition) # rubocop:disable Metrics/AbcSize
    claimed = @account.with_lock do
      state = @account.custom_attributes.dig('umi_segment_refresh', 'recent_intent').to_h
      next false if state['segment_id'].present? || state['create_attempted_at'].present?
      next false if state['next_check_at'].present? && Time.iso8601(state['next_check_at']) > Time.current

      record_recent_intent('status' => 'creating', 'create_attempted_at' => Time.current.utc.iso8601)
      true
    end
    return unless claimed

    begin
      segment = client.create_segment(name: RECENT_INTENT_NAME, definition: definition)
    rescue Umi::Funnel::KlaviyoClient::RateLimited => e
      record_recent_intent('create_attempted_at' => nil, 'status' => 'error', 'last_error' => e.message,
                           'next_check_at' => e.retry_after.seconds.from_now.utc.iso8601)
      return
    end
    id = segment.fetch('id')
    record_recent_intent('segment_id' => id, 'status' => 'awaiting_readback')
    id
  end

  def validate_recent_intent!(segment, definition)
    return if segment.dig('attributes', 'name') == RECENT_INTENT_NAME && segment.dig('attributes', 'definition') == definition

    raise Umi::Funnel::KlaviyoClient::Error, 'Recent-intent definition differs'
  end

  def record_recent_intent(values)
    @account.with_lock do
      state = @account.custom_attributes.fetch('umi_segment_refresh', {})
      recent = state.fetch('recent_intent', {}).merge(values).merge('checked_at' => Time.current.utc.iso8601)
      @account.update!(custom_attributes: @account.custom_attributes.merge('umi_segment_refresh' => state.merge('recent_intent' => recent)))
    end
  end

  def publish(contact, expected, observations, observed_at)
    contact.reload
    return unless Umi::Funnel::CustomerContextSync.eligible?(contact) && Umi::Funnel::CustomerContextSync.version(contact) == expected

    segments = { 'complete' => true, 'observed_at' => observed_at }
    SEGMENTS.each do |name, id|
      segments[name] = observations.fetch(name).include?(expected.fetch('profile_id'))
      segments["#{name}_id"] = id
    end
    Umi::Funnel::CustomerMutation.new(contact, source: 'remote').perform(
      snapshot: { 'segments' => segments }, sync: { 'expected' => expected, 'metadata' => { 'segments' => segments } }
    )
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def record_status(values)
    @account.with_lock do
      state = @account.custom_attributes.fetch('umi_segment_refresh', {}).merge(values)
      @account.update!(custom_attributes: @account.custom_attributes.merge('umi_segment_refresh' => state))
    end
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def definitions(metrics)
    ids = METRICS.transform_values do |name, integration|
      matches = metrics.select { |metric| metric.dig('attributes', 'name') == name && metric.dig('attributes', 'integration', 'key') == integration }
      raise Umi::Funnel::KlaviyoClient::Error, "Expected one #{integration} metric #{name}" unless matches.one?

      matches.first.fetch('id')
    end
    stage = { type: 'profile-property', property: "properties['umi_buyer_lifecycle']",
              filter: { type: 'string', operator: 'equals', value: 'non_buyer' } }
    fresh = { type: 'profile-property', property: "properties['umi_payment_snapshot_at']",
              filter: { type: 'date', operator: 'in-the-last', quantity: 2, unit: 'hour' } }
    activity = ids.transform_values { |id| activity_condition(id) }
    groups = { 'chooser' => [[stage], [fresh], activity.values_at('site', 'product'),
                             [activity_condition(ids.fetch('cart'), present: false)], [activity_condition(ids.fetch('checkout'), present: false)]],
               'seeker' => [[stage], [fresh], activity.values_at('cart', 'checkout')] }
    groups.transform_values { |conditions| { condition_groups: conditions.map { |items| { conditions: items } } }.deep_stringify_keys }
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def activity_condition(id, present: true)
    { type: 'profile-metric', metric_id: id, measurement: 'count',
      measurement_filter: { type: 'numeric', operator: present ? 'greater-than' : 'equals', value: 0 },
      timeframe_filter: { type: 'date', operator: 'in-the-last', quantity: 30, unit: 'day' }, metric_filters: nil }
  end
end
