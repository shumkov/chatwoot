require 'rails_helper'

# The trigger is prepended onto Umi::FbigAdAttribution, whose methods are
# declared with module_function. That gives the module both a private instance
# copy and a singleton copy, and only calls made through an explicit receiver go
# through the singleton class where this prepend sits. Patch 20 calls it that
# way today; if a rebase changes it, the notes stop and nothing says so.
describe Umi::Meta::AdContextNoteTrigger do
  before { stub_request(:post, /graph\.facebook\.com/) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
  end
  let(:ad_referral) do
    { 'source' => 'ADS', 'ad_id' => '120252251820030415', 'ads_context_data' => { 'ad_title' => 'Video_2' } }
  end

  it 'sits in front of the module patch 20 actually calls' do
    expect(Umi::FbigAdAttribution.singleton_class.ancestors).to include(described_class)
  end

  it 'enqueues the note once attribution has been written' do
    expect { Umi::FbigAdAttribution.promote(message, ad_referral) }
      .to have_enqueued_job(Umi::Meta::AdContextNoteJob).with(conversation.id)
  end

  # Meta reuses the referral object for Instagram Shops product taps, which
  # patch 20 declines to promote. Enqueuing there would spend a Sidekiq job to
  # discover there is nothing to do.
  it 'does not enqueue for referrals that are not ads' do
    expect { Umi::FbigAdAttribution.promote(message, { 'source' => 'SHOPS', 'product' => {} }) }
      .not_to have_enqueued_job(Umi::Meta::AdContextNoteJob)
  end

  # If this rescue covered super, an attribution failure would be logged as an
  # enqueue failure and patch 20's exception tracker would never be reached —
  # on an installation where that log line is the only signal there is.
  it 'lets a failure inside patch 20 surface as patch 20 reports it' do
    allow(conversation).to receive(:update!).and_raise(ActiveRecord::LockWaitTimeout)
    allow(message).to receive(:conversation).and_return(conversation)

    expect { Umi::FbigAdAttribution.promote(message, ad_referral) }.to raise_error(ActiveRecord::LockWaitTimeout)
  end

  it 'does not let a broken queue cost the attribution write' do
    allow(Umi::Meta::AdContextNoteJob).to receive(:perform_later).and_raise(Redis::CannotConnectError)

    expect { Umi::FbigAdAttribution.promote(message, ad_referral) }.not_to raise_error
    expect(conversation.reload.custom_attributes).to include('meta_ad_id' => '120252251820030415')
  end

  describe 'erasure' do
    it 'removes the note when a Shopify redaction erases ad attribution' do
      Umi::FbigAdAttribution.promote(message, ad_referral)
      note = conversation.messages.create!(
        account_id: account.id, inbox_id: inbox.id, message_type: :outgoing, private: true,
        content: 'ad copy', content_attributes: { 'umi_ad_context' => { 'ad_id' => '1', 'status' => 'ok' } }
      )

      Umi::FbigAdAttribution.purge_for(contact.reload)

      expect(Message.exists?(note.id)).to be(false)
      expect(conversation.reload.custom_attributes).not_to include('meta_ad_id')
    end

    it 'removes failure notes too, since they also name the ad' do
      note = conversation.messages.create!(
        account_id: account.id, inbox_id: inbox.id, message_type: :outgoing, private: true,
        content: 'unavailable', content_attributes: { 'umi_ad_context' => { 'ad_id' => '1', 'status' => 'error' } }
      )

      Umi::FbigAdAttribution.purge_for(contact.reload)

      expect(Message.exists?(note.id)).to be(false)
    end

    it 'leaves ordinary messages alone' do
      keep = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'hello')

      Umi::FbigAdAttribution.purge_for(contact.reload)

      expect(Message.exists?(keep.id)).to be(true)
    end
  end
end
