# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Automatic conversation classification' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) do
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Can I reserve this dress for fitting?',
                     created_at: 1.minute.ago)
  end
  let(:decision) do
    { 'status' => 'qualified', 'topics' => [{ 'label' => 'intent-ready-to-order', 'evidence_message_ids' => [message.id] }],
      'roles' => [], 'reason' => 'Requested a fitting reservation',
      'evidence_message_ids' => [message.id] }
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_MODE: 'shadow', UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s,
                      UMI_FUNNEL_CLASSIFIER_AUTO_STARTED_AT: 1.day.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_MODEL: 'gpt-6-sol', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '500000',
                      UMI_FUNNEL_CLASSIFIER_API_BASE: 'https://proxy.example.test/v1' do
      with_modified_env UMI_FUNNEL_CLASSIFIER_ACCEPTED_CONFIGURATION: Umi::Funnel::ClassificationClient.configuration_digest do
        example.run
      end
    end
  end

  it 'records shadow classification without changing status or creating a positive outcome' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)

    Umi::Funnel::ConversationClassifier.new(conversation).perform

    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload).to include('outcome' => 'shadow')
  end

  it 'automatically qualifies new buying evidence once and preserves unrelated labels' do
    Umi::Funnel::EventRecorder.capture_message(message)
    conversation.update!(label_list: ['source-paid-ads'])
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      2.times { Umi::Funnel::ConversationClassifier.new(conversation).perform }
    end

    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('qualified')
    expect(conversation.label_list).to include('source-paid-ads', 'intent-ready-to-order', 'lead-qualified')
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified').count).to eq(1)
    expect(Umi::ConversionDelivery.count).to eq(2)
    expect(client).to have_received(:classify).once
  end

  it 'does not apply a stale answer when a new incoming message has not reached the event recorder yet' do
    Umi::Funnel::EventRecorder.capture_message(message)
    allow(Umi::Funnel::EventRecorder).to receive(:capture_message).and_wrap_original do |original, candidate|
      original.call(candidate) unless candidate.content == 'Sorry, wrong shop'
    end
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Sorry, wrong shop')
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end

    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload).to include('outcome' => 'stale')
  end

  it 'rejects evidence made private while inference was running' do
    Umi::Funnel::EventRecorder.capture_message(message)
    other = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Thank you', created_at: 45.seconds.ago)
    decision['evidence_message_ids'] << other.id
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      message.update!(private: true)
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end

    expect(conversation.reload.label_list).not_to include('intent-ready-to-order')
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
  end

  it 'rejects evidence soft-deleted while inference was running' do
    Umi::Funnel::EventRecorder.capture_message(message)
    other = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Thank you', created_at: 45.seconds.ago)
    decision['evidence_message_ids'] << other.id
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      message.update!(content: 'This message was deleted', deleted: true)
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end

    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(conversation.label_list).not_to include('intent-ready-to-order')
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
  end

  it 'keeps a human correction made during inference and records the losing result' do
    Umi::Funnel::EventRecorder.capture_message(message)
    actor = create(:user, account: account)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'not_sales', actor: actor,
                                              reason: 'This is a collaboration request', evidence_message_ids: [message.id]).perform
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end

    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('not_sales')
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('manual_override')
  end

  it 'does not reuse rejected buying evidence after a later greeting' do
    Umi::Funnel::EventRecorder.capture_message(message)
    actor = create(:user, account: account)
    Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'not_sales', actor: actor,
                                            reason: 'This is not a purchase request', evidence_message_ids: [message.id]).perform
    greeting = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Hi again',
                                created_at: 40.seconds.ago)
    decision['evidence_message_ids'] << greeting.id
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end

    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('not_sales')
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('failed')
  end

  it 'does not replay a shadow result when automatic mode starts' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    Umi::Funnel::ConversationClassifier.new(conversation).perform
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.enqueue
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end

    expect(client).to have_received(:classify).once
    expect(Umi::ConversionDelivery.count).to eq(0)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
  end

  it 'does not turn pre-activation buying evidence into a conversion after a new greeting' do
    Umi::Funnel::EventRecorder.capture_message(message)
    greeting = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Hi again',
                                created_at: 40.seconds.ago)
    decision['evidence_message_ids'] << greeting.id
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_FUNNEL_CLASSIFIER_AUTO_STARTED_AT: 50.seconds.ago.utc.iso8601 do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(Umi::ConversionDelivery.count).to eq(0)
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('failed')
  end

  %w[qualified order_placed purchased].each do |status|
    it "preserves #{status} when a later message asks for a refund" do
      Umi::Funnel::EventRecorder.capture_message(message)
      if status == 'qualified'
        Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: create(:user, account: account), status: status,
                                                reason: 'Requested a reservation', evidence_message_ids: [message.id]).perform
      else
        conversation.project_umi_sales_status!(status)
      end
      refund = create(:message, conversation: conversation, account: account, message_type: :incoming,
                                content: 'How can I return it for a refund?', created_at: 40.seconds.ago)
      Umi::Funnel::EventRecorder.capture_message(refund)
      previous_events = Umi::ConversationEvent.where(event_type: %w[classification_changed conversation_qualified]).pluck(:id)
      previous_deliveries = Umi::ConversionDelivery.pluck(:id)
      decision.merge!('status' => 'not_sales', 'topics' => [{ 'label' => 'support-refund', 'evidence_message_ids' => [refund.id] }],
                      'reason' => 'Refund assistance', 'evidence_message_ids' => [refund.id])
      client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
      allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
      with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
        Umi::Funnel::ConversationClassifier.new(conversation).perform
      end
      expect(conversation.reload.custom_attributes['umi_sales_status']).to eq(status)
      expect(conversation.label_list).to include('support-refund')
      expect(Umi::ConversationEvent.where(event_type: %w[classification_changed conversation_qualified]).pluck(:id)).to eq(previous_events)
      expect(Umi::ConversionDelivery.pluck(:id)).to eq(previous_deliveries)
    end
  end

  it 'records uncertainty without projecting topics or status' do
    Umi::Funnel::EventRecorder.capture_message(message)
    decision.merge!('status' => 'uncertain', 'evidence_message_ids' => [])
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(conversation.label_list).to be_empty
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('uncertain')
  end

  it 'records one sanitized failure and does not repeatedly infer the same input' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify).and_raise(Timeout::Error, 'secret provider body')
    2.times { Umi::Funnel::ConversationClassifier.new(conversation).perform }
    expect(client).to have_received(:classify).once
    payload = Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload
    expect(payload).to include('outcome' => 'failed', 'error' => 'Timeout::Error')
    expect(payload.to_json).not_to include('secret provider body')
  end

  it 'does not write a result or qualification after contact erasure during inference' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      Umi::Shopify::CustomerRedactionService.new(conversation.contact).perform
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated')).to be_empty
    expect(Umi::ConversionDelivery.count).to eq(0)
  end

  %w[off disabled_account other_inbox].each do |condition|
    it "does not infer or write for #{condition}" do
      Umi::Funnel::EventRecorder.capture_message(message)
      overrides = { 'off' => { UMI_FUNNEL_CLASSIFIER_MODE: 'off' }, 'disabled_account' => { UMI_FUNNEL_ACCOUNT_IDS: '' },
                    'other_inbox' => { UMI_FUNNEL_CLASSIFIER_INBOX_IDS: (conversation.inbox_id + 1).to_s } }.fetch(condition)
      expect(Umi::Funnel::ClassificationClient).not_to receive(:new)
      with_modified_env(**overrides) { Umi::Funnel::ConversationClassifier.new(conversation).perform }
      expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated')).to be_empty
    end
  end

  it 'does not apply either of two overlapping responses twice' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      allow(client).to receive(:classify).and_return(decision)
      Umi::Funnel::ConversationClassifier.new(Conversation.find(conversation.id)).perform
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').count).to eq(1)
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified').count).to eq(1)
    expect(Umi::ConversionDelivery.count).to eq(2)
  end

  it 'schedules only new evidence and exposes outcomes in the existing report' do
    Umi::Funnel::EventRecorder.capture_message(message)
    expect { Umi::Funnel::ConversationClassifier.enqueue }.to have_enqueued_job(Umi::Funnel::ClassificationJob).with(conversation.id)
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    Umi::Funnel::ClassificationJob.perform_now(conversation.id)
    expect { Umi::Funnel::ConversationClassifier.enqueue }.not_to have_enqueued_job(Umi::Funnel::ClassificationJob)
    expect(Umi::Funnel::Report.perform(account_id: account.id, since: 1.day.ago)[:classifier_outcomes]).to eq('shadow' => 1)
  end

  it 'ignores private, outgoing and recovered messages as classification triggers' do
    message.update!(private: true)
    Umi::ConversationEvent.where(conversation_id: conversation.id).delete_all
    create(:message, conversation: conversation, account: account, message_type: :outgoing, content: 'Let me know')
    create(:message, conversation: conversation, account: account, message_type: :incoming,
                     content: 'Imported buying request', content_attributes: { umi_recovered: true })
    expect(Umi::Funnel::ClassificationClient).not_to receive(:new)
    Umi::Funnel::ConversationClassifier.new(conversation).perform
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated')).to be_empty
  end

  it 'leaves statuses unchanged when mode is disabled during inference' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      allow(Umi::Funnel::ConversationClassifier).to receive(:mode).and_return('off')
      decision
    end
    Umi::Funnel::ConversationClassifier.new(conversation).perform
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated')).to be_empty
    expect(Umi::ConversionDelivery.count).to eq(0)
  end

  %w[deleted private recovered soft_deleted].each do |change|
    it "does not schedule an observed message that is now #{change}" do
      Umi::Funnel::EventRecorder.capture_message(message)
      case change
      when 'deleted' then message.delete
      when 'private' then message.update!(private: true)
      when 'soft_deleted' then message.update!(content: 'This message was deleted', deleted: true)
      when 'recovered'
        message.update!(content_attributes: { 'umi_recovered' => true })
        expect(message.reload.content_attributes['umi_recovered']).to be(true)
      end
      expect(Umi::Funnel::ClassificationClient).not_to receive(:new)
      expect { Umi::Funnel::ConversationClassifier.enqueue }.not_to have_enqueued_job(Umi::Funnel::ClassificationJob)
      expect { Umi::Funnel::ConversationClassifier.new(conversation).perform }.not_to raise_error
    end
  end

  it 'preserves qualification history when a later inactive conversation asks for support' do
    actor = create(:user, account: account)
    Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'qualified', actor: actor,
                                            reason: 'Requested a fitting', evidence_message_ids: [message.id]).perform
    Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'inactive', actor: actor,
                                            reason: 'No further answer', evidence_message_ids: []).perform
    newer = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Where is my other order?',
                             created_at: 40.seconds.ago)
    decision.merge!('status' => 'not_sales', 'topics' => [{ 'label' => 'support-order-tracking', 'evidence_message_ids' => [newer.id] }],
                    'evidence_message_ids' => [newer.id])
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('inactive')
    expect(conversation.label_list).to include('support-order-tracking')
    expect(Umi::ConversationEvent.where(event_type: 'classification_changed').order(:id).last.payload['status']).to eq('inactive')
  end

  it 'preserves complete long history and attachment metadata without truncation' do
    message.update!(content: 'Earlier context. ' * 2500)
    newer = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Do not reserve it anymore',
                             created_at: 40.seconds.ago)
    newer.attachments.create!(account: account, file_type: :image, external_url: 'https://example.test/photo.jpg')
    decision.merge!('status' => 'engaged', 'evidence_message_ids' => [newer.id])
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    queries = []
    subscriber = lambda do |*args|
      sql = args.last[:sql]
      queries << sql if sql.match?(/SELECT.+FROM "attachments"/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(queries.size).to be <= 2
    expect(client).to have_received(:classify) do |input|
      expect(input[:messages].last).to include(id: newer.id, text: newer.content, attachments: true)
      expect(input[:messages].first[:attachments]).to be(false)
      expect(input[:messages].first[:text]).to eq(message.content)
      expect(input[:truncated]).to be(false)
    end
  end

  it 'holds malformed decisions without storing raw provider text' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient, classify: 'secret invalid response')
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    Umi::Funnel::ConversationClassifier.new(conversation).perform
    payload = Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload
    expect(payload).to include('outcome' => 'failed', 'decision' => {})
    expect(payload.to_json).not_to include('secret invalid response')
  end

  it 'rejects evidence from another conversation' do
    Umi::Funnel::EventRecorder.capture_message(message)
    other = create(:message, account: account)
    decision['evidence_message_ids'] = [other.id]
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(Umi::ConversionDelivery.count).to eq(0)
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('failed')
  end

  it 'includes pre-collection customer history and staff replies saved after the incoming trigger' do
    message
    earlier = create(:message, conversation: conversation, account: account, message_type: :incoming,
                               content: 'My previous purchase fitted well', created_at: 3.days.ago)
    reply = create(:message, conversation: conversation, account: account, message_type: :outgoing,
                             content: 'We can reserve the medium', created_at: 35.seconds.ago)
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    Umi::Funnel::ConversationClassifier.new(conversation).perform
    expect(client).to have_received(:classify) do |input|
      expect(input[:messages].map { |row| row[:id] }).to include(earlier.id, reply.id)
    end
  end

  it 'does not apply an answer after the conversation is resolved during inference' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      conversation.resolved!
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
  end

  it 'rejects a result when included old public text changes during inference' do
    Umi::Funnel::EventRecorder.capture_message(message)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      message.update!(content: 'Actually I am contacting you about a collaboration')
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('stale')
  end

  it 'makes no provider call for an over-budget whole context and deduplicates the diagnostic note' do
    message
    expect(Umi::Funnel::ClassificationClient).not_to receive(:new)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '100' do
      with_modified_env UMI_FUNNEL_CLASSIFIER_ACCEPTED_CONFIGURATION: Umi::Funnel::ClassificationClient.configuration_digest do
        2.times do |index|
          create(:message, conversation: conversation, account: account, message_type: :incoming, content: "Hello #{index}",
                           created_at: 40.seconds.ago)
          Umi::Funnel::ConversationClassifier.new(conversation).perform
        end
      end
    end
    outcomes = Umi::ConversationEvent.where(event_type: 'classification_evaluated').map(&:payload)
    expect(outcomes.size).to eq(2)
    expect(outcomes).to all(include('outcome' => 'uncertain', 'reason_code' => 'context_too_large'))
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(conversation.messages.where(private: true).count).to eq(1)
  end

  it 'keeps shadow attachment-only uncertainty out of the timeline and provider' do
    message.update!(content: nil)
    message.attachments.create!(account: account, file_type: :image, external_url: 'https://example.test/photo.jpg')
    expect(Umi::Funnel::ClassificationClient).not_to receive(:new)
    Umi::Funnel::ConversationClassifier.new(conversation).perform
    payload = Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload
    expect(payload).to include('reason_code' => 'attachment_context_required')
    expect(conversation.messages.where(private: true)).to be_empty
  end

  it 'applies status topics and an unknown positive relationship in one marked note without fan-out duplicates' do
    message
    decision['status'] = 'not_sales'
    decision['roles'] = [{ 'role' => 'umi_influencer', 'evidence_message_ids' => [message.id] }]
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
      Umi::Funnel::CustomerProjectionJob.perform_now(conversation.contact_id)
    end
    expect(conversation.reload.label_list).to include('influencer', 'intent-ready-to-order')
    expect(conversation.contact.reload.custom_attributes['umi_influencer']).to eq('yes')
    note = conversation.messages.where(private: true).sole
    expect(note.content).to include('Sales status:', 'Topics added:', 'influencer: unknown → yes')
    expect(note.content_attributes.dig(Umi::Funnel::CustomerProjection::NOTE_MARKER, 'kind')).to eq('classification_applied')
    expect(note.sender).to be_nil
  end

  it 'rolls back all local changes and qualification when the combined note cannot be stored' do
    message
    decision['roles'] = [{ 'role' => 'umi_wholesale', 'evidence_message_ids' => [message.id] }]
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(Umi::Funnel::CustomerProjection).to receive(:write_note!).and_raise(ActiveRecord::RecordInvalid)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(conversation.label_list).to be_empty
    expect(conversation.contact.reload.custom_attributes['umi_wholesale']).to be_nil
    expect(conversation.contact.additional_attributes.dig('umi_klaviyo_sync', 'roles')).to be_nil
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    expect(Umi::ConversionDelivery.count).to eq(0)
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('failed')
  end

  it 'does not reactivate a topic removed by an operator using older buying evidence' do
    message
    actor = create(:user, account: account)
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      conversation.update_labels(['intent-ready-to-order'])
      allow(Current).to receive(:user).and_return(actor)
      conversation.update_labels([])
    end
    greeting = create(:message, conversation: conversation, account: account, message_type: :incoming,
                                content: 'Hello again', created_at: 40.seconds.ago)
    decision.merge!('status' => 'engaged', 'evidence_message_ids' => [greeting.id])
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.label_list).not_to include('intent-ready-to-order')
    expect(conversation.custom_attributes['umi_sales_status']).to eq('engaged')
  end

  it 'allows a genuinely new topic request after the operator removal' do
    freeze_time do
      message
      actor = create(:user, account: account)
      with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
        conversation.update_labels(['intent-ready-to-order'])
        allow(Current).to receive(:user).and_return(actor)
        conversation.update_labels([])
      end
      travel 1.minute
      fresh = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Please reserve a blue dress')
      travel 1.minute
      decision['evidence_message_ids'] = [fresh.id]
      decision['topics'].first['evidence_message_ids'] = [fresh.id]
      client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
      allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
      with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
        Umi::Funnel::ConversationClassifier.new(conversation).perform
      end
      expect(conversation.reload.label_list).to include('intent-ready-to-order')
    end
  end

  it 'keeps topic corrections committed while inference is running' do
    message
    conversation.update!(label_list: ['support-refund'])
    actor = create(:user, account: account)
    client = instance_double(Umi::Funnel::ClassificationClient)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    allow(client).to receive(:classify) do
      allow(Current).to receive(:user).and_return(actor)
      conversation.update_labels([])
      decision
    end
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('manual_override')
  end

  it 'holds a changed configuration until its exact tuple has a fresh quality acceptance' do
    message
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '500001' do
      Umi::Funnel::ConversationClassifier.new(conversation).perform
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('configuration_unaccepted')
  end

  %w[umi_vip umi_high_value].each do |role|
    it "rejects forbidden AI #{role} proposals without local mutation" do
      message
      decision['roles'] = [{ 'role' => role, 'evidence_message_ids' => [message.id] }]
      client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
      allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
      with_modified_env UMI_FUNNEL_CLASSIFIER_MODE: 'auto' do
        Umi::Funnel::ConversationClassifier.new(conversation).perform
      end
      expect(conversation.reload.custom_attributes['umi_sales_status']).to be_nil
      expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated').sole.payload['outcome']).to eq('failed')
    end
  end
end
