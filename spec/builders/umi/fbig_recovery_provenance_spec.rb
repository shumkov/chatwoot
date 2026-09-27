require 'rails_helper'

describe Umi::FbigRecoveryProvenance do
  let(:builder_class) do
    Class.new do
      def initialize(params)
        @params = params
      end

      private

      def message_params
        @params
      end
    end.prepend(described_class)
  end
  let(:params) do
    { inbox_id: 42, source_id: 'mid-1', message_type: :incoming,
      content_attributes: { in_reply_to_external_id: 'parent', referral: { source: 'ADS' } } }
  end
  let(:builder) { builder_class.new(params) }

  it 'preserves other ingestion attributes while marking the exact recovered source' do
    Umi::Fbig::RecoveryContext.set(inbox_id: 42, source_id: 'mid-1', source_created_at: '2026-07-21T10:00:00Z') do
      expect(builder.send(:message_params)[:content_attributes]).to eq(
        in_reply_to_external_id: 'parent', referral: { source: 'ADS' },
        umi_recovered: true, external_created_at: '2026-07-21T10:00:00Z'
      )
    end
  end

  it 'does not mark ordinary live ingestion when no recovery is active' do
    expect(builder.send(:message_params)).to eq(params)
  end

  it 'does not mark another inbox even when its provider message ID matches' do
    Umi::Fbig::RecoveryContext.set(inbox_id: 43, source_id: 'mid-1') do
      expect(builder.send(:message_params)).to eq(params)
    end
  end

  it 'does not mark another provider message in the same inbox' do
    Umi::Fbig::RecoveryContext.set(inbox_id: 42, source_id: 'mid-2') do
      expect(builder.send(:message_params)).to eq(params)
    end
  end

  it 'does not mark an outgoing echo as recovered customer evidence' do
    params[:message_type] = :outgoing
    Umi::Fbig::RecoveryContext.set(inbox_id: 42, source_id: 'mid-1') do
      expect(builder.send(:message_params)).to eq(params)
    end
  end
end
