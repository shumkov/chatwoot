# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Instagram concurrent conversation creation', type: :model do
  self.use_transactional_tests = false

  reusable_statuses = %w[open pending snoozed]

  [
    [Messages::Instagram::Messenger::MessageBuilder, :channel_instagram_fb_page],
    [Messages::Instagram::MessageBuilder, :channel_instagram]
  ].each do |builder_class, channel_factory|
    context "with #{builder_class}" do
      let!(:account) { create(:account) }
      let!(:channel) { create(channel_factory, account: account) }
      let!(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false, lock_to_single_conversation: false) }
      let!(:contact) { create(:contact, account: account) }
      let!(:binding) { create(:contact_inbox, contact: contact, inbox: inbox) }
      let(:payload) do
        { sender: { id: binding.source_id }, recipient: { id: 'instagram-account' },
          message: { mid: SecureRandom.uuid, text: 'มีไซส์ให้เลือกหรือไม่?' } }.with_indifferent_access
      end

      before do
        stub_request(:post, /graph\.facebook\.com/)
        stub_request(:delete, /graph\.facebook\.com/)
        stub_request(:get, 'https://example.com/post.jpg').to_return(status: 200, body: 'image', headers: { 'Content-Type' => 'image/jpeg' })
      end

      after do
        perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
          account.conversations.destroy_all
          account.contacts.destroy_all
          account.destroy!
        end
        [Contact, Conversation, Message, Inbox, channel.class].each do |model|
          raise "Leaked #{model} fixtures for account #{account.id}" if model.exists?(account_id: account.id)
        end
      end

      # rubocop:disable RSpec/ExampleLength
      it 'keeps a shared post and a simultaneous ad size question in one conversation' do
        first = nil
        second = nil
        unrelated = nil
        other_contact = create(:contact, account: account)
        other_binding = create(:contact_inbox, contact: other_contact, inbox: inbox)
        ready = Queue.new
        release = Queue.new
        second_started = Queue.new
        errors = Queue.new
        shared = payload.deep_dup
        shared_id = SecureRandom.uuid
        question_id = SecureRandom.uuid
        shared[:message] = { mid: shared_id, attachments: [{ type: 'ig_post', payload: { url: 'https://example.com/post.jpg' } }] }
        question = payload.deep_dup
        question[:message][:mid] = question_id
        question[:message][:referral] = { source: 'ADS', type: 'OPEN_THREAD', ad_id: '123456789' }
        first_builder = builder_class.new(shared, inbox)
        second_builder = builder_class.new(question, inbox)
        [first_builder, second_builder].each { |builder| allow(builder).to receive(:handle_error) { |error| raise error } }
        allow(first_builder).to receive(:process_attachment).and_wrap_original do |original, attachment|
          ready << ActiveRecord::Base.connection.raw_connection.backend_pid
          release.pop
          original.call(attachment)
        end

        first = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { first_builder.perform }
        rescue StandardError => e
          errors << e
          ready << nil
        end
        first_pid = Timeout.timeout(10) { ready.pop }
        raise errors.pop unless errors.empty?

        other_payload = payload.deep_dup
        other_payload[:sender][:id] = other_binding.source_id
        other_builder = builder_class.new(other_payload, inbox)
        allow(other_builder).to receive(:handle_error) { |error| raise error }
        unrelated = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { other_builder.perform }
        rescue StandardError => e
          errors << e
        end
        expect(unrelated.join(10)).to eq(unrelated)
        raise errors.pop unless errors.empty?

        expect(other_contact.conversations.count).to eq(1)

        second = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            second_started << connection.raw_connection.backend_pid
            second_builder.perform
          end
        rescue StandardError => e
          errors << e
        end
        second_pid = Timeout.timeout(10) { second_started.pop }
        Timeout.timeout(10) do
          while second.alive?
            blocked = ActiveRecord::Base.connection.select_value("SELECT #{first_pid} = ANY(pg_blocking_pids(#{second_pid}))")
            break if blocked

            sleep 0.01
          end
        end
        release << true
        expect(first.join(10)).to eq(first)
        expect(second.join(10)).to eq(second)
        raise errors.pop unless errors.empty?

        expect(inbox.messages.where(source_id: [shared_id, question_id]).count).to eq(2)
        expect(contact.conversations.count).to eq(1)
        expect(inbox.messages.find_by!(source_id: question_id).content_attributes['referral']).to eq(
          { 'source' => 'ADS', 'type' => 'OPEN_THREAD', 'ad_id' => '123456789' }
        )
      ensure
        release << true
        [first, second, unrelated].compact.each do |thread|
          thread.kill if thread.alive?
          thread.join
        end
      end
      # rubocop:enable RSpec/ExampleLength

      reusable_statuses.each do |status|
        it "reuses the existing #{status} conversation" do
          conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: binding,
                                               status: status, additional_attributes: { type: 'instagram_direct_message' })
          builder_class.new(payload, inbox).perform

          expect(contact.conversations.count).to eq(1)
          expect(Message.find_by!(source_id: payload[:message][:mid]).conversation_id).to eq(conversation.id)
        end
      end

      if builder_class == Messages::Instagram::Messenger::MessageBuilder
        it 'keeps Instagram messages separate from an existing Facebook conversation' do
          facebook = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: binding)
          builder_class.new(payload, inbox).perform

          message = Message.find_by!(source_id: payload[:message][:mid])
          expect(message.conversation_id).not_to eq(facebook.id)
          expect(message.conversation.additional_attributes['type']).to eq('instagram_direct_message')
        end
      end
    end
  end
end
