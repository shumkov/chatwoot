require 'rails_helper'

# Meta exposes a display name on Messenger participants but only a handle on
# Instagram ones, and the Conversations API answers for Instagram ids that the
# profile API refuses with error 230 ("user consent is required"). Resolving
# both platforms through one service is what lets an Instagram contact be named
# at all — see docs/UMI-FBIG-PROFILE-REFRESH-SPEC.md.
describe Umi::Fbig::ParticipantNameService do
  let(:channel) { create(:channel_facebook_page) }
  let(:api) { double }
  let(:service) { described_class.new(channel) }

  before do
    # Channel::FacebookPage subscribes to Meta on create.
    stub_request(:post, /graph\.facebook\.com/)
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
  end

  it 'reads the display name for messenger, and asks Meta for the messenger thread' do
    expect(api).to receive(:get_connections).with(
      channel.page_id, 'conversations',
      { platform: 'messenger', user_id: 'psid-1', fields: 'participants' }
    ).and_return([{ 'participants' => { 'data' => [{ 'id' => 'psid-1', 'name' => 'Somchai Prasert' }] } }])

    expect(service.name_for('psid-1')).to eq('Somchai Prasert')
  end

  # The Instagram participant carries no 'name' key at all, so reading the
  # messenger field here would silently resolve every Instagram contact to nil
  # and leave the placeholder in place.
  it 'reads the handle for instagram, where Meta returns no display name' do
    expect(api).to receive(:get_connections).with(
      channel.page_id, 'conversations',
      { platform: 'instagram', user_id: 'igsid-1', fields: 'participants' }
    ).and_return([{ 'participants' => { 'data' => [{ 'id' => 'igsid-1', 'username' => 'ploy.bkk' }] } }])

    expect(service.name_for('igsid-1', platform: :instagram)).to eq('ploy.bkk')
  end

  it 'returns nil when the thread holds no matching participant' do
    allow(api).to receive(:get_connections).and_return(
      [{ 'participants' => { 'data' => [{ 'id' => 'someone-else', 'username' => 'other' }] } }]
    )

    expect(service.name_for('igsid-1', platform: :instagram)).to be_nil
  end

  it 'returns nil when Meta refuses, so callers keep their placeholder' do
    allow(api).to receive(:get_connections).and_raise(Koala::Facebook::ClientError.new(403, ''))

    expect(service.name_for('igsid-1', platform: :instagram)).to be_nil
  end
end
