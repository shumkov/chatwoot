# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

class Umi::Funnel::EventRecorder
  def self.capture_message(message)
    return unless Umi::Funnel::Configuration.enabled?(message.account_id) && message.incoming? && !message.private?

    conversation = message.conversation
    contact = conversation.contact
    contact.with_lock do
      next if contact.additional_attributes['umi_profile_redacted']

      recovered = message.content_attributes['umi_recovered'] == true
      historical = message.created_at < Umi::Funnel::Configuration.started_at
      provenance = if historical
                     'historical'
                   else
                     (recovered ? 'recovered' : 'live')
                   end
      time = recovered ? source_time(message.content_attributes['external_created_at']) : message.created_at
      Umi::ConversationEvent.record!(account_id: message.account_id, conversation_id: conversation.id, contact_id: contact.id,
                                     event_type: 'message_received', occurrence_key: "message:#{message.id}",
                                     occurred_at: time, observed_at: Time.current, provenance: provenance,
                                     evidence_message_ids: [message.id], payload: identity(message).merge('message_id' => message.id))
    end
  end

  def self.source_time(value)
    Time.iso8601(value)
  rescue ArgumentError, TypeError
    nil
  end

  def self.identity(message)
    conversation = message.conversation
    inbox = conversation.inbox
    type = inbox.channel_type
    instagram = conversation.additional_attributes['type'] == 'instagram_direct_message' || type == 'Channel::Instagram'
    channel = if instagram
                'instagram'
              else
                (type == 'Channel::FacebookPage' ? 'messenger' : 'other')
              end
    payload = { 'inbox_id' => inbox.id, 'channel_type' => type, 'messaging_channel' => channel }
    if channel != 'other'
      payload['scoped_user_id'] = conversation.contact_inbox.source_id if conversation.contact_inbox.source_id.present?
      payload['page_id'] = inbox.channel.page_id if inbox.channel.respond_to?(:page_id) && inbox.channel.page_id.present?
      referral = message.content_attributes['referral'].to_h
      payload['ad_id'] = referral['ad_id'].to_s if referral['source'] == 'ADS' && referral['ad_id'].present?
    end
    payload
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
