require 'rails_helper'

# Meta returns the follower count, the verified badge and the follow
# relationship on every Instagram profile fetch Chatwoot already makes, and
# upstream files them in additional_attributes — which no sidebar, filter,
# automation rule or AI assistant reads. In production 569 contacts carried
# these values invisibly, 196 of them with 5,000+ followers and 18 above
# 100,000, while agents saw nothing.
#
# Waiting for the nightly refresher is not good enough on the live path: it
# rotates the whole population, so a new influencer's numbers would surface
# weeks after the conversation ended.
describe Instagram::Messenger::MessageText do
  let!(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram_fb_page, account: account, instagram_id: 'chatwoot-app-user-id-3') }
  let!(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false) }
  let(:fb_object) { double }
  let(:sender_id) { 'ig-sender-influencer-1' }

  let(:messaging) do
    {
      'sender': { 'id': sender_id },
      'recipient': { 'id': 'chatwoot-app-user-id-3' },
      'timestamp': '2026-08-13T06:34:04+0000',
      'message': { 'mid': 'mid-influencer-profile', 'text': 'do you do collabs?' }
    }.with_indifferent_access
  end

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    allow(fb_object).to receive(:get_object).and_return(
      { 'id' => sender_id, 'username' => 'ploy.bkk', 'name' => 'Ploy',
        'follower_count' => 128_000, 'is_verified_user' => true,
        'is_user_follow_business' => true, 'is_business_follow_user' => false }
    )
  end

  def contact
    inbox.contact_inboxes.find_by(source_id: sender_id).contact
  end

  it 'makes the audience visible the moment the customer messages' do
    described_class.new(messaging, channel).perform

    expect(contact.custom_attributes).to include(
      'instagram_followers' => 128_000,
      'instagram_audience' => '100K+',
      'instagram_verified' => true,
      'instagram_follows_us' => true,
      'instagram_followed_by_us' => false
    )
  end

  # Upstream asks for no fields at all here and relies on whatever Meta chooses
  # to return. That happens to include the commercial fields today; if Meta
  # trims its default set they vanish with no error and no log line, and the
  # only symptom would be new contacts quietly arriving without numbers. The
  # sibling Instagram-Login path already names its fields.
  it 'names the fields it needs rather than trusting Meta defaults' do
    described_class.new(messaging, channel).perform

    expect(fb_object).to have_received(:get_object) do |_id, args|
      expect(args[:fields]).to include('follower_count', 'is_verified_user', 'is_user_follow_business', 'profile_pic')
    end
  end

  # Erasure purges the stored profile; the projection must not put a copy of it
  # back into a second column on the customer's next message.
  it 'projects nothing for a contact whose erasure was requested' do
    described_class.new(messaging, channel).perform
    erased = contact
    erased.update!(custom_attributes: {},
                   additional_attributes: { 'umi_profile_redacted' => true })

    described_class.new(messaging.deep_merge('message' => { 'mid' => 'mid-influencer-2' }), channel).perform

    expect(erased.reload.custom_attributes).to eq({})
  end

  it 'writes no email or phone number, whatever Meta returns' do
    allow(fb_object).to receive(:get_object).and_return(
      { 'id' => sender_id, 'username' => 'ploy.bkk', 'follower_count' => 900,
        'email' => "#{sender_id}@facebook.com" }
    )

    described_class.new(messaging, channel).perform

    expect(contact.email).to be_nil
    expect(contact.phone_number).to be_nil
  end
end
