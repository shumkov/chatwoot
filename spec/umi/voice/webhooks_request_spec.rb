# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Voice inbound webhook', type: :request do
  let(:account) { create(:account) }

  before do
    channel = create(:channel_twilio_sms, account: account, messaging_service_sid: nil, phone_number: '+15550009999')
    channel.update_column(:voice_enabled, true) # rubocop:disable Rails/SkipsModelValidations
  end

  around do |example|
    with_modified_env(UMI_VOICE_SKIP_SIGNATURE: 'true', UMI_VOICE_SIP_DOMAIN: 'd.sip.twilio.com', UMI_VOICE_AGENTS: 'agent1') do
      example.run
    end
  end

  it 'logs an inbound call and returns <Dial><Sip> TwiML ringing the agent' do
    post '/umi/voice/15550009999/incoming', params: { From: '+15551112222', CallSid: 'CAreq1', Direction: 'inbound' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('sip:agent1@d.sip.twilio.com')

    call = Umi::Call.find_by(provider_call_id: 'CAreq1')
    expect(call).to be_present
    expect(call.direction).to eq('incoming')
    expect(call.message.content_type).to eq('voice_call')
  end

  it 'returns 404 for an unknown / non-voice number' do
    post '/umi/voice/19999999999/incoming', params: { From: '+15551112222', CallSid: 'CAx' }
    expect(response).to have_http_status(:not_found)
  end

  it 'marks the call no_answer when the dial result is no-answer' do
    post '/umi/voice/15550009999/incoming', params: { From: '+15551112222', CallSid: 'CAreq2', Direction: 'inbound' }
    post '/umi/voice/15550009999/dial_status', params: { CallSid: 'CAreq2', DialCallStatus: 'no-answer' }

    expect(Umi::Call.find_by(provider_call_id: 'CAreq2').status).to eq('no_answer')
  end
end
