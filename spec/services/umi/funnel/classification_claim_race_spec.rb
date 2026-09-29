# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Classification evidence application' do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false

  it 'keeps native deletion from passing the final context check before classification commits' do # rubocop:disable RSpec/ExampleLength
    account = create(:account)
    conversation = create(:conversation, account: account)
    ready = Queue.new
    release = Queue.new
    classifier = deleting = nil
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s,
                      UMI_FUNNEL_CLASSIFIER_AUTO_STARTED_AT: 1.day.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_MODEL: 'gpt-6-sol', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '500000',
                      UMI_FUNNEL_CLASSIFIER_API_BASE: 'https://proxy.example.test/v1' do
      message = create(:message, :incoming, conversation: conversation, account: account,
                                            content: 'Can I reserve this dress for fitting?', created_at: 1.minute.ago)
      Umi::Funnel::EventRecorder.capture_message(message)
      decision = { 'status' => 'qualified', 'topics' => [], 'roles' => [], 'reason' => 'Requested a fitting',
                   'evidence_message_ids' => [message.id] }
      allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(instance_double(Umi::Funnel::ClassificationClient, classify: decision))
      service = Umi::Funnel::ConversationClassifier.new(conversation)
      allow(service).to receive(:apply!).and_wrap_original do |original, *arguments|
        ready << true
        release.pop
        original.call(*arguments)
      end
      with_modified_env UMI_FUNNEL_CLASSIFIER_ACCEPTED_CONFIGURATION: Umi::Funnel::ClassificationClient.configuration_digest do
        classifier = Thread.new { ActiveRecord::Base.connection_pool.with_connection { service.perform } }
        Timeout.timeout(10) { ready.pop }
        deleting_pid = Queue.new
        deleting = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            deleting_pid << connection.select_value('SELECT pg_backend_pid()')
            Message.find(message.id).update!(content: 'This message was deleted', content_attributes: { deleted: true })
          end
        end
        pid = Timeout.timeout(10) { deleting_pid.pop }
        waiting = Timeout.timeout(10) do
          loop do
            blocked = ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{pid.to_i}")
            break true if blocked
            break false unless deleting.alive?

            sleep 0.01
          end
        end
        expect(waiting).to be(true), 'Native deletion committed after the last context check, before classification applied'
        release << true
        Timeout.timeout(10) { classifier.value }
        Timeout.timeout(10) { deleting.value }
        expect(Umi::ConversationEvent.where(account_id: account.id, event_type: 'classification_evaluated').sole.payload['outcome']).to eq('applied')
        expect(message.reload.content_attributes['deleted']).to be(true)
      end
    end
  ensure
    release << true if release
    classifier&.join(10)
    deleting&.join(10)
    if account
      Umi::ConversationEvent.where(account_id: account.id).destroy_all
      account.custom_attribute_definitions.destroy_all
      perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
        account.conversations.destroy_all
        account.contacts.destroy_all
        account.destroy!
      end
    end
  end
end
