# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::OutboundCallBuilder do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, account: account, messaging_service_sid: nil, phone_number: '+15550000000') }
  let(:user) { create(:user) }
  let(:contact) { create(:contact, account: account, phone_number: '+15551112222') }
  let(:twilio_client) { instance_double(Twilio::REST::Client) }
  let(:calls_resource) { instance_double(Twilio::REST::Api::V2010::AccountContext::CallList) }

  before do
    allow(channel).to receive_messages(umi_voice_client: twilio_client, umi_sip_domain: 'd.sip.twilio.com')
    allow(twilio_client).to receive(:calls).and_return(calls_resource)
    allow(calls_resource).to receive(:create).and_return(instance_double(Twilio::REST::Api::V2010::AccountContext::CallInstance, sid: 'CAout1'))
  end

  it 'rings the initiating agent SIP and bridges from the business number' do
    described_class.perform!(account: account, channel: channel, user: user, contact: contact)

    expect(calls_resource).to have_received(:create).with(
      hash_including(to: "sip:agent-#{user.id}@d.sip.twilio.com", from: '+15550000000')
    )
  end

  it 'requests status callbacks on the agent leg so the call log can leave ringing' do
    # REST-originated calls only get status webhooks when StatusCallback is passed on
    # create (the number-level callback covers incoming calls only) — without it every
    # outbound call stays "ringing" forever.
    with_modified_env(FRONTEND_URL: 'https://app.example.com') do
      described_class.perform!(account: account, channel: channel, user: user, contact: contact)
    end

    expect(calls_resource).to have_received(:create).with(
      hash_including(
        status_callback: 'https://app.example.com/umi/voice/15550000000/status',
        status_callback_event: %w[initiated ringing answered completed],
        status_callback_method: 'POST'
      )
    )
  end

  it 'creates an outgoing Umi::Call keyed on the Twilio SID' do
    call = described_class.perform!(account: account, channel: channel, user: user, contact: contact)

    expect(call.direction).to eq('outgoing')
    expect(call.provider_call_id).to eq('CAout1')
    expect(call.accepted_by_agent).to eq(user)
  end

  it 'attaches an outgoing voice_call message' do
    call = described_class.perform!(account: account, channel: channel, user: user, contact: contact)

    expect(call.message.content_type).to eq('voice_call')
    expect(call.message.message_type).to eq('outgoing')
  end
end
