readonly BINDING_MANIFEST="${1:?delivery audit binding is required}"
readonly BINDING_CHECKSUM="${BINDING_MANIFEST}.sha256"
PROGRAM_PATH="$(readlink -f "$0")"
readonly PROGRAM_PATH
readonly PROGRAM_CHECKSUM="${PROGRAM_PATH}.sha256"

readonly BINDING_FIELDS=(
  schema_version authorization_mode authorization_manifest
  authorization_checksum authorization_sha256 label candidate_commit
  candidate_image acceptance_sha256
  audit_root attempt_result attempt_result_checksum before_checkpoint
  before_checkpoint_checksum after_checkpoint after_checkpoint_checksum
  predecessor_audit predecessor_audit_checksum production_lock
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
readonly AUDIT_FIELDS=(
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

verify_checksum "$PROGRAM_PATH" "$PROGRAM_CHECKSUM"
verify_checksum "$BINDING_MANIFEST" "$BINDING_CHECKSUM"
require_ordered_manifest "$BINDING_MANIFEST" "${BINDING_FIELDS[@]}"
test "$(manifest_value "$BINDING_MANIFEST" schema_version)" = 1

LABEL="$(manifest_value "$BINDING_MANIFEST" label)"
AUTHORIZATION_MODE="$(manifest_value "$BINDING_MANIFEST" authorization_mode)"
AUTHORIZATION_MANIFEST="$(manifest_value "$BINDING_MANIFEST" authorization_manifest)"
AUTHORIZATION_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" authorization_checksum)"
AUTHORIZATION_SHA256="$(manifest_value "$BINDING_MANIFEST" authorization_sha256)"
CANDIDATE_COMMIT="$(manifest_value "$BINDING_MANIFEST" candidate_commit)"
CANDIDATE_IMAGE="$(manifest_value "$BINDING_MANIFEST" candidate_image)"
ACCEPTANCE_SHA256="$(manifest_value "$BINDING_MANIFEST" acceptance_sha256)"
AUDIT_ROOT="$(manifest_value "$BINDING_MANIFEST" audit_root)"
ATTEMPT_RESULT="$(manifest_value "$BINDING_MANIFEST" attempt_result)"
ATTEMPT_RESULT_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" attempt_result_checksum
)"
BEFORE_CHECKPOINT="$(manifest_value "$BINDING_MANIFEST" before_checkpoint)"
BEFORE_CHECKPOINT_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" before_checkpoint_checksum
)"
AFTER_CHECKPOINT="$(manifest_value "$BINDING_MANIFEST" after_checkpoint)"
AFTER_CHECKPOINT_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" after_checkpoint_checksum
)"
PREDECESSOR_AUDIT="$(manifest_value "$BINDING_MANIFEST" predecessor_audit)"
PREDECESSOR_AUDIT_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" predecessor_audit_checksum
)"
PRODUCTION_LOCK="$(manifest_value "$BINDING_MANIFEST" production_lock)"
readonly LABEL AUTHORIZATION_MODE AUTHORIZATION_MANIFEST AUTHORIZATION_CHECKSUM
readonly AUTHORIZATION_SHA256
readonly CANDIDATE_COMMIT CANDIDATE_IMAGE ACCEPTANCE_SHA256 AUDIT_ROOT
readonly ATTEMPT_RESULT ATTEMPT_RESULT_CHECKSUM BEFORE_CHECKPOINT
readonly BEFORE_CHECKPOINT_CHECKSUM AFTER_CHECKPOINT AFTER_CHECKPOINT_CHECKSUM
readonly PREDECESSOR_AUDIT PREDECESSOR_AUDIT_CHECKSUM PRODUCTION_LOCK

require_safe_token label "$LABEL"
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$CANDIDATE_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]
[[ "$AUTHORIZATION_MODE" = clone_authorized ||
  "$AUTHORIZATION_MODE" = production_first ]]
