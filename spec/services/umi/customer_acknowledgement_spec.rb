# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::CustomerAcknowledgement' do
  let(:account) { create(:account) }
  let(:job) { Umi::CustomerAcknowledgementJob.new }
  let(:generation) { settings.value.fetch('started_at') }
  let(:incoming) { create(:message, conversation: conversation, message_type: :incoming, content: 'Is size M available?') }
  let(:inbox) do
    create(:inbox, account: account, channel: create(:channel_facebook_page, account: account),
                   working_hours_enabled: true, timezone: 'Asia/Bangkok')
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent) { create(:user, account: account) }
  let(:opened_at) { Time.iso8601('2026-10-17T03:00:00Z') }
  let(:settings) do
    InstallationConfig.create!(name: 'UMI_CUSTOMER_ACKNOWLEDGEMENTS',
                               value: { 'inbox_ids' => [inbox.id], 'started_at' => (opened_at - 1.hour).iso8601 })
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    travel_to opened_at
    settings
    inbox.working_hours.each do |hours|
      hours.update!(closed_all_day: false, open_hour: 9, open_minutes: 0, close_hour: 21, close_minutes: 0)
    end
    clear_enqueued_jobs
  end

  it 'schedules the missing five-minute acknowledgement when a customer is left waiting' do
    create(:message, conversation: conversation, message_type: :incoming, content: 'Does this dress come in blue?')
    jobs = enqueued_jobs.select { |job| job[:job].name == 'Umi::CustomerAcknowledgementJob' }
    expect(jobs.size).to eq(1)
    expect(jobs.first[:at]).to eq((opened_at + 5.minutes).to_f)
  end

  it 'acknowledges once without claiming a human response or clearing the operator wait' do
    incoming
    waiting_since = conversation.reload.waiting_since
    travel 5.minutes
    2.times { job.perform(incoming.id, generation, 'day') }
    expect(conversation.messages.template.count).to eq(1)
    acknowledgement = conversation.messages.template.sole
    expect(acknowledgement.content).to eq(Umi::CustomerAcknowledgement::DAY_COPY)
    expect(acknowledgement.send(:human_response?)).to be(false)
    expect(acknowledgement.send(:bot_response?)).to be(false)
    expect(conversation.reload.waiting_since).to eq(waiting_since)
    expect(conversation.first_reply_created_at).to be_nil
  end

  it 'keeps the first message clock when the customer adds another question' do
    incoming
    travel 2.minutes
    second = create(:message, conversation: conversation, message_type: :incoming, content: 'And in blue?')
    travel 3.minutes
    job.perform(incoming.id, generation, 'day')
    travel 2.minutes
    job.perform(second.id, generation, 'day')
    expect(conversation.messages.template.count).to eq(1)
  end

  it 'waits the full five minutes' do
    incoming
    travel 299.seconds
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
  end

  it 'cancels after Mai answers and does not let an old job acknowledge a new customer burst early' do
    incoming
    travel 2.minutes
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, content: 'Yes, M is available.')
    travel 1.minute
    second = create(:message, conversation: conversation, message_type: :incoming, content: 'How long is delivery?')
    travel 2.minutes
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
    travel 3.minutes
    job.perform(second.id, generation, 'day')
    expect(conversation.messages.template.count).to eq(1)
  end

  it 'does not mistake a private note, bot reply or failed human send for an answer' do
    incoming
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, private: true, content: 'Checking stock')
    create(:message, conversation: conversation, message_type: :outgoing, sender: create(:agent_bot), content: 'Received')
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: :failed, content: 'Available')
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template.count).to eq(1)
  end

  %w[resolved snoozed].each do |status|
    it "cancels permanently when #{status}, even if manually reopened before the job runs" do
      incoming
      travel 1.minute
      conversation.reload.update!(status: status)
      conversation.update!(status: :open)
      travel 4.minutes
      job.perform(incoming.id, generation, 'day')
      expect(conversation.messages.template).to be_empty
      second = create(:message, conversation: conversation, message_type: :incoming, content: 'One more question')
      travel 5.minutes
      job.perform(second.id, generation, 'day')
      expect(conversation.messages.template.count).to eq(1)
    end
  end

  it 'sends an immediate night reply, without another apology the next morning' do
    travel_to opened_at.change(hour: 15)
    incoming
    job.perform(incoming.id, generation, 'night')
    expect(conversation.messages.template.sole.content).to eq(Umi::CustomerAcknowledgement::NIGHT_COPY)
    travel 19.hours
    second = create(:message, conversation: conversation, message_type: :incoming, content: 'Any update?')
    travel 5.minutes
    job.perform(second.id, generation, 'day')
    expect(conversation.messages.template.count).to eq(1)
  end

  it 'does not repeat a day acknowledgement at night, but can answer a new burst after a human reply' do
    incoming
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    travel_to opened_at.change(hour: 15)
    second = create(:message, conversation: conversation, message_type: :incoming, content: 'Still waiting')
    job.perform(second.id, generation, 'night')
    expect(conversation.messages.template.count).to eq(1)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, content: 'M is available.')
    travel 6.minutes
    third = create(:message, conversation: conversation, message_type: :incoming, content: 'How long is delivery?')
    job.perform(third.id, generation, 'night')
    expect(conversation.messages.template.count).to eq(2)
  end

  it 'does not interrupt a human conversation just after closing' do
    travel_to opened_at.change(hour: 13, min: 59)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent)
    travel 2.minutes
    incoming
    job.perform(incoming.id, generation, 'night')
    expect(conversation.messages.template).to be_empty
  end

  it 'does not deliver the night wording after the office has opened' do
    travel_to opened_at.change(hour: 1, min: 59, sec: 59)
    incoming
    travel 3.seconds
    job.perform(incoming.id, generation, 'night')
    expect(conversation.messages.template).to be_empty
  end

  it 'does not deliver a daytime promise after closing at exactly 21:00' do
    travel_to opened_at.change(hour: 13, min: 55)
    incoming
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
  end

  it 'does not repeat an acknowledgement after its first incoming message is deleted' do
    incoming
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    incoming.update!(content_attributes: { deleted: true })
    second = create(:message, conversation: conversation, message_type: :incoming, content: 'Still there?')
    travel 5.minutes
    job.perform(second.id, generation, 'day')
    expect(conversation.messages.template.count).to eq(1)
  end

  it 'discards work from a previous activation or outside the standard messaging window' do
    incoming
    travel 5.minutes
    job.perform(incoming.id, (opened_at - 2.hours).iso8601, 'day')
    expect(conversation.messages.template).to be_empty
    travel 24.hours
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
  end

  it 'cancels when the inbox is disabled' do
    incoming
    settings.update!(value: { 'inbox_ids' => [], 'started_at' => generation })
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
  end

  it 'does not schedule recovered, deleted or pure story event messages' do
    [{ umi_recovered: true }, { deleted: true }, { image_type: 'story_mention' }, { image_type: 'ig_story' }].each do |attributes|
      create(:message, conversation: conversation, message_type: :incoming, content: 'Mentioned you in their story',
                       content_attributes: attributes)
    end
    expect(enqueued_jobs.select { |item| item[:job].name == 'Umi::CustomerAcknowledgementJob' }).to be_empty
  end

  it 'checks current spam classification and deletion again before sending' do
    incoming
    conversation.add_labels(['spam'])
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
    conversation.update_labels([])
    incoming.update!(content_attributes: { deleted: true })
    job.perform(incoming.id, generation, 'day')
    expect(conversation.messages.template).to be_empty
  end

  it 'fails visibly when native away messaging would duplicate the acknowledgement' do
    inbox.update!(out_of_office_message: 'Away')
    expect { incoming }.to raise_error(ArgumentError, /native auto-replies disabled/)
  end

  it 'refuses automatic delivery with the human-agent tag enabled' do
    incoming
    allow(GlobalConfigService).to receive(:load).with('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT', nil).and_return(true)
    travel 5.minutes
    expect { job.perform(incoming.id, generation, 'day') }.to raise_error(ArgumentError, /HUMAN_AGENT/)
    expect(conversation.messages.template).to be_empty
  end

  it 'does not interrupt a recent human reply when a resolved conversation receives a new night message' do
    travel_to opened_at.change(hour: 14)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent)
    travel 1.minute
    conversation.reload.update!(status: :resolved)
    travel 1.minute
    incoming
    expect(conversation.reload).to be_open
    job.perform(incoming.id, generation, 'night')
    expect(conversation.messages.template).to be_empty
  end

  %w[image audio].each do |file_type|
    it "acknowledges a customer #{file_type} without a text caption" do
      message = build(:message, conversation: conversation, message_type: :incoming, content: nil)
      attachment = message.attachments.build(file_type: file_type, account: account)
      fixture = file_type == 'audio' ? 'sample.mp3' : 'avatar.png'
      attachment.file.attach(io: Rails.root.join('spec/assets', fixture).open, filename: fixture)
      message.save!
      travel 5.minutes
      job.perform(message.id, generation, 'day')
      expect(conversation.messages.template.count).to eq(1)
    end
  end

  it 'acknowledges a real question replying to a story, while keeping pure mentions excluded' do
    message = build(:message, conversation: conversation, message_type: :incoming, content: 'Is this available in M?',
                              content_attributes: { image_type: 'ig_story_reply' })
    message.attachments.build(file_type: 'ig_story', account: account, external_url: 'https://example.com/story')
    message.save!
    travel 5.minutes
    job.perform(message.id, generation, 'day')
    expect(conversation.messages.template.count).to eq(1)
  end

  it 'delivers the Facebook acknowledgement as a normal response and ignores its own app echo' do
    incoming
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    acknowledgement = conversation.messages.template.sole
    allow(Facebook::Messenger::Bot).to receive(:deliver).and_return({ message_id: 'ack-fb-123' }.to_json)
    Facebook::SendOnFacebookService.new(message: acknowledgement).perform
    expect(Facebook::Messenger::Bot).to have_received(:deliver).with(
      hash_including(message: { text: Umi::CustomerAcknowledgement::DAY_COPY }, messaging_type: 'RESPONSE'),
      page_id: inbox.channel.page_id
    )
    expect(acknowledgement.reload.source_id).to eq('ack-fb-123')
    allow(GlobalConfigService).to receive(:load).with('FB_APP_ID', '').and_return('12345')
    response = Integrations::Facebook::MessageParser.new({ messaging: {
      sender: { id: inbox.channel.page_id }, recipient: { id: conversation.contact_inbox.source_id },
      message: { mid: 'ack-fb-123', app_id: 12_345, is_echo: true, text: acknowledgement.content }
    } }.to_json)
    expect { Integrations::Facebook::MessageCreator.new(response).perform }.not_to change(Message, :count)
    expect(conversation.reload.first_reply_created_at).to be_nil
    expect(conversation.waiting_since).to be_present
  end

  it 'deduplicates the normal Instagram send-response then echo sequence without claiming a human reply' do
    incoming
    travel 5.minutes
    job.perform(incoming.id, generation, 'day')
    acknowledgement = conversation.messages.template.sole
    allow(Facebook::Messenger::Configuration::AppSecretProofCalculator).to receive(:call).and_return(nil)
    request = stub_request(:post, 'https://graph.facebook.com/v21.0/me/messages')
              .with(query: { access_token: inbox.channel.page_access_token })
              .to_return(status: 200, body: { message_id: 'ack-ig-123' }.to_json, headers: { 'Content-Type' => 'application/json' })
    Instagram::Messenger::SendOnInstagramService.new(message: acknowledgement).perform
    expect(request).to have_been_requested.once
    expect(acknowledgement.reload.source_id).to eq('ack-ig-123')
    messaging = { sender: { id: inbox.channel.page_id }, recipient: { id: conversation.contact_inbox.source_id },
                  message: { mid: 'ack-ig-123', is_echo: true, text: acknowledgement.content } }
    expect do
      Messages::Instagram::Messenger::MessageBuilder.new(messaging, inbox, outgoing_echo: true).perform
    end.not_to change(Message, :count)
    expect(conversation.reload.first_reply_created_at).to be_nil
    expect(conversation.waiting_since).to be_present
  end
end
