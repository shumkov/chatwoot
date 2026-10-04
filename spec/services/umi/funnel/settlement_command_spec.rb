# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::SettlementCommand do # rubocop:disable RSpec/MultipleMemoizedHelpers
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: build(:channel_facebook_page, account: account, page_id: '123')) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:contact) { conversation.contact }
  let!(:hook) { create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com') }
  let!(:link) do
    Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: hook.reference_id, shopify_order_id: '1001', shopify_order_name: '#1234',
                                         source: 'operator', attribution_state: 'verified', contact_id: contact.id, conversation_id: conversation.id)
  end
  let(:paid_at) { 30.minutes.ago.change(usec: 0) }
  let(:incoming) do
    create(:message, :incoming, account: account, inbox: inbox, conversation: conversation, sender: contact, source_id: 'mid.123',
                                created_at: 1.hour.ago)
  end
  let(:note) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                     content: '/paid-in-chat #1234')
  end
  let(:order) do
    { 'id' => 1001, 'created_at' => 1.day.ago.iso8601, 'updated_at' => paid_at.iso8601, 'financial_status' => 'paid', 'test' => false,
      'currency' => 'THB', 'total_price' => '4000.00', 'current_total_price' => '4000.00', 'checkout_id' => nil,
      'source_name' => 'shopify_draft_order' }
  end
  let(:transactions) do
    [{ 'id' => 2001, 'kind' => 'sale', 'status' => 'success', 'currency' => 'THB', 'amount' => '4000.00', 'processed_at' => paid_at.iso8601 }]
  end
  let(:shopify) { instance_double(ShopifyAPI::Clients::Rest::Admin) }
  let(:state) { Umi::ShopifyOrderFinancialState.find_by!(account_id: account.id, shopify_order_id: '1001') }
  let(:delivery) { state.paid_event.conversion_deliveries.find_by!(destination: 'meta') }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_META_ACCOUNT_ID: account.id.to_s, UMI_FUNNEL_META_PAGE_ID: '123', UMI_FUNNEL_META_DATASET_ID: '789',
                      UMI_FUNNEL_META_ACCESS_TOKEN: 'synthetic', UMI_FUNNEL_META_ENABLED: 'true', UMI_FUNNEL_META_PURCHASE_CHANNELS: '' do
      example.run
    end
  end

  prepend_before do
    stub_request(:post, 'https://graph.facebook.com/v3.2/me/subscribed_apps').to_return(status: 200, body: '{}')
  end

  before do
    conversation.contact_inbox.update!(source_id: '456')
    Umi::Funnel::EventRecorder.capture_message(incoming)
    allow(Umi::Shopify::ClientFactory).to receive(:client_for).and_return(shopify)
    allow(shopify).to receive(:get).with(path: 'orders/1001', query: anything) do
      ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'order' => order })
    end
    allow(shopify).to receive(:get).with(path: 'orders/1001/transactions', query: anything) do
      ShopifyAPI::Clients::HttpResponse.new(code: 200, headers: {}, body: { 'transactions' => transactions })
    end
    described_class.register(note, actor)
  end

  it 'records genuine paid settlement once while Purchase remains explicitly disabled' do
    response_id = note.content_attributes.fetch(described_class::KEY).fetch('response_message_id')
    2.times { described_class.new(note).perform }
    expect(link.reload.settlement_command_message_id).to eq(note.id)
    result = note.reload.content_attributes.fetch(described_class::KEY)
    expect(result).to include('status' => 'accepted', 'reason' => 'purchase_channel_disabled')
    response = Message.find(result.fetch('response_message_id'))
    expect(response).to have_attributes(id: response_id, private: true, sender_id: nil)
    expect(response.content_attributes).to include('umi_paid_in_chat_response' => true)
    expect(conversation.messages.where("(content_attributes #>> '{}')::jsonb ->> 'umi_paid_in_chat_response' = 'true'").count).to eq(1)
    expect(state.paid_event.payload).to include('value' => '4000.0', 'order_origin' => 'unknown')
    Umi::Funnel::DeliveryService.new(delivery).prepare
    Umi::Funnel::DeliveryService.new(delivery).dispatch
    expect(delivery.reload).to have_attributes(reason: 'purchase_channel_disabled', attempt_count: 0)
  end

  it 'replaces a pending note deleted by the operator before completion without restoring its content' do
    response_id = note.content_attributes.fetch(described_class::KEY).fetch('response_message_id')
    response = Message.find(response_id)
    response.update!(content: 'This message was deleted', content_attributes: { deleted: true })
    described_class.new(note).perform
    result_id = note.reload.content_attributes.fetch(described_class::KEY).fetch('response_message_id')
    expect(result_id).not_to eq(response_id)
    expect(response.reload.content_attributes).to eq('deleted' => true)
    expect(response.content).to eq('This message was deleted')
    expect(Message.find(result_id)).to have_attributes(private: true, sender_id: nil)
  end

  it 'rechecks an acknowledgement deleted between lookup and its update lock' do
    response_id = note.content_attributes.fetch(described_class::KEY).fetch('response_message_id')
    response = Message.find(response_id)
    data = note.content_attributes.fetch(described_class::KEY).merge('error' => 'invalid_command')
    note.update!(content_attributes: note.content_attributes.merge(described_class::KEY => data))
    allow(note).to receive(:conversation).and_return(conversation)
    allow(conversation.messages).to receive(:find_by).with(id: response_id).and_return(response)
    allow(response).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      Message.find(response_id).update!(content: 'This message was deleted', content_attributes: { deleted: true })
      original.call(*args, &block)
    end
    described_class.new(note).perform
    expect(Message.find(response_id)).to have_attributes(content: 'This message was deleted', content_attributes: { 'deleted' => true })
    expect(note.reload.content_attributes.dig(described_class::KEY, 'response_message_id')).not_to eq(response_id)
  end

  it 'finishes legacy queued commands without an acknowledgement' do
    data = note.content_attributes.fetch(described_class::KEY)
    Message.find(data.fetch('response_message_id')).destroy!
    note.update!(content_attributes: note.content_attributes.merge(described_class::KEY => data.except('response_message_id')))
    described_class.new(note).perform
    expect(note.reload.content_attributes.dig(described_class::KEY, 'status')).to eq('accepted')
    expect(Message.find(note.content_attributes.dig(described_class::KEY, 'response_message_id'))).to have_attributes(private: true)
  end

  it 'erases the queued acknowledgement with its customer before the command runs' do
    ids = [note.id, note.content_attributes.fetch(described_class::KEY).fetch('response_message_id')]
    Umi::Shopify::CustomerRedactionService.new(contact).perform
    expect(Message.where(id: ids)).to be_empty
  end

  it 'uses the original paid occurrence and selected pre-payment message for a Purchase' do
    described_class.new(note).perform
    event_id = state.paid_event_id
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
    end
    expect(delivery.reload.reason).to be_nil
    expect(delivery.payload.fetch('data').sole).to include('event_name' => 'Purchase', 'event_time' => paid_at.to_i,
                                                           'user_data' => { 'page_id' => '123', 'page_scoped_user_id' => '456' },
                                                           'custom_data' => { 'value' => 4000.0, 'currency' => 'THB', 'order_id' => '1001' })
    expect(state.reload.paid_event_id).to eq(event_id)
    expect(state.paid_event.conversion_deliveries.count).to eq(2)
  end

  it 'rejects unpaid confirmation permanently rather than accepting it after a later payment' do
    transactions.clear
    order['financial_status'] = 'pending'
    described_class.new(note).perform
    expect(note.reload.content_attributes.dig(described_class::KEY, 'reason')).to eq('payment_not_verified')
    order['financial_status'] = 'paid'
    described_class.new(note).perform
    expect(link.reload.settlement_command_message_id).to be_nil
  end

  it 'does not synthesize a paid occurrence from first-observed refunded history' do
    order['financial_status'] = 'refunded'
    transactions << transactions.first.merge('id' => 2002, 'kind' => 'refund')
    described_class.new(note).perform
    expect(state.reload.paid_event_id).to be_nil
    expect(note.reload.content_attributes.dig(described_class::KEY, 'status')).to eq('rejected')
  end

  [123, ''].each do |checkout|
    it "rejects checkout #{checkout.inspect} or incomplete source evidence without losing the real payment" do
      checkout == '' ? order.delete('checkout_id') : order['checkout_id'] = checkout
      described_class.new(note).perform
      expect(note.reload.content_attributes.dig(described_class::KEY, 'status')).to eq('rejected')
      expect(state.paid_event).to be_present
      expect(link.reload.settlement_command_message_id).to be_nil
    end
  end

  it 'retains paid value after a refund while taking source eligibility from the current observation' do
    described_class.new(note).perform
    order['financial_status'] = 'partially_refunded'
    order['current_total_price'] = '3000.00'
    transactions << transactions.first.merge('id' => 2002, 'kind' => 'refund', 'amount' => '1000.00')
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
      expect(delivery.reload.payload.dig('data', 0, 'custom_data', 'value')).to eq(4000.0)
      order['checkout_id'] = 456
      Umi::Funnel::DeliveryService.new(delivery).prepare
      expect(delivery.reload.reason).to eq('website_checkout')
    end
  end

  it 'lets cancellation win over a delayed earlier confirmation even during a Shopify outage' do
    cancel = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                              content: '/paid-in-chat cancel #1234')
    described_class.register(cancel, actor)
    allow(shopify).to receive(:get).and_raise(Timeout::Error)
    described_class.new(cancel).perform
    expect(link.reload.settlement_command_message_id).to eq(cancel.id)
    expect(cancel.reload.content_attributes.dig(described_class::KEY, 'reason')).to eq('chat_settlement_canceled')
    described_class.new(note).perform
    expect(note.reload.content_attributes.dig(described_class::KEY, 'status')).to eq('superseded')
    expect(link.reload.settlement_command_message_id).to eq(cancel.id)
  end

  it 'does not revive older confirmation after native deletion of the cancel note' do
    described_class.new(note).perform
    cancel = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                              content: '/paid-in-chat cancel #1234')
    described_class.register(cancel, actor)
    described_class.new(cancel).perform
    cancel.update!(content: 'Deleted', content_attributes: { deleted: true })
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
    end
    expect(delivery.reload.reason).to eq('chat_settlement_unconfirmed')
    expect(link.reload.settlement_command_message_id).to eq(cancel.id)
  end

  it 'advances duplicate confirmation beyond an intervening delayed cancellation' do
    described_class.new(note).perform
    cancel = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                              content: '/paid-in-chat cancel #1234')
    newer = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                             content: note.content)
    [cancel, newer].each { |message| described_class.register(message, actor) }
    described_class.new(newer).perform
    described_class.new(cancel).perform
    expect(link.reload.settlement_command_message_id).to eq(newer.id)
    expect(newer.reload.content_attributes.dig(described_class::KEY,
                                               'evidence_event_id')).to eq(note.reload.content_attributes.dig(described_class::KEY,
                                                                                                              'evidence_event_id'))
    expect(cancel.reload.content_attributes.dig(described_class::KEY, 'status')).to eq('superseded')
  end

  it 'retains attempted provider history when cancellation can no longer recall a send' do
    described_class.new(note).perform
    delivery.update!(state: 'unknown', attempted_at: Time.current, attempt_count: 1, payload: { 'frozen' => true }, destination_key: '123:789')
    cancel = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                              content: '/paid-in-chat cancel #1234')
    described_class.register(cancel, actor)
    described_class.new(cancel).perform
    expect(delivery.reload).to have_attributes(state: 'unknown', payload: { 'frozen' => true }, attempt_count: 1, destination_key: '123:789')
    expect(cancel.reload.content_attributes.dig(described_class::KEY, 'reason')).to eq('already_attempted_cannot_recall')
  end

  it 'never re-creates a deleted private acknowledgment' do
    described_class.new(note).perform
    Message.find(note.reload.content_attributes.dig(described_class::KEY, 'response_message_id')).destroy!
    expect { described_class.new(note).perform }.not_to change(Message, :count)
  end

  it 'holds deleted or metadata-cleared confirmation evidence' do
    described_class.new(note).perform
    note.update!(content_attributes: {})
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
    end
    expect(delivery.reload.reason).to eq('chat_settlement_unconfirmed')
  end

  it 'does not retarget a registered command after its order is linked to a different conversation' do
    other = create(:conversation, account: account, contact: contact)
    link.update!(conversation_id: other.id)
    described_class.new(note).perform
    expect(note.reload.content_attributes.dig(described_class::KEY, 'reason')).to eq('binding_changed')
    expect(link.reload.settlement_command_message_id).to be_nil
  end

  it 'clears successful, rejected and marker-cleared command notes during customer erasure' do
    described_class.new(note).perform
    command_id = note.id
    response_id = note.reload.content_attributes.dig(described_class::KEY, 'response_message_id')
    extra = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor, message_type: :outgoing, private: true,
                             content: '/paid-in-chat #9999')
    described_class.register(extra, actor)
    described_class.new(extra).perform
    note.update!(content_attributes: {})
    Umi::Shopify::CustomerRedactionService.new(contact).perform
    expect(Message.where(id: [command_id, response_id, extra.id])).to be_empty
    expect(link.reload.settlement_command_message_id).to be_nil
    expect(state.reload).to have_attributes(paid_event_id: nil, snapshot: {})
  end

  %w[deleted recovered source_missing post_payment].each do |condition|
    it "records location without exporting #{condition} incoming evidence" do
      case condition
      when 'deleted' then incoming.update!(content_attributes: { deleted: true })
      when 'recovered' then incoming.update!(content_attributes: { umi_recovered: true })
      when 'source_missing' then incoming.update!(source_id: nil)
      when 'post_payment' then incoming.update!(created_at: paid_at + 1.minute)
      end
      described_class.new(note).perform
      expect(link.reload.settlement_command_message_id).to eq(note.id)
      with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
        Umi::Funnel::DeliveryService.new(delivery).prepare
      end
      expect(delivery.reload).to have_attributes(reason: 'purchase_evidence_missing', attempt_count: 0, payload: {})
    end
  end

  it 'holds an otherwise prepared payment when a webhook requests reconciliation before claim' do
    described_class.new(note).perform
    service = Umi::Funnel::DeliveryService.new(delivery)
    passes = 0
    allow(service).to receive(:with_source_lock).and_wrap_original do |method, &block|
      passes += 1
      state.update!(reconciliation_requested_at: Time.current) if passes == 2
      method.call(&block)
    end
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      service.dispatch
    end
    expect(delivery.reload).to have_attributes(reason: 'financial_observation_stale', attempt_count: 0, state: 'pending')
  end

  it 'holds failed financial refresh and permits a later successful read without changing the frozen event' do
    described_class.new(note).perform
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
      payload = delivery.reload.payload.deep_dup
      allow(Umi::Shopify::ClientFactory).to receive(:client_for).and_raise(Timeout::Error)
      Umi::Funnel::DeliveryService.new(delivery).dispatch
      expect(delivery.reload).to have_attributes(reason: 'financial_observation_stale', attempt_count: 0, payload: payload)
      allow(Umi::Shopify::ClientFactory).to receive(:client_for).and_return(shopify)
      Umi::Funnel::DeliveryService.new(delivery).prepare
      expect(delivery.reload).to have_attributes(reason: nil, payload: payload)
    end
  end

  it 'holds a changed destination instead of overwriting a frozen Purchase' do
    described_class.new(note).perform
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
      with_modified_env UMI_FUNNEL_META_DATASET_ID: '999' do
        Umi::Funnel::DeliveryService.new(delivery).dispatch
      end
    end
    expect(delivery.reload).to have_attributes(reason: 'prepared_source_changed', destination_key: '123:789', attempt_count: 0)
  end

  it 'claims once and never replays an uncertain Purchase result' do
    described_class.new(note).perform
    client = instance_double(Umi::Funnel::MetaClient)
    allow(Umi::Funnel::MetaClient).to receive(:new).and_return(client)
    allow(client).to receive(:send_events) do
      expect(delivery.reload).to have_attributes(state: 'sending', attempt_count: 1)
      { state: 'unknown', error: 'Net::ReadTimeout' }
    end
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      2.times { Umi::Funnel::DeliveryService.new(delivery).dispatch }
    end
    expect(client).to have_received(:send_events).once
    expect(delivery.reload).to have_attributes(state: 'unknown', attempt_count: 1)
  end

  it 'provides the ig_account_id required by Instagram CAPI only when that channel is explicitly enabled' do
    inbox.channel.update!(instagram_id: '987')
    conversation.update!(additional_attributes: { type: 'instagram_direct_message' })
    incoming.destroy!
    message = create(:message, :incoming, account: account, inbox: inbox, conversation: conversation, sender: contact,
                                          source_id: 'mid.instagram', created_at: 1.hour.ago)
    Umi::Funnel::EventRecorder.capture_message(message)
    described_class.new(note).perform
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger', UMI_FUNNEL_META_INSTAGRAM_ID: '987' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
      expect(delivery.reload.reason).to eq('purchase_channel_disabled')
    end
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'instagram', UMI_FUNNEL_META_INSTAGRAM_ID: '987' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
    end
    expect(delivery.reload.payload.dig('data', 0, 'user_data')).to eq('ig_account_id' => '987', 'ig_sid' => '456')
  end

  it 'rejects an invalid channel configuration rather than silently enabling Purchase' do
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'all' do
      expect { Umi::Funnel::PurchaseSource.channels }.to raise_error(ArgumentError, /channels/)
    end
  end

  it 'recovers registered unfinished commands without interpreting old notes' do
    old = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor,
                           message_type: :outgoing, private: true, content: '/paid-in-chat #1234')
    clear_enqueued_jobs
    described_class.enqueue_unfinished
    jobs = enqueued_jobs.select { |job| job[:job] == Umi::Funnel::SettlementCommandJob }
    expect(jobs.pluck(:args)).to eq([[note.id]])
    expect(jobs.pluck(:args)).not_to include([old.id])
  end

  it 'requires a successful immediate refresh even when request registration fails before touching the financial row' do
    described_class.new(note).perform
    with_modified_env UMI_FUNNEL_META_PURCHASE_CHANNELS: 'messenger' do
      Umi::Funnel::DeliveryService.new(delivery).prepare
      allow(Umi::Shopify::OrderFinancialStateService).to receive(:request).and_raise(ActiveRecord::RecordNotFound)
      Umi::Funnel::DeliveryService.new(delivery).dispatch
    end
    expect(state.reload.last_error).to be_nil
    expect(delivery.reload).to have_attributes(state: 'pending', reason: 'financial_observation_stale', attempt_count: 0)
  end

  it 'erases rejected commands and their results after their contact disappears without an order link' do
    link.destroy!
    extra = create(:message, account: account, inbox: inbox, conversation: conversation, sender: actor,
                             message_type: :outgoing, private: true, content: '/paid-in-chat #9999')
    described_class.register(extra, actor)
    described_class.new(extra).perform
    response_id = extra.reload.content_attributes.dig(described_class::KEY, 'response_message_id')
    Contact.where(id: contact.id).delete_all
    Umi::Funnel::Privacy.redact_orphans!
    expect(Message.where(id: [extra.id, response_id])).to be_empty
  end
end
