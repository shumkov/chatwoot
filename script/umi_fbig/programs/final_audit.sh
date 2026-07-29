readonly BINDING_MANIFEST="${1:?final audit binding is required}"
readonly BINDING_CHECKSUM="${BINDING_MANIFEST}.sha256"
PROGRAM_PATH="$(readlink -f "$0")"
readonly PROGRAM_PATH
readonly PROGRAM_CHECKSUM="${PROGRAM_PATH}.sha256"

readonly BINDING_FIELDS=(
  schema_version authorization_mode authorization_manifest
  authorization_checksum authorization_sha256 candidate_commit candidate_image
  stack_dir compose_file
  compose_file_sha256 compose_project rails_service sidekiq_service
  production_database audit_root inbox_id acceptance_manifest
  acceptance_checksum acceptance_sha256 history_approval
  history_approval_checksum history_approval_sha256 profile_approval
  profile_approval_checksum profile_approval_sha256 profile_targets
  profile_targets_sha256 profile_wrapper_sha256 storage_helper_sha256
  unrecoverable_sidecar unrecoverable_sidecar_checksum
  unrecoverable_sidecar_sha256 pre_history_backup
  pre_history_backup_checksum pre_history_backup_sha256 history_result_index
  history_result_index_checksum history_result_index_sha256
  profile_result_index profile_result_index_checksum profile_result_index_sha256
  checkpoint_index checkpoint_index_checksum checkpoint_index_sha256
  messenger_dry_1 messenger_dry_1_checksum messenger_dry_2
  messenger_dry_2_checksum instagram_dry_1 instagram_dry_1_checksum
  instagram_dry_2 instagram_dry_2_checksum messenger_terminal_result
  messenger_terminal_checksum instagram_terminal_result
  instagram_terminal_checksum final_profile_result
  final_profile_result_checksum final_profile_audit
  final_profile_audit_checksum first_checkpoint first_checkpoint_checksum
  final_checkpoint final_checkpoint_checksum production_lock
)
readonly PRODUCTION_FIRST_AUTHORIZATION_FIELDS=(
  schema_version authorization_mode repository_commit image_digest
  production_database account_id inbox_id facebook_page_id
  instagram_business_id since before outbound_policy profile_mode
  r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256
  r2_probe_summary_sha256 messenger_count messenger_fingerprint
  instagram_count instagram_fingerprint
  messenger_unavailable_message_thread_count
  messenger_unavailable_message_thread_fingerprint
  instagram_unavailable_message_thread_count
  instagram_unavailable_message_thread_fingerprint
  recovered_thread_targets_sha256 placeholder_targets_sha256
  unrecoverable_sidecar_sha256 unrecoverable_inspector_sha256
  coordinated_backup_manifest_sha256
  history_program_sha256 profile_program_sha256 final_audit_program_sha256
  delivery_audit_program_sha256 delivery_checkpoint_program_sha256
  profile_wrapper_sha256 storage_helper_sha256
  recovered_target_generator_sha256 authorization_generator_sha256
  history_revision_generator_sha256 profile_approval_generator_sha256
  normal_terminal_acceptance_sha256
  normal_dry_pair_sha256 predecessor_authorization_sha256
  predecessor_history_result_sha256 predecessor_terminal_summary_sha256
  predecessor_delta_sha256 predecessor_expanded_baseline_sha256
  current_state_backup_sha256 approved_by created_at
)
readonly PRODUCTION_FIRST_HISTORY_APPROVAL_FIELDS=(
  schema_version authorization_mode repository_commit image_digest
  production_database account_id inbox_id facebook_page_id
  instagram_business_id since before outbound_policy profile_mode
  coordinated_backup_manifest_sha256 production_first_authorization_sha256
  recovered_thread_targets_sha256 placeholder_targets_sha256
  unrecoverable_sidecar_sha256 messenger_count messenger_fingerprint
  instagram_count instagram_fingerprint
  messenger_unavailable_message_thread_count
  messenger_unavailable_message_thread_fingerprint
  instagram_unavailable_message_thread_count
  instagram_unavailable_message_thread_fingerprint
  r2_acceptance_binding_sha256 r2_launch_manifest_sha256 r2_probe_log_sha256
  r2_probe_summary_sha256 revision_platform predecessor_approval_sha256
  predecessor_attempt_result_sha256 predecessor_run_summary_sha256
  predecessor_delta_sha256 approved_by approved_at
)
readonly HISTORY_RESULT_FIELDS=(
  schema_version authorization_mode authorization_sha256 label operation
  platforms require_zero_writes program_sha256
  binding_sha256 candidate_commit candidate_image production_database inbox_id
  history_approval_sha256 acceptance_sha256 pre_history_backup_sha256
  dry_pair_sha256 attempt_identity_sha256 compose_override_sha256
  attachment_reconcile_start_sha256 prestate_sha256
  unrecoverable_before_sha256 unrecoverable_after_sha256
  attachment_reconcile_final_sha256 poststate_sha256 release_schema_sha256
  finalizer_release_schema_sha256 run_log_sha256 run_summary_sha256
  exit_status_artifact_sha256 comparison_log_sha256 delta_sha256 exit_status
  termination predecessor_result_sha256
  messenger_contacts_created messenger_contacts_reused
  messenger_contact_inboxes_created messenger_contact_inboxes_reused
  messenger_archives_created messenger_messages_created
  messenger_incoming_created messenger_outgoing_created
  messenger_attachments_created messenger_active_storage_attachments_created
  messenger_active_storage_blobs_created messenger_archive_activity_changed
  messenger_archive_configuration_changed messenger_contact_activity_changed
  messenger_contact_profile_changed instagram_contacts_created
  instagram_contacts_reused instagram_contact_inboxes_created
  instagram_contact_inboxes_reused instagram_archives_created
  instagram_messages_created instagram_incoming_created
  instagram_outgoing_created instagram_attachments_created
  instagram_active_storage_attachments_created
  instagram_active_storage_blobs_created instagram_archive_activity_changed
  instagram_archive_configuration_changed instagram_contact_activity_changed
  instagram_contact_profile_changed protected_changes deleted_rows
  unattributed_changes counter_mismatches zero_write_observed started_at
  finished_at sealed_at
)
readonly PROFILE_RESULT_FIELDS=(
  schema_version authorization_mode authorization_sha256 label profile_phase
  program_sha256 binding_sha256
  profile_wrapper_sha256 storage_helper_sha256 candidate_commit candidate_image
  production_database
  inbox_id acceptance_sha256 profile_approval_sha256
  predecessor_result_sha256 predecessor_audit_sha256 before_checkpoint_sha256
  attempt_identity_sha256 attempt_directory attempt_manifest_sha256
  pre_attempt_backup_directory pre_attempt_backup_sha256 wrapper_log_sha256
  wrapper_exit_status_sha256 platforms dry_run zero_write_observed
  termination started_at finished_at sealed_at
)
readonly PROFILE_ATTEMPT_FIELDS=(
  schema_version profile_approval_sha256 image_digest
  production_database_name platforms dry_run pre_attempt_backup_sha256
  prestate_sha256 poststate_sha256 avatar_staging_sha256 run_log_sha256
  run_summary_sha256 exit_status started_at finished_at
)
readonly PROFILE_AUDIT_FIELDS=(
  schema_version authorization_mode authorization_sha256 label program_sha256
  binding_sha256 candidate_commit
  candidate_image acceptance_sha256 attempt_result_sha256
  attempt_manifest_sha256 attempt_started_at attempt_finished_at
  before_checkpoint_sha256 after_checkpoint_sha256
  audit_window_started_at audit_window_finished_at
  page_identity_sha256 instagram_identity_sha256
  page_subscription_evidence_sha256
  instagram_subscription_evidence_sha256 messenger_recon_summary_sha256
  instagram_recon_summary_sha256 messenger_missing instagram_missing
  messenger_threads_failed instagram_threads_failed messenger_caps_hit
  instagram_caps_hit zero_unrecovered_deliveries
  predecessor_audit_sha256 audited_at
)
readonly CHECKPOINT_FIELDS=(
  schema_version label program_sha256 binding_sha256 candidate_commit
  candidate_image service_source_sha256 running_rails_image_id
  running_rails_commit running_rails_service_source_sha256
  running_sidekiq_image_id running_sidekiq_commit production_database
  inbox_id page_identity_sha256 instagram_identity_sha256 history_cutoff
  service_rolling_window_start effective_window_start grace_end
  started_at finished_at compose_override_sha256 reconciliation_log_sha256
  window_evidence_sha256 messenger_subscription_evidence_sha256
  instagram_subscription_evidence_sha256 messenger_recon_summary_sha256
  instagram_recon_summary_sha256 messenger_threads messenger_mids
  messenger_missing messenger_threads_failed messenger_caps_hit
  instagram_threads instagram_mids instagram_missing instagram_threads_failed
  instagram_caps_hit predecessor_manifest_sha256 sealed_at
)
readonly LIVE_COUNT_FIELDS=(
  schema_version observed_at database_snapshot_sha256
  messenger_archives messenger_nonempty_archives
  messenger_messages messenger_incoming messenger_outgoing
  messenger_attachments messenger_attachment_bytes messenger_linked_contacts
  messenger_linked_contact_inboxes messenger_baseline_archives
  messenger_baseline_messages messenger_baseline_incoming
  messenger_baseline_outgoing messenger_baseline_attachments
  messenger_baseline_linked_contacts messenger_baseline_linked_contact_inboxes
  instagram_archives
  instagram_nonempty_archives instagram_messages instagram_incoming
  instagram_outgoing instagram_attachments instagram_attachment_bytes
  instagram_linked_contacts instagram_linked_contact_inboxes
  instagram_baseline_archives instagram_baseline_messages
  instagram_baseline_incoming instagram_baseline_outgoing
  instagram_baseline_attachments instagram_baseline_linked_contacts
  instagram_baseline_linked_contact_inboxes
  empty_importer_archives
  duplicate_imported_source_ids invalid_importer_archives
  duplicate_contact_avatars history_attachment_intents
  unclassified_importer_messages seed_only_targets
  importer_only_targets seed_and_importer_targets unclassified_profile_targets
  instagram_seed_targets_sealed
  instagram_placeholders_remaining
  instagram_placeholders_remaining_fingerprint
)
readonly PLATFORM_COUNT_FIELDS=(
  schema_version
  messenger_conversation_pages_scanned messenger_threads_scanned
  messenger_listed_threads messenger_message_cursor_exhausted_threads
  messenger_structural_unrecoverable_threads
  messenger_unavailable_message_threads messenger_classified_omitted_threads
  messenger_failed_threads messenger_unavailable_message_thread_fingerprint
  messenger_message_pages_scanned messenger_message_ids_scanned
  messenger_out_of_scope_message_ids messenger_already_present
  messenger_candidate_incoming messenger_candidate_outgoing
  messenger_policy_skips messenger_content_unavailable
  messenger_contentless_omissions messenger_attachment_urls_found
  messenger_attachments_unsupported messenger_contacts_created
  messenger_contacts_reused messenger_contact_inboxes_created
  messenger_contact_inboxes_reused messenger_archives_created
  messenger_messages_created messenger_incoming_created
  messenger_outgoing_created messenger_attachments_created
  messenger_active_storage_attachments_created
  messenger_active_storage_blobs_created messenger_attachments_unavailable
  messenger_attachment_bytes messenger_nonempty_archives
  messenger_linked_contacts messenger_linked_contact_inboxes
  messenger_preexisting_importer_archives
  messenger_preexisting_importer_messages
  messenger_preexisting_importer_incoming
  messenger_preexisting_importer_outgoing
  messenger_preexisting_importer_attachments
  messenger_preexisting_linked_contacts
  messenger_preexisting_linked_contact_inboxes
  messenger_total_importer_archives messenger_total_importer_messages
  messenger_total_importer_incoming messenger_total_importer_outgoing
  messenger_total_importer_attachments messenger_stable_profile_targets
  messenger_profile_targets_success
  messenger_profile_targets_unavailable messenger_profile_targets_blocking
  instagram_conversation_pages_scanned instagram_threads_scanned
  instagram_listed_threads instagram_message_cursor_exhausted_threads
  instagram_structural_unrecoverable_threads
  instagram_unavailable_message_threads instagram_classified_omitted_threads
  instagram_failed_threads instagram_unavailable_message_thread_fingerprint
  instagram_message_pages_scanned instagram_message_ids_scanned
  instagram_out_of_scope_message_ids instagram_already_present
  instagram_candidate_incoming instagram_candidate_outgoing
  instagram_policy_skips instagram_content_unavailable
  instagram_contentless_omissions instagram_attachment_urls_found
  instagram_attachments_unsupported instagram_contacts_created
  instagram_contacts_reused instagram_contact_inboxes_created
  instagram_contact_inboxes_reused instagram_archives_created
  instagram_messages_created instagram_incoming_created
  instagram_outgoing_created instagram_attachments_created
  instagram_active_storage_attachments_created
  instagram_active_storage_blobs_created instagram_attachments_unavailable
  instagram_attachment_bytes instagram_nonempty_archives
  instagram_linked_contacts instagram_linked_contact_inboxes
  instagram_preexisting_importer_archives
  instagram_preexisting_importer_messages
  instagram_preexisting_importer_incoming
  instagram_preexisting_importer_outgoing
  instagram_preexisting_importer_attachments
  instagram_preexisting_linked_contacts
  instagram_preexisting_linked_contact_inboxes
  instagram_total_importer_archives instagram_total_importer_messages
  instagram_total_importer_incoming instagram_total_importer_outgoing
  instagram_total_importer_attachments instagram_stable_profile_targets
  instagram_profile_targets_success
  instagram_profile_targets_unavailable instagram_profile_targets_blocking
  profile_seed_targets_sealed
  profile_scalar_changes_applied profile_name_changes_applied
  profile_username_changes_applied profile_optional_changes_applied
  profile_avatars_offered profile_avatars_preserved profile_avatars_attached
  profile_avatars_unavailable profile_avatar_bytes
  profile_seed_targets_repaired profile_seed_targets_preserved
  profile_seed_targets_blank_name profile_seed_targets_blocked
  seed_only_targets importer_only_targets seed_and_importer_targets
  instagram_placeholders_remaining
  instagram_placeholders_remaining_fingerprint
  instagram_placeholders_name_unavailable empty_importer_archives
  unrecoverable_instagram_envelopes profile_mutations_are_aggregate
)
readonly FINAL_MANIFEST_FIELDS=(
  schema_version authorization_mode authorization_sha256 program_sha256
  binding_sha256 candidate_commit
  candidate_image production_database inbox_id acceptance_sha256
  history_approval_sha256 profile_approval_sha256
  pre_history_backup_sha256 history_result_index_sha256
  profile_result_index_sha256 checkpoint_index_sha256 platform_counts_sha256
  live_counts_sha256 release_schema_sha256 messenger_terminal_result_sha256
  instagram_terminal_result_sha256 final_profile_result_sha256
  final_profile_audit_sha256 first_checkpoint_sha256 final_checkpoint_sha256
  unrecoverable_sidecar_sha256 unrecoverable_instagram_envelopes
  profile_mutations_are_aggregate audited_at
)

