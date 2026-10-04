# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Funnel::DeliveryService
  METRICS = { 'conversation_qualified' => 'UMI Conversation Qualified', 'order_paid' => 'UMI Order Paid' }.freeze

  def initialize(delivery)
    @delivery = delivery
  end

  def prepare(automatic: false)
    return @delivery unless @delivery.reload.state == 'pending'

    @purchase_refresh_failed = !refresh_purchase_source if purchase? && purchase_enabled?
    event = @delivery.conversation_event
    contact = Contact.find_by(id: event.contact_id, account_id: event.account_id)
    if automatic && @delivery.destination == 'klaviyo' && ready_for_schedule?
      Umi::Funnel::ProfileBinding.new(contact: contact).resolve do |resolved_id|
        ready = ready_for_schedule?
        raise ArgumentError, 'Prepared destination cannot change' if @delivery.destination_key.present? && @delivery.destination_key != resolved_id

        ready
      end
      contact.reload
    end
    profile_id = contact&.additional_attributes&.[]('umi_klaviyo_profile_id')
    @profile = Umi::Funnel::KlaviyoClient.new.profile(profile_id) if @delivery.destination == 'klaviyo' && profile_id.present? && !event.redacted_at
    with_source_lock do |source, owner|
      next unless @delivery.state == 'pending'
      next if automatic && Umi::Funnel::DeliveryAutomation::PENDING_REASONS.exclude?(@delivery.reason)
      next if ineligible!(source, owner)

      payload, destination = provider_payload(source, owner)
      next unless payload
      next unless frozen_pair_matches?(payload, destination)

      attrs = { reason: nil, last_error: nil }
      if @delivery.payload.empty?
        attrs[:payload] = payload
        attrs[:destination_key] = destination
      end
      @delivery.update!(attrs)
    end
    @delivery
  end

  def dispatch(automatic: false)
    return @delivery unless @delivery.reload.state == 'pending'

    unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("UMI_FUNNEL_#{@delivery.destination.upcase}_ENABLED", false))
      @delivery.update!(reason: 'dispatch_disabled')
      return @delivery
    end

    prepare(automatic: automatic)
    return @delivery unless @delivery.state == 'pending' && @delivery.reason.nil? && @delivery.payload.present?

    client = @delivery.destination == 'meta' ? Umi::Funnel::MetaClient.new : Umi::Funnel::KlaviyoClient.new
    claimed = false
    with_source_lock do |source, owner|
      next unless @delivery.state == 'pending'
      next if automatic && Umi::Funnel::DeliveryAutomation::PENDING_REASONS.exclude?(@delivery.reason)
      next if ineligible!(source, owner)

      payload, destination = provider_payload(source, owner)
      next unless payload && frozen_pair_matches?(payload, destination)

      @delivery.update!(state: 'sending', attempted_at: Time.current, attempt_count: @delivery.attempt_count + 1, last_error: nil)
      claimed = true
    end
    return @delivery unless claimed

    begin
      result = if @delivery.destination == 'meta'
                 client.send_events(dataset_id: @delivery.destination_key.split(':').last, payload: @delivery.payload)
               else
                 client.create_event(@delivery.payload)
               end
    rescue StandardError => e
      result = { state: 'unknown', error: e.class.name }
    end
    @delivery.with_lock do
      attrs = { state: result.fetch(:state), last_error: result[:error], provider_reference: result[:reference] }
      attrs[:accepted_at] = Time.current if result[:state] == 'accepted'
      @delivery.update!(attrs)
    end
    @delivery
  end

  def ready_for_schedule?
    ready = false
    with_source_lock do |source, owner|
      next unless @delivery.state == 'pending' && Umi::Funnel::DeliveryAutomation::PENDING_REASONS.include?(@delivery.reason)
      next unless Umi::Funnel::DeliveryAutomation.enabled?(@delivery.destination)
      next if purchase? && !purchase_enabled?
      next if ineligible!(source, owner)

      if @delivery.destination == 'klaviyo' && owner.additional_attributes['umi_klaviyo_profile_id'].blank?
        mark!('pending', 'profile_unbound')
        next if Umi::Funnel::ProfileBinding.identifiers(owner).empty?
      end

      ready = true
    end
    ready
  end

  def hold_preparation(error)
    with_source_lock do |source, owner|
      next if source.redacted_at || owner&.additional_attributes&.[]('umi_profile_redacted')

      @delivery.update!(reason: 'preparation_failed', last_error: error.class.name.first(255)) if @delivery.state == 'pending'
    end
  end

  def confirm_scheduled
    reserved = false
    with_source_lock do |source, owner|
      next unless @delivery.destination == 'klaviyo' && @delivery.state == 'accepted' && @delivery.accepted_at
      next if source.redacted_at || !owner || owner.additional_attributes['umi_profile_redacted']
      next unless Umi::Funnel::Configuration.enabled?(source.account_id) && Umi::Funnel::DeliveryAutomation.enabled?('klaviyo')

      delay = Umi::Funnel::DeliveryAutomation::READBACK_DELAYS[@delivery.readback_attempt_count]
      next unless delay && @delivery.accepted_at + delay <= Time.current

      @delivery.update!(readback_attempt_count: @delivery.readback_attempt_count + 1)
      reserved = true
    end
    confirm if reserved
  rescue StandardError => e
    record_readback_wait('readback_failed', e.class.name.first(255))
  end

  def hold_interrupted
    @delivery.with_lock do
      @delivery.update!(state: 'unknown', last_error: 'interrupted_attempt') if @delivery.state == 'sending'
    end
    @delivery
  end

  def confirm
    return @delivery unless @delivery.reload.destination == 'klaviyo' && @delivery.state == 'accepted'

    event = @delivery.conversation_event
    return @delivery if event.redacted_at

    client = Umi::Funnel::KlaviyoClient.new
    cursor = nil
    10.times do
      page = client.events(profile_id: @delivery.destination_key, since: event.occurred_at.utc.iso8601,
                           until_time: (event.occurred_at + 1.second).utc.iso8601, cursor: cursor)
      return @delivery.reload if event.reload.redacted_at

      match = matching_readback(page, event)
      if match
        with_source_lock do |source, owner|
          next if source.redacted_at || !owner || owner.additional_attributes['umi_profile_redacted']
          next unless @delivery.state == 'accepted'

          @delivery.update!(state: 'confirmed', provider_reference: match.fetch('id'), confirmed_at: Time.current, reason: nil)
        end
        return @delivery
      end
      next_url = page.dig('links', 'next')
      if next_url.blank?
        record_readback_wait('awaiting_readback')
        return @delivery
      end
      cursor = URI.decode_www_form(URI.parse(next_url).query.to_s).to_h.fetch('page[cursor]')
    end
    record_readback_wait('readback_page_limit')
    @delivery
  end

  private

  def purchase?
    @delivery.destination == 'meta' && @delivery.conversation_event.event_type == 'order_paid'
  end

  def purchase_enabled?
    Umi::Funnel::DeliveryAutomation.enabled?('meta') && Umi::Funnel::PurchaseSource.channels.any?
  end

  def refresh_purchase_source
    state = Umi::ShopifyOrderFinancialState.find_by(account_id: @delivery.conversation_event.account_id,
                                                    paid_event_id: @delivery.conversation_event_id)
    Umi::Funnel::PurchaseSource.new(state).refresh if state
  end

  def frozen_pair_matches?(payload, destination)
    return true if @delivery.payload.empty? && @delivery.destination_key.blank?
    return true if @delivery.payload == payload && @delivery.destination_key == destination

    raise ArgumentError, 'Prepared destination cannot change' if !purchase? && @delivery.destination_key != destination

    mark!('pending', 'prepared_source_changed')
    false
  end

  def with_source_lock
    if purchase?
      state = Umi::ShopifyOrderFinancialState.find_by(account_id: @delivery.conversation_event.account_id,
                                                      paid_event_id: @delivery.conversation_event_id)
      if state
        @purchase_source = Umi::Funnel::PurchaseSource.new(state)
        return @purchase_source.with_lock do |source|
          @delivery.with_lock { yield(@delivery.conversation_event.reload, source.contact) }
        end
      end
    end
    event = @delivery.conversation_event.reload
    contact = Contact.find_by(id: event.contact_id, account_id: event.account_id)
    operation = -> { @delivery.with_lock { yield(event.reload, contact&.reload) } }
    contact ? contact.with_lock(&operation) : operation.call
  end

  def ineligible!(event, contact)
    return mark!('excluded', 'redacted') if event.redacted_at || contact&.additional_attributes&.[]('umi_profile_redacted')
    return mark!('pending', 'account_disabled') unless Umi::Funnel::Configuration.enabled?(event.account_id)
    return mark!('excluded', 'unsupported_event') unless METRICS.key?(event.event_type)
    return mark!('excluded', 'unknown_event_time') unless event.occurred_at
    return mark!('excluded', 'future_event_time') if event.occurred_at > Time.current
    return mark!('excluded', 'pre_boundary') if event.occurred_at < Umi::Funnel::Configuration.started_at
    return mark!('excluded', 'historical_event') if %w[recovered historical].include?(event.provenance)
    return mark!('pending', 'identity_unlinked') if event.contact_id.nil?
    return mark!('excluded', 'identity_missing') unless contact && event.contact_id == contact.id

    if event.event_type == 'order_paid' && Umi::ShopifyOrderFinancialState.where(account_id: event.account_id, paid_event_id: event.id)
                                                                          .where("snapshot ->> 'identity_hold' IS NOT NULL").exists?
      return mark!('pending', 'financial_identity_conflict')
    end

    if event.conversation_id && !Conversation.exists?(id: event.conversation_id, contact_id: contact.id, account_id: event.account_id)
      return mark!('excluded', 'conversation_missing')
    end

    correction = Umi::ConversationEvent.where(account_id: event.account_id, conversation_id: event.conversation_id,
                                              event_type: 'classification_changed').order(id: :desc).first
    if event.event_type == 'conversation_qualified' && correction && %w[not_sales unevaluated].include?(correction.payload['status'])
      return mark!('excluded', 'qualification_corrected')
    end

    false
  end

  def mark!(state, reason)
    @delivery.update!(state: state, reason: reason)
    true
  end

  def provider_payload(event, contact)
    configured_account = Integer(ENV.fetch("UMI_FUNNEL_#{@delivery.destination.upcase}_ACCOUNT_ID"))
    raise ArgumentError, 'Destination account mismatch' unless event.account_id == configured_account

    @delivery.destination == 'meta' ? meta_payload(event) : klaviyo_payload(event, contact)
  end

  def meta_payload(event)
    return purchase_payload(event) if event.event_type == 'order_paid'

    channel = event.payload['messaging_channel']
    if %w[messenger instagram].exclude?(channel)
      mark!('excluded', 'channel_not_enabled')
      return []
    end
    if event.occurred_at < 7.days.ago
      mark!('excluded', 'event_too_old')
      return []
    end
    asset = ENV.fetch(channel == 'instagram' ? 'UMI_FUNNEL_META_INSTAGRAM_ID' : 'UMI_FUNNEL_META_PAGE_ID')
    dataset = ENV.fetch('UMI_FUNNEL_META_DATASET_ID')
    asset_key = channel == 'instagram' ? 'instagram_id' : 'page_id'
    user_asset_key = channel == 'instagram' ? 'ig_account_id' : 'page_id'
    scoped_key = channel == 'instagram' ? 'ig_sid' : 'page_scoped_user_id'
    raise ArgumentError, 'Invalid Meta destination IDs' unless [asset, dataset].all? { |id| id.match?(/\A[1-9]\d*\z/) }

    if event.payload[asset_key] != asset || !event.payload['scoped_user_id'].to_s.match?(/\A[1-9]\d*\z/)
      mark!('excluded', 'channel_identity_mismatch')
      return []
    end
    payload = { 'data' => [{ 'event_name' => 'QualifiedLead', 'event_time' => event.occurred_at.to_i,
                             'action_source' => 'business_messaging', 'messaging_channel' => channel,
                             'user_data' => { user_asset_key => asset, scoped_key => event.payload['scoped_user_id'] } }] }
    payload['test_event_code'] = ENV['UMI_FUNNEL_META_TEST_EVENT_CODE'] if ENV['UMI_FUNNEL_META_TEST_EVENT_CODE'].present?
    [payload, "#{asset}:#{dataset}"]
  end

  def purchase_payload(event)
    unless purchase_enabled?
      mark!('pending', 'purchase_channel_disabled')
      return []
    end
    reason = if @purchase_refresh_failed
               'financial_observation_stale'
             elsif @purchase_source && @purchase_source.event&.id == event.id
               @purchase_source.reason
             else
               'purchase_source_unknown'
             end
    reason ||= 'event_too_old' if event.occurred_at < 7.days.ago
    if reason
      mark!('pending', reason)
      return []
    end
    identity = @purchase_source.evidence.payload
    channel = identity.fetch('messaging_channel')
    asset = ENV.fetch(channel == 'instagram' ? 'UMI_FUNNEL_META_INSTAGRAM_ID' : 'UMI_FUNNEL_META_PAGE_ID')
    dataset = ENV.fetch('UMI_FUNNEL_META_DATASET_ID')
    asset_key = channel == 'instagram' ? 'instagram_id' : 'page_id'
    scoped_key = channel == 'instagram' ? 'ig_sid' : 'page_scoped_user_id'
    user_asset_key = channel == 'instagram' ? 'ig_account_id' : 'page_id'
    unless [asset, dataset, identity['scoped_user_id']].all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) } && identity[asset_key] == asset
      mark!('pending', 'channel_identity_mismatch')
      return []
    end
    value = BigDecimal(event.payload.fetch('value'))
    raise ArgumentError, 'Invalid paid value' unless value.finite? && value.positive?

    data = { 'event_name' => 'Purchase', 'event_time' => event.occurred_at.to_i, 'event_id' => "umi-funnel-#{event.account_id}-#{event.id}",
             'action_source' => 'business_messaging', 'messaging_channel' => channel,
             'user_data' => { user_asset_key => asset, scoped_key => identity.fetch('scoped_user_id') },
             'custom_data' => { 'currency' => event.payload.fetch('currency'), 'value' => value.to_f,
                                'order_id' => event.payload.fetch('order_id') } }
    payload = { 'data' => [data] }
    payload['test_event_code'] = ENV['UMI_FUNNEL_META_TEST_EVENT_CODE'] if ENV['UMI_FUNNEL_META_TEST_EVENT_CODE'].present?
    [payload, "#{asset}:#{dataset}"]
  end

  def klaviyo_payload(event, contact)
    profile_id = contact.additional_attributes['umi_klaviyo_profile_id']
    if profile_id.blank?
      mark!('pending', 'profile_unbound')
      return []
    end
    unless Umi::Funnel::ProfileBinding.matches?(contact, @profile, profile_id)
      mark!('pending', 'profile_identity_conflict')
      return []
    end
    properties = event.payload.slice('qualification_reason', 'shop_domain', 'order_id', 'currency', 'value')
    attributes = { 'profile' => { 'data' => { 'type' => 'profile', 'id' => profile_id, 'attributes' => {} } },
                   'metric' => { 'data' => { 'type' => 'metric', 'attributes' => { 'name' => METRICS.fetch(event.event_type) } } },
                   'time' => event.occurred_at.utc.iso8601, 'unique_id' => "umi-funnel-#{event.account_id}-#{event.id}",
                   'properties' => properties.merge('umi_event_id' => event.id.to_s) }
    if event.event_type == 'order_paid'
      amount = BigDecimal(event.payload.fetch('value'))
      raise ArgumentError, 'Invalid paid value' unless amount.finite? && amount.positive?

      attributes['value'] = amount.to_f
      attributes['value_currency'] = event.payload.fetch('currency')
    end
    [{ 'data' => { 'type' => 'event', 'attributes' => attributes } }, profile_id]
  end

  def record_readback_wait(reason, error = nil)
    with_source_lock do |source, owner|
      next if source.redacted_at || !owner || owner.additional_attributes['umi_profile_redacted']

      @delivery.update!(reason: reason, last_error: error) if @delivery.state == 'accepted'
    end
  end

  def matching_readback(page, event)
    metric = METRICS.fetch(event.event_type)
    metrics = page.fetch('included', []).select { |item| item['type'] == 'metric' && item.dig('attributes', 'name') == metric }.pluck('id')
    page.fetch('data').find do |item|
      item.dig('relationships', 'profile', 'data', 'id') == @delivery.destination_key &&
        metrics.include?(item.dig('relationships', 'metric', 'data', 'id')) &&
        item.dig('attributes', 'event_properties', 'umi_event_id').to_s == event.id.to_s &&
        Time.iso8601(item.dig('attributes', 'datetime')).to_i == event.occurred_at.to_i
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
