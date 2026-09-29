# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Paid-ad referral continuity' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '12345') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:actor) { create(:user, account: account) }
  let(:referral) { { 'source' => 'ADS', 'ad_id' => '111', 'ads_context_data' => { 'ad_title' => 'First ad' } } }
  let(:source) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                     content: 'First tapped option', content_attributes: { referral: referral }, created_at: 2.minutes.ago)
  end
  let(:evidence) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                     content: 'Can I try the dress?', created_at: 1.minute.ago)
  end
  let(:service) { instance_double(Umi::Meta::AdWelcomeMessageService) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z',
                      UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: account.id.to_s do
      example.run
    end
  end

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Umi::Meta::AdWelcomeMessageService).to receive(:new).and_return(service)
    allow(service).to receive(:fetch).and_return({})
    allow(Umi::Meta::AdContextNotePresenter).to receive(:new).and_return(instance_double(Umi::Meta::AdContextNotePresenter, body: 'Ad details'))
    Umi::Funnel::EventRecorder.capture_message(source)
  end

  it 'retains the first-message ad when the shopper qualifies on a later organic message' do
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                            reason: 'Asked about fitting', evidence_message_ids: [evidence.id]).perform
    expect(Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified').payload)
      .to include('ad_id' => '111', 'referral_message_id' => source.id)
  end

  it 'does not borrow a later tap with the same timestamp as qualification evidence' do
    evidence
    later = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                             created_at: evidence.created_at, content_attributes: { referral: referral.merge('ad_id' => '222') })
    Umi::Funnel::EventRecorder.capture_message(later)
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                            reason: 'Asked about fitting', evidence_message_ids: [evidence.id]).perform
    expect(Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified').payload['ad_id']).to eq('111')
  end

  it 'posts one source-specific note for each new ad tap and none for a retry' do
    later = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                             content: 'Second option', content_attributes: { referral: referral.merge('ad_id' => '222') })
    Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
    Umi::Meta::AdContextNoteJob.perform_now(conversation.id, later.id)
    Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
    notes = conversation.messages.select { |message| message.content_attributes['umi_ad_context'] }
    expect(notes.map { |message| message.content_attributes['umi_ad_context']['source_message_id'] }).to contain_exactly(source.id, later.id)
    expect(service).to have_received(:fetch).with('111').once
    expect(service).to have_received(:fetch).with('222').once
  end

  it 'adds paid-source visibility without replacing unrelated labels or the latest sidebar' do
    conversation.update!(label_list: ['intent-sizing'])
    later = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                             content_attributes: { referral: referral.merge('ad_id' => '222') })
    Umi::FbigAdAttribution.promote(later, later.content_attributes['referral'])
    Umi::FbigAdAttribution.promote(source, referral)
    expect(conversation.reload.custom_attributes['meta_ad_id']).to eq('222')
    expect(conversation.label_list).to match_array(%w[intent-sizing source-paid-ads])
    expect(conversation.custom_attributes['umi_sales_status']).not_to eq('qualified')
  end

  %w[deleted recovered private changed_referral changed_identity missing_source].each do |change|
    it "does not qualify from a #{change} earlier ad source" do
      evidence
      case change
      when 'deleted' then source.update!(content_attributes: source.content_attributes.merge('deleted' => true))
      when 'recovered' then source.update!(content_attributes: source.content_attributes.merge('umi_recovered' => true))
      when 'private' then source.update!(private: true)
      when 'changed_referral' then source.update!(content_attributes: { referral: referral.merge('ad_id' => '222') })
      when 'changed_identity' then contact_inbox.update!(source_id: '54321')
      when 'missing_source' then source.destroy!
      end
      Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                              reason: 'Asked about fitting', evidence_message_ids: [evidence.id]).perform
      expect(Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified').payload).not_to have_key('ad_id')
    end
  end

  it 'freezes the selected source and keeps the earlier ID at an equal timestamp' do
    evidence.update!(created_at: source.created_at)
    transition = Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                                         reason: 'Asked about fitting', evidence_message_ids: [evidence.id])
    transition.perform
    event = Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified')
    original = event.attributes
    later = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                             content_attributes: { referral: referral.merge('ad_id' => '222') })
    Umi::Funnel::EventRecorder.capture_message(later)
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                            reason: 'Additional evidence', evidence_message_ids: [later.id]).perform
    expect(event.reload.attributes).to eq(original)
    expect(event.payload).to include('ad_id' => '111', 'referral_message_id' => source.id)
  end

  it 'pins a delayed lookup to its own ad and tapped text even after a newer referral' do
    allow(service).to receive(:fetch).with('111') do
      later = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                               content: 'Second tapped option', content_attributes: { referral: referral.merge('ad_id' => '222') })
      Umi::FbigAdAttribution.promote(later, later.content_attributes['referral'])
      {}
    end
    Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
    note = conversation.messages.detect { |message| message.content_attributes['umi_ad_context'] }
    expect(note.content).to include("message ##{source.id}", source.created_at.utc.iso8601, 'ad 111')
    expect(note.content_attributes['umi_ad_context']).to include('ad_id' => '111', 'source_message_id' => source.id)
    expect(Umi::Meta::AdContextNotePresenter).to have_received(:new).with({}, tapped_title: 'First tapped option')
    expect(conversation.reload.custom_attributes['meta_ad_id']).to eq('222')
  end

  it 'does not let historical notes suppress a new source, or clear another source failure' do
    old = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, private: true,
                           content_attributes: { umi_ad_context: { ad_id: '111', status: 'ok' } })
    other = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, private: true,
                             content_attributes: { umi_ad_context: { source_message_id: source.id + 100, ad_id: '222', status: 'error' } })
    Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
    expect(conversation.messages.count { |message| message.content_attributes['umi_ad_context'] }).to eq(3)
    expect(Message.exists?(old.id)).to be(true)
    expect(Message.exists?(other.id)).to be(true)
  end

  %w[deleted erased reassigned recovered].each do |change|
    it "does not post success or failure after the source is #{change} during a lookup" do
      allow(service).to receive(:fetch) do
        case change
        when 'deleted' then source.update!(content_attributes: { deleted: true })
        when 'erased' then Umi::Shopify::CustomerRedactionService.new(contact).perform
        when 'reassigned' then conversation.update!(contact: create(:contact, account: account))
        when 'recovered' then source.update!(content_attributes: source.content_attributes.merge('umi_recovered' => true))
        end
        raise Umi::Meta::AdWelcomeMessageService::Unavailable, 'lookup failed'
      end
      Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
      expect(conversation.messages.none? { |message| message.content_attributes['umi_ad_context'] }).to be(true)
    end
  end

  %w[outgoing private recovered deleted malformed redacted].each do |change|
    it "does not promote or enqueue #{change} referrals even with old sidebar attribution" do
      conversation.update!(custom_attributes: { meta_ad_id: '999' })
      case change
      when 'outgoing' then source.update!(message_type: :outgoing)
      when 'private' then source.update!(private: true)
      when 'recovered' then source.update!(content_attributes: source.content_attributes.merge('umi_recovered' => true))
      when 'deleted' then source.update!(content_attributes: source.content_attributes.merge('deleted' => true))
      when 'malformed' then source.update!(content_attributes: { referral: { source: 'ADS', ad_id: 'invalid' } })
      when 'redacted' then contact.update!(additional_attributes: { umi_profile_redacted: true })
      end
      expect { Umi::FbigAdAttribution.promote(source, source.content_attributes['referral']) }
        .not_to have_enqueued_job(Umi::Meta::AdContextNoteJob)
      expect(conversation.reload.custom_attributes['meta_ad_id']).to eq('999')
      expect(conversation.label_list).not_to include('source-paid-ads')
    end
  end

  it 'keeps attribution active without enabling the managed label on an unrolled account' do
    with_modified_env UMI_CUSTOMER_CONTEXT_ACCOUNT_IDS: '' do
      expect { Umi::FbigAdAttribution.promote(source, referral) }
        .to have_enqueued_job(Umi::Meta::AdContextNoteJob).with(conversation.id, source.id)
      expect(conversation.reload.custom_attributes['meta_ad_id']).to eq('111')
      expect(conversation.label_list).not_to include('source-paid-ads')
    end
  end

  it 'removes only the derived source label during erasure' do
    conversation.update!(label_list: ['intent-sizing'])
    Umi::FbigAdAttribution.promote(source, referral)
    Umi::FbigAdAttribution.purge_for(contact)
    expect(conversation.reload.label_list).to eq(['intent-sizing'])
    expect(conversation.cached_label_list_array).to eq(['intent-sizing'])
    expect(source.reload.content_attributes).not_to have_key('referral')
  end

  it 'keeps a delayed failure attached to the old source after a new tap' do
    allow(service).to receive(:fetch).with('111') do
      later = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming,
                               content_attributes: { referral: referral.merge('ad_id' => '222') })
      Umi::FbigAdAttribution.promote(later, later.content_attributes['referral'])
      raise Umi::Meta::AdWelcomeMessageService::Unavailable, 'lookup failed'
    end
    Umi::Meta::AdContextNoteJob.perform_now(conversation.id, source.id)
    note = conversation.messages.detect { |message| message.content_attributes['umi_ad_context'] }
    expect(note.content_attributes['umi_ad_context']).to include('ad_id' => '111', 'source_message_id' => source.id, 'status' => 'error')
    expect(note.content).to include('ad 111', "message ##{source.id}")
  end

  it 'does not borrow an ad from another conversation with the same contact' do
    source.update!(content_attributes: {})
    other = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    tap = create(:message, account: account, inbox: inbox, conversation: other, message_type: :incoming,
                           content_attributes: { referral: referral }, created_at: source.created_at)
    Umi::Funnel::EventRecorder.capture_message(tap)
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                            reason: 'Asked about fitting', evidence_message_ids: [evidence.id]).perform
    expect(Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified').payload).not_to have_key('ad_id')
  end

  it 'does not export a conflicting channel identity by selecting only its first evidence message' do
    Umi::Funnel::EventRecorder.capture_message(evidence)
    conversation.update!(additional_attributes: { type: 'instagram_direct_message' })
    other = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                            reason: 'Asked about fitting', evidence_message_ids: [evidence.id, other.id]).perform
    payload = Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified').payload
    expect(payload).not_to have_key('messaging_channel')
    expect(payload).not_to have_key('ad_id')
  end

  it 'does not export a prior scoped identity after the inbox contact identity changes' do
    Umi::Funnel::EventRecorder.capture_message(evidence)
    contact_inbox.update!(source_id: '54321')
    Umi::Funnel::ConversationTransition.new(conversation: conversation, actor: actor, status: 'qualified',
                                            reason: 'Asked about fitting', evidence_message_ids: [evidence.id]).perform
    event = Umi::ConversationEvent.find_by!(event_type: 'conversation_qualified')
    expect(event.payload['scoped_user_id']).to be_nil
  end
end