verify_checksum "$PROGRAM_PATH" "$PROGRAM_CHECKSUM"
verify_checksum "$BINDING_MANIFEST" "$BINDING_CHECKSUM"
require_ordered_manifest "$BINDING_MANIFEST" "${BINDING_FIELDS[@]}"
test "$(manifest_value "$BINDING_MANIFEST" schema_version)" = 1

binding() {
  manifest_value "$BINDING_MANIFEST" "$1"
}

CANDIDATE_COMMIT="$(binding candidate_commit)"
AUTHORIZATION_MODE="$(binding authorization_mode)"
AUTHORIZATION_MANIFEST="$(binding authorization_manifest)"
AUTHORIZATION_CHECKSUM="$(binding authorization_checksum)"
AUTHORIZATION_SHA256="$(binding authorization_sha256)"
CANDIDATE_IMAGE="$(binding candidate_image)"
STACK_DIR="$(binding stack_dir)"
COMPOSE_FILE="$(binding compose_file)"
COMPOSE_FILE_SHA256="$(binding compose_file_sha256)"
COMPOSE_PROJECT="$(binding compose_project)"
RAILS_SERVICE="$(binding rails_service)"
SIDEKIQ_SERVICE="$(binding sidekiq_service)"
PRODUCTION_DATABASE="$(binding production_database)"
AUDIT_ROOT="$(binding audit_root)"
INBOX_ID="$(binding inbox_id)"
ACCEPTANCE_MANIFEST="$(binding acceptance_manifest)"
ACCEPTANCE_CHECKSUM="$(binding acceptance_checksum)"
ACCEPTANCE_SHA256="$(binding acceptance_sha256)"
HISTORY_APPROVAL="$(binding history_approval)"
HISTORY_APPROVAL_CHECKSUM="$(binding history_approval_checksum)"
HISTORY_APPROVAL_SHA256="$(binding history_approval_sha256)"
PROFILE_APPROVAL="$(binding profile_approval)"
PROFILE_APPROVAL_CHECKSUM="$(binding profile_approval_checksum)"
PROFILE_APPROVAL_SHA256="$(binding profile_approval_sha256)"
PROFILE_TARGETS="$(binding profile_targets)"
PROFILE_TARGETS_SHA256="$(binding profile_targets_sha256)"
PROFILE_WRAPPER_SHA256="$(binding profile_wrapper_sha256)"
STORAGE_HELPER_SHA256="$(binding storage_helper_sha256)"
UNRECOVERABLE_SIDECAR="$(binding unrecoverable_sidecar)"
UNRECOVERABLE_SIDECAR_CHECKSUM="$(binding unrecoverable_sidecar_checksum)"
UNRECOVERABLE_SIDECAR_SHA256="$(binding unrecoverable_sidecar_sha256)"
PRE_HISTORY_BACKUP="$(binding pre_history_backup)"
PRE_HISTORY_BACKUP_CHECKSUM="$(binding pre_history_backup_checksum)"
PRE_HISTORY_BACKUP_SHA256="$(binding pre_history_backup_sha256)"
HISTORY_RESULT_INDEX="$(binding history_result_index)"
HISTORY_RESULT_INDEX_CHECKSUM="$(binding history_result_index_checksum)"
HISTORY_RESULT_INDEX_SHA256="$(binding history_result_index_sha256)"
PROFILE_RESULT_INDEX="$(binding profile_result_index)"
PROFILE_RESULT_INDEX_CHECKSUM="$(binding profile_result_index_checksum)"
PROFILE_RESULT_INDEX_SHA256="$(binding profile_result_index_sha256)"
CHECKPOINT_INDEX="$(binding checkpoint_index)"
CHECKPOINT_INDEX_CHECKSUM="$(binding checkpoint_index_checksum)"
CHECKPOINT_INDEX_SHA256="$(binding checkpoint_index_sha256)"
MESSENGER_DRY_1="$(binding messenger_dry_1)"
MESSENGER_DRY_1_CHECKSUM="$(binding messenger_dry_1_checksum)"
MESSENGER_DRY_2="$(binding messenger_dry_2)"
MESSENGER_DRY_2_CHECKSUM="$(binding messenger_dry_2_checksum)"
INSTAGRAM_DRY_1="$(binding instagram_dry_1)"
INSTAGRAM_DRY_1_CHECKSUM="$(binding instagram_dry_1_checksum)"
INSTAGRAM_DRY_2="$(binding instagram_dry_2)"
INSTAGRAM_DRY_2_CHECKSUM="$(binding instagram_dry_2_checksum)"
MESSENGER_TERMINAL_RESULT="$(binding messenger_terminal_result)"
MESSENGER_TERMINAL_CHECKSUM="$(binding messenger_terminal_checksum)"
INSTAGRAM_TERMINAL_RESULT="$(binding instagram_terminal_result)"
INSTAGRAM_TERMINAL_CHECKSUM="$(binding instagram_terminal_checksum)"
FINAL_PROFILE_RESULT="$(binding final_profile_result)"
FINAL_PROFILE_RESULT_CHECKSUM="$(binding final_profile_result_checksum)"
FINAL_PROFILE_AUDIT="$(binding final_profile_audit)"
FINAL_PROFILE_AUDIT_CHECKSUM="$(binding final_profile_audit_checksum)"
FIRST_CHECKPOINT="$(binding first_checkpoint)"
FIRST_CHECKPOINT_CHECKSUM="$(binding first_checkpoint_checksum)"
FINAL_CHECKPOINT="$(binding final_checkpoint)"
FINAL_CHECKPOINT_CHECKSUM="$(binding final_checkpoint_checksum)"
PRODUCTION_LOCK="$(binding production_lock)"
readonly AUTHORIZATION_MODE AUTHORIZATION_MANIFEST AUTHORIZATION_CHECKSUM
readonly AUTHORIZATION_SHA256 CANDIDATE_COMMIT CANDIDATE_IMAGE STACK_DIR COMPOSE_FILE
readonly COMPOSE_FILE_SHA256 COMPOSE_PROJECT RAILS_SERVICE SIDEKIQ_SERVICE
readonly PRODUCTION_DATABASE AUDIT_ROOT INBOX_ID ACCEPTANCE_MANIFEST
readonly ACCEPTANCE_CHECKSUM ACCEPTANCE_SHA256 HISTORY_APPROVAL
readonly HISTORY_APPROVAL_CHECKSUM HISTORY_APPROVAL_SHA256 PROFILE_APPROVAL
readonly PROFILE_APPROVAL_CHECKSUM PROFILE_APPROVAL_SHA256 PROFILE_TARGETS
readonly PROFILE_TARGETS_SHA256 PROFILE_WRAPPER_SHA256 STORAGE_HELPER_SHA256
readonly UNRECOVERABLE_SIDECAR
readonly UNRECOVERABLE_SIDECAR_CHECKSUM UNRECOVERABLE_SIDECAR_SHA256
readonly PRE_HISTORY_BACKUP PRE_HISTORY_BACKUP_CHECKSUM
readonly PRE_HISTORY_BACKUP_SHA256 HISTORY_RESULT_INDEX
readonly HISTORY_RESULT_INDEX_CHECKSUM HISTORY_RESULT_INDEX_SHA256
readonly PROFILE_RESULT_INDEX PROFILE_RESULT_INDEX_CHECKSUM
readonly PROFILE_RESULT_INDEX_SHA256 CHECKPOINT_INDEX CHECKPOINT_INDEX_CHECKSUM
readonly CHECKPOINT_INDEX_SHA256 MESSENGER_DRY_1 MESSENGER_DRY_1_CHECKSUM
readonly MESSENGER_DRY_2 MESSENGER_DRY_2_CHECKSUM INSTAGRAM_DRY_1
readonly INSTAGRAM_DRY_1_CHECKSUM INSTAGRAM_DRY_2 INSTAGRAM_DRY_2_CHECKSUM
readonly MESSENGER_TERMINAL_RESULT MESSENGER_TERMINAL_CHECKSUM
readonly INSTAGRAM_TERMINAL_RESULT INSTAGRAM_TERMINAL_CHECKSUM
readonly FINAL_PROFILE_RESULT FINAL_PROFILE_RESULT_CHECKSUM FINAL_PROFILE_AUDIT
readonly FINAL_PROFILE_AUDIT_CHECKSUM FIRST_CHECKPOINT
readonly FIRST_CHECKPOINT_CHECKSUM FINAL_CHECKPOINT FINAL_CHECKPOINT_CHECKSUM
readonly PRODUCTION_LOCK

[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$CANDIDATE_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]
[[ "$PROFILE_WRAPPER_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$STORAGE_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$AUTHORIZATION_MODE" = clone_authorized ||
  "$AUTHORIZATION_MODE" = production_first ]]
if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
  verify_checksum "$AUTHORIZATION_MANIFEST" "$AUTHORIZATION_CHECKSUM"
  require_ordered_manifest \
    "$AUTHORIZATION_MANIFEST" "${PRODUCTION_FIRST_AUTHORIZATION_FIELDS[@]}"
  test "$(sha256_file "$AUTHORIZATION_MANIFEST")" = "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" authorization_mode)" = production_first
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" repository_commit)" = \
    "$CANDIDATE_COMMIT"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" image_digest)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" production_database)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" final_audit_program_sha256)" = \
    "$(sha256_file "$PROGRAM_PATH")"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" profile_wrapper_sha256)" = \
    "$PROFILE_WRAPPER_SHA256"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" storage_helper_sha256)" = \
    "$STORAGE_HELPER_SHA256"
  test "$ACCEPTANCE_MANIFEST" = none
  test "$ACCEPTANCE_CHECKSUM" = none
  test "$ACCEPTANCE_SHA256" = none
else
  test "$AUTHORIZATION_MANIFEST" = none
  test "$AUTHORIZATION_CHECKSUM" = none
  test "$AUTHORIZATION_SHA256" = none
