# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::CallStatus::Manager do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: contact) }
  let(:call) do
    Umi::Call.create!(account: account, inbox: channel.inbox, conversation: conversation, contact: contact,
                      provider: :twilio, direction: :incoming, provider_call_id: 'CA1', status: 'ringing')
  end

  it 'moves ringing → in_progress and stamps started_at' do
    described_class.new(call: call).process('in_progress')
    expect(call.reload.status).to eq('in_progress')
    expect(call.started_at).to be_present
  end

  it 'stamps duration + ended_at on a terminal status' do
    described_class.new(call: call).process('completed', duration: '42')
    expect(call.reload.status).to eq('completed')
    expect(call.duration_seconds).to eq(42)
    expect(call.ended_at).to be_present
  end

  it 'never overwrites a terminal status' do
    described_class.new(call: call).process('completed', duration: '10')
    described_class.new(call: call).process('no_answer')
    expect(call.reload.status).to eq('completed')
  end

  it 'is a no-op when the status is unchanged' do
    call.update!(status: 'in_progress')
    expect { described_class.new(call: call).process('in_progress') }.not_to(change { call.reload.updated_at })
  end
end
