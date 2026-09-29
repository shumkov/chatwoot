# frozen_string_literal: true

class Umi::Funnel::SegmentRefreshJob < MutexApplicationJob
  queue_as :low
  SEGMENTS = { 'chooser' => 'SS6aWp', 'seeker' => 'RUy6Wc' }.freeze
  METRICS = { 'site' => ['Active on Site', 'api'], 'product' => ['Viewed Product', 'api'],
              'cart' => ['Added to Cart', 'shopify'], 'checkout' => ['Checkout Started', 'shopify'] }.freeze

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
    validate_segments!(client)
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
  end
  # rubocop:enable Metrics/AbcSize

  def validate_segments!(client)
    expected = definitions(client.metrics)
    SEGMENTS.each do |name, id|
      segment = client.segment(id)
      next if segment['id'] == id && segment.dig('attributes', 'name') == "UMI - #{name.capitalize}" &&
              segment.dig('attributes', 'definition') == expected.fetch(name)

      raise Umi::Funnel::KlaviyoClient::Error, 'Configured segment definition differs'
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
