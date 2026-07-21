# frozen_string_literal: true

# UMI patch: when the orders sidebar finds the contact's Shopify customer,
# persist the customer id onto the contact (once). Its consumer is the
# customers/redact compliance handler — the id keeps redaction matching working
# after an agent later edits the contact's email/phone.
#
# Only an EXACT email (case-insensitive) or E.164-phone match is persisted —
# the sidebar's own "customers.first" from its loose OR-query is fine for a
# transient render but not for a durable link.
module Umi::Shopify::PersistCustomerLink
  private

  def fetch_customers
    super.tap { |customers| persist_customer_link(customers) }
  end

  def persist_customer_link(customers)
    return unless linkable_contact?

    match = Array(customers).find { |customer| exact_customer_match?(customer) }
    return if match.nil? || match['id'].blank?

    contact.update!(additional_attributes: contact.additional_attributes.merge('shopify_customer_id' => match['id']))
  rescue StandardError => e
    # Never let link persistence break the orders sidebar.
    Rails.logger.warn("[umi-contact-sync] on-touch shopify link skipped for contact #{contact&.id}: #{e.message}")
  end

  def linkable_contact?
    contact.present? && contact.additional_attributes['shopify_customer_id'].blank?
  end

  def exact_customer_match?(customer)
    (contact.email.present? && customer['email'].to_s.casecmp?(contact.email)) ||
      (contact.phone_number.present? && customer['phone'].to_s == contact.phone_number)
  end
end