if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
  [[ "$AUTHORIZATION_SHA256" =~ ^[0-9a-f]{64}$ && "$ACCEPTANCE_SHA256" = none ]]
  verify_checksum "$AUTHORIZATION_MANIFEST" "$AUTHORIZATION_CHECKSUM"
  require_ordered_manifest \
    "$AUTHORIZATION_MANIFEST" "${PRODUCTION_FIRST_AUTHORIZATION_FIELDS[@]}"
  test "$(sha256_file "$AUTHORIZATION_MANIFEST")" = "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" repository_commit)" = \
    "$CANDIDATE_COMMIT"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" image_digest)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$AUTHORIZATION_MANIFEST" delivery_audit_program_sha256)" = \
    "$(sha256_file "$PROGRAM_PATH")"
else
  [[ "$AUTHORIZATION_SHA256" = none && "$ACCEPTANCE_SHA256" =~ ^[0-9a-f]{64}$ ]]
  test "$AUTHORIZATION_MANIFEST" = none
  test "$AUTHORIZATION_CHECKSUM" = none
fi
test "$BEFORE_CHECKPOINT_CHECKSUM" = "${BEFORE_CHECKPOINT}.sha256"
test "$AFTER_CHECKPOINT_CHECKSUM" = "${AFTER_CHECKPOINT}.sha256"
require_root_directory "$AUDIT_ROOT"
readonly RESULT_DIRECTORY="$AUDIT_ROOT/$LABEL"
readonly RESULT_MANIFEST="$RESULT_DIRECTORY/fbig-profile-delivery-audit-v1.tsv"

validate_checkpoint() {
  local checkpoint="$1"
  local directory
  local entry
  local field
  local filename
  local artifact

  verify_checksum "$checkpoint" "${checkpoint}.sha256"
  require_ordered_manifest "$checkpoint" "${CHECKPOINT_FIELDS[@]}"
  test "$(manifest_value "$checkpoint" schema_version)" = 1
  test "$(manifest_value "$checkpoint" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$checkpoint" candidate_image)" = "$CANDIDATE_IMAGE"
  for field in \
    messenger_missing instagram_missing messenger_threads_failed \
    instagram_threads_failed messenger_caps_hit instagram_caps_hit; do
    test "$(manifest_value "$checkpoint" "$field")" = 0
  done
  directory="$(dirname "$checkpoint")"
  for entry in \
    'compose_override:candidate-compose.yml' \
    'reconciliation_log:reconciliation.log' \
    'window_evidence:window.tsv' \
    'messenger_subscription_evidence:messenger-subscription.tsv' \
    'instagram_subscription_evidence:instagram-subscription.tsv' \
    'messenger_recon_summary:messenger-recon-summary.tsv' \
    'instagram_recon_summary:instagram-recon-summary.tsv'; do
    field="${entry%%:*}"
    filename="${entry#*:}"
    artifact="$directory/$filename"
    require_root_artifact "$artifact"
    test "$(manifest_value "$checkpoint" "${field}_sha256")" = \
      "$(sha256_file "$artifact")"
  done
}

validate_profile_result() {
  verify_checksum "$ATTEMPT_RESULT" "$ATTEMPT_RESULT_CHECKSUM"
  require_ordered_manifest "$ATTEMPT_RESULT" "${PROFILE_RESULT_FIELDS[@]}"
  test "$(manifest_value "$ATTEMPT_RESULT" authorization_mode)" = \
    "$AUTHORIZATION_MODE"
  test "$(manifest_value "$ATTEMPT_RESULT" authorization_sha256)" = \
    "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$ATTEMPT_RESULT" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$ATTEMPT_RESULT" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$ATTEMPT_RESULT" acceptance_sha256)" = \
    "$ACCEPTANCE_SHA256"
  test "$(manifest_value "$ATTEMPT_RESULT" before_checkpoint_sha256)" = \
    "$(sha256_file "$BEFORE_CHECKPOINT")"
}

predecessor_audit_sha=none
if [[ "$PREDECESSOR_AUDIT" = none ]]; then
  test "$PREDECESSOR_AUDIT_CHECKSUM" = none
