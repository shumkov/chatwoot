# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::CustomerAcknowledgement do
  self.use_transactional_tests = false

  it 'creates one acknowledgement when two workers check the same unanswered conversation' do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    travel_to Time.iso8601('2026-10-17T03:00:00Z')
    account = create(:account)
    inbox = create(:inbox, account: account, channel: create(:channel_facebook_page, account: account),
                           working_hours_enabled: true, timezone: 'Asia/Bangkok')
    inbox.working_hours.each do |hours|
      hours.update!(closed_all_day: false, open_hour: 9, open_minutes: 0, close_hour: 21, close_minutes: 0)
    end
    generation = 1.hour.ago.iso8601
    settings = InstallationConfig.create!(name: 'UMI_CUSTOMER_ACKNOWLEDGEMENTS', value: { 'inbox_ids' => [inbox.id], 'started_at' => generation })
    conversation = create(:conversation, account: account, inbox: inbox)
    incoming = create(:message, conversation: conversation, message_type: :incoming, content: 'Do you have M?')
    travel 5.minutes
    ready = Queue.new
    start = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          start.pop
          Umi::CustomerAcknowledgementJob.new.perform(incoming.id, generation, 'day')
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    workers.each(&:value)
    expect(conversation.messages.template.count).to eq(1)
  ensure
    workers&.each(&:join)
    settings&.destroy!
    account&.destroy!
  end
end
