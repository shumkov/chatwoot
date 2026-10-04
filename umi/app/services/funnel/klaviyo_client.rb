# frozen_string_literal: true

require 'httparty'

class Umi::Funnel::KlaviyoClient
  include HTTParty

  BASE_URI = 'https://a.klaviyo.com/api'
  API_REVISION = '2025-10-15'
  PROFILE_REVISION = '2026-07-15'
  class Error < StandardError; end

  class RateLimited < Error
    attr_reader :retry_after

    def initialize(value)
      @retry_after = value.to_s.match?(/\A\d+\z/) ? value.to_i : [(Time.httpdate(value.to_s) - Time.current).ceil, 1].max
      super('Klaviyo HTTP_429')
    rescue ArgumentError
      @retry_after = 60
      super('Klaviyo HTTP_429')
    end
  end

  def initialize(api_key: ENV.fetch('UMI_KLAVIYO_PRIVATE_API_KEY'))
    raise ArgumentError, 'Klaviyo API key is required' if api_key.to_s.empty?

    @headers = { 'Authorization' => "Klaviyo-API-Key #{api_key}", 'Content-Type' => 'application/vnd.api+json',
                 'Accept' => 'application/vnd.api+json', 'revision' => API_REVISION }
  end

  def create_event(payload)
    response = self.class.post("#{BASE_URI}/events", headers: @headers, body: JSON.generate(payload),
                                                     open_timeout: 3, read_timeout: 10, no_follow: true)
    return { state: 'accepted' } if response.code == 202

    { state: (400..499).cover?(response.code) ? 'rejected' : 'unknown', error: "HTTP_#{response.code}" }
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, HTTParty::RedirectionTooDeep => e
    { state: 'unknown', error: e.class.name }
  end

  def profile(id, properties: false)
    raise ArgumentError, 'Invalid profile ID' unless id.to_s.match?(/\A[A-Za-z0-9_-]+\z/)

    get("profiles/#{id}", { 'fields[profile]' => properties ? 'email,phone_number,properties' : 'email,phone_number' }).fetch('data')
  end

  def profiles(identifiers)
    raise ArgumentError, 'Profile identifier is required' if identifiers.empty?

    pages = identifiers.map do |key, value|
      get('profiles', { 'filter' => "equals(#{key},#{JSON.generate(value)})", 'fields[profile]' => 'email,phone_number', 'page[size]' => 2 })
    end
    { 'data' => pages.flat_map { |page| page.fetch('data') }.uniq { |profile| profile.fetch('id') },
      'links' => { 'next' => pages.filter_map { |page| page.dig('links', 'next').presence }.first } }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def update_roles(id, roles)
    raise ArgumentError, 'Invalid profile ID' unless id.to_s.match?(/\A[A-Za-z0-9_-]+\z/)
    raise ArgumentError, 'Unknown customer role' unless (roles.keys - Umi::Funnel::Configuration::ROLES.keys).empty?
    raise ArgumentError, 'Invalid role value' unless roles.values.all? { |value| Umi::Funnel::Configuration::ROLE_VALUES.include?(value) }

    properties = roles.reject { |_key, value| value == 'unknown' }.transform_values { |value| value == 'yes' }
    data = { type: 'profile', id: id, attributes: { properties: properties } }
    unset = roles.select { |_key, value| value == 'unknown' }.keys
    data[:meta] = { patch_properties: { unset: unset } } if unset.any?
    response = self.class.patch("#{BASE_URI}/profiles/#{id}", headers: @headers.merge('revision' => PROFILE_REVISION),
                                                              body: JSON.generate(data: data), open_timeout: 3, read_timeout: 10, no_follow: true)
    parse_response(response)
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, HTTParty::RedirectionTooDeep => e
    raise Error, "Klaviyo #{e.class.name}"
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def segment(id)
    raise ArgumentError, 'Invalid segment ID' unless id.to_s.match?(/\A[A-Za-z0-9_-]+\z/)

    get("segments/#{id}", { 'fields[segment]' => 'name,definition' }).fetch('data')
  end

  def segments(name:)
    collection('segments', { 'filter' => "equals(name,#{JSON.generate(name)})", 'fields[segment]' => 'name,definition' })
  end

  def create_segment(name:, definition:)
    payload = { data: { type: 'segment', attributes: { name: name, definition: definition } } }
    response = self.class.post("#{BASE_URI}/segments", headers: @headers.merge('revision' => PROFILE_REVISION),
                                                       body: JSON.generate(payload), open_timeout: 3, read_timeout: 10, no_follow: true)
    raise RateLimited, response.headers['retry-after'] if response.code == 429
    raise Error, "Klaviyo HTTP_#{response.code}" unless response.code == 201

    segment = JSON.parse(response.body.to_s)['data']
    raise Error, 'Missing created segment ID' unless segment.is_a?(Hash) && segment['id'].to_s.match?(/\A[A-Za-z0-9_-]+\z/)

    segment
  rescue JSON::ParserError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError,
         HTTParty::RedirectionTooDeep => e
    raise Error, "Klaviyo #{e.class.name}"
  end

  def metrics
    collection('metrics', {})
  end

  def segment_profiles(id, &)
    raise ArgumentError, 'Invalid segment ID' unless id.to_s.match?(/\A[A-Za-z0-9_-]+\z/)

    collection("segments/#{id}/profiles", { 'page[size]' => 100, 'fields[profile]' => 'email,phone_number' }, &)
  end

  def events(profile_id:, since:, until_time:, cursor: nil)
    query = { 'filter' => "and(equals(profile_id,#{JSON.generate(profile_id)}),greater-or-equal(datetime,#{since})," \
                          "less-or-equal(datetime,#{until_time}))", 'include' => 'metric', 'page[size]' => 100 }
    query['page[cursor]'] = cursor if cursor
    get('events', query, revision: API_REVISION)
  end

  private

  def get(path, query, revision: PROFILE_REVISION)
    response = self.class.get("#{BASE_URI}/#{path}", headers: @headers.merge('revision' => revision), query: query,
                                                     open_timeout: 3, read_timeout: 10, no_follow: true)
    parse_response(response)
  rescue JSON::ParserError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError,
         HTTParty::RedirectionTooDeep => e
    raise Error, "Klaviyo #{e.class.name}"
  end

  def parse_response(response)
    raise RateLimited, response.headers['retry-after'] if response.code == 429
    raise Error, "Klaviyo HTTP_#{response.code}" unless response.code == 200

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError => e
    raise Error, "Klaviyo #{e.class.name}"
  end

  def collection(path, query)
    result = []
    seen = Set.new
    loop do
      page = get(path, query)
      links = page.fetch('links', {})
      raise Error, 'Incomplete Klaviyo page' unless page['data'].is_a?(Array) && links.is_a?(Hash)

      page['data'].each { |item| block_given? ? yield(item) : result << item }
      break if links['next'].nil?

      cursor = next_cursor(links['next'], path)
      raise Error, 'Repeated Klaviyo cursor' unless seen.add?(cursor)

      query = query.merge('page[cursor]' => cursor)
    end
    result
  end

  def next_cursor(link, path)
    uri = URI.parse(link)
    expected = URI.parse("#{BASE_URI}/#{path}")
    actual = [uri.scheme, uri.host, uri.port, uri.path.delete_suffix('/'), uri.userinfo, uri.fragment]
    unless actual == [expected.scheme, expected.host, expected.port, expected.path, nil, nil]
      raise Error, 'Unexpected Klaviyo pagination origin or path'
    end

    cursor = URI.decode_www_form(uri.query.to_s).to_h['page[cursor]']
    raise Error, 'Missing Klaviyo cursor' if cursor.blank?

    cursor
  rescue URI::InvalidURIError, TypeError
    raise Error, 'Invalid Klaviyo pagination link'
  end
end
