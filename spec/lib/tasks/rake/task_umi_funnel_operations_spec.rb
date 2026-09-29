# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Rake::Task do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:actor) { create(:user, account: account) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: '2026-01-01T00:00:00Z' do
      example.run
    end
  end

  it 'classifies by internal ID and returns only the recorded event and status' do
    task = described_class['umi:funnel:qualify']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, CONVERSATION_ID: conversation.id.to_s, ACTOR_ID: actor.id.to_s,
                      STATUS: 'engaged', REASON: 'Sizing conversation', MESSAGE_IDS: '' do
      expect { task.invoke }.to output(satisfy { |output| JSON.parse(output)['status'] == 'engaged' }).to_stdout
    end
    expect(conversation.reload.custom_attributes['umi_sales_status']).to eq('engaged')
  end

  it 'durably queues bounded requested orders without an inline Shopify read' do
    create(:integrations_hook, :shopify, account: account, reference_id: 'umi.myshopify.com')
    task = described_class['umi:funnel:reconcile']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, ORDER_IDS: '123,123,456', SINCE: nil do
      expect { task.invoke }.to output("{\"requested\":2}\n").to_stdout
    end
    expect(Umi::ShopifyOrderFinancialState.count).to eq(2)
  end

  it 'prints an aggregate report without contact data' do
    task = described_class['umi:funnel:report']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, SINCE: 1.day.ago.iso8601, UNTIL: nil do
      expect { task.invoke }.to output(satisfy { |output| JSON.parse(output)['paid_occurrences'].zero? }).to_stdout
    end
  end

  it 'prints only deterministic operational aggregates for the requested period and inbox' do
    conversation
    task = described_class['umi:funnel:operations']
    task.reenable
    with_modified_env ACCOUNT_ID: account.id.to_s, SINCE: '2026-09-01T00:00:00Z', UNTIL: '2026-09-08T00:00:00Z',
                      AS_OF: '2026-09-09T00:00:00Z', INBOX_ID: conversation.inbox_id.to_s do
      expect { task.invoke }.to output(satisfy do |output|
        data = JSON.parse(output)
        data['coverage']['inbox_ids'] == [conversation.inbox_id] && data['as_of'] == '2026-09-09T00:00:00.000000Z' &&
          output.exclude?(conversation.contact.name)
      end).to_stdout
    end
  end
end
