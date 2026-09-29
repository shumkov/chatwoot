# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::ClassificationContext do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:as_of) { Time.current }
  let(:builder) { described_class.new(conversation, watermark: nil, cutoff: nil, boundary: 1.day.ago, as_of: as_of) }

  around do |example|
    with_modified_env UMI_FUNNEL_ACCOUNT_IDS: account.id.to_s, UMI_FUNNEL_STARTED_AT: 2.days.ago.utc.iso8601,
                      UMI_FUNNEL_CLASSIFIER_INBOX_IDS: conversation.inbox_id.to_s do
      example.run
    end
  end

  it 'marks old paid facts stale even when a stopped sync retained fresh status' do
    contact.update!(custom_attributes: { umi_funnel_stage: 'repeat', umi_paid_order_count: 2 },
                    additional_attributes: { umi_klaviyo_sync: { status: 'fresh', buyer_lifecycle: 'repeat',
                                                                 payment_snapshot_at: 3.hours.ago.iso8601 } })
    expect(builder.build[:customer]).to include(freshness: 'stale', facts: include('umi_paid_order_count' => 2))
  end

  it 'marks expired non-buyer segment membership stale at the captured observation time' do
    contact.update!(additional_attributes: { umi_klaviyo_sync: { status: 'fresh', buyer_lifecycle: 'non_buyer', payment_snapshot_at: as_of.iso8601,
                                                                 segments: { complete: true, observed_at: 16.minutes.ago.iso8601 } } })
    expect(builder.build[:customer][:freshness]).to eq('stale')
  end
end
