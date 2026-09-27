# frozen_string_literal: true

require 'httparty'

class Umi::Funnel::KlaviyoClient
  include HTTParty

  BASE_URI = 'https://a.klaviyo.com/api'
  API_REVISION = '2025-10-15'
  class Error < StandardError; end

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

  def profile(id)
    raise ArgumentError, 'Invalid profile ID' unless id.to_s.match?(/\A[A-Za-z0-9_-]+\z/)

    get("profiles/#{id}", 'fields[profile]' => 'email,phone_number').fetch('data')
  end

  def events(profile_id:, since:, until_time:, cursor: nil)
    query = { 'filter' => "and(equals(profile_id,#{JSON.generate(profile_id)}),greater-or-equal(datetime,#{since})," \
                          "less-or-equal(datetime,#{until_time}))", 'include' => 'metric', 'page[size]' => 100 }
    query['page[cursor]'] = cursor if cursor
    get('events', query)
  end

  private

  def get(path, query)
    response = self.class.get("#{BASE_URI}/#{path}", headers: @headers, query: query,
                                                     open_timeout: 3, read_timeout: 10, no_follow: true)
    raise Error, "Klaviyo HTTP_#{response.code}" unless response.code == 200

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError,
         HTTParty::RedirectionTooDeep => e
    raise Error, "Klaviyo #{e.class.name}"
  end
end