fi
require_safe_token compose_project "$COMPOSE_PROJECT"
require_safe_token rails_service "$RAILS_SERVICE"
require_safe_token sidekiq_service "$SIDEKIQ_SERVICE"
require_root_directory "$STACK_DIR"
require_root_readonly_file "$COMPOSE_FILE"
test "$(sha256_file "$COMPOSE_FILE")" = "$COMPOSE_FILE_SHA256"
require_root_directory "$AUDIT_ROOT"
artifact_tuples=(
  "$HISTORY_APPROVAL:$HISTORY_APPROVAL_CHECKSUM:$HISTORY_APPROVAL_SHA256" \
  "$PROFILE_APPROVAL:$PROFILE_APPROVAL_CHECKSUM:$PROFILE_APPROVAL_SHA256" \
  "$UNRECOVERABLE_SIDECAR:$UNRECOVERABLE_SIDECAR_CHECKSUM:$UNRECOVERABLE_SIDECAR_SHA256" \
  "$PRE_HISTORY_BACKUP:$PRE_HISTORY_BACKUP_CHECKSUM:$PRE_HISTORY_BACKUP_SHA256" \
  "$HISTORY_RESULT_INDEX:$HISTORY_RESULT_INDEX_CHECKSUM:$HISTORY_RESULT_INDEX_SHA256" \
  "$PROFILE_RESULT_INDEX:$PROFILE_RESULT_INDEX_CHECKSUM:$PROFILE_RESULT_INDEX_SHA256" \
  "$CHECKPOINT_INDEX:$CHECKPOINT_INDEX_CHECKSUM:$CHECKPOINT_INDEX_SHA256"
)
if [[ "$AUTHORIZATION_MODE" = clone_authorized ]]; then
  artifact_tuples+=("$ACCEPTANCE_MANIFEST:$ACCEPTANCE_CHECKSUM:$ACCEPTANCE_SHA256")
fi
for tuple in "${artifact_tuples[@]}"; do
  artifact="${tuple%%:*}"
  remainder="${tuple#*:}"
  checksum="${remainder%%:*}"
  expected_sha="${remainder#*:}"
  verify_checksum "$artifact" "$checksum"
  test "$(sha256_file "$artifact")" = "$expected_sha"
done
require_root_artifact "$PROFILE_TARGETS"
test "$(sha256_file "$PROFILE_TARGETS")" = "$PROFILE_TARGETS_SHA256"
if [[ "$AUTHORIZATION_MODE" = clone_authorized ]]; then
  test "$(manifest_value "$ACCEPTANCE_MANIFEST" candidate_commit)" = \
    "$CANDIDATE_COMMIT"
  test "$(manifest_value "$ACCEPTANCE_MANIFEST" candidate_image)" = \
    "$CANDIDATE_IMAGE"
  test "$(manifest_value "$ACCEPTANCE_MANIFEST" history_approval_sha256)" = \
    "$HISTORY_APPROVAL_SHA256"
  test "$(manifest_value "$ACCEPTANCE_MANIFEST" profile_approval_sha256)" = \
    "$PROFILE_APPROVAL_SHA256"
else
  test "$(manifest_value "$HISTORY_APPROVAL" authorization_mode)" = production_first
  test "$(manifest_value "$HISTORY_APPROVAL" production_first_authorization_sha256)" = \
    "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$PROFILE_APPROVAL" authorization_mode)" = production_first
  test "$(manifest_value "$PROFILE_APPROVAL" production_first_authorization_sha256)" = \
    "$AUTHORIZATION_SHA256"
fi
test "$(manifest_value "$HISTORY_APPROVAL" inbox_id)" = "$INBOX_ID"
test "$(manifest_value "$PROFILE_APPROVAL" inbox_id)" = "$INBOX_ID"

readonly RESULT_DIRECTORY="$AUDIT_ROOT/final-production-audit"
readonly RESULT_MANIFEST="$RESULT_DIRECTORY/fbig-production-migration-audit-v1.tsv"
readonly PLATFORM_COUNTS="$RESULT_DIRECTORY/fbig-production-platform-counts-v1.tsv"
readonly LIVE_COUNTS="$RESULT_DIRECTORY/fbig-production-live-counts-v1.tsv"
readonly RELEASE_SCHEMA="$RESULT_DIRECTORY/production-release-schema.tsv"
readonly PROFILE_ATTEMPT_ROOT='/opt/umi/fbig-profile-attempts'

validate_history_result() {
  local result="$1"
  local checksum="$2"
  local expected_authorization_sha="${3:-$AUTHORIZATION_SHA256}"
  local expected_commit="${4:-$CANDIDATE_COMMIT}"
  local expected_image="${5:-$CANDIDATE_IMAGE}"
  local expected_approval_sha="${6:-$HISTORY_APPROVAL_SHA256}"
  local directory
  local artifact
  local field
  local filename

  verify_checksum "$result" "$checksum"
  require_ordered_manifest "$result" "${HISTORY_RESULT_FIELDS[@]}"
  test "$(manifest_value "$result" authorization_mode)" = "$AUTHORIZATION_MODE"
  test "$(manifest_value "$result" authorization_sha256)" = \
    "$expected_authorization_sha"
  test "$(manifest_value "$result" candidate_commit)" = "$expected_commit"
  test "$(manifest_value "$result" candidate_image)" = "$expected_image"
  test "$(manifest_value "$result" production_database)" = "$PRODUCTION_DATABASE"
  test "$(manifest_value "$result" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$result" acceptance_sha256)" = "$ACCEPTANCE_SHA256"
  test "$(manifest_value "$result" history_approval_sha256)" = \
    "$expected_approval_sha"
  for field in protected_changes deleted_rows unattributed_changes; do
    test "$(manifest_value "$result" "$field")" = 0
  done
  test "$(manifest_value "$result" counter_mismatches)" = none
  directory="$(dirname "$result")"
  for field in compose_override attachment_reconcile_start prestate attachment_reconcile_final poststate delta; do
    case "$field" in
      compose_override) filename=candidate-compose.yml ;;
      attachment_reconcile_start) filename=attachment-reconcile-start.log ;;
      prestate) filename=fbig-history-production-prestate-v1.tsv ;;
      attachment_reconcile_final) filename=attachment-reconcile-final.log ;;
      poststate) filename=fbig-history-production-poststate-v1.tsv ;;
      delta) filename=history-delta.tsv ;;
    esac
    artifact="$directory/$filename"
    verify_checksum "$artifact" "${artifact}.sha256"
    test "$(manifest_value "$result" "${field}_sha256")" = \
      "$(sha256_file "$artifact")"
  done
  if [[ "$(manifest_value "$result" run_summary_sha256)" != none ]]; then
    artifact="$directory/history-summary.tsv"
    verify_checksum "$artifact" "${artifact}.sha256"
    test "$(manifest_value "$result" run_summary_sha256)" = \
      "$(sha256_file "$artifact")"
  fi
  for field in unrecoverable_before unrecoverable_after; do
    artifact="$directory/${field//_/-}.tsv"
    if [[ "$(manifest_value "$result" platforms)" = instagram ]]; then
      verify_checksum "$artifact" "${artifact}.sha256"
      test "$(manifest_value "$result" "${field}_sha256")" = \
        "$(sha256_file "$artifact")"
    else
      test "$(manifest_value "$result" "${field}_sha256")" = none
      test ! -e "$artifact"
      test ! -e "${artifact}.sha256"
    fi
  done
}

validate_production_history_pair() {
  local result="$1"
  local authorization="$2"
  local expected_authorization_sha="$3"
  local approval="$4"
  local expected_approval_sha="$5"
  local field
  verify_checksum "$authorization" "${authorization}.sha256"
  require_ordered_manifest \
    "$authorization" "${PRODUCTION_FIRST_AUTHORIZATION_FIELDS[@]}"
  test "$(sha256_file "$authorization")" = "$expected_authorization_sha"
  test "$(manifest_value "$authorization" authorization_mode)" = production_first
  test "$(manifest_value "$authorization" production_database)" = "$PRODUCTION_DATABASE"
  test "$(manifest_value "$authorization" inbox_id)" = "$INBOX_ID"

  verify_checksum "$approval" "${approval}.sha256"
  require_ordered_manifest \
    "$approval" "${PRODUCTION_FIRST_HISTORY_APPROVAL_FIELDS[@]}"
  test "$(sha256_file "$approval")" = "$expected_approval_sha"
  test "$(manifest_value "$approval" authorization_mode)" = production_first
  test "$(manifest_value "$approval" production_first_authorization_sha256)" = \
    "$expected_authorization_sha"

  validate_history_result \
    "$result" "${result}.sha256" "$expected_authorization_sha" \
    "$(manifest_value "$authorization" repository_commit)" \
    "$(manifest_value "$authorization" image_digest)" "$expected_approval_sha"
  test "$(manifest_value "$result" pre_history_backup_sha256)" = \
    "$(manifest_value "$approval" coordinated_backup_manifest_sha256)"
  test "$(manifest_value "$result" program_sha256)" = \
    "$(manifest_value "$authorization" history_program_sha256)"

  for field in \
    repository_commit image_digest production_database account_id inbox_id \
    facebook_page_id instagram_business_id since before outbound_policy \
    profile_mode coordinated_backup_manifest_sha256 \
    recovered_thread_targets_sha256 placeholder_targets_sha256 \
    unrecoverable_sidecar_sha256 \
    messenger_unavailable_message_thread_count \
    messenger_unavailable_message_thread_fingerprint \
    instagram_unavailable_message_thread_count \
    instagram_unavailable_message_thread_fingerprint \
    r2_acceptance_binding_sha256 r2_launch_manifest_sha256 \
    r2_probe_log_sha256 r2_probe_summary_sha256; do
    test "$(manifest_value "$approval" "$field")" = \
      "$(manifest_value "$authorization" "$field")"
  done

  validate_production_first_contentless_relation "$authorization" "$approval"
}

validate_profile_result() {
  local result="$1"
  local checksum="$2"
  local attempt_directory
  local attempt_manifest
  local run_log
  local summary

  verify_checksum "$result" "$checksum"
  require_ordered_manifest "$result" "${PROFILE_RESULT_FIELDS[@]}"
  test "$(manifest_value "$result" authorization_mode)" = "$AUTHORIZATION_MODE"
  test "$(manifest_value "$result" authorization_sha256)" = "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$result" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$result" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$result" production_database)" = "$PRODUCTION_DATABASE"
  test "$(manifest_value "$result" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$result" acceptance_sha256)" = "$ACCEPTANCE_SHA256"
  test "$(manifest_value "$result" profile_approval_sha256)" = \
    "$PROFILE_APPROVAL_SHA256"
  test "$(manifest_value "$result" profile_wrapper_sha256)" = \
    "$PROFILE_WRAPPER_SHA256"
  test "$(manifest_value "$result" storage_helper_sha256)" = \
    "$STORAGE_HELPER_SHA256"
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    test "$(manifest_value "$result" program_sha256)" = \
      "$(manifest_value "$AUTHORIZATION_MANIFEST" profile_program_sha256)"
  fi
  attempt_directory="$(manifest_value "$result" attempt_directory)"
  test "$attempt_directory" = "$(realpath -e -- "$attempt_directory")"
  test "$(dirname "$attempt_directory")" = "$PROFILE_ATTEMPT_ROOT"
  test ! -L "$attempt_directory"
  require_root_directory "$PROFILE_ATTEMPT_ROOT"
  require_root_directory "$attempt_directory"
  attempt_manifest="$attempt_directory/fbig-profile-production-attempt-v1.tsv"
  run_log="$attempt_directory/fbig-profile-production-run.log"
  summary="$attempt_directory/fbig-profile-production-run-summary.tsv"
  verify_checksum "$attempt_manifest" "${attempt_manifest}.sha256"
  require_ordered_manifest "$attempt_manifest" "${PROFILE_ATTEMPT_FIELDS[@]}"
  test "$(manifest_value "$result" attempt_manifest_sha256)" = \
    "$(sha256_file "$attempt_manifest")"
  test "$(manifest_value "$attempt_manifest" schema_version)" = 1
  test "$(manifest_value "$attempt_manifest" profile_approval_sha256)" = \
    "$PROFILE_APPROVAL_SHA256"
  test "$(manifest_value "$attempt_manifest" image_digest)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$attempt_manifest" production_database_name)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$attempt_manifest" platforms)" = \
    "$(manifest_value "$result" platforms)"
  test "$(manifest_value "$attempt_manifest" dry_run)" = \
    "$(manifest_value "$result" dry_run)"
  test "$(manifest_value "$attempt_manifest" exit_status)" = 0
  require_root_artifact "$run_log"
  require_root_artifact "$summary"
  test "$(manifest_value "$attempt_manifest" run_log_sha256)" = \
    "$(sha256_file "$run_log")"
  test "$(manifest_value "$attempt_manifest" run_summary_sha256)" = \
    "$(sha256_file "$summary")"
  verify_seed_target_conservation "$run_log" "$summary"
}

