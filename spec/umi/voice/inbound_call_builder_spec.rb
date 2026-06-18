# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::InboundCallBuilder do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_twilio_sms, account: account) }

  it 'materialises the contact, conversation and ringing inbound call' do
    call = described_class.perform!(channel: channel, from_number: '+15551112222', call_sid: 'CA1')

    expect(call).to be_persisted
    expect(call.contact.phone_number).to eq('+15551112222')
    expect(call.conversation).to be_present
    expect(call.direction).to eq('incoming')
    expect(call.status).to eq('ringing')
  end

  it 'attaches an incoming voice_call message from the contact' do
    call = described_class.perform!(channel: channel, from_number: '+15551112222', call_sid: 'CA1')

    expect(call.message.content_type).to eq('voice_call')
    expect(call.message.message_type).to eq('incoming')
    expect(call.message.sender).to eq(call.contact)
  end

  it 'is idempotent on a retried CallSid (Twilio re-delivers webhooks)' do
    first = described_class.perform!(channel: channel, from_number: '+15551112222', call_sid: 'CA9')
    again = described_class.perform!(channel: channel, from_number: '+15551112222', call_sid: 'CA9')

    expect(again.id).to eq(first.id)
    expect(Umi::Call.where(provider_call_id: 'CA9').count).to eq(1)
  end

  it 'reuses an existing open conversation for the contact' do
    first = described_class.perform!(channel: channel, from_number: '+15551112222', call_sid: 'CA1')
    second = described_class.perform!(channel: channel, from_number: '+15551112222', call_sid: 'CA2')

    expect(second.conversation_id).to eq(first.conversation_id)
  end
end
