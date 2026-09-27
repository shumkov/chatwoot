# frozen_string_literal: true

require 'spec_helper'
require 'httparty'
require 'json'

module Umi; end
module Umi::Funnel; end

require_relative '../../../../umi/app/services/funnel/meta_client'
require_relative '../../../../umi/app/services/funnel/klaviyo_client'

RSpec.describe 'Funnel provider clients' do # rubocop:disable RSpec/DescribeClass
  let(:meta) { Umi::Funnel::MetaClient.new(token: 'meta-secret') }
  let(:klaviyo) { Umi::Funnel::KlaviyoClient.new(api_key: 'klaviyo-secret') }
  let(:payload) { { 'data' => [{ 'event_name' => 'QualifiedLead' }] } }

  it 'sends Messenger events once using a header credential and the pinned Graph API' do
    request = stub_request(:post, 'https://graph.facebook.com/v23.0/123/events')
              .with(headers: { 'Authorization' => 'Bearer meta-secret' }, body: JSON.generate(payload))
              .to_return(status: 200, body: '{"events_received":1,"fbtrace_id":"trace"}')

    expect(meta.send_events(dataset_id: '123', payload: payload)).to eq(state: 'accepted', reference: 'trace')
    expect(request).to have_been_requested.once
  end

  it 'holds an ambiguous Meta response instead of treating HTTP success as receipt' do
    stub_request(:post, 'https://graph.facebook.com/v23.0/123/events').to_return(status: 200, body: '{}')

    expect(meta.send_events(dataset_id: '123', payload: payload)).to include(state: 'unknown')
  end

  it 'does not retry a Meta timeout that may have followed acceptance' do
    request = stub_request(:post, 'https://graph.facebook.com/v23.0/123/events').to_timeout

    expect(meta.send_events(dataset_id: '123', payload: payload)).to include(state: 'unknown')
    expect(request).to have_been_requested.once
  end

  [400, 401, 403, 429].each do |status|
    it "reports an explicit HTTP #{status} rejection without retaining the provider body" do
      stub_request(:post, 'https://graph.facebook.com/v23.0/123/events')
        .to_return(status: status, body: '{"error":{"message":"secret customer data"}}')

      result = meta.send_events(dataset_id: '123', payload: payload)
      expect(result).to eq(state: 'rejected', error: "HTTP_#{status}")
    end
  end

  it 'holds a Meta server error and makes no retry' do
    request = stub_request(:post, 'https://graph.facebook.com/v23.0/123/events').to_return(status: 503)

    expect(meta.send_events(dataset_id: '123', payload: payload)).to eq(state: 'unknown', error: 'HTTP_503')
    expect(request).to have_been_requested.once
  end

  it 'does not follow a provider redirect with the access token' do
    stub_request(:post, 'https://graph.facebook.com/v23.0/123/events')
      .to_return(status: 302, headers: { 'Location' => 'https://other.example/events' })

    expect(meta.send_events(dataset_id: '123', payload: payload)).to include(state: 'unknown')
    expect(a_request(:any, /other.example/)).not_to have_been_made
  end

  it 'distinguishes Klaviyo queued acceptance from confirmed readback' do
    request = stub_request(:post, 'https://a.klaviyo.com/api/events')
              .with(headers: { 'Authorization' => 'Klaviyo-API-Key klaviyo-secret', 'revision' => '2025-10-15' },
                    body: JSON.generate(payload)).to_return(status: 202)

    expect(klaviyo.create_event(payload)).to eq(state: 'accepted')
    expect(request).to have_been_requested.once
  end

  it 'reads an existing profile without importing or updating any profile' do
    stub_request(:get, 'https://a.klaviyo.com/api/profiles/PROFILE1')
      .with(query: { 'fields[profile]' => 'email,phone_number' })
      .to_return(status: 200, body: '{"data":{"type":"profile","id":"PROFILE1","attributes":{"email":"person@example.com"}}}')

    expect(klaviyo.profile('PROFILE1').fetch('id')).to eq('PROFILE1')
    expect(a_request(:post, /klaviyo/)).not_to have_been_made
  end

  it 'fails visibly on an inaccessible profile without exposing the error response' do
    stub_request(:get, %r{api/profiles}).to_return(status: 404, body: 'secret')

    expect { klaviyo.profile('PROFILE1') }.to raise_error(Umi::Funnel::KlaviyoClient::Error, 'Klaviyo HTTP_404')
  end

  it 'fetches a bounded readback page for the pinned profile and event interval' do
    request = stub_request(:get, 'https://a.klaviyo.com/api/events')
              .with(query: { 'filter' => 'and(equals(profile_id,"PROFILE1"),greater-or-equal(datetime,2026-09-27T00:00:00Z),' \
                                         'less-or-equal(datetime,2026-09-27T00:00:01Z))',
                             'include' => 'metric', 'page[size]' => '100', 'page[cursor]' => 'next-page' })
              .to_return(status: 200, body: '{"data":[],"included":[],"links":{"next":null}}')

    expect(klaviyo.events(profile_id: 'PROFILE1', since: '2026-09-27T00:00:00Z', until_time: '2026-09-27T00:00:01Z', cursor: 'next-page'))
      .to include('data' => [])
    expect(request).to have_been_requested.once
  end

  it 'holds a Klaviyo transport failure without retrying or creating profiles' do
    request = stub_request(:post, 'https://a.klaviyo.com/api/events').to_timeout

    expect(klaviyo.create_event(payload)).to include(state: 'unknown')
    expect(request).to have_been_requested.once
  end

  [Errno::ECONNREFUSED, Errno::EPIPE, OpenSSL::SSL::SSLError, Net::WriteTimeout].each do |error_class|
    it "holds #{error_class} from Meta without exposing transport details" do
      allow(Umi::Funnel::MetaClient).to receive(:post).and_raise(error_class, 'sensitive transport context')

      expect(meta.send_events(dataset_id: '123', payload: payload)).to eq(state: 'unknown', error: error_class.name)
    end

    it "holds #{error_class} from Klaviyo without exposing transport details" do
      allow(Umi::Funnel::KlaviyoClient).to receive(:post).and_raise(error_class, 'sensitive transport context')

      expect(klaviyo.create_event(payload)).to eq(state: 'unknown', error: error_class.name)
    end
  end

  it 'normalizes an inaccessible profile transport failure without sensitive details' do
    allow(Umi::Funnel::KlaviyoClient).to receive(:get).and_raise(Errno::ECONNREFUSED, 'sensitive transport context')

    expect { klaviyo.profile('PROFILE1') }.to raise_error(Umi::Funnel::KlaviyoClient::Error, 'Klaviyo Errno::ECONNREFUSED')
  end

  it 'holds a bodyless Meta success without claiming delivery' do
    response = instance_double(HTTParty::Response, code: 204, body: nil)
    allow(Umi::Funnel::MetaClient).to receive(:post).and_return(response)

    expect(meta.send_events(dataset_id: '123', payload: payload)).to include(state: 'unknown')
  end
end
