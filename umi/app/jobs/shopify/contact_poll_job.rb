# frozen_string_literal: true

# UMI patch: incremental Shopify customer poll (cron-registered when
# UMI_SHOPIFY_CONTACT_SYNC_ENABLED). Fetches customers updated since the
# watermark (minus a 5-minute overlap for clock skew / read-visibility lag) and
# upserts them per-record so contact events fire.
#
# The watermark only advances after ALL pages succeed — REST results are
# id-ordered, not update-ordered, so a partial advance would drop updates
# permanently. Errors are swallowed loudly (tracker) without advancing: the next
# cron tick is the retry, which avoids overlapping runs piling up on the starved
# :low queue. Deletions are invisible to updated_at_min polling by design
# (see the spec §3e) — non-redact deletions wait for a backfill re-run.
class Umi::Shopify::ContactPollJob < ApplicationJob
  queue_as :low

  LOCK_TTL = 25.minutes
  OVERLAP = 5.minutes
  PAGE_LIMIT = 250

  class PageCapExceeded < StandardError; end

  def perform
    Integrations::Hook.where(app_id: 'shopify', status: :enabled).find_each do |hook|
      next if hook.access_token.blank?

      poll_hook(hook)
    end
  rescue StandardError => e
    # Nothing outside poll_hook's own rescue may bubble to the adapter — a
    # Sidekiq-level retry would replay the whole multi-hook loop; the next cron
    # tick is the retry.
    ChatwootExceptionTracker.new(e).capture_exception
    Rails.logger.error("[umi-contact-sync] poll run failed before/outside a hook sync: #{e.message}")
  end

  private

  def poll_hook(hook)
    run_id = @run_id = SecureRandom.uuid
    run_started_at = Time.current.utc.iso8601
    # Held lock = a backfill chain or the previous poll is still running; skip
    # this tick rather than interleave writers.
    return Rails.logger.info("[umi-contact-sync] poll skipped for account #{hook.account_id}: sync lock held") unless
      Umi::Shopify::SyncLock.acquire(hook.account_id, run_id, ttl: LOCK_TTL)

    begin
      run_sync(hook, run_started_at)
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: hook.account).capture_exception
      Rails.logger.error("[umi-contact-sync] poll failed for account #{hook.account_id} (watermark not advanced): #{e.message}")
    ensure
      Umi::Shopify::SyncLock.release(hook.account_id, run_id)
    end
  end

  def run_sync(hook, run_started_at)
    watermark = Umi::Shopify::ContactSyncWatermark.read(hook)
    if watermark.blank?
      # The only symptom of a dead backfill chain or wiped settings — must stay
      # loud on every run, never a one-time info line.
      Rails.logger.error("[umi-contact-sync] account #{hook.account_id}: no watermark — backfill needed, poll skipped")
      return
    end

    sync_changes(hook, watermark)
    advance_watermark(hook, run_started_at)
  end

  # A run that outlived its lock TTL has lost ownership to a newer tick — its
  # (older) run_started_at must not regress the watermark the new run will write.
  def advance_watermark(hook, run_started_at)
    unless Umi::Shopify::SyncLock.held_by?(hook.account_id, @run_id)
      Rails.logger.error("[umi-contact-sync] poll run for account #{hook.account_id} outlived its lock — " \
                         'watermark not advanced (newer run owns it)')
      return
    end

    Umi::Shopify::ContactSyncWatermark.write(hook.id, run_started_at)
  end

  def sync_changes(hook, watermark)
    client = Umi::Shopify::ClientFactory.client_for(hook)
    cursor = nil
    pages = 0

    loop do
      pages += 1
      if pages > max_pages
        raise PageCapExceeded, "poll exceeded #{max_pages} pages for account #{hook.account_id} — " \
                               "run `rake umi:shopify_contacts:backfill[#{hook.account_id}]` instead"
      end

      response = fetch_page(client, watermark, cursor)
      counters = Umi::Shopify::ContactSyncService.new(account: hook.account, customers: response.body['customers'] || [],
                                                      mode: :per_record).perform
      Rails.logger.info("[umi-contact-sync] poll page #{pages} for account #{hook.account_id}: #{counters.inspect}")

      cursor = response.next_page_info
      break if cursor.blank?
    end
  end

  # Cursor pages must carry ONLY page_info + limit — Shopify 400s when a filter
  # param is combined with a cursor (the filter is baked into the cursor).
  def fetch_page(client, watermark, cursor)
    query = if cursor.present?
              { limit: PAGE_LIMIT, page_info: cursor }
            else
              { limit: PAGE_LIMIT, updated_at_min: (Time.zone.parse(watermark) - OVERLAP).utc.iso8601 }
            end
    client.get(path: 'customers.json', query: query)
  end

  def max_pages
    ENV.fetch('UMI_SHOPIFY_CONTACT_SYNC_POLL_MAX_PAGES', '20').to_i
  end
end
