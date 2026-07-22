require 'rails_helper'

# Regression: Messages::Facebook::MessageBuilder creates the message and
# downloads its attachments inside one DB transaction. Facebook CDN attachment
# URLs expire quickly, so a failed download (Down::Error) raised out of
# `process_attachment`, rolled back the already-created message row, and the
# whole inbound message — text included — was permanently lost (Meta does not
# redeliver). An attachment failure must not discard the message.
describe Messages::Facebook::MessageBuilder do
  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    allow(fb_object).to receive(:get_object).and_return(
      { first_name: 'Jane', last_name: 'Dae', profile_pic: nil }.with_indifferent_access
    )
    allow(Down).to receive(:download).and_raise(Down::TimeoutError.new('timed out'))
  end

  let!(:facebook_channel) { create(:channel_facebook_page) }
  let(:fb_object) { double }

  let(:message_object) do
    {
      messaging: {
        sender: { id: '3383290475046708' },
        recipient: { id: facebook_channel.page_id },
        message: {
          mid: 'mid-with-expired-attachment',
          text: 'message with attachment',
          attachments: [
            { type: 'image', payload: { url: 'https://scontent.example/expired.jpeg' } }
          ]
        }
      }
    }.to_json
  end
  let(:incoming_message) { Integrations::Facebook::MessageParser.new(message_object) }

  it 'keeps the message when the attachment download fails' do
    described_class.new(incoming_message, facebook_channel.inbox).perform

    message = facebook_channel.inbox.messages.last
    expect(message).to be_present
    expect(message.content).to eq('message with attachment')
  end
end
