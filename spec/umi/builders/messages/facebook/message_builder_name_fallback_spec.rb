require 'rails_helper'

# Regression: Meta denies the /PSID User Profile API for apps without the
# Business Asset User Profile Access feature (GraphMethodException code 100 /
# subcode 33), and upstream then names the contact "John Doe" permanently.
# The same names are available through the page-inbox Conversations API
# (participants field) with permissions the app already holds — the data path
# Meta Business Suite itself displays names from. Fall back to it before
# accepting a placeholder.
describe Messages::Facebook::MessageBuilder do
  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    allow(fb_object).to receive(:get_object).and_raise(
      Koala::Facebook::ClientError.new(
        400, '',
        { 'type' => 'GraphMethodException', 'code' => 100, 'error_subcode' => 33,
          'message' => 'Unsupported get request.' }
      )
    )
  end

  let!(:facebook_channel) { create(:channel_facebook_page) }
  let(:fb_object) { double }
  let(:psid) { 'psid-denied-profile-1' }

  let(:message_object) do
    {
      messaging: {
        sender: { id: psid },
        recipient: { id: facebook_channel.page_id },
        message: { mid: 'mid-name-fallback-1', text: 'hello from a profile-locked user' }
      }
    }.to_json
  end
  let(:incoming_message) { Integrations::Facebook::MessageParser.new(message_object) }

  context 'when the thread participants carry the name' do
    before do
      allow(fb_object).to receive(:get_connections)
        .with(facebook_channel.page_id, 'conversations', hash_including(user_id: psid))
        .and_return([
                      { 'participants' => { 'data' => [
                        { 'id' => psid, 'name' => 'Oxana Khashagulgova' },
                        { 'id' => facebook_channel.page_id, 'name' => 'UMI clothing' }
                      ] } }
                    ])
    end

    it 'names the contact from the conversations participants instead of John Doe' do
      described_class.new(incoming_message, facebook_channel.inbox).perform

      expect(facebook_channel.inbox.messages.count).to eq(1)
      expect(facebook_channel.inbox.contacts.last.name).to eq('Oxana Khashagulgova')
    end
  end

  context 'when the participants lookup also fails' do
    before do
      allow(fb_object).to receive(:get_connections)
        .with(facebook_channel.page_id, 'conversations', anything)
        .and_raise(Koala::Facebook::ClientError.new(400, '', { 'message' => 'nope' }))
    end

    it 'still persists the message with the stock placeholder name' do
      described_class.new(incoming_message, facebook_channel.inbox).perform

      expect(facebook_channel.inbox.messages.count).to eq(1)
      expect(facebook_channel.inbox.contacts.last.name).to eq('John Doe')
    end
  end
end
