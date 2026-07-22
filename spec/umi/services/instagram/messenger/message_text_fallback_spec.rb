require 'rails_helper'

# Regression: for a first-time Instagram contact (FB-page-linked channel), the
# sender profile fetch can fail — most commonly when the Meta app lacks
# Advanced Access to instagram_manage_messages (chatwoot#11578), but also on
# error 230 (user consent) / 9010 (no matching user). Stock behaviour returned
# an empty profile, never created the contact, and `create_message` silently
# bailed on the missing contact_inbox — the inbound DM was permanently lost.
# The DM must be persisted with a placeholder contact instead.
describe Instagram::Messenger::MessageText do
  let!(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram_fb_page, account: account, instagram_id: 'chatwoot-app-user-id-1') }
  let!(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false) }
  let(:fb_object) { double }
  let(:sender_id) { 'ig-new-sender-1' }

  let(:messaging) do
    {
      'sender': { 'id': sender_id },
      'recipient': { 'id': 'chatwoot-app-user-id-1' },
      'timestamp': '2021-09-08T06:34:04+0000',
      'message': { 'mid': 'mid-from-new-user', 'text': 'First DM from a brand-new user' }
    }.with_indifferent_access
  end

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
  end

  context 'when the profile fetch fails with a permission error (no Advanced Access)' do
    before do
      allow(fb_object).to receive(:get_object).and_raise(
        Koala::Facebook::ClientError.new(
          403, '',
          { 'type' => 'OAuthException', 'code' => 10,
            'message' => '(#10) Application does not have permission for this action' }
        )
      )
    end

    it 'still persists the inbound message with a placeholder contact' do
      described_class.new(messaging, channel).perform

      expect(inbox.messages.count).to eq(1)
      expect(inbox.messages.last.content).to eq('First DM from a brand-new user')
      expect(inbox.contacts.count).to eq(1)
    end
  end

  context 'when the profile fetch fails with an authentication error' do
    before do
      allow(fb_object).to receive(:get_object).and_raise(
        Koala::Facebook::AuthenticationError.new(401, 'Error validating access token')
      )
    end

    it 'still persists the inbound message with a placeholder contact' do
      described_class.new(messaging, channel).perform

      expect(inbox.messages.count).to eq(1)
      expect(inbox.contacts.count).to eq(1)
    end

    it 'restores stock drop behaviour with UMI_IG_FALLBACK_CONTACT=off' do
      with_modified_env UMI_IG_FALLBACK_CONTACT: 'off' do
        described_class.new(messaging, channel).perform
      end

      expect(inbox.messages.count).to eq(0)
      expect(inbox.contacts.count).to eq(0)
    end
  end

  context 'when an echo to a brand-new user fails the profile fetch (error 230: user consent)' do
    let(:messaging) do
      {
        'sender': { 'id': 'chatwoot-app-user-id-1' },
        'recipient': { 'id': sender_id },
        'timestamp': '2021-09-08T06:34:04+0000',
        'message': { 'mid': 'mid-echo-new-user', 'text': 'Agent DM from the native app', 'is_echo': true }
      }.with_indifferent_access
    end

    before do
      allow(fb_object).to receive(:get_object).and_raise(
        Koala::Facebook::ClientError.new(
          403, '',
          { 'type' => 'OAuthException', 'code' => 230,
            'message' => '(#230) Requires pages_messaging permission to manage the object' }
        )
      )
    end

    it 'logs the outgoing thread with a placeholder contact instead of dropping it' do
      described_class.new(messaging, channel).perform

      expect(inbox.messages.count).to eq(1)
      expect(inbox.messages.last.message_type).to eq('outgoing')
      expect(inbox.contacts.count).to eq(1)
    end
  end
end
