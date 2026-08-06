require 'rails_helper'

describe Umi::Fbig::ProfileRefreshJob do
  let(:channel) { create(:channel_facebook_page) }
  let(:inbox) { channel.inbox }
  let(:account) { inbox.account }
  let(:api) { double }

  let(:service) { instance_double(Umi::Fbig::ProfileEnrichmentService) }

  before do
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
    allow(api).to receive(:get_object).and_return({})
    allow(api).to receive(:get_connections).and_return([])
    allow(Umi::Fbig::ProfileEnrichmentService).to receive(:new).and_return(service)
  end

  def contact_with(name:, attrs: {})
    contact = create(:contact, account: account, name: name, additional_attributes: attrs)
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: "src-#{contact.id}")
    contact
  end

  # Postgres defaults ASC to NULLS LAST, which would sort the entire
  # never-checked backlog behind contacts already handled — the drain would
  # never start.
  it 'takes never-checked contacts before ones already checked' do
    checked = contact_with(name: 'Checked', attrs: { 'umi_profile_checked_at' => 1.day.ago.iso8601 })
    fresh = contact_with(name: 'Never checked')

    seen = []
    allow(service).to receive(:enrich) do |contact|
      seen << contact.id
      Umi::Fbig::ProfileEnrichmentService::Outcome.new(status: :unchanged)
    end

    described_class.new.perform('cap' => 1)

    expect(seen).to eq([fresh.id])
    expect(seen).not_to include(checked.id)
  end

  it 'never selects a contact whose erasure was requested' do
    contact_with(name: 'Redacted customer', attrs: { 'umi_profile_redacted' => true })

    expect(service).not_to receive(:enrich)

    described_class.new.perform
  end

  it 'does nothing when the kill switch is set' do
    contact_with(name: 'Instagram user 0001')

    expect(service).not_to receive(:enrich)

    with_modified_env UMI_FBIG_PROFILE_REFRESH_DISABLED: 'true' do
      described_class.new.perform
    end
  end

  it 'sweeps ledger rows past the retention window and ones orphaned by a deleted contact' do
    allow(service).to receive(:enrich).and_return(Umi::Fbig::ProfileEnrichmentService::Outcome.new(status: :unchanged))
    contact = contact_with(name: 'Instagram user 0002')
    stale = Umi::ProfileLedgerEntry.create!(run_id: 'old', contact_id: contact.id, attribute_name: 'name',
                                            evidence_source: 'profile_api', created_at: 120.days.ago)
    orphan = Umi::ProfileLedgerEntry.create!(run_id: 'old', contact_id: 0, attribute_name: 'name',
                                             evidence_source: 'profile_api', created_at: Time.current)

    described_class.new.perform

    expect(Umi::ProfileLedgerEntry.exists?(stale.id)).to be(false)
    expect(Umi::ProfileLedgerEntry.exists?(orphan.id)).to be(false)
  end
end