validate_profile_audit() {
  local audit="$1"
  local checksum="$2"

  verify_checksum "$audit" "$checksum"
  require_ordered_manifest "$audit" "${PROFILE_AUDIT_FIELDS[@]}"
  test "$(manifest_value "$audit" authorization_mode)" = "$AUTHORIZATION_MODE"
  test "$(manifest_value "$audit" authorization_sha256)" = "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$audit" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$audit" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$audit" acceptance_sha256)" = "$ACCEPTANCE_SHA256"
  test "$(manifest_value "$audit" zero_unrecovered_deliveries)" = true
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    test "$(manifest_value "$audit" program_sha256)" = \
      "$(manifest_value "$AUTHORIZATION_MANIFEST" delivery_audit_program_sha256)"
  fi
}

validate_checkpoint() {
  local checkpoint="$1"
  local checksum="$2"
  local field
  local identity_manifest

  verify_checksum "$checkpoint" "$checksum"
  require_ordered_manifest "$checkpoint" "${CHECKPOINT_FIELDS[@]}"
  test "$(manifest_value "$checkpoint" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$checkpoint" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$checkpoint" production_database)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$checkpoint" inbox_id)" = "$INBOX_ID"
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    test "$(manifest_value "$checkpoint" program_sha256)" = \
      "$(manifest_value "$AUTHORIZATION_MANIFEST" delivery_checkpoint_program_sha256)"
  fi
  test "$(manifest_value "$checkpoint" service_source_sha256)" = \
    "$(manifest_value "$FIRST_CHECKPOINT" service_source_sha256)"
  test "$(manifest_value "$checkpoint" running_rails_commit)" = \
    "$CANDIDATE_COMMIT"
  test "$(manifest_value "$checkpoint" running_sidekiq_commit)" = \
    "$CANDIDATE_COMMIT"
  [[ "$(manifest_value "$checkpoint" running_rails_image_id)" =~ \
    ^sha256:[0-9a-f]{64}$ ]]
  [[ "$(manifest_value "$checkpoint" running_sidekiq_image_id)" =~ \
    ^sha256:[0-9a-f]{64}$ ]]
  test "$(manifest_value "$checkpoint" running_rails_service_source_sha256)" = \
    "$(manifest_value "$checkpoint" service_source_sha256)"
  candidate_image_matches_container \
    "$(manifest_value "$checkpoint" running_rails_image_id)"
  candidate_image_matches_container \
    "$(manifest_value "$checkpoint" running_sidekiq_image_id)"
  identity_manifest="$ACCEPTANCE_MANIFEST"
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    identity_manifest="$AUTHORIZATION_MANIFEST"
  fi
  test "$(manifest_value "$checkpoint" page_identity_sha256)" = "$(
    printf '%s' "$(manifest_value "$identity_manifest" facebook_page_id)" |
      sha256sum | awk '{ print $1 }'
  )"
  test "$(manifest_value "$checkpoint" instagram_identity_sha256)" = "$(
    printf '%s' "$(manifest_value "$identity_manifest" instagram_business_id)" |
      sha256sum | awk '{ print $1 }'
  )"
  for field in \
    messenger_missing instagram_missing messenger_threads_failed \
    instagram_threads_failed messenger_caps_hit instagram_caps_hit; do
    test "$(manifest_value "$checkpoint" "$field")" = 0
  done
}

candidate_image_matches_container() {
  local image_id="$1"

  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "$image_id" | grep -Fxq -- "$CANDIDATE_IMAGE"
}

validate_terminal_result() {
  local result="$1"
  local checksum="$2"
  local platform="$3"
  local result_sha

  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    verify_checksum "$result" "$checksum"
    require_ordered_manifest "$result" "${HISTORY_RESULT_FIELDS[@]}"
    result_sha="$(sha256_file "$result")"
    test -n "${RESULT_AUTHORIZATION_SHA["$result_sha"]:-}"
    test -n "${RESULT_APPROVAL_SHA["$result_sha"]:-}"
  else
    validate_history_result "$result" "$checksum"
  fi
  test "$(manifest_value "$result" operation)" = apply
  test "$(manifest_value "$result" platforms)" = "$platform"
  test "$(manifest_value "$result" require_zero_writes)" = true
  test "$(manifest_value "$result" zero_write_observed)" = true
  test "$(manifest_value "$result" exit_status)" = 0
  test "$(manifest_value "$result" termination)" = normal
}

dry_pair_sha() {
  local platform="$1"
  local first="$2"
  local second="$3"

  printf '%s\n%s\n%s\n' \
    "$platform" "$(sha256_file "$first")" "$(sha256_file "$second")" |
    sha256sum --binary | awk '{ print $1 }'
}

validate_terminal_summary() {
  local result="$1"
  local platform="$2"
  local summary
  local in_scope
  local already_present
  local candidate_incoming
  local candidate_outbound
  local outbound_import
  local outbound_skip
  local imported_messages
  local imported_incoming
  local imported_outgoing
  local late_already_present
  local contentless
  local expected_structural=0
  local unavailable
  local classified
  local failed
  local listed
  local cursor_exhausted
  local counter

  summary="$(dirname "$result")/history-summary.tsv"
  in_scope="$(stage_value "$summary" history_import_summary in_scope_mids_scanned)"
  already_present="$(stage_value "$summary" history_import_summary already_present)"
  candidate_incoming="$(stage_value "$summary" history_import_summary candidate_incoming)"
  candidate_outbound="$(stage_value "$summary" history_import_summary candidate_outbound)"
  outbound_import="$(
    stage_value "$summary" history_import_summary outbound_pre_presence_import
  )"
  outbound_skip="$(
    stage_value "$summary" history_import_summary outbound_pre_presence_skip
  )"
  imported_messages="$(stage_value "$summary" history_import_summary imported_messages)"
  imported_incoming="$(stage_value "$summary" history_import_summary imported_incoming)"
  imported_outgoing="$(stage_value "$summary" history_import_summary imported_outgoing)"
  late_already_present="$(
    stage_value "$summary" history_import_summary late_already_present
  )"
  contentless="$(
    stage_value "$summary" history_import_summary "${platform}_contentless_details"
  )"
  if test "$platform" = instagram; then
    expected_structural="$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  fi
  unavailable="$(
    manifest_value "$HISTORY_APPROVAL" "${platform}_unavailable_message_thread_count"
  )"
  classified="$(stage_value "$summary" history_import_summary classified_omitted_threads)"
  failed="$(stage_value "$summary" history_import_summary failed_threads)"
  listed="$(stage_value "$summary" history_import_summary listed_threads)"
  cursor_exhausted="$(
    stage_value "$summary" history_import_summary message_cursor_exhausted_threads
  )"
  test "$in_scope" = \
    "$((already_present + candidate_incoming + candidate_outbound))"
  test "$candidate_outbound" = "$((outbound_import + outbound_skip))"
  test "$((candidate_incoming + outbound_import))" = \
    "$((imported_messages + late_already_present + contentless))"
  test "$imported_messages" = "$((imported_incoming + imported_outgoing))"
  test "$(stage_value "$summary" history_import_summary content_unavailable)" = \
    "$contentless"
  test "$(stage_value "$summary" history_import_summary structural_unrecoverable_threads)" = \
    "$expected_structural"
  test "$(stage_value "$summary" history_import_summary ambiguous_participants)" = \
    "$expected_structural"
  test "$(stage_value "$summary" history_import_summary unavailable_message_threads)" = \
    "$unavailable"
  test "$(stage_value "$summary" history_import_summary \
    "${platform}_unavailable_message_thread_fingerprint")" = \
    "$(manifest_value "$HISTORY_APPROVAL" \
      "${platform}_unavailable_message_thread_fingerprint")"
  test "$(stage_value "$summary" history_import_summary "${platform}_listed_threads")" = \
    "$listed"
  test "$(stage_value "$summary" history_import_summary \
    "${platform}_message_cursor_exhausted_threads")" = "$cursor_exhausted"
  test "$(stage_value "$summary" history_import_summary \
    "${platform}_structural_unrecoverable_threads")" = "$expected_structural"
  test "$(stage_value "$summary" history_import_summary \
    "${platform}_unavailable_message_threads")" = "$unavailable"
  test "$(stage_value "$summary" history_import_summary \
    "${platform}_classified_omitted_threads")" = "$classified"
  test "$(stage_value "$summary" history_import_summary "${platform}_failed_threads")" = \
    "$failed"
  test "$classified" -eq "$((expected_structural + unavailable))"
  test "$failed" = 0
  test "$listed" -eq "$((cursor_exhausted + classified + failed))"
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    local recovered_expected=0
    local recovered_sha=none
    if [[ "$platform" = instagram ]]; then
      recovered_expected=2
      recovered_sha="$(manifest_value "$HISTORY_APPROVAL" recovered_thread_targets_sha256)"
    fi
    test "$(stage_value "$summary" history_import_summary recovered_thread_targets_sha256)" = \
      "$recovered_sha"
    test "$(stage_value "$summary" history_import_summary recovered_targets_expected)" = \
      "$recovered_expected"
    test "$(stage_value "$summary" history_import_summary recovered_targets_listed)" = \
      "$recovered_expected"
    test "$(stage_value "$summary" history_import_summary recovered_targets_message_cursor_exhausted)" = \
      "$recovered_expected"
    test "$(stage_value "$summary" history_import_summary recovered_target_mismatches)" = 0
    test "$(stage_value "$summary" history_import_summary recovered_target_duplicate_listings)" = 0
  fi
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = true
  for counter in \
    imported_contacts imported_archives imported_incoming imported_outgoing \
    imported_messages imported_attachments marker_normalizations \
    history_evidence_changes_applied profile_changes_applied avatars_attached \
    avatars_raced contentless_acceptance_mismatches \
    unavailable_message_thread_acceptance_mismatches ambiguous_senders \
    partially_paginated_threads uncategorized_threads \
    foreign_source_id_anomalies platform_failures retry_exhaustion \
    authentication_failures lock_loss reindex_failures \
    download_budget_exhaustions exit_failures; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done
}

validate_history_platform_transition() {
  local predecessor="$1"
  local successor="$2"
  local predecessor_platform
  local successor_platform

  predecessor_platform="$(manifest_value "$predecessor" platforms)"
  successor_platform="$(manifest_value "$successor" platforms)"
  [[ "$predecessor_platform" = messenger && "$successor_platform" = instagram ]] ||
    die "production-first history platform transition is invalid"
  validate_terminal_result "$predecessor" "${predecessor}.sha256" messenger
  validate_terminal_summary "$predecessor" messenger
}

history_state_content_sha256() {
  local snapshot="$1"

  awk -F '\t' '
    NR == 5 {
      if (NF != 2 || $1 != "captured_at") exit 1
      next
    }
    NR == 6 {
      if (NF != 2 || $1 != "row_count") exit 1
      print "row_count\tplatform-owned"
      next
    }
    $1 == "contact" || $1 == "contact_inbox" { next }
    { print }
  ' "$snapshot" | sha256sum --binary | awk '{ print $1 }'
}

validate_final_manifest() {
  local manifest="$1"

  verify_checksum "$manifest" "${manifest}.sha256"
  require_ordered_manifest "$manifest" "${FINAL_MANIFEST_FIELDS[@]}"
  test "$(manifest_value "$manifest" authorization_mode)" = "$AUTHORIZATION_MODE"
  test "$(manifest_value "$manifest" authorization_sha256)" = "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$manifest" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$manifest" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$manifest" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$manifest" platform_counts_sha256)" = \
    "$(sha256_file "$PLATFORM_COUNTS")"
  test "$(manifest_value "$manifest" live_counts_sha256)" = \
    "$(sha256_file "$LIVE_COUNTS")"
  test "$(manifest_value "$manifest" release_schema_sha256)" = \
    "$(sha256_file "$RELEASE_SCHEMA")"
}

if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_final_manifest "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=production_migration_audit_validated manifest=%s\n' \
    "$RESULT_MANIFEST"
  exit 0
fi

acquire_descriptor_verified_lock "$PRODUCTION_LOCK"
[[ ! -e "$RESULT_DIRECTORY" ]]
readonly STAGING_DIRECTORY="$AUDIT_ROOT/.final-production-audit.in-progress"
[[ ! -e "$STAGING_DIRECTORY" ]]
mkdir "$STAGING_DIRECTORY"
chmod 0700 "$STAGING_DIRECTORY"
readonly LIVE_COUNTS_TEMP="$STAGING_DIRECTORY/fbig-production-live-counts-v1.tsv"

