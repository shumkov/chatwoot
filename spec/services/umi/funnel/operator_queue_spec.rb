# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Umi::Funnel::OperatorQueue' do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, working_hours_enabled: false) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, created_at: 10.days.ago) }
  let(:agent) { create(:user, account: account) }
  let(:start) { Time.iso8601('2026-10-01T13:55:00Z') }
  let(:as_of) { Time.iso8601('2026-10-02T02:05:00Z') }
  let(:queue) { Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start, as_of: as_of) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-09-01T00:00:00Z',
                      UMI_FUNNEL_CLASSIFIER_MODE: 'off', UMI_FUNNEL_CLASSIFIER_INBOX_IDS: inbox.id.to_s do
      ApplicationRecord.transaction(isolation: :repeatable_read) do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end

  it 'keeps the 20:55 burst timer through snooze, private, automated, failed and bot replies until 09:05' do
    first = create(:message, conversation: conversation, message_type: :incoming, created_at: start, content: 'Private customer text')
    create(:message, conversation: conversation, message_type: :incoming, created_at: start + 1.minute)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, private: true, created_at: start + 2.minutes)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: :failed, created_at: start + 3.minutes)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent,
                     content_attributes: { automation_rule_id: 1 }, created_at: start + 4.minutes)
    create(:message, conversation: conversation, message_type: :outgoing, sender: create(:agent_bot), created_at: start + 5.minutes)
    conversation.update!(status: :snoozed, snoozed_until: as_of + 1.day)
    result = queue.index
    expect(result[:conversations].sole[:waiting]).to include(message_id: first.id, business_seconds: 600, first_response: true)
    expect(result[:business_open]).to be true
    expect(result.to_json).not_to include('Private customer text', conversation.contact.email)
  end

  it 'starts an overnight message at zero and reaches ten minutes at 09:10 every day' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: Time.iso8601('2026-10-03T16:00:00Z'))
    result = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start, as_of: Time.iso8601('2026-10-04T02:10:00Z')).index
    expect(result[:conversations].sole[:waiting][:business_seconds]).to eq(600)
    expect(Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start, as_of: start + 5.minutes).index[:business_open]).to be false
  end

  it 'keeps old unanswered history available without activating reminders or carrying its timer into a resumed chat' do
    old = create(:message, conversation: conversation, message_type: :incoming, created_at: start - 90.days)
    expect(queue.index[:conversations].sole).to include(active_since: nil, waiting: nil)
    fresh = create(:message, conversation: conversation, message_type: :incoming, created_at: as_of - 2.minutes)
    row = queue.show(conversation.reload.display_id)[:conversation]
    expect(row).to include(active_since: fresh.created_at.utc.iso8601(6), waiting: include(message_id: fresh.id, business_seconds: 120))
    expect(row[:messages].pluck(:id)).to include(old.id, fresh.id)
  end

  it 'does not reactivate history through private notes, bots, automation, recovered messages, views or labels' do
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, private: true, created_at: start)
    create(:message, conversation: conversation, message_type: :outgoing, sender: create(:agent_bot), created_at: start)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent,
                     content_attributes: { automation_rule_id: 1 }, created_at: start)
    create(:message, conversation: conversation, message_type: :incoming, created_at: start,
                     content_attributes: { umi_recovered: true })
    create(:message, conversation: conversation, message_type: :incoming, created_at: start,
                     content_attributes: { deleted: true })
    conversation.update!(label_list: ['support-size'], agent_last_seen_at: as_of)
    expect(queue.index[:conversations].sole[:active_since]).to be_nil
  end

  %i[sent failed].each do |delivery|
    it "reactivates an old chat on a #{delivery} public human message without inventing an incoming timer" do
      create(:message, conversation: conversation, message_type: :incoming, created_at: start - 1.day)
      create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: delivery, created_at: start)
      expect(queue.index[:conversations].sole).to include(active_since: start.utc.iso8601(6), waiting: nil)
    end
  end

  it 'invalidates cached decisions when the activation boundary changes and preserves prior reply history' do
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, created_at: start - 1.day)
    create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    original = queue.index[:conversations].sole
    later = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start + 1.second, as_of: as_of).index[:conversations].sole
    expect(original[:waiting][:first_response]).to be false
    expect(later[:revision]).not_to eq(original[:revision])
    expect(later).to include(active_since: nil, waiting: nil)
  end

  it 'counts long waits using full business days plus the first and last partial days' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    finish = start + 3650.days + 12.hours + 10.minutes
    result = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start, as_of: finish).index
    expect(result[:conversations].sole[:waiting][:business_seconds]).to eq((3650 * 43_200) + 600)
  end

  [
    ['2026-10-01T00:00:00Z', '2026-10-01T01:59:59Z', 0],
    ['2026-10-01T00:00:00Z', '2026-10-01T16:00:00Z', 43_200],
    ['2026-10-01T15:00:00Z', '2026-10-01T16:00:00Z', 0],
    ['2026-10-01T15:00:00Z', '2026-10-02T01:59:59Z', 0]
  ].each do |incoming_at, checked_at, expected|
    it "counts #{expected} working seconds between #{incoming_at} and #{checked_at}" do
      incoming = Time.iso8601(incoming_at)
      create(:message, conversation: conversation, message_type: :incoming, created_at: incoming)
      result = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: incoming, as_of: Time.iso8601(checked_at)).index
      expect(result[:conversations].sole[:waiting][:business_seconds]).to eq(expected)
    end
  end

  it 'ends a factual wait on even a partial successful human reply and gives the next burst a new identity' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    reply = create(:message, conversation: conversation, message_type: :outgoing, sender: agent, created_at: start + 1.minute,
                             content: 'Here is one answer; I will check the other question')
    expect(queue.index[:conversations].sole[:waiting]).to be_nil
    next_message = create(:message, conversation: conversation, message_type: :incoming, created_at: start + 2.minutes)
    expect(queue.index[:conversations].sole[:waiting]).to include(message_id: next_message.id, first_response: false)
    expect(queue.show(conversation.reload.display_id)[:conversation][:messages].pluck(:id)).to include(reply.id)
  end

  it 'makes recovered chronology explicit but allows a fresh wait after a verified human reply' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start - 1.day,
                     content_attributes: { umi_recovered: true })
    expect(queue.index[:conversations].sole).to include(chronology: 'unverifiable', waiting: nil)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, created_at: start - 1.hour)
    fresh = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    expect(queue.index[:conversations].sole).to include(chronology: 'available', waiting: include(message_id: fresh.id, business_seconds: 600))
  end

  it 'keeps the live waiting timer when recovered incoming history arrives later' do
    live = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    create(:message, conversation: conversation, message_type: :incoming, created_at: start + 1.minute,
                     content_attributes: { umi_recovered: true })
    expect(queue.index[:conversations].sole).to include(chronology: 'available', waiting: include(message_id: live.id, business_seconds: 600))
  end

  it 'starts a new verifiable lower bound after recovered incoming history without requiring a human reply' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start - 1.minute,
                     content_attributes: { umi_recovered: true })
    live = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    expect(queue.index[:conversations].sole).to include(chronology: 'available', waiting: include(message_id: live.id, business_seconds: 600))
  end

  it 'does not carry a live timer across a recovered human reply but accepts the next live incoming message' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start - 2.minutes)
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, created_at: start - 1.minute,
                     content_attributes: { umi_recovered: true })
    expect(queue.index[:conversations].sole).to include(chronology: 'unverifiable', waiting: nil)
    live = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    expect(queue.index[:conversations].sole).to include(chronology: 'available', waiting: include(message_id: live.id, first_response: false))
  end

  it 'keeps live waiting through recovered bot, private and failed messages' do
    live = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    create(:message, conversation: conversation, message_type: :outgoing, sender: create(:agent_bot), created_at: start + 1.minute,
                     content_attributes: { umi_recovered: true })
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, private: true, created_at: start + 2.minutes,
                     content_attributes: { umi_recovered: true })
    create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: :failed, created_at: start + 3.minutes,
                     content_attributes: { umi_recovered: true })
    expect(queue.index[:conversations].sole).to include(chronology: 'available', waiting: include(message_id: live.id))
  end

  it 'retains support and old unresolved backlog, but excludes spam and erased contacts from list and detail' do
    conversation.project_umi_sales_status!('not_sales')
    expect(queue.index[:conversations].sole[:sales_status]).to eq('not_sales')
    conversation.update!(label_list: ['spam'])
    expect(queue.index[:conversations]).to be_empty
    expect { queue.show(conversation.reload.display_id) }.to raise_error(ActiveRecord::RecordNotFound)
    conversation.update!(label_list: [])
    conversation.contact.update!(additional_attributes: { umi_profile_redacted: true })
    expect(queue.index[:conversations]).to be_empty
    expect { queue.show(conversation.reload.display_id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'includes recently resolved promises but excludes resolved conversations predating activation' do
    conversation.update!(status: :resolved)
    conversation.update!(updated_at: start - 1.second)
    expect(queue.index[:conversations]).to be_empty
    conversation.update!(updated_at: start)
    expect(queue.index[:conversations].sole[:status]).to eq('resolved')
  end

  it 'returns complete private and public history, omits deleted content and changes revision on edits and deletion' do
    messages = Array.new(55) do |index|
      create(:message, conversation: conversation, message_type: :incoming, content: "History #{index}", created_at: start - index.minutes)
    end
    note = create(:message, conversation: conversation, message_type: :outgoing, private: true, sender: agent, content: 'Promise', created_at: start)
    detail = queue.show(conversation.reload.display_id)[:conversation]
    expect(detail[:messages].size).to eq(56)
    expect(detail[:revision]).to eq(queue.index[:conversations].sole[:revision])
    note.update!(content: 'Changed promise')
    edited = queue.show(conversation.reload.display_id)[:conversation]
    expect(edited[:revision]).not_to eq(detail[:revision])
    messages.first.update!(content_attributes: { deleted: true })
    deleted = queue.show(conversation.reload.display_id)[:conversation]
    expect(deleted[:messages].pluck(:id)).not_to include(messages.first.id)
    expect(deleted[:revision]).not_to eq(edited[:revision])
    note.destroy!
    expect(queue.index[:conversations].sole[:revision]).not_to eq(deleted[:revision])
  end

  it 'binds contact facts, sync freshness, assignment and attachment changes to the revision' do
    message = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    revision = queue.index[:conversations].sole[:revision]
    conversation.contact.update!(custom_attributes: { umi_vip: 'yes' })
    detail = queue.show(conversation.reload.display_id)[:conversation]
    expect(detail[:customer][:facts]).to include('umi_vip' => 'yes')
    expect(detail[:revision]).not_to eq(revision)
    conversation.contact.update!(additional_attributes: { umi_klaviyo_sync: { status: 'stale' } })
    synced = queue.index[:conversations].sole[:revision]
    expect(synced).not_to eq(detail[:revision])
    conversation.update!(assignee: agent)
    assigned = queue.index[:conversations].sole
    expect(assigned[:assignee_name]).to eq(agent.name)
    expect(assigned[:revision]).not_to eq(synced)
    Attachment.create!(message: message, account: account, file_type: :image)
    expect(queue.index[:conversations].sole[:revision]).not_to eq(assigned[:revision])
  end

  it 'does not invalidate analysis when an operator views the chat or a read receipt arrives' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    reply = create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: :sent, created_at: start + 1.minute)
    detail = queue.show(conversation.reload.display_id)[:conversation]
    conversation.update!(agent_last_seen_at: as_of, updated_at: as_of)
    conversation.contact.update!(last_activity_at: as_of, updated_at: as_of)
    reply.update!(status: :read, updated_at: as_of)
    observed = queue.show(conversation.display_id)[:conversation]
    expect(observed[:revision]).to eq(detail[:revision])
    expect(observed[:messages]).to eq(detail[:messages])
  end

  it 'invalidates analysis when a resolved identity changes to another customer profile' do
    conversation.contact.update!(additional_attributes: { umi_klaviyo_profile_id: 'profile-one' })
    before = queue.index[:conversations].sole[:revision]
    conversation.contact.update!(additional_attributes: { umi_klaviyo_profile_id: 'profile-two' })
    expect(queue.index[:conversations].sole[:revision]).not_to eq(before)
  end

  it 'binds failed delivery and visibility changes to the revision and factual wait' do
    incoming = create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    reply = create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: :sent, created_at: start + 1.minute)
    before = queue.index[:conversations].sole[:revision]
    reply.update!(status: :failed)
    failed = queue.index[:conversations].sole
    expect(failed[:revision]).not_to eq(before)
    expect(failed[:waiting][:message_id]).to eq(incoming.id)
    reply.update!(private: true)
    expect(queue.index[:conversations].sole[:revision]).not_to eq(failed[:revision])
  end

  it 'returns attachment-only content as a string and excludes failed replies from factual completion' do
    incoming = create(:message, conversation: conversation, message_type: :incoming, content: nil, created_at: start)
    Attachment.create!(message: incoming, account: account, file_type: :image)
    failed = create(:message, conversation: conversation, message_type: :outgoing, sender: agent, status: :failed,
                              content: 'Not actually delivered', created_at: start + 1.minute)
    detail = queue.show(conversation.reload.display_id)[:conversation]
    serialized = JSON.parse(detail.to_json)
    expect(serialized['messages'].find { |row| row['id'] == incoming.id }).to include('content' => '', 'attachment_types' => ['image'])
    expect(serialized['messages'].find { |row| row['id'] == failed.id }).to include('delivery_status' => 'failed', 'human' => true)
    expect(serialized['waiting']['message_id']).to eq(incoming.id)
  end

  it 'includes labelled persisted commerce facts and changes revision when reconciliation changes' do
    link = Umi::ShopifyOrderAttribution.create!(account: account, conversation_id: conversation.id, contact_id: conversation.contact_id,
                                                shop_domain: 'example.myshopify.com', shopify_order_id: '1001', source: 'operator',
                                                attribution_state: 'verified', shopify_order_name: '#1001')
    state = Umi::ShopifyOrderFinancialState.create!(account: account, shop_domain: link.shop_domain, shopify_order_id: link.shopify_order_id,
                                                    reconciliation_requested_at: start, reconciled_at: start,
                                                    snapshot: { classification: 'paid', currency: 'THB', captured: '1000.00' })
    detail = queue.show(conversation.reload.display_id)[:conversation]
    expect(detail[:commerce][:basis]).to eq('persisted_shopify_reconciliation_not_live_verification')
    expect(detail[:commerce][:orders].sole[:payment][:facts]).to include('classification' => 'paid')
    state.update!(snapshot: { classification: 'refunded', currency: 'THB', captured: '1000.00', refunded: '1000.00' })
    expect(queue.index[:conversations].sole[:revision]).not_to eq(detail[:revision])
    state.update!(redacted_at: as_of, snapshot: {})
    expect(queue.show(conversation.reload.display_id)[:conversation][:commerce][:orders].sole[:payment]).to be_nil
  end

  it 'does not transfer embedded email bodies or treat service notifications as unanswered customer work' do
    email_inbox = create(:inbox, :with_email, account: account)
    email_conversation = create(:conversation, account: account, inbox: email_inbox)
    create(:message, conversation: email_conversation, inbox: email_inbox, message_type: :incoming, content_type: :incoming_email,
                     created_at: start, content_attributes: { email: { auto_reply: true, text_content: { full: 'Embedded private text' } } })
    with_modified_env UMI_FUNNEL_CLASSIFIER_INBOX_IDS: email_inbox.id.to_s do
      email_queue = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start, as_of: as_of)
      expect(email_queue.index[:conversations].sole[:waiting]).to be_nil
      expect(email_queue.index[:conversations].sole[:active_since]).to be_nil
      expect(email_queue.instance_variable_get(:@messages).values.flatten.sole.content_attributes.to_json).not_to include('Embedded private text')
    end
  end

  it 'exposes automatic email replies and invalidates weekly analysis when that fact changes' do
    email_inbox = create(:inbox, :with_email, account: account)
    email_conversation = create(:conversation, account: account, inbox: email_inbox)
    message = create(:message, conversation: email_conversation, inbox: email_inbox, message_type: :incoming, content_type: :incoming_email,
                               created_at: start, content_attributes: { email: { auto_reply: true } })
    with_modified_env UMI_FUNNEL_CLASSIFIER_INBOX_IDS: email_inbox.id.to_s do
      email_queue = Umi::Funnel::OperatorQueue.new(account_id: account.id, since: start, as_of: as_of)
      before = email_queue.show(email_conversation.reload.display_id)[:conversation]
      expect(JSON.parse(before.to_json)['messages'].sole).to include('id' => message.id, 'auto_reply' => true)
      expect(before).to include(active_since: nil, waiting: nil)

      message.update!(content_attributes: { email: { auto_reply: false } })
      after = email_queue.show(email_conversation.display_id)[:conversation]
      expect(JSON.parse(after.to_json)['messages'].sole).to include('auto_reply' => false)
      expect(after[:revision]).not_to eq(before[:revision])
      expect(after[:revision]).to eq(email_queue.index[:conversations].sole[:revision])
      expect(after[:waiting]).to include(message_id: message.id)
    end
  end

  it 'exposes false automatic-email flags for ordinary messages using the native predicate' do
    create(:message, conversation: conversation, message_type: :incoming, created_at: start)
    create(:message, conversation: conversation, message_type: :incoming, created_at: start + 1.minute,
                     content_attributes: { email: { auto_reply: true } })
    messages = JSON.parse(queue.show(conversation.reload.display_id).to_json).dig('conversation', 'messages')
    expect(messages.pluck('auto_reply')).to eq([false, false])
  end

  it 'does not skip a candidate when an earlier row leaves scope between keyset pages' do
    create_list(:conversation, 51, account: account, inbox: inbox)
    first = queue.index
    Conversation.find(first[:conversations].first[:id]).update!(label_list: ['spam'])
    second = queue.index(after_id: first[:next_after_id], through_id: first[:through_id])
    expect(first[:conversations].size).to eq(50)
    expect(first[:next_after_id]).to eq(first[:conversations].last[:id])
    expect(second[:conversations].size).to eq(1)
    expect(second[:next_after_id]).to be_nil
    expect(first[:conversations].pluck(:id) & second[:conversations].pluck(:id)).to be_empty
  end
end
