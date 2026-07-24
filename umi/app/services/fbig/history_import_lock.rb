# frozen_string_literal: true

# Serializes FB/IG repair writers for one channel. The renewable lease keeps a
# long history import exclusive while still recovering automatically if its
# process exits without releasing the key.
module Umi::Fbig::HistoryImportLock
  KEY_PREFIX = 'UMI_FBIG_HISTORY_IMPORT_LOCK::'
  LEASE_TTL = 15.minutes.to_i
  RENEW_INTERVAL = 5.minutes.to_i

  class << self
    def acquire(channel_id, run_id, ttl: LEASE_TTL)
      Redis::Alfred.set(key(channel_id), run_id, nx: true, ex: ttl.to_i)
    end

    def renew(channel_id, run_id, ttl: LEASE_TTL)
      result = Redis::Alfred.with do |connection|
        connection.watch(key(channel_id)) do
          next false unless connection.get(key(channel_id)) == run_id

          connection.multi { |transaction| transaction.expire(key(channel_id), ttl.to_i) }
        end
      end
      result.present?
    end

    def held_by?(channel_id, run_id)
      Redis::Alfred.get(key(channel_id)) == run_id
    end

    def release(channel_id, run_id)
      Redis::Alfred.delete_if_equals(key(channel_id), run_id)
    end

    def key(channel_id)
      "#{KEY_PREFIX}#{channel_id}"
    end
  end
end
