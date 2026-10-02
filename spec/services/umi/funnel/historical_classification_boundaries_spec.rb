# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Historical classification boundaries' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:actor) { create(:user, account: account) }
  let(:old_message) do
    create(:message, conversation: conversation, account: account, message_type: :incoming,
                     content: 'Please reserve the black dress in S', created_at: 3.hours.ago)
  end
  let!(:historical) do
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'classification_evaluated', provenance: 'historical', occurrence_key: 'audit:example',
                                   occurred_at: old_message.created_at, observed_at: 2.hours.ago, evidence_message_ids: [old_message.id],
                                   payload: { mode: 'historical', outcome: 'applied', public_history_cutoff: old_message.id,
                                              snapshot_at: 2.hours.ago.utc.iso8601(6), decision: { status: 'qualified' } })
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_MODE: 'auto', UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s do
      example.run
    end
  end

  it 'does not erase an archived classification when commerce facts refresh' do
    conversation.project_umi_sales_status!('qualified')
    Umi::Funnel::CommerceProjection.refresh(conversation)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('qualified')
    expect(Umi::ConversionDelivery.count).to eq(0)
  end

  it 'allows a historical qualified display to acquire one genuine live qualification' do
    conversation.project_umi_sales_status!('qualified')
    fresh = create(:message, conversation: conversation, account: account, message_type: :incoming,
                             content: 'Please reserve another dress for tomorrow', created_at: 1.minute.ago)
    2.times do
      Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'qualified', actor: nil, reason: 'New reservation',
                                              evidence_message_ids: [fresh.id], classifier: { 'model' => 'test' }).perform
    end
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified').count).to eq(1)
    expect(Umi::ConversionDelivery.count).to eq(2)
  end

  it 'does not export archived buying evidence after a new greeting' do
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Hello again')
    expect do
      Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'qualified', actor: actor,
                                              reason: 'Previously wanted a dress', evidence_message_ids: [old_message.id]).perform
    end.to raise_error(ArgumentError, /live incoming evidence/)
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
  end

  it 'keeps archived buying evidence out of the classifier fresh evidence list' do
    Umi::Funnel::EventRecorder.capture_message(old_message)
    fresh = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Hello again')
    Umi::Funnel::EventRecorder.capture_message(fresh)
    context = Umi::Funnel::ClassificationContext.new(conversation, watermark: fresh.id, cutoff: fresh.id,
                                                                   boundary: 2.days.ago, as_of: Time.current).build
    expect(context[:fresh_evidence_ids]).to eq([fresh.id])
    expect(context[:messages].map { |row| row[:id] }).to include(old_message.id)
  end

  it 'keeps a later manual correction authoritative during commerce refresh' do
    conversation.project_umi_sales_status!('qualified')
    Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'not_sales', actor: actor,
                                            reason: 'Reviewed collaboration', evidence_message_ids: [old_message.id]).perform
    Umi::Funnel::CommerceProjection.refresh(conversation)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('not_sales')
    expect(Umi::ConversionDelivery.count).to eq(0)
  end

  it 'classifies genuinely new buying intent after a historical qualified display' do
    conversation.project_umi_sales_status!('qualified')
    fresh = create(:message, conversation: conversation, account: account, message_type: :incoming,
                             content: 'Please reserve another dress for tomorrow', created_at: 1.minute.ago)
    Umi::Funnel::EventRecorder.capture_message(fresh)
    decision = { 'status' => 'qualified', 'topics' => [], 'roles' => [], 'reason' => 'New reservation',
                 'evidence_message_ids' => [fresh.id] }
    client = instance_double(Umi::Funnel::ClassificationClient, classify: decision)
    allow(Umi::Funnel::ClassificationClient).to receive(:new).and_return(client)
    with_modified_env UMI_FUNNEL_CLASSIFIER_AUTO_STARTED_AT: 1.day.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_MODEL: 'gpt-6-sol', UMI_FUNNEL_CLASSIFIER_INPUT_MAX_BYTES: '500000',
                      UMI_FUNNEL_CLASSIFIER_API_BASE: 'https://proxy.example.test/v1' do
      with_modified_env UMI_FUNNEL_CLASSIFIER_ACCEPTED_CONFIGURATION: Umi::Funnel::ClassificationClient.configuration_digest do
        2.times { Umi::Funnel::ConversationClassifier.new(conversation).perform }
      end
    end
    expect(client).to have_received(:classify).once
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified').count).to eq(1)
    expect(Umi::ConversionDelivery.count).to eq(2)
    expect(Umi::ConversationEvent.where(event_type: 'classification_evaluated', provenance: 'classifier').sole.payload)
      .to include('outcome' => 'applied', 'input_message_id' => fresh.id)
  end

  it 'does not export reviewed old buying evidence after an uncertain historical assessment' do
    historical.destroy!
    Umi::ConversationEvent.record!(account_id: account.id, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                   event_type: 'classification_evaluated', provenance: 'historical', occurrence_key: 'audit:uncertain',
                                   occurred_at: nil, observed_at: 2.hours.ago, evidence_message_ids: [],
                                   payload: { mode: 'historical', outcome: 'uncertain', public_history_cutoff: old_message.id,
                                              snapshot_at: 2.hours.ago.utc.iso8601(6), decision: { status: 'uncertain' } })
    Umi::Funnel::EventRecorder.capture_message(old_message)
    fresh = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Hello again')
    Umi::Funnel::EventRecorder.capture_message(fresh)
    context = Umi::Funnel::ClassificationContext.new(conversation, watermark: fresh.id, cutoff: fresh.id,
                                                                   boundary: 2.days.ago, as_of: Time.current).build
    expect(context[:fresh_evidence_ids]).to eq([fresh.id])
    expect do
      Umi::Funnel::ConversationTransition.new(conversation: conversation, status: 'qualified', actor: actor,
                                              reason: 'Previously wanted a dress', evidence_message_ids: [old_message.id]).perform
    end.to raise_error(ArgumentError, /live incoming evidence/)
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
  end
end
