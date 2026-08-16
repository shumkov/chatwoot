# frozen_string_literal: true

require 'httparty'

class Umi::Line::KlaviyoClient
  include HTTParty

  BASE_URI = 'https://a.klaviyo.com/api/profile-import'

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end

  class TransientError < Error; end
  class PermanentError < Error; end

  def profile_import(email:, properties:)
    response = request_profile_import(email, properties)
    return response if response.code.in?([200, 201])

    raise_for_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
    raise TransientError, "Klaviyo profile import transport failed: #{e.class}"
  end

  private

  # The JSON:API request shape and provider options are kept together for auditability.
  # rubocop:disable Metrics/MethodLength
  def request_profile_import(email, properties)
    self.class.post(
      BASE_URI,
      headers: {
        'Authorization' => "Klaviyo-API-Key #{api_key}",
        'Content-Type' => 'application/vnd.api+json',
        'revision' => Umi::Line::Config::API_REVISION
      },
      body: {
        data: {
          type: 'profile',
          attributes: {
            email: email,
            properties: properties
          }
        }
      }.to_json,
      open_timeout: 2,
      read_timeout: 4,
      no_follow: true
    )
  end
  # rubocop:enable Metrics/MethodLength

  def raise_for_response(response)
    error_class = response.code == 429 || response.code >= 500 ? TransientError : PermanentError
    raise error_class.new("Klaviyo profile import failed with HTTP #{response.code}", status: response.code)
  end

  def api_key
    Umi::Line::Config.klaviyo_private_api_key
  end
end