MESSENGER_DRY_PAIR_SHA=none
INSTAGRAM_DRY_PAIR_SHA=none
if [[ "$AUTHORIZATION_MODE" = clone_authorized ]]; then
  validate_history_result "$MESSENGER_DRY_1" "$MESSENGER_DRY_1_CHECKSUM"
  validate_history_result "$MESSENGER_DRY_2" "$MESSENGER_DRY_2_CHECKSUM"
  validate_history_result "$INSTAGRAM_DRY_1" "$INSTAGRAM_DRY_1_CHECKSUM"
  validate_history_result "$INSTAGRAM_DRY_2" "$INSTAGRAM_DRY_2_CHECKSUM"
  for result in "$MESSENGER_DRY_1" "$MESSENGER_DRY_2"; do
    test "$(manifest_value "$result" operation)" = dry
    test "$(manifest_value "$result" platforms)" = messenger
    test "$(manifest_value "$result" require_zero_writes)" = true
    test "$(manifest_value "$result" zero_write_observed)" = true
    test "$(manifest_value "$result" exit_status)" = 0
    test "$(manifest_value "$result" termination)" = normal
    test "$(manifest_value "$result" pre_history_backup_sha256)" = none
    test "$(manifest_value "$result" dry_pair_sha256)" = none
  done
  for result in "$INSTAGRAM_DRY_1" "$INSTAGRAM_DRY_2"; do
    test "$(manifest_value "$result" operation)" = dry
    test "$(manifest_value "$result" platforms)" = instagram
    test "$(manifest_value "$result" require_zero_writes)" = true
    test "$(manifest_value "$result" zero_write_observed)" = true
    test "$(manifest_value "$result" exit_status)" = 0
    test "$(manifest_value "$result" termination)" = normal
    test "$(manifest_value "$result" pre_history_backup_sha256)" = none
    test "$(manifest_value "$result" dry_pair_sha256)" = none
  done
  cmp -s \
    "$(dirname "$MESSENGER_DRY_1")/history-summary.tsv" \
    "$(dirname "$MESSENGER_DRY_2")/history-summary.tsv"
  cmp -s \
    "$(dirname "$INSTAGRAM_DRY_1")/history-summary.tsv" \
    "$(dirname "$INSTAGRAM_DRY_2")/history-summary.tsv"
  MESSENGER_DRY_PAIR_SHA="$(
    dry_pair_sha messenger "$MESSENGER_DRY_1" "$MESSENGER_DRY_2"
  )"
  INSTAGRAM_DRY_PAIR_SHA="$(
    dry_pair_sha instagram "$INSTAGRAM_DRY_1" "$INSTAGRAM_DRY_2"
  )"
else
  test "$MESSENGER_DRY_1" = none
  test "$MESSENGER_DRY_1_CHECKSUM" = none
  test "$MESSENGER_DRY_2" = none
  test "$MESSENGER_DRY_2_CHECKSUM" = none
  test "$INSTAGRAM_DRY_1" = none
  test "$INSTAGRAM_DRY_1_CHECKSUM" = none
  test "$INSTAGRAM_DRY_2" = none
  test "$INSTAGRAM_DRY_2_CHECKSUM" = none
fi
readonly MESSENGER_DRY_PAIR_SHA INSTAGRAM_DRY_PAIR_SHA

declare -A HISTORY_TOTALS=()
history_delta_fields=(
  contacts_created contacts_reused contact_inboxes_created
  contact_inboxes_reused archives_created messages_created incoming_created
  outgoing_created attachments_created active_storage_attachments_created
  active_storage_blobs_created
)
for platform in messenger instagram; do
  for field in "${history_delta_fields[@]}"; do
    HISTORY_TOTALS["$platform:$field"]=0
  done
done

history_sequence=0
previous_history_sha=none
previous_authorization_sha=none
previous_approval_sha=none
previous_approval=none
declare -A PREVIOUS_HISTORY_POST=([messenger]=none [instagram]=none)
declare -A FIRST_HISTORY_PRE=([messenger]=none [instagram]=none)
declare -A FIRST_HISTORY_SUMMARY=([messenger]=none [instagram]=none)
declare -A RESULT_AUTHORIZATION_SHA=()
declare -A RESULT_APPROVAL_SHA=()
last_messenger_result=none
last_instagram_result=none
while IFS= read -r history_index_row; do
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    IFS=$'\t' read -r sequence result expected_sha authorization authorization_sha approval approval_sha extra \
      <<<"$history_index_row"
    test -z "$extra"
    test -n "$approval_sha" ||
      die "production-first history index must contain the complete chain"
  else
    IFS=$'\t' read -r sequence result expected_sha extra <<<"$history_index_row"
    test -z "$extra"
    authorization=none
    authorization_sha=none
    approval=none
    approval_sha="$HISTORY_APPROVAL_SHA256"
  fi
  history_sequence=$((history_sequence + 1))
  test "$sequence" = "$history_sequence"
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    validate_production_history_pair \
      "$result" "$authorization" "$authorization_sha" "$approval" "$approval_sha"
    if [[ "$previous_authorization_sha" = none ]]; then
      test "$(manifest_value "$authorization" predecessor_authorization_sha256)" = none ||
        die "production-first history index must contain the complete chain"
      test "$(manifest_value "$approval" revision_platform)" = none
      for field in \
        predecessor_approval_sha256 predecessor_attempt_result_sha256 \
        predecessor_run_summary_sha256 predecessor_delta_sha256; do
        test "$(manifest_value "$approval" "$field")" = none
      done
      test "$(manifest_value "$result" platforms)" = messenger
    elif [[ "$authorization_sha" != "$previous_authorization_sha" ]]; then
      test "$(manifest_value "$authorization" predecessor_authorization_sha256)" = \
        "$previous_authorization_sha"
      test "$(manifest_value "$authorization" predecessor_history_result_sha256)" = \
        "$previous_history_sha"
      test "$(manifest_value "$result" platforms)" = \
        "$(manifest_value "$previous_result" platforms)"
      predecessor_summary="$(dirname "$previous_result")/history-summary.tsv"
      predecessor_delta="$(dirname "$previous_result")/history-delta.tsv"
      predecessor_poststate="$(
        dirname "$previous_result"
      )/fbig-history-production-poststate-v1.tsv"
      verify_checksum "$predecessor_summary" "${predecessor_summary}.sha256"
      verify_checksum "$predecessor_delta" "${predecessor_delta}.sha256"
      verify_checksum "$predecessor_poststate" "${predecessor_poststate}.sha256"
      test "$(manifest_value "$authorization" predecessor_terminal_summary_sha256)" = \
        "$(sha256_file "$predecessor_summary")"
      test "$(manifest_value "$authorization" predecessor_delta_sha256)" = \
        "$(sha256_file "$predecessor_delta")"
      test "$(manifest_value "$authorization" predecessor_expanded_baseline_sha256)" = \
        "$(sha256_file "$predecessor_poststate")"
      test "$(manifest_value "$authorization" current_state_backup_sha256)" = \
        "$(manifest_value "$approval" coordinated_backup_manifest_sha256)"
      test "$(manifest_value "$authorization" current_state_backup_sha256)" != none
      test "$(manifest_value "$previous_result" protected_changes)" = 0
      test "$(manifest_value "$previous_result" deleted_rows)" = 0
      test "$(manifest_value "$previous_result" unattributed_changes)" = 0
      test "$(manifest_value "$previous_result" counter_mismatches)" = none
      revision_platform="$(manifest_value "$approval" revision_platform)"
      if [[ "$revision_platform" = none ]]; then
        for field in \
          predecessor_approval_sha256 predecessor_attempt_result_sha256 \
          predecessor_run_summary_sha256 predecessor_delta_sha256; do
          test "$(manifest_value "$approval" "$field")" = none
        done
      else
        for suffix in count fingerprint; do
          test "$(manifest_value "$approval" "${revision_platform}_${suffix}")" = \
            "$(manifest_value "$authorization" "${revision_platform}_${suffix}")"
        done
        for platform in messenger instagram; do
          if [[ "$platform" != "$revision_platform" ]]; then
            for suffix in count fingerprint; do
              test "$(manifest_value "$approval" "${platform}_${suffix}")" = \
                "$(manifest_value "$previous_approval" "${platform}_${suffix}")"
            done
          fi
        done
        test "$(manifest_value "$result" platforms)" = "$revision_platform"
        test "$(manifest_value "$previous_result" platforms)" = \
          "$revision_platform"
        test "$(manifest_value "$approval" predecessor_approval_sha256)" = \
          "$previous_approval_sha"
        test "$(manifest_value "$approval" predecessor_attempt_result_sha256)" = \
          "$previous_history_sha"
        test "$(manifest_value "$approval" predecessor_run_summary_sha256)" = \
          "$(sha256_file "$predecessor_summary")"
        test "$(manifest_value "$approval" predecessor_delta_sha256)" = \
          "$(sha256_file "$predecessor_delta")"
        test "$(manifest_value "$approval" "${revision_platform}_count")" = \
          "$(stage_value "$predecessor_summary" history_import_summary \
            "${revision_platform}_contentless_details")"
        test "$(manifest_value "$approval" "${revision_platform}_fingerprint")" = \
          "$(stage_value "$predecessor_summary" history_import_summary \
            "${revision_platform}_contentless_fingerprint")"
        test "$(stage_value "$predecessor_summary" history_import_summary \
          contentless_acceptance_mismatches)" = 1
        test "$(manifest_value "$previous_result" exit_status)" = 1
        test "$(manifest_value "$previous_result" termination)" = normal
      fi
    elif [[ "$approval_sha" != "$previous_approval_sha" ]]; then
      test "$(manifest_value "$approval" revision_platform)" != none
      revision_platform="$(manifest_value "$approval" revision_platform)"
      if [[
        "$(manifest_value "$approval" "${revision_platform}_count")" = \
          "$(manifest_value "$authorization" "${revision_platform}_count")" &&
        "$(manifest_value "$approval" "${revision_platform}_fingerprint")" = \
          "$(manifest_value "$authorization" "${revision_platform}_fingerprint")"
      ]]; then
        die "same-release history revision must change its selected contentless pair"
      fi
      predecessor_summary="$(dirname "$previous_result")/history-summary.tsv"
      predecessor_delta="$(dirname "$previous_result")/history-delta.tsv"
      verify_checksum "$predecessor_summary" "${predecessor_summary}.sha256"
      verify_checksum "$predecessor_delta" "${predecessor_delta}.sha256"
      test "$(manifest_value "$result" platforms)" = \
        "$revision_platform"
      test "$(manifest_value "$previous_result" platforms)" = \
        "$revision_platform"
      test "$(manifest_value "$approval" predecessor_approval_sha256)" = \
        "$previous_approval_sha"
      test "$(manifest_value "$approval" predecessor_attempt_result_sha256)" = \
        "$previous_history_sha"
      test "$(manifest_value "$approval" predecessor_run_summary_sha256)" = \
        "$(sha256_file "$predecessor_summary")"
      test "$(manifest_value "$approval" predecessor_delta_sha256)" = \
        "$(sha256_file "$predecessor_delta")"
      test "$(manifest_value "$approval" "${revision_platform}_count")" = \
        "$(stage_value "$predecessor_summary" history_import_summary \
          "${revision_platform}_contentless_details")"
      test "$(manifest_value "$approval" "${revision_platform}_fingerprint")" = \
        "$(stage_value "$predecessor_summary" history_import_summary \
          "${revision_platform}_contentless_fingerprint")"
      test "$(stage_value "$predecessor_summary" history_import_summary \
        contentless_acceptance_mismatches)" = 1
      test "$(manifest_value "$previous_result" exit_status)" = 1
      test "$(manifest_value "$previous_result" termination)" = normal
    elif [[ "$(manifest_value "$result" platforms)" != \
      "$(manifest_value "$previous_result" platforms)" ]]; then
      validate_history_platform_transition "$previous_result" "$result"
    fi
  else
    validate_history_result "$result" "${result}.sha256"
  fi
  test "$(sha256_file "$result")" = "$expected_sha"
  test "$(manifest_value "$result" predecessor_result_sha256)" = \
    "$previous_history_sha" ||
    die "production-first history index must contain the complete chain"
  selected_platform="$(manifest_value "$result" platforms)"
  [[ "$selected_platform" =~ ^(messenger|instagram)$ ]]
  current_pre="$(dirname "$result")/fbig-history-production-prestate-v1.tsv"
  current_post="$(dirname "$result")/fbig-history-production-poststate-v1.tsv"
  current_summary="$(dirname "$result")/history-summary.tsv"
  if [[ "${PREVIOUS_HISTORY_POST["$selected_platform"]}" = none ]]; then
    FIRST_HISTORY_PRE["$selected_platform"]="$current_pre"
  else
    test "$(
      history_state_content_sha256 "${PREVIOUS_HISTORY_POST["$selected_platform"]}"
    )" = "$(history_state_content_sha256 "$current_pre")"
  fi
  if [[ "${FIRST_HISTORY_SUMMARY["$selected_platform"]}" = none &&
    "$(manifest_value "$result" run_summary_sha256)" != none &&
    "$(stage_value "$current_summary" history_import_summary scan_complete)" = true &&
    "$(stage_value "$current_summary" history_import_summary failed_threads)" = 0 &&
    "$(stage_value "$current_summary" history_import_summary partially_paginated_threads)" = 0 ]]; then
    FIRST_HISTORY_SUMMARY["$selected_platform"]="$current_summary"
  fi
  if [[ "$(manifest_value "$result" operation)" = apply ]]; then
    if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
      test "$(manifest_value "$result" dry_pair_sha256)" = none
    elif [[ "$selected_platform" = messenger ]]; then
      test "$(manifest_value "$result" dry_pair_sha256)" = "$MESSENGER_DRY_PAIR_SHA"
    else
      test "$(manifest_value "$result" dry_pair_sha256)" = "$INSTAGRAM_DRY_PAIR_SHA"
    fi
    for platform in messenger instagram; do
      if [[ ",$(manifest_value "$result" platforms)," = *",$platform,"* ]]; then
        for field in "${history_delta_fields[@]}"; do
          current="${HISTORY_TOTALS["$platform:$field"]}"
          delta="$(manifest_value "$result" "${platform}_${field}")"
          HISTORY_TOTALS["$platform:$field"]=$((current + delta))
        done
      fi
    done
  else
    test "$(manifest_value "$result" dry_pair_sha256)" = none
  fi
  [[ ",$(manifest_value "$result" platforms)," != *,messenger,* ]] ||
    last_messenger_result="$expected_sha"
  [[ ",$(manifest_value "$result" platforms)," != *,instagram,* ]] ||
    last_instagram_result="$expected_sha"
  RESULT_AUTHORIZATION_SHA["$expected_sha"]="$authorization_sha"
  RESULT_APPROVAL_SHA["$expected_sha"]="$approval_sha"
  previous_result="$result"
  previous_history_sha="$expected_sha"
  previous_authorization_sha="$authorization_sha"
  previous_approval_sha="$approval_sha"
  previous_approval="$approval"
  PREVIOUS_HISTORY_POST["$selected_platform"]="$current_post"
