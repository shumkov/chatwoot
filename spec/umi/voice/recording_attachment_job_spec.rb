# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Voice::RecordingAttachmentJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: contact) }
  let(:call) do
    Umi::Call.create!(account: account, inbox: channel.inbox, conversation: conversation, contact: contact,
                      provider: :twilio, direction: :incoming, provider_call_id: 'CA1', status: 'completed')
  end

  def fake_result
    SafeFetch::Result.new(tempfile: StringIO.new('audio-bytes'), filename: 'RE1.mp3', content_type: 'audio/mpeg')
  end

  it 'downloads the recording and attaches it to the call' do
    allow(SafeFetch).to receive(:fetch).and_yield(fake_result)

    described_class.perform_now(call.id, 'RE1', 'https://api.twilio.com/r/RE1', '42')

    expect(call.reload.recording).to be_attached
    expect(call.recording_sid).to eq('RE1')
  end

  it 'is idempotent — skips when the same recording is already attached' do
    call.recording.attach(io: StringIO.new('x'), filename: 'RE1.mp3', content_type: 'audio/mpeg')
    call.update!(recording_sid: 'RE1')

    expect(SafeFetch).not_to receive(:fetch)
    described_class.perform_now(call.id, 'RE1', 'https://x', '1')
  end
end
