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
      # Contact profile fetch inside the IG builder path, which names the
      # fields it wants rather than relying on Meta's defaults.
      allow(api).to receive(:get_object).with('ig-customer-1', hash_including(:fields))
                                        .and_return({ 'name' => 'Jane', 'id' => 'ig-customer-1', 'username' => 'jane_ig' }.with_indifferent_access)
    end

    it 'persists the missing DM through the regular pipeline and stamps it recovered' do
      expect(service.heal('mid-lost')).to eq(:healed)

      message = inbox.messages.find_by(source_id: 'mid-lost')
      expect(message.content).to eq('the lost DM')
      expect(message.message_type).to eq('incoming')
      expect(message.content_attributes['umi_recovered']).to be true
    end

    it 'identifies a recovered Instagram DM and its original time before creation listeners run' do
      observed = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
        message = data[:message]
        observed << message.content_attributes.deep_dup if event == Events::Types::MESSAGE_CREATED && message&.source_id == 'mid-lost'
        original.call(event, time, data)
      end

      expect(service.heal('mid-lost')).to eq(:healed)
      expect(observed).to contain_exactly(hash_including('umi_recovered' => true, 'external_created_at' => '2026-07-21T10:00:00Z'))
    end

    [nil, 'invalid-time'].each do |source_time|
      it "keeps a recovered DM historical when its source time is #{source_time.inspect}" do
        detail['created_time'] = source_time

        expect(service.heal('mid-lost')).to eq(:healed)

        message = inbox.messages.find_by!(source_id: 'mid-lost')
        expect(message.content_attributes).to include('umi_recovered' => true, 'external_created_at' => nil)
      end
    end

    it 'keeps recovery time as created_at while normalizing the original source timezone' do
      detail['created_time'] = '2026-07-21T17:00:00+0700'

      freeze_time do
        expect(service.heal('mid-lost')).to eq(:healed)

        message = inbox.messages.find_by!(source_id: 'mid-lost')
        expect(message.created_at).to eq(Time.current)
        expect(message.content_attributes['external_created_at']).to eq('2026-07-21T10:00:00Z')
      end
    end

    it 'leaves a subsequent live webhook unmarked even when it includes forged recovery metadata' do
      expect(service.heal('mid-lost')).to eq(:healed)
      payload = {
        sender: { id: 'ig-customer-1' }, recipient: { id: channel.instagram_id },
        message: { mid: 'mid-live', text: 'new customer question' },
        umi_recovered: true, content_attributes: { umi_recovered: true, external_created_at: 'forged' }
      }.with_indifferent_access

      Instagram::Messenger::MessageText.new(payload, channel).perform

      message = inbox.messages.find_by!(source_id: 'mid-live')
      expect(message.content_attributes).not_to have_key('umi_recovered')
      expect(message.content_attributes).not_to have_key('external_created_at')
    end

    it 'does not emit a provenance-only message update after recovery' do
      updates = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
        updates << data[:message].source_id if event == Events::Types::MESSAGE_UPDATED
        original.call(event, time, data)
      end

      expect(service.heal('mid-lost')).to eq(:healed)
      expect(updates).not_to include('mid-lost')
    end

    it 'does not mark a live message recovered when it wins the race inside the Instagram builder' do
      conversation = create(:conversation, account: account, inbox: inbox)
      allow(Instagram::Messenger::MessageText).to receive(:new).and_wrap_original do |original, *args|
        create(:message, conversation: conversation, account: account, inbox: inbox, source_id: 'mid-lost')
        original.call(*args)
      end

      expect(service.heal('mid-lost')).to eq(:already_present)
      expect(inbox.messages.find_by!(source_id: 'mid-lost').content_attributes).not_to have_key('umi_recovered')
    end

    it 'restores enclosing recovery context after replay' do
      Umi::Fbig::RecoveryContext.set(inbox_id: -1, source_id: 'outer', source_created_at: 'outer-time') do
        expect(service.heal('mid-lost')).to eq(:healed)
        expect(Umi::Fbig::RecoveryContext.attributes).to eq(inbox_id: -1, source_id: 'outer', source_created_at: 'outer-time')
      end
      expect(Umi::Fbig::RecoveryContext.inbox_id).to be_nil
    end

    it 'restores recovery context when replay raises' do
      allow(Instagram::Messenger::MessageText).to receive(:new).and_raise(RuntimeError)

      Umi::Fbig::RecoveryContext.set(inbox_id: -1, source_id: 'outer', source_created_at: 'outer-time') do
        expect(service.heal('mid-lost')).to eq(:error)
        expect(Umi::Fbig::RecoveryContext.attributes).to eq(inbox_id: -1, source_id: 'outer', source_created_at: 'outer-time')
      end
      expect(Umi::Fbig::RecoveryContext.inbox_id).to be_nil
    end

    it 'skips when the mid arrived via webhook since the scan' do
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, conversation: conversation, account: account, inbox: inbox, source_id: 'mid-lost')

      expect(service.heal('mid-lost')).to eq(:already_present)
      expect(inbox.messages.where(source_id: 'mid-lost').count).to eq(1)
    end

    it 'does not replay a mid while another healer owns it' do
      lock_key = "UMI_FBIG_MESSAGE_HEAL_LOCK::#{channel.id}:instagram:mid-lost"
      Redis::Alfred.set(lock_key, 'another-healer', ex: 15.minutes.to_i)

      expect(service.heal('mid-lost')).to eq(:heal_in_progress)
      expect(api).not_to have_received(:get_object).with('mid-lost', anything)
    ensure
      Redis::Alfred.delete(lock_key)
    end

    it 'reports content_unavailable when the detail fetch fails' do
      allow(api).to receive(:get_object).with('mid-lost', anything)
                                        .and_raise(Koala::Facebook::ClientError.new(400, '', { 'message' => 'nope' }))

      expect(service.heal('mid-lost')).to eq(:content_unavailable)
      expect(inbox.messages.count).to eq(0)
    end

    it 'logs only the exception class when replay fails' do
      allow(Rails.logger).to receive(:warn)
      allow(Instagram::Messenger::MessageText).to receive(:new).and_raise(RuntimeError, 'sensitive replay detail')

      expect(service.heal('mid-lost')).to eq(:error)
      expect(Rails.logger).to have_received(:warn)
        .with('[UMI-FBIG] stage=heal_error mid=mid-lost error=RuntimeError')
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including('sensitive replay detail'))
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

    it 'identifies a recovered Facebook DM and its original time before creation listeners run' do
      observed = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, event, time, data|
        message = data[:message]
        observed << message.content_attributes.deep_dup if event == Events::Types::MESSAGE_CREATED && message&.source_id == 'mid-fb-lost'
        original.call(event, time, data)
      end

      expect(service.heal('mid-fb-lost')).to eq(:healed)
      expect(observed).to contain_exactly(hash_including('umi_recovered' => true, 'external_created_at' => '2026-07-21T10:00:00Z'))
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
