# frozen_string_literal: true

# Shopify compliance webhooks are acknowledged immediately. This job is the
# durable retry path for a database or Active Storage failure during erasure.
class Umi::Shopify::CustomerRedactionRetryJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(contact_id)
    contact = Contact.find_by(id: contact_id)
    return if contact.nil?

    Umi::Shopify::CustomerRedactionService.new(contact).perform
  end
end
