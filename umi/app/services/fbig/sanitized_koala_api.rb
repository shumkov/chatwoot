# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
class Umi::Fbig::SanitizedKoalaApi < Koala::Facebook::API
  Usage = Data.define(:maximum_percent, :estimated_regain_minutes)

  class UsageMetadataError < StandardError
    def initialize
      super('invalid Meta usage metadata')
    end
  end

  USAGE_HEADERS = %w[x-business-use-case-usage x-ad-account-usage x-app-usage].freeze
  PERCENT_KEYS = %w[call_count total_cputime total_time acc_id_util_pct].freeze
  GRAPH_API_VERSION = 'v21.0'

  def initialize(access_token, app_secret = nil, usage_observer: nil)
    super(access_token, app_secret, nil)
    @usage_observer = usage_observer
  end

  def api(path, args = {}, verb = 'get', options = {})
    args = args.dup
    args['access_token'] ||= @access_token || @app_access_token if @access_token || @app_access_token
    if options.delete(:appsecret_proof) && args['access_token'] && @app_secret
      args['appsecret_proof'] = OpenSSL::HMAC.hexdigest(
        OpenSSL::Digest.new('sha256'),
        @app_secret,
        args['access_token']
      )
    end
    args = sanitize_request_parameters(args) unless preserve_form_arguments?(options)
    path = "/#{path}" unless path.to_s.start_with?('/')

    result = Koala.make_request(path, args, verb, options.merge(api_version: GRAPH_API_VERSION))
    observe_usage!(result.headers)
    return sanitized_error_response(result) if result.status.to_i >= 400 && result.status.to_i < 500
    raise sanitized_server_error(result) if result.status.to_i >= 500

    Koala::HTTPService::Response.new(result.status, result.body, {})
  end

  private

  def observe_usage!(headers)
    normalized = headers.to_h.transform_keys { |key| key.to_s.downcase }
    present = USAGE_HEADERS.filter_map do |name|
      value = normalized[name]
      [name, value] if value.present?
    end
    return if present.empty?

    percentages = []
    regain_minutes = []
    present.each do |name, raw|
      parsed = JSON.parse(raw)
      validate_usage_shape!(name, parsed)
      collect_usage_values!(parsed, percentages, regain_minutes) unless name == 'x-ad-account-usage'
    rescue JSON::ParserError
      raise UsageMetadataError
    end
    @usage_observer&.call(
      Usage.new(
        maximum_percent: percentages.max,
        estimated_regain_minutes: regain_minutes.select(&:positive?).max
      )
    )
  end

  def validate_usage_shape!(name, parsed)
    valid = case name
            when 'x-app-usage'
              parsed.is_a?(Hash) && PERCENT_KEYS.first(3).all? { |key| numeric_usage?(parsed[key]) }
            when 'x-ad-account-usage'
              parsed.is_a?(Hash) && numeric_usage?(parsed['acc_id_util_pct'])
            when 'x-business-use-case-usage'
              parsed.is_a?(Hash) && parsed.values.all? do |entries|
                entries.is_a?(Array) && entries.all?(Hash)
              end
            end
    raise UsageMetadataError unless valid
  end

  def numeric_usage?(value)
    value.is_a?(Numeric) && value.finite? && value >= 0
  end

  def collect_usage_values!(value, percentages, regain_minutes)
    case value
    when Hash
      value.each do |key, nested|
        if PERCENT_KEYS.include?(key.to_s)
          raise UsageMetadataError unless numeric_usage?(nested)

          percentages << nested
        elsif key.to_s == 'estimated_time_to_regain_access'
          raise UsageMetadataError unless numeric_usage?(nested)

          regain_minutes << nested
        elsif nested.is_a?(Hash) || nested.is_a?(Array)
          collect_usage_values!(nested, percentages, regain_minutes)
        end
      end
    when Array
      value.each { |nested| collect_usage_values!(nested, percentages, regain_minutes) }
    end
  end

  def sanitized_server_error(result)
    Koala::Facebook::ServerError.new(result.status.to_i, '', safe_error_info(result.body))
  end

  def sanitized_error_response(result)
    body = JSON.generate('error' => safe_error_info(result.body))
    Koala::HTTPService::Response.new(result.status, body, {})
  end

  def safe_error_info(body)
    error = JSON.parse(body.to_s).fetch('error', {})
    return {} unless error.is_a?(Hash)

    error.slice('type', 'code', 'error_subcode')
  rescue JSON::ParserError
    {}
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
