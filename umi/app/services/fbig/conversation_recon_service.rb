# frozen_string_literal: true

# Daily reconciliation of a Facebook-page channel (Messenger + linked
# Instagram) against Meta's Conversations API — the ground truth for which
# messages exist. Webhook-side code cannot see messages Meta never delivered
# (subscription outages, misconfigured fields, drops predating the pipeline
# patches); this service lists every in-window message id from the API and
# anti-joins against messages.source_id, reporting what Chatwoot is missing.
#
# Design record: docs/UMI-FBIG-RECON-SPEC.md. Detection is read-only; the
# optional heal pass (UMI_FBIG_RECON_HEAL=true) replays missing INBOUND
# messages through the regular webhook builders via Umi::Fbig::MessageHealService.
#
# Reporting contract (grep-able, consumed by the trail cron + future alert):
#   [UMI-FBIG] stage=reconcile_missing platform=… thread=… mid=… created=…
#              direction=in|out sender=… [suspect=multipart]
#   [UMI-FBIG] stage=reconcile_summary platform=… threads=… mids=… missing=…
#              missing_suspect=… healed=… heal_failed=… threads_failed=…
#              caps_hit=… [missing_lines_capped=true] [error=…]
# The summary is emitted for every platform on every run, including failures.
class Umi::Fbig::ConversationReconService
  # The 48 h window is structurally coupled to the daily cron cadence: every
  # period is covered by two consecutive runs, so one failed run leaves no
  # gap. Change them together or not at all.
  WINDOW_HOURS = 48
  # Webhooks still in flight are not "missing" yet.
  RECENT_GRACE_MINUTES = 15
  # Meta can return entries slightly out of order when a thread is touched
  # mid-pagination; stopping on the first out-of-window entry would silently
  # under-cover, so require several consecutive ones.
  OUT_OF_WINDOW_STOP = 3
  MAX_THREAD_PAGES = 20
  MAX_MESSAGE_PAGES = 10
  # A systematic false-positive class must not flood the trail or the alert;
  # the summary always carries the full missing count.
  MAX_MISSING_LINES = 20
  MAX_HEALS_PER_PLATFORM = 10
  # A missing outbound mid within this distance of an existing outgoing row is
  # almost certainly a lost part of a multi-part send (each part's send call
  # overwrites the same row's source_id), not a genuinely absent message.
  MULTIPART_SUSPECT_RANGE = 90.seconds
  PLATFORMS = %w[messenger instagram].freeze

  def initialize(channel)
    @channel = channel
    @window_start = WINDOW_HOURS.hours.ago
    @grace_end = RECENT_GRACE_MINUTES.minutes.ago
  end

  def perform
    @fatal = nil
    @auth_failed = false
    PLATFORMS.each do |platform|
      break if @auth_failed

      recon_platform(platform)
    end
    # Non-auth platform errors are transient candidates: surface one so the
    # job retries; the summary lines already recorded the partial coverage.
    raise @fatal if @fatal
  end

  private

  def recon_platform(platform)
    @stats = { threads: 0, mids: 0, missing: 0, missing_suspect: 0, healed: 0,
               heal_failed: 0, threads_failed: 0, caps_hit: 0 }
    @heal_budget = MAX_HEALS_PER_PLATFORM
    error = nil
    each_in_window_thread(platform) { |thread_id| recon_thread(platform, thread_id) }
  rescue Koala::Facebook::AuthenticationError => e
    # A 401 is not transient: retrying 3x daily adds sustained errors against
    # Meta (a subscription-health risk) for zero benefit. Log and stand down;
    # the send path owns reauthorization semantics.
    error = e
    @auth_failed = true
  rescue StandardError => e
    error = e
    @fatal ||= e
  ensure
    fields = { platform: platform }.merge(@stats)
    fields[:error] = error.class.name if error
    log(:reconcile_summary, fields)
  end

  def recon_thread(platform, thread_id)
    entries = in_window_messages(thread_id)
    @stats[:mids] += entries.size
    report_missing(platform, thread_id, entries)
  rescue Koala::Facebook::AuthenticationError
    raise
  rescue StandardError
    @stats[:threads_failed] += 1
  end

  def each_in_window_thread(platform)
    out_of_window = 0
    paginate(threads_first_page(platform), MAX_THREAD_PAGES) do |thread|
      updated = Time.zone.parse(thread['updated_time'].to_s)
      if updated && updated < @window_start
        out_of_window += 1
        next(out_of_window < OUT_OF_WINDOW_STOP ? :continue : :stop)
      end
      out_of_window = 0
      @stats[:threads] += 1
      yield thread['id']
      :continue
    end
  end

  def in_window_messages(thread_id)
    entries = []
    out_of_window = 0
    first_page = api.get_connections(thread_id, 'messages',
                                     { fields: 'id,created_time,from', limit: 50 })
    paginate(first_page, MAX_MESSAGE_PAGES) do |message|
      created = Time.zone.parse(message['created_time'].to_s)
      next :continue if created.nil? || created > @grace_end

      if created < @window_start
        out_of_window += 1
        next(out_of_window < OUT_OF_WINDOW_STOP ? :continue : :stop)
      end
      out_of_window = 0
      entries << { mid: message['id'], created: created, from_id: message.dig('from', 'id') }
      :continue
    end
    entries
  end

  # Yields each item; the block returns :continue or :stop. Counts a caps_hit
  # only when the page budget runs out with data still unread (a cursor for a
  # further page exists) — an exactly-at-budget collection is fully covered.
  def paginate(collection, max_pages)
    pages = 0
    while collection
      pages += 1
      collection.each do |item|
        return nil if yield(item) == :stop
      end
      if pages >= max_pages
        @stats[:caps_hit] += 1 if next_page_available?(collection)
        return nil
      end
      collection = collection.respond_to?(:next_page) ? collection.next_page : nil
    end
  end

  def next_page_available?(collection)
    collection.respond_to?(:paging) && collection.paging&.key?('next')
  end

  def threads_first_page(platform)
    api.get_connections(@channel.page_id, 'conversations',
                        { platform: platform, fields: 'id,updated_time', limit: 50 })
  end

  def report_missing(platform, thread_id, entries)
    mids = entries.pluck(:mid)
    present = @channel.inbox.account.messages.where(source_id: mids).pluck(:source_id).to_set
    entries.reject { |entry| present.include?(entry[:mid]) }.each do |entry|
      handle_missing(platform, thread_id, entry)
    end
  end

  def handle_missing(platform, thread_id, entry)
    direction = own_identity?(entry[:from_id]) ? 'out' : 'in'
    suspect = direction == 'out' && multipart_suspect?(entry[:created])
    @stats[:missing] += 1
    @stats[:missing_suspect] += 1 if suspect
    log_missing_line(platform, thread_id, entry, direction, suspect)
    heal(platform, entry) if direction == 'in' && heal_enabled?
  end

  def log_missing_line(platform, thread_id, entry, direction, suspect)
    if @stats[:missing] > MAX_MISSING_LINES
      @stats[:missing_lines_capped] = true
      return
    end
    fields = { platform: platform, thread: thread_id, mid: entry[:mid], created: entry[:created].iso8601,
               direction: direction, sender: entry[:from_id] }
    fields[:suspect] = 'multipart' if suspect
    log(:reconcile_missing, fields)
  end

  def heal(platform, entry)
    return if @heal_budget.zero?

    @heal_budget -= 1
    result = Umi::Fbig::MessageHealService.new(@channel, platform).heal(entry[:mid])
    if result == :healed
      @stats[:healed] += 1
    else
      @stats[:heal_failed] += 1
      log(:heal_skipped, platform: platform, mid: entry[:mid], reason: result)
    end
  end

  def heal_enabled?
    ENV['UMI_FBIG_RECON_HEAL'] == 'true'
  end

  def multipart_suspect?(created_at)
    @channel.inbox.messages.outgoing
            .exists?(created_at: (created_at - MULTIPART_SUSPECT_RANGE)..(created_at + MULTIPART_SUSPECT_RANGE))
  end

  def own_identity?(from_id)
    [@channel.page_id, @channel.instagram_id].compact.include?(from_id.to_s)
  end

  def api
    @api ||= Koala::Facebook::API.new(@channel.page_access_token)
  end

  # Same grep prefix as Umi::FbigTrace, deliberately not the same code — this
  # patch stays removable independently of the trace patch.
  def log(stage, fields)
    line = "[UMI-FBIG] stage=#{stage}"
    fields.each { |key, value| line += " #{key}=#{value}" unless value.nil? }
    healthy_summary?(stage, fields) ? Rails.logger.info(line) : Rails.logger.warn(line)
  end

  # Multipart-suspect misses are an expected artifact of multi-part sends,
  # not a health problem — severity keys on hard misses only.
  def healthy_summary?(stage, fields)
    stage == :reconcile_summary &&
      (fields[:missing].to_i - fields[:missing_suspect].to_i).zero? &&
      fields.values_at(:threads_failed, :caps_hit).all? { |v| v.to_i.zero? } &&
      fields[:error].nil?
  end
end
