# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity

class Umi::ConversationEvent < ApplicationRecord
  self.table_name = 'umi_conversation_events'
  belongs_to :account
  has_many :conversion_deliveries, class_name: 'Umi::ConversionDelivery', dependent: :delete_all
  validates :event_type,
            inclusion: { in: %w[message_received classification_changed classification_topics_corrected classification_evaluated
                                conversation_qualified order_paid] }
  validates :provenance, inclusion: { in: %w[live recovered historical operator shopify classifier] }
  validates :occurrence_key, :observed_at, presence: true
  validate :consistent_evidence
  validate :immutable_occurrence, on: :update

  def self.record!(attributes)
    transaction do
      event = create_or_find_by!(account_id: attributes.fetch(:account_id), occurrence_key: attributes.fetch(:occurrence_key)) do |row|
        row.assign_attributes(attributes)
      end
      if %w[conversation_qualified order_paid].include?(event.event_type)
        %w[meta klaviyo].each { |destination| event.conversion_deliveries.create_or_find_by!(destination: destination) }
      end
      event
    end
  end

  private

  def consistent_evidence
    if conversation_id
      conversation = Conversation.find_by(id: conversation_id, account_id: account_id)
      errors.add(:conversation_id, 'must match account and contact') unless conversation && conversation.contact_id == contact_id
    end
    errors.add(:contact_id, 'must match account') if contact_id && !Contact.exists?(id: contact_id, account_id: account_id)
    unless evidence_message_ids.is_a?(Array) &&
           Message.where(id: evidence_message_ids, account_id: account_id, conversation_id: conversation_id).count == evidence_message_ids.uniq.size
      errors.add(:evidence_message_ids, 'must belong to the conversation')
    end
  end

  def immutable_occurrence
    return if redacted_at_changed? && redacted_at.present?

    mutable = %w[updated_at]
    if event_type == 'order_paid' && redacted_at.nil?
      mutable << 'contact_id' if contact_id_in_database.nil?
      mutable << 'conversation_id' if conversation_id_in_database.nil?
    end
    errors.add(:base, 'Recorded occurrence is immutable') if (changes.keys - mutable).any?
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
