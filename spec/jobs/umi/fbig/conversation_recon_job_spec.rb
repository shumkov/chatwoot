require 'rails_helper'

describe Umi::Fbig::ConversationReconJob do
  before do
    stub_request(:post, /graph\.facebook\.com/)
  end

  let!(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram_fb_page, account: account, page_id: 'page-1') }

  it 'runs the recon service for every facebook page channel' do
    service = instance_double(Umi::Fbig::ConversationReconService, perform: nil)
    allow(Umi::Fbig::ConversationReconService).to receive(:new).with(channel).and_return(service)

    described_class.perform_now

    expect(service).to have_received(:perform)
  end

  it 'no-ops when the kill switch is set' do
    allow(Umi::Fbig::ConversationReconService).to receive(:new)

    with_modified_env UMI_FBIG_RECON_DISABLED: 'true' do
      described_class.perform_now
    end

    expect(Umi::Fbig::ConversationReconService).not_to have_received(:new)
  end

  it 'isolates per-channel failures but still surfaces them for retry' do
    other_channel = create(:channel_facebook_page, account: account)
    services = {}
    [channel, other_channel].each do |ch|
      services[ch] = instance_double(Umi::Fbig::ConversationReconService)
      allow(Umi::Fbig::ConversationReconService).to receive(:new).with(ch).and_return(services[ch])
    end
    allow(services[channel]).to receive(:perform).and_raise(Koala::Facebook::ServerError.new(500, 'transient'))
    allow(services[other_channel]).to receive(:perform)

    expect { described_class.perform_now }.to raise_error(Koala::Facebook::ServerError)
    expect(services[other_channel]).to have_received(:perform)
  end
end
