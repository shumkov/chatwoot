# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::CustomerAcknowledgement do
  self.use_transactional_tests = false

  # These examples commit their rows so two workers can see them, so they create records in the example's account and
  # remove them here, together with the agent. The account's associations and the agent's token are destroyed
  # asynchronously and a contact's destroy callbacks still need its account, so conversations and contacts go first
  # and the jobs run here; otherwise the rows stay behind for whichever spec runs next.
  def destroy_committed(account, users: [])
    return unless account

    allow(Facebook::Messenger::Subscriptions).to receive(:unsubscribe).and_return(true)
    perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
      account.conversations.destroy_all
      account.contacts.destroy_all
      account.destroy!
      users.compact.each(&:destroy!)
    end
  end

  it 'creates one acknowledgement when two workers check the same unanswered conversation' do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    travel_to Time.iso8601('2026-10-17T03:00:00Z')
    account = create(:account)
    inbox = create(:inbox, account: account, channel: create(:channel_facebook_page, account: account, inbox: nil),
                           working_hours_enabled: true, timezone: 'Asia/Bangkok')
    inbox.working_hours.each do |hours|
      hours.update!(closed_all_day: false, open_hour: 9, open_minutes: 0, close_hour: 21, close_minutes: 0)
    end
    generation = 1.hour.ago.iso8601
    settings = InstallationConfig.create!(name: 'UMI_CUSTOMER_ACKNOWLEDGEMENTS', value: { 'inbox_ids' => [inbox.id], 'started_at' => generation })
    conversation = create(:conversation, account: account, inbox: inbox)
    incoming = create(:message, account: account, conversation: conversation, message_type: :incoming, content: 'Do you have M?')
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
    destroy_committed(account)
  end

  it 'creates no acknowledgement when two workers check a thanks right after a reply' do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    travel_to Time.iso8601('2026-10-17T03:00:00Z')
    account = create(:account)
    inbox = create(:inbox, account: account, channel: create(:channel_facebook_page, account: account, inbox: nil),
                           working_hours_enabled: true, timezone: 'Asia/Bangkok')
    inbox.working_hours.each do |hours|
      hours.update!(closed_all_day: false, open_hour: 9, open_minutes: 0, close_hour: 21, close_minutes: 0)
    end
    generation = 1.hour.ago.iso8601
    settings = InstallationConfig.create!(name: 'UMI_CUSTOMER_ACKNOWLEDGEMENTS', value: { 'inbox_ids' => [inbox.id], 'started_at' => generation })
    conversation = create(:conversation, account: account, inbox: inbox)
    agent = create(:user, account: account)
    create(:message, account: account, conversation: conversation, message_type: :outgoing, sender: agent, content: 'M is in stock.')
    travel 1.minute
    thanks = create(:message, account: account, conversation: conversation, message_type: :incoming, content: 'Thank you!')
    travel 5.minutes
    ready = Queue.new
    start = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          start.pop
          Umi::CustomerAcknowledgementJob.new.perform(thanks.id, generation, 'day')
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    workers.each(&:value)
    expect(conversation.messages.template.count).to eq(0)
  ensure
    workers&.each(&:join)
    settings&.destroy!
    destroy_committed(account, users: [agent])
  end
end
