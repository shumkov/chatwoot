require 'rake'
require 'rails_helper'

# The subject is a named task rather than the Rake::Task class itself.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'umi:fbig:history_import' do
  subject(:task) { Rake::Task['umi:fbig:history_import'] }

  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: 'page-1', instagram_id: 'instagram-1')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:environment) do
    {
      DRY_RUN: nil,
      SINCE: nil,
      BEFORE: nil,
      OUTBOUND_POLICY: nil,
      PLATFORMS: nil,
      ACK_SINGLE_CONVERSATION_REOPEN: nil,
      UMI_FBIG_HISTORY_GRAPH_DELAY_MS: nil,
      UMI_FBIG_HISTORY_MAX_CONVERSATION_PAGES: nil,
      UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES: nil
    }
  end

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    task.reenable
  end

  it 'requires an explicit historical scope' do
    with_modified_env(**environment) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end

  it 'requires the reviewed cutoff and outbound policy before applying' do
    env = environment.merge(DRY_RUN: 'false', SINCE: 'all')

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end

  it 'runs a dry scan with normalized defaults and prints its fixed cutoff' do
    service = instance_double(Umi::Fbig::HistoryImportService)
    result = Umi::Fbig::HistoryImportService::Result.new(
      stats: { exit_failures: 0, threads_scanned: 2 },
      scan_complete: true,
      write_complete: nil,
      degraded: false,
      dry_run: true
    )
    allow(Umi::Fbig::HistoryImportService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_return(result)
    env = environment.merge(SINCE: 'all')

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }
        .to output(/dry_run=true.*platforms=messenger,instagram.*since=all.*write_complete=not_applicable/m).to_stdout
    end

    expect(Umi::Fbig::HistoryImportService).to have_received(:new).with(
      inbox,
      since: nil,
      before: kind_of(Time),
      dry_run: true,
      platforms: %w[messenger instagram],
      outbound_policy: nil,
      graph_options: {
        delay_ms: 250,
        max_conversation_pages: 10_000,
        max_message_pages: 10_000
      }
    )
  end

  it 'prints unknown attachment downloadability and the single-conversation archive warning in dry run' do
    inbox.update!(lock_to_single_conversation: true)
    service = instance_double(Umi::Fbig::HistoryImportService)
    result = Umi::Fbig::HistoryImportService::Result.new(
      stats: { exit_failures: 0, projected_archives: 2, attachments_downloaded: 0 },
      scan_complete: true,
      write_complete: nil,
      degraded: false,
      dry_run: true
    )
    allow(Umi::Fbig::HistoryImportService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_return(result)
    env = environment.merge(SINCE: 'all')

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }
        .to output(/attachments_downloadable=unknown.*warning=single_conversation_reopen.*projected_archives=2/m).to_stdout
    end
  end

  it 'exits nonzero when the service reports an incomplete scan' do
    service = instance_double(Umi::Fbig::HistoryImportService)
    result = Umi::Fbig::HistoryImportService::Result.new(
      stats: { exit_failures: 1 },
      scan_complete: false,
      write_complete: nil,
      degraded: true,
      dry_run: true
    )
    allow(Umi::Fbig::HistoryImportService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_return(result)
    env = environment.merge(SINCE: 'all')

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end

  it 'rejects unsafe or unbounded task controls' do
    env = environment.merge(SINCE: 'all', UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES: '0')

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
