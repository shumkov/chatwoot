# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Umi::Funnel::KlaviyoClient do
  let(:client) { described_class.new(api_key: 'test-key') }
  let(:base) { 'https://a.klaviyo.com/api' }

  it 'keeps identifier discovery while requesting properties on the pinned revision' do
    stub_request(:get, "#{base}/profiles/P1").with(query: { 'fields[profile]' => 'email,phone_number,properties' },
                                                   headers: { 'revision' => '2026-07-15' }).to_return(body: { data: { id: 'P1' } }.to_json)
    expect(client.profile('P1', properties: true)).to eq('id' => 'P1')
  end

  it 'patches only typed owned properties and explicitly unsets unknown without touching consent' do
    request = stub_request(:patch, "#{base}/profiles/P1").with(body: {
      data: { type: 'profile', id: 'P1', attributes: { properties: { umi_vip: false, umi_wholesale: true } },
              meta: { patch_properties: { unset: ['umi_influencer'] } } }
    }.to_json).to_return(body: { data: { id: 'P1' } }.to_json)
    client.update_roles('P1', 'umi_vip' => 'no', 'umi_wholesale' => 'yes', 'umi_influencer' => 'unknown')
    expect(request).to have_been_requested.once
    expect { client.update_roles('P1', 'subscriptions' => 'yes') }.to raise_error(ArgumentError)
  end

  it 'reads every segment page before returning membership' do
    first_page = { data: [{ id: 'P1' }], links: { next: "#{base}/segments/SS6aWp/profiles?page%5Bcursor%5D=two" } }
    query = { 'page[size]' => 100, 'fields[profile]' => 'email,phone_number' }
    stub_request(:get, "#{base}/segments/SS6aWp/profiles").with(query: query).to_return(body: first_page.to_json)
    stub_request(:get, "#{base}/segments/SS6aWp/profiles").with(query: query.merge('page[cursor]' => 'two'))
                                                          .to_return(body: { data: [{ id: 'P2' }], links: { next: nil } }.to_json)
    expect(client.segment_profiles('SS6aWp').map { |p| p.fetch('id') }).to eq(%w[P1 P2])
  end

  it 'requests the segment definition through the documented sparse fieldset' do
    stub_request(:get, "#{base}/segments/SS6aWp").with(query: { 'fields[segment]' => 'name,definition' })
                                                 .to_return(body: { data: { id: 'SS6aWp',
                                                                            attributes: { name: 'UMI - Chooser', definition: {} } } }.to_json)
    expect(client.segment('SS6aWp').dig('attributes', 'definition')).to eq({})
  end

  it 'reads metrics without an unsupported page size parameter' do
    stub_request(:get, "#{base}/metrics").with(query: {})
                                         .to_return(body: { data: [{ id: 'M1' }], links: { next: nil } }.to_json)
    expect(client.metrics).to eq([{ 'id' => 'M1' }])
  end

  [{ 'self' => 'https://a.klaviyo.com/api/segments/SS6aWp/profiles' }, nil].each do |links|
    it "accepts a documented terminal page without next (links=#{links.present?})" do
      page = { data: [{ id: 'P1' }] }
      page[:links] = links if links
      stub_request(:get, %r{segments/SS6aWp/profiles}).to_return(body: page.to_json)
      expect(client.segment_profiles('SS6aWp')).to eq([{ 'id' => 'P1' }])
    end
  end

  it 'fails on incomplete or off-origin pagination instead of reporting an empty segment' do
    stub_request(:get,
                 %r{segments/SS6aWp/profiles}).to_return(body: { data: [], links: { next: 'https://evil.example/?page%5Bcursor%5D=x' } }.to_json)
    expect { client.segment_profiles('SS6aWp') }.to raise_error(described_class::Error)
  end

  it 'retains Retry-After as a due-time signal rather than absent properties' do
    stub_request(:get, %r{profiles/P1}).to_return(status: 429, headers: { 'Retry-After' => '90' })
    expect { client.profile('P1') }.to raise_error(described_class::RateLimited) { |error| expect(error.retry_after).to eq(90) }
  end

  it 'rejects repeated cursors and malformed links' do
    stub_request(:get, %r{segments/SS6aWp/profiles}).to_return(body: {
      data: [], links: { next: "#{base}/segments/SS6aWp/profiles?page%5Bcursor%5D=again" }
    }.to_json)
    expect { client.segment_profiles('SS6aWp') }.to raise_error(described_class::Error, /Repeated/)
    stub_request(:get, %r{segments/SS6aWp/profiles}).to_return(body: { data: [], links: 'invalid' }.to_json)
    expect { client.segment_profiles('SS6aWp') }.to raise_error(described_class::Error, /Incomplete/)
  end

  it 'keeps the established event revision and accepted-event receipt unchanged' do
    stub_request(:post, "#{base}/events").with(headers: { 'revision' => '2025-10-15' }).to_return(status: 202)
    expect(client.create_event(data: { type: 'event' })).to eq(state: 'accepted')
    stub_request(:get, %r{#{base}/events}).with(headers: { 'revision' => '2025-10-15' }).to_return(body: { data: [] }.to_json)
    expect(client.events(profile_id: 'P1', since: '2026-01-01', until_time: '2026-01-02')).to eq('data' => [])
  end

  it 'fully paginates exact-name segment lookup rather than overlooking a second matching name' do
    query = { 'filter' => 'equals(name,"UMI - Recent conversation intent")', 'fields[segment]' => 'name,definition' }
    stub_request(:get, "#{base}/segments").with(query: query, headers: { 'revision' => '2026-07-15' }).to_return(body: {
      data: [{ id: 'S1' }], links: { next: "#{base}/segments?page%5Bcursor%5D=next" }
    }.to_json)
    stub_request(:get, "#{base}/segments").with(query: query.merge('page[cursor]' => 'next')).to_return(body: {
      data: [{ id: 'S2' }], links: { next: nil }
    }.to_json)
    expect(client.segments(name: 'UMI - Recent conversation intent').pluck('id')).to eq(%w[S1 S2])
  end

  it 'creates a native segment once on the profile revision and requires its created ID' do
    payload = { data: { type: 'segment', attributes: { name: 'UMI - Recent conversation intent', definition: { condition_groups: [] } } } }
    request = stub_request(:post, "#{base}/segments").with(headers: { 'revision' => '2026-07-15' }, body: payload)
                                                     .to_return(status: 201, body: { data: { id: 'S1' } }.to_json)
    expect(client.create_segment(name: 'UMI - Recent conversation intent', definition: { condition_groups: [] })).to eq('id' => 'S1')
    expect(request).to have_been_requested.once
  end

  [200, 202, 400, 403, 503].each do |status|
    it "does not treat HTTP#{status} as a confirmed segment creation or repeat its POST" do
      request = stub_request(:post, "#{base}/segments").to_return(status: status, body: { data: { id: 'S1' } }.to_json)
      expect { client.create_segment(name: 'UMI - Recent conversation intent', definition: {}) }
        .to raise_error(described_class::Error, "Klaviyo HTTP_#{status}")
      expect(request).to have_been_requested.once
    end
  end

  it 'reports ambiguous creation without retrying a timed-out POST' do
    request = stub_request(:post, "#{base}/segments").to_timeout
    expect { client.create_segment(name: 'UMI - Recent conversation intent', definition: {}) }.to raise_error(described_class::Error)
    expect(request).to have_been_requested.once
  end

  it 'carries an explicit creation rate limit to the scheduler' do
    request = stub_request(:post, "#{base}/segments").to_return(status: 429, headers: { 'Retry-After' => '600' })
    expect { client.create_segment(name: 'UMI - Recent conversation intent', definition: {}) }
      .to raise_error(described_class::RateLimited) { |error| expect(error.retry_after).to eq(600) }
    expect(request).to have_been_requested.once
  end

  it 'does not lose the creation uncertainty when the provider omits its segment ID' do
    stub_request(:post, "#{base}/segments").to_return(status: 201, body: { data: { type: 'segment' } }.to_json)
    expect { client.create_segment(name: 'UMI - Recent conversation intent', definition: {}) }
      .to raise_error(described_class::Error, 'Missing created segment ID')
  end
end
