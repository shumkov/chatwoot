# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Call do
  subject(:call) do
    described_class.create!(account: account, inbox: inbox, conversation: conversation, contact: contact,
                            provider: :twilio, direction: :incoming, provider_call_id: 'CA123')
  end

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  it 'defaults to ringing' do
    expect(call.status).to eq('ringing')
  end

  it 'exposes a hyphenated display_status for the frontend' do
    call.update!(status: 'in_progress')
    expect(call.display_status).to eq('in-progress')
  end

  it 'enforces (provider, provider_call_id) uniqueness' do
    call
    dup = described_class.new(account: account, inbox: inbox, conversation: conversation, contact: contact,
                              provider: :twilio, direction: :incoming, provider_call_id: 'CA123')
    expect(dup).not_to be_valid
  end

  it 'stores conference_sid in meta' do
    call.update!(conference_sid: 'conf_1')
    expect(call.reload.meta['conference_sid']).to eq('conf_1')
  end

  it 'push_event_data carries the frontend contract fields (snake_case, hyphenated status)' do
    expect(call.push_event_data).to include(
      provider: 'twilio', provider_call_id: 'CA123', status: 'ringing', direction: 'incoming'
    )
  end

  it 'is reachable via message.call (association repointed to Umi::Call)' do
    message = create(:message, account: account, conversation: conversation, content_type: 'voice_call')
    call.update!(message: message)
    expect(message.reload.call).to eq(call)
  end
end
