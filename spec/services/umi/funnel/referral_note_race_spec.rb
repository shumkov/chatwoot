# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ad referral note source locks' do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false

  # These examples expose both PostgreSQL sessions and their write boundary.
  # rubocop:disable RSpec/ExampleLength
  %w[before_write during_write].each do |timing|
    it "serializes native message deletion #{timing} against the ad note" do
      release = worker = deleting = nil
      original_account_ids = Account.pluck(:id)
      account = create(:account)
      stub_request(:post, /graph\.facebook\.com/)
      stub_request(:delete, /graph\.facebook\.com/)
      channel = create(:channel_facebook_page, account: account)
      conversation = create(:conversation, account: account, inbox: channel.inbox)
      source = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming,
                                content: 'Tapped option', content_attributes: { referral: { source: 'ADS', ad_id: '111' } })
      client = instance_double(Umi::Meta::AdWelcomeMessageService)
      allow(Umi::Meta::AdWelcomeMessageService).to receive(:new).and_return(client)
      allow(Umi::Meta::AdContextNotePresenter).to receive(:new).and_return(instance_double(Umi::Meta::AdContextNotePresenter, body: 'Ad details'))
      prepared = Queue.new
      release = Queue.new
      allow(client).to receive(:fetch) do
        if timing == 'before_write'
          prepared << true
          release.pop
        end
        {}
      end
      calls = 0
      allow(Umi::FbigAdAttribution).to receive(:valid_source?).and_wrap_original do |method, *args|
        result = method.call(*args)
        calls += 1
        if timing == 'during_write' && calls == 2
          prepared << true
          release.pop
        end
        result
      end
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
        end
      end
      Timeout.timeout(10) { prepared.pop }
      if timing == 'before_write'
        source.update!(content: 'Deleted', content_attributes: { deleted: true })
      else
        deleting_pid = Queue.new
        deleting = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            deleting_pid << connection.select_value('SELECT pg_backend_pid()')
            Message.find(source.id).update!(content: 'Deleted', content_attributes: { deleted: true })
          end
        end
        pid = Timeout.timeout(10) { deleting_pid.pop }
        Timeout.timeout(10) do
          loop do
            break if ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{pid.to_i}")

            sleep 0.01
          end
        end
      end
      release << true
      Timeout.timeout(10) { worker.value }
      Timeout.timeout(10) { deleting.value } if deleting
      notes = conversation.messages.select { |message| message.content_attributes['umi_ad_context'] }
      expect(notes.length).to eq(timing == 'during_write' ? 1 : 0)
      expect(source.reload.content_attributes['deleted']).to be(true)
    ensure
      release << true if release
      worker&.join(10)
      deleting&.join(10)
      Account.where.not(id: original_account_ids).find_each do |created_account|
        Umi::ConversationEvent.where(account_id: created_account.id).destroy_all
        perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
          created_account.conversations.destroy_all
          created_account.contacts.destroy_all
          created_account.destroy!
        end
      end
    end
  end
  # rubocop:enable RSpec/ExampleLength
end
