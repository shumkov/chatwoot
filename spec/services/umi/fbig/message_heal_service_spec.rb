require 'rails_helper'

describe Umi::Fbig::MessageHealService do
  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
  end

  let!(:account) { create(:account) }
  let!(:channel) do
    create(:channel_instagram_fb_page, account: account, page_id: 'page-1', instagram_id: 'ig-1')
  end
  let!(:inbox) { create(:inbox, channel: channel, account: account) }
  let(:api) { double }

  describe 'instagram replay' do
    let(:service) { described_class.new(channel, 'instagram') }
    let(:detail) do
      { 'id' => 'mid-lost', 'created_time' => '2026-07-21T10:00:00+0000',
        'from' => { 'id' => 'ig-customer-1' }, 'message' => 'the lost DM' }
    end

    before do
      allow(api).to receive(:get_object).with('mid-lost', anything).and_return(detail)
      # Contact profile fetch inside the IG builder path.
      allow(api).to receive(:get_object).with('ig-customer-1')
                                        .and_return({ 'name' => 'Jane', 'id' => 'ig-customer-1', 'username' => 'jane_ig' }.with_indifferent_access)
    end

    it 'persists the missing DM through the regular pipeline and stamps it recovered' do
      expect(service.heal('mid-lost')).to eq(:healed)

      message = inbox.messages.find_by(source_id: 'mid-lost')
      expect(message.content).to eq('the lost DM')
      expect(message.message_type).to eq('incoming')
      expect(message.content_attributes['umi_recovered']).to be true
    end

    it 'skips when the mid arrived via webhook since the scan' do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, conversation: conversation, account: account, inbox: inbox, source_id: 'mid-lost')

      expect(service.heal('mid-lost')).to eq(:already_present)
      expect(inbox.messages.where(source_id: 'mid-lost').count).to eq(1)
    end

    it 'reports content_unavailable when the detail fetch fails' do
      allow(api).to receive(:get_object).with('mid-lost', anything)
                                        .and_raise(Koala::Facebook::ClientError.new(400, '', { 'message' => 'nope' }))

      expect(service.heal('mid-lost')).to eq(:content_unavailable)
      expect(inbox.messages.count).to eq(0)
    end
  end

  describe 'facebook replay' do
    let(:service) { described_class.new(channel, 'messenger') }
    let(:detail) do
      { 'id' => 'mid-fb-lost', 'created_time' => '2026-07-21T10:00:00+0000',
        'from' => { 'id' => 'fb-customer-1' }, 'message' => 'lost messenger text',
        'attachments' => { 'data' => [
          { 'image_data' => { 'url' => 'https://www.example.com/test.jpeg' } },
          { 'unmappable' => true }
        ] } }
    end

    before do
      stub_request(:get, 'https://www.example.com/test.jpeg').to_return(status: 200, body: '')
      allow(api).to receive(:get_object).with('mid-fb-lost', anything).and_return(detail)
      allow(api).to receive(:get_object).with('fb-customer-1')
                                        .and_return({ 'first_name' => 'Jane', 'last_name' => 'Dae' }.with_indifferent_access)
    end

    it 'persists the message with mappable attachments through the FB builder' do
      expect(service.heal('mid-fb-lost')).to eq(:healed)

      message = inbox.messages.find_by(source_id: 'mid-fb-lost')
      expect(message.content).to eq('lost messenger text')
      expect(message.attachments.count).to eq(1)
      expect(message.content_attributes['umi_recovered']).to be true
    end
  end
end
