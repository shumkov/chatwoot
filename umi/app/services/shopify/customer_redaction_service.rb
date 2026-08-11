# frozen_string_literal: true

# Performs the database portion of a Shopify customer erasure as one unit.
# The compliance endpoint acknowledges every delivery with 200, so callers
# enqueue a retry if this service raises.
class Umi::Shopify::CustomerRedactionService
  def initialize(contact)
    @contact = contact
  end

  def perform
    ActiveRecord::Base.transaction do
      @contact.update!(
        name: 'Redacted customer', last_name: '', middle_name: '',
        email: nil, phone_number: nil, identifier: nil,
        location: nil, country_code: nil, custom_attributes: {},
        additional_attributes: @contact.additional_attributes.except('city', 'country')
                                                .reject { |key, _| key.start_with?('shopify_', 'social_', 'umi_profile_') }
                                                .merge('umi_profile_redacted' => true)
      )
      Umi::ProfileLedgerEntry.where(contact_id: @contact.id).delete_all
      Umi::FbigAdAttribution.purge_for(@contact)
    end

    # Active Storage deletion is not transactional. It is intentionally after
    # the database commit; a failure leaves the redaction durable and the retry
    # job can safely attempt the same purge again.
    @contact.avatar.purge
  end
end
