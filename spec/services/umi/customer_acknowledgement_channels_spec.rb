# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::CustomerAcknowledgement do
  let(:account) { create(:account) }
  let(:opened_at) { Time.iso8601('2026-10-18T03:00:00Z') }
  let(:old_generation) { (opened_at - 2.hours).iso8601 }
  let(:new_generation) { (opened_at - 1.hour).iso8601 }
  let(:facebook) { create(:inbox, account: account, channel: create(:channel_facebook_page, account: account)) }
  let(:website) { create(:inbox, account: account, channel: create(:channel_widget, account: account, continuity_via_email: true)) }
  let(:line) { create(:inbox, account: account, channel: create(:channel_line, account: account)) }
  let(:whatsapp) { create(:inbox, account: account, channel: create(:channel_twilio_sms, :whatsapp, account: account)) }
  let(:settings) do
    InstallationConfig.create!(name: 'UMI_CUSTOMER_ACKNOWLEDGEMENTS', value: {
                                 'inbox_ids' => [facebook.id, website.id, line.id, whatsapp.id], 'started_at' => old_generation,
                                 'inbox_started_at' => { website.id.to_s => new_generation, line.id.to_s => new_generation,
                                                         whatsapp.id.to_s => new_generation }
                               })
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    travel_to opened_at
    settings
    [facebook, website, line, whatsapp].each do |inbox|
      inbox.update!(working_hours_enabled: true, timezone: 'Asia/Bangkok', out_of_office_message: '', greeting_enabled: false)
      inbox.working_hours.each do |hours|
        hours.update!(closed_all_day: false, open_hour: 9, open_minutes: 0, close_hour: 21, close_minutes: 0)
      end
    end
    clear_enqueued_jobs
  end

  def incoming_for(inbox, content: 'Is size M available?')
    create(:message, conversation: create(:conversation, account: account, inbox: inbox), message_type: :incoming, content: content)
  end

  def ack_jobs
    enqueued_jobs.select { |entry| entry[:job].name == 'Umi::CustomerAcknowledgementJob' }
  end

  [[:website, 'day'], [:line, 'night'], [:whatsapp, 'day']].each do |channel, mode|
    it "acknowledges a waiting #{channel} customer in #{mode} mode without a human response" do
      travel_to opened_at.change(hour: 15) if mode == 'night'
      message = incoming_for(send(channel))
      expect(ack_jobs.sole[:args][1]).to eq(new_generation)
      travel 5.minutes if mode == 'day'
      Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, mode)
      acknowledgement = message.conversation.messages.template.sole
      expect(acknowledgement.content_attributes).to have_key(Umi::CustomerAcknowledgement::MARKER)
      expect(acknowledgement.send(:human_response?)).to be(false)
      expect(message.conversation.reload.first_reply_created_at).to be_nil
    end
  end

  it 'preserves a queued Facebook job and its old activation after adding other inboxes' do
    message = incoming_for(facebook)
    expect(ack_jobs.sole[:args][1]).to eq(old_generation)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, old_generation, 'day')
    expect(message.conversation.messages.template.count).to eq(1)
  end

  it 'does not schedule pre-cutover website messages or include them in the new burst' do
    travel_to Time.iso8601(new_generation) - 1.minute
    previous = incoming_for(website, content: 'Old question')
    expect(ack_jobs).to be_empty
    travel_to opened_at
    current = create(:message, conversation: previous.conversation, message_type: :incoming, content: 'New question')
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(current.id, new_generation, 'day')
    marker = current.conversation.messages.template.sole.content_attributes.fetch(Umi::CustomerAcknowledgement::MARKER)
    expect(marker['first_message_id']).to eq(current.id)
  end

  it 'cancels removed inbox jobs and rejects their old generation after re-add' do
    message = incoming_for(website)
    settings.update!(value: settings.value.merge('inbox_ids' => [facebook.id, line.id, whatsapp.id]))
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    expect(message.conversation.messages.template).to be_empty
    fresh_generation = Time.current.iso8601
    started = settings.value.fetch('inbox_started_at').merge(website.id.to_s => fresh_generation)
    settings.update!(value: settings.value.merge('inbox_ids' => [facebook.id, website.id, line.id, whatsapp.id],
                                                 'inbox_started_at' => started))
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    expect(message.conversation.messages.template).to be_empty
  end

  it 'uses the global generation with an old configuration lacking per-inbox timestamps' do
    settings.update!(value: { 'inbox_ids' => [facebook.id], 'started_at' => old_generation })
    message = incoming_for(facebook)
    expect(ack_jobs.sole[:args][1]).to eq(old_generation)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, old_generation, 'day')
    expect(message.conversation.messages.template.count).to eq(1)
  end

  it 'reloads the inbox when an inbound request spans a website away-message cutover' do
    website.update!(out_of_office_message: 'Old away text')
    stale_inbox = Inbox.find(website.id)
    stale_inbox.out_of_office_message
    website.update!(out_of_office_message: '')
    message = build(:message, conversation: create(:conversation, account: account, inbox: stale_inbox),
                              inbox: stale_inbox, message_type: :incoming, content: 'Question after cutover')
    expect(described_class).to receive(:schedule).with(message).and_call_original
    expect { message.save! }.not_to raise_error
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    expect(message.conversation.messages.template.count).to eq(1)
  end

  it 'rejects configured SMS, native WhatsApp, Email and API inboxes' do
    stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook').to_return(status: 200, body: '{}')
    stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates').to_return(status: 200, body: '{"waba_templates":[]}')
    [create(:channel_twilio_sms, account: account), create(:channel_whatsapp, account: account),
     create(:channel_email, account: account), create(:channel_api, account: account)].each do |channel|
      inbox = create(:inbox, account: account, channel: channel, working_hours_enabled: true, timezone: 'Asia/Bangkok')
      settings.update!(value: settings.value.merge('inbox_ids' => settings.value.fetch('inbox_ids') + [inbox.id]))
      inbox.working_hours.each do |hours|
        hours.update!(closed_all_day: false, open_hour: 9, open_minutes: 0, close_hour: 21, close_minutes: 0)
      end
      expect { incoming_for(inbox) }.to raise_error(ArgumentError, /Customer acknowledgements require/)
    end
  end

  it 'allows non-Facebook channels while the global HUMAN_AGENT setting is enabled' do
    allow(GlobalConfigService).to receive(:load).with('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil).and_return(true)
    message = incoming_for(line)
    travel 5.minutes
    expect { Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day') }.not_to raise_error
    expect(message.conversation.messages.template.count).to eq(1)
  end

  it 'keeps website email continuity for a human reply and an unmarked template after a widget-only acknowledgement' do # rubocop:disable RSpec/MultipleExpectations
    message = incoming_for(website)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    acknowledgement = message.conversation.messages.template.sole
    expect(acknowledgement.private?).to be(false)
    expect(acknowledgement.push_event_data[:content]).to eq(Umi::CustomerAcknowledgement::DAY_COPY)
    event = Events::Base.new(:'message.created', Time.current, message: acknowledgement)
    allow(ActionCableBroadcastJob).to receive(:perform_later)
    ActionCableListener.instance.message_created(event)
    expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
      array_including(message.conversation.contact_inbox.pubsub_token), 'message.created',
      hash_including(content: Umi::CustomerAcknowledgement::DAY_COPY, account_id: account.id)
    )
    clear_enqueued_jobs
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(Redis::Alfred).to receive(:incr).and_return(1)
    allow(Redis::Alfred).to receive(:expire)
    expect { SendReplyJob.perform_now(acknowledgement.id) }.not_to have_enqueued_job(ConversationReplyEmailJob)
    expect(Redis::Alfred).not_to have_received(:set)
    expect(Redis::Alfred).not_to have_received(:incr)
    agent = create(:user, account: account)
    human = create(:message, conversation: message.conversation, message_type: :outgoing, sender: agent, content: 'We can help.')
    expect { SendReplyJob.perform_now(human.id) }.to have_enqueued_job(ConversationReplyEmailJob).with(message.conversation.id, human.id)
    expect(Redis::Alfred).to have_received(:set).once
    expect(Redis::Alfred).to have_received(:incr).once

    unmarked = create(:message, conversation: message.conversation, message_type: :template, content: 'Ordinary template')
    expect { SendReplyJob.perform_now(unmarked.id) }.to have_enqueued_job(ConversationReplyEmailJob).with(message.conversation.id, unmarked.id)
    expect(Redis::Alfred).to have_received(:set).twice
  end

  it 'sends the WhatsApp acknowledgement through Twilio as free-form text with a persisted provider ID' do
    message = incoming_for(whatsapp)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    acknowledgement = message.conversation.messages.template.sole
    twilio_messages = double
    allow(Twilio::REST::Client).to receive(:new).and_return(double(messages: twilio_messages)) # rubocop:disable RSpec/VerifiedDoubles
    expect(twilio_messages).to receive(:create) do |params|
      expect(params).to include(body: Umi::CustomerAcknowledgement::DAY_COPY,
                                to: message.conversation.contact_inbox.source_id)
      expect(params).not_to have_key(:content_sid)
      Struct.new(:sid).new('ack-wa-123')
    end
    SendReplyJob.perform_now(acknowledgement.id)
    expect(acknowledgement.reload.source_id).to eq('ack-wa-123')
  end

  it 'records a failed Twilio WhatsApp send through the native status path' do
    message = incoming_for(whatsapp)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    acknowledgement = message.conversation.messages.template.sole
    twilio_messages = double
    allow(Twilio::REST::Client).to receive(:new).and_return(double(messages: twilio_messages)) # rubocop:disable RSpec/VerifiedDoubles
    allow(twilio_messages).to receive(:create).and_raise(Twilio::REST::TwilioError)
    SendReplyJob.perform_now(acknowledgement.id)
    expect(acknowledgement.reload.status).to eq('failed')
    expect(message.conversation.reload.first_reply_created_at).to be_nil
  end

  it 'uses native LINE push and records accepted or failed delivery status' do
    message = incoming_for(line)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    acknowledgement = message.conversation.messages.template.sole
    client = double
    allow(Line::Bot::Client).to receive(:new).and_return(client)
    expect(client).to receive(:push_message).with(message.conversation.contact_inbox.source_id,
                                                  { type: 'text', text: Umi::CustomerAcknowledgement::DAY_COPY })
                                            .and_return(OpenStruct.new(code: '200', body: '{}'))
    SendReplyJob.perform_now(acknowledgement.id)
    expect(acknowledgement.reload.status).to eq('delivered')
  end

  it 'keeps LINE acknowledgement deduplication across day and night and after a human reply' do
    first = incoming_for(line)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(first.id, new_generation, 'day')
    travel_to opened_at.change(hour: 15)
    second = create(:message, conversation: first.conversation, message_type: :incoming, content: 'Any update?')
    Umi::CustomerAcknowledgementJob.new.perform(second.id, new_generation, 'night')
    expect(first.conversation.messages.template.count).to eq(1)
    create(:message, conversation: first.conversation, message_type: :outgoing,
                     sender: create(:user, account: account), content: 'Working on it.')
    travel 6.minutes
    third = create(:message, conversation: first.conversation, message_type: :incoming, content: 'Another question')
    Umi::CustomerAcknowledgementJob.new.perform(third.id, new_generation, 'night')
    expect(first.conversation.messages.template.count).to eq(2)
  end

  it 'does not treat a private note, bot reply or failed human send as an answer on LINE' do
    message = incoming_for(line)
    create(:message, conversation: message.conversation, message_type: :outgoing,
                     sender: create(:user, account: account), private: true, content: 'Checking stock')
    create(:message, conversation: message.conversation, message_type: :outgoing,
                     sender: create(:agent_bot), content: 'Received')
    create(:message, conversation: message.conversation, message_type: :outgoing,
                     sender: create(:user, account: account), status: :failed, content: 'Available')
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    expect(message.conversation.messages.template.count).to eq(1)
  end

  it 'cancels a website wait when the conversation is resolved' do
    message = incoming_for(website)
    message.conversation.update!(status: :resolved)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    expect(message.conversation.messages.template).to be_empty
  end

  it 'records a failed native LINE push without treating it as a human reply' do
    message = incoming_for(line)
    travel 5.minutes
    Umi::CustomerAcknowledgementJob.new.perform(message.id, new_generation, 'day')
    acknowledgement = message.conversation.messages.template.sole
    client = double
    allow(Line::Bot::Client).to receive(:new).and_return(client)
    allow(client).to receive(:push_message).and_return(OpenStruct.new(code: '400', body: '{"message":"blocked"}'))
    SendReplyJob.perform_now(acknowledgement.id)
    expect(acknowledgement.reload.status).to eq('failed')
    expect(acknowledgement.external_error).to eq('blocked')
    expect(message.conversation.reload.first_reply_created_at).to be_nil
  end
end
