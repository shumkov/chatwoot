# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::ProfileBinding do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, email: 'person@example.com', phone_number: '+66812345678') }
  let(:profile) { { 'id' => 'PROFILE1', 'attributes' => { 'email' => 'Person@example.com', 'phone_number' => '+66812345678' } } }
  let(:client) { instance_double(Umi::Funnel::KlaviyoClient, profile: profile) }
  let(:binding) { described_class.new(contact: contact, profile_id: 'PROFILE1', actor: actor, reason: 'Verified existing customer') }

  around do |example|
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      example.run
    end
  end

  before do
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
  end

  it 'binds the existing profile after identifier readback without creating a profile or changing consent' do
    contact.update!(additional_attributes: { 'unrelated' => 'preserve' })
    binding.perform

    expect(contact.reload.additional_attributes).to include('umi_klaviyo_profile_id' => 'PROFILE1', 'unrelated' => 'preserve')
    expect(contact.additional_attributes['umi_klaviyo_binding']).to include('actor_id' => actor.id, 'reason' => 'Verified existing customer')
    expect(client).to have_received(:profile).with('PROFILE1')
    expect(a_request(:post, /klaviyo/)).not_to have_been_made
  end

  it 'rejects conflicting phone even when the email matches' do
    profile['attributes']['phone_number'] = '+66899999999'

    expect { binding.perform }.to raise_error(ArgumentError, /identity/)
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'does not bind an anonymous contact by profile name or social handle' do
    contact.update!(email: nil, phone_number: nil)

    expect { binding.perform }.to raise_error(ArgumentError, /identity/)
  end

  it 'rejects a response for a different profile ID' do
    profile['id'] = 'OTHER'

    expect { binding.perform }.to raise_error(ArgumentError, /profile/)
  end

  it 'does not guess a country code for local-format phone numbers' do
    contact.update!(email: nil)
    profile['attributes'] = { 'phone_number' => '0812345678' }

    expect { binding.perform }.to raise_error(ArgumentError, /identity/)
  end

  it 'rejects a profile already bound to another contact in this account' do
    create(:contact, account: account, additional_attributes: { 'umi_klaviyo_profile_id' => 'PROFILE1' })

    expect { binding.perform }.to raise_error(ArgumentError, /another contact/)
  end

  it 'rejects an actor from another account' do
    outsider = create(:user)
    operation = described_class.new(contact: contact, profile_id: 'PROFILE1', actor: outsider, reason: 'Selected profile')

    expect { operation.perform }.to raise_error(ArgumentError, /Actor/)
    expect(client).not_to have_received(:profile)
  end

  it 'rejects another account using this destination credential' do
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: (account.id + 1).to_s do
      expect { binding.perform }.to raise_error(ArgumentError, /account/)
    end
    expect(client).not_to have_received(:profile)
  end

  it 'checks the contact again after a slow profile read overlaps erasure' do
    allow(client).to receive(:profile) do
      contact.update!(additional_attributes: { 'umi_profile_redacted' => true })
      profile
    end

    expect { binding.perform }.to raise_error(ArgumentError, /redacted/)
    expect(contact.reload.additional_attributes).not_to have_key('umi_klaviyo_profile_id')
  end

  it 'changes binding generation and clears old baseline and pending even while the writer is disabled' do
    contact.update!(additional_attributes: {
                      'umi_klaviyo_profile_id' => 'OLD', 'umi_klaviyo_binding' => { 'generation' => 'old-generation' },
                      'umi_klaviyo_sync' => { 'roles' => { 'umi_vip' => { 'baseline_known' => true, 'baseline' => 'no',
                                                                          'pending' => { 'value' => 'yes' } } } }
                    }, custom_attributes: { 'umi_vip' => 'yes', 'umi_funnel_stage' => 'repeat' })
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: '' do
      binding.perform
    end
    expect(contact.reload.additional_attributes['umi_klaviyo_sync']).to be_nil
    expect(contact.additional_attributes.dig('umi_klaviyo_binding', 'generation')).to be_present
    expect(contact.additional_attributes.dig('umi_klaviyo_binding', 'generation')).not_to eq('old-generation')
    expect(contact.custom_attributes).not_to have_key('umi_vip')
  end
end
