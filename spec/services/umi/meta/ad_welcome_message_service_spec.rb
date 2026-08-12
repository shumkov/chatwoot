require 'rails_helper'

# The fixture is the real payload for ad 120252251820030415, captured from
# production. Every trap these examples pin is present in it: the documented
# field is empty, the payload is nested and JSON-encoded inside a string, and
# two of the three format blocks hold copy no customer has ever been shown.
describe Umi::Meta::AdWelcomeMessageService do
  let(:payload) { JSON.parse(file_fixture('umi/meta_ad_creative.json').read) }
  let(:api) { instance_double(Koala::Facebook::API) }
  let(:service) { described_class.new('page-token') }

  before do
    allow(Koala::Facebook::API).to receive(:new).with('page-token').and_return(api)
    allow(api).to receive(:get_object).and_return(payload)
  end

  it 'asks Meta for a pinned API version, as a symbol key' do
    service.fetch('120252251820030415')

    # Koala reads raw_options[:api_version]; a string key falls through to
    # Koala.config.api_version, which nothing in this app sets, and the Ads API
    # rejects the resulting unversioned URL with (#2635).
    expect(api).to have_received(:get_object).with(
      '120252251820030415', hash_including(:fields), { api_version: 'v25.0' }
    )
  end

  it 'finds the welcome message Meta nested inside object_story_spec' do
    # The documented field really is empty — that is what makes a fixed path a
    # silent failure rather than a loud one.
    expect(payload.dig('creative', 'page_welcome_message')).to be_nil

    welcome = service.fetch('120252251820030415')

    expect(welcome.greeting).to include('สวัสดีค่ะ')
    expect(welcome.items.map { |i| i[:title] }).to eq(
      ['1. สนใจรับส่วนลด 10% สำหรับการสั่งซื้อครั้งแรก',
       '2. ขอแนะนำสินค้าสำหรับวันแม่',
       '3. ขอแนะนำสินค้าขายดีของ UMI']
    )
  end

  it 'keeps Meta placeholders in the greeting rather than resolving them' do
    expect(service.fetch('120252251820030415').greeting).to include('{{user_full_name}}')
  end

  describe 'the campaign hierarchy' do
    it 'reads campaign and ad set names from the same request as the creative' do
      welcome = service.fetch('120252251820030415')

      expect(welcome.campaign_name).to eq('05082026_Conversation_Messages Engagement')
      expect(welcome.adset_name).to eq('Thai_Board')
      expect(api).to have_received(:get_object).once
    end

    it 'asks for them by expanding the existing field list, not a second call' do
      service.fetch('120252251820030415')

      expect(api).to have_received(:get_object).with(
        anything, hash_including(fields: a_string_including('campaign{id,name}', 'adset{id,name}')), anything
      )
    end

    # The welcome message is the value; the hierarchy is context. Meta omitting
    # a level, or the token not being able to see it, must not cost the note.
    it 'still returns the welcome message when Meta omits both levels' do
      payload.delete('campaign')
      payload.delete('adset')

      welcome = service.fetch('120252251820030415')

      expect(welcome.campaign_name).to be_nil
      expect(welcome.adset_name).to be_nil
      expect(welcome.items.size).to eq(3)
      expect(welcome.greeting).to be_present
    end

    it 'treats an empty name as absent rather than printing a blank' do
      payload['campaign'] = { 'id' => '1', 'name' => '' }

      expect(service.fetch('120252251820030415').campaign_name).to be_nil
    end
  end

  it 'reads only the format block named by media_type' do
    # image_format and video_format are always populated. Their quick reply is a
    # Meta default in English that no customer of this ad has ever seen, so
    # anything that scrapes the payload broadly will render a fiction.
    expect(payload.dig('creative', 'object_story_spec', 'video_data', 'page_welcome_message'))
      .to include("I'd like to learn more")

    welcome = service.fetch('120252251820030415')

    expect(welcome.action_type).to eq('ice_breakers')
    expect(welcome.items.map { |i| i[:title] }).not_to include("I'd like to learn more")
  end

  it 'reads quick replies when that is what the ad uses' do
    inner = { 'media_type' => 'image',
              'image_format' => { 'customer_action_type' => 'quick_replies',
                                  'message' => { 'text' => 'hello',
                                                 'quick_replies' => [{ 'title' => 'Learn more' }] } } }
    payload['creative']['object_story_spec']['video_data']['page_welcome_message'] = inner.to_json

    welcome = service.fetch('ad')

    expect(welcome.items).to eq([{ title: 'Learn more', response: nil }])
  end

  it 'accepts a welcome message Meta returns already decoded' do
    decoded = JSON.parse(payload.dig('creative', 'object_story_spec', 'video_data', 'page_welcome_message'))
    payload['creative']['object_story_spec']['video_data']['page_welcome_message'] = decoded

    expect(service.fetch('ad').items.size).to eq(3)
  end

  context 'when the ad cannot be read' do
    it 'raises Unavailable rather than returning a blank welcome' do
      payload['creative'].delete('object_story_spec')

      expect { service.fetch('ad') }.to raise_error(described_class::Unavailable, /no page_welcome_message/)
    end

    it 'raises Unavailable on malformed JSON instead of leaking a parser error' do
      payload['creative']['object_story_spec']['video_data']['page_welcome_message'] = '{not json'

      expect { service.fetch('ad') }.to raise_error(described_class::Unavailable, /not valid JSON/)
    end

    it 'reports a Graph failure by code, never by exception message' do
      error = Koala::Facebook::ClientError.new(400, { error: { code: 100, type: 'OAuthException',
                                                               message: 'token=SECRET in url' } }.to_json)
      allow(api).to receive(:get_object).and_raise(error)

      expect { service.fetch('ad') }.to raise_error(described_class::Unavailable, 'graph error 100 OAuthException')
    end

    it 'reports a transport failure by class, because its message carries the access token' do
      allow(api).to receive(:get_object)
        .and_raise(Errno::ECONNREFUSED, 'https://graph.facebook.com/v25.0/ad?access_token=SECRET')

      expect { service.fetch('ad') }.to raise_error(described_class::Unavailable) do |e|
        expect(e.message).not_to include('SECRET')
      end
    end
  end
end