done <"$HISTORY_RESULT_INDEX"
test "$history_sequence" -gt 0
test "${FIRST_HISTORY_PRE[messenger]}" != none
test "${FIRST_HISTORY_PRE[instagram]}" != none
test "${FIRST_HISTORY_SUMMARY[messenger]}" != none
test "${FIRST_HISTORY_SUMMARY[instagram]}" != none
test "$last_messenger_result" = "$(sha256_file "$MESSENGER_TERMINAL_RESULT")"
test "$last_instagram_result" = "$(sha256_file "$INSTAGRAM_TERMINAL_RESULT")"
if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
  test "$previous_authorization_sha" = "$AUTHORIZATION_SHA256"
  test "$previous_approval_sha" = "$HISTORY_APPROVAL_SHA256"
  test "${RESULT_AUTHORIZATION_SHA["$last_instagram_result"]}" = "$AUTHORIZATION_SHA256"
  test "${RESULT_APPROVAL_SHA["$last_instagram_result"]}" = "$HISTORY_APPROVAL_SHA256"
fi
validate_terminal_result \
  "$MESSENGER_TERMINAL_RESULT" "$MESSENGER_TERMINAL_CHECKSUM" messenger
validate_terminal_result \
  "$INSTAGRAM_TERMINAL_RESULT" "$INSTAGRAM_TERMINAL_CHECKSUM" instagram
validate_terminal_summary "$MESSENGER_TERMINAL_RESULT" messenger
validate_terminal_summary "$INSTAGRAM_TERMINAL_RESULT" instagram

declare -A PROFILE_TOTALS=()
profile_sum_fields=(
  scalar_changes_applied name_changes_applied username_changes_applied
  optional_changes_applied avatars_offered avatars_preserved avatars_attached
  avatars_unavailable avatar_bytes seed_targets_repaired seed_targets_preserved
  seed_targets_blank_name seed_targets_blocked
)
for field in "${profile_sum_fields[@]}"; do
  PROFILE_TOTALS["$field"]=0
done
profile_sequence=0
previous_profile_result_sha=none
previous_profile_audit_sha=none
last_profile_result=none
last_profile_audit=none
while IFS=$'\t' read -r sequence result result_sha audit audit_sha extra; do
  test -z "$extra"
  profile_sequence=$((profile_sequence + 1))
  test "$sequence" = "$profile_sequence"
  validate_profile_result "$result" "${result}.sha256"
  validate_profile_audit "$audit" "${audit}.sha256"
  test "$(sha256_file "$result")" = "$result_sha"
  test "$(sha256_file "$audit")" = "$audit_sha"
  test "$(manifest_value "$result" predecessor_result_sha256)" = \
    "$previous_profile_result_sha"
  test "$(manifest_value "$result" predecessor_audit_sha256)" = \
    "$previous_profile_audit_sha"
  test "$(manifest_value "$audit" predecessor_audit_sha256)" = \
    "$previous_profile_audit_sha"
  test "$(manifest_value "$audit" attempt_result_sha256)" = "$result_sha"
  test "$(manifest_value "$audit" before_checkpoint_sha256)" = \
    "$(manifest_value "$result" before_checkpoint_sha256)"
  summary="$(
    manifest_value "$result" attempt_directory
  )/fbig-profile-production-run-summary.tsv"
  if [[ "$(manifest_value "$result" dry_run)" = false ]]; then
    for field in "${profile_sum_fields[@]}"; do
      current="${PROFILE_TOTALS["$field"]}"
      delta="$(stage_value "$summary" history_profiles_summary "$field")"
      PROFILE_TOTALS["$field"]=$((current + delta))
    done
  fi
  previous_profile_result_sha="$result_sha"
  previous_profile_audit_sha="$audit_sha"
  last_profile_result="$result_sha"
  last_profile_audit="$audit_sha"
done <"$PROFILE_RESULT_INDEX"
test "$profile_sequence" -gt 0
test "$last_profile_result" = "$(sha256_file "$FINAL_PROFILE_RESULT")"
test "$last_profile_audit" = "$(sha256_file "$FINAL_PROFILE_AUDIT")"
validate_profile_result "$FINAL_PROFILE_RESULT" "$FINAL_PROFILE_RESULT_CHECKSUM"
validate_profile_audit "$FINAL_PROFILE_AUDIT" "$FINAL_PROFILE_AUDIT_CHECKSUM"
test "$(manifest_value "$FINAL_PROFILE_RESULT" dry_run)" = false
test "$(manifest_value "$FINAL_PROFILE_RESULT" zero_write_observed)" = true

checkpoint_sequence=0
previous_checkpoint_sha=none
previous_checkpoint_grace=none
last_checkpoint=none
declare -A CHECKPOINT_PATH_BY_SHA=()
while IFS=$'\t' read -r sequence checkpoint expected_sha extra; do
  test -z "$extra"
  checkpoint_sequence=$((checkpoint_sequence + 1))
  test "$sequence" = "$checkpoint_sequence"
  validate_checkpoint "$checkpoint" "${checkpoint}.sha256"
  test "$(sha256_file "$checkpoint")" = "$expected_sha"
  test "$(manifest_value "$checkpoint" predecessor_manifest_sha256)" = \
    "$previous_checkpoint_sha"
  if [[ "$previous_checkpoint_grace" = none ]]; then
    test "$(manifest_value "$checkpoint" effective_window_start)" = \
      "$(manifest_value "$HISTORY_APPROVAL" before)"
    test "$checkpoint" = "$FIRST_CHECKPOINT"
  else
    test "$(
      date -u -d "$(manifest_value "$checkpoint" effective_window_start)" +%s
    )" -le "$(date -u -d "$previous_checkpoint_grace" +%s)"
  fi
  previous_checkpoint_sha="$expected_sha"
  previous_checkpoint_grace="$(manifest_value "$checkpoint" grace_end)"
  last_checkpoint="$checkpoint"
  CHECKPOINT_PATH_BY_SHA["$expected_sha"]="$checkpoint"
done <"$CHECKPOINT_INDEX"
test "$checkpoint_sequence" -gt 0
test "$last_checkpoint" = "$FINAL_CHECKPOINT"
validate_checkpoint "$FIRST_CHECKPOINT" "$FIRST_CHECKPOINT_CHECKSUM"
validate_checkpoint "$FINAL_CHECKPOINT" "$FINAL_CHECKPOINT_CHECKSUM"
test "$(manifest_value "$FINAL_CHECKPOINT" running_rails_commit)" = \
  "$CANDIDATE_COMMIT"
test "$(manifest_value "$FINAL_CHECKPOINT" running_sidekiq_commit)" = \
  "$CANDIDATE_COMMIT"
test "$(manifest_value "$FINAL_CHECKPOINT" running_rails_service_source_sha256)" = \
  "$(manifest_value "$FINAL_CHECKPOINT" service_source_sha256)"
test "$(
  date -u -d "$(manifest_value "$FINAL_CHECKPOINT" grace_end)" +%s
)" -ge "$(
  date -u -d "$(manifest_value "$FINAL_PROFILE_RESULT" finished_at)" +%s
)"

while IFS=$'\t' read -r _sequence result _result_sha audit _audit_sha _extra; do
  before_sha="$(manifest_value "$result" before_checkpoint_sha256)"
  after_sha="$(manifest_value "$audit" after_checkpoint_sha256)"
  before_path="${CHECKPOINT_PATH_BY_SHA["$before_sha"]:-}"
  after_path="${CHECKPOINT_PATH_BY_SHA["$after_sha"]:-}"
  test -n "$before_path"
  test -n "$after_path"
  test "$(
    date -u -d "$(manifest_value "$before_path" finished_at)" +%s
  )" -le "$(
    date -u -d "$(manifest_value "$result" started_at)" +%s
  )"
  test "$(
    date -u -d "$(manifest_value "$after_path" effective_window_start)" +%s
  )" -le "$(
    date -u -d "$(manifest_value "$result" started_at)" +%s
  )"
  test "$(
    date -u -d "$(manifest_value "$after_path" grace_end)" +%s
  )" -ge "$(
    date -u -d "$(manifest_value "$result" finished_at)" +%s
  )"
done <"$PROFILE_RESULT_INDEX"

compose=(
  docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE"
)
for service in "$RAILS_SERVICE" "$SIDEKIQ_SERVICE"; do
  container="$(
    cd "$STACK_DIR" || exit 1
    "${compose[@]}" ps -q "$service"
  )"
  test -n "$container"
  image_id="$(docker inspect --format '{{.Image}}' "$container")"
  docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" |
    grep -Fxq "$CANDIDATE_IMAGE"
  commit="$(
    cd "$STACK_DIR" || exit 1
    "${compose[@]}" exec -T "$service" sh -c 'tr -d "\r\n" </app/.git_sha'
  )"
  test "$commit" = "$CANDIDATE_COMMIT"
done

readonly OVERRIDE="$STAGING_DIRECTORY/final-audit-compose.yml"
printf 'services:\n  %s:\n    image: %s\n' "$RAILS_SERVICE" "$CANDIDATE_IMAGE" \
  >"$OVERRIDE"
chmod 0400 "$OVERRIDE"
audit_compose=(
  docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE"
  --file "$OVERRIDE"
)
(
  cd "$STACK_DIR" || exit 1
  "${audit_compose[@]}" run --rm --no-deps -T \
    --volume "$(dirname "$PROFILE_TARGETS"):/run/fbig/targets:ro" \
    --volume "$(dirname "${FIRST_HISTORY_PRE[messenger]}"):/run/fbig/messenger-baseline:ro" \
    --volume "$(dirname "${FIRST_HISTORY_PRE[instagram]}"):/run/fbig/instagram-baseline:ro" \
    -e UMI_FBIG_FINAL_COMMIT="$CANDIDATE_COMMIT" \
    -e UMI_FBIG_FINAL_DATABASE="$PRODUCTION_DATABASE" \
    -e UMI_FBIG_FINAL_INBOX_ID="$INBOX_ID" \
    -e UMI_FBIG_FINAL_TARGETS_SHA="$PROFILE_TARGETS_SHA256" \
    -e UMI_FBIG_FINAL_MESSENGER_BASELINE_SHA="$(
      sha256_file "${FIRST_HISTORY_PRE[messenger]}"
    )" \
    -e UMI_FBIG_FINAL_INSTAGRAM_BASELINE_SHA="$(
      sha256_file "${FIRST_HISTORY_PRE[instagram]}"
    )" \
    "$RAILS_SERVICE" bundle exec rails runner - <<'RUBY'
