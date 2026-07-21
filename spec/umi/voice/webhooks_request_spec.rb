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

  it 'rings agents with a per-leg answered callback for attribution' do
    post '/umi/voice/15550009999/incoming', params: { From: '+15551112222', CallSid: 'CAreq4', Direction: 'inbound' }

    expect(response.body).to include('statusCallbackEvent="answered"')
    expect(response.body).to include('/umi/voice/15550009999/sip_status?agent=agent1')
  end

  it 'attributes the answering agent, flips the call in_progress and assigns the conversation' do
    agent = create(:user, account: account)
    post '/umi/voice/15550009999/incoming', params: { From: '+15551112222', CallSid: 'CAreq3', Direction: 'inbound' }
    post '/umi/voice/15550009999/sip_status',
         params: { CallSid: 'CAchild1', ParentCallSid: 'CAreq3', CallStatus: 'in-progress', agent: "agent-#{agent.id}" }

    call = Umi::Call.find_by(provider_call_id: 'CAreq3')
    expect(call.status).to eq('in_progress')
    expect(call.accepted_by_agent).to eq(agent)
    expect(call.conversation.assignee).to eq(agent)
  end

  it 'marks the call no_answer when the dial result is no-answer' do
    post '/umi/voice/15550009999/incoming', params: { From: '+15551112222', CallSid: 'CAreq2', Direction: 'inbound' }
    post '/umi/voice/15550009999/dial_status', params: { CallSid: 'CAreq2', DialCallStatus: 'no-answer' }

    expect(Umi::Call.find_by(provider_call_id: 'CAreq2').status).to eq('no_answer')
  end
end
