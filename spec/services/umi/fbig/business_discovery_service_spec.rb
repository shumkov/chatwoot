require 'rails_helper'

describe Umi::Fbig::BusinessDiscoveryService do
  let(:channel) { create(:channel_facebook_page) }
  let(:api) { double }
  let(:service) { described_class.new(channel) }
  let(:profile) do
    { 'business_discovery' => { 'username' => 'marinaemmb', 'name' => 'Marina Balenciaga', 'followers_count' => 613_737 } }
  end

  before do
    stub_request(:post, /graph\.facebook\.com/)
    channel.update!(instagram_id: 'ig-business-1')
    allow(Koala::Facebook::API).to receive(:new).and_return(api)
    allow(api).to receive(:get_object).and_return(profile)
  end

  def client_error(code)
    error = Koala::Facebook::ClientError.new(400, '{}')
    allow(error).to receive(:fb_error_code).and_return(code)
    error
  end

  it 'asks the business account for the public profile behind a handle' do
    result = service.lookup('marinaemmb')

    expect(api).to have_received(:get_object).with('ig-business-1',
                                                   hash_including(fields: a_string_including('business_discovery.username(marinaemmb)')), anything)
    expect(result).to be_found
    expect(result.profile['followers_count']).to eq(613_737)
  end

  it 'asks for every field that has somewhere to go' do
    service.lookup('marinaemmb')

    expect(api).to have_received(:get_object) do |_id, args, _options|
      expect(args[:fields]).to include('followers_count', 'profile_picture_url', 'name', 'website', 'biography')
    end
  end

  # A string key here is silently ignored by Koala and the call falls back to a
  # default nothing sets, which fails later with a deprecation error while the
  # code still looks correct. This cost time twice already.
  it 'pins the API version with a symbol key' do
    service.lookup('marinaemmb')

    expect(api).to have_received(:get_object) do |_id, _args, options|
      expect(options[:api_version]).to eq(described_class::API_VERSION)
      expect(options).not_to have_key('api_version')
    end
  end

  # Koala mutates the options hash it is handed, so a shared or frozen hash
  # raises FrozenError on the first call and every call after it.
  it 'builds a fresh options hash per call' do
    seen = []
    allow(api).to receive(:get_object) { |_id, _args, options|
      seen << options
      profile
    }

    service.lookup('marinaemmb')
    service.lookup('nasa')

    expect(seen.first).not_to equal(seen.last)
  end

  describe 'the handle it will accept' do
    # The handle is interpolated into a Graph field expression and can reach us
    # from a contact name an agent typed. Anything outside Instagram's own
    # handle rule must never be sent.
    ['marina){id},name(', 'has space', 'quote"mark', ('a' * 31), '', nil].each do |handle|
      it "refuses #{handle.inspect} without calling Meta" do
        expect(service.lookup(handle).status).to eq(:invalid_handle)
        expect(api).not_to have_received(:get_object)
      end
    end

    it 'accepts a handle typed with the leading @' do
      service.lookup('@marinaemmb')

      expect(api).to have_received(:get_object).with(anything, hash_including(fields: a_string_including('username(marinaemmb)')), anything)
    end
  end

  # Personal accounts are invisible to this endpoint and always will be — no
  # permission changes it. The caller needs to tell that apart from a blip so
  # it can stop asking.
  it 'reports a personal or missing account as not discoverable' do
    allow(api).to receive(:get_object).and_raise(client_error(described_class::NOT_FOUND_CODE))

    result = service.lookup('someone.private')

    expect(result.status).to eq(:not_discoverable)
    expect(result).to be_conclusive
  end

  it 'reports any other Meta error as a failure worth retrying' do
    allow(api).to receive(:get_object).and_raise(client_error(4))

    result = service.lookup('marinaemmb')

    expect(result.status).to eq(:failed)
    expect(result).not_to be_conclusive
  end

  # A 401 is about the token, not this handle. Swallowing it would spend a
  # whole run's cap discovering the same failure once per contact.
  it 'lets an authentication error through to the caller' do
    allow(api).to receive(:get_object).and_raise(Koala::Facebook::AuthenticationError.new(401, '{}'))

    expect { service.lookup('marinaemmb') }.to raise_error(Koala::Facebook::AuthenticationError)
  end

  it 'does not call Meta when the channel has no linked Instagram account' do
    channel.update!(instagram_id: nil)

    expect(service.lookup('marinaemmb').status).to eq(:unconfigured)
    expect(api).not_to have_received(:get_object)
  end
end
