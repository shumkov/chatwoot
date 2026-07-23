# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity
# Reads the Meta Conversations API with bounded pagination, throttling, and
# retry classification. Cursor values stay inside this object so signed paging
# URLs cannot leak into importer logs.
class Umi::Fbig::HistoryImportGraphClient
  PageResult = Data.define(:items, :pages)

  class PaginationError < StandardError; end
  class AuthenticationError < StandardError; end

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

  def initialize(channel, delay_ms:, max_conversation_pages:, max_message_pages:, sleeper: Kernel, random: Random)
    @channel = channel
    @delay_seconds = delay_ms.to_f / 1000
    @max_conversation_pages = max_conversation_pages
    @max_message_pages = max_message_pages
    @sleeper = sleeper
    @random = random
  end

  def each_thread(platform, on_page: nil, &)
    first_page = request do
      api.get_connections(@channel.page_id, 'conversations',
                          { platform: platform, fields: CONVERSATION_FIELDS, limit: 50 })
    end
    paginate(first_page, kind: :conversation, max_pages: @max_conversation_pages, on_page: on_page, &)
  end

  def messages(thread_id, on_page: nil)
    first_page = request do
      api.get_connections(thread_id, 'messages', { fields: MESSAGE_FIELDS, limit: 50 })
    end
    items = []
    pages = paginate(first_page, kind: :message, max_pages: @max_message_pages, on_page: on_page) { |message| items << message }
    PageResult.new(items: items, pages: pages)
  end

  def detail(mid)
    request { api.get_object(mid, { fields: DETAIL_FIELDS }) }
  rescue Koala::Facebook::ClientError
    nil
  end

  private

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

      collection = request { collection.next_page }
      raise PaginationError, "#{kind} next page missing" if collection.nil?
    end
    pages
  end

  def request
    attempts = 0
    begin
      attempts += 1
      yield
    rescue StandardError => e
      raise AuthenticationError, e.class.name if e.is_a?(Koala::Facebook::APIError) && authentication_error?(e)
      raise unless retryable?(e)
      raise RequestError, request_error_reason(e) if attempts >= MAX_ATTEMPTS

      @sleeper.sleep(backoff_seconds(attempts))
      retry
    ensure
      @sleeper.sleep(@delay_seconds) if @delay_seconds.positive?
    end
  end

  def retryable?(error)
    RETRYABLE_NETWORK_ERRORS.any? { |error_class| error.is_a?(error_class) } ||
      (error.is_a?(Koala::Facebook::APIError) && retryable_api_error?(error))
  end

  def retryable_api_error?(error)
    status = error.http_status.to_i
    status == 429 || status >= 500 || RATE_LIMIT_CODES.include?(error.fb_error_code.to_i)
  end

  def authentication_error?(error)
    error.is_a?(Koala::Facebook::AuthenticationError) || error.fb_error_code.to_i == 190
  end

  def request_error_reason(error)
    return :rate_limit if error.is_a?(Koala::Facebook::APIError) &&
                          (error.http_status.to_i == 429 || RATE_LIMIT_CODES.include?(error.fb_error_code.to_i))

    :retry_exhausted
  end

  def backoff_seconds(attempt)
    ceiling = [2**(attempt - 1), MAX_BACKOFF_SECONDS].min
    @random.rand * ceiling
  end

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end
end
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity
