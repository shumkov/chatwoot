# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'UMI FB/IG full-history runbook' do
  let(:runbook) { File.read(File.expand_path('../../docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md', __dir__)) }
  let(:design) { File.read(File.expand_path('../../docs/UMI-FBIG-FULL-HISTORY-EXPANSION-SPEC.md', __dir__)) }
  let(:program_directory) { File.expand_path('../../script/umi_fbig/programs', __dir__) }

  it 'uses portable awk field variables in every summary parser' do
    expect(runbook).not_to include('for (index =')
    expect(runbook.scan('for (field =')).not_to be_empty
  end

  it 'binds the exact unrecoverable Instagram envelope into the accepted approval chain' do
    expect(runbook).to include('fbig-unrecoverable-envelope-v1.tsv')
    expect(runbook).to include('umi-fbig-unrecoverable-envelope-v1')
    expect(runbook).to include('source_dry_log_sha256')
    expect(runbook).to include('inspector_script_sha256')
  end

  it 'binds exact release-bound unavailable-message omissions into approval and thread conservation' do
    acceptance = File.read(File.join(program_directory, 'acceptance.sh'))
    history_attempt = File.read(File.join(program_directory, 'history_attempt.sh'))
    acceptance_control = File.read(File.join(program_directory, 'acceptance_control.sh'))
    final_audit = File.read(File.join(program_directory, 'final_audit.sh'))

    expect([runbook, acceptance, history_attempt, acceptance_control]).to all(include('fbig-approval-v2.tsv'))
    expect([runbook, acceptance, history_attempt, acceptance_control].count do |artifact|
      artifact.include?('fbig-approval-v1.tsv')
    end).to be_zero
    expect([runbook, acceptance]).to all(
      include(
        'messenger_unavailable_message_thread_count',
        'messenger_unavailable_message_thread_fingerprint',
        'instagram_unavailable_message_thread_count',
        'instagram_unavailable_message_thread_fingerprint',
        'unavailable_message_thread_acceptance_mismatches'
      )
    )
    expect([runbook, acceptance, history_attempt, final_audit]).to all(
      include(
        'listed_threads',
        'message_cursor_exhausted_threads',
        'structural_unrecoverable_threads',
        'unavailable_message_threads',
        'classified_omitted_threads',
        'partially_paginated_threads'
      )
    )
    expect(final_audit).to include(
      'messenger_unavailable_message_thread_fingerprint',
      'instagram_unavailable_message_thread_fingerprint',
      'unavailable_message_thread_acceptance_mismatches'
    )
  end

  it 'refuses to fingerprint an ambiguous envelope that has become recoverable' do
    inspector = runbook.match(
      /UNRECOVERABLE_INSPECTOR=.*?<<'RUBY'\n(?<body>.*?)\nRUBY/m
    )[:body]

    expect(inspector).to include(
      "abort('unrecoverable envelope participant shape changed')",
      "abort('unrecoverable envelope message shape changed')",
      "participants_state == 'array'",
      "participants == [{ 'id' => business_id, 'business' => true }]",
      'messages.size == 1',
      "message.fetch('listing_sender') == business_id",
      "message.fetch('detail_sender') == business_id",
      "message.fetch('recipients').empty?",
      "message.fetch('message_blank')",
      "message.fetch('attachment_descriptors').zero?",
      "message.fetch('attachment_omissions').empty?"
    )
    ordered_markers = [
      "abort('unrecoverable envelope participant shape changed')",
      "abort('unrecoverable envelope message shape changed')",
      'ambiguous_threads <<',
      'TypedValueDigest.hexdigest(record)',
      "puts [\n  '[UMI-FBIG]'"
    ]
    positions = ordered_markers.map { |marker| inspector.index(marker) }

    expect(positions).to all(be_a(Integer))
    expect(positions).to eq(positions.sort)
  end

  it 'uses the platform-aware Graph message API in every embedded inspector' do
    acceptance = File.read(File.join(program_directory, 'acceptance.sh'))

    expect([runbook, acceptance]).to all(include("client.messages('instagram', thread_id)"))
    expect([runbook, acceptance].count { |artifact| artifact.include?('client.messages(thread_id)') }).to be_zero
  end

  it 'brackets every Instagram-inclusive clone and production history run with exact envelope checks' do
    expect(runbook).to match(
      /
        inspect_unrecoverable_envelopes\ before-probe .*?
        PLATFORMS=messenger,instagram .*? umi:fbig:history_import .*?
        inspect_unrecoverable_envelopes\ after-probe
      /mx
    )
    expect(runbook).to match(
      /
        accepted_history_dry_run\(\) .*?
        inspect_unrecoverable_envelopes\ "before-\$attempt" .*?
        history_run\ true\ messenger,instagram .*?
        inspect_unrecoverable_envelopes\ "after-\$attempt" .*? ^\}
      /mx
    )
    expect(runbook).to match(
      /
        history_apply_with_verification\(\) .*?
        inspect_unrecoverable_envelopes\ "before-\$label" .*?
        history_run\ false\ "\$platforms" .*?
        inspect_unrecoverable_envelopes\ "after-\$label" .*? ^\}
      /mx
    )
    expect(runbook).to match(
      /
        production_history_run_with_verification\(\) .*?
        inspect_production_unrecoverable_envelopes\ "before-\$label" .*?
        fbig_history_run\.sh .*?
        inspect_production_unrecoverable_envelopes\ "after-\$label" .*? ^\}
      /mx
    )
    expect(runbook).to include('inspect_production_unrecoverable_envelopes final-production')
  end

  it 'validates the strict exception sidecar and chains it into production approval' do
    production = runbook.match(/## 9\. Production history\n(?<body>.*?)(?=^## 10\.)/m)[:body]
    ordered_markers = [
      'verify_checksum "$UNRECOVERABLE_SIDECAR" "$UNRECOVERABLE_SIDECAR_CHECKSUM"',
      'EXPECTED_UNRECOVERABLE_FIELDS=(',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" repository_commit)" = "$APP_COMMIT"',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" image_digest)" = "$APP_DIGEST"',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" before)" = "$CUTOFF"',
      'test "$(manifest_value "$UNRECOVERABLE_SIDECAR" inspector_script_sha256)" =',
      'test "$(manifest_value "$HISTORY_APPROVAL" source_dry_log_sha256)" =',
      '"$(sha256_file "$HISTORY_PROBE_LOG")"',
      'stage=unrecoverable_envelope_approval sidecar_sha256=',
      'production_history_run_with_verification()'
    ]
    positions = ordered_markers.map { |marker| production.index(marker) }

    expect(positions).to all(be_a(Integer))
    expect(positions).to eq(positions.sort)
  end

  it 'requires protected terminal clone acceptance before production history' do
    control = File.read(File.join(program_directory, 'acceptance_control.sh'))
    history = File.read(File.join(program_directory, 'history_attempt.sh'))

    expect(control).to include(
      'fbig-acceptance-complete-v1.tsv',
      'unit_fragment_sha256',
      'prelaunch_descriptor_sha256',
      'postlaunch_descriptor_sha256',
      'InvocationID',
      'DropInPaths',
      'messenger_history_terminal_summary_sha256',
      'instagram_history_terminal_summary_sha256',
      'clone_database_name',
      'profile_approval_sha256',
      'profile_targets_sha256',
      'artifact_index_sha256',
      'acquire_descriptor_verified_lock "$FINALIZER_LOCK"'
    )
    expect(history).to include(
      'verify_checksum "$ACCEPTANCE_MANIFEST" "$ACCEPTANCE_CHECKSUM"',
      'require_ordered_manifest "$ACCEPTANCE_MANIFEST" "${ACCEPTANCE_FIELDS[@]}"',
      'terminal acceptance commit mismatch',
      'terminal acceptance image mismatch',
      'terminal acceptance approval mismatch',
      'terminal acceptance did not succeed'
    )
  end

  it 'proves the deployed commit, migration, and exact valid avatar index before production evidence' do
    production = runbook.match(/## 9\. Production history\n(?<body>.*?)(?=^## 10\.)/m)[:body]
    preflight = production.index("\nverify_production_release_and_schema\n")
    first_evidence = production.index('verify_production_history_state before-production-history')

    expect(preflight).to be < first_evidence
    expect(production).to include(
      '20260724000000',
      '/app/.git_sha',
      'index_active_storage_contact_avatar_uniqueness',
      "namespace.nspname = 'public'",
      'i.indnatts = 3 AND i.indnkeyatts = 3',
      'i.indexprs IS NULL',
      'indisunique',
      'indisvalid',
      'indisready',
      "ARRAY['record_type', 'record_id', 'name']",
      "record_type = 'Contact'",
      "name = 'avatar'"
    )
  end

  it 'validates and skips sealed production history stages on resume' do
    production = runbook.match(/## 9\. Production history\n(?<body>.*?)(?=^## 10\.)/m)[:body]
    resume_gate = production.index('if [[ -e "$log" || -e "$summary" ]]')
    sealed_log = production.index('require_root_artifact "$log" "$(basename "$log")"')
    wrapper = production.index('"$STACK_DIR/bin/fbig_history_run.sh" "${arguments[@]}"')

    expect([resume_gate, sealed_log, wrapper]).to eq([resume_gate, sealed_log, wrapper].sort)
    expect(production).to include(
      'if [[ -e "$PRE_HISTORY_BACKUP_LOG" ]]',
      '"$PRE_HISTORY_BACKUP_LOG" "$(basename "$PRE_HISTORY_BACKUP_LOG")"',
      'stage_value "$log" history_import_start platforms',
      'stage_value "$log" history_import_start profile_mode)" = defer'
    )
  end

  it 'turns the final profile pass into a sealed zero-write proof' do
    profile = runbook.match(/## 10\. Production profile\n(?<body>.*?)(?=^## 11\.)/m)[:body]

    expect(profile).to include(
      'PROFILE_OPERATION=',
      'run_profile_attempt_phase()',
      'verify_profile_attempt_result()',
      'fbig-profile-attempt-result-v1.tsv',
      'attempt_checksum="${attempt_manifest}.sha256"',
      'fbig-profile-production-run-summary.tsv',
      'fbig-profile-production-prestate-v1.tsv',
      'fbig-profile-production-poststate-v1.tsv',
      'fbig-profile-avatar-staging-v1.tsv',
      'fbig-profile-production-run.log',
      'fbig-profile-attempt-complete-v1.tsv',
      'pre_attempt_backup_sha256',
      'avatar_staging_sha256',
      'run_log_sha256',
      'predecessor_result_sha256',
      'predecessor_audit_sha256',
      'verify_profile_attempt_result "$predecessor_result"',
      'verify_profile_delivery_audit "$predecessor_audit" "$predecessor_result"',
      'cmp -s "$prestate" "$poststate"',
      'zero_write_observed',
      'scalar_changes_applied',
      'name_changes_applied',
      'username_changes_applied',
      'optional_changes_applied',
      'avatars_attached',
      'avatar_bytes',
      'mirror_jobs'
    )
  end

  it 'requires a sealed webhook audit between profile maintenance windows' do
    audit = File.read(File.join(program_directory, 'delivery_audit.sh'))

    expect(audit).to include(
      'fbig-profile-delivery-audit-v1.tsv',
      'attempt_started_at',
      'attempt_finished_at',
      'before_checkpoint_sha256',
      'after_checkpoint_sha256',
      'effective_window_start',
      'grace_end',
      'page_subscription_evidence_sha256',
      'instagram_subscription_evidence_sha256',
      'messenger_recon_summary_sha256',
      'instagram_recon_summary_sha256',
      'messenger_missing',
      'instagram_missing',
      'zero_unrecovered_deliveries',
      'predecessor_manifest_sha256',
      'acquire_descriptor_verified_lock "$PRODUCTION_LOCK"'
    )
  end

  it 'seals a live reconciliation audit before declaring migration completion' do
    final_audit = File.read(File.join(program_directory, 'final_audit.sh'))

    expect(runbook).to include('stage=production_writes_complete final_audit_pending=true')
    expect(final_audit).to include(
      'fbig-production-migration-audit-v1.tsv',
      'fbig-production-platform-counts-v1.tsv',
      'messenger_threads_scanned',
      'instagram_threads_scanned',
      'messenger_message_ids_scanned',
      'instagram_message_ids_scanned',
      'messenger_messages_created',
      'instagram_messages_created',
      'messenger_contentless_omissions',
      'instagram_contentless_omissions',
      'messenger_profile_targets_success',
      'instagram_profile_targets_success',
      'instagram_placeholders_remaining',
      'instagram_placeholders_remaining_fingerprint',
      'profile_seed_targets_sealed',
      'profile_seed_targets_repaired',
      'profile_avatars_attached',
      'empty_importer_archives',
      'duplicate_imported_source_ids',
      'unrecoverable_instagram_envelopes',
      'profile_mutations_are_aggregate',
      'history_result_index_sha256',
      'profile_result_index_sha256',
      'checkpoint_index_sha256',
      'SET TRANSACTION READ ONLY',
      'isolation: :repeatable_read',
      'stage=production_migration_complete'
    )
    seal = final_audit.index('seal_in_place "$FINAL_TEMP"')
    publish = final_audit.index(
      'publish_directory_no_replace "$STAGING_DIRECTORY" "$RESULT_DIRECTORY"'
    )
    validate = final_audit.rindex('validate_final_manifest "$RESULT_MANIFEST"')
    complete = final_audit.index('stage=production_migration_complete')

    expect([seal, publish, validate, complete]).to eq(
      [seal, publish, validate, complete].sort
    )
    expect(final_audit).to include(
      'in_scope_mids_scanned',
      'candidate_incoming + candidate_outbound',
      'candidate_incoming + outbound_import',
      'imported_incoming + imported_outgoing'
    )
  end

  it 'keeps the production safety gates in the reviewed design contract' do
    expect(design).to include(
      'terminal acceptance',
      'migration `20260724000000`',
      'Exit zero alone is not idempotency',
      'zero unrecovered deliveries',
      'resumable phase',
      'final live-database reconciliation'
    )
  end
end
# rubocop:enable RSpec/DescribeClass
