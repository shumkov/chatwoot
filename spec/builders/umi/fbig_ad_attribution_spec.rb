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

  # The whole point of promoting after the transaction commits.
  it 'still persists the customer message when promotion raises' do
    allow(described_class).to receive(:promote).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect { perform(build_event(referral: ad_referral)) }.to change(Message, :count).by(1)
    expect(Message.last.content_attributes['referral']).to be_present
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
