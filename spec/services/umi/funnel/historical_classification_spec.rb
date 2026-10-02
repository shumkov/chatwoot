# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/MultipleDescribes, RSpec/ExampleLength, RSpec/MultipleExpectations

RSpec.describe Umi::Funnel::HistoricalClassification do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, custom_attributes: { 'umi_funnel_stage' => 'repeat', 'umi_vip' => 'yes' }) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:actor) { create(:user, account: account) }
  let!(:message) do
    create(:message, conversation: conversation, account: account, message_type: :incoming,
                     content: 'Please reserve the black dress', created_at: 1.month.ago)
  end
  let(:as_of) { 1.hour.ago }
  let(:decision) do
    { 'status' => 'qualified', 'reason' => 'Customer requested a reservation', 'evidence_message_ids' => [message.id],
      'topics' => [{ 'label' => 'intent-ready-to-order', 'evidence_message_ids' => [message.id] }] }
  end
  let(:expected) { described_class.snapshot(conversation.reload) }
  let(:service) do
    described_class.new(conversation: conversation, actor: actor, run_id: 'archive-example', as_of: as_of,
                        expected: expected, decision: decision)
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s do
      example.run
    end
  end

  it 'previews without writes and labels a resolved archive without reopening or advertising a new lead' do
    conversation.resolved!
    conversation.update!(label_list: conversation.label_list | ['ordinary'])
    expected
    expect { service.preview }.not_to change(Umi::ConversationEvent, :count)
    expect(service.preview[:status]).to eq('eligible')
    before = conversation.messages.count
    event = service.perform
    expect(event.provenance).to eq('historical')
    expect(event.payload).to include('mode' => 'historical', 'outcome' => 'applied')
    expect(event.payload).not_to have_key('input_message_id')
    expect(conversation.reload).to be_resolved
    expect(conversation.label_list).to match_array(%w[ordinary repeat vip lead-qualified intent-ready-to-order])
    expect(conversation.messages.count).to eq(before + 1)
    expect(conversation.messages.last).to have_attributes(private: true, sender: nil)
    expect(conversation.messages.last.content).to include('Historical classification')
    expect(Umi::ConversionDelivery.count).to eq(0)
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    expect(service.perform.id).to eq(event.id)
    expect(conversation.messages.count).to eq(before + 1)
  end

  it 'rejects a changed decision under an already applied run instead of silently accepting it' do
    expected
    service.perform
    decision['status'] = 'not_sales'
    expect { service.perform }.to raise_error(ArgumentError, /different decision/)
  end

  it 'holds new or edited customer evidence without applying a stale interpretation' do
    expected
    message.update!(content: 'Sorry, wrong shop')
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
    expect { service.perform }.to raise_error(ArgumentError, /review_inputs_changed/)
    expect(Umi::ConversationEvent.where(provenance: 'historical', event_type: 'classification_evaluated')).to be_empty
  end

  it 'holds edited private staff guidance but ignores new generated customer-summary notes' do
    guidance = create(:message, conversation: conversation, account: account, private: true, message_type: :outgoing,
                                sender: actor, content: 'Customer cancelled the request', created_at: 2.hours.ago)
    expected
    create(:message, conversation: conversation, account: account, private: true, message_type: :outgoing,
                     content: 'Customer context refreshed', content_attributes: { umi_customer_summary: { contact_id: contact.id } })
    expect(service.preview[:status]).to eq('eligible')
    guidance.update!(content: 'Correction: another customer cancelled')
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds a reviewed reply whose delivery status changes before application' do
    reply = create(:message, conversation: conversation, account: account, message_type: :outgoing,
                             sender: actor, content: 'Your dress is reserved', status: :sent, created_at: 2.hours.ago)
    expected
    reply.update!(status: :failed)

    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
    expect { service.perform }.to raise_error(ArgumentError, /review_inputs_changed/)
    expect(Umi::ConversationEvent.where(provenance: 'historical', event_type: 'classification_evaluated')).to be_empty
  end

  it 'holds a reviewed reply whose campaign provenance changes before application' do
    reply = create(:message, conversation: conversation, account: account, message_type: :outgoing,
                             sender: actor, content: 'Your dress is reserved', created_at: 2.hours.ago)
    expected
    reply.update!(additional_attributes: reply.additional_attributes.merge('campaign_id' => 123))

    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
    expect { service.perform }.to raise_error(ArgumentError, /review_inputs_changed/)
    expect(Umi::ConversationEvent.where(provenance: 'historical', event_type: 'classification_evaluated')).to be_empty
  end

  it 'holds a changed customer identity despite an unchanged conversation contact ID' do
    expected
    contact.update!(additional_attributes: { shopify_customer_id: '999' })
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'preserves a manual correction and its topics' do
    expected
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'not_sales',
                                            reason: 'This is a collaboration', evidence_message_ids: [message.id]).perform
    expect(service.preview[:status]).to eq('held')
    expect { service.perform }.to raise_error(ArgumentError)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('not_sales')
  end

  it 'rejects evidence from another conversation and an unsupported label' do
    other = create(:message, account: account)
    decision['evidence_message_ids'] = [other.id]
    expect { service.perform }.to raise_error(ArgumentError, /evidence/)
    decision['evidence_message_ids'] = [message.id]
    decision['topics'][0]['label'] = 'legacy-topic'
    expect { service.perform }.to raise_error(ArgumentError, /topic/)
  end

  it 'records uncertain without turning it into a qualified lead' do
    decision.merge!('status' => 'uncertain', 'evidence_message_ids' => [])
    expect(service.preview).to include(sales_status: nil, topics_added: [])
    event = service.perform
    expect(event.payload.dig('decision', 'status')).to eq('uncertain')
    expect(conversation.reload.label_list).not_to include('intent-ready-to-order')
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(Umi::ConversionDelivery.count).to eq(0)
  end

  it 'rolls back classification, labels and receipt when the explanatory private note cannot be stored' do
    expected
    before = conversation.label_list.sort
    allow(Umi::Funnel::CustomerProjection).to receive(:write_note!).and_raise('note storage unavailable')
    expect { service.perform }.to raise_error('note storage unavailable')
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(conversation.label_list.sort).to eq(before)
    expect(Umi::ConversationEvent.where(provenance: 'historical', event_type: 'classification_evaluated')).to be_empty
  end

  it 'holds a new public message or deletion after review' do
    expected
    added = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'I changed my mind')
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
    added.destroy!
    message.update!(content_attributes: { deleted: true })
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds deleted private guidance and changed attachment metadata' do
    guidance = create(:message, :with_attachment, conversation: conversation, account: account, private: true,
                                                  message_type: :outgoing, sender: actor, created_at: 2.hours.ago)
    expected
    guidance.attachments.first.update!(file_type: 'file')
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
    guidance.destroy!
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds redaction and reassignment rather than applying the former customer review' do
    expected
    contact.update!(additional_attributes: { umi_profile_redacted: true })
    expect(service.preview).to include(status: 'held', reason: 'contact_redacted')
    replacement = create(:contact, account: account)
    conversation.update!(contact: replacement)
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds semantic customer changes but ignores unrelated synchronization timestamps' do
    expected
    contact.update!(additional_attributes: { umi_klaviyo_sync: { observed_at: Time.current.iso8601 } })
    expect(service.preview[:status]).to eq('eligible')
    contact.update!(custom_attributes: contact.custom_attributes.merge('umi_funnel_stage' => 'non_buyer'))
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds newly linked commerce even when the sales status did not change' do
    expected
    Umi::ShopifyOrderAttribution.create!(account: account, conversation_id: conversation.id, contact_id: contact.id,
                                         shop_domain: 'example.myshopify.com', shopify_order_id: '1001', source: 'operator',
                                         attribution_state: 'verified')
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds semantic draft changes while ignoring refresh timestamps' do
    draft = Umi::ShopifyDraftLink.create!(account: account, conversation_id: conversation.id, contact_id: contact.id,
                                          shop_domain: 'example.myshopify.com', shopify_draft_id: '2001')
    expected
    draft.update!(last_checked_at: Time.current)
    expect(service.preview[:status]).to eq('eligible')
    draft.update!(status: 'resolved', shopify_order_id: '1001')
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds semantic financial changes while ignoring reconciliation timestamps' do
    link = Umi::ShopifyOrderAttribution.create!(account: account, conversation_id: conversation.id, contact_id: contact.id,
                                                shop_domain: 'example.myshopify.com', shopify_order_id: '1001', source: 'operator',
                                                attribution_state: 'verified')
    state = Umi::ShopifyOrderFinancialState.create!(account: account, shop_domain: link.shop_domain, shopify_order_id: link.shopify_order_id,
                                                    reconciliation_requested_at: 1.hour.ago,
                                                    snapshot: { classification: 'refunded', refunded: '100.00' })
    expected
    state.update!(reconciled_at: Time.current)
    expect(service.preview[:status]).to eq('eligible')
    state.update!(snapshot: { classification: 'refunded', refunded: '200.00' })
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'holds changed paid event ownership even with unchanged financial facts' do
    paid = Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, conversation_id: nil,
                                          event_type: 'order_paid', provenance: 'shopify', occurrence_key: 'paid-example',
                                          occurred_at: 2.days.ago, observed_at: 2.days.ago, evidence_message_ids: [], payload: {})
    link = Umi::ShopifyOrderAttribution.create!(account: account, conversation_id: conversation.id, contact_id: contact.id,
                                                shop_domain: 'example.myshopify.com', shopify_order_id: '1001', source: 'operator',
                                                attribution_state: 'verified')
    Umi::ShopifyOrderFinancialState.create!(account: account, shop_domain: link.shop_domain, shopify_order_id: link.shopify_order_id,
                                            reconciliation_requested_at: 1.hour.ago, paid_event: paid, snapshot: { classification: 'refunded' })
    expected
    paid.update!(conversation_id: conversation.id)
    expect(service.preview).to include(status: 'held', reason: 'review_inputs_changed')
  end

  it 'records the original recovered evidence time rather than import time' do
    source_time = 2.months.ago.change(usec: 0)
    message.update!(content_attributes: { umi_recovered: true, external_created_at: source_time.iso8601 })
    expect(service.perform.occurred_at).to eq(source_time)
  end

  it 'keeps an unknown recovered evidence time unknown' do
    message.update!(content_attributes: { umi_recovered: true })
    expect(service.perform.occurred_at).to be_nil
  end

  it 'does not use the review time as an evidence time for an uncertain decision without evidence' do
    decision.merge!('status' => 'uncertain', 'evidence_message_ids' => [], 'topics' => [])
    expect(service.perform.occurred_at).to be_nil
  end

  it 'preserves earlier operator topic removals even if current status is unevaluated' do
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, conversation_id: conversation.id,
                                   event_type: 'classification_topics_corrected', provenance: 'operator',
                                   occurrence_key: 'topic-correction', occurred_at: 2.hours.ago, observed_at: 2.hours.ago,
                                   evidence_message_ids: [], payload: { removed: ['intent-ready-to-order'], added: [] })
    expect(service.preview).to include(status: 'held', reason: 'manual_correction')
  end
