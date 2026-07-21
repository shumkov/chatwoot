# frozen_string_literal: true

# UMI patch: single-writer lock for the Shopify customer → contact sync. Every
# writer (the backfill page chain, the incremental poll) takes the same
# per-account Redis key, so concurrent chains, poll-vs-backfill interleaving and
# watermark regressions are excluded by construction.
#
# Redis, not Rails.cache: the production cache store is per-container FileStore,
# which cannot lock across the rake/web/Sidekiq processes (and the test store is
# a null store — a cache-based lock would never actually hold anywhere).
module Umi::Shopify::SyncLock
  KEY_PREFIX = 'UMI_SHOPIFY_CONTACT_SYNC_LOCK::'

  class << self
    # Atomic check-and-set; returns truthy only when the lock was free.
    def acquire(account_id, run_id, ttl:)
      Redis::Alfred.set(key(account_id), run_id, nx: true, ex: ttl.to_i)
    end

    # A page job re-checks ownership before writing: if the TTL expired and
    # another run took over, the stale chain must abort rather than interleave.
    def held_by?(account_id, run_id)
      Redis::Alfred.get(key(account_id)) == run_id
    end

    # Compare-and-delete — releases only if this run still owns the lock.
    def release(account_id, run_id)
      Redis::Alfred.delete_if_equals(key(account_id), run_id)
    end

    def key(account_id)
      "#{KEY_PREFIX}#{account_id}"
    end
  end
end
