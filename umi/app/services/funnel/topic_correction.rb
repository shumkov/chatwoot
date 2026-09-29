# frozen_string_literal: true

class Umi::Funnel::TopicCorrection
  def self.record!(conversation, before:, actor: Current.user) # rubocop:disable Metrics/AbcSize
    return unless actor.is_a?(User) && conversation.account.users.exists?(id: actor.id)
    return if conversation.contact.additional_attributes['umi_profile_redacted']

    topics = Umi::Funnel::ClassificationClient::TOPICS
    added = (conversation.label_list - before) & topics
    removed = (before - conversation.label_list) & topics
    return if added.empty? && removed.empty?

    watermark = Umi::Funnel::ClassificationContext.public_messages(conversation).incoming.maximum(:id)
    Umi::ConversationEvent.record!(account_id: conversation.account_id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_topics_corrected', provenance: 'operator', occurred_at: Time.current,
                                   observed_at: Time.current, occurrence_key: "topics:#{SecureRandom.uuid}", evidence_message_ids: [],
                                   payload: { added: added, removed: removed, input_message_id: watermark, actor_id: actor.id })
  end

  def self.state(conversation)
    events = Umi::ConversationEvent.where(conversation_id: conversation.id, event_type: 'classification_topics_corrected',
                                          redacted_at: nil).order(:id)
    removals = {}
    events.each do |event|
      event.payload.fetch('removed').each do |label|
        removals[label] = { input_message_id: event.payload['input_message_id'], observed_at: event.observed_at.iso8601(6) }
      end
    end
    { latest_event_id: events.last&.id, removals: removals }
  end

  def self.permitted?(topic, input)
    fence = input.fetch(:topic_corrections).fetch(:removals)[topic.fetch('label')]
    return true unless fence

    topic.fetch('evidence_message_ids').all? do |id|
      row = input.fetch(:messages).find { |message| message[:id] == id }
      input.fetch(:fresh_evidence_ids).include?(id) && id > fence[:input_message_id].to_i && row[:created_at] > fence[:observed_at]
    end
  end
end
