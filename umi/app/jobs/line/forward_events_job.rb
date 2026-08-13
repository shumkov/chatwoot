# frozen_string_literal: true

class Umi::Line::ForwardEventsJob < ApplicationJob
  queue_as :low

  self.log_arguments = false

  class RetryableError < StandardError
    attr_reader :status, :error_class

    def initialize(status:, error_class:)
      @status = status
      @error_class = error_class
      super(error_class)
    end
  end

  retry_on RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    arguments = job.arguments.first || {}
    channel_id = arguments[:line_channel_id] || arguments['line_channel_id']
    status = error.status || 'none'
    Rails.logger.error("[umi-line-dual] stage=forward_failed channel_id=#{channel_id} status=#{status} " \
                       "error=#{error.error_class} attempts=#{job.executions}")
  end

  def perform(post_body:, signature:, line_channel_id:)
    @line_channel_id = line_channel_id
    return unless Umi::Line::DualConsumer.target_channel?(@line_channel_id)

    endpoint = valid_endpoint(Umi::Line::DualConsumer.endpoint)
    unless endpoint
      log_failure(stage: 'config_invalid', error_class: 'InvalidEndpoint')
      return
    end

    response = post_to_endpoint(endpoint, post_body, signature)
    handle_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, IOError,
         Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
    raise_retryable(nil, e.class.name)
  rescue SsrfFilter::InvalidUriScheme, SsrfFilter::Error, URI::InvalidURIError => e
    log_failure(stage: 'config_invalid', error_class: e.class.name)
  rescue RetryableError
    raise
  rescue StandardError => e
    log_failure(stage: 'forward_failed', error_class: e.class.name)
  end

  private

  def raise_retryable(status, error_class)
    Rails.logger.warn("[umi-line-dual] stage=forward_retry channel_id=#{@line_channel_id} " \
                      "status=#{status || 'none'} error=#{error_class} attempt=#{executions}")
    raise RetryableError.new(status: status, error_class: error_class)
  end

  def retryable_status?(status)
    status == 429 || status >= 500
  end

  def post_to_endpoint(endpoint, post_body, signature)
    SsrfFilter.post(
      endpoint,
      body: post_body,
      headers: {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'X-Line-Signature' => signature
      },
      sensitive_headers: ['X-Line-Signature'],
      allow_unfollowed_redirects: true,
      max_redirects: 0,
      http_options: { open_timeout: 5, read_timeout: 10 }
    )
  end

  def handle_response(response)
    return Rails.logger.info("[umi-line-dual] stage=forward_success channel_id=#{@line_channel_id} status=2xx") if response.is_a?(Net::HTTPSuccess)

    status = response.code.to_i
    return raise_retryable(status, 'HttpError') if retryable_status?(status)

    log_failure(stage: 'forward_failed', status: status, error_class: 'HttpError')
  end

  def valid_endpoint(endpoint)
    uri = URI.parse(endpoint.to_s)
    return if uri.host.blank?
    return if [uri.user, uri.password, uri.query, uri.fragment].compact.any?

    uri if uri.scheme == 'https'
  rescue URI::InvalidURIError
    nil
  end

  def log_failure(stage:, error_class:, status: nil)
    status_value = status || 'none'
    Rails.logger.error("[umi-line-dual] stage=#{stage} channel_id=#{@line_channel_id} " \
                       "status=#{status_value} error=#{error_class}")
  end
end
