readonly ACTION="${1:?action is required (start|finalize)}"
readonly BINDING_MANIFEST="${2:?profile attempt binding is required}"
readonly BINDING_CHECKSUM="${BINDING_MANIFEST}.sha256"
PROGRAM_PATH="$(readlink -f "$0")"
readonly PROGRAM_PATH
readonly PROGRAM_CHECKSUM="${PROGRAM_PATH}.sha256"

readonly BINDING_FIELDS=(
  schema_version label profile_phase platforms dry_run require_zero_writes
  candidate_commit candidate_image stack_dir production_database audit_root
  inbox_id history_approval history_approval_checksum history_approval_sha256
  profile_approval profile_approval_checksum profile_approval_sha256
  profile_targets profile_targets_sha256 acceptance_manifest
  acceptance_checksum acceptance_sha256 profile_wrapper
  profile_wrapper_sha256 storage_helper storage_helper_sha256
  profile_attempt_root profile_backup_root
  predecessor_result predecessor_checksum predecessor_audit
  predecessor_audit_checksum before_checkpoint before_checkpoint_checksum
  production_lock
)
readonly PROFILE_APPROVAL_FIELDS=(
  schema_version history_manifest_sha256 repository_commit image_digest
  clone_database_name production_database_name account_id inbox_id
  facebook_page_id instagram_business_id platforms graph_delay_ms
  max_conversation_pages max_rate_limit_wait_seconds
  max_avatar_download_bytes placeholder_targets_sha256
  predecessor_profile_approval_sha256 predecessor_production_attempt_sha256
  source_profile_state_sha256 messenger_stable_target_count
  messenger_stable_target_fingerprint instagram_stable_target_count
  instagram_stable_target_fingerprint clone_profile_dry_log_sha256
  clone_profile_dry_summary_sha256 clone_profile_apply_log_sha256
  clone_profile_apply_summary_sha256 clone_profile_idempotency_log_sha256
  clone_profile_idempotency_summary_sha256 approved_by approved_at
)
readonly ACCEPTANCE_FIELDS=(
  schema_version acceptance_id candidate_commit candidate_image
  clone_database_name production_database_name account_id inbox_id
  facebook_page_id instagram_business_id history_approval_sha256
  profile_approval_sha256 profile_targets_sha256 clone_baseline_sha256
  messenger_history_terminal_summary_sha256
  instagram_history_terminal_summary_sha256 profile_terminal_summary_sha256
  unrecoverable_sidecar_sha256 artifact_index_sha256
  acceptance_binding_sha256 acceptance_program_sha256
  acceptance_control_sha256 unit_fragment_sha256
  prelaunch_descriptor_sha256 start_intent_sha256
  postlaunch_descriptor_sha256 invocation_id exit_status started_at
  finished_at sealed_at
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
readonly RESULT_FIELDS=(
  schema_version label profile_phase program_sha256 binding_sha256
  profile_wrapper_sha256 storage_helper_sha256 candidate_commit candidate_image
  production_database
  inbox_id acceptance_sha256 profile_approval_sha256
  predecessor_result_sha256 predecessor_audit_sha256 before_checkpoint_sha256
  attempt_identity_sha256 attempt_directory attempt_manifest_sha256
  pre_attempt_backup_directory pre_attempt_backup_sha256 wrapper_log_sha256
  wrapper_exit_status_sha256 platforms dry_run zero_write_observed
  termination started_at finished_at sealed_at
)
readonly ATTEMPT_FIELDS=(
  schema_version profile_approval_sha256 image_digest
  production_database_name platforms dry_run pre_attempt_backup_sha256
  prestate_sha256 poststate_sha256 avatar_staging_sha256 run_log_sha256
  run_summary_sha256 exit_status started_at finished_at
)
readonly COMPLETION_FIELDS=(
  schema_version attempt_id attempt_manifest_sha256 completed_at
)

[[ "$ACTION" =~ ^(start|finalize)$ ]] || die 'action must be start|finalize'
verify_checksum "$PROGRAM_PATH" "$PROGRAM_CHECKSUM"
verify_checksum "$BINDING_MANIFEST" "$BINDING_CHECKSUM"
require_ordered_manifest "$BINDING_MANIFEST" "${BINDING_FIELDS[@]}"
test "$(manifest_value "$BINDING_MANIFEST" schema_version)" = 1

LABEL="$(manifest_value "$BINDING_MANIFEST" label)"
PROFILE_PHASE="$(manifest_value "$BINDING_MANIFEST" profile_phase)"
PLATFORMS="$(manifest_value "$BINDING_MANIFEST" platforms)"
DRY_RUN="$(manifest_value "$BINDING_MANIFEST" dry_run)"
REQUIRE_ZERO_WRITES="$(manifest_value "$BINDING_MANIFEST" require_zero_writes)"
CANDIDATE_COMMIT="$(manifest_value "$BINDING_MANIFEST" candidate_commit)"
CANDIDATE_IMAGE="$(manifest_value "$BINDING_MANIFEST" candidate_image)"
STACK_DIR="$(manifest_value "$BINDING_MANIFEST" stack_dir)"
PRODUCTION_DATABASE="$(manifest_value "$BINDING_MANIFEST" production_database)"
AUDIT_ROOT="$(manifest_value "$BINDING_MANIFEST" audit_root)"
INBOX_ID="$(manifest_value "$BINDING_MANIFEST" inbox_id)"
HISTORY_APPROVAL="$(manifest_value "$BINDING_MANIFEST" history_approval)"
HISTORY_APPROVAL_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" history_approval_checksum
)"
HISTORY_APPROVAL_SHA256="$(
  manifest_value "$BINDING_MANIFEST" history_approval_sha256
)"
PROFILE_APPROVAL="$(manifest_value "$BINDING_MANIFEST" profile_approval)"
PROFILE_APPROVAL_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" profile_approval_checksum
)"
PROFILE_APPROVAL_SHA256="$(
  manifest_value "$BINDING_MANIFEST" profile_approval_sha256
)"
PROFILE_TARGETS="$(manifest_value "$BINDING_MANIFEST" profile_targets)"
PROFILE_TARGETS_SHA256="$(
  manifest_value "$BINDING_MANIFEST" profile_targets_sha256
)"
ACCEPTANCE_MANIFEST="$(manifest_value "$BINDING_MANIFEST" acceptance_manifest)"
ACCEPTANCE_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" acceptance_checksum)"
ACCEPTANCE_SHA256="$(manifest_value "$BINDING_MANIFEST" acceptance_sha256)"
PROFILE_WRAPPER="$(manifest_value "$BINDING_MANIFEST" profile_wrapper)"
PROFILE_WRAPPER_SHA256="$(
  manifest_value "$BINDING_MANIFEST" profile_wrapper_sha256
)"
STORAGE_HELPER="$(manifest_value "$BINDING_MANIFEST" storage_helper)"
STORAGE_HELPER_SHA256="$(
  manifest_value "$BINDING_MANIFEST" storage_helper_sha256
)"
PROFILE_ATTEMPT_ROOT="$(manifest_value "$BINDING_MANIFEST" profile_attempt_root)"
PROFILE_BACKUP_ROOT="$(manifest_value "$BINDING_MANIFEST" profile_backup_root)"
PREDECESSOR_RESULT="$(manifest_value "$BINDING_MANIFEST" predecessor_result)"
PREDECESSOR_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" predecessor_checksum)"
PREDECESSOR_AUDIT="$(manifest_value "$BINDING_MANIFEST" predecessor_audit)"
PREDECESSOR_AUDIT_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" predecessor_audit_checksum
)"
BEFORE_CHECKPOINT="$(manifest_value "$BINDING_MANIFEST" before_checkpoint)"
BEFORE_CHECKPOINT_CHECKSUM="$(
  manifest_value "$BINDING_MANIFEST" before_checkpoint_checksum
)"
PRODUCTION_LOCK="$(manifest_value "$BINDING_MANIFEST" production_lock)"
readonly LABEL PROFILE_PHASE PLATFORMS DRY_RUN REQUIRE_ZERO_WRITES
readonly CANDIDATE_COMMIT CANDIDATE_IMAGE STACK_DIR PRODUCTION_DATABASE
readonly AUDIT_ROOT INBOX_ID HISTORY_APPROVAL HISTORY_APPROVAL_CHECKSUM
readonly HISTORY_APPROVAL_SHA256 PROFILE_APPROVAL PROFILE_APPROVAL_CHECKSUM
readonly PROFILE_APPROVAL_SHA256 PROFILE_TARGETS PROFILE_TARGETS_SHA256
readonly ACCEPTANCE_MANIFEST ACCEPTANCE_CHECKSUM ACCEPTANCE_SHA256
readonly PROFILE_WRAPPER PROFILE_WRAPPER_SHA256 PROFILE_ATTEMPT_ROOT
readonly STORAGE_HELPER STORAGE_HELPER_SHA256
readonly PROFILE_BACKUP_ROOT PREDECESSOR_RESULT PREDECESSOR_CHECKSUM
readonly PREDECESSOR_AUDIT PREDECESSOR_AUDIT_CHECKSUM BEFORE_CHECKPOINT
readonly BEFORE_CHECKPOINT_CHECKSUM PRODUCTION_LOCK

