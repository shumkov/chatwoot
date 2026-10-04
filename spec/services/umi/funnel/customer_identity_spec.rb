# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Customer projection identity', type: :model do
  let(:account) { create(:account) }
  let(:target) { create(:contact, account: account) }
  let(:source) { create(:contact, account: account, additional_attributes: { umi_klaviyo_profile_id: 'source-profile' }) }

  around do |example|
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  it 'preserves canonical target facts and removes source-owned context from moved closed conversations' do
    Umi::Funnel::CustomerMutation.new(source, source: 'system').perform(roles: { umi_vip: 'yes' })
    conversation = create(:conversation, account: account, contact: source)
    conversation.reload.update_labels(%w[vip support-refund])
    conversation.resolved!
    ContactMergeAction.new(account: account, base_contact: target, mergee_contact: source).perform
    expect(target.reload.custom_attributes['umi_vip']).to be_nil
    expect(target.additional_attributes['umi_klaviyo_profile_id']).to be_nil
    expect(conversation.reload.contact_id).to eq(target.id)
    expect(conversation.label_list).to eq(['support-refund'])
  end

  it 'invalidates only projections owned by the specified binding, including closed conversations' do
    Umi::Funnel::CustomerMutation.new(source, source: 'system').perform(roles: { umi_vip: 'yes' })
    owned = create(:conversation, account: account, contact: source)
    unrelated = create(:conversation, account: account, contact: source)
    owned.reload.resolved!
    state = unrelated.additional_attributes.fetch('umi_customer_projection').merge('binding' => 'different-profile')
    unrelated.update!(additional_attributes: { umi_customer_projection: state })
    source.with_lock { Umi::Funnel::CustomerProjection.invalidate!(source, binding: 'source-profile') }
    expect(owned.reload.label_list).to be_empty
    expect(unrelated.reload.label_list).to eq(['vip'])
  end

  it 'clears the previous binding projection through the real verified binding action' do
    source.update!(email: 'buyer@example.com')
    actor = create(:user, account: account)
    Umi::Funnel::CustomerMutation.new(source, source: 'system').perform(snapshot: { 'buyer_lifecycle' => 'repeat' })
    conversation = create(:conversation, account: account, contact: source)
    conversation.reload.resolved!
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profile).with('replacement').and_return('id' => 'replacement', 'attributes' => { 'email' => source.email })
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      Umi::Funnel::ProfileBinding.new(contact: source, profile_id: 'replacement', actor: actor, reason: 'Corrected customer identity').perform
    end
    expect(source.reload.additional_attributes['umi_klaviyo_profile_id']).to eq('replacement')
    expect(source.custom_attributes).not_to have_key('umi_funnel_stage')
    expect(conversation.reload.label_list).to be_empty
  end

  it 'keeps an erasure tombstone when its contact is merged' do
    source.update!(additional_attributes: { umi_profile_redacted: true })
    ContactMergeAction.new(account: account, base_contact: target, mergee_contact: source).perform
    expect(target.reload.additional_attributes['umi_profile_redacted']).to be(true)
  end

  it 'does not project the previous customer roles under a corrected binding' do
    source.update!(email: 'buyer@example.com', custom_attributes: { size: 'M' })
    actor = create(:user, account: account)
    Umi::Funnel::CustomerMutation.new(source, source: 'operator', actor: actor).perform(
      roles: { umi_vip: 'yes', umi_model: 'yes' },
      snapshot: { 'buyer_lifecycle' => 'repeat', 'paid_order_count' => 2, 'barter_history' => true }
    )
    conversation = create(:conversation, account: account, contact: source)
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profile).with('replacement').and_return('id' => 'replacement', 'attributes' => { 'email' => source.email })
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      Umi::Funnel::ProfileBinding.new(contact: source, profile_id: 'replacement', actor: actor, reason: 'Corrected customer identity').perform
    end
    Umi::Funnel::CustomerProjectionJob.perform_now(source.id)

    expect(source.reload.custom_attributes).to eq('size' => 'M')
    expect(source.additional_attributes).not_to have_key('umi_klaviyo_sync')
    expect(conversation.reload.label_list).to be_empty
    expect(conversation.additional_attributes.fetch('umi_customer_projection')).to include('binding' => 'replacement', 'facts' => {})
  end

  it 'preserves local roles when verifying the first customer binding' do
    target.update!(email: 'buyer@example.com')
    actor = create(:user, account: account)
    Umi::Funnel::CustomerMutation.new(target, source: 'operator', actor: actor).perform(roles: { umi_vip: 'yes' })
    conversation = create(:conversation, account: account, contact: target)
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profile).with('first-profile').and_return('id' => 'first-profile', 'attributes' => { 'email' => target.email })
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      Umi::Funnel::ProfileBinding.new(contact: target, profile_id: 'first-profile', actor: actor, reason: 'Verified customer identity').perform
    end
    Umi::Funnel::CustomerProjectionJob.perform_now(target.id)

    expect(target.reload.custom_attributes['umi_vip']).to eq('yes')
    expect(target.additional_attributes.dig('umi_klaviyo_sync', 'roles', 'umi_vip', 'pending', 'value')).to eq('yes')
    expect(conversation.reload.label_list).to eq(['vip'])
  end

  it 'does not rebuild invalidated closed history when its deferred initial summary runs after binding correction' do
    source.update!(email: 'buyer@example.com')
    actor = create(:user, account: account)
    Umi::Funnel::CustomerMutation.new(source, source: 'system').perform(snapshot: { 'buyer_lifecycle' => 'repeat' })
    conversation = create(:conversation, account: account, contact: source)
    conversation.reload.resolved!
    client = instance_double(Umi::Funnel::KlaviyoClient)
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    allow(client).to receive(:profile).with('replacement').and_return('id' => 'replacement', 'attributes' => { 'email' => source.email })
    with_modified_env UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      Umi::Funnel::ProfileBinding.new(contact: source, profile_id: 'replacement', actor: actor, reason: 'Corrected customer identity').perform
    end
    Umi::Funnel::CustomerMutation.new(source, source: 'system').perform(snapshot: { 'buyer_lifecycle' => 'client' })
    expect(conversation.reload.additional_attributes).not_to have_key('umi_customer_projection')

    expect { Umi::Funnel::CustomerProjectionJob.perform_now(source.id, conversation.id) }.not_to change(conversation.messages, :count)
    expect(conversation.reload.label_list).to be_empty
    expect(conversation.additional_attributes).not_to have_key('umi_customer_projection')
  end

  it 'erases existing target customer context when merging an erased source without resurrecting it' do
    target.update!(custom_attributes: { size: 'M' }, additional_attributes: { umi_klaviyo_profile_id: 'target-profile' })
    Umi::Funnel::CustomerMutation.new(target, source: 'system').perform(
      roles: { umi_vip: 'yes' }, snapshot: { 'buyer_lifecycle' => 'repeat', 'paid_order_count' => 2 }
    )
    conversations = create_list(:conversation, 2, account: account, contact: target)
    conversations.each do |conversation|
      Umi::Funnel::CustomerProjectionJob.perform_now(target.id, conversation.id)
      conversation.reload.update_labels(%w[repeat vip support-refund])
    end
    conversations.last.resolved!
    staff_note = create(:message, :outgoing, private: true, conversation: conversations.first, account: account)
    Umi::Shopify::CustomerRedactionService.new(source).perform

    ContactMergeAction.new(account: account, base_contact: target, mergee_contact: source).perform

    expect(target.reload.custom_attributes).to eq('size' => 'M')
    expect(target.additional_attributes.slice(*Umi::Funnel::Configuration::TECHNICAL_KEYS)).to eq('umi_profile_redacted' => true)
    conversations.each do |conversation|
      expect(conversation.reload.additional_attributes).not_to have_key('umi_customer_projection')
      expect(conversation.messages.where("content_attributes -> 'umi_customer_summary' IS NOT NULL")).to be_empty
      conversation.open!
      Umi::Funnel::CustomerProjectionJob.perform_now(target.id, conversation.id)
      expect(conversation.reload.label_list).to eq(['support-refund'])
      expect(conversation.additional_attributes).not_to have_key('umi_customer_projection')
    end
    expect(Message.exists?(staff_note.id)).to be(true)
  end

  it 'erases owned labels, technical projection and summary notes, including resolved conversations' do
    Umi::Funnel::CustomerMutation.new(source, source: 'system').perform(roles: { umi_vip: 'yes' })
    conversation = create(:conversation, account: account, contact: source)
    Umi::Funnel::CustomerProjectionJob.perform_now(source.id, conversation.id)
    conversation.reload.resolved!
    Umi::Shopify::CustomerRedactionService.new(source).perform
    expect(source.reload.additional_attributes).to include('umi_profile_redacted' => true)
    expect(source.additional_attributes).not_to have_key('umi_klaviyo_sync')
    expect(conversation.reload.label_list).not_to include('vip')
    expect(conversation.additional_attributes).not_to have_key('umi_customer_projection')
    expect(conversation.messages.where(private: true)).to be_empty
    conversation.open!
    expect(conversation.reload.additional_attributes).not_to have_key('umi_customer_projection')
  end
end
