# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'FB/IG history migration completion record' do
  let(:record_path) { Rails.root.join('docs/UMI-FBIG-HISTORY-MIGRATION-RECORD.md') }
  let(:record) { File.read(record_path) }

  it 'preserves the exact production identity and sealed evidence checksums' do
    expect(record).to include('7570ec0489bb6d79cbb012f36a6d8f0b8957b82e')
    expect(record).to include('sha256:507e113873ca4b560921cccf5777ea4753d186556614bb23158356b801c3b33a')
    expect(record).to include('/opt/umi/fbig-ops/profile-completion-20260801T060110Z')
    expect(record).to include('d87c6556420de482426a355f4dc24f0b3cfd21203d3ebfedb03803f5e223fe68')
    expect(record).to include('4ec2a4df2bba39f4c4ec9a245a17a6ad61239adb1c7d96f9bd76a259a14a8a2b')
  end

  it 'records the accepted history and profile outcome without claiming a later Instagram scan' do
    expect(record).to include('| Messenger | 52 | 633 |')
    expect(record).to include('| Instagram | 607 | 8,408 |')
    expect(record).to include('seven sealed targets. Six were fixed')
    expect(record).to match(/493 contacts in the\s+marker-selected set had an avatar/)
    expect(record).to include('No Instagram successor-2 or later convergence scan was run')
    expect(record).to include('write_complete=false')
  end

  it 'pins the full marker-selected read-state audit rather than a sample' do
    expect(record).to include("jsonb_exists(additional_attributes, 'umi_history_import')")
    expect(record).to include('| Messenger | 68 | 0 | 0 |')
    expect(record).to include('| Instagram | 613 | 0 | 0 |')
    expect(record).to include('| **All imported markers** | **681** | **0** | **0** |')
    expect(record).to match(/Every one\s+of the 681 selected conversations had `status=resolved`/)
    expect(record).to include('zero read-state repairs')
    expect(record).to include('Six legacy rows')
  end

  it 'does not leave the retired importer entrypoints in the application tree' do
    surviving_services = Dir[Rails.root.join('umi/app/services/fbig/*.rb')].map { |path| File.basename(path) }
    # profile_enrichment_service.rb is not a resurrected importer component: it
    # was written fresh under the reviewed plan the migration record demands
    # (docs/UMI-FBIG-PROFILE-REFRESH-SPEC.md) for the ongoing gap the importer
    # never covered. The importer's own profile services stay retired.
    expect(surviving_services).to match_array(
      %w[conversation_recon_service.rb message_heal_service.rb participant_name_service.rb profile_enrichment_service.rb]
    )

    expect(Dir[Rails.root.join('lib/tasks/*fbig*history*.rake')]).to be_empty
    expect(Dir[Rails.root.join('script/umi_fbig/**/*')].reject { |path| File.directory?(path) }).to be_empty

    active_docs = %w[
      UMI-PATCHES.md
      docs/UMI-FBIG-HISTORY-MIGRATION-RECORD.md
      docs/UMI-FBIG-RECON-SPEC.md
    ].map { |path| Rails.root.join(path) }
    retired_reference = %r{umi:fbig:history_|script/umi_fbig|HistoryImportLock|history_import_running|Umi::Fbig::HistoryImport}
    matches = active_docs.to_h { |path| [path.relative_path_from(Rails.root).to_s, File.read(path).scan(retired_reference)] }
                         .reject { |_path, references| references.empty? }

    expect(matches).to be_empty
  end
end
# rubocop:enable RSpec/DescribeClass