require_safe_token label "$LABEL"
[[ "${#LABEL}" -le 32 ]]
[[ "$PROFILE_PHASE" =~ ^(dry|apply|idempotency)$ ]]
[[ "$PLATFORMS" = messenger,instagram ]]
[[ "$DRY_RUN" =~ ^(true|false)$ ]]
[[ "$REQUIRE_ZERO_WRITES" =~ ^(true|false)$ ]]
if [[ "$PROFILE_PHASE" = dry ]]; then
  [[ "$DRY_RUN" = true && "$REQUIRE_ZERO_WRITES" = false ]]
else
  [[ "$DRY_RUN" = false ]]
fi
[[ "$PROFILE_PHASE" != idempotency || "$REQUIRE_ZERO_WRITES" = true ]]
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$CANDIDATE_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]
[[ "$PRODUCTION_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
require_root_directory "$STACK_DIR"
require_root_directory "$AUDIT_ROOT"
require_root_directory "$PROFILE_ATTEMPT_ROOT"
require_root_directory "$PROFILE_BACKUP_ROOT"
require_root_artifact "$PROFILE_WRAPPER"
test "$(sha256_file "$PROFILE_WRAPPER")" = "$PROFILE_WRAPPER_SHA256"
require_root_artifact "$STORAGE_HELPER"
test "$(sha256_file "$STORAGE_HELPER")" = "$STORAGE_HELPER_SHA256"
test "$PRODUCTION_LOCK" = /run/lock/umi-fbig/production.lock

verify_checksum "$HISTORY_APPROVAL" "$HISTORY_APPROVAL_CHECKSUM"
test "$(sha256_file "$HISTORY_APPROVAL")" = "$HISTORY_APPROVAL_SHA256"
verify_checksum "$PROFILE_APPROVAL" "$PROFILE_APPROVAL_CHECKSUM"
require_ordered_manifest "$PROFILE_APPROVAL" "${PROFILE_APPROVAL_FIELDS[@]}"
test "$(sha256_file "$PROFILE_APPROVAL")" = "$PROFILE_APPROVAL_SHA256"
test "$(manifest_value "$PROFILE_APPROVAL" history_manifest_sha256)" = \
  "$HISTORY_APPROVAL_SHA256"
test "$(manifest_value "$PROFILE_APPROVAL" repository_commit)" = "$CANDIDATE_COMMIT"
test "$(manifest_value "$PROFILE_APPROVAL" image_digest)" = "$CANDIDATE_IMAGE"
test "$(manifest_value "$PROFILE_APPROVAL" production_database_name)" = \
  "$PRODUCTION_DATABASE"
test "$(manifest_value "$PROFILE_APPROVAL" inbox_id)" = "$INBOX_ID"
require_root_artifact "$PROFILE_TARGETS"
test "$(sha256_file "$PROFILE_TARGETS")" = "$PROFILE_TARGETS_SHA256"
test "$(manifest_value "$PROFILE_APPROVAL" placeholder_targets_sha256)" = \
  "$PROFILE_TARGETS_SHA256"

verify_checksum "$ACCEPTANCE_MANIFEST" "$ACCEPTANCE_CHECKSUM"
require_ordered_manifest "$ACCEPTANCE_MANIFEST" "${ACCEPTANCE_FIELDS[@]}"
test "$(sha256_file "$ACCEPTANCE_MANIFEST")" = "$ACCEPTANCE_SHA256"
test "$(manifest_value "$ACCEPTANCE_MANIFEST" candidate_commit)" = \
  "$CANDIDATE_COMMIT"
test "$(manifest_value "$ACCEPTANCE_MANIFEST" candidate_image)" = \
  "$CANDIDATE_IMAGE"
test "$(manifest_value "$ACCEPTANCE_MANIFEST" profile_approval_sha256)" = \
  "$PROFILE_APPROVAL_SHA256"
test "$(manifest_value "$ACCEPTANCE_MANIFEST" profile_targets_sha256)" = \
  "$PROFILE_TARGETS_SHA256"
test "$(manifest_value "$ACCEPTANCE_MANIFEST" exit_status)" = 0

verify_checksum "$BEFORE_CHECKPOINT" "$BEFORE_CHECKPOINT_CHECKSUM"
require_ordered_manifest "$BEFORE_CHECKPOINT" "${CHECKPOINT_FIELDS[@]}"
test "$(manifest_value "$BEFORE_CHECKPOINT" candidate_commit)" = \
  "$CANDIDATE_COMMIT"
test "$(manifest_value "$BEFORE_CHECKPOINT" candidate_image)" = \
  "$CANDIDATE_IMAGE"
test "$(manifest_value "$BEFORE_CHECKPOINT" production_database)" = \
  "$PRODUCTION_DATABASE"
test "$(manifest_value "$BEFORE_CHECKPOINT" inbox_id)" = "$INBOX_ID"

predecessor_result_sha=none
predecessor_audit_sha=none
if [[ "$PREDECESSOR_RESULT" = none ]]; then
  [[ "$PROFILE_PHASE" = dry ]]
  [[ "$PREDECESSOR_CHECKSUM" = none ]]
  [[ "$PREDECESSOR_AUDIT" = none && "$PREDECESSOR_AUDIT_CHECKSUM" = none ]]
else
  verify_checksum "$PREDECESSOR_RESULT" "$PREDECESSOR_CHECKSUM"
  require_ordered_manifest "$PREDECESSOR_RESULT" "${RESULT_FIELDS[@]}"
  verify_checksum "$PREDECESSOR_AUDIT" "$PREDECESSOR_AUDIT_CHECKSUM"
  test "$(manifest_value "$PREDECESSOR_RESULT" candidate_commit)" = \
    "$CANDIDATE_COMMIT"
  test "$(manifest_value "$PREDECESSOR_RESULT" acceptance_sha256)" = \
    "$ACCEPTANCE_SHA256"
  predecessor_result_sha="$(sha256_file "$PREDECESSOR_RESULT")"
  predecessor_audit_sha="$(sha256_file "$PREDECESSOR_AUDIT")"
fi
readonly predecessor_result_sha predecessor_audit_sha

readonly RESULT_DIRECTORY="$AUDIT_ROOT/$LABEL"
readonly IN_PROGRESS_DIRECTORY="$AUDIT_ROOT/.${LABEL}.in-progress"
readonly RESULT_MANIFEST="$RESULT_DIRECTORY/fbig-profile-attempt-result-v1.tsv"
readonly ATTEMPT_IDENTITY="$IN_PROGRESS_DIRECTORY/fbig-profile-attempt-identity-v1.tsv"
readonly START_GATE="$IN_PROGRESS_DIRECTORY/wrapper-start-authorized"
readonly WRAPPER_LOG="$IN_PROGRESS_DIRECTORY/fbig-profile-wrapper.log"
readonly WRAPPER_EXIT="$IN_PROGRESS_DIRECTORY/fbig-profile-wrapper-exit-v1.tsv"

validate_result() {
  local manifest="$1"
  local result_directory
  local identity
  local wrapper_log
  local wrapper_exit
  local attempt_directory
  local attempt_manifest
  local backup_directory
  local backup_manifest

  verify_checksum "$manifest" "${manifest}.sha256"
  require_ordered_manifest "$manifest" "${RESULT_FIELDS[@]}"
  test "$(manifest_value "$manifest" schema_version)" = 1
  test "$(manifest_value "$manifest" label)" = "$LABEL"
  test "$(manifest_value "$manifest" profile_phase)" = "$PROFILE_PHASE"
  test "$(manifest_value "$manifest" program_sha256)" = \
    "$(sha256_file "$PROGRAM_PATH")"
  test "$(manifest_value "$manifest" binding_sha256)" = \
    "$(sha256_file "$BINDING_MANIFEST")"
  test "$(manifest_value "$manifest" profile_wrapper_sha256)" = \
    "$PROFILE_WRAPPER_SHA256"
  test "$(manifest_value "$manifest" storage_helper_sha256)" = \
    "$STORAGE_HELPER_SHA256"
  test "$(manifest_value "$manifest" candidate_commit)" = "$CANDIDATE_COMMIT"
  test "$(manifest_value "$manifest" candidate_image)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$manifest" production_database)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$manifest" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$manifest" acceptance_sha256)" = "$ACCEPTANCE_SHA256"
  test "$(manifest_value "$manifest" profile_approval_sha256)" = \
    "$PROFILE_APPROVAL_SHA256"
  test "$(manifest_value "$manifest" predecessor_result_sha256)" = \
    "$predecessor_result_sha"
  test "$(manifest_value "$manifest" predecessor_audit_sha256)" = \
    "$predecessor_audit_sha"
  test "$(manifest_value "$manifest" before_checkpoint_sha256)" = \
    "$(sha256_file "$BEFORE_CHECKPOINT")"
  test "$(manifest_value "$manifest" platforms)" = "$PLATFORMS"
  test "$(manifest_value "$manifest" dry_run)" = "$DRY_RUN"
  [[ "$(manifest_value "$manifest" zero_write_observed)" =~ ^(true|false)$ ]]
  result_directory="$(dirname "$manifest")"
  identity="$result_directory/fbig-profile-attempt-identity-v1.tsv"
  wrapper_log="$result_directory/fbig-profile-wrapper.log"
  wrapper_exit="$result_directory/fbig-profile-wrapper-exit-v1.tsv"
  verify_checksum "$identity" "${identity}.sha256"
  verify_checksum "$wrapper_log" "${wrapper_log}.sha256"
  test "$(manifest_value "$manifest" attempt_identity_sha256)" = \
    "$(sha256_file "$identity")"
  test "$(manifest_value "$manifest" wrapper_log_sha256)" = \
    "$(sha256_file "$wrapper_log")"
  if [[ "$(manifest_value "$manifest" wrapper_exit_status_sha256)" = none ]]; then
    test ! -e "$wrapper_exit"
  else
    verify_checksum "$wrapper_exit" "${wrapper_exit}.sha256"
    test "$(manifest_value "$manifest" wrapper_exit_status_sha256)" = \
      "$(sha256_file "$wrapper_exit")"
    test "$(manifest_value "$wrapper_exit" wrapper_status)" = 0
  fi
  attempt_directory="$(manifest_value "$manifest" attempt_directory)"
  backup_directory="$(manifest_value "$manifest" pre_attempt_backup_directory)"
  test "$(dirname "$attempt_directory")" = "$PROFILE_ATTEMPT_ROOT"
  test "$(dirname "$backup_directory")" = "$PROFILE_BACKUP_ROOT"
  attempt_manifest="$attempt_directory/fbig-profile-production-attempt-v1.tsv"
  backup_manifest="$backup_directory/fbig-profile-pre-attempt-backup-v1.tsv"
  verify_checksum "$attempt_manifest" "${attempt_manifest}.sha256"
  verify_checksum "$backup_manifest" "${backup_manifest}.sha256"
  test "$(manifest_value "$manifest" attempt_manifest_sha256)" = \
    "$(sha256_file "$attempt_manifest")"
  test "$(manifest_value "$manifest" pre_attempt_backup_sha256)" = \
    "$(sha256_file "$backup_manifest")"
}

