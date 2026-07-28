require 'rails_helper'

describe Umi::Fbig::ConversationReconService do
  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
  end

  let!(:account) { create(:account) }
  let!(:channel) do
    create(:channel_instagram_fb_page, account: account, page_id: 'page-1', instagram_id: 'ig-1')
  end
  let!(:inbox) { create(:inbox, channel: channel, account: account) }
  let(:api) { double }
  let(:service) { described_class.new(channel) }

  # Koala returns GraphCollection pages; a plain Array (no next_page) reads as
  # a single page in the service's pagination loop.
  def thread_item(id, updated_at)
    { 'id' => id, 'updated_time' => updated_at.iso8601 }
  end

  def message_item(mid, created_at, from: 'customer-1')
    { 'id' => mid, 'created_time' => created_at.iso8601, 'from' => { 'id' => from } }
  end

  def stub_threads(platform, items)
    allow(api).to receive(:get_connections)
      .with('page-1', 'conversations', hash_including(platform: platform))
      .and_return(items)
  end

  def stub_messages(thread_id, items)
    allow(api).to receive(:get_connections)
      .with(thread_id, 'messages', anything)
      .and_return(items)
  end

  describe 'detection' do
    before { stub_threads('instagram', []) }

    it 'reports mids Meta has that Chatwoot does not, with direction and sender' do
      allow(Rails.logger).to receive(:warn).and_call_original
      stub_threads('messenger', [thread_item('t-1', 1.hour.ago)])
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, conversation: conversation, account: account, inbox: inbox, source_id: 'mid-present')
      stub_messages('t-1', [
                      message_item('mid-present', 2.hours.ago),
                      message_item('mid-lost', 3.hours.ago, from: 'customer-9')
                    ])

      service.perform

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_missing platform=messenger thread=t-1 mid=mid-lost .*direction=in sender=customer-9/))
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger threads=1 mids=2 missing=1/))
    end

    it 'labels a missing outbound mid near an existing outgoing row as multipart-suspect' do
      allow(Rails.logger).to receive(:warn).and_call_original
      stub_threads('messenger', [thread_item('t-1', 1.hour.ago)])
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, :outgoing, conversation: conversation, account: account, inbox: inbox,
                                  source_id: 'mid-last-part', created_at: 2.hours.ago)
      stub_messages('t-1', [message_item('mid-first-part', 2.hours.ago - 30.seconds, from: 'page-1')])

      service.perform

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/mid=mid-first-part .*direction=out sender=page-1 suspect=multipart/))
    end

    it 'excludes messages inside the recent-grace period' do
      allow(Rails.logger).to receive(:info).and_call_original
      stub_threads('messenger', [thread_item('t-1', 1.minute.ago)])
      stub_messages('t-1', [message_item('mid-in-flight', 2.minutes.ago)])

      service.perform

      expect(Rails.logger).to have_received(:info)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger threads=1 mids=0 missing=0/))
    end

    it 'uses an inclusive explicit lower bound for post-cutoff checkpoints' do
      cutoff = Time.zone.parse('2026-07-25 19:00:00 UTC')
      grace_end = cutoff + 2.hours
      checkpoint = described_class.new(
        channel,
        window_start: cutoff,
        grace_end: grace_end
      )
      allow(Rails.logger).to receive(:warn).and_call_original
      stub_threads('messenger', [thread_item('t-1', grace_end)])
      stub_messages('t-1', [
                      message_item('mid-before-cutoff', cutoff - 1.second),
                      message_item('mid-at-cutoff', cutoff),
                      message_item('mid-after-cutoff', cutoff + 1.second)
                    ])

      checkpoint.perform

      expect(checkpoint.window_start).to eq(cutoff)
      expect(checkpoint.grace_end).to eq(grace_end)
      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger threads=1 mids=2 missing=2/))
      expect(Rails.logger).not_to have_received(:warn)
        .with(a_string_matching(/mid=mid-before-cutoff/))
    end

    it 'rejects an empty reconciliation interval before Meta access' do
      cutoff = Time.zone.parse('2026-07-25 19:00:00 UTC')

      expect do
        described_class.new(channel, window_start: cutoff, grace_end: cutoff)
      end.to raise_error(ArgumentError, 'reconciliation window must be nonempty')
      expect(api).not_to have_received(:get_connections)
    end

    it 'does not stop the thread scan on a single out-of-window straggler' do
      stub_threads('messenger', [
                     thread_item('t-new', 1.hour.ago),
                     thread_item('t-old', 10.days.ago),
                     thread_item('t-new-2', 2.hours.ago)
                   ])
      stub_messages('t-new', [])
      stub_messages('t-new-2', [])

      service.perform

      expect(api).to have_received(:get_connections).with('t-new-2', 'messages', anything)
    end

    it 'stops the thread scan after consecutive out-of-window threads' do
      stub_threads('messenger', [
                     thread_item('t-old-1', 10.days.ago),
                     thread_item('t-old-2', 10.days.ago),
                     thread_item('t-old-3', 10.days.ago),
                     thread_item('t-after-stop', 1.hour.ago)
                   ])

      service.perform

      expect(api).not_to have_received(:get_connections).with('t-after-stop', 'messages', anything)
    end
  end

  describe 'pagination caps' do
    let(:fake_page_class) do
      Class.new(Array) do
        attr_accessor :paging, :next_page

        def respond_to_missing?(name, include_private = false)
          %i[paging next_page].include?(name) || super
        end
      end
    end

    before do
      stub_threads('instagram', [])
      stub_threads('messenger', [thread_item('t-1', 1.hour.ago)])
    end

    def chained_pages(count)
      pages = Array.new(count) do |index|
        page = fake_page_class.new([message_item("mid-#{index}", (index + 1).hours.ago)])
        page.paging = { 'next' => 'cursor' }
        page
      end
      pages.each_cons(2) { |page, next_page| page.next_page = next_page }
      pages.last.paging = {}
      pages.first
    end

    it 'counts a caps_hit when the page budget runs out with pages unread' do
      allow(Rails.logger).to receive(:warn).and_call_original
      stub_messages('t-1', chained_pages(described_class::MAX_MESSAGE_PAGES + 1))

      service.perform

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger .*caps_hit=1/))
    end

    it 'does not count a caps_hit when the collection ends exactly at the budget' do
      allow(Rails.logger).to receive(:warn).and_call_original
      stub_messages('t-1', chained_pages(described_class::MAX_MESSAGE_PAGES))

      service.perform

      expect(Rails.logger).not_to have_received(:warn)
        .with(a_string_matching(/caps_hit=1/))
    end
  end

  describe 'failure semantics' do
    it 'emits a summary and continues to the next platform when a thread fails' do
      allow(Rails.logger).to receive(:warn).and_call_original
      stub_threads('messenger', [thread_item('t-1', 1.hour.ago)])
      allow(api).to receive(:get_connections).with('t-1', 'messages', anything)
                                             .and_raise(Koala::Facebook::ClientError.new(500, '', { 'message' => 'boom' }))
      stub_threads('instagram', [])

      service.perform

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger .*threads_failed=1/))
    end

    it 'stands down without raising on an auth error and skips the remaining platform' do
      allow(Rails.logger).to receive(:warn).and_call_original
      allow(api).to receive(:get_connections)
        .with('page-1', 'conversations', hash_including(platform: 'messenger'))
        .and_raise(Koala::Facebook::AuthenticationError.new(401, 'bad token'))

      expect { service.perform }.not_to raise_error

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger .*error=Koala::Facebook::AuthenticationError/))
      expect(api).not_to have_received(:get_connections)
        .with('page-1', 'conversations', hash_including(platform: 'instagram'))
    end

    it 'emits the summary and re-raises once on a non-auth platform failure' do
      allow(Rails.logger).to receive(:warn).and_call_original
      allow(Rails.logger).to receive(:info).and_call_original
      allow(api).to receive(:get_connections)
        .with('page-1', 'conversations', hash_including(platform: 'messenger'))
        .and_raise(Koala::Facebook::ServerError.new(500, 'transient'))
      stub_threads('instagram', [])

      expect { service.perform }.to raise_error(Koala::Facebook::ServerError)

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_matching(/stage=reconcile_summary platform=messenger .*error=Koala::Facebook::ServerError/))
      expect(Rails.logger).to have_received(:info)
        .with(a_string_matching(/stage=reconcile_summary platform=instagram/))
    end
  end

  describe 'healing' do
    before { stub_threads('instagram', []) }

    it 'replays missing inbound mids through the heal service when enabled' do
      stub_threads('messenger', [thread_item('t-1', 1.hour.ago)])
      stub_messages('t-1', [message_item('mid-lost', 3.hours.ago)])
      heal_service = instance_double(Umi::Fbig::MessageHealService, heal: :healed)
      allow(Umi::Fbig::MessageHealService).to receive(:new).and_return(heal_service)

      with_modified_env UMI_FBIG_RECON_HEAL: 'true' do
        service.perform
      end

      expect(heal_service).to have_received(:heal).with('mid-lost')
    end

    it 'does not heal when the flag is off' do
      stub_threads('messenger', [thread_item('t-1', 1.hour.ago)])
      stub_messages('t-1', [message_item('mid-lost', 3.hours.ago)])
      allow(Umi::Fbig::MessageHealService).to receive(:new)

      service.perform

      expect(Umi::Fbig::MessageHealService).not_to have_received(:new)
    end
  end
end
