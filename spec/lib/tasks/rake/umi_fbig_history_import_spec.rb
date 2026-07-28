require 'rake'
require 'rails_helper'

# The subject is a named task rather than the Rake::Task class itself.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'umi:fbig:history_import' do
  subject(:task) { Rake::Task['umi:fbig:history_import'] }

  let(:account) { create(:account) }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: '123456789', instagram_id: '987654321')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:approval) do
    values = {
      'schema_version' => '2',
      'repository_commit' => 'a' * 40,
      'image_digest' => "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
      'clone_backup_id' => '20260724T190000Z-0123456789abcdef',
      'clone_database_name' => 'chatwoot_fbig_clone',
      'database_dump_sha256' => 'c' * 64,
      'source_storage_manifest_sha256' => 'd' * 64,
      'restored_storage_manifest_sha256' => 'e' * 64,
      'account_id' => account.id.to_s,
      'inbox_id' => inbox.id.to_s,
      'facebook_page_id' => channel.page_id,
      'instagram_business_id' => channel.instagram_id,
      'since' => 'all',
      'before' => '2025-02-01T00:00:00Z',
      'outbound_policy' => 'pre_presence',
      'profile_mode' => 'defer',
      'messenger_count' => '1',
      'messenger_fingerprint' => 'f' * 64,
      'instagram_count' => '0',
      'instagram_fingerprint' => '1' * 64,
      'messenger_unavailable_message_thread_count' => '0',
      'messenger_unavailable_message_thread_fingerprint' => '901290cdf01a1cd38b6c8ac38c1a36fb1b02376245c8237a44fc6252971bf1fa',
      'instagram_unavailable_message_thread_count' => '2',
      'instagram_unavailable_message_thread_fingerprint' => '3cd76b2a651ef9eab0883e3d7969b3257df34336dd44a2e7e3b05dc6c763042b',
      'placeholder_targets_sha256' => '2' * 64,
      'source_dry_log_sha256' => '3' * 64,
      'source_dry_summary_sha256' => '4' * 64,
      'approved_by' => 'operator@example.com',
      'approved_at' => '2025-02-01T01:00:00Z'
    }
    bytes = Umi::Fbig::HistoryApprovalManifest::FIELD_NAMES.map do |name|
      "#{name}\t#{values.fetch(name)}\n"
    end.join
    Umi::Fbig::HistoryApprovalManifest.parse(bytes)
  end
  let(:environment) do
    {
      DRY_RUN: nil,
      SINCE: nil,
      BEFORE: nil,
      OUTBOUND_POLICY: nil,
      PLATFORMS: nil,
      ACK_SINGLE_CONVERSATION_REOPEN: nil,
      ACK_EXPAND_EXISTING: nil,
      PROFILE_MODE: nil,
      UMI_FBIG_HISTORY_APPROVAL_MODE: nil,
      UMI_FBIG_APPROVAL_MANIFEST_PATH: nil,
      UMI_FBIG_APPROVAL_CHECKSUM_PATH: nil,
      UMI_FBIG_HISTORY_ACCEPTED_CONTENTLESS: nil,
      UMI_FBIG_HISTORY_ACCEPTED_UNAVAILABLE_MESSAGE_THREADS: nil,
      UMI_FBIG_RUNTIME_REPOSITORY_COMMIT: nil,
      UMI_FBIG_RUNTIME_IMAGE_DIGEST: nil,
      UMI_FBIG_HISTORY_EXPECTED_DATABASE: ActiveRecord::Base.connection_db_config.database,
      UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES: nil,
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

  it 'rejects a missing approval mode before loading the inbox' do
    allow(Inbox).to receive(:find)

    with_modified_env(**environment) do
      expect { task.invoke(inbox.id) }
        .to raise_error(SystemExit)
        .and output(/UMI_FBIG_HISTORY_APPROVAL_MODE/).to_stderr
    end

    expect(Inbox).not_to have_received(:find)
  end

  it 'aborts before loading the inbox when the connected database does not match the expected database' do
    allow(Inbox).to receive(:find)
    env = environment.merge(
      DRY_RUN: 'true',
      SINCE: 'all',
      OUTBOUND_POLICY: 'pre_presence',
      PLATFORMS: 'messenger,instagram',
      PROFILE_MODE: 'defer',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'unaccepted_probe',
      UMI_FBIG_HISTORY_EXPECTED_DATABASE: 'not_the_connected_database'
    )

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }
        .to raise_error(SystemExit)
        .and output(/database_identity_mismatch/).to_stderr
    end

    expect(Inbox).not_to have_received(:find)
  end

  it 'requires the expected database before loading the inbox' do
    allow(Inbox).to receive(:find)
    env = environment.merge(
      DRY_RUN: 'true',
      SINCE: 'all',
      OUTBOUND_POLICY: 'pre_presence',
      PLATFORMS: 'messenger,instagram',
      PROFILE_MODE: 'defer',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'unaccepted_probe',
      UMI_FBIG_HISTORY_EXPECTED_DATABASE: nil
    )

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }
        .to raise_error(SystemExit)
        .and output(/UMI_FBIG_HISTORY_EXPECTED_DATABASE is required/).to_stderr
    end

    expect(Inbox).not_to have_received(:find)
  end

  it 'requires the reviewed cutoff, outbound policy, and shared download budget before applying' do
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
    env = environment.merge(
      DRY_RUN: 'true',
      SINCE: 'all',
      OUTBOUND_POLICY: 'pre_presence',
      PLATFORMS: 'messenger,instagram',
      PROFILE_MODE: 'defer',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'unaccepted_probe'
    )

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
      outbound_policy: 'pre_presence',
      accepted_contentless: {
        'messenger' => Umi::Fbig::ContentlessFingerprint.build(platform: 'messenger', mids: []),
        'instagram' => Umi::Fbig::ContentlessFingerprint.build(platform: 'instagram', mids: [])
      },
      accepted_unavailable_message_threads: {
        'messenger' => Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'messenger', records: []),
        'instagram' => Umi::Fbig::UnavailableMessageThreadFingerprint.build(platform: 'instagram', records: [])
      },
      profile_mode: 'defer',
      ack_expand_existing: false,
      max_download_bytes: nil,
      graph_options: {
        delay_ms: 250,
        max_conversation_pages: 10_000,
        max_message_pages: 10_000
      }
    )
  end

  it 'passes explicit expansion acknowledgement to the importer' do
    service = instance_double(Umi::Fbig::HistoryImportService)
    result = Umi::Fbig::HistoryImportService::Result.new(
      stats: { exit_failures: 0 },
      scan_complete: true,
      write_complete: true,
      degraded: false,
      dry_run: false
    )
    allow(Umi::Fbig::HistoryImportService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_return(result)
    allow(Umi::Fbig::HistoryApprovalManifest).to receive(:load).and_return(approval)
    env = environment.merge(
      DRY_RUN: 'false',
      PLATFORMS: 'messenger',
      ACK_EXPAND_EXISTING: 'true',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'approved',
      UMI_FBIG_APPROVAL_MANIFEST_PATH: '/audit/fbig-approval-v2.tsv',
      UMI_FBIG_APPROVAL_CHECKSUM_PATH: '/audit/fbig-approval-v2.tsv.sha256',
      UMI_FBIG_RUNTIME_REPOSITORY_COMMIT: approval.repository_commit,
      UMI_FBIG_RUNTIME_IMAGE_DIGEST: approval.image_digest,
      UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES: '104857600'
    )

    with_modified_env(**env) do
      task.invoke(inbox.id)
    end

    expect(Umi::Fbig::HistoryImportService).to have_received(:new).with(
      inbox,
      since: nil,
      before: Time.zone.parse('2025-02-01 00:00:00 UTC'),
      dry_run: false,
      platforms: ['messenger'],
      outbound_policy: 'pre_presence',
      accepted_contentless: {
        'messenger' => Umi::Fbig::ContentlessFingerprint::Result.new(count: 1, fingerprint: 'f' * 64)
      },
      accepted_unavailable_message_threads: {
        'messenger' => Umi::Fbig::UnavailableMessageThreadFingerprint::Result.new(
          count: 0,
          fingerprint: '901290cdf01a1cd38b6c8ac38c1a36fb1b02376245c8237a44fc6252971bf1fa'
        )
      },
      profile_mode: 'defer',
      ack_expand_existing: true,
      max_download_bytes: 104_857_600,
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
    env = environment.merge(
      DRY_RUN: 'true',
      SINCE: 'all',
      OUTBOUND_POLICY: 'pre_presence',
      PLATFORMS: 'messenger,instagram',
      PROFILE_MODE: 'defer',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'unaccepted_probe'
    )

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
    env = environment.merge(
      DRY_RUN: 'true',
      SINCE: 'all',
      OUTBOUND_POLICY: 'pre_presence',
      PLATFORMS: 'messenger,instagram',
      PROFILE_MODE: 'defer',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'unaccepted_probe'
    )

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end

  it 'rejects unsafe or unbounded task controls' do
    env = environment.merge(
      DRY_RUN: 'true',
      SINCE: 'all',
      OUTBOUND_POLICY: 'pre_presence',
      PLATFORMS: 'messenger,instagram',
      PROFILE_MODE: 'defer',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'unaccepted_probe',
      UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES: '0'
    )

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end

  it 'rejects a non-positive shared download budget' do
    allow(Umi::Fbig::HistoryApprovalManifest).to receive(:load).and_return(approval)
    env = environment.merge(
      DRY_RUN: 'false',
      PLATFORMS: 'messenger',
      ACK_EXPAND_EXISTING: 'true',
      UMI_FBIG_HISTORY_APPROVAL_MODE: 'approved',
      UMI_FBIG_APPROVAL_MANIFEST_PATH: '/audit/fbig-approval-v2.tsv',
      UMI_FBIG_APPROVAL_CHECKSUM_PATH: '/audit/fbig-approval-v2.tsv.sha256',
      UMI_FBIG_RUNTIME_REPOSITORY_COMMIT: approval.repository_commit,
      UMI_FBIG_RUNTIME_IMAGE_DIGEST: approval.image_digest,
      UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES: '0'
    )

    with_modified_env(**env) do
      expect { task.invoke(inbox.id) }.to raise_error(SystemExit)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