if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_result "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=profile_attempt_validated label=%s manifest=%s\n' \
    "$LABEL" "$RESULT_MANIFEST"
  exit 0
fi

process_is_live() {
  local pid="$1"
  local boot_id="$2"
  local start_ticks="$3"

  [[ -d "/proc/$pid" ]] || return 1
  [[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id" ]] || return 1
  [[ "$(awk '{ print $22 }' "/proc/$pid/stat")" = "$start_ticks" ]]
}

start_attempt() {
  local wrapper_pid
  local boot_id
  local start_ticks
  local started_at
  local identity_temporary
  local exit_temporary
  local wrapper_status

  [[ ! -e "$IN_PROGRESS_DIRECTORY" ]]
  mkdir "$IN_PROGRESS_DIRECTORY"
  chmod 0700 "$IN_PROGRESS_DIRECTORY"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (
    for _gate_wait in {1..1200}; do
      [[ -e "$START_GATE" ]] && exec env \
        CHATWOOT_STACK_DIR="$STACK_DIR" \
        CHATWOOT_DATABASE_NAME="$PRODUCTION_DATABASE" \
        FBIG_ATTEMPT_ROOT="$PROFILE_ATTEMPT_ROOT" \
        FBIG_BACKUP_ROOT="$PROFILE_BACKUP_ROOT" \
        FBIG_STORAGE_HELPER="$STORAGE_HELPER" \
        /bin/bash "$PROFILE_WRAPPER" \
        "$INBOX_ID" "$DRY_RUN" "$PLATFORMS" \
        "$HISTORY_APPROVAL" "$HISTORY_APPROVAL_CHECKSUM" \
        "$PROFILE_APPROVAL" "$PROFILE_APPROVAL_CHECKSUM" "$PROFILE_TARGETS"
      sleep 0.05
    done
    exit 75
  ) >"$WRAPPER_LOG" 2>&1 &
  wrapper_pid=$!
  boot_id="$(cat /proc/sys/kernel/random/boot_id)"
  start_ticks="$(awk '{ print $22 }' "/proc/$wrapper_pid/stat")"
  identity_temporary="${ATTEMPT_IDENTITY}.$$.tmp"
  (
    set -o noclobber
    {
      printf 'schema_version\t1\n'
      printf 'label\t%s\n' "$LABEL"
      printf 'profile_phase\t%s\n' "$PROFILE_PHASE"
      printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
      printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
      printf 'profile_wrapper_sha256\t%s\n' "$PROFILE_WRAPPER_SHA256"
      printf 'storage_helper_sha256\t%s\n' "$STORAGE_HELPER_SHA256"
      printf 'wrapper_pid\t%s\n' "$wrapper_pid"
      printf 'boot_id\t%s\n' "$boot_id"
      printf 'wrapper_start_ticks\t%s\n' "$start_ticks"
      printf 'started_at\t%s\n' "$started_at"
    } >"$identity_temporary"
  )
  publish_artifact "$identity_temporary" "$ATTEMPT_IDENTITY"
  (
    set -o noclobber
    printf 'authorized\n' >"$START_GATE"
  )
  chmod 0400 "$START_GATE"
  fsync_path "$START_GATE"
  set +e
  wait "$wrapper_pid"
  wrapper_status=$?
  set -e
  exit_temporary="${WRAPPER_EXIT}.$$.tmp"
  (
    set -o noclobber
    {
      printf 'schema_version\t1\n'
      printf 'wrapper_status\t%s\n' "$wrapper_status"
      printf 'finished_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$exit_temporary"
  )
  publish_artifact "$exit_temporary" "$WRAPPER_EXIT"
  [[ "$wrapper_status" -eq 0 ]] ||
    die "profile wrapper failed with status $wrapper_status"
  finalize_attempt false
}

finalize_attempt() {
  local adopted="$1"
  local wrapper_pid
  local boot_id
  local start_ticks
  local attempt_directory
  local backup_directory
  local attempt_manifest
  local completion
  local summary
  local run_log
  local prestate
  local poststate
  local staging
  local backup_manifest
  local observed_zero=true
  local termination=normal
  local counter
  local placeholder_remaining
  local placeholder_unavailable
  local placeholder_blank_name
  local temporary

  require_root_directory "$IN_PROGRESS_DIRECTORY"
  verify_checksum "$ATTEMPT_IDENTITY" "${ATTEMPT_IDENTITY}.sha256"
  wrapper_pid="$(manifest_value "$ATTEMPT_IDENTITY" wrapper_pid)"
  boot_id="$(manifest_value "$ATTEMPT_IDENTITY" boot_id)"
  start_ticks="$(manifest_value "$ATTEMPT_IDENTITY" wrapper_start_ticks)"
  if process_is_live "$wrapper_pid" "$boot_id" "$start_ticks"; then
    die 'profile wrapper is still live'
  fi

  if [[ -e "$WRAPPER_EXIT" ]]; then
    verify_checksum "$WRAPPER_EXIT" "${WRAPPER_EXIT}.sha256"
    test "$(manifest_value "$WRAPPER_EXIT" wrapper_status)" = 0
  else
    adopted=true
    termination=adopted_after_wrapper_exit
  fi
  test "$(grep -c '^\[UMI-FBIG\] stage=profile_attempt_complete ' "$WRAPPER_LOG")" = 1
  attempt_directory="$(
    stage_value "$WRAPPER_LOG" profile_attempt_complete attempt_directory
  )"
  backup_directory="$(
    stage_value "$WRAPPER_LOG" profile_attempt_complete backup_directory
  )"
  test "$(dirname "$attempt_directory")" = "$PROFILE_ATTEMPT_ROOT"
  test "$(dirname "$backup_directory")" = "$PROFILE_BACKUP_ROOT"
  require_root_directory "$attempt_directory"
  require_root_directory "$backup_directory"

  attempt_manifest="$attempt_directory/fbig-profile-production-attempt-v1.tsv"
  completion="$attempt_directory/fbig-profile-attempt-complete-v1.tsv"
  summary="$attempt_directory/fbig-profile-production-run-summary.tsv"
  run_log="$attempt_directory/fbig-profile-production-run.log"
  prestate="$attempt_directory/fbig-profile-production-prestate-v1.tsv"
  poststate="$attempt_directory/fbig-profile-production-poststate-v1.tsv"
  staging="$attempt_directory/fbig-profile-avatar-staging-v1.tsv"
  backup_manifest="$backup_directory/fbig-profile-pre-attempt-backup-v1.tsv"
  for artifact in \
    "$attempt_manifest" "${attempt_manifest}.sha256" "$completion" \
    "$summary" "$run_log" "$prestate" "${prestate}.sha256" \
    "$poststate" "${poststate}.sha256" "$staging" "${staging}.sha256" \
    "$backup_manifest" "${backup_manifest}.sha256"; do
    require_root_artifact "$artifact"
  done
  verify_checksum "$attempt_manifest" "${attempt_manifest}.sha256"
  require_ordered_manifest "$attempt_manifest" "${ATTEMPT_FIELDS[@]}"
  require_ordered_manifest "$completion" "${COMPLETION_FIELDS[@]}"
  verify_checksum "$prestate" "${prestate}.sha256"
  verify_checksum "$poststate" "${poststate}.sha256"
  verify_checksum "$staging" "${staging}.sha256"
  verify_checksum "$backup_manifest" "${backup_manifest}.sha256"
  test "$(manifest_value "$attempt_manifest" profile_approval_sha256)" = \
    "$PROFILE_APPROVAL_SHA256"
  test "$(manifest_value "$attempt_manifest" image_digest)" = "$CANDIDATE_IMAGE"
  test "$(manifest_value "$attempt_manifest" production_database_name)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$attempt_manifest" platforms)" = "$PLATFORMS"
  test "$(manifest_value "$attempt_manifest" dry_run)" = "$DRY_RUN"
  test "$(manifest_value "$attempt_manifest" exit_status)" = 0
  test "$(manifest_value "$attempt_manifest" pre_attempt_backup_sha256)" = \
    "$(sha256_file "$backup_manifest")"
  test "$(manifest_value "$attempt_manifest" prestate_sha256)" = \
    "$(sha256_file "$prestate")"
  test "$(manifest_value "$attempt_manifest" poststate_sha256)" = \
    "$(sha256_file "$poststate")"
  test "$(manifest_value "$attempt_manifest" avatar_staging_sha256)" = \
    "$(sha256_file "$staging")"
  test "$(manifest_value "$attempt_manifest" run_log_sha256)" = \
    "$(sha256_file "$run_log")"
  test "$(manifest_value "$attempt_manifest" run_summary_sha256)" = \
    "$(sha256_file "$summary")"
  test "$(manifest_value "$completion" attempt_manifest_sha256)" = \
    "$(sha256_file "$attempt_manifest")"
  test "$(stage_value "$summary" history_profiles_summary scan_complete)" = true

  if [[ "$DRY_RUN" = true ]]; then
    test "$(stage_value "$summary" history_profiles_summary write_complete)" = \
      not_applicable
    observed_zero=false
  else
    test "$(stage_value "$summary" history_profiles_summary write_complete)" = true
    cmp -s "$prestate" "$poststate" || observed_zero=false
    for counter in \
      scalar_changes_applied name_changes_applied username_changes_applied \
      optional_changes_applied avatars_attached avatar_bytes mirror_jobs; do
      [[ "$(stage_value "$summary" history_profiles_summary "$counter")" = 0 ]] ||
        observed_zero=false
    done
  fi
  for counter in \
    exit_failures lock_loss profile_errors avatar_failures \
    messenger_targets_blocking instagram_targets_blocking \
    seed_targets_blocking; do
    test "$(stage_value "$summary" history_profiles_summary "$counter")" = 0
  done
  if [[ "$DRY_RUN" = false ]]; then
    placeholder_remaining="$(
      stage_value "$summary" history_profiles_summary \
        instagram_placeholders_remaining
    )"
    placeholder_unavailable="$(
      stage_value "$summary" history_profiles_summary \
        instagram_placeholders_unavailable
    )"
    placeholder_blank_name="$(
      stage_value "$summary" history_profiles_summary \
        instagram_placeholders_blank_name
    )"
    test "$(stage_value "$summary" history_profiles_summary \
      instagram_placeholders_projected_repair)" = 0
    test "$(stage_value "$summary" history_profiles_summary \
      instagram_placeholders_unclassified)" = 0
    test "$placeholder_remaining" = \
      "$((placeholder_unavailable + placeholder_blank_name))"
    test "$(stage_value "$summary" history_profiles_summary \
      instagram_placeholders_remaining_fingerprint)" = "$(
      stage_value "$summary" history_profiles_summary \
        instagram_placeholders_classified_fingerprint
    )"
  fi
  if [[ "$REQUIRE_ZERO_WRITES" = true && "$observed_zero" != true ]]; then
    die 'profile attempt did not reach zero writes'
  fi

  seal_in_place "$WRAPPER_LOG"
  seal_in_place "$START_GATE"
  seal_in_place "$completion"
  seal_in_place "$summary"
  seal_in_place "$run_log"
  temporary="$IN_PROGRESS_DIRECTORY/fbig-profile-attempt-result-v1.tsv.$$.tmp"
  (
    set -o noclobber
    {
      printf 'schema_version\t1\n'
      printf 'label\t%s\n' "$LABEL"
      printf 'profile_phase\t%s\n' "$PROFILE_PHASE"
      printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
      printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
      printf 'profile_wrapper_sha256\t%s\n' "$PROFILE_WRAPPER_SHA256"
      printf 'storage_helper_sha256\t%s\n' "$STORAGE_HELPER_SHA256"
      printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
      printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
      printf 'production_database\t%s\n' "$PRODUCTION_DATABASE"
      printf 'inbox_id\t%s\n' "$INBOX_ID"
      printf 'acceptance_sha256\t%s\n' "$ACCEPTANCE_SHA256"
      printf 'profile_approval_sha256\t%s\n' "$PROFILE_APPROVAL_SHA256"
      printf 'predecessor_result_sha256\t%s\n' "$predecessor_result_sha"
      printf 'predecessor_audit_sha256\t%s\n' "$predecessor_audit_sha"
      printf 'before_checkpoint_sha256\t%s\n' \
        "$(sha256_file "$BEFORE_CHECKPOINT")"
      printf 'attempt_identity_sha256\t%s\n' "$(sha256_file "$ATTEMPT_IDENTITY")"
      printf 'attempt_directory\t%s\n' "$attempt_directory"
      printf 'attempt_manifest_sha256\t%s\n' "$(sha256_file "$attempt_manifest")"
      printf 'pre_attempt_backup_directory\t%s\n' "$backup_directory"
      printf 'pre_attempt_backup_sha256\t%s\n' "$(sha256_file "$backup_manifest")"
      printf 'wrapper_log_sha256\t%s\n' "$(sha256_file "$WRAPPER_LOG")"
      if [[ -e "$WRAPPER_EXIT" ]]; then
        printf 'wrapper_exit_status_sha256\t%s\n' "$(sha256_file "$WRAPPER_EXIT")"
      else
        printf 'wrapper_exit_status_sha256\tnone\n'
      fi
      printf 'platforms\t%s\n' "$PLATFORMS"
      printf 'dry_run\t%s\n' "$DRY_RUN"
      printf 'zero_write_observed\t%s\n' "$observed_zero"
      printf 'termination\t%s\n' "$termination"
      printf 'started_at\t%s\n' \
        "$(manifest_value "$attempt_manifest" started_at)"
      printf 'finished_at\t%s\n' \
        "$(manifest_value "$attempt_manifest" finished_at)"
      printf 'sealed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$temporary"
  )
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  mv "$temporary" "$IN_PROGRESS_DIRECTORY/fbig-profile-attempt-result-v1.tsv"
  seal_in_place "$IN_PROGRESS_DIRECTORY/fbig-profile-attempt-result-v1.tsv"
  fsync_path "$IN_PROGRESS_DIRECTORY"
  publish_directory_no_replace "$IN_PROGRESS_DIRECTORY" "$RESULT_DIRECTORY"
  fsync_path "$AUDIT_ROOT"
  validate_result "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=profile_attempt_complete label=%s manifest=%s adopted=%s\n' \
    "$LABEL" "$RESULT_MANIFEST" "$adopted"
}

if [[ "$ACTION" = start ]]; then
  start_attempt
else
  finalize_attempt true
fi
