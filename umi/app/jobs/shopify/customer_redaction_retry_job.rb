# frozen_string_literal: true

# Shopify compliance webhooks are acknowledged immediately. This job is the
# durable retry path for a database or Active Storage failure during erasure.
class Umi::Shopify::CustomerRedactionRetryJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  # unbound_only: the contact matched the erased customer by exact email while
  # carrying no Shopify customer. The service re-checks that under the row lock
  # of its own erasure: a contact bound since then belongs to another
  # customer's erasure, and erasing it would purge that customer's records.
  def perform(contact_id, unbound_only: false)
    contact = Contact.find_by(id: contact_id)
    return if contact.nil?

    erased = Umi::Shopify::CustomerRedactionService.new(contact).perform(only_unbound: unbound_only)
    report_bound_since(contact) unless erased
  end

  private

  def report_bound_since(contact)
    message = "[umi-shopify-compliance] customers/redact retry: contact #{contact.id} held the erased customer's email " \
              'but is now bound to a Shopify customer; not erased, review manually'
    ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
    Rails.logger.error(message)
  end
end
