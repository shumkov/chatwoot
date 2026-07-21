# frozen_string_literal: true

# UMI patch: the incremental-sync watermark, stored in the Shopify hook's
# settings jsonb. The watermark is the *start* time of the last fully successful
# run — anything Shopify updated mid-run is re-fetched by the next poll.
#
# Writes always re-find the hook by id first: an OAuth reconnect destroys and
# recreates the hook, and update! on a stale instance silently updates zero rows.
# A missing watermark means "backfill needed" — the poll refuses to sync from
# epoch.
module Umi::Shopify::ContactSyncWatermark
  KEY = 'umi_contact_sync_watermark'

  class << self
    def read(hook)
      hook.settings.to_h[KEY]
    end

    def write(hook_id, timestamp)
      hook = Integrations::Hook.find_by(id: hook_id)
      if hook.nil?
        message = "[umi-contact-sync] hook #{hook_id} vanished before watermark write (reconnect?) — re-run the backfill"
        ChatwootExceptionTracker.new(StandardError.new(message)).capture_exception
        Rails.logger.error(message)
        return false
      end

      hook.update!(settings: hook.settings.to_h.merge(KEY => timestamp))
      true
    end
  end
end