require "digest"
require "set"

abort("candidate commit mismatch") unless
  File.binread("/app/.git_sha").strip == ENV.fetch("UMI_FBIG_FINAL_COMMIT")
connection = ActiveRecord::Base.connection
abort("production database mismatch") unless
  connection.select_value("SELECT current_database()") ==
    ENV.fetch("UMI_FBIG_FINAL_DATABASE")
abort("Contact avatar migration missing") unless
  connection.select_value(
    "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = '20260724000000')"
  )
indexes = connection.select_all(<<~SQL).to_a
  SELECT
    i.indisunique,
    i.indisvalid,
    i.indisready,
    i.indnatts = 3 AND i.indnkeyatts = 3 AS exact_attribute_count,
    i.indexprs IS NULL AS no_expressions,
    ARRAY(
      SELECT attribute.attname::text
      FROM unnest(i.indkey::smallint[]) WITH ORDINALITY AS key(attnum, position)
      JOIN pg_attribute AS attribute
        ON attribute.attrelid = i.indrelid
       AND attribute.attnum = key.attnum
      ORDER BY key.position
    ) = ARRAY['record_type', 'record_id', 'name'] AS columns_match,
    pg_get_expr(i.indpred, i.indrelid) AS predicate
  FROM pg_index AS i
  JOIN pg_class AS index_class ON index_class.oid = i.indexrelid
  JOIN pg_class AS table_class ON table_class.oid = i.indrelid
  JOIN pg_namespace AS namespace ON namespace.oid = table_class.relnamespace
  WHERE namespace.nspname = 'public'
    AND index_class.relname = 'index_active_storage_contact_avatar_uniqueness'
    AND table_class.relname = 'active_storage_attachments'
SQL
abort("exactly one Contact avatar index is required") unless indexes.one?
index = indexes.first
required = %w[
  indisunique indisvalid indisready exact_attribute_count no_expressions columns_match
]
abort("Contact avatar index shape is invalid") unless
  index.values_at(*required).all? { |value| value == true }
predicate = index.fetch("predicate").gsub("::text", "").delete("() \n\t")
expected = "record_type = 'Contact' AND name = 'avatar'".delete("() \n\t")
abort("Contact avatar index predicate changed") unless predicate == expected
connection.transaction(isolation: :repeatable_read, requires_new: true) do
connection.execute("SET TRANSACTION READ ONLY")
inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_FINAL_INBOX_ID"), 10))
targets = Umi::Fbig::ProfileTargetManifest.load(
  path: "/run/fbig/targets/fbig-profile-targets-v1.tsv",
  expected_sha256: ENV.fetch("UMI_FBIG_FINAL_TARGETS_SHA")
)
baselines = %w[messenger instagram].to_h do |platform|
  directory = "/run/fbig/#{platform}-baseline"
  artifact = Umi::Fbig::HistoryStateSnapshot.load(
    path: "#{directory}/fbig-history-production-prestate-v1.tsv",
    checksum_path: "#{directory}/fbig-history-production-prestate-v1.tsv.sha256"
  )
  expected = ENV.fetch("UMI_FBIG_FINAL_#{platform.upcase}_BASELINE_SHA")
  abort("#{platform} baseline mismatch") unless
    artifact.sha256 == expected && artifact.platforms == [platform]
  [platform, artifact]
end
archives = inbox.conversations.where(
  "jsonb_exists(conversations.additional_attributes, :key)",
  key: "umi_history_import"
)
messages = Message.where(inbox_id: inbox.id).where(
  "messages.additional_attributes ->> 'umi_history_import' = 'true'"
)
attachments = Attachment.joins(:message).merge(messages).where(
  "attachments.meta ->> 'umi_history_import' = 'true'"
)
values = {
  "schema_version" => 1,
  "observed_at" => Time.current.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
  "database_snapshot_sha256" =>
    Digest::SHA256.hexdigest(connection.select_value("SELECT txid_current_snapshot()"))
}
%w[messenger instagram].each do |platform|
  platform_archives = archives.where(
    "conversations.additional_attributes -> 'umi_history_import' ->> 'platform' = ?",
    platform
  )
  platform_messages = messages.where(
    "messages.additional_attributes ->> 'umi_history_platform' = ?",
    platform
  )
  platform_attachments = attachments.where(
    "messages.additional_attributes ->> 'umi_history_platform' = ?",
    platform
  )
  values["#{platform}_archives"] = platform_archives.count
  values["#{platform}_nonempty_archives"] =
    platform_archives.joins(:messages).distinct.count
  values["#{platform}_messages"] = platform_messages.count
  values["#{platform}_incoming"] =
    platform_messages.where(message_type: Message.message_types.fetch("incoming")).count
  values["#{platform}_outgoing"] =
    platform_messages.where(message_type: Message.message_types.fetch("outgoing")).count
  values["#{platform}_attachments"] = platform_attachments.count
  values["#{platform}_attachment_bytes"] =
    platform_attachments.joins(file_attachment: :blob)
                        .sum("active_storage_blobs.byte_size")
  values["#{platform}_linked_contacts"] = platform_archives.distinct.count(:contact_id)
  values["#{platform}_linked_contact_inboxes"] =
    platform_archives.distinct.count(:contact_inbox_id)
  baseline_rows = baselines.fetch(platform).rows
  baseline_archives = baseline_rows.select { |row| row.entity == "archive" }
  baseline_messages = baseline_rows.select { |row| row.entity == "message" }
  values["#{platform}_baseline_archives"] = baseline_archives.size
  values["#{platform}_baseline_messages"] = baseline_messages.size
  values["#{platform}_baseline_incoming"] =
    baseline_messages.count { |row| row.values.fetch(4) == "incoming" }
  values["#{platform}_baseline_outgoing"] =
    baseline_messages.count { |row| row.values.fetch(4) == "outgoing" }
  values["#{platform}_baseline_attachments"] =
    baseline_rows.count { |row| row.entity == "attachment" }
  values["#{platform}_baseline_linked_contacts"] =
    baseline_archives.map { |row| row.values.fetch(3) }.uniq.size
  values["#{platform}_baseline_linked_contact_inboxes"] =
    baseline_archives.map { |row| row.values.fetch(4) }.uniq.size
end
values["empty_importer_archives"] =
  archives.left_joins(:messages).where(messages: { id: nil }).count
values["duplicate_imported_source_ids"] =
  messages.group(:source_id).having("COUNT(*) > 1").count.size
values["invalid_importer_archives"] = archives.where.not(
  status: Conversation.statuses.fetch("resolved"),
  assignee_id: nil,
  team_id: nil,
  waiting_since: nil,
  first_reply_created_at: nil
).count
values["duplicate_contact_avatars"] = ActiveStorage::Attachment
  .where(record_type: "Contact", name: "avatar")
  .group(:record_id).having("COUNT(*) > 1").count.size
values["history_attachment_intents"] = ActiveStorage::Blob.find_each.count do |blob|
  blob.metadata.key?(Umi::Fbig::HistoryImportAttachmentService::INTENT_KEY)
end
values["unclassified_importer_messages"] = messages.where.not(
  "messages.additional_attributes ->> 'umi_history_platform' IN (?)",
  %w[messenger instagram]
).count
seed_ids = targets.map(&:contact_inbox_id).to_set
values["instagram_seed_targets_sealed"] = targets.size
importer_ids = archives.where(
  "conversations.additional_attributes -> 'umi_history_import' ->> 'platform' = 'instagram'"
).distinct.pluck(:contact_inbox_id).to_set
values["seed_only_targets"] = (seed_ids - importer_ids).size
values["importer_only_targets"] = (importer_ids - seed_ids).size
values["seed_and_importer_targets"] = (seed_ids & importer_ids).size
union_ids = seed_ids | importer_ids
values["unclassified_profile_targets"] =
  union_ids.size - values.values_at(
    "seed_only_targets", "importer_only_targets", "seed_and_importer_targets"
  ).sum
placeholder_candidate_ids = inbox.contact_inboxes.includes(:contact).select do |contact_inbox|
  contact_inbox.contact.name == "Instagram user #{contact_inbox.source_id.to_s.last(4)}"
end.map(&:id)
placeholder_candidates = inbox.contact_inboxes
                              .includes(:contact, :conversations)
                              .where(id: placeholder_candidate_ids)
                              .to_a
classified_placeholders = placeholder_candidates.group_by do |contact_inbox|
  Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox)
end
abort("ambiguous Instagram placeholder evidence") if
  classified_placeholders[:ambiguous].present?
placeholders = classified_placeholders.fetch(:instagram, [])
values["instagram_placeholders_remaining"] = placeholders.size
placeholder_fingerprints = placeholders.map do |contact_inbox|
  Digest::SHA256.hexdigest(
    [
      contact_inbox.id,
      contact_inbox.contact_id,
      contact_inbox.source_id
    ].join(":")
  )
end.sort
values["instagram_placeholders_remaining_fingerprint"] =
  Digest::SHA256.hexdigest(placeholder_fingerprints.join("\n"))
order = [
  "schema_version", "observed_at", "database_snapshot_sha256",
  *%w[messenger instagram].flat_map do |platform|
    %W[
      #{platform}_archives #{platform}_nonempty_archives
      #{platform}_messages #{platform}_incoming #{platform}_outgoing
      #{platform}_attachments #{platform}_attachment_bytes
      #{platform}_linked_contacts
      #{platform}_linked_contact_inboxes
      #{platform}_baseline_archives #{platform}_baseline_messages
      #{platform}_baseline_incoming #{platform}_baseline_outgoing
      #{platform}_baseline_attachments #{platform}_baseline_linked_contacts
      #{platform}_baseline_linked_contact_inboxes
    ]
  end,
  "empty_importer_archives", "duplicate_imported_source_ids",
  "invalid_importer_archives", "duplicate_contact_avatars",
  "history_attachment_intents",
  "unclassified_importer_messages", "seed_only_targets",
  "importer_only_targets", "seed_and_importer_targets",
  "unclassified_profile_targets", "instagram_seed_targets_sealed",
  "instagram_placeholders_remaining",
  "instagram_placeholders_remaining_fingerprint"
]
order.each { |key| puts "#{key}\t#{values.fetch(key)}" }
end
RUBY
) >"$LIVE_COUNTS_TEMP"
chmod 0400 "$LIVE_COUNTS_TEMP"
require_ordered_manifest "$LIVE_COUNTS_TEMP" "${LIVE_COUNT_FIELDS[@]}"
for invariant in \
  empty_importer_archives duplicate_imported_source_ids \
  invalid_importer_archives duplicate_contact_avatars \
  history_attachment_intents unclassified_importer_messages \
  unclassified_profile_targets; do
  test "$(manifest_value "$LIVE_COUNTS_TEMP" "$invariant")" = 0
done

terminal_profile_summary="$(
  manifest_value "$FINAL_PROFILE_RESULT" attempt_directory
)/fbig-profile-production-run-summary.tsv"
terminal_profile_log="$(
  manifest_value "$FINAL_PROFILE_RESULT" attempt_directory
)/fbig-profile-production-run.log"
test "$(manifest_value "$LIVE_COUNTS_TEMP" instagram_seed_targets_sealed)" = "$(
  stage_value "$terminal_profile_log" history_profiles_start seed_targets_expected
)"
placeholders_remaining="$(
  manifest_value "$LIVE_COUNTS_TEMP" instagram_placeholders_remaining
)"
instagram_targets_unavailable="$(
  stage_value "$terminal_profile_summary" history_profiles_summary \
    instagram_placeholders_unavailable
)"
instagram_targets_blank_name="$(
  stage_value "$terminal_profile_summary" history_profiles_summary \
    instagram_placeholders_blank_name
)"
test "$placeholders_remaining" = "$(
  stage_value "$terminal_profile_summary" history_profiles_summary \
    instagram_placeholders_remaining
)"
test "$(manifest_value "$LIVE_COUNTS_TEMP" \
  instagram_placeholders_remaining_fingerprint)" = "$(
  stage_value "$terminal_profile_summary" history_profiles_summary \
    instagram_placeholders_remaining_fingerprint
)"
test "$placeholders_remaining" = \
  "$((instagram_targets_unavailable + instagram_targets_blank_name))"
