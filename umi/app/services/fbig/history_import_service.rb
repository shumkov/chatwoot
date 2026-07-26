# frozen_string_literal: true

require 'active_storage/service/mirror_service'

# The importer keeps trust-boundary validation and callback-free persistence in
# one auditable unit because partial reuse of ordinary model writers is unsafe.
# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity, Rails/SkipsModelValidations
class Umi::Fbig::HistoryImportService
  Result = Data.define(:stats, :scan_complete, :write_complete, :degraded, :dry_run) do
    def success?
      scan_complete && write_complete != false && stats[:exit_failures].zero?
    end

    def attachments_downloadable
      dry_run ? 'unknown' : stats[:attachments_downloaded]
    end
  end
  NormalizedListing = Data.define(:payload, :created_at) do
    def mid
      payload['id']
    end
  end
  Candidate = Data.define(:listing, :direction) do
    delegate :created_at, :mid, :payload, to: :listing
  end
  PreparedMessage = Data.define(:candidate, :detail, :attachment_plan, :stage_result) do
    delegate :created_at, :direction, :mid, :payload, to: :candidate
  end
  PROFILE_READ_ERROR = Object.new.freeze
  AvatarWork = Data.define(:contact_id, :urls)
  DryRunProfileContact = Data.define(:id, :name, :additional_attributes, :persisted) do
    def persisted?
      persisted
    end
  end
  ArchiveSnapshot = Data.define(
    :id,
    :platform,
    :thread_id,
    :identifier,
    :configuration,
    :contact_id,
    :contact_inbox_id,
    :source_id
  )
  TaskOptions = Data.define(
    :approval_mode,
    :since,
    :before,
    :dry_run,
    :platforms,
    :outbound_policy,
    :profile_mode,
    :accepted_contentless,
    :ack_expand_existing,
    :max_download_bytes,
    :graph_delay_ms,
    :max_conversation_pages,
    :max_message_pages
  )
  TaskEnvelope = Data.define(
    :approval_mode,
    :since,
    :before,
    :dry_run,
    :platforms,
    :outbound_policy,
    :profile_mode,
    :accepted_contentless,
    :ack_expand_existing,
    :max_download_bytes,
    :graph_delay_ms,
    :max_conversation_pages,
    :max_message_pages,
    :approval
  )

  class ConfigurationError < StandardError; end
  class LockError < StandardError; end

  class ThreadError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  OUTBOUND_POLICIES = %w[no_native_presence pre_presence all].freeze
  SCHEMA_VERSION = 1
  MULTIPART_GUARD = 90.seconds
  MAX_MESSAGE_CONTENT = 150_000
  DETAIL_LOG_LIMIT = 1_000
  DEFAULT_GRAPH_OPTIONS = {
    delay_ms: 250,
    max_conversation_pages: 10_000,
    max_message_pages: 10_000
  }.freeze
  STAT_KEYS = %i[
    conversation_pages threads_scanned message_pages mids_scanned in_scope_mids_scanned out_of_scope_mids
    already_present previously_imported
    candidate_incoming candidate_outbound outbound_no_native_presence_import outbound_no_native_presence_skip
    outbound_pre_presence_import outbound_pre_presence_skip outbound_all_import outbound_all_skip details_fetched
    content_unavailable attachment_urls_found attachments_downloaded attachments_unsupported attachments_unavailable
    imported_contacts imported_archives imported_incoming imported_outgoing imported_messages imported_attachments
    ambiguous_participants ambiguous_senders foreign_source_id_anomalies failed_threads platform_failures
    retry_exhaustion rate_limits authentication_failures lock_loss late_already_present reindex_jobs reindex_failures
    mirror_jobs projected_archives predecessor_archive_not_returned content_truncated detail_logs_suppressed exit_failures
    profile_requests profile_successes profile_unavailable profile_errors profile_changes_projected
    profile_changes_applied avatars_offered avatars_preserved avatars_attached avatars_raced avatars_unavailable
    avatar_failures avatars_skipped_history_incomplete attachment_bytes avatar_bytes total_download_bytes
    download_budget_exhaustions marker_normalizations platforms_history_complete
    messenger_contentless_details instagram_contentless_details contentless_acceptance_mismatches
    history_evidence_changes_projected history_evidence_changes_applied
    messenger_history_evidence_changes_projected messenger_history_evidence_changes_applied
    instagram_history_evidence_changes_projected instagram_history_evidence_changes_applied
  ].freeze

  class << self
    def preflight_task_environment!(env: ENV, now: Time.current, expected_uid: 0)
      mode = env['UMI_FBIG_HISTORY_APPROVAL_MODE']
      raise ConfigurationError, 'UMI_FBIG_HISTORY_APPROVAL_MODE must be unaccepted_probe or approved' unless
        mode.in?(%w[unaccepted_probe approved])
      raise ConfigurationError, 'DRY_RUN is required' if env['DRY_RUN'].nil?
      raise ConfigurationError, 'UMI_FBIG_HISTORY_ACCEPTED_CONTENTLESS is not a supported override' if
        env['UMI_FBIG_HISTORY_ACCEPTED_CONTENTLESS'].present?

      mode == 'unaccepted_probe' ? unaccepted_probe_envelope(env, now) : approved_envelope(env, now, expected_uid)
    rescue Umi::Fbig::HistoryApprovalManifest::InvalidManifest
      raise ConfigurationError, 'history approval manifest is invalid'
    end

    def task_options(inbox, env: ENV, now: Time.current, envelope: nil)
      raise ConfigurationError, 'inbox must use Channel::FacebookPage' unless inbox.channel.is_a?(Channel::FacebookPage)

      envelope ||= preflight_task_environment!(env: env, now: now)
      validate_envelope_scope!(inbox, envelope)
      if !envelope.dry_run && inbox.lock_to_single_conversation &&
         env['ACK_SINGLE_CONVERSATION_REOPEN'] != 'true'
        raise ConfigurationError, 'ACK_SINGLE_CONVERSATION_REOPEN=true is required for this inbox'
      end

      TaskOptions.new(
        **envelope.to_h.except(:approval)
      )
    end

    private

    def unaccepted_probe_envelope(env, now)
      exact_environment!(env, 'DRY_RUN', 'true')
      exact_environment!(env, 'PLATFORMS', 'messenger,instagram')
      exact_environment!(env, 'SINCE', 'all')
      exact_environment!(env, 'OUTBOUND_POLICY', 'pre_presence')
      exact_environment!(env, 'PROFILE_MODE', 'defer')
      reject_present!(env, %w[
                        UMI_FBIG_APPROVAL_MANIFEST_PATH UMI_FBIG_APPROVAL_CHECKSUM_PATH
                        ACK_EXPAND_EXISTING UMI_FBIG_RUNTIME_REPOSITORY_COMMIT UMI_FBIG_RUNTIME_IMAGE_DIGEST
                        UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES
                      ])
      platforms = %w[messenger instagram]
      TaskEnvelope.new(
        approval_mode: 'unaccepted_probe',
        since: nil,
        before: parse_before(env['BEFORE'], dry_run: true, now: now),
        dry_run: true,
        platforms: platforms,
        outbound_policy: 'pre_presence',
        profile_mode: 'defer',
        accepted_contentless: empty_contentless(platforms),
        ack_expand_existing: false,
        max_download_bytes: nil,
        **graph_task_options(env),
        approval: nil
      )
    end

    def approved_envelope(env, now, expected_uid)
      dry_run = parse_boolean(env['DRY_RUN'], default: nil, name: 'DRY_RUN')
      platforms = parse_canonical_platforms!(env['PLATFORMS'])
      reject_present!(env, %w[SINCE BEFORE OUTBOUND_POLICY PROFILE_MODE UMI_FBIG_HISTORY_ACCEPTED_CONTENTLESS])
      approval = Umi::Fbig::HistoryApprovalManifest.load(
        manifest_path: env['UMI_FBIG_APPROVAL_MANIFEST_PATH'],
        checksum_path: env['UMI_FBIG_APPROVAL_CHECKSUM_PATH'],
        expected_uid: expected_uid
      )
      exact_environment!(env, 'UMI_FBIG_RUNTIME_REPOSITORY_COMMIT', approval.repository_commit)
      exact_environment!(env, 'UMI_FBIG_RUNTIME_IMAGE_DIGEST', approval.image_digest)
      raise ConfigurationError, 'approved BEFORE must be at least 15 minutes old' if approval.before > now - 15.minutes

      ack_expand_existing = parse_boolean(env['ACK_EXPAND_EXISTING'], default: false, name: 'ACK_EXPAND_EXISTING')
      if dry_run
        raise ConfigurationError, 'ACK_EXPAND_EXISTING is apply-only' if env['ACK_EXPAND_EXISTING'].present?
      elsif !ack_expand_existing
        raise ConfigurationError, 'ACK_EXPAND_EXISTING=true is required when DRY_RUN=false'
      end
      max_download_bytes = if env['UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES'].present?
                             positive_integer(
                               env['UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES'],
                               nil,
                               'UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES'
                             )
                           end
      raise ConfigurationError, 'UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES is required when DRY_RUN=false' if !dry_run && max_download_bytes.nil?

      TaskEnvelope.new(
        approval_mode: 'approved',
        since: nil,
        before: approval.before,
        dry_run: dry_run,
        platforms: platforms,
        outbound_policy: approval.outbound_policy,
        profile_mode: approval.profile_mode,
        accepted_contentless: approval.accepted_contentless(platforms),
        ack_expand_existing: ack_expand_existing,
        max_download_bytes: max_download_bytes,
        **graph_task_options(env),
        approval: approval
      )
    end

    def validate_envelope_scope!(inbox, envelope)
      raise ConfigurationError, 'the inbox has no Instagram identity' if
        envelope.platforms.include?('instagram') && inbox.channel.instagram_id.blank?
      return unless envelope.approval

      approval = envelope.approval
      valid = approval.account_id == inbox.account_id &&
              approval.inbox_id == inbox.id &&
              approval.facebook_page_id.to_s == inbox.channel.page_id.to_s &&
              approval.instagram_business_id.to_s == inbox.channel.instagram_id.to_s
      raise ConfigurationError, 'history approval scope does not match the inbox' unless valid
    end

    def parse_canonical_platforms!(value)
      platforms = {
        'messenger' => ['messenger'],
        'instagram' => ['instagram'],
        'messenger,instagram' => %w[messenger instagram]
      }[value]
      raise ConfigurationError, 'PLATFORMS must be messenger, instagram, or messenger,instagram' unless platforms

      platforms
    end

    def graph_task_options(env)
      {
        graph_delay_ms: positive_integer(env['UMI_FBIG_HISTORY_GRAPH_DELAY_MS'], 250, 'UMI_FBIG_HISTORY_GRAPH_DELAY_MS'),
        max_conversation_pages: positive_integer(
          env['UMI_FBIG_HISTORY_MAX_CONVERSATION_PAGES'],
          10_000,
          'UMI_FBIG_HISTORY_MAX_CONVERSATION_PAGES'
        ),
        max_message_pages: positive_integer(
          env['UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES'],
          10_000,
          'UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES'
        )
      }
    end

    def empty_contentless(platforms)
      platforms.index_with { |platform| Umi::Fbig::ContentlessFingerprint.build(platform: platform, mids: []) }
    end

    def exact_environment!(env, name, expected)
      raise ConfigurationError, "#{name} must be #{expected}" unless env[name] == expected
    end

    def reject_present!(env, names)
      supplied = names.find { |name| env[name].present? }
      raise ConfigurationError, "#{supplied} is not allowed in this approval mode" if supplied
    end

    def parse_boolean(value, default:, name:)
      return default if value.nil?
      return true if value == 'true'
      return false if value == 'false'

      raise ConfigurationError, "#{name} must be true or false"
    end

    def parse_since(value)
      raise ConfigurationError, 'SINCE is required (all or an ISO-8601 UTC timestamp)' if value.blank?
      return if value == 'all'

      parse_utc_time(value, 'SINCE')
    end

    def parse_before(value, dry_run:, now:)
      if value.blank?
        raise ConfigurationError, 'BEFORE is required when DRY_RUN=false' unless dry_run

        return (now - 15.minutes).utc.change(usec: 0)
      end

      parsed = parse_utc_time(value, 'BEFORE')
      raise ConfigurationError, 'BEFORE must be at least 15 minutes old' if parsed > now - 15.minutes

      parsed
    end

    def parse_utc_time(value, name)
      parsed = Time.iso8601(value.to_s)
      raise ArgumentError unless parsed.utc_offset.zero?

      parsed.utc
    rescue ArgumentError
      raise ConfigurationError, "#{name} must be an ISO-8601 UTC timestamp"
    end

    def parse_platforms(value, channel)
      defaults = ['messenger']
      defaults << 'instagram' if channel.instagram_id.present?
      platforms = value.blank? ? defaults : value.split(',').map(&:strip).compact_blank.uniq
      raise ConfigurationError, 'PLATFORMS must include messenger and/or instagram' if platforms.empty?
      raise ConfigurationError, 'PLATFORMS contains an unsupported platform' if (platforms - %w[messenger instagram]).any?
      raise ConfigurationError, 'the inbox has no Instagram identity' if platforms.include?('instagram') && channel.instagram_id.blank?

      platforms
    end

    def positive_integer(value, default, name)
      parsed = value.nil? ? default : Integer(value, 10)
      raise ArgumentError unless parsed&.positive?

      parsed
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{name} must be a positive integer"
    end
  end

  def initialize(inbox, since:, before:, dry_run:, platforms:, outbound_policy:, graph_client: nil,
                 attachment_service: nil, logger: Rails.logger, run_id: SecureRandom.uuid, clock: -> { Time.current },
                 graph_options: nil, ack_expand_existing: false, max_download_bytes: nil, profile_service: nil,
                 accepted_contentless: nil, profile_mode: 'inline')
    @inbox = inbox
    @channel = inbox.channel
    @account = inbox.account
    @since = since
    @before = before
    @dry_run = dry_run
    @platforms = platforms
    @outbound_policy = outbound_policy
    @accepted_contentless_explicit = !accepted_contentless.nil?
    @accepted_contentless = accepted_contentless || platforms.index_with do |platform|
      Umi::Fbig::ContentlessFingerprint.build(platform: platform, mids: [])
    end
    @profile_mode = profile_mode
    @ack_expand_existing = ack_expand_existing
    @graph_client = graph_client
    @graph_options = graph_options
    @attachment_service = attachment_service || Umi::Fbig::HistoryImportAttachmentService.new
    @profile_service = profile_service || Umi::Fbig::HistoryImportProfileService.new
    @remaining_download_bytes = max_download_bytes
    @logger = logger
    @run_id = run_id
    @clock = clock
    @stats = Hash.new(0).merge(STAT_KEYS.index_with(0))
    @scan_complete = true
    @write_complete = dry_run ? nil : true
    @degraded = false
    @abort_scan = false
    @detail_logs_emitted = 0
    @platform_preflights = {}
    @seen_archive_participants = Hash.new { |hash, platform| hash[platform] = {} }
    @profile_cache = {}
    @avatar_work = {}
    @dry_run_avatar_urls = Hash.new { |hash, key| hash[key] = Set.new }
    @dry_run_profile_contacts = {}
    @history_failures = Hash.new(0)
    @platform_history_complete = {}
    @contentless_mids = Hash.new { |hash, platform| hash[platform] = [] }
    @contentless_mid_sets = Hash.new { |hash, platform| hash[platform] = Set.new }
  end

  def perform
    validate_arguments!
    validate_profile_configuration!
    acquired = Umi::Fbig::HistoryImportLock.acquire(@channel.id, @run_id)
    raise LockError unless acquired

    @last_renewed_at = @clock.call
    prepare_existing_archives!
    @platforms.each do |platform|
      process_platform(platform)
      break if @abort_scan
    end
    unless @dry_run || @profile_mode == 'defer'
      if all_platform_history_complete?
        process_avatars
      else
        @stats[:avatars_skipped_history_incomplete] += @avatar_work.values.sum { |work| work.urls.size }
      end
    end
    renew_if_due!
    Result.new(
      stats: @stats.to_h,
      scan_complete: @scan_complete,
      write_complete: @write_complete,
      degraded: @degraded,
      dry_run: @dry_run
    )
  ensure
    Umi::Fbig::HistoryImportLock.release(@channel.id, @run_id) if acquired
  end

  private

  def process_platform(platform)
    @current_platform = platform
    history_failures_before = @history_failures[platform]
    pages = graph_client.each_thread(platform, on_page: -> { renew_if_due! }) do |thread|
      process_thread(platform, thread)
    end
    @stats[:conversation_pages] += pages
    compare_contentless_acceptance!(platform)
    record_archives_not_returned(platform)
    return if @dry_run || @history_failures[platform] != history_failures_before

    @stats[:marker_normalizations] += normalize_platform_configuration!(platform)
    @platform_history_complete[platform] = true
    @stats[:platforms_history_complete] += 1
  rescue LockError
    @stats[:lock_loss] += 1
    raise
  rescue Umi::Fbig::HistoryImportGraphClient::AuthenticationError => e
    @scan_complete = false
    fail_write!
    @abort_scan = true
    @stats[:authentication_failures] += 1
    @stats[:platform_failures] += 1
    log(:platform_failed, platform: platform, error: e.class.name)
  rescue StandardError => e
    @scan_complete = false
    fail_write!
    @stats[:platform_failures] += 1
    log(:platform_failed, platform: platform, error: e.class.name)
  ensure
    @current_platform = nil
  end

  def process_thread(platform, thread)
    @stats[:threads_scanned] += 1
    thread_id = required_text!(thread['id'], ApplicationRecord::MAX_TEXT_COLUMN_LENGTH, :invalid_thread_id)
    participant = external_participant!(platform, thread)
    result = graph_client.messages(thread_id, on_page: -> { renew_if_due! })
    @stats[:message_pages] += result.pages
    @stats[:mids_scanned] += result.items.size

    listings = in_scope_listings(result.items)
    @stats[:in_scope_mids_scanned] += listings.size
    @stats[:out_of_scope_mids] += result.items.size - listings.size
    archive_exists = validate_existing_archive_for_scan!(platform, thread_id, participant['id'])
    existing_contact_inbox = @inbox.contact_inboxes.find_by(source_id: participant['id'])
    existing_profile_plan = profile_plan_for(platform, participant, listings, existing_contact_inbox.contact) if existing_contact_inbox
    begin
      candidates = classify_candidates(platform, participant['id'], listings)
    rescue StandardError
      apply_existing_profile(existing_contact_inbox, existing_profile_plan) if existing_contact_inbox
      raise
    end
    if candidates.empty?
      apply_existing_profile(existing_contact_inbox, existing_profile_plan) if existing_contact_inbox
      log_detail(:thread_complete, platform: platform, thread_id: thread_id, candidates: 0, dry_run: @dry_run)
      return
    end

    begin
      prepared = prepare_details(platform, thread_id, participant['id'], candidates)
    rescue StandardError
      apply_existing_profile(existing_contact_inbox, existing_profile_plan) if existing_contact_inbox
      raise
    end
    if existing_contact_inbox
      if prepared.present? && existing_profile_plan
        existing_profile_plan = profile_plan_for(
          platform,
          participant,
          listings,
          existing_contact_inbox.contact,
          prepared: prepared,
          count_preserved_avatar: false
        )
      end
      apply_existing_profile(existing_contact_inbox, existing_profile_plan)
      profile_plan = nil
    elsif prepared.present?
      begin
        profile_plan = profile_plan_for(platform, participant, listings, nil, prepared: prepared)
      rescue StandardError
        @attachment_service.cleanup_all_unattached!(prepared.map(&:stage_result)) unless @dry_run
        raise
      end
    end
    if prepared.empty? || @dry_run
      @stats[:projected_archives] += 1 if @dry_run && prepared.present? && !archive_exists
      record_projected_profile_change(profile_plan) if @dry_run && profile_plan
      log_detail(:thread_complete, platform: platform, thread_id: thread_id, candidates: prepared.size, dry_run: @dry_run)
      return
    end

    import_thread(platform, thread_id, participant, prepared, profile_plan)
    log_detail(:thread_complete, platform: platform, thread_id: thread_id, candidates: prepared.size, dry_run: false)
  rescue LockError, Umi::Fbig::HistoryImportGraphClient::AuthenticationError
    raise
  rescue Umi::Fbig::HistoryImportGraphClient::RequestError => e
    @scan_complete = false
    @stats[:retry_exhaustion] += 1
    @stats[:rate_limits] += 1 if e.reason == :rate_limit
    fail_thread(platform, thread&.[]('id'), :graph_request_failed, error: e.class.name)
  rescue ThreadError => e
    if e.reason == :ambiguous_participants && !history_archive_exists?(platform, thread_id)
      record_permanent_ambiguity(platform)
    else
      fail_thread(platform, thread&.[]('id'), e.reason)
    end
  rescue StandardError => e
    @scan_complete = false if e.is_a?(Umi::Fbig::HistoryImportGraphClient::PaginationError) ||
                              e.is_a?(Koala::Facebook::APIError)
    fail_thread(platform, thread&.[]('id'), :exception, error: e.class.name)
  end

  def external_participant!(platform, thread)
    business_id = business_id_for(platform)
    participants = Array(thread.dig('participants', 'data'))
    external = participants.reject { |participant| participant['id'].to_s == business_id }
    valid = external.select { |participant| participant['id'].present? }
    raise ThreadError, :ambiguous_participants unless external.size == 1 && valid.size == 1

    required_text!(valid.first['id'], ApplicationRecord::MAX_TEXT_COLUMN_LENGTH, :invalid_participant_id)
    valid.first
  end

  def in_scope_listings(items)
    seen = Set.new
    Array(items).filter_map do |listing|
      mid = required_text!(listing['id'], ApplicationRecord::MAX_TEXT_COLUMN_LENGTH, :invalid_mid)
      raise ThreadError, :duplicate_mid unless seen.add?(mid)

      created_at = parse_time!(listing['created_time'], :invalid_listing_time)
      next if @since && created_at < @since
      next unless created_at < @before

      NormalizedListing.new(payload: listing, created_at: created_at)
    end
  end

  def classify_candidates(platform, participant_id, listings)
    return [] if listings.empty?

    mids = listings.map(&:mid)
    existing = Message.where(account_id: @account.id, inbox_id: @inbox.id, source_id: mids)
                      .pluck(:source_id, :additional_attributes).to_h
    @stats[:already_present] += existing.size
    @stats[:previously_imported] += existing.count { |_mid, attributes| attributes['umi_history_import'] == true }
    absent = listings.reject { |listing| existing.key?(listing.mid) }
    return [] if absent.empty?

    foreign_count = Message.where(source_id: absent.map(&:mid)).where.not(account_id: @account.id).distinct.count(:source_id)
    if foreign_count.positive?
      @stats[:foreign_source_id_anomalies] += foreign_count
      @degraded = true
      @stats[:exit_failures] += foreign_count
      @write_complete = false unless @dry_run
      @history_failures[@current_platform] += foreign_count
    end

    native_presence_at = earliest_native_presence(platform, participant_id)
    absent.filter_map do |listing|
      direction = direction_for!(platform, participant_id, listing.payload.dig('from', 'id'))
      if direction == :incoming
        @stats[:candidate_incoming] += 1
      else
        @stats[:candidate_outbound] += 1
        record_policy_counts(listing.created_at, native_presence_at)
        next unless selected_outbound?(listing.created_at, native_presence_at)
      end
      Candidate.new(listing: listing, direction: direction)
    end
  end

  def direction_for!(platform, participant_id, sender_id)
    return :incoming if sender_id.to_s == participant_id
    return :outgoing if sender_id.to_s == business_id_for(platform)

    raise ThreadError, :ambiguous_sender
  end

  def record_policy_counts(created_at, native_presence_at)
    OUTBOUND_POLICIES.each do |policy|
      outcome = outbound_allowed?(policy, created_at, native_presence_at) ? :import : :skip
      @stats[:"outbound_#{policy}_#{outcome}"] += 1
    end
  end

  def selected_outbound?(created_at, native_presence_at)
    return true if @dry_run && @outbound_policy.nil?

    outbound_allowed?(@outbound_policy, created_at, native_presence_at)
  end

  def outbound_allowed?(policy, created_at, native_presence_at)
    case policy
    when 'no_native_presence'
      native_presence_at.nil?
    when 'pre_presence'
      native_presence_at.nil? || created_at < native_presence_at - MULTIPART_GUARD
    when 'all'
      true
    else
      false
    end
  end

  def earliest_native_presence(platform, participant_id)
    contact_inbox = @inbox.contact_inboxes.find_by(source_id: participant_id)
    return unless contact_inbox

    scope = Message.unscoped.joins(:conversation)
                   .where(account_id: @account.id, inbox_id: @inbox.id)
                   .where(conversations: { contact_inbox_id: contact_inbox.id })
                   .where("COALESCE(messages.additional_attributes ->> 'umi_history_import', 'false') <> 'true'")
    scope = if platform == 'instagram'
              scope.where("conversations.additional_attributes ->> 'type' = 'instagram_direct_message'")
            else
              scope.where("COALESCE(conversations.additional_attributes ->> 'type', '') <> 'instagram_direct_message'")
            end
    scope.minimum(:created_at)
  end

  def prepare_details(platform, thread_id, participant_id, candidates)
    prepared = candidates.filter_map do |candidate|
      renew_if_due!
      detail = graph_client.detail(candidate.mid)
      renew_if_due!
      unless detail
        @stats[:content_unavailable] += 1
        fail_write!
        next
      end

      validate_detail!(platform, participant_id, candidate, detail)
      @stats[:details_fetched] += 1
      attachment_plan = @attachment_service.plan(detail)
      if detail['message'].blank? && attachment_plan.descriptors.empty? && attachment_plan.omissions.empty?
        @stats[:content_unavailable] += 1
        mid = candidate.mid
        raise ThreadError, :duplicate_contentless_mid unless @contentless_mid_sets[platform].add?(mid)

        @contentless_mids[platform] << mid
        next
      end
      @stats[:attachment_urls_found] += attachment_plan.descriptors.size
      @stats[:attachments_unsupported] += attachment_plan.omissions.values.sum
      PreparedMessage.new(
        candidate: candidate,
        detail: detail,
        attachment_plan: attachment_plan,
        stage_result: nil
      )
    end
    return prepared if @dry_run

    stage_prepared(platform, thread_id, prepared)
  end

  def validate_detail!(platform, participant_id, candidate, detail)
    raise ThreadError, :detail_mid_mismatch unless detail['id'].to_s == candidate.mid

    created_at = parse_time!(detail['created_time'], :invalid_detail_time)
    raise ThreadError, :detail_time_mismatch unless created_at.to_i == candidate.created_at.to_i
    raise ThreadError, :detail_out_of_scope if (@since && created_at < @since) || created_at >= @before

    expected_sender = candidate.direction == :incoming ? participant_id : business_id_for(platform)
    expected_recipient = candidate.direction == :incoming ? business_id_for(platform) : participant_id
    raise ThreadError, :detail_sender_mismatch unless detail.dig('from', 'id').to_s == expected_sender

    recipient_ids = Array(detail.dig('to', 'data')).pluck('id').map(&:to_s)
    raise ThreadError, :detail_recipient_mismatch unless recipient_ids == [expected_recipient]
  end

  def import_thread(platform, thread_id, participant, prepared, profile_plan)
    stage_results = prepared.map(&:stage_result)
    committed = false
    imported_ids, contact = persist_thread(platform, thread_id, participant, prepared, profile_plan)
    committed = true
    queue_avatar(contact, profile_plan)
    reindex_messages(imported_ids)
  ensure
    fail_write! if stage_results.present? && !committed
    @attachment_service.cleanup_all_unattached!(stage_results) if stage_results
  end

  def persist_thread(platform, thread_id, participant, prepared, profile_plan)
    attempts = 0
    begin
      persist_thread_transaction(platform, thread_id, participant, prepared, profile_plan)
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts == 1 && @inbox.contact_inboxes.exists?(source_id: participant['id'])

      raise
    end
  end

  def persist_thread_transaction(platform, thread_id, participant, prepared, profile_plan)
    renew_lock!
    imported_ids = []
    archive = nil
    contact = nil
    archive_created = false
    committed_stats = Hash.new(0)
    ActiveRecord::Base.transaction do
      present_mids = Message.where(
        account_id: @account.id,
        inbox_id: @inbox.id,
        source_id: prepared.map(&:mid)
      ).pluck(:source_id).to_set
      @stats[:late_already_present] += present_mids.size
      remaining = prepared.reject { |item| present_mids.include?(item.mid) }
      next if remaining.empty?

      contact_inbox, contact_created, profile_changed = contact_inbox_for(platform, participant, remaining, profile_plan)
      contact = contact_inbox.contact
      archive, archive_created = archive_for(platform, thread_id, contact_inbox, remaining)
      remaining.sort_by(&:created_at).each do |item|
        renew_if_due!
        message_id = insert_message(archive, contact_inbox.contact, platform, thread_id, item)
        imported_ids << message_id
        attachment_count = @attachment_service.persist!(
          item.stage_result,
          message_id: message_id,
          account_id: @account.id,
          created_at: item.created_at
        )
        renew_if_due!
        committed_stats[:imported_attachments] += attachment_count
        committed_stats[item.direction == :incoming ? :imported_incoming : :imported_outgoing] += 1
        committed_stats[:imported_messages] += 1
      end
      renew_if_due!
      update_historical_activity(contact_inbox.contact, archive, remaining)
      renew_if_due!
      committed_stats[:imported_contacts] += 1 if contact_created
      committed_stats[:imported_archives] += 1 if archive_created
      record_scalar_change!(committed_stats, :applied) if profile_changed
    end
    register_created_archive!(platform, thread_id, participant['id'], archive) if archive_created
    committed_stats.each { |key, value| @stats[key] += value }
    [imported_ids, contact]
  end

  def contact_inbox_for(platform, participant, prepared, profile_plan)
    existing = @inbox.contact_inboxes.find_by(source_id: participant['id'])
    if existing
      profile_changed = profile_plan && @profile_service.apply!(contact: existing.contact, plan: profile_plan).changed
      return [existing, false, profile_changed]
    end

    earliest = prepared.map(&:created_at).min
    latest = prepared.map(&:created_at).max
    incoming_latest = prepared.select { |item| item.direction == :incoming }.map(&:created_at).max
    planned_attributes = profile_plan&.contact_attributes || {}
    planned_name = planned_attributes[:name].presence.to_s.truncate(ApplicationRecord::MAX_STRING_COLUMN_LENGTH, omission: '').presence
    additional_attributes = planned_attributes[:additional_attributes]
    additional_attributes = {} unless additional_attributes.is_a?(Hash)
    contact_id = Contact.insert_all!(
      [{
        account_id: @account.id,
        name: planned_name ||
              participant['name'].presence.to_s.truncate(ApplicationRecord::MAX_STRING_COLUMN_LENGTH, omission: '').presence ||
              fallback_contact_name(platform, participant['id']),
        email: nil,
        phone_number: nil,
        identifier: nil,
        last_activity_at: incoming_latest,
        additional_attributes: additional_attributes,
        custom_attributes: {},
        contact_type: Contact.contact_types.fetch('visitor'),
        middle_name: '',
        last_name: '',
        location: '',
        country_code: '',
        blocked: false,
        created_at: earliest,
        updated_at: latest
      }],
      returning: %w[id]
    ).rows.dig(0, 0)
    contact = Contact.find(contact_id)
    contact_inbox = ContactInbox.create!(
      contact: contact,
      inbox: @inbox,
      source_id: participant['id'],
      created_at: earliest,
      updated_at: latest
    )
    profile_changed = profile_plan && (planned_name.present? || additional_attributes.present?)
    [contact_inbox, true, profile_changed]
  end

  def archive_for(platform, thread_id, contact_inbox, prepared)
    identifier = archive_identifier(platform, thread_id)
    existing = @account.conversations.where(inbox_id: @inbox.id, identifier: identifier).limit(2).to_a
    raise ThreadError, :archive_identifier_collision if existing.many?

    if existing.one?
      snapshot = @platform_preflights.dig(platform, :by_thread_id, thread_id)
      raise ThreadError, :archive_created_after_preflight unless @dry_run || snapshot

      validate_archive!(
        existing.first,
        platform,
        thread_id,
        contact_inbox,
        expected_configuration: snapshot&.configuration || configuration
      )
      return [existing.first, false]
    end

    earliest = prepared.map(&:created_at).min
    latest = prepared.map(&:created_at).max
    conversation_id = Conversation.insert_all!(
      [{
        account_id: @account.id,
        inbox_id: @inbox.id,
        status: Conversation.statuses.fetch('resolved'),
        contact_id: contact_inbox.contact_id,
        contact_inbox_id: contact_inbox.id,
        identifier: identifier,
        additional_attributes: archive_attributes(platform, thread_id),
        custom_attributes: {},
        agent_last_seen_at: latest,
        created_at: earliest,
        updated_at: latest,
        last_activity_at: latest
      }],
      returning: %w[id]
    ).rows.dig(0, 0)
    [Conversation.find(conversation_id), true]
  end

  def validate_archive!(archive, platform, thread_id, contact_inbox, expected_configuration: configuration)
    failures = canonical_archive_failures(
      archive,
      platform,
      thread_id,
      contact_inbox,
      expected_configuration: expected_configuration
    )
    raise ThreadError, :archive_became_live if failures.any?
  end

  def canonical_archive_failures(archive, platform, thread_id, contact_inbox, expected_configuration:)
    marker = archive.additional_attributes['umi_history_import']
    expected_type = platform == 'instagram' ? 'instagram_direct_message' : nil
    imported_only = !archive.messages
                            .where("COALESCE(additional_attributes ->> 'umi_history_import', 'false') <> 'true'")
                            .exists?
    expected_marker = archive_marker(platform, thread_id).slice('schema_version', 'platform', 'thread_id')
    checks = {
      resolved: archive.resolved?,
      inbox: archive.inbox_id == @inbox.id,
      contact: archive.contact_id == contact_inbox.contact_id,
      contact_inbox: archive.contact_inbox_id == contact_inbox.id,
      assignee: archive.assignee_id.nil?,
      agent_bot: archive.assignee_agent_bot_id.nil?,
      team: archive.team_id.nil?,
      campaign: archive.campaign_id.nil?,
      sla_policy: archive.sla_policy_id.nil?,
      priority: archive.priority.nil?,
      snoozed: archive.snoozed_until.nil?,
      waiting: archive.waiting_since.nil?,
      first_reply: archive.first_reply_created_at.nil?,
      seen_at: archive.agent_last_seen_at&.to_i == archive.last_activity_at.to_i,
      conversation_type: archive.additional_attributes['type'] == expected_type,
      marker: marker.is_a?(Hash) && marker.slice('schema_version', 'platform', 'thread_id') == expected_marker,
      configuration: @dry_run || (marker.is_a?(Hash) && marker['configuration'] == expected_configuration),
      imported_only: imported_only
    }
    checks.reject { |_name, valid| valid }.keys
  end

  def insert_message(archive, contact, platform, thread_id, prepared)
    omissions = prepared.stage_result.omissions
    content = historical_content(prepared.detail['message'], omissions)
    content_attributes = {}
    reply_mid = prepared.detail.dig('reply_to', 'mid')
    if reply_mid.present?
      content_attributes[:in_reply_to_external_id] =
        required_text!(reply_mid, ApplicationRecord::MAX_TEXT_COLUMN_LENGTH, :invalid_reply_mid)
    end
    content_attributes[:external_echo] = true if prepared.direction == :outgoing
    additional_attributes = {
      umi_history_import: true,
      umi_history_schema_version: SCHEMA_VERSION,
      umi_history_platform: platform,
      umi_history_thread_id: thread_id
    }
    additional_attributes[:attachment_omissions] = omissions if omissions.present?

    Message.insert_all!(
      [{
        account_id: @account.id,
        inbox_id: @inbox.id,
        conversation_id: archive.id,
        message_type: Message.message_types.fetch(prepared.direction.to_s),
        content_type: Message.content_types.fetch('text'),
        content: content,
        processed_message_content: content,
        private: false,
        status: Message.statuses.fetch(prepared.direction == :incoming ? 'sent' : 'delivered'),
        sender_type: prepared.direction == :incoming ? 'Contact' : nil,
        sender_id: prepared.direction == :incoming ? contact.id : nil,
        source_id: prepared.mid,
        external_source_ids: {},
        content_attributes: content_attributes,
        additional_attributes: additional_attributes,
        sentiment: {},
        created_at: prepared.created_at,
        updated_at: prepared.created_at
      }],
      returning: %w[id]
    ).rows.dig(0, 0)
  end

  def update_historical_activity(contact, archive, prepared)
    earliest = ([archive.created_at] + prepared.map(&:created_at)).compact.min
    latest = ([archive.last_activity_at] + prepared.map(&:created_at)).compact.max
    Conversation.where(id: archive.id).update_all(
      created_at: earliest,
      updated_at: latest,
      last_activity_at: latest,
      agent_last_seen_at: latest
    )
    incoming_latest = prepared.select { |item| item.direction == :incoming }.map(&:created_at).max
    return unless incoming_latest && (contact.last_activity_at.nil? || contact.last_activity_at < incoming_latest)

    Contact.where(id: contact.id).update_all(last_activity_at: incoming_latest)
  end

  def historical_content(message, omissions)
    count = omissions.values.sum
    marker = count.positive? ? "[Historical attachment unavailable: #{count}]" : nil
    separator_length = marker ? 2 : 0
    maximum_text_length = MAX_MESSAGE_CONTENT - marker.to_s.length - separator_length
    raw_text = message.to_s
    @stats[:content_truncated] += 1 if raw_text.length > maximum_text_length
    text = raw_text.truncate(maximum_text_length, omission: '').presence
    return text unless marker

    [text, marker].compact.join("\n\n")
  end

  def reindex_messages(message_ids)
    Message.where(id: message_ids).find_each do |message|
      next unless message.should_index?

      message.__send__(:reindex_for_search)
      @stats[:reindex_jobs] += 1
    rescue StandardError => e
      @stats[:reindex_failures] += 1
      log_detail(:reindex_failed, message_id: message.id, error: e.class.name)
    end
  end

  def prepare_existing_archives!
    archives = selected_archive_scope(@platforms).order(:id).to_a
    duplicate_identifier = archives.group_by(&:identifier).find { |_identifier, matches| matches.many? }
    raise ConfigurationError, "duplicate archive identifier #{duplicate_identifier.first.inspect}" if duplicate_identifier

    snapshots = archives.map { |archive| snapshot_existing_archive!(archive) }
    predecessor_configurations = snapshots.map(&:configuration).uniq.reject { |stored| stored == configuration }
    raise ConfigurationError, 'selected platforms must have at most one predecessor configuration' if predecessor_configurations.many?

    predecessor = predecessor_configurations.first
    validate_predecessor_configuration!(predecessor) if predecessor
    @platforms.each do |platform|
      platform_snapshots = snapshots.select { |snapshot| snapshot.platform == platform }
      @platform_preflights[platform] = {
        by_thread_id: platform_snapshots.index_by(&:thread_id),
        by_id: platform_snapshots.index_by(&:id)
      }
    end
  end

  def selected_archive_scope(platforms)
    base = @account.conversations.where(inbox_id: @inbox.id)
    prefix_ids = platforms.flat_map do |platform|
      prefix = ActiveRecord::Base.sanitize_sql_like("umi-fbig-history:#{@inbox.id}:#{platform}:")
      base.where('identifier LIKE ?', "#{prefix}%").pluck(:id)
    end
    marker_ids = base.where(
      "additional_attributes -> 'umi_history_import' ->> 'platform' IN (?)",
      platforms
    ).pluck(:id)
    base.where(id: (prefix_ids | marker_ids))
  end

  def snapshot_existing_archive!(archive)
    marker = archive.additional_attributes['umi_history_import']
    unless marker.is_a?(Hash) &&
           marker.keys.to_set == %w[schema_version platform thread_id configuration].to_set
      raise ConfigurationError, "malformed history marker on archive #{archive.id}"
    end

    platform = marker['platform']
    raise ConfigurationError, "wrong history platform on archive #{archive.id}" unless @platforms.include?(platform)
    raise ConfigurationError, "unsupported history schema on archive #{archive.id}" unless marker['schema_version'] == SCHEMA_VERSION

    thread_id = configuration_text!(marker['thread_id'], ApplicationRecord::MAX_TEXT_COLUMN_LENGTH, 'thread_id')
    expected_identifier = raw_archive_identifier(platform, thread_id)
    raise ConfigurationError, "history archive identifier mismatch on archive #{archive.id}" unless archive.identifier == expected_identifier

    stored_configuration = parse_stored_configuration!(marker['configuration'], archive.id)
    contact_inbox = ContactInbox.find_by(id: archive.contact_inbox_id)
    unless contact_inbox&.inbox_id == @inbox.id &&
           contact_inbox.contact_id == archive.contact_id &&
           contact_inbox.source_id.present?
      raise ConfigurationError, "history archive identity mismatch on archive #{archive.id}"
    end

    canonical_failures = canonical_archive_failures(
      archive,
      platform,
      thread_id,
      contact_inbox,
      expected_configuration: stored_configuration
    )
    if canonical_failures.any?
      raise ConfigurationError, "history archive is no longer import-only on archive #{archive.id}: #{canonical_failures.join(',')}"
    end

    ArchiveSnapshot.new(
      id: archive.id,
      platform: platform,
      thread_id: thread_id,
      identifier: expected_identifier,
      configuration: stored_configuration.deep_dup,
      contact_id: archive.contact_id,
      contact_inbox_id: contact_inbox.id,
      source_id: contact_inbox.source_id.to_s
    )
  end

  def parse_stored_configuration!(stored, archive_id)
    unless stored.is_a?(Hash) && stored.keys.to_set == %w[since before outbound_policy].to_set
      raise ConfigurationError, "malformed configuration marker on archive #{archive_id}"
    end

    since_value = stored['since']
    parse_configuration_time!(since_value, 'since', archive_id) unless since_value == 'all'
    parse_configuration_time!(stored['before'], 'before', archive_id)
    raise ConfigurationError, "malformed outbound policy marker on archive #{archive_id}" unless OUTBOUND_POLICIES.include?(stored['outbound_policy'])

    stored.deep_dup
  end

  def parse_configuration_time!(value, name, archive_id)
    parsed = Time.iso8601(value.to_s)
    raise ArgumentError unless parsed.utc_offset.zero? && parsed.utc.iso8601 == value

    parsed.utc
  rescue ArgumentError
    raise ConfigurationError, "malformed #{name} marker on archive #{archive_id}"
  end

  def validate_predecessor_configuration!(predecessor)
    raise ConfigurationError, 'expansion cannot change the outbound policy' unless predecessor['outbound_policy'] == configuration['outbound_policy']
    raise ConfigurationError, 'the requested interval must contain the predecessor interval' unless interval_contains?(configuration, predecessor)
    return if @dry_run || @ack_expand_existing

    raise ConfigurationError, 'ACK_EXPAND_EXISTING=true is required to expand existing archives'
  end

  def interval_contains?(target, predecessor)
    target_since = configuration_since(target)
    predecessor_since = configuration_since(predecessor)
    contains_since = target_since.nil? || (predecessor_since && target_since <= predecessor_since)
    contains_before = Time.iso8601(target['before']) >= Time.iso8601(predecessor['before'])
    contains_since && contains_before
  end

  def configuration_since(value)
    return if value['since'] == 'all'

    Time.iso8601(value['since'])
  end

  def validate_existing_archive_for_scan!(platform, thread_id, participant_id)
    identifier = archive_identifier(platform, thread_id)
    archives = @account.conversations.where(inbox_id: @inbox.id, identifier: identifier).limit(2).to_a
    snapshot = @platform_preflights.dig(platform, :by_thread_id, thread_id)
    if snapshot.nil?
      raise ThreadError, :archive_created_after_preflight if archives.any?

      return false
    end

    raise ThreadError, :archive_identity_mismatch unless archives.one? && archives.first.id == snapshot.id

    archive = archives.first
    contact_inbox = ContactInbox.find_by(id: snapshot.contact_inbox_id)
    validate_snapshot_identity!(snapshot, archive, contact_inbox)
    raise ThreadError, :archive_identity_mismatch unless participant_id.to_s == snapshot.source_id

    @seen_archive_participants[platform][thread_id] = participant_id.to_s
    true
  end

  def validate_snapshot_identity!(snapshot, archive, contact_inbox)
    identity_matches = archive.id == snapshot.id &&
                       archive.identifier == snapshot.identifier &&
                       archive.contact_id == snapshot.contact_id &&
                       archive.contact_inbox_id == snapshot.contact_inbox_id &&
                       contact_inbox&.id == snapshot.contact_inbox_id &&
                       contact_inbox&.inbox_id == @inbox.id &&
                       contact_inbox&.contact_id == snapshot.contact_id &&
                       contact_inbox&.source_id.to_s == snapshot.source_id
    raise ThreadError, :archive_identity_mismatch unless identity_matches

    validate_archive!(
      archive,
      snapshot.platform,
      snapshot.thread_id,
      contact_inbox,
      expected_configuration: snapshot.configuration
    )
  end

  def record_archives_not_returned(platform)
    snapshots = @platform_preflights.fetch(platform).fetch(:by_thread_id)
    returned = @seen_archive_participants[platform]
    @stats[:predecessor_archive_not_returned] += snapshots.keys.count { |thread_id| !returned.key?(thread_id) }
  end

  def normalize_platform_configuration!(platform)
    preflight = @platform_preflights.fetch(platform)
    snapshots = preflight.fetch(:by_id).values.sort_by(&:id)
    affected = 0
    ActiveRecord::Base.transaction do
      archives = Conversation.where(id: snapshots.map(&:id)).order(:id).lock.to_a
      contact_inboxes = ContactInbox.where(id: snapshots.map(&:contact_inbox_id).uniq).order(:id).lock.index_by(&:id)
      current_scope_ids = selected_archive_scope([platform]).order(:id).pluck(:id)
      raise ThreadError, :archive_scope_changed unless current_scope_ids == snapshots.map(&:id)

      archives.index_by(&:id).tap do |archives_by_id|
        snapshots.each do |snapshot|
          archive = archives_by_id[snapshot.id]
          contact_inbox = contact_inboxes[snapshot.contact_inbox_id]
          raise ThreadError, :archive_identity_mismatch unless archive

          validate_snapshot_identity!(snapshot, archive, contact_inbox)
          participant_id = @seen_archive_participants[platform][snapshot.thread_id]
          raise ThreadError, :archive_identity_mismatch if participant_id && participant_id != contact_inbox.source_id.to_s

          next if snapshot.configuration == configuration

          attributes = archive.additional_attributes.deep_dup
          attributes['umi_history_import'] = attributes['umi_history_import'].deep_dup
          attributes['umi_history_import']['configuration'] = configuration.deep_dup
          affected += Conversation.where(id: archive.id).update_all(additional_attributes: attributes)
        end
      end
      expected = snapshots.count { |snapshot| snapshot.configuration != configuration }
      raise ThreadError, :archive_normalization_incomplete unless affected == expected

      final_scope_ids = selected_archive_scope([platform]).order(:id).pluck(:id)
      raise ThreadError, :archive_scope_changed unless final_scope_ids == snapshots.map(&:id)
    end
    affected
  end

  def register_created_archive!(platform, thread_id, participant_id, archive)
    snapshot = snapshot_existing_archive!(archive.reload)
    raise ThreadError, :archive_identity_mismatch unless snapshot.source_id == participant_id.to_s

    preflight = @platform_preflights.fetch(platform)
    preflight[:by_thread_id][thread_id] = snapshot
    preflight[:by_id][archive.id] = snapshot
    @seen_archive_participants[platform][thread_id] = participant_id.to_s
  end

  def configuration_text!(value, maximum, name)
    text = value.to_s
    raise ConfigurationError, "malformed #{name} marker" if text.blank? || text.length > maximum

    text
  end

  def raw_archive_identifier(platform, thread_id)
    identifier = "umi-fbig-history:#{@inbox.id}:#{platform}:#{thread_id}"
    raise ConfigurationError, 'history archive identifier is too long' if identifier.length > ApplicationRecord::MAX_STRING_COLUMN_LENGTH

    identifier
  end

  def archive_identifier(platform, thread_id)
    identifier = "umi-fbig-history:#{@inbox.id}:#{platform}:#{thread_id}"
    required_text!(identifier, ApplicationRecord::MAX_STRING_COLUMN_LENGTH, :archive_identifier_too_long)
  end

  def archive_attributes(platform, thread_id)
    attributes = { 'umi_history_import' => archive_marker(platform, thread_id) }
    attributes['type'] = 'instagram_direct_message' if platform == 'instagram'
    attributes
  end

  def archive_marker(platform, thread_id)
    {
      'schema_version' => SCHEMA_VERSION,
      'platform' => platform,
      'thread_id' => thread_id,
      'configuration' => configuration
    }
  end

  def configuration
    @configuration ||= {
      'since' => @since ? @since.utc.iso8601 : 'all',
      'before' => @before.utc.iso8601,
      'outbound_policy' => @outbound_policy
    }
  end

  def business_id_for(platform)
    platform == 'instagram' ? @channel.instagram_id.to_s : @channel.page_id.to_s
  end

  def fallback_contact_name(platform, participant_id)
    return "Instagram user #{participant_id.to_s.last(4)}" if platform == 'instagram'

    'Facebook user'
  end

  def graph_client
    options = @graph_options || DEFAULT_GRAPH_OPTIONS
    @graph_client ||= Umi::Fbig::HistoryImportGraphClient.new(
      @channel,
      **options
    )
  end

  def profile_for(platform, participant_id)
    key = [platform, participant_id.to_s]
    return @profile_cache[key] if @profile_cache.key?(key)

    @stats[:profile_requests] += 1
    result = graph_client.profile(*key)
    _attributes, unavailable = profile_attributes(result)
    if unavailable
      @stats[:profile_unavailable] += 1
      @degraded = true
    else
      @stats[:profile_successes] += 1
    end
    @profile_cache[key] = result
  rescue Umi::Fbig::HistoryImportGraphClient::AuthenticationError
    raise
  rescue Umi::Fbig::HistoryImportGraphClient::ProfileError,
         Umi::Fbig::HistoryImportGraphClient::RequestError
    @stats[:profile_errors] += 1
    fail_enrichment!
    @profile_cache[key] = PROFILE_READ_ERROR
  end

  def profile_plan_for(platform, participant, listings, contact, prepared: [], count_preserved_avatar: true)
    if @profile_mode == 'defer'
      return @profile_service.plan(
        platform: platform,
        source_id: participant['id'],
        profile: {},
        participant_name: participant['name'],
        observed_sender_username: observed_sender_username(listings, prepared, participant['id']),
        contact: dry_run_profile_contact(platform, participant['id'], contact)
      )
    end

    profile_read = profile_for(platform, participant['id'])
    return if profile_read.equal?(PROFILE_READ_ERROR) && contact

    attributes = profile_read.equal?(PROFILE_READ_ERROR) ? {} : profile_attributes(profile_read).first
    planning_contact = dry_run_profile_contact(platform, participant['id'], contact)
    @stats[:avatars_preserved] += 1 if count_preserved_avatar &&
                                       attributes['profile_pic'].present? &&
                                       avatar_attached?(contact)
    @profile_service.plan(
      platform: platform,
      source_id: participant['id'],
      profile: attributes,
      participant_name: participant['name'],
      observed_sender_username: observed_sender_username(listings, prepared, participant['id']),
      contact: planning_contact
    )
  end

  def profile_attributes(result)
    if result.respond_to?(:attributes) && result.respond_to?(:unavailable_reason)
      [(result.attributes || {}).to_h.stringify_keys, result.unavailable_reason.present?]
    else
      [result.to_h.stringify_keys, false]
    end
  end

  def observed_sender_username(listings, prepared, participant_id)
    listing_username = Array(listings).filter_map do |listing|
      next unless listing.payload.dig('from', 'id').to_s == participant_id.to_s

      listing.payload.dig('from', 'username').presence
    end.first
    return listing_username if listing_username

    Array(prepared).filter_map do |item|
      next unless item.direction == :incoming
      next unless item.detail.dig('from', 'id').to_s == participant_id.to_s

      item.detail.dig('from', 'username').presence
    end.first
  end

  def apply_existing_profile(contact_inbox, plan)
    return unless plan

    if @dry_run
      contact = current_evidence_contact!(contact_inbox, plan)
      current = dry_run_profile_contact(plan.platform, plan.source_id, contact)
      projected = plan.contact_attributes
      changed = current.name != projected[:name] || current.additional_attributes != projected[:additional_attributes]
      record_scalar_change!(@stats, :projected) if changed
      store_dry_run_profile_contact(plan, contact, projected)
      queue_avatar(contact, plan)
      return
    end

    contact_inbox.with_lock do
      contact_inbox.reload
      contact = current_evidence_contact!(contact_inbox, plan)
      result = @profile_service.apply!(contact: contact, plan: plan)
      record_scalar_change!(@stats, :applied) if result.changed
      queue_avatar(contact, plan)
    end
  end

  def current_evidence_contact!(contact_inbox, plan)
    valid = contact_inbox.inbox_id == @inbox.id &&
            contact_inbox.source_id.to_s == plan.source_id.to_s &&
            plan.platform.to_s == @current_platform
    raise ThreadError, :contact_inbox_identity_changed unless valid

    Contact.find(contact_inbox.contact_id)
  end

  def record_projected_profile_change(plan)
    current = dry_run_profile_contact(plan.platform, plan.source_id, nil)
    attributes = plan.contact_attributes
    changed = if current
                current.name != attributes[:name] || current.additional_attributes != attributes[:additional_attributes]
              else
                attributes[:name].present? || attributes[:additional_attributes].present?
              end
    record_scalar_change!(@stats, :projected) if changed
    store_dry_run_profile_contact(plan, nil, attributes)
    queue_avatar(nil, plan)
  end

  def dry_run_profile_contact(platform, source_id, contact)
    return contact unless @dry_run

    @dry_run_profile_contacts.fetch(dry_run_profile_key(platform, source_id, contact), contact)
  end

  def store_dry_run_profile_contact(plan, contact, attributes)
    @dry_run_profile_contacts[dry_run_profile_key(plan.platform, plan.source_id, contact)] = DryRunProfileContact.new(
      id: contact&.id,
      name: attributes[:name],
      additional_attributes: attributes[:additional_attributes].deep_dup,
      persisted: contact&.persisted? || false
    )
  end

  def dry_run_profile_key(platform, source_id, contact)
    contact ? [:contact, contact.id] : [:source, platform.to_sym, source_id.to_s]
  end

  def queue_avatar(contact, plan)
    return unless plan&.avatar_candidate

    if @dry_run
      key = contact ? [:contact, contact.id] : [:source, plan.platform, plan.source_id]
      return unless @dry_run_avatar_urls[key].add?(plan.avatar_candidate.url)

      @stats[:avatars_offered] += 1
      return
    end
    return unless contact

    existing = @avatar_work[contact.id]
    urls = existing&.urls || []
    return if urls.include?(plan.avatar_candidate.url)

    @stats[:avatars_offered] += 1
    @avatar_work[contact.id] = AvatarWork.new(contact_id: contact.id, urls: [*urls, plan.avatar_candidate.url])
  end

  def process_avatars
    @avatar_work.each_value do |work|
      renew_if_due!
      contact = Contact.find_by(id: work.contact_id)
      next unless contact

      work.urls.each do |url|
        result = @profile_service.attach_avatar(
          contact: contact,
          url: url,
          remaining_budget_bytes: @remaining_download_bytes
        )
        @remaining_download_bytes = [@remaining_download_bytes - result.bytes_used, 0].max
        @stats[:avatar_bytes] += result.bytes_used
        @stats[:total_download_bytes] += result.bytes_used
        @stats[:mirror_jobs] += result.mirror_jobs
        record_avatar_result(result)
        break unless result.status.in?(
          %i[invalid_url unsafe_url unsupported_content_type unavailable_url file_too_large]
        )
      end
    end
  end

  def record_avatar_result(result)
    case result.status
    when :attached
      @stats[:avatars_attached] += 1
    when :already_present
      @stats[:avatars_preserved] += 1
    when :concurrent_avatar_preserved
      @stats[:avatars_raced] += 1
    when :invalid_url, :unsafe_url, :unsupported_content_type, :unavailable_url, :file_too_large
      @stats[:avatars_unavailable] += 1
    else
      @stats[:avatar_failures] += 1 if result.incomplete
    end
    @degraded = true if result.degraded
    @stats[:download_budget_exhaustions] += 1 if result.status == :budget_exhausted
    fail_enrichment! if result.incomplete
  end

  def avatar_attached?(contact)
    contact && ActiveStorage::Attachment.exists?(
      name: 'avatar',
      record_type: 'Contact',
      record_id: contact.id
    )
  end

  def renew_if_due!
    return if @clock.call - @last_renewed_at < Umi::Fbig::HistoryImportLock::RENEW_INTERVAL

    renew_lock!
  end

  def stage_prepared(platform, thread_id, prepared)
    staged = []
    prepared.each do |item|
      renew_if_due!
      stage_result = @attachment_service.stage(
        item.attachment_plan,
        remaining_budget_bytes: @remaining_download_bytes,
        intent: Umi::Fbig::HistoryImportAttachmentService::Intent.new(
          run_id: @run_id,
          account_id: @account.id,
          inbox_id: @inbox.id,
          platform: platform,
          thread_id: thread_id,
          mid: item.mid
        )
      )
      staged << item.with(stage_result: stage_result)
      renew_if_due!
      @stats[:attachments_downloaded] += stage_result.attachments.size
      bytes = stage_result.bytes_used
      @remaining_download_bytes -= bytes
      @stats[:attachment_bytes] += bytes
      @stats[:total_download_bytes] += bytes
      omission_count = stage_result.omissions.values.sum
      @stats[:attachments_unavailable] += omission_count
      @stats[:mirror_jobs] += stage_result.attachments.count do |attachment|
        attachment.blob.service.is_a?(ActiveStorage::Service::MirrorService)
      end
      @degraded = true if omission_count.positive?
      stage_result.omissions.each do |reason, count|
        log_detail(
          :attachment_omitted,
          platform: platform,
          thread_id: thread_id,
          mid: item.mid,
          reason: reason,
          count: count
        )
      end
    end
    staged
  rescue Umi::Fbig::HistoryImportAttachmentService::StageError => e
    @stats[:attachment_bytes] += e.bytes_used
    @stats[:total_download_bytes] += e.bytes_used
    if e.budget_exhausted
      @stats[:download_budget_exhaustions] += 1
      @remaining_download_bytes = 0
    else
      @remaining_download_bytes = [@remaining_download_bytes - e.bytes_used, 0].max
    end
    begin
      @attachment_service.cleanup_all_unattached!(staged.map(&:stage_result))
    rescue Umi::Fbig::HistoryImportAttachmentService::CleanupError => cleanup_error
      raise Umi::Fbig::HistoryImportAttachmentService::CleanupError.new(
        cleanup_error.message,
        bytes_used: e.bytes_used,
        budget_exhausted: e.budget_exhausted
      )
    end
    raise ThreadError, :download_budget_exhausted if e.is_a?(Umi::Fbig::HistoryImportAttachmentService::BudgetExceeded)

    raise
  rescue StandardError
    @attachment_service.cleanup_all_unattached!(staged.map(&:stage_result))
    raise
  end

  def validate_arguments!
    valid_channel = @channel.is_a?(Channel::FacebookPage)
    valid_platforms = @platforms.present? && (@platforms - %w[messenger instagram]).empty?
    valid_policy = @outbound_policy.nil? || OUTBOUND_POLICIES.include?(@outbound_policy)
    raise ConfigurationError unless valid_channel && valid_platforms && valid_policy && @before.present?
    raise ConfigurationError if !@dry_run && @outbound_policy.nil?
    raise ConfigurationError if @since && @since >= @before
    raise ConfigurationError if @platforms.include?('instagram') && @channel.instagram_id.blank?
    raise ConfigurationError, 'max download bytes must be a positive integer' if !@dry_run && !@remaining_download_bytes.to_i.positive?
    raise ConfigurationError, 'profile mode must be inline or defer' unless @profile_mode.in?(%w[inline defer])
    raise ConfigurationError, 'accepted contentless details require pre_presence outbound policy' if
      @accepted_contentless_explicit && @outbound_policy != 'pre_presence'

    validate_accepted_contentless!
  end

  def validate_accepted_contentless!
    unless @accepted_contentless.is_a?(Hash) && @accepted_contentless.keys.sort == @platforms.sort
      raise ConfigurationError, 'accepted contentless details must cover exactly the selected platforms'
    end

    @accepted_contentless.each do |platform, result|
      valid = result.is_a?(Umi::Fbig::ContentlessFingerprint::Result) &&
              result.count.is_a?(Integer) &&
              result.count >= 0 &&
              result.fingerprint.match?(/\A[0-9a-f]{64}\z/)
      raise ConfigurationError, "invalid accepted contentless details for #{platform}" unless valid
    end
  end

  def compare_contentless_acceptance!(platform)
    observed = Umi::Fbig::ContentlessFingerprint.build(platform: platform, mids: @contentless_mids[platform])
    @stats[:"#{platform}_contentless_details"] = observed.count
    @stats[:"#{platform}_contentless_fingerprint"] = observed.fingerprint
    if observed == @accepted_contentless.fetch(platform)
      @degraded = true if observed.count.positive?
      return
    end

    @stats[:contentless_acceptance_mismatches] += 1
    fail_write!
    @abort_scan = true unless @dry_run
  end

  def validate_profile_configuration!
    return if @dry_run || @profile_mode == 'defer'

    @profile_service.validate_apply_configuration!
  rescue Umi::Fbig::HistoryImportProfileService::UnsafeConfigurationError => e
    raise ConfigurationError, e.message
  end

  def scalar_change_stat(outcome)
    prefix = @profile_mode == 'defer' ? 'history_evidence_changes' : 'profile_changes'
    :"#{prefix}_#{outcome}"
  end

  def record_scalar_change!(stats, outcome)
    stats[scalar_change_stat(outcome)] += 1
    return unless @profile_mode == 'defer'

    stats[:"#{@current_platform}_history_evidence_changes_#{outcome}"] += 1
  end

  def renew_lock!
    renewed = Umi::Fbig::HistoryImportLock.renew(@channel.id, @run_id)
    raise LockError unless renewed

    @last_renewed_at = @clock.call
  end

  def fail_thread(platform, thread_id, reason, error: nil)
    @stats[:ambiguous_participants] += 1 if reason == :ambiguous_participants
    @stats[:ambiguous_senders] += 1 if reason == :ambiguous_sender
    @stats[:failed_threads] += 1
    fail_write!
    fields = { platform: platform, thread_id: thread_id, reason: reason }
    fields[:error] = error if error
    log_detail(:thread_failed, **fields)
  end

  def record_permanent_ambiguity(platform)
    @stats[:ambiguous_participants] += 1
    @stats[:failed_threads] += 1
    @degraded = true
    log_detail(:thread_omitted, platform: platform, reason: :ambiguous_participants)
  end

  def history_archive_exists?(platform, thread_id)
    return false if thread_id.blank?

    if @dry_run
      @account.conversations.exists?(inbox_id: @inbox.id, identifier: archive_identifier(platform, thread_id))
    else
      @platform_preflights.dig(platform, :by_thread_id, thread_id).present?
    end
  end

  def all_platform_history_complete?
    @platforms.all? { |platform| @platform_history_complete[platform] }
  end

  def fail_write!
    @write_complete = false unless @dry_run
    @degraded = true
    @stats[:exit_failures] += 1
    @history_failures[@current_platform] += 1 if @current_platform
  end

  def fail_enrichment!
    @write_complete = false unless @dry_run
    @degraded = true
    @stats[:exit_failures] += 1
  end

  def parse_time!(value, reason)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise ThreadError, reason
  end

  def required_text!(value, maximum, reason)
    text = value.to_s
    raise ThreadError, reason if text.blank? || text.length > maximum

    text
  end

  def log(stage, **fields)
    payload = fields.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
    @logger.info("[UMI-FBIG] stage=#{stage} #{payload}".strip)
  end

  def log_detail(stage, **fields)
    if @detail_logs_emitted < DETAIL_LOG_LIMIT
      @detail_logs_emitted += 1
      log(stage, **fields)
    else
      @stats[:detail_logs_suppressed] += 1
    end
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity, Rails/SkipsModelValidations
