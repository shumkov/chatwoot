# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Funnel::MessageWindow' do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:as_of) { Time.iso8601('2026-10-31T02:00:00Z') }
  let(:incoming) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: as_of - 24.hours)
  end
  let(:window) { Umi::Funnel::MessageWindow.new(conversation: conversation, as_of: as_of).perform }

  before do
    stub_request(:post, /graph.facebook.com/)
    stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook').to_return(status: 200, body: '{}')
    stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates').to_return(status: 200, body: '{"waba_templates":[]}')
    allow(GlobalConfigService).to receive(:load).with('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil).and_return(nil)
    allow(GlobalConfigService).to receive(:load).with('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT', nil).and_return(nil)
  end

  it 'closes at the exact native 24-hour boundary with the currently unset flag' do
    incoming
    travel_to(as_of) do
      expect(window).to include(can_reply: conversation.can_reply?, state: 'closed', reason: 'expired',
                                human_extension: 'disabled', standard_expires_at: as_of.iso8601(6), human_expires_at: nil,
                                native_last_incoming_message_id: incoming.id, last_incoming_message_id: incoming.id,
                                evaluated_at: as_of.iso8601(6))
      before = Umi::Funnel::MessageWindow.new(conversation: conversation, as_of: as_of - 0.000001.seconds).perform
      expect(before).to include(can_reply: true, state: 'standard_open')
    end
  end

  it 'does not invent a countdown when no restricted-channel incoming exists' do
    expect(window).to include(can_reply: false, state: 'closed', reason: 'no_incoming', standard_expires_at: nil)
  end

  it 'uses the latest incoming in the burst, ignoring outgoing and private progress' do
    incoming
    latest = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: as_of - 1.hour)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, created_at: as_of - 1.minute)
    expect(window).to include(state: 'standard_open', last_incoming_message_id: latest.id,
                              standard_expires_at: (latest.created_at + 24.hours).iso8601(6))
  end

  it 'does not let a recovered storage timestamp manufacture a fresh window' do
    incoming
    recovered = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: as_of - 1.hour,
                                 content_attributes: { umi_recovered: true, external_created_at: (as_of - 2.days).iso8601 })
    expect(window).to include(can_reply: true, state: 'unknown', reason: 'native_incoming_mismatch',
                              native_last_incoming_message_id: recovered.id, last_incoming_message_id: incoming.id,
                              standard_expires_at: as_of.iso8601(6))
  end

  [{ deleted: true }, { umi_recovered: true, external_created_at: 'unknown' }].each do |attributes|
    it "keeps #{attributes.keys.first} native history uncertain" do
      incoming
      latest = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: as_of - 1.hour,
                                content_attributes: attributes)
      expect(window).to include(can_reply: true, state: 'unknown', native_last_incoming_message_id: latest.id)
    end
  end

  it 'preserves native private incoming selection without treating it as trustworthy customer contact' do
    incoming
    latest = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, private: true,
                              created_at: as_of - 1.hour)
    expect(window).to include(can_reply: true, state: 'unknown', reason: 'native_incoming_mismatch',
                              native_last_incoming_message_id: latest.id, last_incoming_message_id: incoming.id)
  end

  it 'bounds historical incoming selection to as_of and labels current-policy reconstruction' do
    incoming
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: as_of + 1.hour)
    result = Umi::Funnel::MessageWindow.new(conversation: conversation, as_of: as_of, historical: true).perform
    expect(result).to include(can_reply: false, state: 'closed', native_last_incoming_message_id: incoming.id,
                              basis: 'historical_reconstruction_current_policy_history_unavailable')
  end

  it 'holds genuine future stored incoming timestamps as unknown in live evidence' do
    travel_to(as_of) do
      incoming
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: as_of + 1.hour)
      expect(window).to include(state: 'unknown', reason: 'future_incoming_timestamp')
    end
  end

  it 'uses the Messenger flag for Page-linked Instagram and never invents extension approval' do
    incoming
    conversation.update!(additional_attributes: { type: 'instagram_direct_message' })
    allow(GlobalConfigService).to receive(:load).with('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil).and_return(true)
    expect(window).to include(channel_type: 'Channel::FacebookPage', messaging_channel: 'instagram', can_reply: true,
                              state: 'unknown', reason: 'human_extension_unverified', human_extension: 'unverified', human_expires_at: nil)
    first_revision = window[:policy_revision]
    allow(GlobalConfigService).to receive(:load).with('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil).and_return(nil)
    refreshed = Umi::Funnel::MessageWindow.new(conversation: conversation, as_of: as_of).perform
    expect(refreshed[:policy_revision]).not_to eq(first_revision)
  end

  it 'does not hide a recovered future source time behind a later valid incoming' do
    create(:message, account: account, inbox: inbox, conversation: conversation, created_at: as_of - 2.hours,
                     content_attributes: { umi_recovered: true, external_created_at: (as_of + 1.hour).iso8601 })
    create(:message, account: account, inbox: inbox, conversation: conversation, created_at: as_of - 1.hour)
    expect(window).to include(state: 'unknown', reason: 'future_incoming_timestamp')
  end

  [nil, 'unknown'].each do |source_time|
    it "keeps an unparseable recovered source #{source_time.inspect} unknown despite a later normal incoming" do
      create(:message, account: account, inbox: inbox, conversation: conversation, created_at: as_of - 2.hours,
                       content_attributes: { umi_recovered: true, external_created_at: source_time })
      latest = create(:message, account: account, inbox: inbox, conversation: conversation, created_at: as_of - 1.hour)

      expect(window).to include(can_reply: true, state: 'unknown', reason: 'source_time_unavailable',
                                native_last_incoming_message_id: latest.id, last_incoming_message_id: latest.id)
    end
  end

  [[:channel_facebook_page, 'ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT'],
   [:channel_instagram, 'ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT']].each do |factory, flag|
    context "with unverified HUMAN_AGENT on #{factory}" do
      let(:channel) { create(factory, account: account) }

      before do
        incoming
        allow(GlobalConfigService).to receive(:load).with(flag, nil).and_return(true)
      end

      it 'keeps the standard window open until the exact 24-hour deadline' do
        result = Umi::Funnel::MessageWindow.new(conversation: conversation, as_of: as_of - 0.000001.seconds).perform

        expect(result).to include(can_reply: true, state: 'standard_open', reason: 'within_standard_window',
                                  standard_expires_at: as_of.iso8601(6), human_extension: 'unverified', human_expires_at: nil)
      end

      [0.seconds, 1.second].each do |elapsed|
        it "keeps extension approval unknown #{elapsed} seconds after the standard deadline" do
          result = Umi::Funnel::MessageWindow.new(conversation: conversation, as_of: as_of + elapsed).perform

          expect(result).to include(can_reply: true, state: 'unknown', reason: 'human_extension_unverified',
                                    standard_expires_at: as_of.iso8601(6), human_extension: 'unverified', human_expires_at: nil)
        end
      end
    end
  end

  context 'without a native time restriction' do
    let(:channel) { create(:channel_line, account: account) }

    it 'retains native and trustworthy facts without gating a deadline-free mismatch' do
      incoming
      private_incoming = create(:message, account: account, inbox: inbox, conversation: conversation,
                                          private: true, created_at: as_of - 1.hour)
      expect(window).to include(can_reply: true, state: 'unrestricted', standard_expires_at: nil,
                                native_last_incoming_message_id: private_incoming.id, last_incoming_message_id: incoming.id)
    end
  end

  it 'keeps the native seven-day expiry strict even while permission remains unknown' do
    incoming.update!(created_at: as_of - 7.days)
    allow(GlobalConfigService).to receive(:load).with('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil).and_return(true)
    expect(window).to include(can_reply: false, state: 'unknown', human_extension: 'unverified')
  end

  policies = [
    [:channel_line, {}, 'unrestricted'],
    [:channel_twilio_sms, {}, 'unrestricted'],
    [:channel_twilio_sms, { medium: :whatsapp }, 'closed'],
    [:channel_whatsapp, {}, 'closed'],
    [:channel_instagram, {}, 'closed'],
    [:channel_api, { additional_attributes: { agent_reply_time_window: '12' } }, 'closed']
  ]
  policies.each do |factory, attrs, state|
    context "with #{factory} #{attrs}" do
      let(:channel) { create(factory, **attrs, account: account) }

      it 'matches native policy selection without copying its channel duration table' do
        incoming
        travel_to(as_of) do
          expect(window).to include(can_reply: conversation.can_reply?, state: state)
          expect(window[:standard_expires_at]).to be_nil if state == 'unrestricted'
        end
      end
    end
  end
end
