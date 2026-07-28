# frozen_string_literal: true

require 'digest'

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/ParameterLists, Metrics/PerceivedComplexity
class Umi::Fbig::HistoryProfileBackfillService
  Result = Data.define(:stats, :scan_complete, :write_complete, :degraded, :dry_run, :evidence) do
    def success?
      scan_complete && write_complete != false && stats[:exit_failures].zero?
    end
  end
  Target = Data.define(:platform, :source_id, :contact_inbox_id, :participant_name, :stable, :seed)

  class ConfigurationError < StandardError; end
  class LockError < StandardError; end
  class StructuralError < StandardError; end

  STAT_KEYS = %i[
    conversation_pages participants_scanned participants_without_contact lookup_targets
    messenger_lookup_targets instagram_lookup_targets
    stable_messenger_targets stable_instagram_targets stable_targets_complete seed_targets seed_targets_complete
    profile_requests profile_successes profile_unavailable profile_errors scalar_changes_projected
    scalar_changes_applied avatars_offered avatars_preserved avatars_attached avatars_unavailable avatar_failures
    name_changes_projected name_changes_applied username_changes_projected username_changes_applied
    optional_changes_projected optional_changes_applied avatar_bytes mirror_jobs exit_failures lock_loss
    avatar_intents staging_attached staging_absent
    messenger_targets_success messenger_targets_unavailable messenger_targets_blocking
    instagram_targets_success instagram_targets_unavailable instagram_targets_blocking
    seed_targets_success seed_targets_unavailable seed_targets_blocking
    seed_targets_repaired seed_targets_preserved seed_targets_blank_name seed_targets_blocked
    instagram_placeholders_remaining instagram_placeholders_remaining_fingerprint
    instagram_placeholders_classified_fingerprint instagram_placeholders_unavailable
    instagram_placeholders_unavailable_fingerprint instagram_placeholders_blank_name
    instagram_placeholders_blank_name_fingerprint instagram_placeholders_projected_repair
    instagram_placeholders_unclassified
    ambiguous_participants
    profile_logical_lookups profile_http_attempts conversation_http_attempts rate_limit_retries
    rate_limit_wait_seconds maximum_usage_percent maximum_estimated_regain_minutes
  ].freeze
  DEFAULT_GRAPH_OPTIONS = {
    delay_ms: 250,
    max_conversation_pages: 10_000,
    max_message_pages: 1
  }.freeze

  def self.stable_target_summary(inbox, platforms:, history_configuration:, seed_targets:)
    collector = new(
      inbox,
      dry_run: true,
      platforms: platforms,
      history_configuration: history_configuration,
      seed_targets: seed_targets,
      graph_client: Object.new,
      max_rate_limit_wait_seconds: 1
    )
    collector.send(:collect_local_targets!)
    platforms.index_with do |platform|
      {
        count: collector.instance_variable_get(:@stats).fetch(:"stable_#{platform}_targets"),
        fingerprint: collector.instance_variable_get(:@stats).fetch(:"stable_#{platform}_fingerprint")
      }
    end
  end

  def initialize(inbox, dry_run:, platforms:, history_configuration:, seed_targets:, graph_client: nil,
                 profile_service: nil, max_download_bytes: nil, graph_options: nil,
                 max_rate_limit_wait_seconds: nil, avatar_intent_store: nil,
                 run_evidence: nil,
                 run_id: SecureRandom.uuid, logger: Rails.logger)
    @inbox = inbox
    @channel = inbox.channel
    @account = inbox.account
    @dry_run = dry_run
    @platforms = platforms
    @history_configuration = history_configuration
    @seed_targets = seed_targets
    @graph_client = graph_client
    @run_id = run_id
    @profile_service = profile_service || Umi::Fbig::HistoryImportProfileService.new(
      intent_store: avatar_intent_store,
      renewer: method(:renew_lock!)
    )
    @remaining_download_bytes = max_download_bytes
    @graph_options = graph_options
    @max_rate_limit_wait_seconds = max_rate_limit_wait_seconds
    @run_evidence = run_evidence
    @logger = logger
    @stats = Hash.new(0).merge(STAT_KEYS.index_with(0))
    @targets = {}
    @target_key_by_contact_id = {}
    @stable_keys = Set.new
    @seed_keys = Set.new
    @seed_success_outcomes = {}
    @placeholder_success_outcomes = {}
    @target_outcomes = {}
    @scan_complete = true
    @write_complete = dry_run ? nil : true
    @degraded = false
  end

  def perform
    validate_configuration!
    acquired = Umi::Fbig::HistoryImportLock.acquire(@channel.id, @run_id)
    raise LockError unless acquired

    @run_evidence&.start!(renewer: method(:renew_lock!))
    collect_local_targets!
    scan_current_participants!
    @stats[:lookup_targets] = @targets.size
    @platforms.each do |platform|
      @stats[:"#{platform}_lookup_targets"] = @targets.count { |key, _target| key.first == platform }
    end
    process_targets! if @scan_complete
    record_placeholder_evidence! if @scan_complete
    validate_target_completion!
    record_graph_stats!
    evidence = finalize_run_evidence!
    Result.new(
      stats: @stats.to_h,
      scan_complete: @scan_complete,
      write_complete: @write_complete,
      degraded: @degraded,
      dry_run: @dry_run,
      evidence: evidence
    )
  rescue Umi::Fbig::ProfileRunEvidence::LeaseLost
    raise LockError
  rescue Umi::Fbig::ProfileRunEvidence::InvalidEvidence
    raise StructuralError, 'profile run evidence is invalid'
  ensure
    Umi::Fbig::HistoryImportLock.release(@channel.id, @run_id) if acquired
  end

  private

  def validate_configuration!
    valid = @channel.is_a?(Channel::FacebookPage) &&
            @platforms.present? &&
            (@platforms - %w[messenger instagram]).empty? &&
            @history_configuration == {
              'since' => 'all',
              'before' => @history_configuration['before'],
              'outbound_policy' => 'pre_presence'
            }
    raise ConfigurationError unless valid
    raise ConfigurationError if @platforms.include?('instagram') && @channel.instagram_id.blank?
    raise ConfigurationError unless @seed_targets.empty? || @platforms.include?('instagram')
    raise ConfigurationError, 'max download bytes must be positive' if !@dry_run && !@remaining_download_bytes.to_i.positive?
    raise ConfigurationError, 'max rate wait seconds must be positive' unless @max_rate_limit_wait_seconds.to_i.positive?

    @profile_service.validate_apply_configuration! unless @dry_run
  end

  def collect_local_targets!
    archive_scope.find_each do |archive|
      marker = archive.additional_attributes['umi_history_import']
      platform = marker&.[]('platform')
      thread_id = marker&.[]('thread_id').to_s
      contact_inbox = ContactInbox.find_by(id: archive.contact_inbox_id)
      imported_only = !archive.messages.where(
        "COALESCE(additional_attributes ->> 'umi_history_import', 'false') <> 'true'"
      ).exists?
      valid = marker.is_a?(Hash) &&
              marker.keys.to_set == %w[schema_version platform thread_id configuration].to_set &&
              marker['schema_version'] == Umi::Fbig::HistoryImportService::SCHEMA_VERSION &&
              @platforms.include?(platform) &&
              marker['configuration'] == @history_configuration &&
              archive.identifier == "umi-fbig-history:#{@inbox.id}:#{platform}:#{thread_id}" &&
              archive.resolved? &&
              contact_inbox&.inbox_id == @inbox.id &&
              contact_inbox&.contact_id == archive.contact_id &&
              imported_only
      raise StructuralError, "invalid importer archive #{archive.id}" unless valid

      add_target!(
        platform: platform,
        source_id: contact_inbox.source_id,
        contact_inbox_id: contact_inbox.id,
        stable: true,
        seed: false
      )
    end

    contact_inboxes_by_id = ContactInbox
                            .includes(:contact, :conversations)
                            .where(id: @seed_targets.map(&:contact_inbox_id))
                            .index_by(&:id)
    @seed_targets.each do |row|
      contact_inbox = contact_inboxes_by_id[row.contact_inbox_id]
      valid = contact_inbox&.inbox_id == @inbox.id &&
              contact_inbox.source_id.to_s == row.source_id.to_s &&
              contact_inbox.contact&.account_id == @account.id &&
              Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox) == :instagram
      raise StructuralError, "invalid Instagram seed #{row.contact_inbox_id}" unless valid

      add_target!(
        platform: 'instagram',
        source_id: row.source_id,
        contact_inbox_id: row.contact_inbox_id,
        stable: true,
        seed: true
      )
    end
    record_stable_fingerprints!
  end

  def archive_scope
    @account.conversations.where(inbox_id: @inbox.id).where(
      "additional_attributes -> 'umi_history_import' ->> 'platform' IN (?)",
      @platforms
    )
  end

  def scan_current_participants!
    @platforms.each do |platform|
      pages = graph_client.each_thread(platform) do |thread|
        @stats[:participants_scanned] += 1
        begin
          participant = external_participant!(platform, thread)
        rescue StructuralError
          @stats[:ambiguous_participants] += 1
          @degraded = true
          next
        end
        contact_inbox = @inbox.contact_inboxes.find_by(source_id: participant.fetch('id').to_s)
        unless contact_inbox
          @stats[:participants_without_contact] += 1
          next
        end
        unless Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox) == platform.to_sym
          raise StructuralError, 'profile participant mapping has conflicting platform evidence'
        end

        add_target!(
          platform: platform,
          source_id: participant.fetch('id'),
          contact_inbox_id: contact_inbox.id,
          participant_name: participant['name'],
          stable: false,
          seed: false
        )
      end
      @stats[:conversation_pages] += pages
    end
  rescue Umi::Fbig::HistoryImportGraphClient::AuthenticationError
    fail_run!
    raise
  rescue Umi::Fbig::HistoryImportGraphClient::LeaseLostError
    @stats[:lock_loss] += 1
    fail_run!
  rescue StandardError
    fail_run!
  end

  def external_participant!(platform, thread)
    business_id = platform == 'instagram' ? @channel.instagram_id.to_s : @channel.page_id.to_s
    participants = Array(thread.dig('participants', 'data'))
    external = participants.reject { |participant| participant['id'].to_s == business_id }
    raise StructuralError unless external.one? && external.first['id'].present?

    external.first
  end

  def add_target!(platform:, source_id:, contact_inbox_id:, stable:, seed:, participant_name: nil)
    key = [platform, source_id.to_s]
    existing = @targets[key]
    raise StructuralError, "conflicting target #{platform}" if existing && existing.contact_inbox_id != contact_inbox_id

    contact_inbox = ContactInbox.find(contact_inbox_id)
    existing_key = @target_key_by_contact_id[contact_inbox.contact_id]
    raise StructuralError, 'multiple target identities share one contact' if existing_key && existing_key != key

    @target_key_by_contact_id[contact_inbox.contact_id] = key

    @stable_keys.add(key) if stable
    @seed_keys.add(key) if seed
    @targets[key] = Target.new(
      platform: platform,
      source_id: source_id.to_s,
      contact_inbox_id: contact_inbox_id,
      participant_name: participant_name.presence || existing&.participant_name,
      stable: stable || existing&.stable || false,
      seed: seed || existing&.seed || false
    )
  end

  def record_stable_fingerprints!
    @platforms.each do |platform|
      source_ids = @stable_keys.select { |key| key.first == platform }.map(&:last).sort
      digest = Digest::SHA256.new
      [platform, *source_ids].each do |value|
        bytes = value.encode(Encoding::UTF_8).b
        digest << [bytes.bytesize].pack('Q>') << bytes
      end
      @stats[:"stable_#{platform}_targets"] = source_ids.size
      @stats[:"stable_#{platform}_fingerprint"] = digest.hexdigest
    end
    @stats[:seed_targets] = @seed_keys.size
  end

  def process_targets!
    @targets.values.sort_by { |target| [@platforms.index(target.platform), target.source_id] }.each do |target|
      outcome = process_target!(target)
    rescue Umi::Fbig::HistoryImportGraphClient::AuthenticationError
      outcome = :blocking
      fail_run!
      break
    rescue Umi::Fbig::HistoryImportGraphClient::ProfileError,
           Umi::Fbig::HistoryImportGraphClient::RequestError,
           StructuralError,
           ActiveRecord::RecordNotFound
      outcome = :blocking
      @stats[:profile_errors] += 1
      fail_run!
      break
    rescue Umi::Fbig::HistoryImportGraphClient::LeaseLostError,
           Umi::Fbig::HistoryImportProfileService::LeaseLost
      outcome = :blocking
      @stats[:lock_loss] += 1
      fail_run!
      break
    ensure
      record_target_outcome!(target, outcome) if outcome
    end
  end

  def process_target!(target)
    current_target!(target, lock: false)
    @stats[:profile_requests] += 1
    profile_result = graph_client.profile(target.platform, target.source_id)
    if profile_result.respond_to?(:unavailable_reason) && profile_result.unavailable_reason.present?
      @stats[:profile_unavailable] += 1
      @degraded = true
      return :unavailable
    end

    profile = profile_result.respond_to?(:attributes) ? profile_result.attributes : profile_result
    profile = profile.to_h.stringify_keys
    raise StructuralError unless profile['id'].to_s == target.source_id

    @stats[:profile_successes] += 1
    contact_inbox, contact = current_target!(target, lock: false)
    plan = @profile_service.plan(
      platform: target.platform,
      source_id: target.source_id,
      profile: profile,
      participant_name: target.participant_name,
      contact: contact
    )
    record_placeholder_success_outcome!(target, contact, plan)
    record_seed_success_outcome!(target, contact, plan)
    if @dry_run
      changed = contact.name != plan.contact_attributes[:name] ||
                contact.additional_attributes != plan.contact_attributes[:additional_attributes]
      @stats[:scalar_changes_projected] += 1 if changed
      record_scalar_transitions(contact.name, contact.additional_attributes, plan.contact_attributes, :projected)
      @stats[:avatars_offered] += 1 if plan.avatar_candidate
      return :success
    end

    apply_plan!(target, contact_inbox, plan)
    :success
  end

  def apply_plan!(target, contact_inbox, plan)
    contact = nil
    contact_inbox.with_lock do
      contact_inbox.reload
      _current_contact_inbox, contact = current_target!(target, lock: false, contact_inbox: contact_inbox)
      before_name = contact.name
      before_attributes = contact.additional_attributes.deep_dup
      result = @profile_service.apply!(contact: contact, plan: plan)
      @stats[:scalar_changes_applied] += 1 if result.changed
      record_scalar_transitions(before_name, before_attributes, result.contact_attributes, :applied)
    end
    return unless plan.avatar_candidate

    @stats[:avatars_offered] += 1
    _current_contact_inbox, contact = current_target!(target, lock: false)
    result = @profile_service.attach_avatar(
      contact: contact,
      url: plan.avatar_candidate.url,
      remaining_budget_bytes: @remaining_download_bytes,
      contact_context: ->(&block) { with_current_contact(target, &block) },
      avatar_intent: {
        platform: target.platform,
        source_id: target.source_id,
        contact_inbox_id: target.contact_inbox_id
      }
    )
    @remaining_download_bytes = [@remaining_download_bytes - result.bytes_used, 0].max
    @stats[:avatar_bytes] += result.bytes_used
    @stats[:mirror_jobs] += result.mirror_jobs
    case result.status
    when :attached
      @stats[:avatars_attached] += 1
    when :already_present, :concurrent_avatar_preserved
      @stats[:avatars_preserved] += 1
    when :invalid_url, :unsafe_url, :unsupported_content_type, :unavailable_url, :file_too_large
      @stats[:avatars_unavailable] += 1
      @degraded = true
    else
      @stats[:avatar_failures] += 1
      fail_run!
    end
  end

  def current_target!(target, lock:, contact_inbox: nil)
    contact_inbox ||= ContactInbox.find(target.contact_inbox_id)
    contact_inbox.lock! if lock
    valid = contact_inbox.inbox_id == @inbox.id &&
            contact_inbox.source_id.to_s == target.source_id &&
            Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox) == target.platform.to_sym
    raise StructuralError unless valid

    contact = Contact.find(contact_inbox.contact_id)
    raise StructuralError unless contact.account_id == @account.id

    [contact_inbox, contact]
  end

  def with_current_contact(target)
    ContactInbox.transaction do
      contact_inbox = ContactInbox.lock.find(target.contact_inbox_id)
      valid = contact_inbox.inbox_id == @inbox.id &&
              contact_inbox.source_id.to_s == target.source_id &&
              Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox) == target.platform.to_sym
      raise StructuralError unless valid

      contact = Contact.lock.find(contact_inbox.contact_id)
      raise StructuralError unless contact.account_id == @account.id

      yield contact
    end
  end

  def record_scalar_transitions(before_name, existing_attributes, projected, outcome)
    @stats[:"name_changes_#{outcome}"] += 1 if before_name != projected[:name]
    before_attributes = existing_attributes.is_a?(Hash) ? existing_attributes : {}
    after_attributes = projected[:additional_attributes]
    username_paths = [
      [before_attributes.dig('social_profiles', 'instagram'), after_attributes.dig('social_profiles', 'instagram')],
      [before_attributes['social_instagram_user_name'], after_attributes['social_instagram_user_name']]
    ]
    @stats[:"username_changes_#{outcome}"] += username_paths.count { |before, after| before != after }
    optional_keys = Umi::Fbig::HistoryImportProfileService::INSTAGRAM_OPTIONAL_FIELDS.values
    @stats[:"optional_changes_#{outcome}"] += optional_keys.count do |key|
      before_attributes[key] != after_attributes[key] || before_attributes.key?(key) != after_attributes.key?(key)
    end
  end

  def record_target_outcome!(target, outcome)
    key = [target.platform, target.source_id]
    @target_outcomes[key] = outcome
    if @stable_keys.include?(key)
      @stats[:"#{target.platform}_targets_#{outcome}"] += 1
      @stats[:stable_targets_complete] += 1
    end
    return unless @seed_keys.include?(key)

    @stats[:seed_targets_complete] += 1
    @stats[:"seed_targets_#{outcome}"] += 1
    @stats[:seed_targets_blocked] += 1 if outcome == :blocking
    seed_outcome = case outcome
                   when :success
                     @seed_success_outcomes.fetch(key)
                   when :unavailable
                     :unavailable
                   when :blocking
                     :blocking
                   end
    @stats[:"seed_targets_#{seed_outcome}"] += 1 unless seed_outcome.in?(%i[unavailable blocking])
  end

  def record_placeholder_success_outcome!(target, contact, plan)
    return unless target.platform == 'instagram'
    return unless contact.name == "Instagram user #{target.source_id.last(4)}"

    key = [target.platform, target.source_id]
    @placeholder_success_outcomes[key] =
      if plan.contact_attributes[:name] != contact.name
        :projected_repair
      elsif plan.name_candidate.blank?
        :blank_name
      else
        :unclassified
      end
  end

  def record_seed_success_outcome!(target, contact, plan)
    return unless target.seed

    key = [target.platform, target.source_id]
    placeholder = "Instagram user #{target.source_id.last(4)}"
    outcome = :preserved
    if contact.name == placeholder
      outcome = if plan.contact_attributes[:name] != contact.name
                  :repaired
                elsif plan.name_candidate.blank?
                  @degraded = true
                  :blank_name
                else
                  :preserved
                end
    end
    @seed_success_outcomes[key] = outcome
  end

  def validate_target_completion!
    complete = @stats[:stable_targets_complete] == @stable_keys.size &&
               @stats[:seed_targets_complete] == @seed_keys.size
    fail_run! unless complete || @stats[:exit_failures].positive?
  end

  def record_placeholder_evidence!
    categories = Hash.new { |hash, key| hash[key] = [] }
    @targets.each do |key, target|
      next unless target.platform == 'instagram'

      contact_inbox, contact = current_target!(target, lock: false)
      next unless contact.name == "Instagram user #{target.source_id.last(4)}"

      identity = Digest::SHA256.hexdigest(
        [contact_inbox.id, contact.id, target.source_id].join(':')
      )
      categories[:remaining] << identity
      category = if @target_outcomes[key] == :unavailable
                   :unavailable
                 elsif @target_outcomes[key] == :success
                   @placeholder_success_outcomes.fetch(key, :unclassified)
                 else
                   :unclassified
                 end
      category = :unclassified if category == :projected_repair && !@dry_run
      categories[category] << identity
    end

    %i[remaining unavailable blank_name].each do |category|
      identities = categories[category].sort
      @stats[:"instagram_placeholders_#{category}"] = identities.size
      @stats[:"instagram_placeholders_#{category}_fingerprint"] =
        Digest::SHA256.hexdigest(identities.join("\n"))
    end
    classified = (categories[:unavailable] + categories[:blank_name]).sort
    @stats[:instagram_placeholders_classified_fingerprint] =
      Digest::SHA256.hexdigest(classified.join("\n"))
    @stats[:instagram_placeholders_projected_repair] =
      categories[:projected_repair].size
    @stats[:instagram_placeholders_unclassified] = categories[:unclassified].size
    fail_run! if categories[:unclassified].any?
  end

  def graph_client
    @graph_client ||= Umi::Fbig::HistoryImportGraphClient.new(
      @channel,
      **(@graph_options || DEFAULT_GRAPH_OPTIONS),
      max_rate_limit_wait_seconds: @max_rate_limit_wait_seconds,
      renewer: -> { Umi::Fbig::HistoryImportLock.renew(@channel.id, @run_id) }
    )
  end

  def finalize_run_evidence!
    return unless @run_evidence

    evidence = @run_evidence.finish!(
      stats: @stats,
      dry_run: @dry_run,
      renewer: method(:renew_lock!)
    )
    statuses = evidence.reconciliation.statuses
    @stats[:avatar_intents] = statuses.values.sum
    @stats[:staging_attached] = statuses.fetch(:attached)
    @stats[:staging_absent] = statuses.fetch(:absent)
    evidence
  end

  def record_graph_stats!
    return unless graph_client.respond_to?(:stats)

    graph_client.stats.each do |key, value|
      @stats[key] = value if STAT_KEYS.include?(key)
    end
  end

  def renew_lock!
    Umi::Fbig::HistoryImportLock.renew(@channel.id, @run_id)
  end

  def fail_run!
    @scan_complete = false
    @write_complete = false unless @dry_run
    @degraded = true
    @stats[:exit_failures] += 1
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/ParameterLists, Metrics/PerceivedComplexity
