# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists
# rubocop:disable Metrics/PerceivedComplexity
# Reads the Meta Conversations API with bounded pagination, throttling, and
# retry classification. Cursor values stay inside this object so signed paging
# URLs cannot leak into importer logs.
class Umi::Fbig::HistoryImportGraphClient
  PageResult = Data.define(:items, :pages)
  ProfileResult = Data.define(:attributes, :unavailable_reason)

  class PaginationError < StandardError; end
  class AuthenticationError < StandardError; end
  class LeaseLostError < StandardError; end

  class ProfileError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  class RequestError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  CONVERSATION_FIELDS = 'id,updated_time,participants'
  MESSAGE_FIELDS = 'id,created_time,from'
  DETAIL_FIELDS = 'id,created_time,from,to,message,reply_to,attachments'
  PROFILE_FIELDS = {
    'instagram' => 'id,name,username,profile_pic,follower_count,is_user_follow_business,' \
                   'is_business_follow_user,is_verified_user',
    'messenger' => 'id,first_name,last_name,profile_pic'
  }.freeze
  PROFILE_UNAVAILABLE_CODES = [10, 230, 9010].freeze
  PROFILE_UNAVAILABLE_SUBCODES = [33, 2_018_218].freeze
  RATE_LIMIT_CODES = [4, 17, 32, 613, 80_004].freeze
  MAX_ATTEMPTS = 3
  MAX_BACKOFF_SECONDS = 30
  RETRYABLE_NETWORK_ERRORS = [
    Faraday::ConnectionFailed,
    Faraday::TimeoutError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Timeout::Error,
    SocketError
  ].freeze

  def initialize(channel, delay_ms:, max_conversation_pages:, max_message_pages:, sleeper: Kernel, random: Random,
                 max_rate_limit_wait_seconds: nil, renewer: nil)
    @channel = channel
    @delay_seconds = delay_ms.to_f / 1000
    @max_conversation_pages = max_conversation_pages
    @max_message_pages = max_message_pages
    @sleeper = sleeper
    @random = random
    @renewer = renewer
    @stats = Hash.new(0)
    return unless max_rate_limit_wait_seconds
    raise ArgumentError, 'renewer is required for rate-aware Graph access' unless renewer

    @rate_controller = Umi::Fbig::ProfileRateLimitController.new(
      max_wait_seconds: max_rate_limit_wait_seconds,
      sleeper: ->(seconds) { @sleeper.sleep(seconds) },
      renewer: renewer,
      random: random
    )
  end

  def each_thread(platform, on_page: nil, &)
    first_page = request(kind: :conversation) do
      api.get_connections(@channel.page_id, 'conversations',
                          { platform: platform, fields: CONVERSATION_FIELDS, limit: 50 })
    end
    paginate(first_page, kind: :conversation, max_pages: @max_conversation_pages, on_page: on_page, &)
  end

  def messages(thread_id, on_page: nil)
    first_page = request(kind: :message) do
      api.get_connections(thread_id, 'messages', { fields: MESSAGE_FIELDS, limit: 50 })
    end
    items = []
    pages = paginate(first_page, kind: :message, max_pages: @max_message_pages, on_page: on_page) { |message| items << message }
    PageResult.new(items: items, pages: pages)
  end

  def detail(mid)
    request(kind: :detail) { api.get_object(mid, { fields: DETAIL_FIELDS }) }
  rescue Koala::Facebook::ClientError
    nil
  end

  def profile(platform, participant_id)
    fields = PROFILE_FIELDS[platform]
    raise ProfileError, :unsupported_platform unless fields

    requested_id = participant_id.to_s
    @stats[:profile_logical_lookups] += 1
    response = request(kind: :profile) { api.get_object(requested_id, { fields: fields }) }
    normalize_profile(response, requested_id, fields)
  rescue Koala::Facebook::ClientError => e
    return ProfileResult.new(attributes: nil, unavailable_reason: :profile_unavailable) if profile_unavailable?(e)

    raise ProfileError, :contract_error
  end

  def stats
    @stats.merge(
      rate_limit_retries: @stats[:rate_limit_retries],
      rate_limit_wait_seconds: @rate_controller&.waited_seconds.to_i,
      maximum_usage_percent: @rate_controller&.maximum_percent.to_f,
      maximum_estimated_regain_minutes: @rate_controller&.maximum_estimated_regain_minutes.to_f
    )
  end

  private

  def normalize_profile(response, requested_id, fields)
    raise ProfileError, :missing_id unless response.is_a?(Hash) && response['id'].present?
    raise ProfileError, :identity_mismatch unless response['id'].to_s == requested_id

    ProfileResult.new(
      attributes: response.slice(*fields.split(',')),
      unavailable_reason: nil
    )
  end

  def profile_unavailable?(error)
    code = error.fb_error_code.to_i
    return true if PROFILE_UNAVAILABLE_CODES.include?(code)

    code == 100 && PROFILE_UNAVAILABLE_SUBCODES.include?(error.fb_error_subcode.to_i)
  end

  def paginate(collection, kind:, max_pages:, on_page:, &)
    pages = 0
    cursors = Set.new
    while collection
      pages += 1
      on_page&.call
      collection.each(&)
      next_url = collection.respond_to?(:paging) && collection.paging&.[]('next')
      break if next_url.blank?

      raise PaginationError, "repeated #{kind} cursor" unless cursors.add?(next_url)
      raise PaginationError, "#{kind} page ceiling reached" if pages >= max_pages

      collection = request(kind: kind) { collection.next_page }
      raise PaginationError, "#{kind} next page missing" if collection.nil?
    end
    pages
  end

  def request(kind:)
    attempts = 0
    transport_failures = 0
    begin
      attempts += 1
      @stats[:"#{kind}_http_attempts"] += 1
      @rate_controller&.before_request!
      yield
    rescue Umi::Fbig::ProfileRateLimitController::LockLossError
      raise LeaseLostError
    rescue Umi::Fbig::ProfileRateLimitController::WaitBudgetError
      raise RequestError, :rate_wait_budget_exhausted
    rescue Umi::Fbig::SanitizedKoalaApi::UsageMetadataError
      raise RequestError, :invalid_usage_metadata
    rescue StandardError => e
      raise AuthenticationError, e.class.name if e.is_a?(Koala::Facebook::APIError) && authentication_error?(e)
      raise unless retryable?(e)

      transport_failures += 1 if transport_failure?(e)
      maximum_attempts = @rate_controller ? 4 : MAX_ATTEMPTS
      exhausted = attempts >= maximum_attempts || transport_failures >= MAX_ATTEMPTS
      raise RequestError, request_error_reason(e) if exhausted

      if @rate_controller && rate_limit_failure?(e)
        begin
          @stats[:rate_limit_retries] += 1
          @rate_controller.retry_wait!(attempts)
        rescue Umi::Fbig::ProfileRateLimitController::LockLossError
          raise LeaseLostError
        rescue Umi::Fbig::ProfileRateLimitController::WaitBudgetError
          raise RequestError, :rate_wait_budget_exhausted
        end
      else
        @sleeper.sleep(backoff_seconds(attempts))
      end
      retry
    ensure
      sleep_graph_delay!
    end
  end

  def retryable?(error)
    RETRYABLE_NETWORK_ERRORS.any? { |error_class| error.is_a?(error_class) } ||
      (error.is_a?(Koala::Facebook::APIError) && retryable_api_error?(error))
  end

  def transport_failure?(error)
    RETRYABLE_NETWORK_ERRORS.any? { |error_class| error.is_a?(error_class) } ||
      (error.is_a?(Koala::Facebook::APIError) && error.http_status.to_i >= 500)
  end

  def rate_limit_failure?(error)
    error.is_a?(Koala::Facebook::APIError) &&
      (error.http_status.to_i == 429 || RATE_LIMIT_CODES.include?(error.fb_error_code.to_i))
  end

  def retryable_api_error?(error)
    status = error.http_status.to_i
    status == 429 || status >= 500 || RATE_LIMIT_CODES.include?(error.fb_error_code.to_i)
  end

  def authentication_error?(error)
    error.is_a?(Koala::Facebook::AuthenticationError) || error.fb_error_code.to_i == 190
  end

  def request_error_reason(error)
    return :rate_limit if rate_limit_failure?(error)

    :retry_exhausted
  end

  def backoff_seconds(attempt)
    ceiling = [2**(attempt - 1), MAX_BACKOFF_SECONDS].min
    @random.rand * ceiling
  end

  def api
    @api ||= if @rate_controller
               Umi::Fbig::SanitizedKoalaApi.new(
                 @channel.page_access_token,
                 usage_observer: ->(usage) { @rate_controller.observe(usage) }
               )
             else
               Koala::Facebook::API.new(@channel.page_access_token)
             end
  end

  def sleep_graph_delay!
    return unless @delay_seconds.positive?

    raise LeaseLostError if @renewer && !@renewer.call

    @sleeper.sleep(@delay_seconds)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists
# rubocop:enable Metrics/PerceivedComplexity
