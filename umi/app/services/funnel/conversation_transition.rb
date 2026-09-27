# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Funnel::ConversationTransition
  def initialize(conversation:, status:, actor:, reason:, evidence_message_ids:)
    @conversation = conversation
    @status = status
    @actor = actor
    @reason = reason.to_s.strip
    @ids = evidence_message_ids.map { |id| Integer(id) }.uniq
  end

  def perform
    validate_request!
    @conversation.contact.with_lock do
      raise ArgumentError, 'Contact is redacted' if @conversation.contact.additional_attributes['umi_profile_redacted']

      @conversation.reload.with_lock { transition! }
    end
  end

  private

  def validate_request!
    raise ArgumentError, 'Funnel account is disabled' unless Umi::Funnel::Configuration.enabled?(@conversation.account_id)
    raise ArgumentError, 'Invalid human status' unless %w[unevaluated engaged qualified inactive not_sales].include?(@status)
    raise ArgumentError, 'Reason must contain 1-1000 characters' unless @reason.length.between?(1, 1000)
    raise ArgumentError, 'Actor must belong to account' unless @conversation.account.users.exists?(id: @actor.id)
    raise ArgumentError, 'Evidence must belong to conversation' unless @conversation.messages.where(id: @ids).count == @ids.size
  end

  def transition!
    previous = @conversation.custom_attributes['umi_sales_status'] || 'unevaluated'
    latest = Umi::ConversationEvent.where(conversation_id: @conversation.id, event_type: 'classification_changed').order(id: :desc).first
    return latest if latest && latest.payload['status'] == @status && latest.payload['reason'] == @reason && latest.evidence_message_ids == @ids

    eligible = @conversation.messages.where(id: @ids).select do |message|
      message.incoming? && !message.private? && !message.content_attributes['umi_recovered'] &&
        message.created_at >= Umi::Funnel::Configuration.started_at
    end
    eligible = eligible.filter_map { |message| Umi::Funnel::EventRecorder.capture_message(message) }
                       .select { |event| event.provenance == 'live' && event.occurred_at && !event.redacted_at }
    raise ArgumentError, 'Qualification requires live incoming evidence' if @status == 'qualified' && eligible.empty?

    event = Umi::ConversationEvent.record!(account_id: @conversation.account_id, conversation_id: @conversation.id,
                                           contact_id: @conversation.contact_id, event_type: 'classification_changed',
                                           occurrence_key: "classification:#{SecureRandom.uuid}", occurred_at: Time.current,
                                           observed_at: Time.current, provenance: 'operator', evidence_message_ids: @ids,
                                           payload: { status: @status, reason: @reason, actor_id: @actor.id, previous_status: previous })
    qualify!(eligible) if @status == 'qualified'
    if %w[not_sales unevaluated].include?(@status)
      Umi::ConversionDelivery.joins(:conversation_event).where(umi_conversation_events: { conversation_id: @conversation.id,
                                                                                          event_type: 'conversation_qualified' }, state: 'pending')
                             .find_each do |delivery|
        delivery.with_lock { delivery.update!(state: 'excluded', reason: 'qualification_corrected') if delivery.state == 'pending' }
      end
    end
    Umi::Funnel::Configuration.provision!(@conversation.account)
    @conversation.project_umi_sales_status!(@status) unless %w[order_placed purchased].include?(previous)
    event
  end

  def qualify!(eligible)
    identities = eligible.map { |event| event.payload.except('message_id') }
    payload = identities.first.slice('inbox_id', 'channel_type', 'messaging_channel')
    %w[scoped_user_id page_id ad_id].each do |key|
      values = identities.map { |identity| identity[key] }.uniq
      payload[key] = values.first if values.size == 1 && values.first.present?
    end
    Umi::ConversationEvent.record!(account_id: @conversation.account_id, conversation_id: @conversation.id,
                                   contact_id: @conversation.contact_id, event_type: 'conversation_qualified',
                                   occurrence_key: "conversation:#{@conversation.id}:qualified", occurred_at: eligible.map(&:occurred_at).max,
                                   observed_at: Time.current, provenance: 'operator', evidence_message_ids: @ids,
                                   payload: payload.merge('qualification_reason' => @reason, 'actor_id' => @actor.id))
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
