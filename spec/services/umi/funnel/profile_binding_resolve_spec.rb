# frozen_string_literal: true

require 'rails_helper'

# Legacy contact rows can contain identifiers that current model validation rejects.
# rubocop:disable Rails/SkipsModelValidations
RSpec.describe Umi::Funnel::ProfileBinding, '#resolve' do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, email: 'person@example.com', phone_number: '+66812345678') }
  let(:profile) { { 'id' => 'PROFILE1', 'attributes' => { 'email' => 'person@example.com', 'phone_number' => '+66812345678' } } }
  let(:page) { { 'data' => [profile], 'links' => { 'next' => nil } } }
  let(:client) { instance_double(Umi::Funnel::KlaviyoClient, profiles: page) }
  let(:resolver) { described_class.new(contact: contact) }

  around do |example|
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      example.run
    end
  end

  before do
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
  end

  it 'binds one existing profile with all shared identifiers matching' do
    resolver.resolve { true }
    expect(contact.reload.additional_attributes).to include('umi_klaviyo_profile_id' => 'PROFILE1')
    expect(contact.additional_attributes.dig('umi_klaviyo_binding', 'generation')).to be_present
    expect(client).to have_received(:profiles).with('email' => 'person@example.com', 'phone_number' => '+66812345678')
  end

  it 'matches a canonical international phone without an email' do
    contact.update!(email: nil)
    resolver.resolve { true }
    expect(client).to have_received(:profiles).with('phone_number' => '+66812345678')
    expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to eq('PROFILE1')
  end

  it 'leaves an unknown profile unbound so later identity can resolve' do
    page['data'] = []
    resolver.resolve { true }
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'does not query an anonymous contact or infer its phone country' do
    contact.update_columns(email: nil, phone_number: '0812345678')
    resolver.resolve { true }
    expect(client).not_to have_received(:profiles)
  end

  it 'holds conflicting phone evidence even if email matches' do
    profile['attributes']['phone_number'] = '+66899999999'
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /identity conflict/)
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'holds two remote matches instead of choosing by response order' do
    page['data'] << profile.merge('id' => 'PROFILE2')
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /Ambiguous/)
  end

  it 'treats a next page as ambiguity even when this page has only one row' do
    page['links']['next'] = 'https://a.klaviyo.com/api/profiles?page[cursor]=another'
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /Ambiguous/)
  end

  it 'does not choose between unbound local contacts sharing normalized email' do
    other = create(:contact, account: account)
    other.update_columns(email: ' Person@example.com ')
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /Duplicate contact/)
  end

  it 'does not choose between local contacts sharing normalized phone' do
    other = create(:contact, account: account)
    other.update_columns(phone_number: '+66 (81) 234-5678')
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /Duplicate contact/)
  end

  it 'ignores erased duplicate identifiers and contacts in other accounts' do
    other = create(:contact, account: account, additional_attributes: { 'umi_profile_redacted' => true })
    other.update_columns(email: ' Person@example.com ')
    create(:contact, email: contact.email, phone_number: contact.phone_number)
    resolver.resolve { true }
    expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to eq('PROFILE1')
  end

  it 'does not query another account using the configured credential' do
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: (account.id + 1).to_s do
      expect { resolver.resolve { true } }.to raise_error(ArgumentError, /account/)
    end
    expect(client).not_to have_received(:profiles)
  end

  it 'preserves a manual binding written while the provider read is in flight' do
    allow(client).to receive(:profiles) do
      Contact.find(contact.id).update!(additional_attributes: { 'umi_klaviyo_profile_id' => 'MANUAL', 'umi_klaviyo_binding' => { 'actor_id' => 42 } })
      page
    end
    resolver.resolve { raise 'Do not reconsider an existing binding' }
    expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to eq('MANUAL')
    expect(contact.additional_attributes['umi_klaviyo_binding']).to eq('actor_id' => 42)
  end

  it 'does not write when the delivery becomes ineligible during the provider read' do
    resolver.resolve { false }
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'does not bind a result obtained before the contact identity changed' do
    allow(client).to receive(:profiles) do
      Contact.find(contact.id).update!(email: 'changed@example.com')
      page
    end
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /identifiers changed/)
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'does not restore a binding after erasure overlaps the provider read' do
    allow(client).to receive(:profiles) do
      Contact.find(contact.id).update!(additional_attributes: { 'umi_profile_redacted' => true })
      page
    end
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /redacted/)
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'does not bind a provider identity already assigned to another contact' do
    create(:contact, account: account, additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })
    expect { resolver.resolve { true } }.to raise_error(ArgumentError, /another contact/)
  end
end

# rubocop:enable Rails/SkipsModelValidations
