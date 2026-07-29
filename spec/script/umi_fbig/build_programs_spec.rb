# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
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
          storage_artifact recovered_thread_targets production_first_request
          production_first_binding production_first_authorize
          production_first_history_revise production_first_profile_approve
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

      recovered = File.join(directory, 'fbig-recovered-thread-targets.rb')
      recovered_checksum = "#{recovered}.sha256"
      recovered_bytes = File.binread(recovered)
      expect(File.stat(recovered).mode & 0o777).to eq(0o400)
      expect(File.binread(recovered_checksum)).to eq(
        "#{Digest::SHA256.hexdigest(recovered_bytes)}  #{File.basename(recovered)}\n"
      )
      _ruby_stdout, ruby_stderr, ruby_status = Open3.capture3('ruby', '-c', recovered)
      expect(ruby_status).to be_success, ruby_stderr

      authorize = File.join(directory, 'fbig-production-first-authorize.rb')
      authorize_checksum = "#{authorize}.sha256"
      authorize_bytes = File.binread(authorize)
      expect(File.stat(authorize).mode & 0o777).to eq(0o400)
      expect(File.binread(authorize_checksum)).to eq(
        "#{Digest::SHA256.hexdigest(authorize_bytes)}  #{File.basename(authorize)}\n"
      )
      _ruby_stdout, ruby_stderr, ruby_status = Open3.capture3('ruby', '-c', authorize)
      expect(ruby_status).to be_success, ruby_stderr

      history_revise = File.join(directory, 'fbig-production-first-history-revise.rb')
      history_revise_checksum = "#{history_revise}.sha256"
      history_revise_bytes = File.binread(history_revise)
      expect(File.stat(history_revise).mode & 0o777).to eq(0o400)
      expect(File.binread(history_revise_checksum)).to eq(
        "#{Digest::SHA256.hexdigest(history_revise_bytes)}  #{File.basename(history_revise)}\n"
      )
      _ruby_stdout, ruby_stderr, ruby_status = Open3.capture3('ruby', '-c', history_revise)
      expect(ruby_status).to be_success, ruby_stderr

      profile_approve = File.join(directory, 'fbig-production-first-profile-approve.rb')
      profile_approve_checksum = "#{profile_approve}.sha256"
      profile_approve_bytes = File.binread(profile_approve)
      expect(File.stat(profile_approve).mode & 0o777).to eq(0o400)
      expect(File.binread(profile_approve_checksum)).to eq(
        "#{Digest::SHA256.hexdigest(profile_approve_bytes)}  #{File.basename(profile_approve)}\n"
      )
      expect(profile_approve_bytes).to include(
        'database.dump',
        'database.restore.list',
        'storage.tar',
        'storage.manifest'
      )
      _ruby_stdout, ruby_stderr, ruby_status = Open3.capture3('ruby', '-c', profile_approve)
      expect(ruby_status).to be_success, ruby_stderr
    end
  end

  it 'enforces every production-first authorization-bound host program' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      profile = File.binread(File.join(directory, 'fbig-profile-attempt.sh'))
      profile_wrapper = File.binread(File.join(directory, 'fbig-profile-wrapper.sh'))
      final_audit = File.binread(File.join(directory, 'fbig-final-audit.sh'))
      delivery_audit = File.binread(File.join(directory, 'fbig-delivery-audit.sh'))
      delivery_checkpoint = File.binread(File.join(directory, 'fbig-delivery-checkpoint.sh'))
      expect(profile).to include(
        'profile_program_sha256',
        'profile_wrapper_sha256',
        'storage_helper_sha256',
        'production-first authorization does not bind this profile program'
      )
      expect(profile).to include(
        'FBIG_PROFILE_AUDIT_ROOT="$AUDIT_ROOT"',
        'FBIG_PROFILE_PREDECESSOR_RESULT="$PREDECESSOR_RESULT"',
        'FBIG_PROFILE_PREDECESSOR_AUDIT="$PREDECESSOR_AUDIT"'
      )
      expect(profile_wrapper).to include(
        'validate_profile_predecessor_chain',
        'attempt_result_sha256',
        'zero_unrecovered_deliveries',
        'production-first profile chain has multiple heads',
        'UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH'
      )
      expect(profile_wrapper).to include(
        "acquire_operation_lock\nvalidate_profile_predecessor_chain\nreadonly PROFILE_PREDECESSOR_STATE_PATH"
      )
      expect(final_audit).to include(
        'final_audit_program_sha256',
        'profile_wrapper_sha256',
        'storage_helper_sha256'
      )
      expect(delivery_audit).to include(
        'authorization_manifest',
        'delivery_audit_program_sha256'
      )
      expect(delivery_checkpoint).to include(
        'authorization_manifest',
        'delivery_checkpoint_program_sha256'
      )
    end
  end

  it 'removes every fixed-six placeholder gate from the generated acceptance program' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr
      acceptance = File.binread(File.join(directory, 'fbig-acceptance.sh'))

      expect(acceptance).not_to include(
        'expected exactly six Instagram placeholder targets',
        'targets.size == 6',
        'seed_targets 6'
      )
      expect(acceptance).to include(
        'Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox)',
        'abort("no Instagram placeholder targets") if rows.empty?',
        'seed_targets_expected',
        'verify_seed_target_conservation "$log" "$summary"'
      )
    end
  end

  it 'validates dynamic seed conservation in clone, control, production, and final-audit programs' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      %w[
        fbig-acceptance.sh fbig-acceptance-control.sh
        fbig-profile-attempt.sh fbig-final-audit.sh
      ].each do |name|
        expect(File.binread(File.join(directory, name))).to include(
          'verify_seed_target_conservation'
        )
      end
      expect(File.binread(File.join(directory, 'fbig-final-audit.sh'))).to include(
        'Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox)'
      )
    end
  end

  it 'rejects a profile log or summary substituted after its attempt manifest was sealed' do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3('ruby', builder, directory)
      expect(status).to be_success, stderr

      final_audit = File.binread(File.join(directory, 'fbig-final-audit.sh'))
      validator = final_audit.match(/^validate_profile_result\(\) \{.*?^\}/m)[0]
      attempt_root = File.join(directory, 'profile-attempts')
      attempt_directory = File.join(attempt_root, 'sealed-attempt')
      FileUtils.mkdir_p(attempt_directory)
      run_log = File.join(attempt_directory, 'fbig-profile-production-run.log')
      summary = File.join(attempt_directory, 'fbig-profile-production-run-summary.tsv')
      sealed_log = "[UMI-FBIG] stage=history_profiles_start seed_targets_expected=1\n"
      sealed_summary = "[UMI-FBIG] stage=history_profiles_summary seed_targets=1\n"
      File.binwrite(run_log, sealed_log)
      File.binwrite(summary, sealed_summary)

      attempt_manifest = File.join(attempt_directory, 'fbig-profile-production-attempt-v1.tsv')
      attempt_rows = {
        schema_version: 1,
        profile_approval_sha256: 'p' * 64,
        image_digest: "ghcr.io/shumkov/chatwoot@sha256:#{'i' * 64}",
        production_database_name: 'chatwoot_production',
        platforms: 'instagram',
        dry_run: 'false',
        pre_attempt_backup_sha256: 'b' * 64,
        prestate_sha256: 's' * 64,
        poststate_sha256: 't' * 64,
        avatar_staging_sha256: 'a' * 64,
        run_log_sha256: Digest::SHA256.file(run_log).hexdigest,
        run_summary_sha256: Digest::SHA256.file(summary).hexdigest,
        exit_status: 0,
        started_at: '2026-07-29T00:00:00Z',
        finished_at: '2026-07-29T00:01:00Z'
      }
      File.write(attempt_manifest, "#{attempt_rows.map { |key, value| "#{key}\t#{value}" }.join("\n")}\n")

      result = File.join(directory, 'profile-result.tsv')
      result_rows = {
        authorization_mode: 'clone_authorized',
        authorization_sha256: 'none',
        candidate_commit: 'c' * 40,
        candidate_image: attempt_rows[:image_digest],
        production_database: attempt_rows[:production_database_name],
        inbox_id: 1,
        acceptance_sha256: 'a' * 64,
        profile_approval_sha256: attempt_rows[:profile_approval_sha256],
        profile_wrapper_sha256: 'w' * 64,
        storage_helper_sha256: 'h' * 64,
        attempt_directory: attempt_directory,
        attempt_manifest_sha256: Digest::SHA256.file(attempt_manifest).hexdigest,
        platforms: attempt_rows[:platforms],
        dry_run: attempt_rows[:dry_run]
      }
      File.write(result, "#{result_rows.map { |key, value| "#{key}\t#{value}" }.join("\n")}\n")

      shell = <<~BASH
        set -Eeuo pipefail
        sha256_file() { sha256sum --binary "$1" | awk '{ print $1 }'; }
        manifest_value() { awk -F '\\t' -v key="$2" '$1 == key { print $2; exit }' "$1"; }
        verify_checksum() { :; }
        require_ordered_manifest() { :; }
        require_root_directory() { :; }
        require_root_artifact() { :; }
        verify_seed_target_conservation() { :; }
        realpath() { printf '%s\n' "$3"; }
        CANDIDATE_COMMIT=#{result_rows[:candidate_commit]}
        CANDIDATE_IMAGE=#{result_rows[:candidate_image]}
        PRODUCTION_DATABASE=#{result_rows[:production_database]}
        INBOX_ID=#{result_rows[:inbox_id]}
        ACCEPTANCE_SHA256=#{result_rows[:acceptance_sha256]}
        PROFILE_APPROVAL_SHA256=#{result_rows[:profile_approval_sha256]}
        PROFILE_WRAPPER_SHA256=#{result_rows[:profile_wrapper_sha256]}
        STORAGE_HELPER_SHA256=#{result_rows[:storage_helper_sha256]}
        AUTHORIZATION_MODE=#{result_rows[:authorization_mode]}
        AUTHORIZATION_SHA256=#{result_rows[:authorization_sha256]}
        PROFILE_ATTEMPT_ROOT="$2"
        PROFILE_RESULT_FIELDS=(schema_version)
        PROFILE_ATTEMPT_FIELDS=(schema_version)
        #{validator}
        validate_profile_result "$1" "$1.sha256"
      BASH

      [run_log, summary].each do |artifact|
        File.binwrite(run_log, sealed_log)
        File.binwrite(summary, sealed_summary)
        _stdout, run_stderr, run_status = Open3.capture3(
          'bash', '-c', shell, 'bash', result, attempt_root
        )
        expect(run_status).to be_success, run_stderr

        File.binwrite(artifact, "substituted #{File.basename(artifact)}\n")
        _stdout, _run_stderr, run_status = Open3.capture3(
          'bash', '-c', shell, 'bash', result, attempt_root
        )
        expect(run_status).not_to be_success
      end
    end
  end
  # rubocop:enable RSpec/ExampleLength

  # rubocop:disable RSpec/ExampleLength
  it 'accepts two and seven seed rows but rejects a non-conserving result' do
    common = File.join(repository_root, 'script/umi_fbig/programs/common.sh')

    Dir.mktmpdir do |directory|
      [2, 7].each do |count|
        log = File.join(directory, "profile-#{count}.log")
        summary = File.join(directory, "profile-#{count}.summary")
        File.write(
          log,
          "[UMI-FBIG] stage=history_profiles_start platforms=messenger,instagram seed_targets_expected=#{count}\n"
        )
        fields = [
          '[UMI-FBIG]',
          'stage=history_profiles_summary',
          "seed_targets=#{count}",
          "seed_targets_complete=#{count}",
          "seed_targets_success=#{count}",
          'seed_targets_unavailable=0',
          'seed_targets_blocking=0',
          "seed_targets_repaired=#{count}",
          'seed_targets_preserved=0',
          'seed_targets_blank_name=0',
          'seed_targets_blocked=0'
        ]
        File.write(summary, "#{fields.join(' ')}\n")

        _stdout, stderr, status = Open3.capture3(
          'bash',
          '-c',
          'source "$1"; verify_seed_target_conservation "$2" "$3"',
          'seed-conservation',
          common,
          log,
          summary
        )
        expect(status).to be_success, stderr
      end

      messenger_log = File.join(directory, 'profile-messenger.log')
      messenger_summary = File.join(directory, 'profile-messenger.summary')
      File.write(
        messenger_log,
        "[UMI-FBIG] stage=history_profiles_start platforms=messenger seed_targets_expected=0\n"
      )
      fields = [
        '[UMI-FBIG]',
        'stage=history_profiles_summary',
        'seed_targets=0',
        'seed_targets_complete=0',
        'seed_targets_success=0',
        'seed_targets_unavailable=0',
        'seed_targets_blocking=0',
        'seed_targets_repaired=0',
        'seed_targets_preserved=0',
        'seed_targets_blank_name=0',
        'seed_targets_blocked=0'
      ]
      File.write(messenger_summary, "#{fields.join(' ')}\n")
      _stdout, stderr, status = Open3.capture3(
        'bash',
        '-c',
        'source "$1"; verify_seed_target_conservation "$2" "$3"',
        'seed-conservation',
        common,
        messenger_log,
        messenger_summary
      )
      expect(status).to be_success, stderr

      summary = File.join(directory, 'profile-7.summary')
      File.write(
        summary,
        File.read(summary).sub('seed_targets_complete=7', 'seed_targets_complete=6')
      )
      _stdout, _stderr, status = Open3.capture3(
        'bash',
        '-c',
        'source "$1"; verify_seed_target_conservation "$2" "$3"',
        'seed-conservation',
        common,
        File.join(directory, 'profile-7.log'),
        summary
      )
      expect(status).not_to be_success
    end
  end
  # rubocop:enable RSpec/ExampleLength

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
        '94714cfd5ceb68a7331bc145f168fa08f2f4b0bfc6f156ee74766e9fd2c24afb'
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
        'profile_seed_targets_sealed',
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
        expected_instagram_unavailable_message_threads: 2,
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
        history_approval: '/protected/history/fbig-approval-v2.tsv',
        history_approval_checksum: '/protected/history/fbig-approval-v2.tsv.sha256',
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

  # rubocop:disable RSpec/ExampleLength
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
      expect(bytes).to include(
        "printf 'schema_version\\t1\\n'\n    printf 'authorization_mode\\t%s\\n' \"$AUTHORIZATION_MODE\"\n    " \
        "printf 'authorization_sha256\\t%s\\n' \"$AUTHORIZATION_SHA256\"\n    " \
        "printf 'label\\t%s\\n' \"$LABEL\""
      )
      expect(bytes).not_to include("arguments[-1]='DRY_RUN=true'")
      expect(bytes).to include('-e DRY_RUN="$dry_run_value"')
      lock_index = bytes.index('acquire_descriptor_verified_lock "$PRODUCTION_LOCK"')
      head_index = bytes.index('global_head_sha=none')
      expect(lock_index).to be < head_index
      expect(bytes.scan('acquire_descriptor_verified_lock "$PRODUCTION_LOCK"').size).to eq(1)
      expect(bytes).to include(
        'revision_platform="$(manifest_value "$HISTORY_APPROVAL" revision_platform)"',
        'production-first revision changed the unselected contentless projection',
        'production_first_history_head_sha',
        'history predecessor is not the global production-first head',
        'successor release predecessor is not the global history head',
        'another history attempt must be finalized before continuing',
        'initial Instagram predecessor is not a successful terminal zero-write Messenger result'
      )
      final_audit = File.binread(File.join(directory, 'fbig-final-audit.sh'))
      expect(final_audit).to include(
        'MESSENGER_DRY_PAIR_SHA',
        'INSTAGRAM_DRY_PAIR_SHA',
        'test "$(manifest_value "$result" dry_pair_sha256)" = none',
        'messenger_listed_threads',
        'instagram_listed_threads',
        'unavailable_message_thread_acceptance_mismatches',
        '$((expected_structural + unavailable))',
        '$((cursor_exhausted + classified + failed))',
        'read -r sequence result expected_sha authorization authorization_sha approval approval_sha extra',
        'production-first history index must contain the complete chain',
        'FIRST_HISTORY_SUMMARY',
        'dry_summary="${FIRST_HISTORY_SUMMARY["$platform"]}"',
        'validate_history_platform_transition "$previous_result" "$result"',
        'test "$(manifest_value "$result" pre_history_backup_sha256)" =',
        '"$(manifest_value "$approval" coordinated_backup_manifest_sha256)"',
        'test "$previous_authorization_sha" = "$AUTHORIZATION_SHA256"',
        'test "$previous_approval_sha" = "$HISTORY_APPROVAL_SHA256"'
      )
      expect(final_audit).not_to include(
        'manifest_value "$HISTORY_APPROVAL" predecessor_attempt_result_sha256'
      )
    end
  end
  # rubocop:enable RSpec/ExampleLength

  it 'rejects a new history label while an interrupted attempt remains unpublished' do
    history_attempt = File.binread(
      File.join(repository_root, 'script/umi_fbig/programs/history_attempt.sh')
    )
    validator = history_attempt.match(
      /^reject_other_in_progress_history_attempts\(\) \{.*?^\}/m
    )[0]
    Dir.mktmpdir do |directory|
      Dir.mkdir(File.join(directory, '.interrupted.in-progress'), 0o700)
      shell = <<~BASH
        set -Eeuo pipefail
        die() { printf '%s\n' "$*" >&2; exit 1; }
        require_root_directory() { :; }
        AUDIT_ROOT=#{directory}
        IN_PROGRESS_DIRECTORY=#{directory}/.new-label.in-progress
        #{validator}
        reject_other_in_progress_history_attempts
      BASH

      _stdout, stderr, status = Open3.capture3('bash', stdin_data: shell)

      expect(status).not_to be_success
      expect(stderr).to include('another history attempt must be finalized before continuing')
    end
  end

  it 'selects the unique global production-first head across release authorizations' do
    history_attempt = File.binread(
      File.join(repository_root, 'script/umi_fbig/programs/history_attempt.sh')
    )
    head_selector = history_attempt.match(
      /^production_first_history_head_sha\(\) \{.*?^\}/m
    )[0]
    Dir.mktmpdir do |directory|
      first_directory = File.join(directory, 'first')
      second_directory = File.join(directory, 'second')
      FileUtils.mkdir_p([first_directory, second_directory], mode: 0o700)
      first = File.join(first_directory, 'fbig-history-attempt-result-v1.tsv')
      second = File.join(second_directory, 'fbig-history-attempt-result-v1.tsv')
      File.write(
        first,
        "authorization_mode\tproduction_first\n" \
        "authorization_sha256\t#{'a' * 64}\n" \
        "predecessor_result_sha256\tnone\n"
      )
      first_sha = Digest::SHA256.file(first).hexdigest
      File.write(
        second,
        "authorization_mode\tproduction_first\n" \
        "authorization_sha256\t#{'b' * 64}\n" \
        "predecessor_result_sha256\t#{first_sha}\n"
      )
      second_sha = Digest::SHA256.file(second).hexdigest
      interrupted_directory = File.join(directory, '.current.in-progress')
      FileUtils.mkdir_p(interrupted_directory, mode: 0o700)
      interrupted = File.join(interrupted_directory, 'fbig-history-attempt-result-v1.tsv')
      File.write(
        interrupted,
        "authorization_mode\tproduction_first\n" \
        "authorization_sha256\t#{'c' * 64}\n" \
        "predecessor_result_sha256\t#{second_sha}\n"
      )
      shell = <<~BASH
        set -Eeuo pipefail
        die() { printf '%s\n' "$*" >&2; exit 1; }
        verify_checksum() { :; }
        require_ordered_manifest() { :; }
        manifest_value() { awk -F '\t' -v key="$2" '$1 == key { print $2 }' "$1"; }
        sha256_file() { sha256sum --binary "$1" | awk '{ print $1 }'; }
        AUDIT_ROOT=#{directory}
        RESULT_FIELDS=(schema_version)
        #{head_selector}
        production_first_history_head_sha none #{interrupted}
      BASH

      stdout, stderr, status = Open3.capture3('bash', stdin_data: shell)

      expect(status).to be_success, stderr
      expect(stdout.chomp).to eq(second_sha)
    end
  end

  # rubocop:disable RSpec/ExampleLength
  it 'normalizes only history snapshot metadata when proving successor live state' do
    history_attempt = File.binread(
      File.join(repository_root, 'script/umi_fbig/programs/history_attempt.sh')
    )
    content_digest = history_attempt.match(
      /^history_state_content_sha256\(\) \{.*?^\}/m
    )[0]
    baseline_validator = history_attempt.match(
      /^validate_successor_live_baseline\(\) \{.*?^\}/m
    )[0]
    Dir.mktmpdir do |directory|
      predecessor = File.join(directory, 'predecessor.tsv')
      matching = File.join(directory, 'matching.tsv')
      drifted = File.join(directory, 'drifted.tsv')
      header = "schema_version\t1\naccount_id\t1\ninbox_id\t2\nplatforms\tmessenger\n"
      File.write(
        predecessor,
        "#{header}captured_at\t2026-07-29T00:00:00Z\nrow_count\t2\n" \
        "contact\tshared\t9\told\narchive\tmessenger\t1\told\n"
      )
      File.write(
        matching,
        "#{header}captured_at\t2026-07-29T01:00:00Z\nrow_count\t2\n" \
        "contact\tshared\t9\tnew\narchive\tmessenger\t1\told\n"
      )
      File.write(
        drifted,
        "#{header}captured_at\t2026-07-29T01:00:00Z\nrow_count\t1\narchive\tmessenger\t1\tnew\n"
      )
      shell = <<~BASH
        set -Eeuo pipefail
        #{content_digest}
        test "$(history_state_content_sha256 #{predecessor})" = \
          "$(history_state_content_sha256 #{matching})"
        test "$(history_state_content_sha256 #{predecessor})" != \
          "$(history_state_content_sha256 #{drifted})"
      BASH

      _stdout, stderr, status = Open3.capture3('bash', stdin_data: shell)

      expect(status).to be_success, stderr

      validator_shell = <<~BASH
        set -Eeuo pipefail
        die() { printf '%s\n' "$*" >&2; exit 1; }
        manifest_value() { printf 'messenger\n'; }
        AUTHORIZATION_MODE=production_first
        PLATFORMS=messenger
        PREDECESSOR_RESULT="$PREDECESSOR_RESULT_VALUE"
        predecessor_baseline="$PREDECESSOR_BASELINE_VALUE"
        BACKUP_HISTORY_STATE=#{predecessor}
        cross_release_predecessor="$CROSS_RELEASE_VALUE"
        #{content_digest}
        #{baseline_validator}
        validate_successor_live_baseline "$LIVE_PRESTATE"
      BASH
      _stdout, stderr, status = Open3.capture3(
        {
          'PREDECESSOR_RESULT_VALUE' => 'none',
          'PREDECESSOR_BASELINE_VALUE' => 'none',
          'CROSS_RELEASE_VALUE' => 'false',
          'LIVE_PRESTATE' => matching
        },
        'bash',
        stdin_data: validator_shell
      )
      expect(status).to be_success, stderr

      _stdout, stderr, status = Open3.capture3(
        {
          'PREDECESSOR_RESULT_VALUE' => 'none',
          'PREDECESSOR_BASELINE_VALUE' => 'none',
          'CROSS_RELEASE_VALUE' => 'false',
          'LIVE_PRESTATE' => drifted
        },
        'bash',
        stdin_data: validator_shell
      )
      expect(status).not_to be_success
      expect(stderr).to include('successor live prestate differs from its coordinated backup state')

      _stdout, stderr, status = Open3.capture3(
        {
          'PREDECESSOR_RESULT_VALUE' => '/predecessor',
          'PREDECESSOR_BASELINE_VALUE' => drifted,
          'CROSS_RELEASE_VALUE' => 'true',
          'LIVE_PRESTATE' => drifted
        },
        'bash',
        stdin_data: validator_shell
      )
      expect(status).not_to be_success
      expect(stderr).to include('successor backup state differs from its predecessor expanded baseline')
    end
    expect(history_attempt).to include(
      'validate_successor_live_baseline "$PRESTATE"',
      'successor live prestate differs from its coordinated backup state'
    )
    validation_index = history_attempt.index('validate_successor_live_baseline "$PRESTATE"')
    importer_index = history_attempt.index("\n  run_importer\n")
    expect(validation_index).to be < importer_index
  end
  # rubocop:enable RSpec/ExampleLength

  # rubocop:disable RSpec/ExampleLength
  it 'rejects a writeful Messenger predecessor before an initial Instagram attempt can mutate' do
    history_attempt = File.binread(
      File.join(repository_root, 'script/umi_fbig/programs/history_attempt.sh')
    )
    validator = history_attempt.match(
      /^validate_initial_messenger_predecessor\(\) \{.*?^\}/m
    )[0]
    Dir.mktmpdir do |directory|
      mutation_log = File.join(directory, 'docker.log')
      shell = <<~BASH
        set -Eeuo pipefail
        die() { printf '%s\n' "$*" >&2; exit 1; }
        manifest_value() {
          case "$2" in
            platforms) printf 'messenger\n' ;;
            operation) printf 'apply\n' ;;
            require_zero_writes) printf 'false\n' ;;
            zero_write_observed) printf 'false\n' ;;
            exit_status) printf '0\n' ;;
            termination) printf 'normal\n' ;;
            protected_changes|deleted_rows|unattributed_changes) printf '0\n' ;;
            counter_mismatches) printf 'none\n' ;;
            run_summary_sha256) printf '%064d\n' 0 ;;
            messenger_unavailable_message_thread_count) printf '0\n' ;;
            messenger_unavailable_message_thread_fingerprint) printf '%064d\n' 0 ;;
            *) exit 2 ;;
          esac
        }
        sha256_file() { printf '%064d\n' 0; }
        stage_value() {
          case "$3" in
            platforms) printf 'messenger\n' ;;
            dry_run) printf 'false\n' ;;
            scan_complete|write_complete) printf 'true\n' ;;
            contentless_acceptance_mismatches|unavailable_message_thread_acceptance_mismatches|exit_failures)
              printf '0\n'
              ;;
            failed_threads|partially_paginated_threads|uncategorized_threads|structural_unrecoverable_threads)
              printf '0\n'
              ;;
            ambiguous_participants|unavailable_message_threads|messenger_unavailable_message_threads)
              printf '0\n'
              ;;
            messenger_unavailable_message_thread_count) printf '0\n' ;;
            messenger_unavailable_message_thread_fingerprint) printf '%064d\n' 0 ;;
            recovered_thread_targets_sha256) printf 'none\n' ;;
            recovered_targets_expected|recovered_targets_listed|recovered_targets_message_cursor_exhausted)
              printf '0\n'
              ;;
            classified_omitted_threads) printf '0\n' ;;
            listed_threads|message_cursor_exhausted_threads) printf '1\n' ;;
            *) exit 3 ;;
          esac
        }
        docker() { printf '%s\n' "$*" >>"$UMI_FBIG_MUTATION_LOG"; }
        HISTORY_APPROVAL=/approval
        #{validator}
        validate_initial_messenger_predecessor /result /summary
        docker compose run
      BASH
      _stdout, stderr, status = Open3.capture3(
        { 'UMI_FBIG_MUTATION_LOG' => mutation_log }, 'bash', '-c', shell
      )

      expect(status).not_to be_success
      expect(stderr).to include(
        'initial Instagram predecessor is not a successful terminal zero-write Messenger result'
      )
      expect(File).not_to exist(mutation_log)
    end
  end
  # rubocop:enable RSpec/ExampleLength

  # rubocop:disable RSpec/ExampleLength
  it 'rejects internally conserved history summaries that differ from the approved structural count' do
    history_attempt = File.binread(
      File.join(repository_root, 'script/umi_fbig/programs/history_attempt.sh')
    )
    validator = history_attempt.match(
      /^validate_history_terminal_summary\(\) \{.*?^\}/m
    )[0]
    shell = <<~BASH
      set -Eeuo pipefail
      die() { printf '%s\n' "$*" >&2; exit 1; }
      manifest_value() {
        case "$2" in
          instagram_unavailable_message_thread_count) printf '2\n' ;;
          instagram_unavailable_message_thread_fingerprint) printf '%064d\n' 0 ;;
          *) exit 2 ;;
        esac
      }
      stage_value() {
        case "$3" in
          platforms) printf 'instagram\n' ;;
          dry_run) printf 'true\n' ;;
          scan_complete) printf 'true\n' ;;
          write_complete) printf 'not_applicable\n' ;;
          contentless_acceptance_mismatches|unavailable_message_thread_acceptance_mismatches|exit_failures)
            printf '0\n'
            ;;
          partially_paginated_threads|uncategorized_threads) printf '0\n' ;;
          ambiguous_participants|structural_unrecoverable_threads) printf '%s\n' "$STRUCTURAL" ;;
          unavailable_message_threads|instagram_unavailable_message_threads|instagram_unavailable_message_thread_count)
            printf '2\n'
            ;;
          instagram_unavailable_message_thread_fingerprint) printf '%064d\n' 0 ;;
          classified_omitted_threads|instagram_classified_omitted_threads) printf '%s\n' "$CLASSIFIED" ;;
          failed_threads|instagram_failed_threads) printf '0\n' ;;
          listed_threads|instagram_listed_threads) printf '748\n' ;;
          message_cursor_exhausted_threads|instagram_message_cursor_exhausted_threads) printf '%s\n' "$CURSOR" ;;
          instagram_structural_unrecoverable_threads) printf '%s\n' "$STRUCTURAL" ;;
          *) exit 3 ;;
        esac
      }
      HISTORY_APPROVAL=/approval
      AUTHORIZATION_MODE=clone_authorized
      PLATFORMS=instagram
      EXPECTED_STRUCTURAL_THREADS=1
      #{validator}
      validate_history_terminal_summary /summary true not_applicable
    BASH

    _stdout, stderr, status = Open3.capture3(
      { 'STRUCTURAL' => '0', 'CLASSIFIED' => '2', 'CURSOR' => '746' },
      'bash',
      stdin_data: shell
    )
    expect(status).not_to be_success
    expect(stderr).to include('history terminal summary platform accounting mismatch')

    _stdout, stderr, status = Open3.capture3(
      { 'STRUCTURAL' => '1', 'CLASSIFIED' => '3', 'CURSOR' => '745' },
      'bash',
      stdin_data: shell
    )
    expect(status).to be_success, stderr
  end
  # rubocop:enable RSpec/ExampleLength

  it 'rejects a production envelope fingerprint change even when its count is unchanged' do
    history_attempt = File.binread(
      File.join(repository_root, 'script/umi_fbig/programs/history_attempt.sh')
    )
    inspector = history_attempt.match(/^inspect_unrecoverable_envelopes\(\) \{.*?^\}/m)[0]

    Dir.mktmpdir do |directory|
      output = File.join(directory, 'unrecoverable-before.tsv')
      File.write(output, "[UMI-FBIG] stage=unrecoverable_envelope_inspection count=1 fingerprint=observed\n")
      shell = <<~BASH
        set -Eeuo pipefail
        die() { printf '%s\n' "$*" >&2; exit 1; }
        verify_checksum() { :; }
        stage_value() {
          case "$3" in
            count) printf '1\n' ;;
            fingerprint) printf 'observed\n' ;;
            *) exit 2 ;;
          esac
        }
        manifest_value() { printf '%s\n' "$EXPECTED_FINGERPRINT"; }
        PLATFORMS=instagram
        EXPECTED_STRUCTURAL_THREADS=1
        IN_PROGRESS_DIRECTORY=#{directory}
        UNRECOVERABLE_SIDECAR=/sidecar
        #{inspector}
        inspect_unrecoverable_envelopes #{output} before
      BASH

      _stdout, stderr, status = Open3.capture3(
        { 'EXPECTED_FINGERPRINT' => 'approved' },
        'bash',
        stdin_data: shell
      )
      expect(status).not_to be_success
      expect(stderr).to include('production unrecoverable-envelope inspection differs from acceptance')

      _stdout, stderr, status = Open3.capture3(
        { 'EXPECTED_FINGERPRINT' => 'observed' },
        'bash',
        stdin_data: shell
      )
      expect(status).to be_success, stderr
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
