# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Purchase source claim fences' do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false

  # Keep the two sessions and their synchronization visible in each example.
  # rubocop:disable RSpec/ExampleLength
  %w[incoming_deleted command_deleted canceled reconciliation_requested erased incoming_delete_during_claim
     command_delete_during_claim].each do |change|
    it "does not claim evidence changed by #{change} on another connection after preparation" do
      release = worker = deleting = nil
      account = create(:account)
      actor = create(:user, account: account)
      stub_request(:post, 'https://graph.facebook.com/v3.2/me/subscribed_apps').to_return(status: 200, body: '{}')
      stub_request(:delete, %r{https://graph.facebook.com/v3.2/me/subscribed_apps}).to_return(status: 200, body: '{}')
      inbox = create(:inbox, account: account, channel: build(:channel_facebook_page, account: account, page_id: '123'))
      conversation = create(:conversation, account: account, inbox: inbox)
      contact = conversation.contact
      conversation.contact_inbox.update!(source_id: '456')
      create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com')
      link = Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: '1001',
                                                  shopify_order_name: '#1234', source: 'operator', attribution_state: 'verified',
                                                  contact_id: contact.id, conversation_id: conversation.id)
      with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                        UMI_FUNNEL_META_ACCOUNT_ID: account.id.to_s, UMI_FUNNEL_META_PAGE_ID: '123', UMI_FUNNEL_META_DATASET_ID: '789',
                        UMI_FUNNEL_META_ACCESS_TOKEN: 'synthetic', UMI_FUNNEL_META_ENABLED: 'true', UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
        incoming = create(:message, :incoming, account: account, inbox: inbox, conversation: conversation, sender: contact,
                                               source_id: 'mid.123', created_at: 1.hour.ago)
        Umi::Funnel::EventRecorder.capture_message(incoming)
        paid_at = 30.minutes.ago.change(usec: 0)
        event = Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, conversation_id: conversation.id,
                                               event_type: 'order_paid', occurrence_key: 'shopify:umi.myshopify.com:order:1001:paid',
                                               occurred_at: paid_at, observed_at: Time.current, provenance: 'shopify',
                                               payload: { shop_domain: 'umi.myshopify.com', order_id: '1001', value: '4000.0', currency: 'THB' })
        Umi::ShopifyOrderFinancialState.create!(account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: '1001',
                                                reconciliation_requested_at: Time.current, paid_event: event)
        report = instance_double(Umi::Shopify::PaidOrderReport)
        allow(Umi::Shopify::PaidOrderReport).to receive(:new).and_return(report)
        allow(report).to receive(:perform) do
          { shop_domain: 'umi.myshopify.com', observed_finished_at: Time.current.iso8601,
            rows: [{ classification: 'paid', last_payment_at: paid_at.iso8601, currency: 'THB', current_order_value: '4000.0',
                     order_source: { checkout_id: nil, source_name: 'shopify_draft_order' } }] }
        end
        note = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor,
                                message_type: :outgoing, private: true, content: '/paid-in-chat #1234')
        Umi::Funnel::SettlementCommand.register(note, actor)
        Umi::Funnel::SettlementCommand.new(note).perform
        expect(link.reload.settlement_command_message_id).to eq(note.id)
        delivery = event.conversion_deliveries.find_by!(destination: 'meta')
        service = Umi::Funnel::DeliveryService.new(delivery)
        prepared = Queue.new
        release = Queue.new
        during_claim = change.end_with?('during_claim')
        if during_claim
          calls = 0
          allow(service).to receive(:provider_payload).and_wrap_original do |method, *args|
            result = method.call(*args)
            calls += 1
            if calls == 2
              prepared << true
              release.pop
            end
            result
          end
        else
          allow(service).to receive(:prepare).and_wrap_original do |method, **args|
            result = method.call(**args)
            prepared << true
            release.pop
            result
          end
        end
        client = instance_double(Umi::Funnel::MetaClient, send_events: { state: 'accepted' })
        allow(Umi::Funnel::MetaClient).to receive(:new).and_return(client)
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { service.dispatch }
        end
        Timeout.timeout(10) { prepared.pop }
        expect(delivery.reload.payload).to be_present
        if during_claim
          deleting_pid = Queue.new
          target_id = change.start_with?('incoming') ? incoming.id : note.id
          deleting = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              deleting_pid << connection.select_value('SELECT pg_backend_pid()')
              Message.find(target_id).update!(content: 'Deleted', content_attributes: { deleted: true })
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
        case change
        when 'incoming_deleted'
          incoming.update!(content: 'Deleted', content_attributes: { deleted: true })
        when 'command_deleted'
          note.update!(content: 'Deleted', content_attributes: { deleted: true })
        when 'canceled'
          cancel = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor,
                                    message_type: :outgoing, private: true, content: '/paid-in-chat cancel #1234')
          Umi::Funnel::SettlementCommand.register(cancel, actor)
          Umi::Funnel::SettlementCommand.new(cancel).perform
        when 'reconciliation_requested'
          Umi::Shopify::OrderFinancialStateService.request(account_id: account.id, shop_domain: 'umi.myshopify.com', order_id: '1001')
        when 'erased'
          Umi::Shopify::CustomerRedactionService.new(contact).perform
        end
        release << true
        Timeout.timeout(10) { worker.value }
        Timeout.timeout(10) { deleting.value } if deleting
        if during_claim
          expect(delivery.reload).to have_attributes(state: 'accepted', attempt_count: 1)
          expect(client).to have_received(:send_events).once
        else
          expect(delivery.reload.attempt_count).to eq(0)
          expect(delivery.state).not_to eq('sending')
          expect(client).not_to have_received(:send_events)
        end
      end
    ensure
      release << true if release
      worker&.join(10)
      deleting&.join(10)
      if account
        Umi::ConversationEvent.where(account_id: account.id).destroy_all
        Umi::ShopifyOrderFinancialState.where(account_id: account.id).delete_all
        Umi::ShopifyOrderAttribution.where(account_id: account.id).delete_all
        perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
          account.conversations.destroy_all
          account.contacts.destroy_all
          account.destroy!
        end
      end
      actor&.destroy!
    end
  end
  # rubocop:enable RSpec/ExampleLength
end
