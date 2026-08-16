# frozen_string_literal: true

require 'httparty'

class Umi::Line::IdentityClient
  include HTTParty

  VERIFY_URI = 'https://api.line.me/oauth2/v2.1/verify'
  PROFILE_URI = 'https://api.line.me/v2/bot/profile'

  class Error < StandardError
    attr_reader :kind

    def initialize(message, kind: :invalid)
      @kind = kind
      super(message)
    end
  end

  # The verification request and claim validation stay together so invalid identities cannot
  # accidentally bypass the provider response checks.
  # rubocop:disable Metrics/MethodLength
  def verify_id_token(id_token)
    channel_id = Umi::Line::Config.line_login_channel_id
    response = self.class.post(
      VERIFY_URI,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
      body: URI.encode_www_form(id_token: id_token.to_s, client_id: channel_id),
      open_timeout: 2,
      read_timeout: 2,
      no_follow: true
    )
    unless response.code == 200
      kind = response.code == 429 || response.code >= 500 ? :transient : :invalid
      raise Error.new('LINE rejected the ID token', kind: kind)
    end

    claims = JSON.parse(response.body)
    validate_claims!(claims, channel_id)
    { user_id: claims.fetch('sub'), display_name: claims['name'].to_s }
  rescue JSON::ParserError, KeyError
    raise Error, 'LINE returned an invalid verification response'
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
    raise Error.new("LINE verification transport failed: #{e.class}", kind: :transient)
  end
  # rubocop:enable Metrics/MethodLength

  def verify_friendship!(user_id)
    response = self.class.get(
      "#{PROFILE_URI}/#{ERB::Util.url_encode(user_id)}",
      headers: { 'Authorization' => "Bearer #{Umi::Line::Config.messaging_channel_access_token}" },
      open_timeout: 2,
      read_timeout: 2,
      no_follow: true
    )
    unless response.code == 200
      kind = response.code == 429 || response.code >= 500 ? :transient : :invalid
      raise Error.new('LINE user does not follow the configured Official Account', kind: kind)
    end

    body = JSON.parse(response.body)
    raise Error, 'LINE provider mismatch' unless body['userId'] == user_id

    true
  rescue JSON::ParserError
    raise Error, 'LINE returned an invalid profile response'
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
    raise Error.new("LINE profile transport failed: #{e.class}", kind: :transient)
  end

  private

  def validate_claims!(claims, channel_id)
    now = Time.current.to_i
    valid = claims['iss'] == 'https://access.line.me' &&
            claims['aud'].to_s == channel_id &&
            claims['exp'].to_i > now &&
            claims['iat'].to_i.between?(now - Umi::Line::Config::ID_TOKEN_FRESHNESS.to_i, now + 30) &&
            claims['sub'].to_s.match?(/\AU[0-9a-f]{32}\z/)
    raise Error, 'LINE returned invalid identity claims' unless valid
  end
end
