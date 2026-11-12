# frozen_string_literal: true

class Umi::Funnel::CustomerProjectionJob < ApplicationJob
  queue_as :high

  self.log_arguments = false

  # Timestamp-only profile writes enqueue no projection, yet the CRM note's service-reservation freshness
  # changes with elapsed time alone. The reconcile tick therefore re-projects every linked customer that
  # has an unresolved conversation; an unchanged projection adds no note.
  def self.enqueue_open
    account_id = ENV['UMI_FUNNEL_KLAVIYO_ACCOUNT_ID'].to_i
    return unless Umi::Funnel::Configuration.customer_context_enabled?(account_id)

    Umi::Funnel::ProfileSyncJob.linked_contacts(account_id)
                               .where(id: Conversation.where(account_id: account_id).where.not(status: :resolved).select(:contact_id))
                               .order(:id).pluck(:id).each { |id| perform_later(id) }
  end

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
