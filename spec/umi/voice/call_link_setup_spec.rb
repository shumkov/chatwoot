# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::CallLinkSetup do
  let(:account) { create(:account) }

  it 'creates a link-type "Call" contact attribute' do
    definition = described_class.new(account).ensure_definition!

    expect(definition.attribute_display_type).to eq('link')
    expect(definition.attribute_model).to eq('contact_attribute')
    expect(definition.attribute_key).to eq('call')
  end

  it 'is idempotent — one definition no matter how many runs' do
    2.times { described_class.new(account).ensure_definition! }

    expect(account.custom_attribute_definitions.where(attribute_key: 'call').count).to eq(1)
  end

  it 'backfills the signed dial link only onto contacts that have a phone' do
    contact = create(:contact, account: account, phone_number: '+15551112222')
    create(:contact, account: account, phone_number: nil)

    count = described_class.new(account).backfill_contacts!

    expect(count).to eq(1)
    expect(contact.reload.custom_attributes['call']).to eq(Umi::Voice.dial_url(contact))
  end
end
