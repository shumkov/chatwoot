require 'rails_helper'

RSpec.describe Umi::Fbig::ProfileTaskConfiguration do
  let(:commit) { 'a' * 40 }
  let(:image) { "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}" }
  let(:history) do
    instance_double(
      Umi::Fbig::HistoryApprovalManifest,
      sha256: 'c' * 64,
      repository_commit: commit,
      image_digest: image,
      clone_database_name: 'chatwoot_fbig_clone',
      placeholder_targets_sha256: 'd' * 64
    )
  end
  let(:source_state) { instance_double(Umi::Fbig::ProfileStateSnapshot::Artifact) }

  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(Umi::Fbig::HistoryApprovalManifest).to receive(:load).and_return(history)
    allow(Umi::Fbig::ProfileStateSnapshot).to receive(:load).and_return(source_state)
    allow(Umi::Fbig::ProfileTargetManifest).to receive(:load).and_return([])
  end

  it 'rejects a sealed target without canonical Instagram-only evidence' do
    account = create(:account)
    channel = build(
      :channel_facebook_page,
      account: account,
      inbox: nil,
      page_id: '1000',
      instagram_id: '2000'
    )
    inbox = create(:inbox, account: account, channel: channel)
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '303')
    target = Umi::Fbig::ProfileTargetManifest::Row.new(
      contact_inbox_id: contact_inbox.id,
      contact_id: contact.id,
      source_id: '303'
    )
    scoped_history = instance_double(
      Umi::Fbig::HistoryApprovalManifest,
      account_id: account.id,
      inbox_id: inbox.id,
      facebook_page_id: channel.page_id,
      instagram_business_id: channel.instagram_id
    )
    options = instance_double(
      Umi::Fbig::ProfileTaskConfiguration::Options,
      history_manifest: scoped_history,
      profile_approval: nil,
      pre_attempt_backup: nil,
      source_state: nil,
      predecessor_state: nil,
      seed_targets: [target]
    )

    expect do
      described_class.validate_scope!(inbox, options)
    end.to raise_error(described_class::ConfigurationError, /profile target mapping/)
  end

  it 'builds clone evidence only from explicit reviewed settings and isolated attempt paths' do
    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'clone_evidence',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_fbig_clone',
        'UMI_FBIG_PROFILE_CLONE_PHASE' => 'dry',
        'DRY_RUN' => 'true',
        'PLATFORMS' => 'messenger,instagram',
        'UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME' => 'chatwoot_production',
        'UMI_FBIG_PROFILE_GRAPH_DELAY_MS' => '250',
        'UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES' => '10000',
        'UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS' => '3600',
        'UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES' => '104857600',
        'UMI_FBIG_PROFILE_STATE_PATH' => '/evidence/fbig-profile-state-v1.tsv',
        'UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH' => '/evidence/fbig-profile-state-v1.tsv.sha256'
      )

      options = described_class.build(
        env: env,
        actual_database: 'chatwoot_fbig_clone',
        expected_uid: Process.uid
      )

      expect(options).to have_attributes(
        approval_mode: 'clone_evidence',
        clone_phase: 'dry',
        dry_run: true,
        actual_database: 'chatwoot_fbig_clone',
        production_database_name: 'chatwoot_production',
        repository_commit: commit,
        image_digest: image,
        graph_delay_ms: 250,
        max_download_bytes: 104_857_600,
        attempt_directory: attempt_directory,
        avatar_intent_directory: intent_directory,
        source_state: source_state,
        pre_attempt_backup: nil
      )
    end
  end

  it 'derives production settings and database identity only from the immutable approval and backup' do
    profile = instance_double(
      Umi::Fbig::ProfileApprovalManifest,
      history_manifest_sha256: history.sha256,
      clone_database_name: 'chatwoot_fbig_clone',
      production_database_name: 'chatwoot_production',
      repository_commit: commit,
      image_digest: image,
      platforms: %w[messenger instagram],
      predecessor_profile_approval_sha256: 'none',
      graph_delay_ms: 300,
      max_conversation_pages: 9000,
      max_rate_limit_wait_seconds: 1800,
      max_avatar_download_bytes: 50.megabytes
    )
    backup = instance_double(Umi::Fbig::ProfilePreAttemptBackupManifest)
    allow(Umi::Fbig::ProfileApprovalManifest).to receive(:load).and_return(profile)
    allow(Umi::Fbig::ProfilePreAttemptBackupManifest).to receive(:load).and_return(backup)

    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'production',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_production',
        'DRY_RUN' => 'false',
        'PLATFORMS' => 'messenger,instagram',
        'UMI_FBIG_PROFILE_APPROVAL_MANIFEST_PATH' => '/approval/fbig-profile-approval-v1.tsv',
        'UMI_FBIG_PROFILE_APPROVAL_CHECKSUM_PATH' => '/approval/fbig-profile-approval-v1.tsv.sha256',
        'UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_PATH' =>
          '/backup/fbig-profile-pre-attempt-backup-v1.tsv',
        'UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_CHECKSUM_PATH' =>
          '/backup/fbig-profile-pre-attempt-backup-v1.tsv.sha256'
      )

      options = described_class.build(
        env: env,
        actual_database: 'chatwoot_production',
        expected_uid: Process.uid
      )

      expect(options).to have_attributes(
        approval_mode: 'production',
        dry_run: false,
        graph_delay_ms: 300,
        max_conversation_pages: 9000,
        max_rate_limit_wait_seconds: 1800,
        max_download_bytes: 50.megabytes,
        pre_attempt_backup: backup,
        attempt_directory: attempt_directory
      )
    end
  end

  it 'rejects a history control and a non-child intent directory before loading evidence' do
    with_attempt_directories do |attempt_directory, _intent_directory|
      env = common_env(attempt_directory, '/tmp/not-the-attempt-intent-directory').merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'clone_evidence',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_fbig_clone',
        'UMI_FBIG_PROFILE_CLONE_PHASE' => 'dry',
        'DRY_RUN' => 'true',
        'PLATFORMS' => 'messenger,instagram',
        'SINCE' => 'all'
      )

      expect do
        described_class.build(env: env, actual_database: 'chatwoot_fbig_clone', expected_uid: Process.uid)
      end.to raise_error(described_class::ConfigurationError, /SINCE/)
    end
  end

  it 'requires the idempotency phase to load a preceding clone poststate' do
    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'clone_evidence',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_fbig_clone',
        'UMI_FBIG_PROFILE_CLONE_PHASE' => 'idempotency',
        'DRY_RUN' => 'false',
        'PLATFORMS' => 'messenger,instagram',
        'UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME' => 'chatwoot_production',
        'UMI_FBIG_PROFILE_GRAPH_DELAY_MS' => '250',
        'UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES' => '10000',
        'UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS' => '3600',
        'UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES' => '104857600',
        'UMI_FBIG_PROFILE_STATE_PATH' => '/evidence/fbig-profile-state-v1.tsv',
        'UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH' => '/evidence/fbig-profile-state-v1.tsv.sha256'
      )

      expect do
        described_class.build(env: env, actual_database: 'chatwoot_fbig_clone', expected_uid: Process.uid)
      end.to raise_error(described_class::ConfigurationError, /predecessor state is required/)
    end
  end

  it 'rejects clone evidence whose runtime release differs from the history approval' do
    allow(history).to receive(:repository_commit).and_return('f' * 40)

    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'clone_evidence',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_fbig_clone',
        'UMI_FBIG_PROFILE_CLONE_PHASE' => 'dry',
        'DRY_RUN' => 'true',
        'PLATFORMS' => 'messenger,instagram',
        'UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME' => 'chatwoot_production',
        'UMI_FBIG_PROFILE_GRAPH_DELAY_MS' => '250',
        'UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES' => '10000',
        'UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS' => '3600',
        'UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES' => '104857600',
        'UMI_FBIG_PROFILE_STATE_PATH' => '/evidence/fbig-profile-state-v1.tsv',
        'UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH' => '/evidence/fbig-profile-state-v1.tsv.sha256'
      )

      expect do
        described_class.build(env: env, actual_database: 'chatwoot_fbig_clone', expected_uid: Process.uid)
      end.to raise_error(described_class::ConfigurationError, /history approval release/)
    end
  end

  it 'rejects a production profile approval with a different clone database than history' do
    profile = instance_double(
      Umi::Fbig::ProfileApprovalManifest,
      history_manifest_sha256: history.sha256,
      clone_database_name: 'different_clone',
      production_database_name: 'chatwoot_production',
      repository_commit: commit,
      image_digest: image
    )
    allow(Umi::Fbig::ProfileApprovalManifest).to receive(:load).and_return(profile)

    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'production',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_production',
        'DRY_RUN' => 'false',
        'PLATFORMS' => 'messenger,instagram',
        'UMI_FBIG_PROFILE_APPROVAL_MANIFEST_PATH' => '/approval/fbig-profile-approval-v1.tsv',
        'UMI_FBIG_PROFILE_APPROVAL_CHECKSUM_PATH' => '/approval/fbig-profile-approval-v1.tsv.sha256'
      )

      expect do
        described_class.build(env: env, actual_database: 'chatwoot_production', expected_uid: Process.uid)
      end.to raise_error(described_class::ConfigurationError, /history approval release/)
    end
  end

  it 'requires the exact source and predecessor state artifact basenames' do
    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'clone_evidence',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_fbig_clone',
        'UMI_FBIG_PROFILE_CLONE_PHASE' => 'idempotency',
        'DRY_RUN' => 'false',
        'PLATFORMS' => 'messenger,instagram',
        'UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME' => 'chatwoot_production',
        'UMI_FBIG_PROFILE_GRAPH_DELAY_MS' => '250',
        'UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES' => '10000',
        'UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS' => '3600',
        'UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES' => '104857600',
        'UMI_FBIG_PROFILE_STATE_PATH' => '/evidence/fbig-profile-state-v1.tsv',
        'UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH' => '/evidence/fbig-profile-state-v1.tsv.sha256',
        'UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH' => '/evidence/fbig-profile-state-v1.tsv',
        'UMI_FBIG_PROFILE_PREDECESSOR_STATE_CHECKSUM_PATH' => '/evidence/fbig-profile-state-v1.tsv.sha256'
      )

      expect do
        described_class.build(env: env, actual_database: 'chatwoot_fbig_clone', expected_uid: Process.uid)
      end.to raise_error(described_class::ConfigurationError, /predecessor state artifact basename/)
    end
  end

  it 'rejects production predecessor approval paths before loading profile evidence' do
    with_attempt_directories do |attempt_directory, intent_directory|
      env = common_env(attempt_directory, intent_directory).merge(
        'UMI_FBIG_PROFILE_APPROVAL_MODE' => 'production',
        'UMI_FBIG_HISTORY_EXPECTED_DATABASE' => 'chatwoot_production',
        'DRY_RUN' => 'true',
        'PLATFORMS' => 'messenger',
        'UMI_FBIG_PROFILE_PREDECESSOR_MANIFEST_PATH' => '/unsupported/predecessor.tsv'
      )

      expect do
        described_class.build(env: env, actual_database: 'chatwoot_production', expected_uid: Process.uid)
      end.to raise_error(described_class::ConfigurationError, /PREDECESSOR_MANIFEST/)
    end
  end

  def common_env(attempt_directory, intent_directory)
    {
      'UMI_FBIG_APPROVAL_MANIFEST_PATH' => '/history/fbig-approval-v2.tsv',
      'UMI_FBIG_APPROVAL_CHECKSUM_PATH' => '/history/fbig-approval-v2.tsv.sha256',
      'UMI_FBIG_RUNTIME_REPOSITORY_COMMIT' => commit,
      'UMI_FBIG_RUNTIME_IMAGE_DIGEST' => image,
      'UMI_FBIG_PROFILE_TARGETS_PATH' => '/history/fbig-profile-targets-v1.tsv',
      'UMI_FBIG_PROFILE_ATTEMPT_DIR' => attempt_directory,
      'UMI_FBIG_PROFILE_AVATAR_INTENT_DIR' => intent_directory
    }
  end

  def with_attempt_directories
    Dir.mktmpdir do |attempt_directory|
      File.chmod(0o700, attempt_directory)
      intent_directory = Pathname.new(attempt_directory).join('avatar-intents')
      intent_directory.mkdir(0o700)
      yield attempt_directory, intent_directory.to_s
    end
  end
end
