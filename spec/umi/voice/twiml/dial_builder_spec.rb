# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::Twiml::DialBuilder do
  subject(:xml) do
    described_class.new(
      domain: 'umi-spike.sip.twilio.com',
      agent_usernames: %w[agent-1 agent-2],
      caller_number: '+15551112222',
      caller_name: 'Test Contact',
      dial_action_url: 'https://app.example.com/umi/voice/15550000000/dial_status'
    ).to_xml
  end

  it 'dials each agent at the GLOBAL sip domain, never an edge URI' do
    expect(xml).to include('sip:agent-1@umi-spike.sip.twilio.com')
    expect(xml).to include('sip:agent-2@umi-spike.sip.twilio.com')
    expect(xml).not_to include('.sip.singapore.twilio.com')
  end

  it 'injects the contact name into the Remote-Party-ID header' do
    expect(xml).to include('Remote-Party-ID=')
    expect(CGI.unescape(xml)).to include('"Test Contact"')
  end

  it 'sets the caller id, ring timeout and dial action callback' do
    expect(xml).to include('callerId="+15551112222"')
    expect(xml).to include('action="https://app.example.com/umi/voice/15550000000/dial_status"')
  end

  context 'without a matched contact name' do
    subject(:xml) do
      described_class.new(
        domain: 'd.sip.twilio.com', agent_usernames: ['agent-1'],
        caller_number: '+15551112222', caller_name: nil, dial_action_url: 'https://x/cb'
      ).to_xml
    end

    it 'omits the Remote-Party-ID header (the number then shows)' do
      expect(xml).not_to include('Remote-Party-ID')
    end
  end

  it 'caps the ring set at 10 targets' do
    builder = described_class.new(
      domain: 'd.sip.twilio.com', agent_usernames: (1..15).map { |i| "agent-#{i}" },
      caller_number: '+1', caller_name: nil, dial_action_url: 'https://x/cb'
    ).to_xml
    expect(builder.scan('<Sip>').size).to eq(10)
  end

  it 'does not record unless a recording_status_url is given' do
    expect(xml).not_to include('record=')
  end

  it 'omits per-leg status callbacks unless a sip_status_url is given' do
    expect(xml).not_to include('statusCallback')
  end

  it 'sets an answered status callback per <Sip> leg carrying the agent username' do
    with_attribution = described_class.new(
      domain: 'd.sip.twilio.com', agent_usernames: %w[agent-1 agent-2],
      caller_number: '+15551112222', caller_name: nil, dial_action_url: 'https://x/cb',
      sip_status_url: 'https://app.example.com/umi/voice/15550000000/sip_status'
    ).to_xml
    expect(with_attribution).to include('statusCallbackEvent="answered"')
    expect(with_attribution).to include('statusCallback="https://app.example.com/umi/voice/15550000000/sip_status?agent=agent-1"')
    expect(with_attribution).to include('statusCallback="https://app.example.com/umi/voice/15550000000/sip_status?agent=agent-2"')
  end

  it 'records dual-channel + sets the recording callback when a recording_status_url is given' do
    recorded = described_class.new(
      domain: 'd.sip.twilio.com', agent_usernames: ['agent-1'], caller_number: '+1',
      caller_name: nil, dial_action_url: 'https://x/cb', recording_status_url: 'https://x/rec'
    ).to_xml
    expect(recorded).to include('record="record-from-answer-dual"')
    expect(recorded).to include('recordingStatusCallback="https://x/rec"')
  end
end
