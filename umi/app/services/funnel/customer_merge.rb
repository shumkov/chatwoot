# frozen_string_literal: true

module Umi::Funnel::CustomerMerge
  def perform
    return super if base_contact.id == mergee_contact.id
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@account.id)

    Contact.transaction do
      Contact.where(id: [base_contact.id, mergee_contact.id]).order(:id).lock.load
      @base_contact.reload
      @mergee_contact.reload
      Umi::Funnel::CustomerProjection.invalidate!(@mergee_contact, erased: @mergee_contact.additional_attributes['umi_profile_redacted'])
      super
    end
  end

  private

  def merge_and_remove_mergee_contact
    return super unless Umi::Funnel::Configuration.customer_context_enabled?(@account.id)

    redacted = @mergee_contact.additional_attributes['umi_profile_redacted'] || @base_contact.additional_attributes['umi_profile_redacted']
    remove_customer_context_attributes(@mergee_contact)
    if redacted
      remove_customer_context_attributes(@base_contact)
      @base_contact.additional_attributes = @base_contact.additional_attributes.merge('umi_profile_redacted' => true)
    end
    super
    Umi::Funnel::Privacy.redact_customer_context!(@base_contact) if redacted
    @base_contact.conversations.where.not(status: :resolved).order(:id).each do |conversation|
      conversation.with_lock { Umi::Funnel::CustomerProjection.apply!(conversation, @base_contact) }
    end
  end

  def remove_customer_context_attributes(contact)
    contact.custom_attributes = contact.custom_attributes.except(*Umi::Funnel::Configuration::CONTACT_FIELDS)
    contact.additional_attributes = contact.additional_attributes.except(*Umi::Funnel::Configuration::TECHNICAL_KEYS)
  end
end
