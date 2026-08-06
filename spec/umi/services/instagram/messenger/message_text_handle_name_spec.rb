require 'rails_helper'

# Regression: with Business Asset User Profile Access granted, Meta's profile
# fetch for an Instagram user now SUCCEEDS but returns no 'name' — only
# 'username' (and sometimes 'profile_pic'). Upstream passes user['name'] =&gt; nil
# through to ContactInboxWithContactBuilder#contact_name, which falls back to
# Haikunator and mints a contact called something like "lingering-sun-586".
#
# That is worse than the "Instagram user NNNN" placeholder it replaced: a
# random adjective-noun name is indistinguishable from one an agent typed, so
# no later repair pass can safely touch it. Production census 2026-08-06 found
# 7 such contacts, all created within the preceding 30 days, the newest the day
# before — this path is actively minting them.
#
# The handle is right there in the same response. Use it.
describe Instagram::Messenger::MessageText do
  let!(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram_fb_page, account: account, instagram_id: 'chatwoot-app-user-id-2') }
  let!(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false) }
  let(:fb_object) { double }
  let(:sender_id) { 'ig-sender-nameless-1' }

  let(:messaging) do
    {
      'sender': { 'id': sender_id },
      'recipient': { 'id': 'chatwoot-app-user-id-2' },
      'timestamp': '2026-08-06T06:34:04+0000',
      'message': { 'mid': 'mid-nameless-profile', 'text': 'DM from a user Meta will not name' }
    }.with_indifferent_access
  end

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    # Exactly what production returns for most Instagram senders post-grant.
    allow(fb_object).to receive(:get_object).and_return(
      { 'id' => sender_id, 'username' => 'ploy.bkk', 'follower_count' => 120, 'is_verified_user' => false }
    )
  end

  it 'names the contact from the handle instead of minting a Haikunator name' do
    described_class.new(messaging, channel).perform

    contact = inbox.contact_inboxes.find_by(source_id: sender_id).contact
    expect(contact.name).to eq('ploy.bkk')
    expect(contact.name).not_to match(/\A[a-z]+-[a-z]+-\d{1,4}\z/)
  end

  # Without this the contact is frozen: a handle is not a recognised
  # placeholder shape, so the enrichment pass would refuse to touch it and it
  # could never be upgraded if Meta later returns a real display name.
  it 'records the written name so a later enrichment pass may still upgrade it' do
    described_class.new(messaging, channel).perform

    contact = inbox.contact_inboxes.find_by(source_id: sender_id).contact
    expect(contact.additional_attributes['umi_profile_name']).to eq('ploy.bkk')
    expect(contact.additional_attributes['social_instagram_user_name']).to eq('ploy.bkk')
  end

  # Erasure removed the handle, but the stock path re-wrote it from the
  # surviving source_id on the customer's very next message — so the erasure
  # lasted exactly until they said something again.
  it 'does not restore the handle of a contact whose erasure was requested' do
    described_class.new(messaging, channel).perform
    contact = inbox.contact_inboxes.find_by(source_id: sender_id).contact
    contact.update!(name: 'Redacted customer',
                    additional_attributes: { 'umi_profile_redacted' => true })

    described_class.new(messaging.merge('message' => { 'mid' => 'mid-2', 'text' => 'again' }), channel).perform

    attrs = contact.reload.additional_attributes
    expect(attrs).not_to have_key('social_instagram_user_name')
    expect(attrs).not_to have_key('social_profiles')
    expect(contact.name).to eq('Redacted customer')
  end

  it 'leaves a real display name alone when Meta provides one' do
    allow(fb_object).to receive(:get_object).and_return(
      { 'id' => sender_id, 'name' => 'Ploy Suwan', 'username' => 'ploy.bkk' }
    )

    described_class.new(messaging, channel).perform

    contact = inbox.contact_inboxes.find_by(source_id: sender_id).contact
    expect(contact.name).to eq('Ploy Suwan')
    expect(contact.additional_attributes).not_to have_key('umi_profile_name')
  end
end
