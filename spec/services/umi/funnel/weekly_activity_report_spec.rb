# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Funnel::WeeklyActivityReport' do
  let(:account) { create(:account) }
  let(:start) { Time.iso8601('2026-10-01T17:00:00Z') }
  let(:conversation) { create(:conversation, account: account, created_at: start) }
  let(:params) { { account: account, since: start, until_time: start + 7.days, as_of: start + 7.days + 9.hours } }
  let(:report) { Umi::Funnel::WeeklyActivityReport.new(**params).perform }
  let(:paid) do
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'order_paid', provenance: 'shopify', occurrence_key: 'paid:1001',
                                   occurred_at: start + 1.day, observed_at: start + 1.day,
                                   payload: { shop_domain: 'umi.myshopify.com', order_id: '1001', currency: 'THB', value: '4000' })
  end

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: '', UMI_FUNNEL_STARTED_AT: '2026-09-27T16:33:00Z' do
      travel_to(start + 14.days) { example.run }
    end
  end

  it 'counts late-observed incoming by occurrence week and keeps raw membership distinct from sales claims' do
    2.times do |index|
      Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                     event_type: 'message_received', provenance: 'live', occurrence_key: "message:#{index}",
                                     occurred_at: start + index.hours, observed_at: start + 8.days,
                                     payload: { message_id: index + 1, ad_id: '12345', content: 'Never export private text' })
    end
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'message_received', provenance: 'live', occurrence_key: 'following-week',
                                   occurred_at: start + 7.days, observed_at: start + 7.days, payload: { message_id: 3 })

    expect(report).to include(conversations: 1, membership_basis: 'raw_recorded_activity_requires_business_audit')
    expect(report[:conversation_evidence]).to contain_exactly(
      include(conversation_id: conversation.id, display_id: conversation.display_id, incoming_message_ids: [1, 2],
              customer_display_name: conversation.contact.name,
              ad_referrals: [include(message_id: 1, ad_id: '12345', ad_name: nil), include(message_id: 2, ad_id: '12345')])
    )
    expect(JSON.generate(report)).not_to include('Never export private text')
  end

  it 'takes an ad title only from the exact matching message referral, never the latest sidebar ad' do
    message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: conversation.contact,
                               message_type: :incoming, created_at: start,
                               content_attributes: { referral: { source: 'ADS', ad_id: '12345', ads_context_data: { ad_title: 'Tank dress' } } })
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'message_received', provenance: 'live', occurrence_key: 'ad-message', occurred_at: start,
                                   observed_at: start, payload: { message_id: message.id, ad_id: '12345' })
    expect(report[:conversation_evidence].sole[:ad_referrals].sole[:ad_name]).to eq('Tank dress')
    message.update!(content_attributes: { referral: { source: 'ADS', ad_id: '99999', ads_context_data: { ad_title: 'Different ad' } } })
    expect(Umi::Funnel::WeeklyActivityReport.new(**params).perform[:conversation_evidence].sole[:ad_referrals].sole[:ad_name]).to be_nil
  end

  it 'deduplicates qualifying conversations and respects the historical correction cutoff' do
    2.times do |index|
      Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                     event_type: 'conversation_qualified', provenance: 'operator', occurrence_key: "qualified:#{index}",
                                     occurred_at: start + (index + 1).hours, observed_at: start + (index + 1).hours, payload: {})
    end
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'classification_changed', provenance: 'operator', occurrence_key: 'correction',
                                   occurred_at: start + 8.days, observed_at: start + 8.days, payload: { status: 'not_sales' })
    expect(report[:qualified_conversations]).to eq(1)
    expect(Umi::Funnel::WeeklyActivityReport.new(**params, as_of: start + 9.days).perform[:qualified_conversations]).to eq(0)
  end

  it 'does not call a non-null conversation ID verified attribution without the link and financial evidence' do
    paid
    expect(report[:paid_orders]).to eq(1)
    expect(report[:verified_chat_paid_orders]).to eq(0)
    expect(report[:paid_order_evidence]).to contain_exactly(include(shopify_order_id: '1001', attribution_reason: 'missing_verified_link'))
  end

  it 'includes a paid customer private-note conversation for workflow audit without claiming attribution or public activity' do
    event = Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id,
                                           event_type: 'order_paid', provenance: 'shopify', occurrence_key: 'unlinked:1001',
                                           occurred_at: start + 1.day, observed_at: start + 1.day,
                                           payload: { shop_domain: 'umi.myshopify.com', order_id: '1001', currency: 'THB', value: '4000' })
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :outgoing,
                     private: true, created_at: start + 2.days, content: 'The fitting order still needs its conversation link.')
    sibling = create(:conversation, account: account, contact: conversation.contact)
    create(:message, account: account, conversation: sibling, inbox: sibling.inbox, message_type: :incoming,
                     created_at: start + 3.days)
    old_thread = create(:conversation, account: account, contact: conversation.contact)
    create(:message, account: account, conversation: old_thread, inbox: old_thread.inbox, message_type: :incoming,
                     created_at: start - 1.second)
    create(:message, account: account, conversation: old_thread, inbox: old_thread.inbox, message_type: :incoming,
                     created_at: start + 7.days)
    unrelated = create(:conversation, account: account)
    create(:message, account: account, conversation: unrelated, inbox: unrelated.inbox, message_type: :incoming,
                     created_at: start + 2.days)
    other_account = create(:account)
    foreign = create(:conversation, account: other_account, contact: conversation.contact)
    create(:message, account: other_account, conversation: foreign, inbox: foreign.inbox, message_type: :incoming,
                     created_at: start + 2.days)

    expect(report[:workflow_candidates]).to contain_exactly(
      { conversation_id: conversation.id, display_id: conversation.display_id, event_ids: [event.id] },
      { conversation_id: sibling.id, display_id: sibling.display_id, event_ids: [event.id] }
    )
    expect(report).to include(conversations: 0, paid_orders: 1, verified_chat_paid_orders: 0)
    expect(report[:paid_order_evidence].sole[:conversation_id]).to be_nil
    expect(JSON.generate(report)).not_to include('The fitting order still needs')
  end

  it 'verifies and deduplicates paid orders while exposing current attribution timing separately from payment time' do
    event = paid
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: conversation.contact_id, conversation_id: conversation.id,
                                   event_type: 'order_paid', provenance: 'shopify', occurrence_key: 'duplicate-payment-evidence',
                                   occurred_at: event.occurred_at, observed_at: event.observed_at, payload: event.payload)
    link = Umi::ShopifyOrderAttribution.create!(account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: '1001',
                                                source: 'operator', attribution_state: 'verified', conversation_id: conversation.id,
                                                contact_id: conversation.contact_id)
    Umi::ShopifyOrderFinancialState.create!(account: account, shop_domain: 'umi.myshopify.com', shopify_order_id: '1001',
                                            reconciliation_requested_at: Time.current, paid_event: event,
                                            snapshot: { first_paid_snapshot: { classification: 'paid', currency: 'THB',
                                                                               current_order_value: '4000',
                                                                               last_payment_at: event.occurred_at.iso8601 } })
    expect(report).to include(paid_orders: 1, verified_chat_paid_orders: 1, verified_chat_paid_value_by_currency: { 'THB' => '4000.0' })
    expect(report[:paid_order_evidence]).to contain_exactly(include(attribution_reason: nil, attribution_verified: true,
                                                                    attribution_updated_at: link.updated_at.iso8601(6),
                                                                    occurred_at: event.occurred_at.iso8601(6)))
  end

  it 'does not export an erased contact or attribute their order through retained IDs' do
    paid
    conversation.contact.update!(additional_attributes: { umi_profile_redacted: true })
    expect(report[:paid_order_evidence]).to be_empty
    expect(report[:workflow_candidates]).to be_empty
    expect(report[:coverage][:redacted_paid_events]).to eq(1)
  end
end
