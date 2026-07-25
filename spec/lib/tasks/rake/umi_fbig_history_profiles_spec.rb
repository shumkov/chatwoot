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
end
# rubocop:enable RSpec/DescribeClass
