# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer context in Enterprise lifecycle', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago) }

  before { create(:captain_inbox, inbox: inbox, captain_assistant: assistant) }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  it 'projects customer context while Captain resolves the actual pending conversation' do
    Umi::Funnel::CustomerMutation.new(conversation.contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    Captain::InboxPendingConversationsResolutionJob.perform_now(inbox.reload)
    expect(conversation.reload).to be_resolved
    expect(conversation.label_list).to eq(['vip'])
  end

  it 'rechecks current status before applying a stale Captain resolution' do
    stale = Conversation.find(conversation.id)
    conversation.reload.open!
    Captain::InboxPendingConversationsResolutionJob.new.send(:resolve_conversation, stale, inbox.reload, 'Complete')
    expect(conversation.reload).to be_open
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'retains Enterprise human-response opening and refreshes the customer projection' do
    Umi::Funnel::CustomerMutation.new(conversation.contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    create(:message, message_type: :outgoing, account: account, conversation: conversation)
    expect(conversation.reload).to be_open
    expect(conversation.label_list).to eq(['vip'])
  end
end
