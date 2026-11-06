# frozen_string_literal: true

class Umi::Funnel::MessageWindow
  META_CHANNELS = %w[Channel::FacebookPage Channel::Instagram].freeze

  def self.policy_for(conversation)
    # Keep the native transport policy authoritative, including the Page-linked Instagram path.
    duration = Conversations::MessageWindowService.new(conversation).send(:messaging_window)
    meta = META_CHANNELS.include?(conversation.inbox.channel_type)
    standard = meta ? Conversations::MessageWindowService::MESSAGING_WINDOW_24_HOURS : duration
    extension = meta && duration != standard ? 'unverified' : 'disabled'
    { duration: duration, standard: standard, human_extension: extension,
      revision: Digest::SHA256.hexdigest([1, conversation.inbox.channel_type, duration&.to_i, extension].to_json) }
  end

  def initialize(conversation:, as_of:, messages: nil, policy: nil, historical: false, future_incoming: nil) # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity
    @conversation = conversation
    @as_of = as_of.utc
    @historical = historical
    @policy = policy || self.class.policy_for(conversation)
    scope = conversation.messages.where(account_id: conversation.account_id).incoming
    @messages = (messages || scope.where(created_at: ..@as_of).to_a).select do |message|
      message.account_id == conversation.account_id && message.incoming? && message.created_at <= @as_of
    end
    @future_incoming = future_incoming.nil? ? !historical && scope.exists?(['created_at > ?', @as_of]) : future_incoming
  end

  def perform # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    native = @messages.max_by { |message| [message.created_at, message.id] }
    timed = @messages.filter_map do |message|
      time = trustworthy_time(message)
      [message, time] if time
    end
    trusted, source_at = timed.max_by { |message, time| [time, message.id] }
    deadline = source_at + @policy[:standard] if source_at && @policy[:standard]
    can_reply = @policy[:duration].nil? || (native.present? && @as_of < native.created_at + @policy[:duration])
    reason = uncertainty(native, source_at)
    state, reason = window_state(native, deadline, reason)
    { evaluated_at: @as_of.iso8601(6), channel_type: @conversation.inbox.channel_type, messaging_channel: messaging_channel,
      can_reply: can_reply, state: state, reason: reason,
      native_last_incoming_message_id: native&.id, native_last_incoming_at: native&.created_at&.utc&.iso8601(6),
      last_incoming_message_id: trusted&.id, last_incoming_at: source_at&.utc&.iso8601(6),
      standard_expires_at: deadline&.utc&.iso8601(6), human_expires_at: nil, human_extension: @policy[:human_extension],
      policy_revision: @policy[:revision],
      basis: @historical ? 'historical_reconstruction_current_policy_history_unavailable' : 'live_persisted_evidence' }
  end

  private

  def trustworthy_time(message)
    return if message.private? || message.content_attributes['deleted']
    return message.created_at unless message.content_attributes['umi_recovered'] == true

    source = Umi::Funnel::EventRecorder.source_time(message.content_attributes['external_created_at'])
    source if source && source <= @as_of
  end

  def uncertainty(native, source_at) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return 'incompatible_configuration' if @policy[:duration] && @policy[:duration] <= 0
    return 'future_incoming_timestamp' if @future_incoming || future_source_time?
    return unless native
    return 'deleted_incoming' if native.content_attributes['deleted']

    @messages.each do |message|
      next unless message.content_attributes['umi_recovered'] == true

      source = Umi::Funnel::EventRecorder.source_time(message.content_attributes['external_created_at'])
      return 'source_time_unavailable' unless source
    end
    return 'native_incoming_mismatch' if @policy[:duration] && native.created_at != source_at
  end

  def future_source_time?
    @messages.any? do |message|
      next false unless message.content_attributes['umi_recovered'] == true

      source = Umi::Funnel::EventRecorder.source_time(message.content_attributes['external_created_at'])
      source && source > @as_of
    end
  end

  def window_state(native, deadline, uncertainty)
    return ['unknown', uncertainty] if uncertainty
    return %w[unrestricted no_time_restriction] if @policy[:duration].nil?
    return %w[closed no_incoming] unless native
    return %w[unknown human_extension_unverified] if @as_of >= deadline && @policy[:human_extension] == 'unverified'
    return %w[closed expired] if @as_of >= deadline

    %w[standard_open within_standard_window]
  end

  def messaging_channel
    return 'instagram' if @conversation.inbox.channel_type == 'Channel::Instagram' ||
                          @conversation.additional_attributes['type'] == 'instagram_direct_message'

    @conversation.inbox.channel_type == 'Channel::FacebookPage' ? 'messenger' : 'other'
  end
end
