# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer projection lock order', type: :model do
  self.use_transactional_tests = false

  # rubocop:disable RSpec/ExampleLength
  { 'resolved' => ['vip'], 'open' => [], 'topic' => ['support-refund'] }.each do |operation, expected_labels|
    it "preserves observed revisions and labels when #{operation} races a contact update" do
      closer = nil
      writer = nil
      account = create(:account)
      contact = create(:contact, account: account)
      conversation = create(:conversation, account: account, contact: contact)
      with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
        Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'yes' })
        Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
        conversation.reload.resolved! if operation == 'open'
        revision = contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'revision')
        locked = Queue.new
        mutated = Queue.new
        errors = Queue.new
        closer = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            current = Conversation.find(conversation.id)
            current.with_lock do
              locked << true
              mutated.pop
              if operation == 'topic'
                current.update_labels(%w[vip support-refund])
              else
                current.update!(status: operation)
              end
            end
          end
        rescue StandardError => e
          errors << e
        end
        writer = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            locked.pop
            current_contact = Contact.find(contact.id)
            current_contact.with_lock do
              Umi::Funnel::CustomerMutation.new(current_contact, source: 'system').perform(roles: { umi_vip: 'no' })
              mutated << true
              Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
            end
          end
        rescue StandardError => e
          errors << e
        end
        expect(closer.join(10)).to eq(closer)
        expect(writer.join(10)).to eq(writer)
        raise errors.pop unless errors.empty?

        expected_revision = operation == 'resolved' ? revision : revision + 1
        expect(conversation.reload.label_list).to eq(expected_labels)
        expect(conversation.additional_attributes.dig('umi_customer_projection', 'revision')).to eq(expected_revision)
        expect(contact.reload.custom_attributes['umi_vip']).to eq('no')
      end
    ensure
      closer&.kill if closer&.alive?
      writer&.kill if writer&.alive?
      conversation&.destroy!
      contact&.destroy!
      account&.destroy!
    end
  end
  # rubocop:enable RSpec/ExampleLength
end
