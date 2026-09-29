# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enterprise customer projection', type: :model do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  it 'preserves a pending SLA policy assignment while projecting customer labels' do
    Umi::Funnel::CustomerMutation.new(contact, source: 'system').perform(roles: { umi_vip: 'yes' })
    policy = create(:sla_policy, account: account)
    conversation.reload.assign_attributes(status: :snoozed, snoozed_until: 1.day.from_now, sla_policy_id: policy.id)
    conversation.save!

    expect(conversation.reload.label_list).to eq(['vip'])
    expect(conversation.snoozed_until).to be_present
    expect(conversation.sla_policy_id).to eq(policy.id)
  end
end
