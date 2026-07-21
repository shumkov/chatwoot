# frozen_string_literal: true

# UMI patch: one page of the Shopify customer backfill. Fetches ≤250 customers,
# upserts them, and self-enqueues the next page (cursor carried in job args, so a
# retry resumes exactly where it died). The final page writes the incremental
# watermark (= the run's start time) and releases the sync lock.
#
# Retry posture: the global Sidekiq config caps retries at 3 (~a 3-minute
# window), far too short to ride out a Shopify blip mid-chain — a dead page job
# silently kills every remaining page. So transient errors (429/5xx AND
# transport-level failures, which shopify_api does not wrap) get their own
# retry_on with polynomial backoff (~78 min cumulative, within the lock TTL),
# and exhaustion is loud: tracker + lock release. Permanent 4xx (token revoked,
# scope lost) stop the chain immediately. Every permanent exit releases the
# lock — the chain owns it once the rake task hands over.
class Umi::Shopify::ContactBackfillJob < ApplicationJob
  queue_as :low

  class RetryableError < StandardError; end

  LOCK_TTL = 6.hours
  PAGE_LIMIT = 250
  RERUN_HINT = 're-run `rake umi:shopify_contacts:backfill[account_id]`'
  # Connection-level failures HTTParty lets through raw (shopify_api only wraps
  # HTTP-status errors) — all as transient as a 429.
  TRANSPORT_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, IOError,
    Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, JSON::ParserError
  ].freeze

  retry_on RetryableError, wait: :polynomially_longer, attempts: 8 do |job, error|
    account_id, run_id, = job.arguments
    Umi::Shopify::SyncLock.release(account_id, run_id)
    ChatwootExceptionTracker.new(error).capture_exception
    Rails.logger.error("[umi-contact-sync] backfill chain died after retries for account #{account_id}: #{error.message} " \
                       "— #{RERUN_HINT}")
  end

  def perform(account_id, run_id, run_started_at, page_info = nil)
    @account_id = account_id
    @run_id = run_id
    @run_started_at = run_started_at

    hook = Umi::Shopify::ClientFactory.hook_for(account_id)
    return unusable_hook_abort if unusable?(hook)
    return lock_lost unless Umi::Shopify::SyncLock.held_by?(account_id, run_id)

    client = Umi::Shopify::ClientFactory.client_for(hook)
    return unless page_info.present? || within_ceiling?(client)

    process_page(hook, client, page_info)
  rescue ShopifyAPI::Errors::HttpResponseError => e
    handle_http_error(e, hook)
  rescue *TRANSPORT_ERRORS => e
    raise RetryableError, "shopify transport error: #{e.class}: #{e.message}"
  end

  private

  def unusable?(hook)
    hook.blank? || !hook.enabled? || hook.access_token.blank? ||
      hook.settings.to_h['scope'].to_s.split(',').map(&:strip).exclude?('read_customers')
  end

  def process_page(hook, client, page_info)
    response = fetch_page(client, page_info)
    counters = Umi::Shopify::ContactSyncService.new(account: hook.account, customers: response.body['customers'] || [], mode: :bulk).perform
    Rails.logger.info("[umi-contact-sync] backfill page done for account #{@account_id}: #{counters.inspect}")

    next_cursor = response.next_page_info
    if next_cursor.present?
      self.class.set(wait: page_wait).perform_later(@account_id, @run_id, @run_started_at, next_cursor)
    else
      finish(hook)
    end
  end

  def fetch_page(client, page_info)
    query = { limit: PAGE_LIMIT }
    query[:page_info] = page_info if page_info.present?
    client.get(path: 'customers.json', query: query)
  end

  def finish(hook)
    Umi::Shopify::ContactSyncWatermark.write(hook.id, @run_started_at)
    Umi::Shopify::SyncLock.release(@account_id, @run_id)
    Rails.logger.info("[umi-contact-sync] backfill complete for account #{@account_id} (run #{@run_id}); watermark #{@run_started_at}")
  end

  def within_ceiling?(client)
    count = client.get(path: 'customers/count.json').body['count'].to_i
    ceiling = ENV.fetch('UMI_SHOPIFY_CONTACT_SYNC_MAX_CUSTOMERS', '20000').to_i
    Rails.logger.info("[umi-contact-sync] backfill starting for account #{@account_id}: #{count} customers, " \
                      "~#{(count / PAGE_LIMIT.to_f).ceil} pages")
    return true if count <= ceiling

    Umi::Shopify::SyncLock.release(@account_id, @run_id)
    Rails.logger.error("[umi-contact-sync] backfill aborted: #{count} customers exceeds ceiling #{ceiling} " \
                       '(UMI_SHOPIFY_CONTACT_SYNC_MAX_CUSTOMERS) — see the spec §6 scale matrix before raising it')
    false
  end

  # Permanent: a chain that can never proceed must not strand the lock for the
  # 6h TTL (polls would skip as "lock held" the whole time), and must page.
  def unusable_hook_abort
    Umi::Shopify::SyncLock.release(@account_id, @run_id)
    message = "[umi-contact-sync] no usable shopify hook for account #{@account_id} (missing/disabled/tokenless/" \
              "no read_customers scope) — backfill aborted; reconnect the integration and #{RERUN_HINT}"
    ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
    Rails.logger.error(message)
  end

  # The lock TTL expired and another run may own the account now — a stale chain
  # must abort loudly rather than interleave writes with the new owner.
  def lock_lost
    message = "[umi-contact-sync] backfill run #{@run_id} lost the sync lock for account #{@account_id} — " \
              "chain aborted; #{RERUN_HINT}"
    ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
    Rails.logger.error(message)
  end

  def handle_http_error(error, hook)
    status = error.respond_to?(:code) ? error.code : nil
    raise RetryableError, "shopify #{status || '?'}: #{error.message}" if status.nil? || status == 429 || status >= 500

    ChatwootExceptionTracker.new(error, account: hook&.account).capture_exception
    Umi::Shopify::SyncLock.release(@account_id, @run_id)
    Rails.logger.error("[umi-contact-sync] backfill aborted on shopify #{status} for account #{@account_id}: #{error.message}")
  end

  def page_wait
    ENV.fetch('UMI_SHOPIFY_CONTACT_SYNC_PAGE_WAIT_SECONDS', '3').to_i.seconds
  end
end
