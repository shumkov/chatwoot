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
