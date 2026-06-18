# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::RecordingStatusService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: contact) }
  let!(:call) do
    Umi::Call.create!(account: account, inbox: channel.inbox, conversation: conversation, contact: contact,
                      provider: :twilio, direction: :incoming, provider_call_id: 'CA1', status: 'completed')
  end

  it 'enqueues the attachment job when the recording is completed' do
    payload = { 'RecordingStatus' => 'completed', 'RecordingSid' => 'RE1', 'RecordingUrl' => 'https://api.twilio.com/r/RE1', 'CallSid' => 'CA1', 'RecordingDuration' => '42' }
    expect { described_class.new(account: account, payload: payload).perform }
      .to have_enqueued_job(Umi::Voice::RecordingAttachmentJob).with(call.id, 'RE1', 'https://api.twilio.com/r/RE1', '42')
  end

  it 'does nothing while the recording is still in-progress' do
    payload = { 'RecordingStatus' => 'in-progress', 'RecordingSid' => 'RE1', 'RecordingUrl' => 'https://x', 'CallSid' => 'CA1' }
    expect { described_class.new(account: account, payload: payload).perform }
      .not_to have_enqueued_job(Umi::Voice::RecordingAttachmentJob)
  end

  it 'does nothing for an unknown call' do
    payload = { 'RecordingStatus' => 'completed', 'RecordingSid' => 'RE1', 'RecordingUrl' => 'https://x', 'CallSid' => 'NOPE' }
    expect { described_class.new(account: account, payload: payload).perform }
      .not_to have_enqueued_job(Umi::Voice::RecordingAttachmentJob)
  end
end
