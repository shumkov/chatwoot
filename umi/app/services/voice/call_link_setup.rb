# frozen_string_literal: true

# Creates the "Call" tap-to-call link contact attribute and (optionally) backfills each contact's
# value with its signed dial link, so the native mobile app can render a tap-to-call link with no
# app fork. See Umi::Voice.dial_url.
class Umi::Voice::CallLinkSetup
  KEY = 'call'

  def initialize(account)
    @account = account
  end

  def ensure_definition!
    @account.custom_attribute_definitions.find_or_create_by!(attribute_key: KEY, attribute_model: 'contact_attribute') do |definition|
      definition.attribute_display_name = 'Call'
      definition.attribute_display_type = 'link'
      definition.attribute_description = 'Tap to call this contact'
    end
  end

  def backfill_contacts!
    ensure_definition!
    count = 0
    @account.contacts.where.not(phone_number: [nil, '']).find_each do |contact|
      contact.update!(custom_attributes: contact.custom_attributes.merge(KEY => Umi::Voice.dial_url(contact)))
      count += 1
    end
    count
  end
end
