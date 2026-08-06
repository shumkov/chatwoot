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
  # Above this share of outright Graph failures, assume Meta is refusing us
  # rather than genuinely having no data for these people. Continuing would
  # burn a whole cycle's quota against an outage.
  MAX_FAILURE_RATE = 0.8
  MIN_SAMPLE_FOR_STANDDOWN = 10

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
    run_id = SecureRandom.uuid
    Channel::FacebookPage.find_each { |channel| refresh_channel(channel, run_id, apply, cap) }
  end

  private

  def refresh_channel(channel, run_id, apply, cap)
    stats = Hash.new(0)
    service = Umi::Fbig::ProfileEnrichmentService.new(channel, run_id: run_id, apply: apply)
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

  def throttled?(stats)
    attempted = stats.values.sum
    return false if attempted < MIN_SAMPLE_FOR_STANDDOWN

    (stats[:failed].to_f / attempted) > MAX_FAILURE_RATE
  end

  def stand_down!(stats)
    raise Throttled, "resolution rate below floor after #{stats.values.sum} contacts"
  end
end