end

RSpec.describe Umi::Funnel::HistoricalClassification, '#perform' do
  self.use_transactional_tests = false

  it 'blocks native evidence deletion from the final comparison through application' do
    account = create(:account)
    conversation = create(:conversation, account: account)
    actor = create(:user, account: account)
    message = create(:message, conversation: conversation, account: account, message_type: :incoming,
                               content: 'Please reserve a dress', created_at: 1.month.ago)
    ready = Queue.new
    release = Queue.new
    applying = deleting = nil
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s do
      service = described_class.new(conversation: conversation, actor: actor, run_id: 'locking-example',
                                    as_of: 1.hour.ago, expected: described_class.snapshot(conversation),
                                    decision: { status: 'qualified', reason: 'Reservation', topics: [],
                                                evidence_message_ids: [message.id] })
      allow(service).to receive(:apply!).and_wrap_original do |original, *arguments|
        ready << true
        release.pop
        original.call(*arguments)
      end
      applying = Thread.new { ActiveRecord::Base.connection_pool.with_connection { service.perform } }
      Timeout.timeout(10) { ready.pop }
      deleting_pid = Queue.new
      deleting = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          deleting_pid << connection.select_value('SELECT pg_backend_pid()')
          Message.find(message.id).update!(content: 'This message was deleted', content_attributes: { deleted: true })
        end
      end
      pid = Timeout.timeout(10) { deleting_pid.pop }
      blocked = Timeout.timeout(10) do
        loop do
          waiting = ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{pid.to_i}")
          break true if waiting
          break false unless deleting.alive?

          sleep 0.01
        end
      end
      expect(blocked).to be(true), 'Evidence deletion committed between the final comparison and historical application'
      release << true
      expect(Timeout.timeout(10) { applying.value }.payload['outcome']).to eq('applied')
      Timeout.timeout(10) { deleting.value }
      expect(message.reload.content_attributes['deleted']).to be(true)
    end
  ensure
    release << true if release
    applying&.join(10)
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

  it 'keeps archive reminder activity inactive after actual labels and a private summary are applied' do
    ApplicationRecord.transaction(isolation: :repeatable_read) do
      account = create(:account)
      conversation = create(:conversation, account: account, created_at: 1.month.ago)
      actor = create(:user, account: account)
      message = create(:message, conversation: conversation, account: account, message_type: :incoming,
                                 content: 'Please reserve a dress', created_at: 1.month.ago)
      boundary = 2.days.ago
      with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: boundary.utc.iso8601,
                        UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s do
        described_class.new(conversation: conversation, actor: actor, run_id: 'inactive-example',
                            as_of: 1.hour.ago, expected: described_class.snapshot(conversation),
                            decision: { status: 'qualified', reason: 'Reservation', topics: [], evidence_message_ids: [message.id] }).perform
        queue = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: boundary, as_of: Time.current)
        expect(queue.index[:conversations].sole).to include(active_since: nil, waiting: nil)
        expect(queue.show(conversation.reload.display_id)[:conversation]).to include(active_since: nil, waiting: nil)
        expect(conversation.label_list).to include('lead-qualified')
        expect(conversation.messages.where(private: true).count).to eq(1)
      end
      raise ActiveRecord::Rollback
    end
  end
end

# rubocop:enable RSpec/MultipleDescribes, RSpec/ExampleLength, RSpec/MultipleExpectations