test "$(manifest_value "$LIVE_COUNTS_TEMP" \
  instagram_placeholders_remaining_fingerprint)" = "$(
  stage_value "$terminal_profile_summary" history_profiles_summary \
    instagram_placeholders_classified_fingerprint
)"
test "$(stage_value "$terminal_profile_summary" history_profiles_summary \
  instagram_placeholders_projected_repair)" = 0
test "$(stage_value "$terminal_profile_summary" history_profiles_summary \
  instagram_placeholders_unclassified)" = 0
PLATFORM_COUNTS_TEMP="$STAGING_DIRECTORY/fbig-production-platform-counts-v1.tsv"
{
  printf 'schema_version\t1\n'
  for platform in messenger instagram; do
    if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
      dry_summary="${FIRST_HISTORY_SUMMARY["$platform"]}"
      if [[ "$platform" = messenger ]]; then
        terminal_result="$MESSENGER_TERMINAL_RESULT"
      else
        terminal_result="$INSTAGRAM_TERMINAL_RESULT"
      fi
    elif [[ "$platform" = messenger ]]; then
      dry_summary="$(dirname "$MESSENGER_DRY_1")/history-summary.tsv"
      terminal_result="$MESSENGER_TERMINAL_RESULT"
    else
      dry_summary="$(dirname "$INSTAGRAM_DRY_1")/history-summary.tsv"
      terminal_result="$INSTAGRAM_TERMINAL_RESULT"
    fi
    terminal_summary="$(dirname "$terminal_result")/history-summary.tsv"
    printf '%s_conversation_pages_scanned\t%s\n' "$platform" \
      "$(stage_value "$terminal_summary" history_import_summary conversation_pages)"
    printf '%s_threads_scanned\t%s\n' "$platform" \
      "$(stage_value "$terminal_summary" history_import_summary threads_scanned)"
    for field in \
      listed_threads message_cursor_exhausted_threads \
      structural_unrecoverable_threads unavailable_message_threads \
      classified_omitted_threads failed_threads \
      unavailable_message_thread_fingerprint; do
      printf '%s_%s\t%s\n' "$platform" "$field" \
        "$(stage_value "$terminal_summary" history_import_summary "${platform}_${field}")"
    done
    printf '%s_message_pages_scanned\t%s\n' "$platform" \
      "$(stage_value "$terminal_summary" history_import_summary message_pages)"
    printf '%s_message_ids_scanned\t%s\n' "$platform" \
      "$(stage_value "$terminal_summary" history_import_summary in_scope_mids_scanned)"
    printf '%s_out_of_scope_message_ids\t%s\n' "$platform" \
      "$(stage_value "$terminal_summary" history_import_summary out_of_scope_mids)"
    printf '%s_already_present\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary already_present)"
    printf '%s_candidate_incoming\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary candidate_incoming)"
    printf '%s_candidate_outgoing\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary candidate_outbound)"
    printf '%s_policy_skips\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary outbound_pre_presence_skip)"
    printf '%s_content_unavailable\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary content_unavailable)"
    printf '%s_contentless_omissions\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary "${platform}_contentless_details")"
    printf '%s_attachment_urls_found\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary attachment_urls_found)"
    printf '%s_attachments_unsupported\t%s\n' "$platform" \
      "$(stage_value "$dry_summary" history_import_summary attachments_unsupported)"
    for field in "${history_delta_fields[@]}"; do
      printf '%s_%s\t%s\n' "$platform" "$field" \
        "${HISTORY_TOTALS["$platform:$field"]}"
    done
    attachment_urls_found="$(
      stage_value "$dry_summary" history_import_summary attachment_urls_found
    )"
    attachments_created="${HISTORY_TOTALS["$platform:attachments_created"]}"
    test "$attachment_urls_found" -ge "$attachments_created"
    attachments_unavailable=$((attachment_urls_found - attachments_created))
    printf '%s_attachments_unavailable\t%s\n' "$platform" \
      "$attachments_unavailable"
    printf '%s_attachment_bytes\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_attachment_bytes")"
    printf '%s_nonempty_archives\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_nonempty_archives")"
    printf '%s_linked_contacts\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_linked_contacts")"
    printf '%s_linked_contact_inboxes\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_linked_contact_inboxes")"
    printf '%s_preexisting_importer_archives\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_baseline_archives")"
    printf '%s_preexisting_importer_messages\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_baseline_messages")"
    printf '%s_preexisting_importer_incoming\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_baseline_incoming")"
    printf '%s_preexisting_importer_outgoing\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_baseline_outgoing")"
    printf '%s_preexisting_importer_attachments\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_baseline_attachments")"
    printf '%s_preexisting_linked_contacts\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_baseline_linked_contacts")"
    printf '%s_preexisting_linked_contact_inboxes\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" \
        "${platform}_baseline_linked_contact_inboxes")"
    printf '%s_total_importer_archives\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_archives")"
    printf '%s_total_importer_messages\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_messages")"
    printf '%s_total_importer_incoming\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_incoming")"
    printf '%s_total_importer_outgoing\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_outgoing")"
    printf '%s_total_importer_attachments\t%s\n' "$platform" \
      "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_attachments")"
    stable_profile_targets="$(
      stage_value "$terminal_profile_summary" history_profiles_summary \
        "stable_${platform}_targets"
    )"
    printf '%s_stable_profile_targets\t%s\n' "$platform" \
      "$stable_profile_targets"
    printf '%s_profile_targets_success\t%s\n' "$platform" \
      "$(stage_value "$terminal_profile_summary" history_profiles_summary \
        "${platform}_targets_success")"
    printf '%s_profile_targets_unavailable\t%s\n' "$platform" \
      "$(stage_value "$terminal_profile_summary" history_profiles_summary \
        "${platform}_targets_unavailable")"
    printf '%s_profile_targets_blocking\t%s\n' "$platform" \
      "$(stage_value "$terminal_profile_summary" history_profiles_summary \
        "${platform}_targets_blocking")"
    profile_success="$(
      stage_value "$terminal_profile_summary" history_profiles_summary \
        "${platform}_targets_success"
    )"
    profile_unavailable="$(
      stage_value "$terminal_profile_summary" history_profiles_summary \
        "${platform}_targets_unavailable"
    )"
    profile_blocking="$(
      stage_value "$terminal_profile_summary" history_profiles_summary \
        "${platform}_targets_blocking"
    )"
    test "$stable_profile_targets" = \
      "$((profile_success + profile_unavailable + profile_blocking))"
  done
  printf 'profile_seed_targets_sealed\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" instagram_seed_targets_sealed)"
  for field in "${profile_sum_fields[@]}"; do
    printf 'profile_%s\t%s\n' "$field" "${PROFILE_TOTALS["$field"]}"
  done
  printf 'seed_only_targets\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" seed_only_targets)"
  printf 'importer_only_targets\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" importer_only_targets)"
  printf 'seed_and_importer_targets\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" seed_and_importer_targets)"
  printf 'instagram_placeholders_remaining\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" instagram_placeholders_remaining)"
  printf 'instagram_placeholders_remaining_fingerprint\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" \
      instagram_placeholders_remaining_fingerprint)"
  printf 'instagram_placeholders_name_unavailable\t%s\n' \
    "$placeholders_remaining"
  printf 'empty_importer_archives\t%s\n' \
    "$(manifest_value "$LIVE_COUNTS_TEMP" empty_importer_archives)"
  printf 'unrecoverable_instagram_envelopes\t%s\n' \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  printf 'profile_mutations_are_aggregate\ttrue\n'
} >"$PLATFORM_COUNTS_TEMP"
chmod 0400 "$PLATFORM_COUNTS_TEMP"
require_ordered_manifest "$PLATFORM_COUNTS_TEMP" "${PLATFORM_COUNT_FIELDS[@]}"

for platform in messenger instagram; do
  test "${HISTORY_TOTALS["$platform:messages_created"]}" = \
    "$((HISTORY_TOTALS["$platform:incoming_created"] + HISTORY_TOTALS["$platform:outgoing_created"]))"
  for equation in \
    archives_created:archives \
    messages_created:messages \
    incoming_created:incoming \
    outgoing_created:outgoing \
    attachments_created:attachments; do
    created="${HISTORY_TOTALS["$platform:${equation%%:*}"]}"
    total="$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_${equation##*:}")"
    baseline="$(manifest_value "$LIVE_COUNTS_TEMP" \
      "${platform}_baseline_${equation##*:}")"
    test "$created" = "$((total - baseline))"
  done
  test "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_archives")" = \
    "$(manifest_value "$LIVE_COUNTS_TEMP" "${platform}_nonempty_archives")"
done

RELEASE_SCHEMA_TEMP="$STAGING_DIRECTORY/production-release-schema.tsv"
{
  printf 'schema_version\t1\n'
  printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
  printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
  printf 'production_database\t%s\n' "$PRODUCTION_DATABASE"
  printf 'migration_20260724000000\tapplied\n'
  printf 'contact_avatar_unique_index\tvalid\n'
} >"$RELEASE_SCHEMA_TEMP"
chmod 0400 "$RELEASE_SCHEMA_TEMP"

seal_in_place "$OVERRIDE"
seal_in_place "$PLATFORM_COUNTS_TEMP"
seal_in_place "$LIVE_COUNTS_TEMP"
seal_in_place "$RELEASE_SCHEMA_TEMP"
FINAL_TEMP="$STAGING_DIRECTORY/fbig-production-migration-audit-v1.tsv"
{
  printf 'schema_version\t1\n'
  printf 'authorization_mode\t%s\n' "$AUTHORIZATION_MODE"
  printf 'authorization_sha256\t%s\n' "$AUTHORIZATION_SHA256"
  printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
  printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
  printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
  printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
  printf 'production_database\t%s\n' "$PRODUCTION_DATABASE"
  printf 'inbox_id\t%s\n' "$INBOX_ID"
  printf 'acceptance_sha256\t%s\n' "$ACCEPTANCE_SHA256"
  printf 'history_approval_sha256\t%s\n' "$HISTORY_APPROVAL_SHA256"
  printf 'profile_approval_sha256\t%s\n' "$PROFILE_APPROVAL_SHA256"
  printf 'pre_history_backup_sha256\t%s\n' "$PRE_HISTORY_BACKUP_SHA256"
  printf 'history_result_index_sha256\t%s\n' "$HISTORY_RESULT_INDEX_SHA256"
  printf 'profile_result_index_sha256\t%s\n' "$PROFILE_RESULT_INDEX_SHA256"
  printf 'checkpoint_index_sha256\t%s\n' "$CHECKPOINT_INDEX_SHA256"
  printf 'platform_counts_sha256\t%s\n' "$(sha256_file "$PLATFORM_COUNTS_TEMP")"
  printf 'live_counts_sha256\t%s\n' "$(sha256_file "$LIVE_COUNTS_TEMP")"
  printf 'release_schema_sha256\t%s\n' "$(sha256_file "$RELEASE_SCHEMA_TEMP")"
  printf 'messenger_terminal_result_sha256\t%s\n' \
    "$(sha256_file "$MESSENGER_TERMINAL_RESULT")"
  printf 'instagram_terminal_result_sha256\t%s\n' \
    "$(sha256_file "$INSTAGRAM_TERMINAL_RESULT")"
  printf 'final_profile_result_sha256\t%s\n' \
    "$(sha256_file "$FINAL_PROFILE_RESULT")"
  printf 'final_profile_audit_sha256\t%s\n' \
    "$(sha256_file "$FINAL_PROFILE_AUDIT")"
  printf 'first_checkpoint_sha256\t%s\n' "$(sha256_file "$FIRST_CHECKPOINT")"
  printf 'final_checkpoint_sha256\t%s\n' "$(sha256_file "$FINAL_CHECKPOINT")"
  printf 'unrecoverable_sidecar_sha256\t%s\n' "$UNRECOVERABLE_SIDECAR_SHA256"
  printf 'unrecoverable_instagram_envelopes\t%s\n' \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  printf 'profile_mutations_are_aggregate\ttrue\n'
  printf 'audited_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$FINAL_TEMP"
chmod 0400 "$FINAL_TEMP"
seal_in_place "$FINAL_TEMP"
fsync_path "$STAGING_DIRECTORY"
publish_directory_no_replace "$STAGING_DIRECTORY" "$RESULT_DIRECTORY"
fsync_path "$AUDIT_ROOT"
validate_final_manifest "$RESULT_MANIFEST"
printf '[UMI-FBIG] stage=production_migration_complete audit_sha256=%s inbox_id=%s\n' \
  "$(sha256_file "$RESULT_MANIFEST")" "$INBOX_ID"
