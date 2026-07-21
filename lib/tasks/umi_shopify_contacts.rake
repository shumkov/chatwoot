# frozen_string_literal: true

# UMI: one-time (or reconcile) backfill of all Shopify customers into Chatwoot
# contacts. Idempotent — matching is by email/phone with a shopify_customer_id
# identity guard, so re-running updates/repairs rather than duplicates. The
# chain is throttled (one page per job, spaced) and single-writer (Redis sync
# lock shared with the incremental poll).
#
#   bundle exec rake umi:shopify_contacts:backfill[account_id]
#
# After the chain finishes, verify the watermark exists in the shopify hook's
# settings (umi_contact_sync_watermark) — its absence means the chain died (the
# failure is also reported to the exception tracker).
namespace :umi do
  namespace :shopify_contacts do
    desc 'Backfill all Shopify customers into Chatwoot contacts (seed/repair; see UMI-SHOPIFY-CONTACT-SYNC-SPEC.md)'
    task :backfill, [:account_id] => :environment do |_t, args|
      account_id = args[:account_id].to_i
      abort('Usage: rake umi:shopify_contacts:backfill[account_id]') if account_id.zero?

      hook = Umi::Shopify::ClientFactory.hook_for(account_id)
      abort("No Shopify integration hook with a token for account #{account_id}") if hook.nil? || hook.access_token.blank?
      unless hook.enabled? && hook.settings.to_h['scope'].to_s.split(',').map(&:strip).include?('read_customers')
        abort("Shopify hook for account #{account_id} is disabled or lacks the read_customers scope — reconnect the integration first")
      end

      run_id = SecureRandom.uuid
      run_started_at = Time.current.utc.iso8601
      unless Umi::Shopify::SyncLock.acquire(account_id, run_id, ttl: Umi::Shopify::ContactBackfillJob::LOCK_TTL)
        abort("A Shopify contact sync is already running for account #{account_id} (lock held); " \
              'wait for it to finish or for the lock TTL to expire.')
      end

      Umi::Shopify::ContactBackfillJob.perform_later(account_id, run_id, run_started_at)
      puts "Enqueued Shopify contact backfill for account #{account_id} (run #{run_id})."
      puts 'When the chain completes, verify hook.settings["umi_contact_sync_watermark"] is set.'
    end
  end
end
