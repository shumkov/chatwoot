# frozen_string_literal: true

require 'active_storage/service/mirror_service'

# The importer keeps trust-boundary validation and callback-free persistence in
# one auditable unit because partial reuse of ordinary model writers is unsafe.
# rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
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
  TaskOptions = Data.define(
    :since,
    :before,
    :dry_run,
    :platforms,
    :outbound_policy,
    :graph_delay_ms,
    :max_conversation_pages,
    :max_message_pages
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
    conversation_pages threads_scanned message_pages mids_scanned already_present previously_imported
    candidate_incoming candidate_outbound outbound_no_native_presence_import outbound_no_native_presence_skip
    outbound_pre_presence_import outbound_pre_presence_skip outbound_all_import outbound_all_skip details_fetched
    content_unavailable attachment_urls_found attachments_downloaded attachments_unsupported attachments_unavailable
    imported_contacts imported_archives imported_incoming imported_outgoing imported_messages imported_attachments
    ambiguous_participants ambiguous_senders foreign_source_id_anomalies failed_threads platform_failures
    retry_exhaustion rate_limits authentication_failures lock_loss late_already_present reindex_jobs reindex_failures
    mirror_jobs projected_archives content_truncated detail_logs_suppressed exit_failures
  ].freeze

  class << self
    def task_options(inbox, env: ENV, now: Time.current)
      raise ConfigurationError, 'inbox must use Channel::FacebookPage' unless inbox.channel.is_a?(Channel::FacebookPage)

      dry_run = parse_boolean(env['DRY_RUN'], default: true, name: 'DRY_RUN')
      since = parse_since(env['SINCE'])
      before = parse_before(env['BEFORE'], dry_run: dry_run, now: now)
      raise ConfigurationError, 'SINCE must be earlier than BEFORE' if since && since >= before

      platforms = parse_platforms(env['PLATFORMS'], inbox.channel)
      outbound_policy = env['OUTBOUND_POLICY'].presence
      unless outbound_policy.nil? || OUTBOUND_POLICIES.include?(outbound_policy)
        raise ConfigurationError, "OUTBOUND_POLICY must be one of #{OUTBOUND_POLICIES.join(',')}"
      end
      raise ConfigurationError, 'OUTBOUND_POLICY is required when DRY_RUN=false' if !dry_run && outbound_policy.nil?
      if !dry_run && inbox.lock_to_single_conversation &&
         env['ACK_SINGLE_CONVERSATION_REOPEN'] != 'true'
        raise ConfigurationError, 'ACK_SINGLE_CONVERSATION_REOPEN=true is required for this inbox'
      end

      TaskOptions.new(
        since: since,
        before: before,
        dry_run: dry_run,
        platforms: platforms,
        outbound_policy: outbound_policy,
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
      )
    end

    private

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
      raise ArgumentError unless parsed.positive?

      parsed
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{name} must be a positive integer"
    end
  end

  def initialize(inbox, since:, before:, dry_run:, platforms:, outbound_policy:, graph_client: nil,
                 attachment_service: nil, logger: Rails.logger, run_id: SecureRandom.uuid, clock: -> { Time.current },
                 graph_options: nil)
    @inbox = inbox
    @channel = inbox.channel
    @account = inbox.account
    @since = since
    @before = before
    @dry_run = dry_run
    @platforms = platforms
    @outbound_policy = outbound_policy
    @graph_client = graph_client
    @graph_options = graph_options
    @attachment_service = attachment_service || Umi::Fbig::HistoryImportAttachmentService.new
    @logger = logger
    @run_id = run_id
    @clock = clock
    @stats = Hash.new(0).merge(STAT_KEYS.index_with(0))
    @scan_complete = true
    @write_complete = dry_run ? nil : true
    @degraded = false
    @abort_scan = false
    @detail_logs_emitted = 0
  end

  def perform
    validate_arguments!
    acquired = Umi::Fbig::HistoryImportLock.acquire(@channel.id, @run_id)
    raise LockError unless acquired

    @last_renewed_at = @clock.call
    validate_existing_configuration! unless @dry_run
    @platforms.each do |platform|
      process_platform(platform)
      break if @abort_scan
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
    pages = graph_client.each_thread(platform, on_page: -> { renew_if_due! }) do |thread|
      process_thread(platform, thread)
    end
    @stats[:conversation_pages] += pages
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
  end

  def process_thread(platform, thread)
    @stats[:threads_scanned] += 1
    thread_id = required_text!(thread['id'], ApplicationRecord::MAX_TEXT_COLUMN_LENGTH, :invalid_thread_id)
    participant = external_participant!(platform, thread)
    result = graph_client.messages(thread_id, on_page: -> { renew_if_due! })
    @stats[:message_pages] += result.pages
    @stats[:mids_scanned] += result.items.size

    listings = in_scope_listings(result.items)
    archive_exists = validate_existing_archive_for_scan!(platform, thread_id, participant['id'])
    candidates = classify_candidates(platform, participant['id'], listings)
    if candidates.empty?
      log_detail(:thread_complete, platform: platform, thread_id: thread_id, candidates: 0, dry_run: @dry_run)
      return
    end

    prepared = prepare_details(platform, thread_id, participant['id'], candidates)
    if prepared.empty? || @dry_run
      @stats[:projected_archives] += 1 if @dry_run && prepared.present? && !archive_exists
      log_detail(:thread_complete, platform: platform, thread_id: thread_id, candidates: prepared.size, dry_run: @dry_run)
      return
    end

    import_thread(platform, thread_id, participant, prepared)
    log_detail(:thread_complete, platform: platform, thread_id: thread_id, candidates: prepared.size, dry_run: false)
  rescue LockError, Umi::Fbig::HistoryImportGraphClient::AuthenticationError
    raise
  rescue Umi::Fbig::HistoryImportGraphClient::RequestError => e
    @scan_complete = false
    @stats[:retry_exhaustion] += 1
    @stats[:rate_limits] += 1 if e.reason == :rate_limit
    fail_thread(platform, thread&.[]('id'), :graph_request_failed, error: e.class.name)
  rescue ThreadError => e
    fail_thread(platform, thread&.[]('id'), e.reason)
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
        fail_write!
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

  def import_thread(platform, thread_id, participant, prepared)
    stage_results = prepared.map(&:stage_result)
    committed = false
    imported_ids = persist_thread(platform, thread_id, participant, prepared)
    committed = true
    reindex_messages(imported_ids)
  ensure
    fail_write! if stage_results.present? && !committed
    @attachment_service.cleanup_all_unattached!(stage_results) if stage_results
  end

  def persist_thread(platform, thread_id, participant, prepared)
    attempts = 0
    begin
      persist_thread_transaction(platform, thread_id, participant, prepared)
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts == 1 && @inbox.contact_inboxes.exists?(source_id: participant['id'])

      raise
    end
  end

  def persist_thread_transaction(platform, thread_id, participant, prepared)
    renew_lock!
    imported_ids = []
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

      contact_inbox, contact_created = contact_inbox_for(platform, participant, remaining)
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
    end
    committed_stats.each { |key, value| @stats[key] += value }
    imported_ids
  end

  def contact_inbox_for(platform, participant, prepared)
    existing = @inbox.contact_inboxes.find_by(source_id: participant['id'])
    return [existing, false] if existing

    earliest = prepared.map(&:created_at).min
    latest = prepared.map(&:created_at).max
    incoming_latest = prepared.select { |item| item.direction == :incoming }.map(&:created_at).max
    contact_id = Contact.insert_all!(
      [{
        account_id: @account.id,
        name: participant['name'].presence.to_s.truncate(ApplicationRecord::MAX_STRING_COLUMN_LENGTH, omission: '')
                                         .presence || fallback_contact_name(platform, participant['id']),
        email: nil,
        phone_number: nil,
        identifier: nil,
        last_activity_at: incoming_latest,
        additional_attributes: {},
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
    [contact_inbox, true]
  end

  def archive_for(platform, thread_id, contact_inbox, prepared)
    identifier = archive_identifier(platform, thread_id)
    existing = @account.conversations.where(inbox_id: @inbox.id, identifier: identifier).limit(2).to_a
    raise ThreadError, :archive_identifier_collision if existing.many?

    if existing.one?
      validate_archive!(existing.first, platform, thread_id, contact_inbox)
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

  def validate_archive!(archive, platform, thread_id, contact_inbox)
    marker = archive.additional_attributes['umi_history_import']
    expected_type = platform == 'instagram' ? 'instagram_direct_message' : nil
    expected_state = archive.resolved? &&
                     archive.inbox_id == @inbox.id &&
                     archive.contact_id == contact_inbox.contact_id &&
                     archive.contact_inbox_id == contact_inbox.id &&
                     archive.assignee_id.nil? &&
                     archive.assignee_agent_bot_id.nil? &&
                     archive.team_id.nil? &&
                     archive.campaign_id.nil? &&
                     archive.sla_policy_id.nil? &&
                     archive.priority.nil? &&
                     archive.snoozed_until.nil? &&
                     archive.waiting_since.nil? &&
                     archive.first_reply_created_at.nil? &&
                     archive.agent_last_seen_at&.to_i == archive.last_activity_at.to_i &&
                     archive.additional_attributes['type'] == expected_type &&
                     marker&.slice('schema_version', 'platform', 'thread_id') ==
                     archive_marker(platform, thread_id).slice('schema_version', 'platform', 'thread_id')
    expected_state &&= marker['configuration'] == configuration unless @dry_run
    imported_only = !archive.messages
                            .where("COALESCE(additional_attributes ->> 'umi_history_import', 'false') <> 'true'")
                            .exists?
    raise ThreadError, :archive_became_live unless expected_state && imported_only
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

  def validate_existing_configuration!
    prefix = "umi-fbig-history:#{@inbox.id}:"
    scope = @account.conversations.where(inbox_id: @inbox.id)
                    .where('identifier LIKE ?', "#{ActiveRecord::Base.sanitize_sql_like(prefix)}%")
    scope.find_each do |archive|
      stored = archive.additional_attributes.dig('umi_history_import', 'configuration')
      raise ConfigurationError unless stored == configuration
    end
  end

  def validate_existing_archive_for_scan!(platform, thread_id, participant_id)
    identifier = archive_identifier(platform, thread_id)
    archives = @account.conversations.where(inbox_id: @inbox.id, identifier: identifier).limit(2).to_a
    return false if archives.empty?
    raise ThreadError, :archive_identifier_collision if archives.many?

    contact_inbox = @inbox.contact_inboxes.find_by(source_id: participant_id)
    raise ThreadError, :archive_identity_mismatch unless contact_inbox

    validate_archive!(archives.first, platform, thread_id, contact_inbox)
    true
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

  def renew_if_due!
    return if @clock.call - @last_renewed_at < Umi::Fbig::HistoryImportLock::RENEW_INTERVAL

    renew_lock!
  end

  def stage_prepared(platform, thread_id, prepared)
    staged = []
    prepared.each do |item|
      renew_if_due!
      stage_result = @attachment_service.stage(item.attachment_plan)
      staged << item.with(stage_result: stage_result)
      renew_if_due!
      @stats[:attachments_downloaded] += stage_result.attachments.size
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

  def fail_write!
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
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity, Rails/SkipsModelValidations
