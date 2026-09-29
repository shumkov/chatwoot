# frozen_string_literal: true

class Umi::Funnel::ClassificationContext
  VERSION = '2'

  def self.public_messages(conversation)
    attributes = "CASE WHEN json_typeof(content_attributes) = 'string' THEN (content_attributes #>> '{}')::json ELSE content_attributes END"
    conversation.messages.where(private: false, message_type: %i[incoming outgoing])
                .where("COALESCE((#{attributes}) ->> 'deleted', 'false') != 'true'")
  end

  def initialize(conversation, watermark:, cutoff:, boundary:, as_of:)
    @conversation = conversation
    @watermark = watermark
    @cutoff = cutoff
    @boundary = boundary
    @as_of = as_of
  end

  def build # rubocop:disable Metrics/AbcSize
    messages = self.class.public_messages(@conversation).where(id: ..@cutoff, created_at: ..@as_of).reorder(:created_at, :id).to_a
    correction = Umi::ConversationEvent.where(conversation_id: @conversation.id, provenance: 'operator', redacted_at: nil,
                                              event_type: 'classification_changed').order(id: :desc).first
    incoming = messages.select { |message| message.incoming? && !message.content_attributes['umi_recovered'] }
    fresh_ids = fresh_evidence(incoming, correction)
    { messages: message_rows(messages, fresh_ids), incoming_ids: incoming.map(&:id), fresh_evidence_ids: fresh_ids, truncated: false,
      coverage: 'all_available_current_conversation_messages', input_message_id: @watermark, public_history_cutoff: @cutoff,
      customer: customer_facts, current_status: @conversation.custom_attributes['umi_sales_status'],
      current_topics: (@conversation.label_list & Umi::Funnel::ClassificationClient::TOPICS).sort,
      human_correction: correction && { id: correction.id, observed_at: correction.observed_at.iso8601(6),
                                        input_message_id: correction.payload['input_message_id'], status: correction.payload['status'],
                                        reason: correction.payload['reason'] },
      topic_corrections: Umi::Funnel::TopicCorrection.state(@conversation) }
  end

  def comparison(input)
    contact = @conversation.contact
    { input: input, contact_id: contact.id, binding: contact.additional_attributes.slice('umi_klaviyo_profile_id', 'umi_klaviyo_binding'),
      sync: contact.additional_attributes['umi_klaviyo_sync'],
      context_enabled: Umi::Funnel::Configuration.customer_context_enabled?(contact.account_id) }
  end

  private

  def fresh_evidence(incoming, correction)
    live_ids = Umi::Funnel::ConversationClassifier.sources.where(conversation_id: @conversation.id)
                                                  .pluck(Arel.sql("(payload ->> 'message_id')::bigint")).to_set
    incoming.select do |message|
      live_ids.include?(message.id) && message.created_at >= @boundary &&
        (!correction || (message.id > correction.payload['input_message_id'].to_i && message.created_at > correction.observed_at))
    end.map(&:id)
  end

  def message_rows(messages, fresh_ids) # rubocop:disable Metrics/AbcSize
    attachments = Attachment.where(message_id: messages.map(&:id)).order(:id).pluck(:message_id, :id, :file_type, :updated_at).group_by(&:first)
    messages.map do |message|
      metadata = Array(attachments[message.id]).map { |row| { id: row[1], type: row[2], updated_at: row[3].iso8601(6) } }
      { id: message.id, created_at: message.created_at.iso8601(6), role: message.incoming? ? 'customer' : 'staff', text: message.content.to_s,
        attachments: attachments.key?(message.id), attachment_metadata: metadata,
        recovered: message.content_attributes['umi_recovered'] == true, context_only: fresh_ids.exclude?(message.id) }
    end
  end

  def customer_facts
    contact = @conversation.contact.reload
    sync = contact.additional_attributes.fetch('umi_klaviyo_sync', {})
    { facts: contact.custom_attributes.slice(*Umi::Funnel::Configuration::CONTACT_FIELDS), freshness: freshness(sync),
      identity: contact.additional_attributes['umi_klaviyo_profile_id'].present? ? 'resolved' : 'unresolved' }
  end

  def freshness(sync)
    return sync.fetch('status', 'unknown') unless sync['status'] == 'fresh'
    return 'stale' if sync['error'].present? || !recent?(sync['payment_snapshot_at'], 2.hours)
    return 'fresh' unless sync['buyer_lifecycle'] == 'non_buyer'

    segments = sync.fetch('segments', {})
    segments['complete'] && recent?(segments['observed_at'], 15.minutes) ? 'fresh' : 'stale'
  end

  def recent?(value, duration)
    timestamp = Time.iso8601(value.to_s)
    timestamp <= @as_of && timestamp > @as_of - duration
  rescue ArgumentError
    false
  end
end
