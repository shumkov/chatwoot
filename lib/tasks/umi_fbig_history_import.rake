# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
namespace :umi do
  namespace :fbig do
    desc 'Import historical Messenger and Instagram conversations as inert resolved archives'
    task :history_import, [:inbox_id] => :environment do |_task, args|
      abort('Usage: bundle exec rake "umi:fbig:history_import[INBOX_ID]"') unless args[:inbox_id].to_s.match?(/\A[1-9]\d*\z/)

      envelope = Umi::Fbig::HistoryImportService.preflight_task_environment!
      expected_database = ENV.fetch('UMI_FBIG_HISTORY_EXPECTED_DATABASE', '').presence
      abort('[UMI-FBIG] configuration_error=UMI_FBIG_HISTORY_EXPECTED_DATABASE is required') unless expected_database

      actual_database = ActiveRecord::Base.connection.select_value('SELECT current_database()')
      unless actual_database == expected_database
        abort("[UMI-FBIG] database_identity_mismatch expected=#{expected_database} actual=#{actual_database}")
      end

      inbox_id = args[:inbox_id].to_i
      inbox = Inbox.find(inbox_id)
      options = Umi::Fbig::HistoryImportService.task_options(inbox, envelope: envelope)
      graph_options = {
        delay_ms: options.graph_delay_ms,
        max_conversation_pages: options.max_conversation_pages,
        max_message_pages: options.max_message_pages
      }

      puts [
        '[UMI-FBIG] stage=history_import_start',
        "approval_mode=#{options.approval_mode}",
        "inbox_id=#{inbox.id}",
        "dry_run=#{options.dry_run}",
        "platforms=#{options.platforms.join(',')}",
        "since=#{options.since ? options.since.iso8601 : 'all'}",
        "before=#{options.before.iso8601}",
        "outbound_policy=#{options.outbound_policy || 'report_all'}",
        "profile_mode=#{options.profile_mode}",
        "ack_expand_existing=#{options.ack_expand_existing}",
        "max_download_bytes=#{options.max_download_bytes || 'not_applicable'}",
        "graph_delay_ms=#{options.graph_delay_ms}",
        "max_conversation_pages=#{options.max_conversation_pages}",
        "max_message_pages=#{options.max_message_pages}"
      ].join(' ')

      result = Umi::Fbig::HistoryImportService.new(
        inbox,
        since: options.since,
        before: options.before,
        dry_run: options.dry_run,
        platforms: options.platforms,
        outbound_policy: options.outbound_policy,
        profile_mode: options.profile_mode,
        accepted_contentless: options.accepted_contentless,
        ack_expand_existing: options.ack_expand_existing,
        max_download_bytes: options.max_download_bytes,
        graph_options: graph_options
      ).perform

      stats = result.stats.sort.map { |key, value| "#{key}=#{value}" }.join(' ')
      write_complete = result.write_complete.nil? ? 'not_applicable' : result.write_complete
      puts [
        '[UMI-FBIG] stage=history_import_summary',
        "dry_run=#{result.dry_run}",
        "scan_complete=#{result.scan_complete}",
        "write_complete=#{write_complete}",
        "degraded=#{result.degraded}",
        "attachments_downloadable=#{result.attachments_downloadable}",
        stats
      ].join(' ')
      if result.dry_run && inbox.lock_to_single_conversation
        puts [
          '[UMI-FBIG] warning=single_conversation_reopen',
          "inbox_id=#{inbox.id}",
          "projected_archives=#{result.stats[:projected_archives]}"
        ].join(' ')
      end
      abort('[UMI-FBIG] historical import incomplete; review the summary and rerun safely') unless result.success?
    rescue ActiveRecord::RecordNotFound
      abort("[UMI-FBIG] inbox_id=#{args[:inbox_id]} not found")
    rescue Umi::Fbig::HistoryImportService::ConfigurationError => e
      abort("[UMI-FBIG] configuration_error=#{e.message}")
    rescue Umi::Fbig::HistoryImportService::LockError
      abort('[UMI-FBIG] another FB/IG writer owns the channel lock')
    end

    desc 'Enrich existing Messenger and Instagram contacts after history import'
    task :history_profiles, [:inbox_id] => :environment do |_task, args|
      abort('Usage: bundle exec rake "umi:fbig:history_profiles[INBOX_ID]"') unless
        args[:inbox_id].to_s.match?(/\A[1-9]\d*\z/)

      actual_database = ActiveRecord::Base.connection.select_value('SELECT current_database()')
      options = Umi::Fbig::ProfileTaskConfiguration.build(env: ENV, actual_database: actual_database)
      inbox = Inbox.find(args[:inbox_id].to_i)
      Umi::Fbig::ProfileTaskConfiguration.validate_scope!(inbox, options)
      intent_store = Umi::Fbig::AvatarIntentStore.new(directory: options.avatar_intent_directory)
      graph_options = {
        delay_ms: options.graph_delay_ms,
        max_conversation_pages: options.max_conversation_pages,
        max_message_pages: 1
      }
      puts [
        '[UMI-FBIG] stage=history_profiles_start',
        "approval_mode=#{options.approval_mode}",
        "clone_phase=#{options.clone_phase || 'none'}",
        "database=#{options.actual_database}",
        "production_database=#{options.production_database_name}",
        "repository_commit=#{options.repository_commit}",
        "image_digest=#{options.image_digest}",
        "inbox_id=#{inbox.id}",
        "dry_run=#{options.dry_run}",
        "platforms=#{options.platforms.join(',')}",
        "history_manifest_sha256=#{options.history_manifest.sha256}",
        "profile_approval_sha256=#{options.profile_approval&.sha256 || 'none'}",
        "pre_attempt_backup_sha256=#{options.pre_attempt_backup&.sha256 || 'none'}",
        "source_state_sha256=#{options.source_state&.sha256 || 'none'}",
        "predecessor_state_sha256=#{options.predecessor_state&.sha256 || 'none'}",
        "graph_delay_ms=#{options.graph_delay_ms}",
        "max_conversation_pages=#{options.max_conversation_pages}",
        "max_rate_limit_wait_seconds=#{options.max_rate_limit_wait_seconds}",
        "max_download_bytes=#{options.max_download_bytes}"
      ].join(' ')

      result = Umi::Fbig::HistoryProfileBackfillService.new(
        inbox,
        dry_run: options.dry_run,
        platforms: options.platforms,
        history_configuration: {
          'since' => options.history_manifest.since,
          'before' => options.history_manifest.values.fetch('before'),
          'outbound_policy' => options.history_manifest.outbound_policy
        },
        seed_targets: options.seed_targets,
        max_download_bytes: options.max_download_bytes,
        max_rate_limit_wait_seconds: options.max_rate_limit_wait_seconds,
        graph_options: graph_options,
        avatar_intent_store: intent_store,
        run_evidence: Umi::Fbig::ProfileRunEvidence.new(
          inbox: inbox,
          mode: options.approval_mode,
          clone_phase: options.clone_phase,
          source_state: options.source_state,
          predecessor_state: options.predecessor_state,
          attempt_directory: options.attempt_directory,
          intent_store: intent_store
        )
      ).perform
      stats = result.stats.sort.map { |key, value| "#{key}=#{value}" }.join(' ')
      puts [
        '[UMI-FBIG] stage=history_profiles_summary',
        "approval_mode=#{options.approval_mode}",
        "clone_phase=#{options.clone_phase || 'none'}",
        "database=#{options.actual_database}",
        "production_database=#{options.production_database_name}",
        "repository_commit=#{options.repository_commit}",
        "image_digest=#{options.image_digest}",
        "history_manifest_sha256=#{options.history_manifest.sha256}",
        "profile_approval_sha256=#{options.profile_approval&.sha256 || 'none'}",
        "source_state_sha256=#{options.source_state&.sha256 || 'none'}",
        "predecessor_state_sha256=#{options.predecessor_state&.sha256 || 'none'}",
        "dry_run=#{result.dry_run}",
        "scan_complete=#{result.scan_complete}",
        "write_complete=#{result.write_complete.nil? ? 'not_applicable' : result.write_complete}",
        "degraded=#{result.degraded}",
        "prestate_sha256=#{result.evidence&.prestate&.sha256 || 'none'}",
        "poststate_sha256=#{result.evidence&.poststate&.sha256 || 'none'}",
        "avatar_staging_sha256=#{result.evidence&.staging&.sha256 || 'none'}",
        stats
      ].join(' ')
      abort('[UMI-FBIG] profile import incomplete; review the summary') unless result.success?
    rescue ActiveRecord::RecordNotFound
      abort("[UMI-FBIG] inbox_id=#{args[:inbox_id]} not found")
    rescue Umi::Fbig::ProfileTaskConfiguration::ConfigurationError => e
      abort("[UMI-FBIG] configuration_error=#{e.message}")
    rescue Umi::Fbig::HistoryProfileBackfillService::LockError
      abort('[UMI-FBIG] another FB/IG writer owns the channel lock')
    rescue Umi::Fbig::HistoryProfileBackfillService::StructuralError,
           Umi::Fbig::ProfileRunEvidence::InvalidEvidence
      abort('[UMI-FBIG] profile evidence or target structure is invalid')
    end

    desc 'Capture a checksummed PII-free profile baseline without Meta access'
    task :history_profile_state, [:inbox_id] => :environment do |_task, args|
      abort('Usage: bundle exec rake "umi:fbig:history_profile_state[INBOX_ID]"') unless
        args[:inbox_id].to_s.match?(/\A[1-9]\d*\z/)
      expected_database = ENV.fetch('UMI_FBIG_HISTORY_EXPECTED_DATABASE', '').presence
      abort('[UMI-FBIG] configuration_error=UMI_FBIG_HISTORY_EXPECTED_DATABASE is required') unless expected_database
      output_directory = ENV.fetch('UMI_FBIG_PROFILE_STATE_OUTPUT_DIR', '').presence
      abort('[UMI-FBIG] configuration_error=UMI_FBIG_PROFILE_STATE_OUTPUT_DIR is required') unless output_directory

      actual_database = ActiveRecord::Base.connection.select_value('SELECT current_database()')
      abort('[UMI-FBIG] database_identity_mismatch') unless actual_database == expected_database
      inbox = Inbox.find(args[:inbox_id].to_i)
      run_id = SecureRandom.uuid
      acquired = Umi::Fbig::HistoryImportLock.acquire(inbox.channel.id, run_id)
      abort('[UMI-FBIG] another FB/IG writer owns the channel lock') unless acquired
      artifact = Umi::Fbig::ProfileStateSnapshot.capture_and_seal!(
        inbox,
        directory: output_directory,
        basename: 'fbig-profile-state-v1.tsv',
        renewer: -> { Umi::Fbig::HistoryImportLock.renew(inbox.channel.id, run_id) }
      )
      puts [
        '[UMI-FBIG] stage=history_profile_state_complete',
        "database=#{actual_database}",
        "inbox_id=#{inbox.id}",
        "row_count=#{artifact.rows.size}",
        "state_sha256=#{artifact.sha256}"
      ].join(' ')
    rescue ActiveRecord::RecordNotFound
      abort("[UMI-FBIG] inbox_id=#{args[:inbox_id]} not found")
    rescue Umi::Fbig::ProfileStateSnapshot::InvalidSnapshot
      abort('[UMI-FBIG] profile state capture is invalid')
    rescue Umi::Fbig::ProfileStateSnapshot::LeaseLost
      abort('[UMI-FBIG] profile state capture lost its writer lock')
    ensure
      Umi::Fbig::HistoryImportLock.release(inbox.channel.id, run_id) if acquired
    end
  end
end
# rubocop:enable Metrics/BlockLength
