# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer projection', type: :model do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  it 'keeps Repeat and VIP separate from refund topics and current sales status' do
    conversation.update_labels(['support-refund'])
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(
      roles: { umi_vip: 'yes' }, snapshot: { 'buyer_lifecycle' => 'repeat', 'paid_order_count' => 2, 'paid_history_complete' => true }
    )
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.reload.label_list).to match_array(%w[repeat vip support-refund])
    expect(conversation.custom_attributes['umi_sales_status']).to be_nil
    expect(conversation.messages.where(private: true).count).to eq(1)
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.messages.where(private: true).count).to eq(1)
  end

  it 'preserves the last verified facts on timeout and does not call unknown a non-buyer' do
    service = Umi::Funnel::CustomerMutation.new(contact, source: 'system')
    service.perform(snapshot: { 'status' => 'stale' })
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to be_nil
    service.perform(snapshot: { 'buyer_lifecycle' => 'client', 'paid_order_count' => 1, 'paid_history_complete' => true })
    service.perform(snapshot: { 'status' => 'stale' })
    expect(contact.reload.custom_attributes['umi_funnel_stage']).to eq('client')
  end

  it 'persists the latest customer tags on close and reopen without losing dirty snooze and assignment fields' do
    conversation.reload.update_labels(['support-refund'])
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    agent = create(:user, account: account)
    policy = create(:sla_policy, account: account)
    conversation.reload.assign_attributes(status: :snoozed, snoozed_until: 1.day.from_now, priority: :high,
                                          assignee_id: agent.id, sla_policy_id: policy.id)
    conversation.save!
    expect(conversation.reload.label_list).to match_array(%w[vip support-refund])
    expect(conversation.snoozed_until).to be_present
    expect(conversation.priority).to eq('high')
    expect(conversation.assignee_id).to eq(agent.id)
    expect(conversation.sla_policy_id).to eq(policy.id)
    conversation.resolved!
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'no' })
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(conversation.reload.label_list).to include('vip')
    conversation.open!
    expect(conversation.reload.label_list).to eq(['support-refund'])
  end

  it 'rejects a stale full label list but preserves current managed labels with a topic edit' do
    conversation.reload.update_labels(['support-refund'])
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect { conversation.update_labels(['support-exchange']) }.to raise_error(ArgumentError, /Managed labels/)
    conversation.update_labels(%w[vip support-exchange])
    expect(conversation.reload.label_list).to match_array(%w[vip support-exchange])
  end

  it 'commits the incoming message even when its deferred initial summary fails' do
    message = create(:message, :incoming, conversation: conversation, account: account)
    allow(Umi::Funnel::CustomerProjection).to receive(:write_note!).and_raise('note storage unavailable')
    expect { Umi::Funnel::CustomerProjectionJob.perform_now(contact.id, conversation.id) }.to raise_error('note storage unavailable')
    expect(Message.exists?(message.id)).to be(true)
    expect(conversation.reload.additional_attributes.dig('umi_customer_projection', 'summary')).to be_nil
    allow(Umi::Funnel::CustomerProjection).to receive(:write_note!).and_call_original
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id, conversation.id)
    expect(conversation.reload.additional_attributes.dig('umi_customer_projection', 'summary')).to be_present
    expect(conversation.messages.where(private: true).count).to eq(1)
    expect { Umi::Funnel::CustomerProjectionJob.perform_now(contact.id, conversation.id) }.not_to change(conversation.messages, :count)
  end

  it 'keeps all four funnel labels mutually exclusive with paid facts taking priority over segment membership' do
    conversation
    service = Umi::Funnel::CustomerMutation.new(contact, source: 'system')
    [
      ['chooser',
       { 'buyer_lifecycle' => 'non_buyer',
         'segments' => { 'complete' => true, 'observed_at' => Time.current.iso8601, 'chooser' => true, 'seeker' => false } }],
      ['seeker',
       { 'buyer_lifecycle' => 'non_buyer',
         'segments' => { 'complete' => true, 'observed_at' => Time.current.iso8601, 'chooser' => true, 'seeker' => true } }],
      ['client', { 'buyer_lifecycle' => 'client' }],
      ['repeat', { 'buyer_lifecycle' => 'repeat' }]
    ].each do |label, snapshot|
      service.perform(snapshot: snapshot)
      Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
      expect(conversation.reload.label_list).to eq([label])
    end
  end

  it 'does not change revision or write a note for a checked-at-only refresh' do
    conversation
    service = Umi::Funnel::CustomerMutation.new(contact, source: 'system')
    service.perform(snapshot: { 'buyer_lifecycle' => 'repeat', 'payment_snapshot_at' => 1.hour.ago.iso8601, 'checked_at' => 1.hour.ago.iso8601 })
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    revision = contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'revision')
    count = conversation.messages.where(private: true).count
    service.perform(snapshot: { 'buyer_lifecycle' => 'repeat', 'payment_snapshot_at' => Time.current.iso8601, 'checked_at' => Time.current.iso8601 })
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id)
    expect(contact.reload.additional_attributes.dig('umi_klaviyo_sync', 'revision')).to eq(revision)
    expect(conversation.messages.where(private: true).count).to eq(count)
  end

  it 'allows AI positive roles only from unknown and never assigns VIP or high value' do
    conversation
    Umi::Funnel::CustomerMutation.new(contact, source: 'operator').perform(roles: { umi_influencer: 'no' })
    Umi::Funnel::CustomerMutation.new(contact, source: 'ai', conversation: conversation).perform(
      roles: { umi_influencer: 'yes', umi_wholesale: 'yes', umi_vip: 'yes', umi_high_value: 'yes' }
    )
    expect(contact.reload.custom_attributes).to include('umi_influencer' => 'no', 'umi_wholesale' => 'yes')
    expect(contact.custom_attributes).not_to have_key('umi_vip')
    expect(contact.custom_attributes).not_to have_key('umi_high_value')
  end

  it 'keeps the closed snapshot when an initial summary runs after a newer customer update' do
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    conversation.reload.resolved!
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'no' })
    Umi::Funnel::CustomerProjectionJob.perform_now(contact.id, conversation.id)
    expect(conversation.reload.label_list).to eq(['vip'])
    expect(conversation.messages.where(private: true).last.content).to include('vip: yes')
  end

  it 'toggles from the locked current status when the model instance is stale' do
    stale = Conversation.find(conversation.id)
    conversation.reload.resolved!
    stale.priority = :high
    stale.toggle_status
    expect(conversation.reload).to be_open
    expect(conversation.priority).to eq('high')
  end

  it 'applies an absolute status setter even when its stale instance already has the requested status' do
    stale = Conversation.find(conversation.id)
    conversation.reload.resolved!
    stale.open!
    expect(conversation.reload).to be_open
  end

  it 'preserves a newer staff role when an older public contact instance saves ordinary pre-chat fields' do
    stale = Contact.find(contact.id)
    Umi::Funnel::CustomerMutation.new(contact, source: 'operator').perform(roles: { umi_vip: 'yes' })
    ContactIdentifyAction.new(contact: stale, params: { name: 'Updated customer', custom_attributes: { size: 'M' } }).perform
    expect(contact.reload.custom_attributes).to include('umi_vip' => 'yes', 'size' => 'M')
    expect(contact.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending', 'value')).to eq('yes')
  end

  it 'rolls back a later role change if its current conversation note cannot be saved' do
    conversation
    allow(Umi::Funnel::CustomerProjection).to receive(:write_note!).and_raise(ActiveRecord::RecordInvalid)
    expect do
      Umi::Funnel::CustomerMutation.new(contact, source: 'ai', conversation: conversation).perform(roles: { umi_influencer: 'yes' })
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(contact.reload.custom_attributes['umi_influencer']).to be_nil
    expect(contact.additional_attributes['umi_klaviyo_sync']).to be_nil
  end
end
