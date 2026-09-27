# frozen_string_literal: true

require 'httparty'

class Umi::Funnel::MetaClient
  include HTTParty

  GRAPH_VERSION = 'v23.0'

  def initialize(token: ENV.fetch('UMI_FUNNEL_META_ACCESS_TOKEN'))
    raise ArgumentError, 'Meta access token is required' if token.to_s.empty?

    @token = token
  end

  def send_events(dataset_id:, payload:)
    raise ArgumentError, 'Dataset ID must be numeric' unless dataset_id.to_s.match?(/\A[1-9]\d*\z/)

    response = self.class.post("https://graph.facebook.com/#{GRAPH_VERSION}/#{dataset_id}/events",
                               headers: { 'Authorization' => "Bearer #{@token}", 'Content-Type' => 'application/json' },
                               body: JSON.generate(payload), open_timeout: 3, read_timeout: 10, no_follow: true)
    return { state: 'rejected', error: "HTTP_#{response.code}" } if (400..499).cover?(response.code)
    return { state: 'unknown', error: "HTTP_#{response.code}" } unless (200..299).cover?(response.code)

    receipt = JSON.parse(response.body.to_s)
    return { state: 'unknown', error: 'unconfirmed_receipt' } unless receipt.is_a?(Hash) && receipt['events_received'] == 1

    { state: 'accepted', reference: receipt['fbtrace_id'] }
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, HTTParty::RedirectionTooDeep,
         JSON::ParserError => e
    { state: 'unknown', error: e.class.name }
  end
end
