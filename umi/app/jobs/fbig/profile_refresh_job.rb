# frozen_string_literal: true

# Nightly entry point for FB/IG contact profile enrichment
# (docs/UMI-FBIG-PROFILE-REFRESH-SPEC.md). Registered by
# config/initializers/zz_umi_fbig_profile_refresh.rb.
#
# Serial Graph HTTP for potentially minutes — must not occupy a default-queue
# worker. Runs the backlog first (never-checked contacts sort ahead of
# everything else), then rotates the population on a rolling cycle.
class Umi::Fbig::ProfileRefreshJob < ApplicationJob
  queue_as :low

  Throttled = Class.new(StandardError)

  CYCLE_CAP = 40
  # Business Discovery is a second Graph call per contact, so it gets its own
  # budget rather than enlarging the first pass. Meta's hourly app quota is
  # shared with live message delivery — an investigation's ~550 calls took it
  # to 94% — so this pass is deliberately slow: it drains the ~120 contacts the
  # profile API refuses in about five nights and sweeps the rest of the
  # Instagram population over about a month.
  DISCOVERY_CAP = 25
  # Follower counts barely move: measured across 60 contacts over a month, the
  # median change was 6 followers and none moved by more than 10%, so nobody
  # crosses an audience band. Re-asking quarterly keeps the data honest without
  # spending quota on a number that has not changed.
  DISCOVERY_COOLDOWN = 90.days
  # Above this share of outright Graph failures, assume Meta is refusing us
  # rather than genuinely having no data for these people. Continuing would
  # burn a whole cycle's quota against an outage.
  MAX_FAILURE_RATE = 0.8
  MIN_SAMPLE_FOR_STANDDOWN = 10

  DISCOVERY_STAMP = Umi::Fbig::ProfileEnrichmentService::DISCOVERY_STAMP
  # Postgres regex rather than a Ruby filter: a contact rejected in Ruby would
  # still have consumed a slot of the cap, so a whole cycle could be spent
  # selecting Facebook contacts and asking Meta about none of them.
  HANDLE_KNOWN_SQL = "additional_attributes ? 'social_instagram_user_name' OR (" \
                     "additional_attributes->>'umi_profile_name' = contacts.name AND contacts.name ~ :handle)"
  # Never asked, or asked longer ago than the cooldown. Compared as a timestamp
  # rather than as text: the stamps carry a zone offset, and two offsets sort
  # against each other wrongly as strings.
  DISCOVERY_DUE_SQL = "NOT (additional_attributes ? '#{DISCOVERY_STAMP}') " \
                      "OR (additional_attributes->>'#{DISCOVERY_STAMP}')::timestamptz < :cutoff".freeze
  # No avatar, or no follower count: what the messaging profile API failed to
  # deliver and Business Discovery exists to supply.
  GAP_SQL = "NOT (contacts.additional_attributes ? 'social_instagram_follower_count') " \
            'OR NOT EXISTS (SELECT 1 FROM active_storage_attachments a ' \
            "WHERE a.record_type = 'Contact' AND a.record_id = contacts.id AND a.name = 'avatar')"

  # Options arrive as a plain hash rather than keywords: Sidekiq serializes job
  # arguments to JSON, so a keyword signature would receive a positional hash
  # from the cron entry and fail to bind.
  def perform(options = {})
    # Retention and erasure propagation run even when enrichment is switched
    # off: the ledger holds customer names and handles, so leaving it frozen
    # would turn the kill switch into an indefinite PII store — precisely when
    # someone reaches for it because something went wrong.
    sweep = Umi::ProfileLedgerEntry.sweep!
    Umi::FbigTrace.log(:profile_ledger_swept, **sweep)

    return if ENV['UMI_FBIG_PROFILE_REFRESH_DISABLED'] == 'true'

    options = options.symbolize_keys
    apply = options.fetch(:apply, false)
    cap = options.fetch(:cap, CYCLE_CAP)
    discovery_cap = options.fetch(:discovery_cap, DISCOVERY_CAP)
    run_id = SecureRandom.uuid
    Channel::FacebookPage.find_each do |channel|
      enrichment = Umi::Fbig::ProfileEnrichmentService.new(channel, run_id: run_id, apply: apply)
      refresh_channel(channel, enrichment, run_id, apply, cap)
      discover_channel(channel, Umi::Fbig::BusinessDiscoveryEnrichment.new(channel, enrichment), run_id, apply, discovery_cap)
    end
  end

  private

  def refresh_channel(channel, service, run_id, apply, cap)
    stats = Hash.new(0)
    contacts = due_contacts(channel, cap)

    contacts.each do |contact|
      stats[service.enrich(contact).status] += 1
      stand_down!(stats) if throttled?(stats)
    end
  rescue Koala::Facebook::AuthenticationError => e
    # Sustained 4xx against Meta is itself a subscription-health risk; the send
    # path owns reauthorization. Stand down rather than retry three times.
    Umi::FbigTrace.log(:profile_summary, channel: channel.id, error: e.class.name, **stats)
  rescue Throttled => e
    Umi::FbigTrace.log(:profile_summary, channel: channel.id, error: 'throttled', reason: e.message, **stats)
  else
    Umi::FbigTrace.log(:profile_summary, channel: channel.id, run: run_id, apply: apply, **stats)
  end

  def discover_channel(channel, discovery, run_id, apply, cap)
    return if cap.to_i.zero?

    stats = Hash.new(0)
    discovery_candidates(channel, cap).each do |contact|
      stats[discovery.discover(contact).status] += 1
      stand_down!(stats) if throttled?(stats)
    end
  rescue Koala::Facebook::AuthenticationError => e
    Umi::FbigTrace.log(:business_discovery_summary, channel: channel.id, error: e.class.name, **stats)
  rescue Throttled => e
    Umi::FbigTrace.log(:business_discovery_summary, channel: channel.id, error: 'throttled', reason: e.message, **stats)
  else
    Umi::FbigTrace.log(:business_discovery_summary, channel: channel.id, run: run_id, apply: apply, **stats)
  end

  # EXISTS rather than a join: SELECT DISTINCT with an ORDER BY on a jsonb
  # expression is a Postgres error, and without DISTINCT the join duplicates
  # contacts and silently halves the cap. NULLS FIRST is explicit because
  # Postgres defaults ASC to NULLS LAST, which would sort the entire
  # never-checked backlog to the back.
  def due_contacts(channel, cap)
    inbox = channel.inbox
    return Contact.none if inbox.nil?

    Contact.where(
      'EXISTS (SELECT 1 FROM contact_inboxes WHERE contact_inboxes.contact_id = contacts.id AND contact_inboxes.inbox_id = ?)',
      inbox.id
    ).where("COALESCE(additional_attributes->>'umi_profile_redacted', 'false') != 'true'")
           .order(Arel.sql("contacts.additional_attributes->>'umi_profile_checked_at' ASC NULLS FIRST"))
           .limit(cap)
  end

  # Only contacts Business Discovery can actually be asked about: an Instagram
  # handle must already be known, either stored or as a name this patch wrote
  # and still owns. Contacts asked within the cooldown are excluded outright —
  # that exclusion, not the cap alone, is what makes this pass go quiet instead
  # of re-asking the same 682 people every night.
  #
  # Ordered gap-first so the contacts with no avatar and no follower count —
  # the ones the profile API refuses, where the influencers turned out to be
  # hiding — drain before the sweep of contacts we already cover.
  def discovery_candidates(channel, cap)
    inbox = channel.inbox
    return Contact.none if inbox.nil?

    Contact.where(
      'EXISTS (SELECT 1 FROM contact_inboxes WHERE contact_inboxes.contact_id = contacts.id AND contact_inboxes.inbox_id = ?)',
      inbox.id
    ).where("COALESCE(additional_attributes->>'umi_profile_redacted', 'false') != 'true'")
           .where(HANDLE_KNOWN_SQL, handle: Umi::Fbig::BusinessDiscoveryService::HANDLE_SQL)
           .where(DISCOVERY_DUE_SQL, cutoff: DISCOVERY_COOLDOWN.ago)
           .order(Arel.sql("CASE WHEN #{GAP_SQL} THEN 0 ELSE 1 END"))
           .order(Arel.sql("contacts.additional_attributes->>'#{DISCOVERY_STAMP}' ASC NULLS FIRST"))
           .limit(cap)
  end

  def throttled?(stats)
    attempted = stats.values.sum
    return false if attempted < MIN_SAMPLE_FOR_STANDDOWN

    (stats[:failed].to_f / attempted) > MAX_FAILURE_RATE
  end

  def stand_down!(stats)
    raise Throttled, "resolution rate below floor after #{stats.values.sum} contacts"
  end
end