else
  verify_checksum "$PREDECESSOR_AUDIT" "$PREDECESSOR_AUDIT_CHECKSUM"
  require_ordered_manifest "$PREDECESSOR_AUDIT" "${AUDIT_FIELDS[@]}"
  test "$(manifest_value "$PREDECESSOR_AUDIT" authorization_mode)" = \
    "$AUTHORIZATION_MODE"
  test "$(manifest_value "$PREDECESSOR_AUDIT" authorization_sha256)" = \
    "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$PREDECESSOR_AUDIT" candidate_commit)" = \
    "$CANDIDATE_COMMIT"
  test "$(manifest_value "$PREDECESSOR_AUDIT" acceptance_sha256)" = \
    "$ACCEPTANCE_SHA256"
  predecessor_audit_sha="$(sha256_file "$PREDECESSOR_AUDIT")"
fi
readonly predecessor_audit_sha

validate_audit() {
  local manifest="$1"

  verify_checksum "$manifest" "${manifest}.sha256"
  require_ordered_manifest "$manifest" "${AUDIT_FIELDS[@]}"
  test "$(manifest_value "$manifest" schema_version)" = 1
  test "$(manifest_value "$manifest" authorization_mode)" = "$AUTHORIZATION_MODE"
  test "$(manifest_value "$manifest" authorization_sha256)" = "$AUTHORIZATION_SHA256"
  test "$(manifest_value "$manifest" label)" = "$LABEL"
  test "$(manifest_value "$manifest" program_sha256)" = \
    "$(sha256_file "$PROGRAM_PATH")"
  test "$(manifest_value "$manifest" binding_sha256)" = \
    "$(sha256_file "$BINDING_MANIFEST")"
  test "$(manifest_value "$manifest" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$manifest" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$manifest" acceptance_sha256)" = "$ACCEPTANCE_SHA256"
  test "$(manifest_value "$manifest" attempt_result_sha256)" = \
    "$(sha256_file "$ATTEMPT_RESULT")"
  test "$(manifest_value "$manifest" before_checkpoint_sha256)" = \
    "$(sha256_file "$BEFORE_CHECKPOINT")"
  test "$(manifest_value "$manifest" after_checkpoint_sha256)" = \
    "$(sha256_file "$AFTER_CHECKPOINT")"
  test "$(manifest_value "$manifest" predecessor_audit_sha256)" = \
    "$predecessor_audit_sha"
  test "$(manifest_value "$manifest" zero_unrecovered_deliveries)" = true
  for field in \
    messenger_missing instagram_missing messenger_threads_failed \
    instagram_threads_failed messenger_caps_hit instagram_caps_hit; do
    test "$(manifest_value "$manifest" "$field")" = 0
  done
}

if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_audit "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=profile_delivery_audit_validated label=%s manifest=%s\n' \
    "$LABEL" "$RESULT_MANIFEST"
  exit 0
fi

acquire_descriptor_verified_lock "$PRODUCTION_LOCK"
if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_audit "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=profile_delivery_audit_validated label=%s manifest=%s\n' \
    "$LABEL" "$RESULT_MANIFEST"
  exit 0
fi

validate_checkpoint "$BEFORE_CHECKPOINT"
validate_checkpoint "$AFTER_CHECKPOINT"
validate_profile_result
test "$(manifest_value "$AFTER_CHECKPOINT" predecessor_manifest_sha256)" = \
  "$(sha256_file "$BEFORE_CHECKPOINT")"
test "$(manifest_value "$BEFORE_CHECKPOINT" finished_at)" \< \
  "$(manifest_value "$ATTEMPT_RESULT" started_at)"
test "$(
  date -u -d "$(manifest_value "$AFTER_CHECKPOINT" effective_window_start)" +%s
)" -le "$(
  date -u -d "$(manifest_value "$ATTEMPT_RESULT" started_at)" +%s
)"
test "$(
  date -u -d "$(manifest_value "$AFTER_CHECKPOINT" grace_end)" +%s
)" -ge "$(
  date -u -d "$(manifest_value "$ATTEMPT_RESULT" finished_at)" +%s
)"
test "$(
  date -u -d "$(manifest_value "$AFTER_CHECKPOINT" effective_window_start)" +%s
)" -le "$(
  date -u -d "$(manifest_value "$BEFORE_CHECKPOINT" grace_end)" +%s
)"
test "$(manifest_value "$BEFORE_CHECKPOINT" page_identity_sha256)" = \
  "$(manifest_value "$AFTER_CHECKPOINT" page_identity_sha256)"
