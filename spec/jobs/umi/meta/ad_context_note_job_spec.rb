require 'rails_helper'

describe Umi::Meta::AdContextNoteJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                          custom_attributes: { 'meta_ad_id' => '120252251820030415', 'meta_ad_title' => 'Video_2' })
  end
  let(:payload) { JSON.parse(file_fixture('umi/meta_ad_creative.json').read) }
  let(:api) { instance_double(Koala::Facebook::API) }

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
    allow(api).to receive(:get_object).and_return(payload)
  end

  def note
    conversation.messages.reload.find { |m| m.content_attributes['umi_ad_context'].present? }
  end

  describe 'the note itself' do
    it 'posts a private note with no sender' do
      described_class.perform_now(conversation.id)

      expect(note).to have_attributes(private: true, message_type: 'outgoing', sender: nil)
      expect(note.content_attributes['umi_ad_context']).to include('status' => 'ok')
    end

    # Liquidable renders outgoing messages before create, private notes
    # included. {{user_full_name}} is Meta's own placeholder and not a Chatwoot
    # drop, so a rendered note would silently drop it and misrepresent what the
    # customer was shown.
    it 'stores Meta copy byte for byte, placeholders included' do
      described_class.perform_now(conversation.id)

      welcome = Umi::Meta::AdWelcomeMessageService.new('t').fetch('120252251820030415')
      expected = Umi::Meta::AdContextNotePresenter.new(welcome, tapped_title: nil).body

      expect(note.content).to eq(expected)
      expect(note.content).to include('{{user_full_name}}')
      expect(note.content).not_to include('{% raw %}', '{% endraw %}')
    end
  end

  # Private notes are outgoing messages, and outgoing messages normally satisfy
  # human_response? — which clears waiting_since, stamps first_reply_created_at
  # and writes ReportingEvent rows. That would take ad conversations out of the
  # Unattended folder and corrupt response-time reporting, which is the data
  # this whole line of work has to be measured on.
  describe 'reporting' do
    let!(:inbound) do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, content: '3. ขอแนะนำสินค้าขายดีของ UMI')
    end

    it 'leaves waiting_since, first reply and reporting events untouched' do
      conversation.update!(waiting_since: inbound.created_at, first_reply_created_at: nil)
      events = ReportingEvent.count

      expect { described_class.perform_now(conversation.id) }
        .not_to(change { conversation.reload.attributes.slice('waiting_since', 'first_reply_created_at') })
      expect(ReportingEvent.count).to eq(events)
    end

    # private:true alone carries this: update_waiting_since skips the whole
    # outgoing branch before human_response? is ever consulted. Each mutation
    # therefore has to clear private and vary the second axis, or it proves
    # nothing and passes for the wrong reason.
    [
      ['an agent-sent reply stamps the first reply', { sender_is_user: true }],
      ['a later agent reply clears waiting_since', { sender_is_user: true, first_reply: true }],
      ['an external echo counts as a human response', { echo: true }]
    ].each do |name, mutation|
      it "would break if the note were not private: #{name}" do
        conversation.update!(waiting_since: inbound.created_at,
                             first_reply_created_at: mutation[:first_reply] ? 1.hour.ago : nil)
        attributes = { account_id: account.id, inbox_id: inbox.id, message_type: :outgoing,
                       private: false, content: 'x' }
        attributes[:sender] = create(:user, account: account, role: :agent) if mutation[:sender_is_user]
        attributes[:content_attributes] = { external_echo: true } if mutation[:echo]

        conversation.messages.create!(attributes)

        expect(conversation.reload.waiting_since).to be_nil
      end
    end
  end

  describe 'delivery' do
    it 'is not sent to the customer' do
      described_class.perform_now(conversation.id)
      service = Facebook::SendOnFacebookService.new(message: note)
      allow(service).to receive(:perform_reply)

      service.perform

      expect(service).not_to have_received(:perform_reply)
    end
  end

  describe 'idempotency' do
    it 'posts once however many times it runs' do
      2.times { described_class.perform_now(conversation.id) }

      expect(conversation.messages.reload.count { |m| m.content_attributes['umi_ad_context'].present? }).to eq(1)
    end

    # content_attributes is a json column with a store coder, so its stored
    # value is a JSON string: `content_attributes::jsonb -> 'key'` matches
    # nothing at all and the guard would silently never fire. This example only
    # catches that because the note is persisted and read back.
    it 'recognises a note that has been through the database' do
      described_class.perform_now(conversation.id)
      persisted = Message.find(note.id)

      expect(persisted.content_attributes['umi_ad_context']).to be_present
      expect(Message.where("content_attributes::jsonb -> 'umi_ad_context' IS NOT NULL").count).to eq(0)
    end

    it 'does nothing when the conversation carries no ad attribution' do
      conversation.update!(custom_attributes: {})

      expect { described_class.perform_now(conversation.id) }.not_to(change { conversation.messages.count })
    end
  end

  describe 'failure' do
    before { allow(api).to receive(:get_object).and_raise(Koala::Facebook::ClientError.new(400, '{}')) }

    it 'says so in the thread rather than leaving the agent with nothing' do
      described_class.perform_now(conversation.id)

      expect(note.content).to include('Ad context unavailable')
      expect(note.content_attributes['umi_ad_context']).to include('status' => 'error')
    end

    # The failure has to arise outside the service to test anything: the service
    # converts everything it catches into Unavailable, so stubbing Koala can
    # never exercise the job's own catch-all. Raising from the presenter does.
    it 'reports failures that never reach Unavailable at all' do
      allow(api).to receive(:get_object).and_return(payload)
      allow(Umi::Meta::AdContextNotePresenter).to receive(:new).and_raise(NoMethodError, 'undefined method for nil')

      described_class.perform_now(conversation.id)

      expect(note.content).to include('Ad context unavailable', 'NoMethodError')
    end

    it 'raises when a Meta inbox has no page token, since that is a deployment fault' do
      channel.update!(page_access_token: '')

      described_class.perform_now(conversation.id)

      expect(note.content).to include('Ad context unavailable')
    end

    it 'posts one failure note, not one per attempt' do
      2.times { described_class.perform_now(conversation.id) }

      expect(conversation.messages.reload.count { |m| m.content_attributes['umi_ad_context'].present? }).to eq(1)
    end

    # A rate limit is transient. If the failure note blocked the real one, a
    # blip would leave the thread permanently claiming the ad is unreadable,
    # and the documented recovery path would do nothing.
    it 'still allows the real note once Meta recovers, and clears the failure note' do
      described_class.perform_now(conversation.id)
      expect(note.content_attributes['umi_ad_context']).to include('status' => 'error')
      allow(api).to receive(:get_object).and_return(payload)

      # No cleanup here on purpose: the failure note is left in place, because
      # whether the guard lets the real note through is the whole point.
      described_class.perform_now(conversation.id)

      notes = conversation.messages.reload.select { |m| m.content_attributes['umi_ad_context'].present? }
      expect(notes.map { |m| m.content_attributes.dig('umi_ad_context', 'status') }).to eq(['ok'])
    end
  end

  describe 'erasure' do
    it 'does not post if attribution was erased while the job was in flight' do
      allow(api).to receive(:get_object) do
        conversation.update!(custom_attributes: {})
        payload
      end

      described_class.perform_now(conversation.id)

      expect(note).to be_nil
    end
  end
end
