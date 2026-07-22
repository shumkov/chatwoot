require 'rails_helper'

# Regression: one webhook POST can batch several events of different types —
# within one entry's messaging array or across entries (the controller
# enqueues the whole entry array as one job). `Webhooks::InstagramEventsJob#event_name`
# memoized the first event type seen anywhere in the job, so every later item
# was dispatched to the first item's handler:
#   * `[read, message]` — the message is routed to ReadStatusService, which
#     raises NoMethodError on the missing `read` key; the job dies through all
#     retries and the DM is permanently lost (Meta delivers webhooks once).
#   * `[message, read]` — the message commits first, then the mis-dispatched
#     read crashes the batch; the message survives but the job dead-letters.
describe Webhooks::InstagramEventsJob do
  subject(:instagram_webhook) { described_class }

  let!(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram_fb_page, account: account, instagram_id: 'chatwoot-app-user-id-1') }
  let!(:inbox) { create(:inbox, channel: channel, account: account, greeting_enabled: false) }
  let(:fb_object) { double }
  let(:sender_id) { 'ig-sender-id-1' }

  def messaging_read_item
    {
      'sender': { 'id': sender_id },
      'recipient': { 'id': 'chatwoot-app-user-id-1' },
      'timestamp': '2021-09-08T06:34:04+0000',
      'read': { 'mid': 'previously-sent-message-id' }
    }
  end

  def messaging_message_item(mid)
    {
      'sender': { 'id': sender_id },
      'recipient': { 'id': 'chatwoot-app-user-id-1' },
      'timestamp': '2021-09-08T06:34:05+0000',
      'message': { 'mid': mid, 'text': 'Hello after read receipt' }
    }
  end

  def entries_with(*messaging_items)
    [{ 'id': 'entry-id-1', 'time': '2021-09-08T06:34:04+0000', 'messaging': messaging_items }]
  end

  before do
    allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
    allow(fb_object).to receive(:get_object).and_return(
      { name: 'Jane', id: sender_id, username: 'jane_ig', profile_pic: nil }.with_indifferent_access
    )
  end

  it 'persists a message that arrives after a read receipt in the same batch' do
    entries = entries_with(messaging_read_item, messaging_message_item('mid-after-read'))

    expect { instagram_webhook.perform_now(entries) }.not_to raise_error

    expect(inbox.messages.count).to eq(1)
    expect(inbox.messages.last.content).to eq('Hello after read receipt')
  end

  it 'processes a read receipt that arrives after a message without crashing the batch' do
    entries = entries_with(messaging_message_item('mid-before-read'), messaging_read_item)

    expect { instagram_webhook.perform_now(entries) }.not_to raise_error

    expect(inbox.messages.count).to eq(1)
    expect(inbox.messages.last.content).to eq('Hello after read receipt')
  end

  it 'persists a message whose entry follows a read-receipt entry in the same job' do
    entries = [
      { 'id': 'entry-read', 'time': '2021-09-08T06:34:04+0000', 'messaging': [messaging_read_item] },
      { 'id': 'entry-message', 'time': '2021-09-08T06:34:05+0000', 'messaging': [messaging_message_item('mid-second-entry')] }
    ]

    expect { instagram_webhook.perform_now(entries) }.not_to raise_error

    expect(inbox.messages.count).to eq(1)
    expect(inbox.messages.last.content).to eq('Hello after read receipt')
  end
end
