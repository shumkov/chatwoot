require 'rails_helper'

# rubocop:disable Rails/SkipsModelValidations
RSpec.describe Umi::Fbig::ProfileRunEvidence do
  let(:account) { create(:account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: '991234') }
  let(:channel) do
    build(:channel_facebook_page, account: account, inbox: nil, page_id: '1000', instagram_id: '2000')
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) { create(:contact, account: account, name: 'Instagram user 1234') }

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    contact_inbox
  end

  it 'rejects a clone dry/apply phase whose prestate already contains an eligible mutation' do
    source_state = Umi::Fbig::ProfileStateSnapshot.capture(inbox)
    contact.update_columns(name: 'Profile Name')
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      evidence = described_class.new(
        inbox: inbox,
        mode: 'clone_evidence',
        clone_phase: 'apply',
        source_state: source_state,
        predecessor_state: nil,
        attempt_directory: attempt_directory,
        intent_store: Umi::Fbig::AvatarIntentStore.new(directory: intent_directory, expected_uid: Process.uid),
        expected_uid: Process.uid
      )

      expect { evidence.start!(renewer: -> { true }) }.to raise_error(described_class::InvalidEvidence)
    end
  end

  it 'accepts idempotency only when the current prestate exactly matches the preceding apply poststate' do
    source_state = Umi::Fbig::ProfileStateSnapshot.capture(inbox)
    contact.update_columns(name: 'Profile Name')
    predecessor_state = Umi::Fbig::ProfileStateSnapshot.capture(inbox)
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      evidence = described_class.new(
        inbox: inbox,
        mode: 'clone_evidence',
        clone_phase: 'idempotency',
        source_state: source_state,
        predecessor_state: predecessor_state,
        attempt_directory: attempt_directory,
        intent_store: Umi::Fbig::AvatarIntentStore.new(directory: intent_directory, expected_uid: Process.uid),
        expected_uid: Process.uid
      )

      expect(evidence.start!(renewer: -> { true }).sha256).to eq(predecessor_state.sha256)
      expect(Pathname.new(attempt_directory).join('fbig-profile-clone-prestate-v1.tsv')).to exist
    end
  end

  it 'rejects production-first profile work when live state drifted after approval' do
    source_state = Umi::Fbig::ProfileStateSnapshot.capture(inbox)
    contact.update_columns(name: 'Profile Name')
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      evidence = described_class.new(
        inbox: inbox,
        mode: 'production_first',
        source_state: source_state,
        attempt_directory: attempt_directory,
        intent_store: Umi::Fbig::AvatarIntentStore.new(directory: intent_directory, expected_uid: Process.uid),
        expected_uid: Process.uid
      )

      expect { evidence.start!(renewer: -> { true }) }.to raise_error(described_class::InvalidEvidence)
    end
  end

  it 'admits a production-first zero-write successor from the exact preceding poststate' do
    source_state = Umi::Fbig::ProfileStateSnapshot.capture(inbox)
    contact.update_columns(name: 'Profile Name')
    predecessor_state = Umi::Fbig::ProfileStateSnapshot.capture(inbox)
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      evidence = described_class.new(
        inbox: inbox,
        mode: 'production_first',
        source_state: source_state,
        predecessor_state: predecessor_state,
        attempt_directory: attempt_directory,
        intent_store: Umi::Fbig::AvatarIntentStore.new(directory: intent_directory, expected_uid: Process.uid),
        expected_uid: Process.uid
      )

      expect(evidence.start!(renewer: -> { true }).sha256).to eq(predecessor_state.sha256)
      result = evidence.finish!(
        stats: {
          name_changes_applied: 0,
          username_changes_applied: 0,
          optional_changes_applied: 0,
          avatars_attached: 0
        },
        dry_run: false,
        renewer: -> { true }
      )
      expect(result.prestate.sha256).to eq(result.poststate.sha256)
    end
  end

  it 'seals production prestate, staging, and poststate and accepts only counter-attributed transitions' do
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      intent_store = Umi::Fbig::AvatarIntentStore.new(directory: intent_directory, expected_uid: Process.uid)
      evidence = described_class.new(
        inbox: inbox,
        mode: 'production',
        source_state: nil,
        attempt_directory: attempt_directory,
        intent_store: intent_store,
        expected_uid: Process.uid
      )

      evidence.start!(renewer: -> { true })
      contact.update_columns(name: 'Profile Name')
      result = evidence.finish!(
        stats: {
          name_changes_applied: 1,
          username_changes_applied: 0,
          optional_changes_applied: 0,
          avatars_attached: 0
        },
        dry_run: false,
        renewer: -> { true }
      )

      expect(result.comparison).to be_success
      expect(result.reconciliation.statuses).to eq(attached: 0, absent: 0)
      expect(result.prestate.sha256).not_to eq(result.poststate.sha256)
      expect(Pathname.new(attempt_directory).children.map(&:basename).map(&:to_s)).to include(
        'fbig-profile-production-prestate-v1.tsv',
        'fbig-profile-production-prestate-v1.tsv.sha256',
        'fbig-profile-avatar-staging-v1.tsv',
        'fbig-profile-avatar-staging-v1.tsv.sha256',
        'fbig-profile-production-poststate-v1.tsv',
        'fbig-profile-production-poststate-v1.tsv.sha256'
      )
    end
  end

  it 'blocks protected drift before reporting a clean attempt' do
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      evidence = described_class.new(
        inbox: inbox,
        mode: 'production',
        source_state: nil,
        attempt_directory: attempt_directory,
        intent_store: Umi::Fbig::AvatarIntentStore.new(directory: intent_directory, expected_uid: Process.uid),
        expected_uid: Process.uid
      )

      evidence.start!(renewer: -> { true })
      contact.update_columns(email: 'protected@example.com')

      expect do
        evidence.finish!(
          stats: {
            name_changes_applied: 0,
            username_changes_applied: 0,
            optional_changes_applied: 0,
            avatars_attached: 0
          },
          dry_run: false,
          renewer: -> { true }
        )
      end.to raise_error(described_class::InvalidEvidence)
    end
  end
end
# rubocop:enable Rails/SkipsModelValidations
