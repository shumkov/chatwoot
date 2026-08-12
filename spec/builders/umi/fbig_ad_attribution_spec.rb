require 'rails_helper'

# Meta nests `referral` INSIDE `message`. Reading the top-level key returns nil,
# which is indistinguishable from an organic conversation — so a patch with the
# wrong path captures nothing while every test passes. These specs pin the real
# shape, taken from a production payload.
describe Umi::FbigAdAttribution do
  before { stub_request(:post, /graph\.facebook\.com/) }

  let!(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram_fb_page, account: account, instagram_id: 'chatwoot-app-user-id-1') }
  let!(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false) }
  let(:fb_object) { double }

  let(:ad_referral) do
    { 'source' => 'ADS', 'type' => 'OPEN_THREAD', 'ad_id' => '120252251820030415',
      'ads_context_data' => { 'ad_title' => 'Video_2', 'video_url' => 'https://scontent.example/v.jpg' } }
  end

  def build_event(referral: nil, echo: false)
    params = build(:instagram_message_create_event).with_indifferent_access
    messaging = params[:entry][0]['messaging'][0]
    messaging['message']['referral'] = referral if referral
    messaging['message']['is_echo'] = true if echo
    messaging
  end

  # The builder resolves an existing contact_inbox rather than creating one, so
  # without this every example would pass vacuously against zero messages.
  def perform(messaging, echo: false)
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    allow(fb_object).to receive(:get_object).and_return(
      { name: 'Jane', id: messaging['sender']['id'] }.with_indifferent_access
    )
    source_id = echo ? messaging['recipient']['id'] : messaging['sender']['id']
    create_instagram_contact_for_sender(source_id, inbox)
    Messages::Instagram::Messenger::MessageBuilder.new(messaging, inbox, outgoing_echo: echo).perform
  end

  it 'stores the referral Meta nested inside message, not the top-level key' do
    messaging = build_event(referral: ad_referral)
    # Prove the top-level key really is absent — that is the bug this guards.
    expect(messaging['referral']).to be_nil

    perform(messaging)

    expect(Message.last.content_attributes['referral']).to include(
      'ad_id' => '120252251820030415', 'source' => 'ADS'
    )
  end

  it 'promotes the readable fields onto the conversation so agents and rules can see them' do
    expect(described_class).to receive(:promote).and_call_original
    perform(build_event(referral: ad_referral))

    expect(Conversation.last.custom_attributes).to include(
      'meta_ad_id' => '120252251820030415', 'meta_ad_title' => 'Video_2'
    )
  end

  it 'omits meta_ad_ref when nobody set a ref on the ad, rather than writing a blank' do
    perform(build_event(referral: ad_referral))

    expect(Conversation.last.custom_attributes).not_to have_key('meta_ad_ref')
  end

  # Meta reuses message.referral for Instagram Shops product taps. Those carry
  # no ad, so promoting them would label organic conversations as ad-driven.
  it 'does not promote a Shops product referral, but still records it on the message' do
    perform(build_event(referral: { 'product' => { 'id' => 'PRODUCT-ID' } }))

    expect(Conversation.last.custom_attributes).not_to include('meta_ad_id')
    expect(Message.last.content_attributes['referral']).to eq('product' => { 'id' => 'PRODUCT-ID' })
  end

  it 'does not promote a referral with an ad id but without the ADS source' do
    referral = { 'ad_id' => '120252251820030415', 'type' => 'OPEN_THREAD' }

    perform(build_event(referral: referral))

    expect(Conversation.last.custom_attributes).not_to have_key('meta_ad_id')
    expect(Message.last.content_attributes['referral']).to eq(referral)
  end

  it 'captures nothing for an echo, which is the business talking to itself' do
    perform(build_event(referral: ad_referral, echo: true), echo: true)

    expect(Message.last.content_attributes).not_to have_key('referral')
    expect(Conversation.last.custom_attributes).not_to have_key('meta_ad_id')
  end

  # A bare merge would leave the first ad's title beside the second ad's id,
  # describing an ad that never existed.
  it 'replaces the whole attribution on a second ad, leaving no field from the first' do
    perform(build_event(referral: ad_referral))
    conversation = Conversation.last

    described_class.promote(
      conversation.messages.last,
      { 'source' => 'ADS', 'ad_id' => '999888777666555' }
    )

    attrs = conversation.reload.custom_attributes
    expect(attrs['meta_ad_id']).to eq('999888777666555')
    expect(attrs).not_to have_key('meta_ad_title')
  end

  it 'preserves an unrelated sidebar attribute written after the conversation was loaded' do
    perform(build_event(referral: ad_referral))
    message = Message.last
    message.conversation
    Conversation.where(id: message.conversation_id)
                .update_all(custom_attributes: { 'sidebar_priority' => 'high' }) # rubocop:disable Rails/SkipsModelValidations

    described_class.promote(message, ad_referral)

    expect(message.conversation.reload.custom_attributes).to include(
      'sidebar_priority' => 'high', 'meta_ad_id' => '120252251820030415'
    )
  end

  # The whole point of promoting after the transaction commits.
  it 'still persists the customer message when promotion raises' do
    messaging = build_event(referral: ad_referral)
    sender_id = messaging['sender']['id']
    contact = create(:contact, account: account, identifier: sender_id)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: sender_id)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    conversation.update_columns(custom_attributes: { 'oversized' => 'x' * 1501 }) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class).to receive(:promote)
      .with(instance_of(Message), hash_including('source' => 'ADS'))
      .and_call_original

    expect { perform(messaging) }.to change(Message, :count).by(1)
    expect(Message.last.content_attributes['referral']).to be_present
  end

  it 'captures a referral through the Facebook parser and message builder' do
    facebook_channel = create(:channel_facebook_page, account: account)
    response = Integrations::Facebook::MessageParser.new(
      {
        messaging: {
          sender: { id: 'facebook-sender-1' },
          recipient: { id: facebook_channel.page_id },
          timestamp: 1,
          message: { mid: 'facebook-message-1', text: 'I am interested', referral: ad_referral }
        }
      }.to_json
    )

    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    allow(fb_object).to receive(:get_object).and_return(
      { first_name: 'Jane', last_name: 'Dae', profile_pic: 'https://chatwoot-assets.local/sample.png' }.with_indifferent_access
    )

    Messages::Facebook::MessageBuilder.new(response, facebook_channel.inbox).perform

    message = facebook_channel.inbox.messages.find_by(source_id: 'facebook-message-1')
    expect(message.content_attributes['referral']).to include('source' => 'ADS', 'ad_id' => '120252251820030415')
    expect(message.conversation.custom_attributes).to include('meta_ad_id' => '120252251820030415')
  end

  # purge_for is the Shopify customers/redact path — a statutory erasure. It
  # shipped with no test of its own, and the referral half never deleted
  # anything: messages.content_attributes is a json column carrying a `store`
  # coder, so what Postgres holds is a JSON *string* and
  # `content_attributes::jsonb -> 'referral'` matches nothing. The method
  # returned cleanly either way, so nothing surfaced it.
  describe 'erasure' do
    def stored_referral
      Message.find(Message.last.id).content_attributes['referral']
    end

    it 'deletes the referral from the message, stored the way the live path stores it' do
      perform(build_event(referral: ad_referral))
      contact = Message.last.conversation.contact
      expect(stored_referral).to be_present

      described_class.purge_for(contact)

      expect(stored_referral).to be_nil
    end

    it 'leaves the rest of content_attributes intact rather than blanking the column' do
      perform(build_event(referral: ad_referral))
      message = Message.last
      message.update_columns(content_attributes: message.content_attributes.merge('in_reply_to' => 42)) # rubocop:disable Rails/SkipsModelValidations

      described_class.purge_for(message.conversation.contact)

      attributes = Message.find(message.id).content_attributes
      expect(attributes).to include('in_reply_to' => 42)
      expect(attributes).not_to have_key('referral')
    end

    # The conversation half is a different column: jsonb with no store coder, so
    # the minus operator does work on it directly. Verified rather than assumed,
    # because the two halves of this method fail independently.
    it 'strips the promoted fields from the conversation' do
      perform(build_event(referral: ad_referral))
      conversation = Message.last.conversation
      expect(conversation.custom_attributes).to include('meta_ad_id')

      described_class.purge_for(conversation.contact)

      expect(conversation.reload.custom_attributes).not_to include('meta_ad_id', 'meta_ad_ref', 'meta_ad_title')
    end

    it 'keeps unrelated conversation attributes' do
      perform(build_event(referral: ad_referral))
      conversation = Message.last.conversation
      conversation.update!(custom_attributes: conversation.custom_attributes.merge('sidebar_priority' => 'high'))

      described_class.purge_for(conversation.contact)

      expect(conversation.reload.custom_attributes).to eq('sidebar_priority' => 'high')
    end

    it 'does nothing for a contact with no conversations' do
      expect { described_class.purge_for(create(:contact, account: account)) }.not_to raise_error
    end
  end

  describe 'the Facebook payload, which is String-keyed rather than indifferent-access' do
    it 'reads the nested referral through the parser' do
      json = { messaging: { sender: { id: '1' }, recipient: { id: '2' }, timestamp: 1,
                            message: { mid: 'm1', text: 'hi', referral: ad_referral } } }.to_json

      expect(Integrations::Facebook::MessageParser.new(json).message_referral).to include('ad_id' => '120252251820030415')
    end

    it 'returns nil when there is no referral, so organic stays organic' do
      json = { messaging: { sender: { id: '1' }, recipient: { id: '2' }, timestamp: 1,
                            message: { mid: 'm1', text: 'hi' } } }.to_json

      expect(Integrations::Facebook::MessageParser.new(json).message_referral).to be_nil
    end
  end
end
