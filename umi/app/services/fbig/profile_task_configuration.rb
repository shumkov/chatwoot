# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
class Umi::Fbig::ProfileTaskConfiguration
  Options = Data.define(
    :approval_mode,
    :clone_phase,
    :dry_run,
    :platforms,
    :actual_database,
    :production_database_name,
    :repository_commit,
    :image_digest,
    :graph_delay_ms,
    :max_conversation_pages,
    :max_rate_limit_wait_seconds,
    :max_download_bytes,
    :history_manifest,
    :profile_approval,
    :pre_attempt_backup,
    :seed_targets,
    :source_state,
    :predecessor_state,
    :attempt_directory,
    :avatar_intent_directory
  )

  class ConfigurationError < StandardError; end

  HISTORY_ONLY_ENV = %w[
    SINCE BEFORE OUTBOUND_POLICY PROFILE_MODE ACK_EXPAND_EXISTING UMI_FBIG_HISTORY_ACCEPTED_CONTENTLESS
  ].freeze
  PROFILE_SETTING_ENV = %w[
    UMI_FBIG_PROFILE_GRAPH_DELAY_MS UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES
    UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES
  ].freeze

  def self.build(env:, actual_database:, expected_uid: 0)
    mode = env['UMI_FBIG_PROFILE_APPROVAL_MODE']
    raise ConfigurationError, 'UMI_FBIG_PROFILE_APPROVAL_MODE must be clone_evidence or production' unless
      mode.in?(%w[clone_evidence production])

    expected_database = env['UMI_FBIG_HISTORY_EXPECTED_DATABASE']
    raise ConfigurationError, 'UMI_FBIG_HISTORY_EXPECTED_DATABASE is required' if expected_database.blank?
    raise ConfigurationError, 'database identity mismatch' unless expected_database == actual_database

    reject_present!(env, HISTORY_ONLY_ENV)
    dry_run = boolean!(env['DRY_RUN'], 'DRY_RUN')
    history = Umi::Fbig::HistoryApprovalManifest.load(
      manifest_path: env['UMI_FBIG_APPROVAL_MANIFEST_PATH'],
      checksum_path: env['UMI_FBIG_APPROVAL_CHECKSUM_PATH'],
      expected_uid: expected_uid
    )

    if mode == 'clone_evidence'
      clone_options(env, actual_database, dry_run, history, expected_uid)
    else
      production_options(env, actual_database, dry_run, history, expected_uid)
    end
  rescue Umi::Fbig::HistoryApprovalManifest::InvalidManifest,
         Umi::Fbig::ProfileApprovalManifest::InvalidManifest,
         Umi::Fbig::ProfileTargetManifest::InvalidManifest,
         Umi::Fbig::ProfileStateSnapshot::InvalidSnapshot,
         Umi::Fbig::ProfilePreAttemptBackupManifest::InvalidManifest,
         Umi::Fbig::AvatarIntentStore::InvalidStore
    raise ConfigurationError, 'profile approval artifact is invalid'
  end

  def self.validate_scope!(inbox, options)
    history = options.history_manifest
    valid = history.account_id == inbox.account_id &&
            history.inbox_id == inbox.id &&
            history.facebook_page_id.to_s == inbox.channel.page_id.to_s &&
            history.instagram_business_id.to_s == inbox.channel.instagram_id.to_s
    raise ConfigurationError, 'history approval scope does not match the inbox' unless valid

    if options.profile_approval
      profile = options.profile_approval
      valid_profile = profile.account_id == inbox.account_id &&
                      profile.inbox_id == inbox.id &&
                      profile.facebook_page_id.to_s == inbox.channel.page_id.to_s &&
                      profile.instagram_business_id.to_s == inbox.channel.instagram_id.to_s &&
                      profile.placeholder_targets_sha256 == history.placeholder_targets_sha256
      raise ConfigurationError, 'profile approval scope does not match the inbox' unless valid_profile

      backup = options.pre_attempt_backup
      valid_backup = backup.production_database_name == profile.production_database_name &&
                     backup.image_digest == profile.image_digest
      raise ConfigurationError, 'pre-attempt backup does not match profile approval' unless valid_backup
    end
    if options.source_state &&
       (options.source_state.account_id != inbox.account_id || options.source_state.inbox_id != inbox.id)
      raise ConfigurationError, 'source profile state does not match the inbox'
    end
    if options.predecessor_state &&
       (options.predecessor_state.account_id != inbox.account_id || options.predecessor_state.inbox_id != inbox.id)
      raise ConfigurationError, 'predecessor profile state does not match the inbox'
    end

    options.seed_targets.each do |row|
      contact_inbox = ContactInbox.find_by(id: row.contact_inbox_id)
      valid_target = contact_inbox&.inbox_id == inbox.id &&
                     contact_inbox.source_id.to_s == row.source_id &&
                     contact_inbox.contact&.account_id == inbox.account_id
      raise ConfigurationError, 'profile target mapping does not match the inbox' unless valid_target
    end
    if options.profile_approval
      history_configuration = {
        'since' => history.since,
        'before' => history.values.fetch('before'),
        'outbound_policy' => history.outbound_policy
      }
      observed = Umi::Fbig::HistoryProfileBackfillService.stable_target_summary(
        inbox,
        platforms: options.platforms,
        history_configuration: history_configuration,
        seed_targets: options.seed_targets
      )
      options.platforms.each do |platform|
        expected_count = options.profile_approval.public_send("#{platform}_stable_target_count")
        expected_fingerprint = options.profile_approval.public_send("#{platform}_stable_target_fingerprint")
        current = observed.fetch(platform)
        unless current[:count] == expected_count && current[:fingerprint] == expected_fingerprint
          raise ConfigurationError, 'stable profile target set does not match approval'
        end
      end
    end
    true
  end

  class << self
    private

    def clone_options(env, actual_database, dry_run, history, expected_uid)
      exact!(env, 'PLATFORMS', 'messenger,instagram')
      raise ConfigurationError, 'clone database does not match history approval' unless
        actual_database == history.clone_database_name

      production_database = env['UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME']
      validate_database_name!(production_database)
      raise ConfigurationError, 'clone and production databases must differ' if production_database == actual_database

      reject_present!(env, %w[
                        UMI_FBIG_PROFILE_APPROVAL_MANIFEST_PATH UMI_FBIG_PROFILE_APPROVAL_CHECKSUM_PATH
                        UMI_FBIG_PROFILE_PREDECESSOR_MANIFEST_PATH UMI_FBIG_PROFILE_PREDECESSOR_CHECKSUM_PATH
                        UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_PATH UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_CHECKSUM_PATH
                      ])
      settings = manual_settings!(env)
      validate_snapshot_paths!(
        env,
        path_name: 'UMI_FBIG_PROFILE_STATE_PATH',
        checksum_name: 'UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH',
        basename: 'fbig-profile-state-v1.tsv',
        label: 'source state'
      )
      source_state = Umi::Fbig::ProfileStateSnapshot.load(
        path: env['UMI_FBIG_PROFILE_STATE_PATH'],
        checksum_path: env['UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH'],
        expected_uid: expected_uid
      )
      clone_phase = clone_phase!(env, dry_run)
      predecessor_state = load_clone_predecessor_state(env, clone_phase, expected_uid)
      seeds = load_targets(env, history, expected_uid)
      attempt_directory, intent_directory = validate_attempt_directories!(env, expected_uid)
      repository_commit, image_digest = runtime_identity!(env)
      unless repository_commit == history.repository_commit && image_digest == history.image_digest
        raise ConfigurationError, 'runtime does not match the history approval release'
      end

      Options.new(
        approval_mode: 'clone_evidence',
        clone_phase: clone_phase,
        dry_run: dry_run,
        platforms: %w[messenger instagram],
        actual_database: actual_database,
        production_database_name: production_database,
        repository_commit: repository_commit,
        image_digest: image_digest,
        **settings,
        history_manifest: history,
        profile_approval: nil,
        pre_attempt_backup: nil,
        seed_targets: seeds,
        source_state: source_state,
        predecessor_state: predecessor_state,
        attempt_directory: attempt_directory,
        avatar_intent_directory: intent_directory
      )
    end

    def production_options(env, actual_database, dry_run, history, expected_uid)
      reject_present!(
        env,
        [
          *PROFILE_SETTING_ENV,
          'UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME',
          'UMI_FBIG_PROFILE_CLONE_PHASE',
          'UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH',
          'UMI_FBIG_PROFILE_PREDECESSOR_STATE_CHECKSUM_PATH',
          'UMI_FBIG_PROFILE_PREDECESSOR_MANIFEST_PATH',
          'UMI_FBIG_PROFILE_PREDECESSOR_CHECKSUM_PATH'
        ]
      )
      profile = Umi::Fbig::ProfileApprovalManifest.load(
        manifest_path: env['UMI_FBIG_PROFILE_APPROVAL_MANIFEST_PATH'],
        checksum_path: env['UMI_FBIG_PROFILE_APPROVAL_CHECKSUM_PATH'],
        expected_uid: expected_uid
      )
      raise ConfigurationError, 'profile approval does not bind the history approval' unless
        profile.history_manifest_sha256 == history.sha256
      unless profile.repository_commit == history.repository_commit &&
             profile.image_digest == history.image_digest &&
             profile.clone_database_name == history.clone_database_name
        raise ConfigurationError, 'profile does not match the history approval release'
      end
      raise ConfigurationError, 'production database does not match profile approval' unless
        actual_database == profile.production_database_name

      exact!(env, 'UMI_FBIG_RUNTIME_REPOSITORY_COMMIT', profile.repository_commit)
      exact!(env, 'UMI_FBIG_RUNTIME_IMAGE_DIGEST', profile.image_digest)
      platforms = canonical_platforms!(env['PLATFORMS'])
      raise ConfigurationError, 'profile apply requires all approved platforms' if !dry_run && platforms != profile.platforms

      seeds = platforms.include?('instagram') ? load_targets(env, history, expected_uid) : reject_instagram_target!(env)
      backup = Umi::Fbig::ProfilePreAttemptBackupManifest.load(
        manifest_path: env['UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_PATH'],
        checksum_path: env['UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_CHECKSUM_PATH'],
        expected_uid: expected_uid
      )
      attempt_directory, intent_directory = validate_attempt_directories!(env, expected_uid)
      Options.new(
        approval_mode: 'production',
        clone_phase: nil,
        dry_run: dry_run,
        platforms: platforms,
        actual_database: actual_database,
        production_database_name: profile.production_database_name,
        repository_commit: profile.repository_commit,
        image_digest: profile.image_digest,
        graph_delay_ms: profile.graph_delay_ms,
        max_conversation_pages: profile.max_conversation_pages,
        max_rate_limit_wait_seconds: profile.max_rate_limit_wait_seconds,
        max_download_bytes: profile.max_avatar_download_bytes,
        history_manifest: history,
        profile_approval: profile,
        pre_attempt_backup: backup,
        seed_targets: seeds,
        source_state: nil,
        predecessor_state: nil,
        attempt_directory: attempt_directory,
        avatar_intent_directory: intent_directory
      )
    end

    def manual_settings!(env)
      {
        graph_delay_ms: positive_integer!(env['UMI_FBIG_PROFILE_GRAPH_DELAY_MS'], 'UMI_FBIG_PROFILE_GRAPH_DELAY_MS'),
        max_conversation_pages: positive_integer!(
          env['UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES'],
          'UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES'
        ),
        max_rate_limit_wait_seconds: positive_integer!(
          env['UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS'],
          'UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS'
        ),
        max_download_bytes: positive_integer!(
          env['UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES'],
          'UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES'
        )
      }
    end

    def load_targets(env, history, expected_uid)
      Umi::Fbig::ProfileTargetManifest.load(
        path: env['UMI_FBIG_PROFILE_TARGETS_PATH'],
        expected_sha256: history.placeholder_targets_sha256,
        expected_uid: expected_uid
      )
    end

    def reject_instagram_target!(env)
      raise ConfigurationError, 'Instagram target path is not allowed for Messenger-only projection' if
        env['UMI_FBIG_PROFILE_TARGETS_PATH'].present?

      []
    end

    def validate_attempt_directories!(env, expected_uid)
      attempt_directory = Pathname.new(env['UMI_FBIG_PROFILE_ATTEMPT_DIR'].to_s)
      intent_directory = Pathname.new(env['UMI_FBIG_PROFILE_AVATAR_INTENT_DIR'].to_s)
      raise ConfigurationError unless attempt_directory.absolute? &&
                                      attempt_directory.cleanpath == attempt_directory &&
                                      intent_directory == attempt_directory.join('avatar-intents')

      stat = File.lstat(attempt_directory)
      raise ConfigurationError unless stat.directory? &&
                                      !stat.symlink? &&
                                      stat.uid == expected_uid &&
                                      (stat.mode & 0o777) == 0o700

      Umi::Fbig::AvatarIntentStore.new(
        directory: intent_directory,
        expected_uid: expected_uid
      )
      [attempt_directory.to_s, intent_directory.to_s]
    rescue SystemCallError
      raise ConfigurationError, 'profile attempt directory is invalid'
    end

    def runtime_identity!(env)
      commit = env['UMI_FBIG_RUNTIME_REPOSITORY_COMMIT']
      image = env['UMI_FBIG_RUNTIME_IMAGE_DIGEST']
      raise ConfigurationError unless commit.to_s.match?(/\A[0-9a-f]{40}\z/)
      raise ConfigurationError unless image.to_s.match?(
        %r{\Aghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}\z}
      )

      [commit, image]
    end

    def clone_phase!(env, dry_run)
      phase = env['UMI_FBIG_PROFILE_CLONE_PHASE']
      raise ConfigurationError, 'invalid clone profile phase' unless phase.in?(%w[dry apply idempotency])
      raise ConfigurationError, 'clone dry phase requires DRY_RUN=true' if phase == 'dry' && !dry_run
      raise ConfigurationError, 'clone apply phases require DRY_RUN=false' if phase != 'dry' && dry_run

      phase
    end

    def load_clone_predecessor_state(env, phase, expected_uid)
      names = %w[
        UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH
        UMI_FBIG_PROFILE_PREDECESSOR_STATE_CHECKSUM_PATH
      ]
      if phase != 'idempotency'
        reject_present!(env, names)
        return
      end
      raise ConfigurationError, 'clone idempotency predecessor state is required' if
        names.any? { |name| env[name].blank? }

      validate_snapshot_paths!(
        env,
        path_name: names.first,
        checksum_name: names.last,
        basename: 'fbig-profile-clone-poststate-v1.tsv',
        label: 'predecessor state'
      )
      Umi::Fbig::ProfileStateSnapshot.load(
        path: env['UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH'],
        checksum_path: env['UMI_FBIG_PROFILE_PREDECESSOR_STATE_CHECKSUM_PATH'],
        expected_uid: expected_uid
      )
    end

    def validate_snapshot_paths!(env, path_name:, checksum_name:, basename:, label:)
      path = env[path_name].to_s
      checksum = env[checksum_name].to_s
      valid = File.basename(path) == basename &&
              File.basename(checksum) == "#{basename}.sha256"
      raise ConfigurationError, "#{label} artifact basename is invalid" unless valid
    end

    def canonical_platforms!(value)
      result = {
        'messenger' => ['messenger'],
        'instagram' => ['instagram'],
        'messenger,instagram' => %w[messenger instagram]
      }[value]
      raise ConfigurationError, 'invalid profile platform projection' unless result

      result
    end

    def boolean!(value, name)
      return true if value == 'true'
      return false if value == 'false'

      raise ConfigurationError, "#{name} must be true or false"
    end

    def positive_integer!(value, name)
      parsed = Integer(value, 10)
      raise ArgumentError unless parsed.positive?

      parsed
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{name} must be a positive integer"
    end

    def validate_database_name!(value)
      raise ConfigurationError unless value.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
    end

    def exact!(env, name, expected)
      raise ConfigurationError, "#{name} must be #{expected}" unless env[name] == expected
    end

    def reject_present!(env, names)
      supplied = names.find { |name| env[name].present? }
      raise ConfigurationError, "#{supplied} is not allowed" if supplied
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity
