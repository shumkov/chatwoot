# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::ConversationTransition do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:actor) { create(:user, account: account) }
  let(:message) { create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :incoming) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      example.run
    end
  end

  it 'captures distinct messages at equal timestamps without storing their content' do
    first = Umi::Funnel::EventRecorder.capture_message(message)
    other = create(:message, conversation: conversation, account: account, inbox: conversation.inbox, created_at: message.created_at)
    second = Umi::Funnel::EventRecorder.capture_message(other)
    expect(first.id).not_to eq(second.id)
    expect(Umi::Funnel::EventRecorder.capture_message(message).id).to eq(first.id)
    expect(first.payload).not_to have_key('content')
  end

  it 'qualifies once with evidence and records correction without deleting history' do
    transition = described_class.new(conversation: conversation, actor: actor, status: 'qualified',
                                     reason: 'Asked about fitting', evidence_message_ids: [message.id])
    transition.perform
    transition.perform
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified').count).to eq(1)
    expect(Umi::ConversionDelivery.count).to eq(2)
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('qualified')
    described_class.new(conversation: conversation, actor: actor, status: 'not_sales',
                        reason: 'Wrong conversation', evidence_message_ids: []).perform
    expect(Umi::ConversionDelivery.distinct.pluck(:state)).to eq(['excluded'])
    expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified').count).to eq(1)
  end

  %w[recovered private historical outgoing deleted].each do |kind|
    it "rejects #{kind} evidence for qualification" do
      message.update!(content_attributes: { umi_recovered: true }) if kind == 'recovered'
      message.update!(private: true) if kind == 'private'
      message.update!(content_attributes: { deleted: true }) if kind == 'deleted'
      message.update!(created_at: Time.utc(2025)) if kind == 'historical'
      message.update!(message_type: Message.message_types[:outgoing]) if kind == 'outgoing'
      expect do
        described_class.new(conversation: conversation, actor: actor, status: 'qualified',
                            reason: 'Interest', evidence_message_ids: [message.id]).perform
      end.to raise_error(ArgumentError)
      expect(Umi::ConversationEvent.where(event_type: 'conversation_qualified')).to be_empty
    end
  end

  it 'protects the derived status while preserving unrelated edits' do
    described_class.new(conversation: conversation, actor: actor, status: 'engaged',
                        reason: 'Started discussion', evidence_message_ids: []).perform
    expect { conversation.update!(custom_attributes: { 'umi_sales_status' => 'purchased' }) }.to raise_error(ActiveRecord::RecordInvalid)
    conversation.reload.update!(custom_attributes: { 'ordinary' => 'value' })
    expect(conversation.reload.custom_attributes).to include('umi_sales_status' => 'engaged', 'ordinary' => 'value')
  end

  it 'does not allow a public new conversation to claim a paid status' do
    fresh = build(:conversation, account: account, custom_attributes: { 'umi_sales_status' => 'purchased' })
    expect(fresh.save).to be(false)
  end

  it 'redacts evidence and prevents subsequent qualification' do
    described_class.new(conversation: conversation, actor: actor, status: 'qualified',
                        reason: 'Fitting', evidence_message_ids: [message.id]).perform
    Umi::Shopify::CustomerRedactionService.new(conversation.contact).perform
    expect(Umi::ConversationEvent.where(redacted_at: nil)).to be_empty
    expect(Umi::ConversationEvent.pluck(:contact_id, :conversation_id).flatten.compact).to be_empty
    expect(Umi::ConversionDelivery.distinct.pluck(:state)).to eq(['excluded'])
    expect do
      described_class.new(conversation: conversation.reload, actor: actor, status: 'qualified',
                          reason: 'Fitting', evidence_message_ids: [message.id]).perform
    end.to raise_error(ArgumentError)
  end
end
