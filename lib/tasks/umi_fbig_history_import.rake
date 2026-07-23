# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
namespace :umi do
  namespace :fbig do
    desc 'Import historical Messenger and Instagram conversations as inert resolved archives'
    task :history_import, [:inbox_id] => :environment do |_task, args|
      abort('Usage: bundle exec rake "umi:fbig:history_import[INBOX_ID]"') unless args[:inbox_id].to_s.match?(/\A[1-9]\d*\z/)

      inbox_id = args[:inbox_id].to_i
      inbox = Inbox.find(inbox_id)
      options = Umi::Fbig::HistoryImportService.task_options(inbox)
      graph_options = {
        delay_ms: options.graph_delay_ms,
        max_conversation_pages: options.max_conversation_pages,
        max_message_pages: options.max_message_pages
      }

      puts [
        '[UMI-FBIG] stage=history_import_start',
        "inbox_id=#{inbox.id}",
        "dry_run=#{options.dry_run}",
        "platforms=#{options.platforms.join(',')}",
        "since=#{options.since ? options.since.iso8601 : 'all'}",
        "before=#{options.before.iso8601}",
        "outbound_policy=#{options.outbound_policy || 'report_all'}",
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
  end
end
# rubocop:enable Metrics/BlockLength
