# frozen_string_literal: true

class Umi::Funnel::CustomerProjectionJob < ApplicationJob
  queue_as :high

  def perform(contact_id, conversation_id = nil)
    contact = Contact.find_by(id: contact_id)
    return unless contact && Umi::Funnel::Configuration.customer_context_enabled?(contact.account_id)

    contact.with_lock do
      next if contact.additional_attributes['umi_profile_redacted']

      scope = contact.conversations
      scope = conversation_id ? scope.where(id: conversation_id) : scope.where.not(status: :resolved)
      scope.order(:id).each do |conversation|
        conversation.with_lock { Umi::Funnel::CustomerProjection.apply!(conversation, contact, initial: conversation_id.present?) }
      end
    end
  end
end
