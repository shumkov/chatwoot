require 'rake'
require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'UMI FB/IG profile rake tasks' do
  describe 'umi:fbig:history_profiles' do
    subject(:task) { Rake::Task['umi:fbig:history_profiles'] }

    before do
      task.reenable
    end

    it 'is exposed as a separate task' do
      expect(task).to be_present
    end

    it 'rejects a missing profile approval mode before loading the inbox' do
      allow(Inbox).to receive(:find)
      env = {
        UMI_FBIG_PROFILE_APPROVAL_MODE: nil,
        UMI_FBIG_HISTORY_EXPECTED_DATABASE: ActiveRecord::Base.connection_db_config.database
      }

      with_modified_env(**env) do
        expect { task.invoke(1) }
          .to raise_error(SystemExit)
          .and output(/UMI_FBIG_PROFILE_APPROVAL_MODE/).to_stderr
      end

      expect(Inbox).not_to have_received(:find)
    end

    # rubocop:disable RSpec/ExampleLength
    it 'logs the strict-parser seed count for downstream conservation checks' do
      history = instance_double(
        Umi::Fbig::HistoryApprovalManifest,
        sha256: 'a' * 64,
        since: 'all',
        values: { 'before' => '2026-07-28T15:39:00Z' },
        outbound_policy: 'pre_presence'
      )
      seed_targets = Array.new(7) { Object.new }
      options = Umi::Fbig::ProfileTaskConfiguration::Options.new(
        approval_mode: 'clone_evidence',
        clone_phase: 'dry',
        dry_run: true,
        platforms: %w[messenger instagram],
        actual_database: 'chatwoot_fbig_clone',
        production_database_name: 'chatwoot_production',
        repository_commit: 'b' * 40,
        image_digest: "ghcr.io/shumkov/chatwoot@sha256:#{'c' * 64}",
        graph_delay_ms: 250,
        max_conversation_pages: 10_000,
        max_rate_limit_wait_seconds: 3_600,
        max_download_bytes: 100.megabytes,
        history_manifest: history,
        profile_approval: nil,
        pre_attempt_backup: nil,
        seed_targets: seed_targets,
        source_state: nil,
        predecessor_state: nil,
        attempt_directory: '/tmp/fbig-profile-attempt',
        avatar_intent_directory: '/tmp/fbig-profile-attempt/avatar-intents'
      )
      inbox = instance_double(Inbox, id: 2)
      intent_store = instance_double(Umi::Fbig::AvatarIntentStore)
      run_evidence = instance_double(Umi::Fbig::ProfileRunEvidence)
      service = instance_double(Umi::Fbig::HistoryProfileBackfillService)
      result = Umi::Fbig::HistoryProfileBackfillService::Result.new(
        stats: { exit_failures: 0 },
        scan_complete: true,
        write_complete: nil,
        degraded: false,
        dry_run: true,
        evidence: nil
      )
      allow(Umi::Fbig::ProfileTaskConfiguration).to receive(:build).and_return(options)
      allow(Umi::Fbig::ProfileTaskConfiguration).to receive(:validate_scope!).and_return(true)
      allow(Inbox).to receive(:find).with(2).and_return(inbox)
      allow(Umi::Fbig::AvatarIntentStore).to receive(:new).and_return(intent_store)
      allow(Umi::Fbig::ProfileRunEvidence).to receive(:new).and_return(run_evidence)
      allow(Umi::Fbig::HistoryProfileBackfillService).to receive(:new).and_return(service)
      allow(service).to receive(:perform).and_return(result)

      expect { task.invoke(2) }
        .to output(/stage=history_profiles_start.*seed_targets_expected=7/).to_stdout
    end
    # rubocop:enable RSpec/ExampleLength
  end

  describe 'umi:fbig:history_profile_state' do
    subject(:task) { Rake::Task['umi:fbig:history_profile_state'] }

    before do
      task.reenable
    end

    it 'is exposed as a separate no-Meta state-capture task' do
      expect(task).to be_present
    end

    it 'rejects a missing expected database before loading the inbox' do
      allow(Inbox).to receive(:find)

      with_modified_env(
        UMI_FBIG_HISTORY_EXPECTED_DATABASE: nil,
        UMI_FBIG_PROFILE_STATE_OUTPUT_DIR: nil
      ) do
        expect { task.invoke(1) }
          .to raise_error(SystemExit)
          .and output(/UMI_FBIG_HISTORY_EXPECTED_DATABASE/).to_stderr
      end

      expect(Inbox).not_to have_received(:find)
    end
  end

  describe 'umi:fbig:history_state' do
    subject(:task) { Rake::Task['umi:fbig:history_state'] }

    before do
      task.reenable
    end

    it 'is exposed as a separate no-Meta importer-graph capture task' do
      expect(task).to be_present
    end

    it 'rejects a missing expected database before loading the inbox' do
      allow(Inbox).to receive(:find)

      with_modified_env(
        UMI_FBIG_HISTORY_EXPECTED_DATABASE: nil,
        UMI_FBIG_HISTORY_STATE_OUTPUT_DIR: nil,
        UMI_FBIG_HISTORY_STATE_BASENAME: nil,
        PLATFORMS: nil
      ) do
        expect { task.invoke(1) }
          .to raise_error(SystemExit)
          .and output(/UMI_FBIG_HISTORY_EXPECTED_DATABASE/).to_stderr
      end

      expect(Inbox).not_to have_received(:find)
    end
  end

  describe 'umi:fbig:history_state_compare' do
    subject(:task) { Rake::Task['umi:fbig:history_state_compare'] }

    before do
      task.reenable
    end

    it 'is exposed as a separate no-Meta conservation task' do
      expect(task).to be_present
    end

    it 'rejects missing snapshot paths before loading the inbox' do
      allow(Inbox).to receive(:find)

      with_modified_env(
        UMI_FBIG_HISTORY_EXPECTED_DATABASE: ActiveRecord::Base.connection_db_config.database,
        UMI_FBIG_HISTORY_PRESTATE_PATH: nil,
        UMI_FBIG_HISTORY_PRESTATE_CHECKSUM_PATH: nil,
        UMI_FBIG_HISTORY_POSTSTATE_PATH: nil,
        UMI_FBIG_HISTORY_POSTSTATE_CHECKSUM_PATH: nil,
        UMI_FBIG_HISTORY_SUMMARY_PATH: nil,
        UMI_FBIG_HISTORY_REQUIRE_ZERO_WRITES: nil
      ) do
        expect { task.invoke(1) }
          .to raise_error(SystemExit)
          .and output(/snapshot paths are required/).to_stderr
      end

      expect(Inbox).not_to have_received(:find)
    end
  end

  describe 'umi:fbig:history_attachment_reconcile' do
    subject(:task) { Rake::Task['umi:fbig:history_attachment_reconcile'] }

    let(:account) { create(:account) }
    let(:channel) { build(:channel_facebook_page, account: account, inbox: nil) }
    let(:inbox) { create(:inbox, account: account, channel: channel) }

    before do
      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
      task.reenable
    end

    it 'reconciles staged blobs under the shared history writer lock' do
      allow(Umi::Fbig::HistoryImportLock).to receive(:acquire).and_return(true)
      allow(Umi::Fbig::HistoryImportLock).to receive(:release)
      allow(Umi::Fbig::HistoryImportAttachmentService).to receive(:reconcile!)
        .with(inbox: inbox).and_return(purged: 2, attached: 1)

      with_modified_env(
        UMI_FBIG_HISTORY_EXPECTED_DATABASE: ActiveRecord::Base.connection_db_config.database
      ) do
        expect { task.invoke(inbox.id) }
          .to output(/stage=history_attachment_reconciliation.*purged=2.*attached=1/).to_stdout
      end

      expect(Umi::Fbig::HistoryImportLock).to have_received(:release).with(
        inbox.channel.id,
        kind_of(String)
      )
    end

    it 'rejects a missing expected database before loading the inbox' do
      allow(Inbox).to receive(:find)

      with_modified_env(UMI_FBIG_HISTORY_EXPECTED_DATABASE: nil) do
        expect { task.invoke(1) }
          .to raise_error(SystemExit)
          .and output(/UMI_FBIG_HISTORY_EXPECTED_DATABASE/).to_stderr
      end

      expect(Inbox).not_to have_received(:find)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
