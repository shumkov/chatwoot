# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

class Umi::Funnel::ConversationTransition
  def initialize(conversation:, status:, actor:, reason:, evidence_message_ids:, classifier: nil) # rubocop:disable Metrics/ParameterLists
    @conversation = conversation
    @status = status
    @actor = actor
    @classifier = classifier
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

    if @classifier
      raise ArgumentError, 'Invalid classifier transition' unless @actor.nil? && Umi::Funnel::ConversationClassifier.mode == 'auto' &&
                                                                  %w[engaged qualified not_sales].include?(@status)
    else
      raise ArgumentError, 'Actor must belong to account' unless @actor && @conversation.account.users.exists?(id: @actor.id)
    end
    raise ArgumentError, 'Evidence must belong to conversation' unless @conversation.messages.where(id: @ids).count == @ids.size
  end

  def transition!
    previous = @conversation.custom_attributes['umi_sales_status'] || 'unevaluated'
    qualified = previous == 'qualified' && Umi::ConversationEvent.exists?(conversation_id: @conversation.id,
                                                                          event_type: 'conversation_qualified', redacted_at: nil)
    return if @classifier && (qualified || %w[order_placed purchased].include?(previous))

    latest = Umi::ConversationEvent.where(conversation_id: @conversation.id, event_type: 'classification_changed').order(id: :desc).first
    return latest if latest && latest.payload['status'] == @status && latest.payload['reason'] == @reason && latest.evidence_message_ids == @ids

    historical = Umi::Funnel::HistoricalClassification.reviewed_event(@conversation)
    eligible = @conversation.messages.where(id: @ids).reorder(:id).lock.select do |message|
      message.incoming? && !message.private? && !message.content_attributes['umi_recovered'] && !message.content_attributes['deleted'] &&
        message.created_at >= Umi::Funnel::Configuration.started_at && Umi::Funnel::HistoricalClassification.fresh_evidence?(message, historical)
    end
    eligible = eligible.filter_map { |message| Umi::Funnel::EventRecorder.capture_message(message) }
                       .select { |event| event.provenance == 'live' && event.occurred_at && !event.redacted_at }
    raise ArgumentError, 'Qualification requires live incoming evidence' if @status == 'qualified' && eligible.empty?

    event = Umi::ConversationEvent.record!(account_id: @conversation.account_id, conversation_id: @conversation.id,
                                           contact_id: @conversation.contact_id, event_type: 'classification_changed',
                                           occurrence_key: "classification:#{SecureRandom.uuid}", occurred_at: Time.current,
                                           observed_at: Time.current, provenance: @classifier ? 'classifier' : 'operator', evidence_message_ids: @ids,
                                           payload: { status: @status, reason: @reason, previous_status: previous }.merge(author_metadata))
    qualify!(eligible) if @status == 'qualified'
    if !@classifier && %w[not_sales unevaluated].include?(@status)
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

  def author_metadata
    return @classifier if @classifier

    watermark = @conversation.messages.incoming.where(private: false).where('created_at >= ?', Umi::Funnel::Configuration.started_at)
                             .reorder(id: :desc).detect { |message| !message.content_attributes['umi_recovered'] }&.id
    { 'actor_id' => @actor.id, 'input_message_id' => watermark }
  end

  def qualify!(eligible)
    identities = eligible.map do |event|
      source = @conversation.messages.find(event.payload.fetch('message_id'))
      current = Umi::Funnel::EventRecorder.identity(source).except('ad_id')
      same_owner = event.account_id == @conversation.account_id && event.conversation_id == @conversation.id &&
                   event.contact_id == @conversation.contact_id
      same_owner && event.payload.except('message_id', 'ad_id') == current ? current : {}
    end
    payload = {}
    %w[inbox_id channel_type messaging_channel scoped_user_id page_id instagram_id].each do |key|
      values = identities.map { |identity| identity[key] }.uniq
      payload[key] = values.first if values.size == 1 && values.first.present?
    end
    referral = qualifying_referral(eligible, payload)
    if referral
      payload['ad_id'] = referral.payload['ad_id']
      payload['referral_message_id'] = referral.payload['message_id']
    end
    Umi::ConversationEvent.record!(account_id: @conversation.account_id, conversation_id: @conversation.id,
                                   contact_id: @conversation.contact_id, event_type: 'conversation_qualified',
                                   occurrence_key: "conversation:#{@conversation.id}:qualified", occurred_at: eligible.map(&:occurred_at).max,
                                   observed_at: Time.current, provenance: @classifier ? 'classifier' : 'operator', evidence_message_ids: @ids,
                                   payload: payload.merge('qualification_reason' => @reason).merge(author_metadata))
  end

  def qualifying_referral(eligible, identity)
    keys = %w[inbox_id channel_type messaging_channel scoped_user_id page_id]
    keys << 'instagram_id' if identity['messaging_channel'] == 'instagram'
    return unless keys.all? { |key| identity[key].present? }
    return unless eligible.all? { |event| event.payload.slice(*keys) == identity.slice(*keys) }

    cutoff = eligible.map { |event| [event.occurred_at, event.payload.fetch('message_id')] }.max
    Umi::ConversationEvent.where(account_id: @conversation.account_id, conversation_id: @conversation.id,
                                 contact_id: @conversation.contact_id, event_type: 'message_received', provenance: 'live', redacted_at: nil)
                          .where('occurred_at <= ?', cutoff.first).where("payload ->> 'ad_id' IS NOT NULL").to_a
                          .sort_by { |event| [event.occurred_at, event.payload.fetch('message_id')] }.reverse.detect do |event|
      next false unless ([event.occurred_at, event.payload['message_id']] <=> cutoff) <= 0
      next false unless event.payload.slice(*keys) == identity.slice(*keys)

      source = @conversation.messages.find_by(id: event.payload['message_id'])
      next false unless source

      source.with_lock do
        Umi::FbigAdAttribution.valid_source?(source, @conversation) && source.created_at == event.occurred_at &&
          source.content_attributes.dig('referral', 'ad_id').to_s == event.payload['ad_id'] &&
          Umi::Funnel::EventRecorder.identity(source).slice(*keys) == identity.slice(*keys)
      end
    end
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
