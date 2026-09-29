# frozen_string_literal: true

class Umi::Funnel::CustomerMutation
  def initialize(contact, source:, actor: nil, conversation: nil)
    @contact = contact
    @source = source
    @actor = actor
    @conversation = conversation
  end

  def perform(roles: {}, snapshot: nil) # rubocop:disable Metrics/AbcSize
    validate_context!

    @contact.with_lock do
      raise ArgumentError, 'Contact is redacted' if @contact.additional_attributes['umi_profile_redacted']

      state = @contact.additional_attributes.fetch('umi_klaviyo_sync', {}).deep_dup
      previous = @contact.custom_attributes.slice(*(Umi::Funnel::Configuration::CONTACT_FIELDS - ['umi_payment_snapshot_at']))
      previous_status = state['status']
      apply_roles(roles.stringify_keys, state)
      apply_snapshot(snapshot, state) if snapshot
      current = @contact.custom_attributes.slice(*(Umi::Funnel::Configuration::CONTACT_FIELDS - ['umi_payment_snapshot_at']))
      state['revision'] = state.fetch('revision', 0) + 1 if previous != current || previous_status != state['status']
      @contact.additional_attributes = @contact.additional_attributes.merge('umi_klaviyo_sync' => state)
      @contact.save!
      project_current_conversation! if @conversation && previous != current
    end
    @contact
  end

  private

  def validate_context!
    unless Umi::Funnel::Configuration.customer_context_enabled?(@contact.account_id)
      raise ArgumentError,
            'Customer context is not enabled for this account'
    end
    raise ArgumentError, 'AI role changes require a conversation' if @source == 'ai' && @conversation.nil?
  end

  def project_current_conversation!
    @conversation.reload.with_lock do
      raise ArgumentError, 'Conversation contact changed' unless @conversation.contact_id == @contact.id
      raise ArgumentError, 'Conversation is resolved' if @source == 'ai' && @conversation.resolved?

      Umi::Funnel::CustomerProjection.apply!(@conversation, @contact)
    end
  end

  def apply_roles(roles, state)
    raise ArgumentError, 'Unknown customer role' unless (roles.keys - Umi::Funnel::Configuration::ROLES.keys).empty?

    roles.each { |key, value| apply_role(key, value, state) }
  end

  def apply_role(key, value, state)
    value = 'unknown' if value.nil?
    raise ArgumentError, 'Role must be unknown, yes or no' unless Umi::Funnel::Configuration::ROLE_VALUES.include?(value)

    previous = @contact.custom_attributes.fetch(key, 'unknown')
    return if previous == value
    return if @source == 'ai' && !ai_role_change?(key, previous, value)

    @contact.custom_attributes = @contact.custom_attributes.merge(key => value)
    record_pending_role(state, key, value) if %w[operator ai].include?(@source)
  end

  def ai_role_change?(key, previous, value)
    %w[umi_influencer umi_wholesale].include?(key) && previous == 'unknown' && value == 'yes'
  end

  def record_pending_role(state, key, value)
    state['roles'] ||= {}
    field = state['roles'][key] ||= {}
    field['revision'] = field.fetch('revision', 0) + 1
    field['pending'] = { 'value' => value, 'source' => @source, 'actor_id' => @actor&.id, 'revision' => field['revision'] }
  end

  def apply_snapshot(snapshot, state)
    if snapshot['status'] == 'stale'
      state['status'] = 'stale'
      return
    end
    state.merge!(snapshot)

    state['status'] = 'fresh'
    values = { 'umi_funnel_stage' => stage_for(state['buyer_lifecycle'], snapshot['segments']) }
    %w[paid_order_count paid_history_complete payment_snapshot_at].each do |key|
      values["umi_#{key}"] = snapshot[key] if snapshot.key?(key)
    end
    @contact.custom_attributes = @contact.custom_attributes.merge(values)
  end

  def stage_for(lifecycle, membership) # rubocop:disable Metrics/CyclomaticComplexity
    return lifecycle if %w[repeat client].include?(lifecycle)
    return 'unclassified' unless lifecycle == 'non_buyer'
    return @contact.custom_attributes['umi_funnel_stage'].presence || 'unclassified' unless membership&.fetch('complete', false)
    return 'seeker' if membership['seeker']

    membership['chooser'] ? 'chooser' : 'non_buyer'
  end
end
