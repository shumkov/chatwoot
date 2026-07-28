# frozen_string_literal: true

require 'digest'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations
RSpec.describe 'UMI FB/IG production program builder' do
  let(:repository_root) { File.expand_path('../../..', __dir__) }
  let(:builder) { File.join(repository_root, 'script/umi_fbig/build_programs.rb') }

  it 'builds protected standalone phase programs with exact checksums' do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = Open3.capture3('ruby', builder, directory)

      expect(status).to be_success, stderr
      expect(stdout.lines.map(&:chomp)).to eq(
        %w[
          acceptance acceptance_control delivery_audit delivery_checkpoint
          final_audit history_attempt profile_attempt profile_wrapper
          storage_artifact
        ]
      )
      %w[
        acceptance acceptance-control delivery-audit delivery-checkpoint
        final-audit history-attempt profile-attempt profile-wrapper
      ].each do |name|
        program = File.join(directory, "fbig-#{name}.sh")
        checksum = "#{program}.sha256"
        bytes = File.binread(program)
        expect(bytes).to start_with("#!/usr/bin/env bash\nset -Eeuo pipefail\n")
        expect(bytes).not_to include("\nsource ")
        expect(File.stat(program).mode & 0o777).to eq(0o400)
        expect(File.stat(checksum).mode & 0o777).to eq(0o400)
        expect(File.binread(checksum)).to eq(
          "#{Digest::SHA256.hexdigest(bytes)}  #{File.basename(program)}\n"
        )
        _syntax_stdout, syntax_stderr, syntax_status = Open3.capture3('bash', '-n', program)
        expect(syntax_status).to be_success, syntax_stderr
      end

      helper = File.join(directory, 'fbig-storage-artifact.py')
      helper_checksum = "#{helper}.sha256"
      helper_bytes = File.binread(helper)
      expect(helper_bytes).to start_with('#!/usr/bin/env python3')
      expect(File.stat(helper).mode & 0o777).to eq(0o400)
      expect(File.stat(helper_checksum).mode & 0o777).to eq(0o400)
      expect(File.binread(helper_checksum)).to eq(
        "#{Digest::SHA256.hexdigest(helper_bytes)}  #{File.basename(helper)}\n"
      )
      source = 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")'
      _syntax_stdout, syntax_stderr, syntax_status = Open3.capture3(
        'python3', '-c', source, helper
      )
      expect(syntax_status).to be_success, syntax_stderr
    end
  end

  it 'emits PostgreSQL restrict keys containing only alphanumeric characters' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      acceptance = File.binread(File.join(directory, 'fbig-acceptance.sh'))
      restrict_keys = acceptance.scan(/--restrict-key=([^\s|]+)/).flatten

      expect(restrict_keys).not_to be_empty
      expect(restrict_keys).to all(match(/\A[[:alnum:]]+\z/))
    end
  end

  it 'publishes the exact reviewed profile maintenance wrapper' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      generated = File.join(directory, 'fbig-profile-wrapper.sh')
      source = File.join(repository_root, 'script/umi_fbig/support/fbig_profile_attempt.sh')
      expect(File.binread(generated)).to eq(File.binread(source))
      expect(Digest::SHA256.file(generated).hexdigest).to eq(
        'ad5315b4385fddbe3def69828195f7b52068a3584ab59124d8d21ba9760911e7'
      )
    end
  end

  it 'proves the approved commit in running profile services and the mutating one-off' do
    wrapper = File.binread(File.join(repository_root, 'script/umi_fbig/support/fbig_profile_attempt.sh'))
    running_release = wrapper.match(/verify_running_release\(\) \{(?<body>.*?)^\}/m)[:body]
    profile_task = wrapper.match(/run_profile_task\(\) \{(?<body>.*?)^\}/m)[:body]

    expect(running_release).to include(
      'compose exec -T "$service"',
      '/app/.git_sha',
      '[[ "$commit" = "$APPROVED_REPOSITORY_COMMIT" ]] || return 1'
    )
    expect(profile_task).to include(
      '--env UMI_FBIG_RUNTIME_REPOSITORY_COMMIT="$APPROVED_REPOSITORY_COMMIT"',
      '/app/.git_sha',
      'exec bundle exec rake "$1"',
      '"umi:fbig:history_profiles[${INBOX_ID}]"'
    )
  end

  it 'rejects a symlinked output directory without changing its target' do
    Dir.mktmpdir do |directory|
      target = File.join(directory, 'target')
      output = File.join(directory, 'output')
      Dir.mkdir(target, 0o755)
      File.symlink(target, output)

      _stdout, _stderr, status = Open3.capture3('ruby', builder, output)

      expect(status).not_to be_success
      expect(File.stat(target).mode & 0o777).to eq(0o755)
    end
  end

  it 'publishes the exact reviewed storage artifact helper' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      generated = File.join(directory, 'fbig-storage-artifact.py')
      source = File.join(repository_root, 'script/umi_fbig/support/fbig_storage_artifact.py')
      expect(File.binread(generated)).to eq(File.binread(source))
      expect(Digest::SHA256.file(generated).hexdigest).to eq(
        'c5958f7aceca8833e2429a39005de928ffa041bd3e6cb71fa30009f13ebb6890'
      )
    end
  end

  it 'builds a final audit with concrete platform, profile, omission, and placeholder totals' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr
      bytes = File.binread(File.join(directory, 'fbig-final-audit.sh'))

      expect(bytes).to include(
        'fbig-production-platform-counts-v1.tsv',
        'messenger_conversation_pages_scanned',
        'instagram_conversation_pages_scanned',
        'messenger_contacts_created',
        'instagram_contacts_created',
        'profile_name_changes_applied',
        'profile_avatars_attached',
        'seed_only_targets',
        'importer_only_targets',
        'seed_and_importer_targets',
        'instagram_placeholders_remaining',
        'empty_importer_archives',
        'unrecoverable_instagram_envelopes',
        'profile_mutations_are_aggregate'
      )
      expect(bytes).to include(
        'test "$(manifest_value "$result" counter_mismatches)" = none',
        'history_state_content_sha256',
        '$1 == "contact" || $1 == "contact_inbox" { next }',
        'terminal_summary="$(dirname "$terminal_result")/history-summary.tsv"',
        'attachments_unavailable=$((attachment_urls_found - attachments_created))'
      )
    end
  end

  it 'requires every delivery checkpoint to match the exact candidate release' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      checkpoint = File.binread(File.join(directory, 'fbig-delivery-checkpoint.sh'))
      final_audit = File.binread(File.join(directory, 'fbig-final-audit.sh'))
      expect([checkpoint, final_audit]).to all(
        include(
          'running_rails_commit',
          'running_sidekiq_commit',
          'running_rails_service_source_sha256',
          'CANDIDATE_COMMIT'
        )
      )
      expect(checkpoint).to include('SERVICE_SOURCE_SHA256')
      expect(final_audit).to include('service_source_sha256')
      expect(checkpoint).to include('CANDIDATE_IMAGE')
      expect(final_audit).to include('candidate_image_matches_container')
    end
  end

  it 'reconciles durable attachment intents around every history mutation window' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      history = File.binread(File.join(directory, 'fbig-history-attempt.sh'))
      final_audit = File.binread(File.join(directory, 'fbig-final-audit.sh'))
      expect(history).to include(
        'umi:fbig:history_attachment_reconcile',
        'attachment_reconcile_start_sha256',
        'attachment_reconcile_final_sha256',
        "attachment_reconcile \"$ATTACHMENT_RECONCILE_START\" start\n  state_capture"
      )
      expect(final_audit).to include(
        'history_attachment_intents',
        'attachment-reconcile-start.log',
        'attachment-reconcile-final.log'
      )
    end
  end

  it 'binds acceptance launch intent before starting a fresh unit invocation' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      bytes = File.binread(File.join(directory, 'fbig-acceptance-control.sh'))
      intent_offset = bytes.index('fbig-acceptance-start-intent-v1.tsv')
      start_offset = bytes.index('systemctl start')
      expect(intent_offset).not_to be_nil
      expect(start_offset).not_to be_nil
      expect(intent_offset).to be < start_offset
      expect(bytes).to include('start_intent_sha256')
    end
  end

  it 'refuses to restart an inactive acceptance after intent publication' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      bytes = File.binread(File.join(directory, 'fbig-acceptance-control.sh'))
      expect(bytes).to include(
        'local start_intent_created=false',
        'start_intent_created=true',
        '[[ "$start_intent_created" = true ]] ||',
        'inactive acceptance with existing start intent cannot be restarted'
      )
    end
  end

  it 'refuses explicit acceptance restarts and binds same-host proof' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      bytes = File.binread(File.join(directory, 'fbig-acceptance-control.sh'))
      expect(bytes).to include(
        "printf 'RefuseManualStop=yes\\n\\n'",
        "grep -Fxq 'RefuseManualStop=yes'",
        'refuse_manual_stop="$(unit_property RefuseManualStop)"',
        "printf 'refuse_manual_stop\\tyes\\n'",
        'fbig-acceptance-restart-guard-probe-v1.tsv',
        'systemd-run',
        'systemctl restart "$RESTART_GUARD_UNIT"',
        'test "$restart_status" -ne 0',
        'restart_guard_probe_sha256'
      )
    end
  end

  it 'validates every root acceptance path before filesystem or Docker mutation' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      acceptance = File.binread(File.join(directory, 'fbig-acceptance.sh'))
      control = File.binread(File.join(directory, 'fbig-acceptance-control.sh'))
      expect(acceptance).to include(
        'require_trusted_directory "$STACK_DIR"',
        'require_root_readonly_file "$STACK_DIR/docker-compose.yml"',
        'require_trusted_directory "$BACKUP_DIR"',
        'require_root_artifact "$BACKUP_DIR/$backup_artifact"',
        'require_trusted_directory "$PRODUCTION_STORAGE"',
        'require_new_root_directory_path "$AUDIT_DIR"',
        'require_new_root_directory_path "$CLONE_ROOT"',
        'mkdir -m 0700 -- "$AUDIT_DIR"',
        'mkdir -m 0700 -- "$CLONE_ROOT"'
      )
      expect(control).to include(
        'require_trusted_directory "$STACK_DIR"',
        'require_root_readonly_file "$STACK_DIR/docker-compose.yml"',
        'require_trusted_directory "$BACKUP_DIR"',
        'require_trusted_directory "$PRODUCTION_STORAGE"',
        'require_new_root_directory_path "$AUDIT_DIR"',
        'require_new_root_directory_path "$CLONE_ROOT"'
      )
    end
  end

  # rubocop:disable RSpec/ExampleLength
  it 'rejects an existing clone root before invoking Docker' do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      output = File.join(directory, 'programs')
      stack = File.join(directory, 'stack')
      backup = File.join(directory, 'backup')
      production_storage = File.join(directory, 'production-storage')
      audit_root = File.join(directory, 'audits')
      clone_parent = File.join(directory, 'clones')
      acceptance_id = 'acceptance-test'
      audit = File.join(audit_root, acceptance_id)
      clone_root = File.join(clone_parent, acceptance_id)
      clone_storage = File.join(clone_root, 'storage')
      [output, stack, backup, production_storage, audit_root, clone_parent, clone_root].each do |path|
        Dir.mkdir(path)
      end
      File.binwrite(File.join(stack, 'docker-compose.yml'), "services: {}\n")
      %w[database.dump storage.tar storage.manifest].each do |artifact|
        File.binwrite(File.join(backup, artifact), "#{artifact}\n")
      end
      backup_manifest = File.join(backup, 'fbig-coordinated-backup-v1.tsv')
      File.binwrite(backup_manifest, "schema_version\t1\n")
      File.binwrite(
        "#{backup_manifest}.sha256",
        "#{Digest::SHA256.file(backup_manifest).hexdigest}  #{File.basename(backup_manifest)}\n"
      )

      _stdout, stderr, status = Open3.capture3('ruby', builder, output)
      expect(status).to be_success, stderr
      helper = File.join(output, 'fbig-storage-artifact.py')
      binding = File.join(output, 'acceptance-binding.tsv')
      rows = {
        schema_version: 1,
        acceptance_id: acceptance_id,
        inbox_id: 2,
        production_database: 'chatwoot_production',
        clone_database: 'chatwoot_acceptance',
        candidate_commit: 'a' * 40,
        candidate_image: "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
        approved_by: 'test',
        stack_dir: stack,
        audit_dir: audit,
        clone_storage: clone_storage,
        production_storage: production_storage,
        backup_dir: backup,
        history_cutoff: '2025-01-01T00:00:00Z',
        expected_instagram_unrecoverable_threads: 0,
        profile_graph_delay_ms: 250,
        profile_max_conversation_pages: 10_000,
        profile_max_rate_limit_wait_seconds: 600,
        profile_max_download_bytes: 1_000_000,
        history_max_download_bytes: 1_000_000,
        storage_helper: helper,
        storage_helper_sha256: Digest::SHA256.file(helper).hexdigest,
        ops_dir: File.join(directory, 'ops'),
        acceptance_unit: 'umi-fbig-acceptance.service',
        unit_fragment_path: File.join(directory, 'unit-fragment'),
        acceptance_finalizer_lock: File.join(directory, 'finalizer.lock')
      }
      File.binwrite(binding, rows.map { |key, value| "#{key}\t#{value}\n" }.join)
      File.binwrite(
        "#{binding}.sha256",
        "#{Digest::SHA256.file(binding).hexdigest}  #{File.basename(binding)}\n"
      )

      tools = File.join(directory, 'tools')
      Dir.mkdir(tools)
      mutation_log = File.join(directory, 'docker.log')
      File.binwrite(
        File.join(tools, 'stat'),
        <<~SH
          #!/usr/bin/env bash
          case "$2" in
            %u:%g:%a:%h) printf '0:0:400:1\n' ;;
            %u:%g:%a) printf '0:0:700\n' ;;
            %u:%g) printf '0:0\n' ;;
            %a) printf '700\n' ;;
            *) exec /usr/bin/stat "$@" ;;
          esac
        SH
      )
      File.binwrite(File.join(tools, 'id'), "#!/usr/bin/env bash\nprintf '0\\n'\n")
      File.binwrite(
        File.join(tools, 'docker'),
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >>\"$UMI_FBIG_MUTATION_LOG\"\nexit 99\n"
      )
      %w[stat id docker].each { |command| File.chmod(0o700, File.join(tools, command)) }
      environment = {
        'PATH' => "#{tools}:#{ENV.fetch('PATH')}",
        'UMI_FBIG_MUTATION_LOG' => mutation_log
      }
      program = File.join(output, 'fbig-acceptance.sh')
      bash_wrapper = <<~'SH'
        mapfile() {
          test "$1" = -t
          local name="$2"
          local line
          local index=0
          while IFS= read -r line; do
            eval "$name[$index]=\"\$line\""
            index=$((index + 1))
          done
        }
        export -f mapfile
        exec bash "$@"
      SH

      _run_stdout, run_stderr, run_status = Open3.capture3(
        environment, 'bash', '-c', bash_wrapper, 'bash', program, binding
      )

      expect(run_status).not_to be_success
      expect(run_stderr).to include('new directory path is not absolute or already exists')
      expect(File).not_to exist(mutation_log)
    end
  end
  # rubocop:enable RSpec/ExampleLength

  it 'rejects unsafe existing and not-yet-created root paths' do
    common = File.join(repository_root, 'script/umi_fbig/programs/common.sh')
    command = 'source "$1"; "$2" "$3"'
    Dir.mktmpdir do |tool_directory|
      File.binwrite(
        File.join(tool_directory, 'stat'),
        <<~'SH'
          #!/usr/bin/env bash
          case "$2" in
            %u:%g) printf '0:0\n' ;;
            %a)
              if [[ "$3" = "$UMI_FBIG_UNSAFE_PATH" ]]; then
                printf '777\n'
              else
                printf '700\n'
              fi
              ;;
            *) exec /usr/bin/stat "$@" ;;
          esac
        SH
      )
      File.chmod(0o700, File.join(tool_directory, 'stat'))
      environment = { 'PATH' => "#{tool_directory}:#{ENV.fetch('PATH')}" }

      Dir.mktmpdir do |writable_directory|
        writable_directory = File.realpath(writable_directory)
        File.chmod(0o777, writable_directory)
        _stdout, writable_stderr, writable_status = Open3.capture3(
          environment.merge('UMI_FBIG_UNSAFE_PATH' => writable_directory),
          'bash', '-c', command, 'bash', common, 'require_trusted_directory', writable_directory
        )
        expect(writable_status).not_to be_success
        expect(writable_stderr).to include('must not be group/world writable')
      end

      Dir.mktmpdir do |directory|
        target = File.join(directory, 'target')
        link = File.join(directory, 'link')
        Dir.mkdir(target)
        File.symlink(target, link)
        unsafe_child = File.join(link, 'acceptance')

        _stdout, link_stderr, link_status = Open3.capture3(
          environment, 'bash', '-c', command, 'bash', common, 'require_new_root_directory_path', unsafe_child
        )
        expect(link_status).not_to be_success
        expect(link_stderr).to include('path is not canonical and link-free')
      end
    end
  end

  # rubocop:disable RSpec/ExampleLength
  it 'executes the generated history gate and rejects apply before any Docker call without a dry pair' do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      output = File.join(directory, 'programs')
      Dir.mkdir(output)
      _stdout, stderr, status = Open3.capture3('ruby', builder, output)
      expect(status).to be_success, stderr

      binding = File.join(output, 'history-binding.tsv')
      rows = {
        schema_version: 1,
        label: 'messenger-apply',
        operation: 'apply',
        platforms: 'messenger',
        require_zero_writes: 'false',
        candidate_commit: 'a' * 40,
        candidate_image: "ghcr.io/shumkov/chatwoot@sha256:#{'b' * 64}",
        stack_dir: '/protected/stack',
        compose_file: '/protected/stack/docker-compose.yml',
        compose_file_sha256: 'c' * 64,
        compose_project: 'umi-chatwoot',
        rails_service: 'rails',
        sidekiq_service: 'sidekiq',
        production_database: 'chatwoot_production',
        audit_root: '/protected/audit',
        inbox_id: 2,
        history_approval: '/protected/history/fbig-approval-v1.tsv',
        history_approval_checksum: '/protected/history/fbig-approval-v1.tsv.sha256',
        history_approval_sha256: 'd' * 64,
        acceptance_manifest: '/protected/acceptance/fbig-acceptance-complete-v1.tsv',
        acceptance_checksum: '/protected/acceptance/fbig-acceptance-complete-v1.tsv.sha256',
        acceptance_sha256: 'e' * 64,
        pre_history_backup_manifest: '/protected/backup/fbig-coordinated-backup-v1.tsv',
        pre_history_backup_checksum: '/protected/backup/fbig-coordinated-backup-v1.tsv.sha256',
        pre_history_backup_sha256: 'f' * 64,
        max_download_bytes: 1_000_000,
        ack_single_conversation_reopen: 'true',
        graph_delay_ms: 250,
        max_conversation_pages: 10_000,
        max_message_pages: 10_000,
        dry_result_1: 'none',
        dry_result_1_checksum: 'none',
        dry_result_2: 'none',
        dry_result_2_checksum: 'none',
        predecessor_result: 'none',
        predecessor_checksum: 'none',
        production_lock: '/protected/locks/fbig.lock'
      }
      File.binwrite(binding, rows.map { |key, value| "#{key}\t#{value}\n" }.join)
      File.binwrite(
        "#{binding}.sha256",
        "#{Digest::SHA256.file(binding).hexdigest}  #{File.basename(binding)}\n"
      )
      File.chmod(0o400, binding)
      File.chmod(0o400, "#{binding}.sha256")

      tools = File.join(directory, 'tools')
      Dir.mkdir(tools)
      mutation_log = File.join(directory, 'docker.log')
      File.binwrite(
        File.join(tools, 'stat'),
        <<~SH
          #!/usr/bin/env bash
          case "$2" in
            %u:%g:%a:%h) printf '0:0:400:1\n' ;;
            %u:%g) printf '0:0\n' ;;
            %a) printf '700\n' ;;
            *) exec /usr/bin/stat "$@" ;;
          esac
        SH
      )
      File.binwrite(
        File.join(tools, 'docker'),
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >>\"$UMI_FBIG_MUTATION_LOG\"\nexit 99\n"
      )
      File.chmod(0o700, File.join(tools, 'stat'))
      File.chmod(0o700, File.join(tools, 'docker'))
      environment = {
        'PATH' => "#{tools}:#{ENV.fetch('PATH')}",
        'UMI_FBIG_MUTATION_LOG' => mutation_log
      }
      program = File.join(output, 'fbig-history-attempt.sh')
      bash_wrapper = <<~'SH'
        mapfile() {
          test "$1" = -t
          local name="$2"
          local line
          local index=0
          while IFS= read -r line; do
            eval "$name[$index]=\"\$line\""
            index=$((index + 1))
          done
        }
        export -f mapfile
        exec bash "$@"
      SH

      _run_stdout, run_stderr, run_status = Open3.capture3(
        environment, 'bash', '-c', bash_wrapper, 'bash', program, 'start', binding
      )

      expect(run_status).not_to be_success
      expect(run_stderr).to include('apply attempts require two distinct dry results')
      expect(File).not_to exist(mutation_log)
    end
  end
  # rubocop:enable RSpec/ExampleLength

  it 'builds a delivery audit that contains each maintenance attempt in the checkpoint chain' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr
      bytes = File.binread(File.join(directory, 'fbig-delivery-audit.sh'))

      expect(bytes).to include(
        'fbig-profile-delivery-audit-v1.tsv',
        'before_checkpoint_sha256',
        'after_checkpoint_sha256',
        'attempt_started_at',
        'attempt_finished_at',
        'effective_window_start',
        'grace_end',
        'predecessor_manifest_sha256',
        'zero_unrecovered_deliveries'
      )
    end
  end

  it 'builds a crash-adoptable profile attempt around the protected maintenance wrapper' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr
      bytes = File.binread(File.join(directory, 'fbig-profile-attempt.sh'))

      expect(bytes).to include(
        'start|finalize',
        'profile_wrapper_sha256',
        'storage_helper_sha256',
        'fbig-profile-attempt-identity-v1.tsv',
        'fbig-profile-attempt-result-v1.tsv',
        'fbig-profile-production-attempt-v1.tsv',
        'predecessor_audit_sha256',
        'before_checkpoint_sha256',
        'zero_write_observed',
        'adopted_after_wrapper_exit'
      )
    end
  end

  it 'builds a protected acceptance launcher and resumable terminal finalizer' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr
      bytes = File.binread(File.join(directory, 'fbig-acceptance-control.sh'))

      expect(bytes).to include(
        'launch|finalize',
        'unit_fragment_sha256',
        'prelaunch_descriptor_sha256',
        'postlaunch_descriptor_sha256',
        'messenger_history_terminal_summary_sha256',
        'instagram_history_terminal_summary_sha256',
        'artifact_index_sha256',
        'InvocationID',
        'DropInPaths',
        'publish_artifact',
        'acquire_descriptor_verified_lock'
      )
    end
  end

  it 'builds a crash-adoptable history program around sealed Rails graph evidence' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr
      bytes = File.binread(File.join(directory, 'fbig-history-attempt.sh'))

      expect(bytes).to include(
        'umi:fbig:history_state',
        'umi:fbig:history_state_compare',
        'fbig-history-attempt-identity-v1.tsv',
        'fbig-history-attempt-result-v1.tsv',
        'candidate-compose.yml',
        'compose_override_sha256',
        '--file "$OVERRIDE_FILE"',
        'configuration["services"][service]["image"] != expected',
        '.in-progress',
        'predecessor_result_sha256',
        'dry_result_1',
        'dry_result_2',
        'dry_pair_sha256',
        'validate_authorizing_dry_result',
        'authorizing dry summaries differ',
        'apply attempts require a predecessor result',
        'adopted_interrupted_attempt',
        'zero_write_observed',
        'require_ordered_manifest "$ACCEPTANCE_MANIFEST" "${ACCEPTANCE_FIELDS[@]}"'
      )
      final_audit = File.binread(File.join(directory, 'fbig-final-audit.sh'))
      expect(final_audit).to include(
        'MESSENGER_DRY_PAIR_SHA',
        'INSTAGRAM_DRY_PAIR_SHA',
        'test "$(manifest_value "$result" dry_pair_sha256)" = none'
      )
    end
  end

  it 'refuses to overwrite an existing program set' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      _second_stdout, second_stderr, second_status = Open3.capture3('ruby', builder, directory)

      expect(second_status).not_to be_success
      expect(second_stderr).to include('program already exists')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
