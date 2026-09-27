# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Rake::Task do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, email: 'person@example.com') }
  let(:actor) { create(:user, account: account) }
  let(:event) do
    Umi::ConversationEvent.record!(account_id: account.id, contact_id: contact.id, event_type: 'conversation_qualified',
                                   occurrence_key: 'qualification:1', occurred_at: 1.hour.ago, observed_at: Time.current, provenance: 'operator',
                                   payload: { 'messaging_channel' => 'messenger', 'page_id' => '123', 'scoped_user_id' => '456' })
  end
  let(:delivery) { event.conversion_deliveries.find_by!(destination: 'meta') }

  it 'previews an eligible delivery without printing customer identity or sending it' do
    task = described_class['umi:funnel:delivery']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, DELIVERY_ID: delivery.id.to_s, ACTION: 'preview',
                      UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 1.day.ago.utc.iso8601,
                      UMI_FUNNEL_META_ACCOUNT_ID: account.id.to_s, UMI_FUNNEL_META_PAGE_ID: '123', UMI_FUNNEL_META_DATASET_ID: '789' do
      expect { task.invoke }.to output(satisfy { |output|
        JSON.parse(output) == { 'delivery_id' => delivery.id, 'event_id' => event.id, 'destination' => 'meta',
                                'state' => 'pending', 'reason' => nil, 'attempt_count' => 0, 'last_error' => nil }
      }).to_stdout
    end
    expect(delivery.reload.payload).to be_present
    expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
  end

  it 'cannot act on another account delivery' do
    task = described_class['umi:funnel:delivery']
    task.reenable
    with_modified_env ACCOUNT_ID: create(:account).id.to_s, DELIVERY_ID: delivery.id.to_s, ACTION: 'dispatch' do
      expect { task.invoke }.to raise_error(ActiveRecord::RecordNotFound)
    end
    expect(delivery.reload.attempt_count).to eq(0)
  end

  it 'rejects unknown actions rather than calling arbitrary service methods' do
    task = described_class['umi:funnel:delivery']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, DELIVERY_ID: delivery.id.to_s, ACTION: 'destroy' do
      expect { task.invoke }.to raise_error(ArgumentError, /ACTION/)
    end
    expect(delivery.reload.state).to eq('pending')
  end

  it 'marks an interrupted attempt unknown without sending it again' do
    delivery.update!(state: 'sending', attempt_count: 1, attempted_at: 1.hour.ago)
    task = described_class['umi:funnel:delivery']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, DELIVERY_ID: delivery.id.to_s, ACTION: 'hold' do
      expect { task.invoke }.to output(satisfy { |output| JSON.parse(output)['state'] == 'unknown' }).to_stdout
    end
  end

  it 'binds only the existing matching profile and prints operational IDs' do
    client = instance_double(Umi::Funnel::KlaviyoClient, profile: { 'id' => 'PROFILE1', 'attributes' => { 'email' => contact.email } })
    allow(Umi::Funnel::KlaviyoClient).to receive(:new).and_return(client)
    task = described_class['umi:funnel:bind_profile']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, CONTACT_ID: contact.id.to_s, ACTOR_ID: actor.id.to_s,
                      PROFILE_ID: 'PROFILE1', REASON: 'Confirmed customer identity', UMI_FUNNEL_KLAVIYO_ACCOUNT_ID: account.id.to_s do
      expect { task.invoke }.to output("#{JSON.generate(contact_id: contact.id, profile_id: 'PROFILE1')}\n").to_stdout
    end
    expect(contact.reload.additional_attributes['umi_klaviyo_profile_id']).to eq('PROFILE1')
  end
end