test "$(manifest_value "$BEFORE_CHECKPOINT" instagram_identity_sha256)" = \
  "$(manifest_value "$AFTER_CHECKPOINT" instagram_identity_sha256)"
test "$(manifest_value "$ATTEMPT_RESULT" predecessor_audit_sha256)" = \
  "$predecessor_audit_sha"

readonly STAGING_DIRECTORY="$AUDIT_ROOT/.${LABEL}.in-progress"
[[ ! -e "$STAGING_DIRECTORY" ]]
mkdir "$STAGING_DIRECTORY"
chmod 0700 "$STAGING_DIRECTORY"
readonly TEMPORARY="$STAGING_DIRECTORY/fbig-profile-delivery-audit-v1.tsv"
{
  printf 'schema_version\t1\n'
  printf 'authorization_mode\t%s\n' "$AUTHORIZATION_MODE"
  printf 'authorization_sha256\t%s\n' "$AUTHORIZATION_SHA256"
  printf 'label\t%s\n' "$LABEL"
  printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
  printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
  printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
  printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
  printf 'acceptance_sha256\t%s\n' "$ACCEPTANCE_SHA256"
  printf 'attempt_result_sha256\t%s\n' "$(sha256_file "$ATTEMPT_RESULT")"
  printf 'attempt_manifest_sha256\t%s\n' \
    "$(manifest_value "$ATTEMPT_RESULT" attempt_manifest_sha256)"
  printf 'attempt_started_at\t%s\n' \
    "$(manifest_value "$ATTEMPT_RESULT" started_at)"
  printf 'attempt_finished_at\t%s\n' \
    "$(manifest_value "$ATTEMPT_RESULT" finished_at)"
  printf 'before_checkpoint_sha256\t%s\n' "$(sha256_file "$BEFORE_CHECKPOINT")"
  printf 'after_checkpoint_sha256\t%s\n' "$(sha256_file "$AFTER_CHECKPOINT")"
  printf 'audit_window_started_at\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" effective_window_start)"
  printf 'audit_window_finished_at\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" grace_end)"
  printf 'page_identity_sha256\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" page_identity_sha256)"
  printf 'instagram_identity_sha256\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" instagram_identity_sha256)"
  printf 'page_subscription_evidence_sha256\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" messenger_subscription_evidence_sha256)"
  printf 'instagram_subscription_evidence_sha256\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" instagram_subscription_evidence_sha256)"
  printf 'messenger_recon_summary_sha256\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" messenger_recon_summary_sha256)"
  printf 'instagram_recon_summary_sha256\t%s\n' \
    "$(manifest_value "$AFTER_CHECKPOINT" instagram_recon_summary_sha256)"
  printf 'messenger_missing\t0\n'
  printf 'instagram_missing\t0\n'
  printf 'messenger_threads_failed\t0\n'
  printf 'instagram_threads_failed\t0\n'
  printf 'messenger_caps_hit\t0\n'
  printf 'instagram_caps_hit\t0\n'
  printf 'zero_unrecovered_deliveries\ttrue\n'
  printf 'predecessor_audit_sha256\t%s\n' "$predecessor_audit_sha"
  printf 'audited_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$TEMPORARY"
chmod 0400 "$TEMPORARY"
fsync_path "$TEMPORARY"
seal_in_place "$TEMPORARY"
fsync_path "$STAGING_DIRECTORY"
publish_directory_no_replace "$STAGING_DIRECTORY" "$RESULT_DIRECTORY"
fsync_path "$AUDIT_ROOT"
validate_audit "$RESULT_MANIFEST"
printf '[UMI-FBIG] stage=profile_delivery_audit_complete label=%s manifest=%s\n' \
  "$LABEL" "$RESULT_MANIFEST"
