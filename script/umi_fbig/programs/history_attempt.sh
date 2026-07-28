
readonly ACTION="${1:?start or finalize is required}"
readonly BINDING_MANIFEST="${2:?history attempt binding is required}"
readonly BINDING_CHECKSUM="${BINDING_MANIFEST}.sha256"
PROGRAM_PATH="$(readlink -f "$0")"
readonly PROGRAM_PATH
readonly PROGRAM_CHECKSUM="${PROGRAM_PATH}.sha256"

readonly BINDING_FIELDS=(
  schema_version label operation platforms require_zero_writes candidate_commit
  candidate_image stack_dir compose_file compose_file_sha256 compose_project
  rails_service sidekiq_service production_database audit_root inbox_id
  history_approval history_approval_checksum history_approval_sha256
  acceptance_manifest acceptance_checksum acceptance_sha256
  pre_history_backup_manifest pre_history_backup_checksum
  pre_history_backup_sha256 max_download_bytes ack_single_conversation_reopen
  graph_delay_ms max_conversation_pages max_message_pages dry_result_1
  dry_result_1_checksum dry_result_2 dry_result_2_checksum
  predecessor_result predecessor_checksum production_lock
)
readonly HISTORY_APPROVAL_FIELDS=(
  schema_version repository_commit image_digest clone_backup_id
  clone_database_name database_dump_sha256 source_storage_manifest_sha256
  restored_storage_manifest_sha256 account_id inbox_id facebook_page_id
  instagram_business_id since before outbound_policy profile_mode
  messenger_count messenger_fingerprint instagram_count instagram_fingerprint
  messenger_unavailable_message_thread_count
  messenger_unavailable_message_thread_fingerprint
  instagram_unavailable_message_thread_count
  instagram_unavailable_message_thread_fingerprint
  placeholder_targets_sha256 source_dry_log_sha256 source_dry_summary_sha256
  approved_by approved_at
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
readonly UNRECOVERABLE_SIDECAR_FIELDS=(
  schema_version repository_commit image_digest account_id inbox_id
  instagram_business_id before platform count fingerprint
  inspector_script_sha256 approved_by approved_at
)
readonly RESULT_FIELDS=(
  schema_version label operation platforms require_zero_writes program_sha256
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

[[ "$ACTION" = start || "$ACTION" = finalize ]] || die "action must be start or finalize"
require_root_artifact "$PROGRAM_PATH"
verify_checksum "$PROGRAM_PATH" "$PROGRAM_CHECKSUM"
verify_checksum "$BINDING_MANIFEST" "$BINDING_CHECKSUM"
require_ordered_manifest "$BINDING_MANIFEST" "${BINDING_FIELDS[@]}"
[[ "$(manifest_value "$BINDING_MANIFEST" schema_version)" = 1 ]] ||
  die "unsupported history binding schema"

LABEL="$(manifest_value "$BINDING_MANIFEST" label)"
OPERATION="$(manifest_value "$BINDING_MANIFEST" operation)"
PLATFORMS="$(manifest_value "$BINDING_MANIFEST" platforms)"
REQUIRE_ZERO_WRITES="$(manifest_value "$BINDING_MANIFEST" require_zero_writes)"
CANDIDATE_COMMIT="$(manifest_value "$BINDING_MANIFEST" candidate_commit)"
CANDIDATE_IMAGE="$(manifest_value "$BINDING_MANIFEST" candidate_image)"
STACK_DIR="$(manifest_value "$BINDING_MANIFEST" stack_dir)"
COMPOSE_FILE="$(manifest_value "$BINDING_MANIFEST" compose_file)"
COMPOSE_FILE_SHA256="$(manifest_value "$BINDING_MANIFEST" compose_file_sha256)"
COMPOSE_PROJECT="$(manifest_value "$BINDING_MANIFEST" compose_project)"
RAILS_SERVICE="$(manifest_value "$BINDING_MANIFEST" rails_service)"
SIDEKIQ_SERVICE="$(manifest_value "$BINDING_MANIFEST" sidekiq_service)"
PRODUCTION_DATABASE="$(manifest_value "$BINDING_MANIFEST" production_database)"
AUDIT_ROOT="$(manifest_value "$BINDING_MANIFEST" audit_root)"
INBOX_ID="$(manifest_value "$BINDING_MANIFEST" inbox_id)"
HISTORY_APPROVAL="$(manifest_value "$BINDING_MANIFEST" history_approval)"
HISTORY_APPROVAL_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" history_approval_checksum)"
HISTORY_APPROVAL_SHA256="$(manifest_value "$BINDING_MANIFEST" history_approval_sha256)"
ACCEPTANCE_MANIFEST="$(manifest_value "$BINDING_MANIFEST" acceptance_manifest)"
ACCEPTANCE_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" acceptance_checksum)"
ACCEPTANCE_SHA256="$(manifest_value "$BINDING_MANIFEST" acceptance_sha256)"
PRE_HISTORY_BACKUP_MANIFEST="$(manifest_value "$BINDING_MANIFEST" pre_history_backup_manifest)"
PRE_HISTORY_BACKUP_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" pre_history_backup_checksum)"
PRE_HISTORY_BACKUP_SHA256="$(manifest_value "$BINDING_MANIFEST" pre_history_backup_sha256)"
MAX_DOWNLOAD_BYTES="$(manifest_value "$BINDING_MANIFEST" max_download_bytes)"
ACK_SINGLE_CONVERSATION_REOPEN="$(
  manifest_value "$BINDING_MANIFEST" ack_single_conversation_reopen
)"
GRAPH_DELAY_MS="$(manifest_value "$BINDING_MANIFEST" graph_delay_ms)"
MAX_CONVERSATION_PAGES="$(manifest_value "$BINDING_MANIFEST" max_conversation_pages)"
MAX_MESSAGE_PAGES="$(manifest_value "$BINDING_MANIFEST" max_message_pages)"
DRY_RESULT_1="$(manifest_value "$BINDING_MANIFEST" dry_result_1)"
DRY_RESULT_1_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" dry_result_1_checksum)"
DRY_RESULT_2="$(manifest_value "$BINDING_MANIFEST" dry_result_2)"
DRY_RESULT_2_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" dry_result_2_checksum)"
PREDECESSOR_RESULT="$(manifest_value "$BINDING_MANIFEST" predecessor_result)"
PREDECESSOR_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" predecessor_checksum)"
PRODUCTION_LOCK="$(manifest_value "$BINDING_MANIFEST" production_lock)"
readonly LABEL OPERATION PLATFORMS REQUIRE_ZERO_WRITES CANDIDATE_COMMIT CANDIDATE_IMAGE
readonly STACK_DIR COMPOSE_FILE COMPOSE_FILE_SHA256 COMPOSE_PROJECT RAILS_SERVICE
readonly SIDEKIQ_SERVICE PRODUCTION_DATABASE AUDIT_ROOT INBOX_ID
readonly HISTORY_APPROVAL HISTORY_APPROVAL_CHECKSUM HISTORY_APPROVAL_SHA256
readonly ACCEPTANCE_MANIFEST ACCEPTANCE_CHECKSUM ACCEPTANCE_SHA256
readonly PRE_HISTORY_BACKUP_MANIFEST PRE_HISTORY_BACKUP_CHECKSUM
readonly PRE_HISTORY_BACKUP_SHA256 MAX_DOWNLOAD_BYTES ACK_SINGLE_CONVERSATION_REOPEN
readonly GRAPH_DELAY_MS MAX_CONVERSATION_PAGES MAX_MESSAGE_PAGES
readonly DRY_RESULT_1 DRY_RESULT_1_CHECKSUM DRY_RESULT_2 DRY_RESULT_2_CHECKSUM
readonly PREDECESSOR_RESULT PREDECESSOR_CHECKSUM PRODUCTION_LOCK

require_safe_token label "$LABEL"
[[ "${#LABEL}" -le 32 ]] || die "history label is too long"
[[ "$OPERATION" = dry || "$OPERATION" = apply ]] || die "invalid history operation"
[[ "$PLATFORMS" = messenger || "$PLATFORMS" = instagram ]] ||
  die "production history attempts must select exactly one platform"
[[ "$REQUIRE_ZERO_WRITES" = true || "$REQUIRE_ZERO_WRITES" = false ]] ||
  die "invalid zero-write requirement"
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid candidate commit"
[[ "$CANDIDATE_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] ||
  die "candidate image must be digest-pinned"
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]] || die "invalid inbox id"
for number in "$GRAPH_DELAY_MS" "$MAX_CONVERSATION_PAGES" "$MAX_MESSAGE_PAGES"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || die "invalid graph bound"
done
[[ "$ACK_SINGLE_CONVERSATION_REOPEN" = true ]] ||
  die "single-conversation reopen acknowledgement is required"
if [[ "$OPERATION" = dry ]]; then
  [[ "$REQUIRE_ZERO_WRITES" = true && "$MAX_DOWNLOAD_BYTES" = none ]] ||
    die "dry attempts must require zero writes and no download budget"
  [[ "$DRY_RESULT_1" = none && "$DRY_RESULT_1_CHECKSUM" = none &&
    "$DRY_RESULT_2" = none && "$DRY_RESULT_2_CHECKSUM" = none ]] ||
    die "dry attempts cannot consume dry-pair authorization"
else
  [[ "$MAX_DOWNLOAD_BYTES" =~ ^[1-9][0-9]*$ ]] ||
    die "apply attempts require a positive download budget"
  [[ "$DRY_RESULT_1" != none && "$DRY_RESULT_2" != none &&
    "$DRY_RESULT_1" != "$DRY_RESULT_2" ]] ||
    die "apply attempts require two distinct dry results"
fi
require_safe_token compose_project "$COMPOSE_PROJECT"
require_safe_token rails_service "$RAILS_SERVICE"
require_safe_token sidekiq_service "$SIDEKIQ_SERVICE"
require_safe_token production_database "$PRODUCTION_DATABASE"
require_root_directory "$STACK_DIR"
require_root_readonly_file "$COMPOSE_FILE"
[[ "$(sha256_file "$COMPOSE_FILE")" = "$COMPOSE_FILE_SHA256" ]] ||
  die "Compose file checksum mismatch"
require_root_directory "$AUDIT_ROOT"

verify_checksum "$HISTORY_APPROVAL" "$HISTORY_APPROVAL_CHECKSUM"
require_ordered_manifest "$HISTORY_APPROVAL" "${HISTORY_APPROVAL_FIELDS[@]}"
[[ "$(manifest_value "$HISTORY_APPROVAL" schema_version)" = 2 ]] ||
  die "unsupported history approval schema"
[[ "$(sha256_file "$HISTORY_APPROVAL")" = "$HISTORY_APPROVAL_SHA256" ]] ||
  die "history approval SHA mismatch"
[[ "$(manifest_value "$HISTORY_APPROVAL" repository_commit)" = "$CANDIDATE_COMMIT" ]] ||
  die "history approval commit mismatch"
[[ "$(manifest_value "$HISTORY_APPROVAL" image_digest)" = "$CANDIDATE_IMAGE" ]] ||
  die "history approval image mismatch"
[[ "$(manifest_value "$HISTORY_APPROVAL" inbox_id)" = "$INBOX_ID" ]] ||
  die "history approval inbox mismatch"
[[ "$(manifest_value "$HISTORY_APPROVAL" profile_mode)" = defer ]] ||
  die "history approval must defer profiles"

verify_checksum "$ACCEPTANCE_MANIFEST" "$ACCEPTANCE_CHECKSUM"
require_ordered_manifest "$ACCEPTANCE_MANIFEST" "${ACCEPTANCE_FIELDS[@]}"
[[ "$(sha256_file "$ACCEPTANCE_MANIFEST")" = "$ACCEPTANCE_SHA256" ]] ||
  die "terminal acceptance SHA mismatch"
[[ "$(manifest_value "$ACCEPTANCE_MANIFEST" candidate_commit)" = "$CANDIDATE_COMMIT" ]] ||
  die "terminal acceptance commit mismatch"
[[ "$(manifest_value "$ACCEPTANCE_MANIFEST" candidate_image)" = "$CANDIDATE_IMAGE" ]] ||
  die "terminal acceptance image mismatch"
[[ "$(manifest_value "$ACCEPTANCE_MANIFEST" production_database_name)" = \
  "$PRODUCTION_DATABASE" ]] || die "terminal acceptance database mismatch"
[[ "$(manifest_value "$ACCEPTANCE_MANIFEST" history_approval_sha256)" = \
  "$HISTORY_APPROVAL_SHA256" ]] || die "terminal acceptance approval mismatch"
[[ "$(manifest_value "$ACCEPTANCE_MANIFEST" inbox_id)" = "$INBOX_ID" ]] ||
  die "terminal acceptance inbox mismatch"
[[ "$(manifest_value "$ACCEPTANCE_MANIFEST" exit_status)" = 0 ]] ||
  die "terminal acceptance did not succeed"

UNRECOVERABLE_SIDECAR="$(dirname "$HISTORY_APPROVAL")/fbig-unrecoverable-envelope-v1.tsv"
UNRECOVERABLE_SIDECAR_CHECKSUM="${UNRECOVERABLE_SIDECAR}.sha256"
UNRECOVERABLE_INSPECTOR="$(dirname "$(dirname "$HISTORY_APPROVAL")")/fbig-unrecoverable-envelope-inspector.rb"
readonly UNRECOVERABLE_SIDECAR UNRECOVERABLE_SIDECAR_CHECKSUM UNRECOVERABLE_INSPECTOR
verify_checksum "$UNRECOVERABLE_SIDECAR" "$UNRECOVERABLE_SIDECAR_CHECKSUM"
require_ordered_manifest "$UNRECOVERABLE_SIDECAR" "${UNRECOVERABLE_SIDECAR_FIELDS[@]}"
require_root_artifact "$UNRECOVERABLE_INSPECTOR"
[[ "$(sha256_file "$UNRECOVERABLE_SIDECAR")" = \
  "$(manifest_value "$ACCEPTANCE_MANIFEST" unrecoverable_sidecar_sha256)" ]] ||
  die "unrecoverable sidecar SHA mismatch"
[[ "$(manifest_value "$UNRECOVERABLE_SIDECAR" repository_commit)" = "$CANDIDATE_COMMIT" &&
  "$(manifest_value "$UNRECOVERABLE_SIDECAR" image_digest)" = "$CANDIDATE_IMAGE" &&
  "$(manifest_value "$UNRECOVERABLE_SIDECAR" inbox_id)" = "$INBOX_ID" &&
  "$(manifest_value "$UNRECOVERABLE_SIDECAR" before)" = \
    "$(manifest_value "$HISTORY_APPROVAL" before)" &&
  "$(manifest_value "$UNRECOVERABLE_SIDECAR" platform)" = instagram &&
  "$(manifest_value "$UNRECOVERABLE_SIDECAR" inspector_script_sha256)" = \
    "$(sha256_file "$UNRECOVERABLE_INSPECTOR")" ]] ||
  die "unrecoverable sidecar binding mismatch"
EXPECTED_STRUCTURAL_THREADS=0
if [[ "$PLATFORMS" = instagram ]]; then
  EXPECTED_STRUCTURAL_THREADS="$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
fi
[[ "$EXPECTED_STRUCTURAL_THREADS" =~ ^[0-9]+$ ]] ||
  die "invalid approved structural-omission count"
readonly EXPECTED_STRUCTURAL_THREADS

if [[ "$PRE_HISTORY_BACKUP_MANIFEST" = none ]]; then
  [[ "$PRE_HISTORY_BACKUP_CHECKSUM" = none && "$PRE_HISTORY_BACKUP_SHA256" = none ]] ||
    die "partial pre-history backup binding"
  [[ "$OPERATION" = dry ]] || die "apply attempts require the pre-history backup"
else
  [[ "$PRE_HISTORY_BACKUP_CHECKSUM" = "${PRE_HISTORY_BACKUP_MANIFEST}.sha256" ]] ||
    die "pre-history backup checksum path mismatch"
  verify_checksum "$PRE_HISTORY_BACKUP_MANIFEST" "$PRE_HISTORY_BACKUP_CHECKSUM"
  [[ "$(sha256_file "$PRE_HISTORY_BACKUP_MANIFEST")" = "$PRE_HISTORY_BACKUP_SHA256" ]] ||
    die "pre-history backup SHA mismatch"
fi

validate_history_terminal_summary() {
  local summary="$1"
  local expected_dry_run="$2"
  local expected_write_complete="$3"
  local unavailable_count
  local structural_count
  local classified_count
  local failed_count
  local listed_count
  local cursor_exhausted_count

  unavailable_count="$(
    manifest_value "$HISTORY_APPROVAL" \
      "${PLATFORMS}_unavailable_message_thread_count"
  )"
  structural_count="$EXPECTED_STRUCTURAL_THREADS"
  classified_count="$(
    stage_value "$summary" history_import_summary classified_omitted_threads
  )"
  failed_count="$(stage_value "$summary" history_import_summary failed_threads)"
  listed_count="$(stage_value "$summary" history_import_summary listed_threads)"
  cursor_exhausted_count="$(
    stage_value "$summary" history_import_summary message_cursor_exhausted_threads
  )"

  [[ "$(stage_value "$summary" history_import_summary platforms)" = "$PLATFORMS" &&
    "$(stage_value "$summary" history_import_summary dry_run)" = "$expected_dry_run" &&
    "$(stage_value "$summary" history_import_summary scan_complete)" = true &&
    "$(stage_value "$summary" history_import_summary write_complete)" = "$expected_write_complete" &&
    "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0 &&
    "$(stage_value "$summary" history_import_summary unavailable_message_thread_acceptance_mismatches)" = 0 &&
    "$(stage_value "$summary" history_import_summary exit_failures)" = 0 &&
    "$(stage_value "$summary" history_import_summary partially_paginated_threads)" = 0 &&
    "$(stage_value "$summary" history_import_summary uncategorized_threads)" = 0 &&
    "$(stage_value "$summary" history_import_summary ambiguous_participants)" = "$structural_count" &&
    "$(stage_value "$summary" history_import_summary structural_unrecoverable_threads)" = "$structural_count" &&
    "$(stage_value "$summary" history_import_summary unavailable_message_threads)" = "$unavailable_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_unavailable_message_threads")" = "$unavailable_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_unavailable_message_thread_count")" = "$unavailable_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_unavailable_message_thread_fingerprint")" = \
      "$(manifest_value "$HISTORY_APPROVAL" "${PLATFORMS}_unavailable_message_thread_fingerprint")" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_structural_unrecoverable_threads")" = "$structural_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_classified_omitted_threads")" = "$classified_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_failed_threads")" = "$failed_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_listed_threads")" = "$listed_count" &&
    "$(stage_value "$summary" history_import_summary "${PLATFORMS}_message_cursor_exhausted_threads")" = "$cursor_exhausted_count" ]] ||
    die "history terminal summary platform accounting mismatch"
  [[ "$classified_count" -eq "$((structural_count + unavailable_count))" &&
    "$failed_count" -eq 0 &&
    "$listed_count" -eq "$((cursor_exhausted_count + classified_count + failed_count))" ]] ||
    die "history terminal summary violates thread conservation"
}

validate_authorizing_dry_result() {
  local result="$1"
  local checksum="$2"
  local summary

  [[ "$checksum" = "${result}.sha256" ]] ||
    die "dry-result checksum path mismatch"
  verify_checksum "$result" "$checksum"
  require_ordered_manifest "$result" "${RESULT_FIELDS[@]}"
  [[ "$(manifest_value "$result" operation)" = dry ]] ||
    die "authorizing result is not a dry attempt"
  [[ "$(manifest_value "$result" platforms)" = "$PLATFORMS" ]] ||
    die "authorizing dry-result platform mismatch"
  [[ "$(manifest_value "$result" require_zero_writes)" = true &&
    "$(manifest_value "$result" zero_write_observed)" = true ]] ||
    die "authorizing dry result is not zero-write"
  [[ "$(manifest_value "$result" candidate_commit)" = "$CANDIDATE_COMMIT" &&
    "$(manifest_value "$result" candidate_image)" = "$CANDIDATE_IMAGE" ]] ||
    die "authorizing dry-result candidate mismatch"
  [[ "$(manifest_value "$result" production_database)" = "$PRODUCTION_DATABASE" &&
    "$(manifest_value "$result" inbox_id)" = "$INBOX_ID" ]] ||
    die "authorizing dry-result production scope mismatch"
  [[ "$(manifest_value "$result" history_approval_sha256)" = "$HISTORY_APPROVAL_SHA256" &&
    "$(manifest_value "$result" acceptance_sha256)" = "$ACCEPTANCE_SHA256" ]] ||
    die "authorizing dry-result approval mismatch"
  [[ "$(manifest_value "$result" pre_history_backup_sha256)" = none &&
    "$(manifest_value "$result" dry_pair_sha256)" = none ]] ||
    die "authorizing dry result has an invalid authorization state"
  [[ "$(manifest_value "$result" exit_status)" = 0 &&
    "$(manifest_value "$result" termination)" = normal ]] ||
    die "authorizing dry result did not terminate successfully"
  [[ "$(manifest_value "$result" protected_changes)" = 0 &&
    "$(manifest_value "$result" deleted_rows)" = 0 &&
    "$(manifest_value "$result" unattributed_changes)" = 0 &&
    "$(manifest_value "$result" counter_mismatches)" = none ]] ||
    die "authorizing dry result failed state comparison"
  summary="$(dirname "$result")/history-summary.tsv"
  verify_checksum "$summary" "${summary}.sha256"
  [[ "$(manifest_value "$result" run_summary_sha256)" = "$(sha256_file "$summary")" ]] ||
    die "authorizing dry-result summary mismatch"
  validate_history_terminal_summary "$summary" true not_applicable
}

dry_pair_sha=none
if [[ "$OPERATION" = apply ]]; then
  validate_authorizing_dry_result "$DRY_RESULT_1" "$DRY_RESULT_1_CHECKSUM"
  validate_authorizing_dry_result "$DRY_RESULT_2" "$DRY_RESULT_2_CHECKSUM"
  cmp -s \
    "$(dirname "$DRY_RESULT_1")/history-summary.tsv" \
    "$(dirname "$DRY_RESULT_2")/history-summary.tsv" ||
    die "authorizing dry summaries differ"
  dry_pair_sha="$(
    printf '%s\n%s\n%s\n' \
      "$PLATFORMS" "$(sha256_file "$DRY_RESULT_1")" "$(sha256_file "$DRY_RESULT_2")" |
      sha256sum --binary | awk '{ print $1 }'
  )"
fi
readonly dry_pair_sha

predecessor_sha=none
if [[ "$PREDECESSOR_RESULT" = none ]]; then
  [[ "$PREDECESSOR_CHECKSUM" = none ]] || die "orphan predecessor checksum"
  [[ "$OPERATION" = dry ]] || die "apply attempts require a predecessor result"
else
  [[ "$PREDECESSOR_CHECKSUM" = "${PREDECESSOR_RESULT}.sha256" ]] ||
    die "predecessor checksum path mismatch"
  verify_checksum "$PREDECESSOR_RESULT" "$PREDECESSOR_CHECKSUM"
  require_ordered_manifest "$PREDECESSOR_RESULT" "${RESULT_FIELDS[@]}"
  [[ "$(manifest_value "$PREDECESSOR_RESULT" candidate_commit)" = "$CANDIDATE_COMMIT" ]] ||
    die "history predecessor candidate mismatch"
  [[ "$(manifest_value "$PREDECESSOR_RESULT" history_approval_sha256)" = \
    "$HISTORY_APPROVAL_SHA256" ]] || die "history predecessor approval mismatch"
  predecessor_sha="$(sha256_file "$PREDECESSOR_RESULT")"
fi
readonly predecessor_sha

readonly RESULT_DIRECTORY="$AUDIT_ROOT/$LABEL"
readonly IN_PROGRESS_DIRECTORY="$AUDIT_ROOT/.${LABEL}.in-progress"
readonly RESULT_MANIFEST_NAME='fbig-history-attempt-result-v1.tsv'
readonly RESULT_MANIFEST="$RESULT_DIRECTORY/$RESULT_MANIFEST_NAME"
readonly ATTEMPT_IDENTITY="$IN_PROGRESS_DIRECTORY/fbig-history-attempt-identity-v1.tsv"
readonly OVERRIDE_FILE="$IN_PROGRESS_DIRECTORY/candidate-compose.yml"
readonly ATTACHMENT_RECONCILE_START="$IN_PROGRESS_DIRECTORY/attachment-reconcile-start.log"
readonly ATTACHMENT_RECONCILE_FINAL="$IN_PROGRESS_DIRECTORY/attachment-reconcile-final.log"
readonly PRESTATE="$IN_PROGRESS_DIRECTORY/fbig-history-production-prestate-v1.tsv"
readonly POSTSTATE="$IN_PROGRESS_DIRECTORY/fbig-history-production-poststate-v1.tsv"
readonly UNRECOVERABLE_BEFORE="$IN_PROGRESS_DIRECTORY/unrecoverable-before.tsv"
readonly UNRECOVERABLE_AFTER="$IN_PROGRESS_DIRECTORY/unrecoverable-after.tsv"
readonly RELEASE_SCHEMA="$IN_PROGRESS_DIRECTORY/release-schema.log"
readonly FINALIZER_RELEASE_SCHEMA="$IN_PROGRESS_DIRECTORY/finalizer-release-schema.log"
readonly RUN_LOG="$IN_PROGRESS_DIRECTORY/history-run.log"
readonly RUN_SUMMARY="$IN_PROGRESS_DIRECTORY/history-summary.tsv"
readonly EXIT_STATUS_ARTIFACT="$IN_PROGRESS_DIRECTORY/history-exit-status.tsv"
readonly COMPARISON_LOG="$IN_PROGRESS_DIRECTORY/history-comparison.log"
readonly DELTA="$IN_PROGRESS_DIRECTORY/history-delta.tsv"
readonly CONTAINER_NAME="umi-fbig-history-$LABEL"

compose=(
  docker compose
  --project-name "$COMPOSE_PROJECT"
  --file "$COMPOSE_FILE"
  --file "$OVERRIDE_FILE"
)

ensure_compose_override() {
  local expected_override
  local temporary="$IN_PROGRESS_DIRECTORY/.candidate-compose.$$.tmp"

  if [[ -e "${OVERRIDE_FILE}.sha256" && ! -e "$OVERRIDE_FILE" ]]; then
    die "candidate Compose override checksum exists without its artifact"
  fi
  if [[ -e "$OVERRIDE_FILE" ]]; then
    verify_checksum "$OVERRIDE_FILE" "${OVERRIDE_FILE}.sha256"
  else
    [[ ! -e "$RELEASE_SCHEMA" && ! -e "$ATTACHMENT_RECONCILE_START" &&
      ! -e "$PRESTATE" && ! -e "$RUN_LOG" ]] ||
      die "history evidence exists without a candidate Compose override"
    printf 'services:\n  %s:\n    image: %s\n' "$RAILS_SERVICE" "$CANDIDATE_IMAGE" >"$temporary"
    publish_artifact "$temporary" "$OVERRIDE_FILE"
  fi
  expected_override="$IN_PROGRESS_DIRECTORY/.candidate-compose-expected.$$.tmp"
  printf 'services:\n  %s:\n    image: %s\n' "$RAILS_SERVICE" "$CANDIDATE_IMAGE" >"$expected_override"
  cmp -s "$expected_override" "$OVERRIDE_FILE" || {
    rm -f "$expected_override"
    die "candidate Compose override content mismatch"
  }
  rm -f "$expected_override"
  (
    cd "$STACK_DIR"
    "${compose[@]}" config --format json
  ) | python3 -c '
import json
import sys

service = sys.argv[1]
expected = sys.argv[2]
configuration = json.load(sys.stdin)
if configuration["services"][service]["image"] != expected:
    raise SystemExit("Rails one-off image is not the candidate digest")
' "$RAILS_SERVICE" "$CANDIDATE_IMAGE"
}

container_identity() {
  local service="$1"
  local container
  local image_id
  local commit

  container="$(
    cd "$STACK_DIR"
    "${compose[@]}" ps -q "$service"
  )"
  [[ -n "$container" && "$(wc -w <<<"$container")" -eq 1 ]] ||
    die "expected one running $service container"
  image_id="$(docker inspect --format '{{.Image}}' "$container")"
  docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" |
    grep -Fxq "$CANDIDATE_IMAGE" || die "$service image digest mismatch"
  commit="$(
    cd "$STACK_DIR"
    "${compose[@]}" exec -T "$service" sh -c 'tr -d "\r\n" </app/.git_sha'
  )"
  [[ "$commit" = "$CANDIDATE_COMMIT" ]] || die "$service commit mismatch"
}

verify_release_and_schema() {
  local service

  for service in "$RAILS_SERVICE" "$SIDEKIQ_SERVICE"; do
    container_identity "$service"
  done
  (
    cd "$STACK_DIR"
    "${compose[@]}" run --rm --no-deps -T \
      -e UMI_FBIG_EXPECTED_COMMIT="$CANDIDATE_COMMIT" \
      -e UMI_FBIG_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
      "$RAILS_SERVICE" bundle exec rails runner - <<'RUBY'
commit = File.binread("/app/.git_sha").strip
abort("candidate commit mismatch") unless commit == ENV.fetch("UMI_FBIG_EXPECTED_COMMIT")
connection = ActiveRecord::Base.connection
abort("production database mismatch") unless
  connection.select_value("SELECT current_database()") ==
    ENV.fetch("UMI_FBIG_EXPECTED_DATABASE")
abort("Contact avatar migration is not applied") unless
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
duplicates = ActiveStorage::Attachment
  .where(record_type: "Contact", name: "avatar")
  .group(:record_id).having("COUNT(*) > 1").count
abort("duplicate Contact avatar rows remain") if duplicates.any?
puts "[UMI-FBIG] stage=production_release_schema_verified"
RUBY
  )
}

state_capture() {
  local basename="$1"
  local log="$2"
  local suffix="$3"

  (
    cd "$STACK_DIR"
    "${compose[@]}" run --rm --no-deps -T \
      --name "${CONTAINER_NAME}-${suffix}" \
      --volume "$IN_PROGRESS_DIRECTORY:/run/fbig/attempt" \
      -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
      -e UMI_FBIG_HISTORY_STATE_OUTPUT_DIR=/run/fbig/attempt \
      -e UMI_FBIG_HISTORY_STATE_BASENAME="$basename" \
      -e PLATFORMS="$PLATFORMS" \
      "$RAILS_SERVICE" bundle exec rake "umi:fbig:history_state[$INBOX_ID]"
  ) >"$log" 2>&1
  seal_in_place "$log"
}

attachment_reconcile() {
  local log="$1"
  local suffix="$2"
  local temporary="$IN_PROGRESS_DIRECTORY/.attachment-reconcile-${suffix}.$$.tmp"

  (
    cd "$STACK_DIR"
    "${compose[@]}" run --rm --no-deps -T \
      --name "${CONTAINER_NAME}-attachment-reconcile-${suffix}" \
      -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
      "$RAILS_SERVICE" bundle exec rake \
        "umi:fbig:history_attachment_reconcile[$INBOX_ID]"
  ) >"$temporary" 2>&1
  [[ "$(grep -c '^\[UMI-FBIG\] stage=history_attachment_reconciliation ' "$temporary")" -eq 1 ]] ||
    die "attachment reconciliation lacks a terminal summary"
  publish_artifact "$temporary" "$log"
}

inspect_unrecoverable_envelopes() {
  local output="$1"
  local suffix="$2"
  local temporary="$IN_PROGRESS_DIRECTORY/.unrecoverable-${suffix}.$$.tmp"

  [[ "$PLATFORMS" = instagram ]] ||
    die "unrecoverable-envelope inspection is Instagram-only"
  if [[ -e "$output" ]]; then
    verify_checksum "$output" "${output}.sha256"
  else
    (
      cd "$STACK_DIR"
      "${compose[@]}" run --rm --no-deps -T \
        --name "${CONTAINER_NAME}-unrecoverable-${suffix}" \
        -e UMI_FBIG_INSPECT_INBOX_ID="$INBOX_ID" \
        -e UMI_FBIG_INSPECT_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
        -e UMI_FBIG_INSPECT_BEFORE="$(manifest_value "$UNRECOVERABLE_SIDECAR" before)" \
        "$RAILS_SERVICE" bundle exec rails runner - <"$UNRECOVERABLE_INSPECTOR"
    ) | grep '^\[UMI-FBIG\] stage=unrecoverable_envelope_inspection ' >"$temporary"
    publish_artifact "$temporary" "$output"
  fi
  [[ "$(grep -c '^\[UMI-FBIG\] stage=unrecoverable_envelope_inspection ' "$output")" -eq 1 &&
    "$(stage_value "$output" unrecoverable_envelope_inspection count)" = \
      "$EXPECTED_STRUCTURAL_THREADS" &&
    "$(stage_value "$output" unrecoverable_envelope_inspection fingerprint)" = \
      "$(manifest_value "$UNRECOVERABLE_SIDECAR" fingerprint)" ]] ||
    die "production unrecoverable-envelope inspection differs from acceptance"
}

write_attempt_identity() {
  local temporary="$IN_PROGRESS_DIRECTORY/.attempt-identity.$$.tmp"
  local boot_id
  local process_start_ticks

  boot_id="$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)"
  process_start_ticks="$(awk '{ print $22 }' "/proc/$$/stat")"
  {
    printf 'schema_version\t1\n'
    printf 'label\t%s\n' "$LABEL"
    printf 'operation\t%s\n' "$OPERATION"
    printf 'platforms\t%s\n' "$PLATFORMS"
    printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
    printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
    printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
    printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
    printf 'inbox_id\t%s\n' "$INBOX_ID"
    printf 'history_approval_sha256\t%s\n' "$HISTORY_APPROVAL_SHA256"
    printf 'dry_pair_sha256\t%s\n' "$dry_pair_sha"
    printf 'predecessor_result_sha256\t%s\n' "$predecessor_sha"
    printf 'host_pid\t%s\n' "$$"
    printf 'host_boot_id\t%s\n' "$boot_id"
    printf 'host_process_start_ticks\t%s\n' "$process_start_ticks"
    printf 'import_container_name\t%s\n' "$CONTAINER_NAME"
    printf 'started_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  publish_artifact "$temporary" "$ATTEMPT_IDENTITY"
}

run_importer() {
  local arguments=(
    --rm --no-deps -T
    --name "$CONTAINER_NAME"
    --volume "$(dirname "$HISTORY_APPROVAL"):/run/fbig/history:ro"
    -e UMI_FBIG_HISTORY_APPROVAL_MODE=approved
    -e UMI_FBIG_APPROVAL_MANIFEST_PATH=/run/fbig/history/fbig-approval-v2.tsv
    -e UMI_FBIG_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-approval-v2.tsv.sha256
    -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$PRODUCTION_DATABASE"
    -e UMI_FBIG_RUNTIME_REPOSITORY_COMMIT="$CANDIDATE_COMMIT"
    -e UMI_FBIG_RUNTIME_IMAGE_DIGEST="$CANDIDATE_IMAGE"
    -e ACK_SINGLE_CONVERSATION_REOPEN="$ACK_SINGLE_CONVERSATION_REOPEN"
    -e UMI_FBIG_HISTORY_GRAPH_DELAY_MS="$GRAPH_DELAY_MS"
    -e UMI_FBIG_HISTORY_MAX_CONVERSATION_PAGES="$MAX_CONVERSATION_PAGES"
    -e UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES="$MAX_MESSAGE_PAGES"
    -e PLATFORMS="$PLATFORMS"
    -e DRY_RUN=false
  )
  if [[ "$OPERATION" = dry ]]; then
    arguments[-1]='DRY_RUN=true'
  else
    arguments+=(
      -e ACK_EXPAND_EXISTING=true
      -e UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES="$MAX_DOWNLOAD_BYTES"
    )
  fi

  set +e
  (
    cd "$STACK_DIR"
    "${compose[@]}" run "${arguments[@]}" \
      "$RAILS_SERVICE" bundle exec rake "umi:fbig:history_import[$INBOX_ID]"
  ) >"$RUN_LOG" 2>&1
  importer_exit_status=$?
  set -e
  readonly importer_exit_status
  {
    printf 'schema_version\t1\n'
    printf 'exit_status\t%s\n' "$importer_exit_status"
    printf 'finished_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$EXIT_STATUS_ARTIFACT"
  seal_in_place "$EXIT_STATUS_ARTIFACT"
}

process_is_still_live() {
  local pid
  local boot_id
  local start_ticks

  pid="$(manifest_value "$ATTEMPT_IDENTITY" host_pid)"
  boot_id="$(manifest_value "$ATTEMPT_IDENTITY" host_boot_id)"
  start_ticks="$(manifest_value "$ATTEMPT_IDENTITY" host_process_start_ticks)"
  [[ "$boot_id" = "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" ]] || return 1
  [[ -r "/proc/$pid/stat" ]] || return 1
  [[ "$(awk '{ print $22 }' "/proc/$pid/stat")" = "$start_ticks" ]]
}

delta_value() {
  local platform="$1"
  local key="$2"
  local selected

  selected="$(
    awk -v platform="$platform" '
      $0 ~ "^\\[UMI-FBIG\\] stage=history_state_delta platform=" platform " " {
        print
      }
    ' "$DELTA"
  )"
  if [[ -z "$selected" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "$selected" >"$IN_PROGRESS_DIRECTORY/.selected-delta.$$.tmp"
  stage_value "$IN_PROGRESS_DIRECTORY/.selected-delta.$$.tmp" history_state_delta "$key"
  rm -f "$IN_PROGRESS_DIRECTORY/.selected-delta.$$.tmp"
}

validate_history_result() {
  local manifest="$1"

  verify_checksum "$manifest" "${manifest}.sha256"
  require_ordered_manifest "$manifest" "${RESULT_FIELDS[@]}"
  [[ "$(manifest_value "$manifest" label)" = "$LABEL" ]] || die "history result label mismatch"
  [[ "$(manifest_value "$manifest" operation)" = "$OPERATION" ]] ||
    die "history result operation mismatch"
  [[ "$(manifest_value "$manifest" platforms)" = "$PLATFORMS" ]] ||
    die "history result platform mismatch"
  [[ "$(manifest_value "$manifest" require_zero_writes)" = "$REQUIRE_ZERO_WRITES" ]] ||
    die "history result zero-write binding mismatch"
  [[ "$(manifest_value "$manifest" program_sha256)" = "$(sha256_file "$PROGRAM_PATH")" ]] ||
    die "history result program mismatch"
  [[ "$(manifest_value "$manifest" binding_sha256)" = "$(sha256_file "$BINDING_MANIFEST")" ]] ||
    die "history result binding mismatch"
  [[ "$(manifest_value "$manifest" candidate_commit)" = "$CANDIDATE_COMMIT" ]] ||
    die "history result candidate mismatch"
  [[ "$(manifest_value "$manifest" history_approval_sha256)" = "$HISTORY_APPROVAL_SHA256" ]] ||
    die "history result approval mismatch"
  [[ "$(manifest_value "$manifest" acceptance_sha256)" = "$ACCEPTANCE_SHA256" ]] ||
    die "history result acceptance mismatch"
  [[ "$(manifest_value "$manifest" pre_history_backup_sha256)" = \
    "$PRE_HISTORY_BACKUP_SHA256" ]] || die "history result backup mismatch"
  [[ "$(manifest_value "$manifest" production_database)" = "$PRODUCTION_DATABASE" ]] ||
    die "history result database mismatch"
  [[ "$(manifest_value "$manifest" inbox_id)" = "$INBOX_ID" ]] ||
    die "history result inbox mismatch"
  [[ "$(manifest_value "$manifest" predecessor_result_sha256)" = "$predecessor_sha" ]] ||
    die "history result predecessor mismatch"
  [[ "$(manifest_value "$manifest" dry_pair_sha256)" = "$dry_pair_sha" ]] ||
    die "history result dry-pair authorization mismatch"
  [[ "$(manifest_value "$manifest" compose_override_sha256)" = "$(sha256_file "$(
    dirname "$manifest"
  )/candidate-compose.yml")" ]] || die "history result Compose override mismatch"
  [[ "$(manifest_value "$manifest" protected_changes)" = 0 ]] ||
    die "history result contains protected changes"
  [[ "$(manifest_value "$manifest" deleted_rows)" = 0 ]] ||
    die "history result contains deleted rows"
  [[ "$(manifest_value "$manifest" unattributed_changes)" = 0 ]] ||
    die "history result contains unattributed changes"
  [[ "$(manifest_value "$manifest" counter_mismatches)" = none ]] ||
    die "history result counters do not conserve"
  if [[ "$REQUIRE_ZERO_WRITES" = true ]]; then
    [[ "$(manifest_value "$manifest" zero_write_observed)" = true ]] ||
      die "history result is not a zero-write proof"
  fi
  local entry
  local field
  local filename
  local artifact
  local expected_sha
  local finalizer_proof
  for entry in \
    'attempt_identity:fbig-history-attempt-identity-v1.tsv' \
    'compose_override:candidate-compose.yml' \
    'attachment_reconcile_start:attachment-reconcile-start.log' \
    'prestate:fbig-history-production-prestate-v1.tsv' \
    'attachment_reconcile_final:attachment-reconcile-final.log' \
    'poststate:fbig-history-production-poststate-v1.tsv' \
    'finalizer_release_schema:finalizer-release-schema.log' \
    'run_log:history-run.log' \
    'comparison_log:history-comparison.log' \
    'delta:history-delta.tsv'; do
    field="${entry%%:*}"
    filename="${entry#*:}"
    artifact="$(dirname "$manifest")/$filename"
    verify_checksum "$artifact" "${artifact}.sha256"
    [[ "$(sha256_file "$artifact")" = "$(manifest_value "$manifest" "${field}_sha256")" ]] ||
      die "history result artifact mismatch: $field"
  done
  for entry in \
    'release_schema:release-schema.log' \
    'run_summary:history-summary.tsv' \
    'exit_status_artifact:history-exit-status.tsv' \
    'unrecoverable_before:unrecoverable-before.tsv' \
    'unrecoverable_after:unrecoverable-after.tsv'; do
    field="${entry%%:*}"
    filename="${entry#*:}"
    expected_sha="$(manifest_value "$manifest" "${field}_sha256")"
    artifact="$(dirname "$manifest")/$filename"
    if [[ "$expected_sha" = none ]]; then
      [[ ! -e "$artifact" && ! -e "${artifact}.sha256" ]] ||
        die "history result has an unbound optional artifact: $field"
    else
      verify_checksum "$artifact" "${artifact}.sha256"
      [[ "$(sha256_file "$artifact")" = "$expected_sha" ]] ||
        die "history result optional artifact mismatch: $field"
    fi
  done
  if [[ "$PLATFORMS" = instagram ]]; then
    [[ "$(manifest_value "$manifest" unrecoverable_before_sha256)" != none &&
      "$(manifest_value "$manifest" unrecoverable_after_sha256)" != none ]] ||
      die "Instagram history result lacks unrecoverable-envelope evidence"
  else
    [[ "$(manifest_value "$manifest" unrecoverable_before_sha256)" = none &&
      "$(manifest_value "$manifest" unrecoverable_after_sha256)" = none ]] ||
      die "Messenger history result contains Instagram-only envelope evidence"
  fi
  finalizer_proof="$(dirname "$manifest")/finalizer-release-schema.log"
  [[ "$(grep -c '^\[UMI-FBIG\] stage=production_release_schema_verified$' "$finalizer_proof")" -eq 1 ]] ||
    die "history result lacks terminal release/schema proof"
}

finalize_attempt() {
  local internal="$1"
  local container_running=false
  local termination
  local exit_status=unknown
  local summary_sha=none
  local temporary
  local comparison_summary
  local field
  local platform

  if [[ -e "$RESULT_DIRECTORY" ]]; then
    require_root_directory "$RESULT_DIRECTORY"
    validate_history_result "$RESULT_MANIFEST"
    printf '[UMI-FBIG] stage=history_attempt_validated label=%s\n' "$LABEL"
    return
  fi
  require_root_directory "$IN_PROGRESS_DIRECTORY"
  verify_checksum "$ATTEMPT_IDENTITY" "${ATTEMPT_IDENTITY}.sha256"
  ensure_compose_override
  if [[ "$internal" != true ]] && process_is_still_live; then
    die "history attempt process is still live"
  fi
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    container_running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")"
    [[ "$container_running" = false ]] || die "history importer container is still running"
    exit_status="$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")"
  fi

  if [[ ! -e "${ATTACHMENT_RECONCILE_START}.sha256" ]]; then
    [[ ! -e "$RUN_LOG" && ! -e "$EXIT_STATUS_ARTIFACT" && "$container_running" = false ]] ||
      die "importer evidence exists without sealed attachment reconciliation"
    [[ ! -e "${PRESTATE}.sha256" ]] ||
      die "sealed prestate exists without attachment reconciliation"
    attachment_reconcile "$ATTACHMENT_RECONCILE_START" start-resume
  fi
  verify_checksum "$ATTACHMENT_RECONCILE_START" "${ATTACHMENT_RECONCILE_START}.sha256"

  if [[ ! -e "${PRESTATE}.sha256" ]]; then
    state_capture \
      fbig-history-production-prestate-v1.tsv \
      "$IN_PROGRESS_DIRECTORY/prestate-capture-resume.log" pre-resume
  fi
  verify_checksum "$PRESTATE" "${PRESTATE}.sha256"

  if [[ "$PLATFORMS" = instagram ]]; then
    if [[ ! -e "${UNRECOVERABLE_BEFORE}.sha256" ]]; then
      [[ ! -e "$RUN_LOG" && ! -e "$EXIT_STATUS_ARTIFACT" && "$container_running" = false ]] ||
        die "importer evidence exists without a sealed pre-import envelope inspection"
    fi
    inspect_unrecoverable_envelopes "$UNRECOVERABLE_BEFORE" before
  fi

  if [[ ! -e "${FINALIZER_RELEASE_SCHEMA}.sha256" ]]; then
    if [[ -e "$FINALIZER_RELEASE_SCHEMA" ]]; then
      seal_in_place "$FINALIZER_RELEASE_SCHEMA"
    else
      finalizer_release_output="$(verify_release_and_schema 2>&1)"
      finalizer_release_temporary="$IN_PROGRESS_DIRECTORY/.finalizer-release.$$.tmp"
      printf '%s\n' "$finalizer_release_output" >"$finalizer_release_temporary"
      publish_artifact "$finalizer_release_temporary" "$FINALIZER_RELEASE_SCHEMA"
    fi
  fi
  verify_checksum "$FINALIZER_RELEASE_SCHEMA" "${FINALIZER_RELEASE_SCHEMA}.sha256"

  if [[ -e "$EXIT_STATUS_ARTIFACT" ]]; then
    verify_checksum "$EXIT_STATUS_ARTIFACT" "${EXIT_STATUS_ARTIFACT}.sha256"
    exit_status="$(manifest_value "$EXIT_STATUS_ARTIFACT" exit_status)"
    termination=normal
  else
    termination=adopted_interrupted_attempt
  fi
  [[ "$exit_status" = unknown || "$exit_status" =~ ^(?:0|[1-9][0-9]{0,2})$ ]] ||
    die "invalid importer exit status"

  if [[ ! -e "$RUN_LOG" ]]; then
    : >"$RUN_LOG"
  fi
  seal_in_place "$RUN_LOG"
  summary_count="$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$RUN_LOG" || true)"
  [[ "$summary_count" -le 1 ]] || die "ambiguous history terminal summary"
  if [[ "$summary_count" -eq 1 ]]; then
    if [[ ! -e "$RUN_SUMMARY" ]]; then
      grep '^\[UMI-FBIG\] stage=history_import_summary ' "$RUN_LOG" >"$RUN_SUMMARY"
    fi
    seal_in_place "$RUN_SUMMARY"
    summary_sha="$(sha256_file "$RUN_SUMMARY")"
  elif [[ -e "$RUN_SUMMARY" ]]; then
    die "orphan history terminal summary"
  fi
  [[ "$exit_status" != 0 || "$summary_sha" != none ]] ||
    die "successful importer exit is missing its terminal summary"
  if [[ "$exit_status" = 0 ]]; then
    if [[ "$OPERATION" = dry ]]; then
      validate_history_terminal_summary "$RUN_SUMMARY" true not_applicable
    else
      validate_history_terminal_summary "$RUN_SUMMARY" false true
    fi
  fi

  if [[ "$PLATFORMS" = instagram ]]; then
    inspect_unrecoverable_envelopes "$UNRECOVERABLE_AFTER" after
  fi

  if [[ ! -e "${ATTACHMENT_RECONCILE_FINAL}.sha256" ]]; then
    [[ ! -e "${POSTSTATE}.sha256" ]] ||
      die "sealed poststate exists without final attachment reconciliation"
    attachment_reconcile "$ATTACHMENT_RECONCILE_FINAL" final
  fi
  verify_checksum "$ATTACHMENT_RECONCILE_FINAL" "${ATTACHMENT_RECONCILE_FINAL}.sha256"

  if [[ ! -e "$POSTSTATE" ]]; then
    state_capture \
      fbig-history-production-poststate-v1.tsv \
      "$IN_PROGRESS_DIRECTORY/poststate-capture.log" post
  fi
  verify_checksum "$POSTSTATE" "${POSTSTATE}.sha256"

  if [[ ! -e "$COMPARISON_LOG" ]]; then
    summary_container_path=none
    if [[ "$summary_sha" != none ]]; then
      summary_container_path=/run/fbig/attempt/history-summary.tsv
    fi
    comparison_temporary="$IN_PROGRESS_DIRECTORY/.comparison-log.$$.tmp"
    (
      cd "$STACK_DIR"
      "${compose[@]}" run --rm --no-deps -T \
        --name "${CONTAINER_NAME}-compare" \
        --volume "$IN_PROGRESS_DIRECTORY:/run/fbig/attempt:ro" \
        -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
        -e UMI_FBIG_HISTORY_PRESTATE_PATH=/run/fbig/attempt/fbig-history-production-prestate-v1.tsv \
        -e UMI_FBIG_HISTORY_PRESTATE_CHECKSUM_PATH=/run/fbig/attempt/fbig-history-production-prestate-v1.tsv.sha256 \
        -e UMI_FBIG_HISTORY_POSTSTATE_PATH=/run/fbig/attempt/fbig-history-production-poststate-v1.tsv \
        -e UMI_FBIG_HISTORY_POSTSTATE_CHECKSUM_PATH=/run/fbig/attempt/fbig-history-production-poststate-v1.tsv.sha256 \
        -e UMI_FBIG_HISTORY_SUMMARY_PATH="$summary_container_path" \
        -e UMI_FBIG_HISTORY_REQUIRE_ZERO_WRITES="$REQUIRE_ZERO_WRITES" \
        "$RAILS_SERVICE" bundle exec rake "umi:fbig:history_state_compare[$INBOX_ID]"
    ) >"$comparison_temporary" 2>&1
    publish_artifact "$comparison_temporary" "$COMPARISON_LOG"
  fi
  if [[ ! -e "${COMPARISON_LOG}.sha256" ]]; then
    seal_in_place "$COMPARISON_LOG"
  fi
  verify_checksum "$COMPARISON_LOG" "${COMPARISON_LOG}.sha256"
  if [[ ! -e "$DELTA" ]]; then
    delta_temporary="$IN_PROGRESS_DIRECTORY/.delta.$$.tmp"
    grep '^\[UMI-FBIG\] stage=history_state_delta ' "$COMPARISON_LOG" >"$delta_temporary"
    publish_artifact "$delta_temporary" "$DELTA"
  fi
  [[ "$(wc -l <"$DELTA")" -eq "$(awk -F, '{ print NF }' <<<"$PLATFORMS")" ]] ||
    die "history delta platform count mismatch"
  if [[ ! -e "${DELTA}.sha256" ]]; then
    seal_in_place "$DELTA"
  fi
  verify_checksum "$DELTA" "${DELTA}.sha256"
  comparison_summary="$(
    grep '^\[UMI-FBIG\] stage=history_state_comparison ' "$COMPARISON_LOG"
  )"
  [[ "$(grep -c '^\[UMI-FBIG\] stage=history_state_comparison ' "$COMPARISON_LOG")" -eq 1 ]] ||
    die "ambiguous history comparison summary"
  [[ "$(printf '%s\n' "$comparison_summary" |
    awk '{ for (field = 1; field <= NF; field += 1) if ($field == "success=true") found = 1 } END { print found + 0 }')" = 1 ]] ||
    die "history state comparison did not succeed"

  temporary="$IN_PROGRESS_DIRECTORY/.result.$$.tmp"
  {
    printf 'schema_version\t1\n'
    printf 'label\t%s\n' "$LABEL"
    printf 'operation\t%s\n' "$OPERATION"
    printf 'platforms\t%s\n' "$PLATFORMS"
    printf 'require_zero_writes\t%s\n' "$REQUIRE_ZERO_WRITES"
    printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
    printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
    printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
    printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
    printf 'production_database\t%s\n' "$PRODUCTION_DATABASE"
    printf 'inbox_id\t%s\n' "$INBOX_ID"
    printf 'history_approval_sha256\t%s\n' "$HISTORY_APPROVAL_SHA256"
    printf 'acceptance_sha256\t%s\n' "$ACCEPTANCE_SHA256"
    printf 'pre_history_backup_sha256\t%s\n' "$PRE_HISTORY_BACKUP_SHA256"
    printf 'dry_pair_sha256\t%s\n' "$dry_pair_sha"
    printf 'attempt_identity_sha256\t%s\n' "$(sha256_file "$ATTEMPT_IDENTITY")"
    printf 'compose_override_sha256\t%s\n' "$(sha256_file "$OVERRIDE_FILE")"
    printf 'attachment_reconcile_start_sha256\t%s\n' \
      "$(sha256_file "$ATTACHMENT_RECONCILE_START")"
    printf 'prestate_sha256\t%s\n' "$(sha256_file "$PRESTATE")"
    if [[ "$PLATFORMS" = instagram ]]; then
      printf 'unrecoverable_before_sha256\t%s\n' "$(sha256_file "$UNRECOVERABLE_BEFORE")"
      printf 'unrecoverable_after_sha256\t%s\n' "$(sha256_file "$UNRECOVERABLE_AFTER")"
    else
      printf 'unrecoverable_before_sha256\tnone\n'
      printf 'unrecoverable_after_sha256\tnone\n'
    fi
    printf 'attachment_reconcile_final_sha256\t%s\n' \
      "$(sha256_file "$ATTACHMENT_RECONCILE_FINAL")"
    printf 'poststate_sha256\t%s\n' "$(sha256_file "$POSTSTATE")"
    if [[ -e "$RELEASE_SCHEMA" ]]; then
      seal_in_place "$RELEASE_SCHEMA"
      printf 'release_schema_sha256\t%s\n' "$(sha256_file "$RELEASE_SCHEMA")"
    else
      printf 'release_schema_sha256\tnone\n'
    fi
    printf 'finalizer_release_schema_sha256\t%s\n' \
      "$(sha256_file "$FINALIZER_RELEASE_SCHEMA")"
    printf 'run_log_sha256\t%s\n' "$(sha256_file "$RUN_LOG")"
    printf 'run_summary_sha256\t%s\n' "$summary_sha"
    if [[ -e "$EXIT_STATUS_ARTIFACT" ]]; then
      printf 'exit_status_artifact_sha256\t%s\n' "$(sha256_file "$EXIT_STATUS_ARTIFACT")"
    else
      printf 'exit_status_artifact_sha256\tnone\n'
    fi
    printf 'comparison_log_sha256\t%s\n' "$(sha256_file "$COMPARISON_LOG")"
    printf 'delta_sha256\t%s\n' "$(sha256_file "$DELTA")"
    printf 'exit_status\t%s\n' "$exit_status"
    printf 'termination\t%s\n' "$termination"
    printf 'predecessor_result_sha256\t%s\n' "$predecessor_sha"
    for platform in messenger instagram; do
      for field in \
        contacts_created contacts_reused contact_inboxes_created \
        contact_inboxes_reused archives_created messages_created \
        incoming_created outgoing_created attachments_created \
        active_storage_attachments_created active_storage_blobs_created \
        archive_activity_changed archive_configuration_changed \
        contact_activity_changed contact_profile_changed; do
        printf '%s_%s\t%s\n' "$platform" "$field" "$(delta_value "$platform" "$field")"
      done
    done
    printf 'protected_changes\t%s\n' \
      "$(printf '%s\n' "$comparison_summary" >"$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp";
        stage_value "$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp" history_state_comparison protected_changes)"
    printf 'deleted_rows\t%s\n' \
      "$(stage_value "$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp" history_state_comparison deleted_rows)"
    printf 'unattributed_changes\t%s\n' \
      "$(stage_value "$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp" history_state_comparison unattributed_changes)"
    printf 'counter_mismatches\t%s\n' \
      "$(stage_value "$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp" history_state_comparison counter_mismatches)"
    printf 'zero_write_observed\t%s\n' \
      "$(stage_value "$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp" history_state_comparison zero_write_observed)"
    printf 'started_at\t%s\n' "$(manifest_value "$ATTEMPT_IDENTITY" started_at)"
    printf 'finished_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'sealed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  rm -f "$IN_PROGRESS_DIRECTORY/.comparison.$$.tmp"
  publish_artifact "$temporary" "$IN_PROGRESS_DIRECTORY/$RESULT_MANIFEST_NAME"
  fsync_path "$IN_PROGRESS_DIRECTORY"
  publish_directory_no_replace "$IN_PROGRESS_DIRECTORY" "$RESULT_DIRECTORY"
  fsync_path "$AUDIT_ROOT"
  validate_history_result "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=history_attempt_result label=%s termination=%s zero_write_observed=%s\n' \
    "$LABEL" "$termination" "$(manifest_value "$RESULT_MANIFEST" zero_write_observed)"
}

if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_history_result "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=history_attempt_validated label=%s\n' "$LABEL"
  exit 0
fi

acquire_descriptor_verified_lock "$PRODUCTION_LOCK"
if [[ "$ACTION" = start ]]; then
  [[ ! -e "$IN_PROGRESS_DIRECTORY" ]] ||
    die "history attempt already exists; run the finalizer instead"
  mkdir "$IN_PROGRESS_DIRECTORY"
  chmod 0700 "$IN_PROGRESS_DIRECTORY"
  write_attempt_identity
  ensure_compose_override
  verify_release_and_schema >"$RELEASE_SCHEMA" 2>&1
  seal_in_place "$RELEASE_SCHEMA"
  attachment_reconcile "$ATTACHMENT_RECONCILE_START" start
  state_capture \
    fbig-history-production-prestate-v1.tsv \
    "$IN_PROGRESS_DIRECTORY/prestate-capture.log" pre
  if [[ "$PLATFORMS" = instagram ]]; then
    inspect_unrecoverable_envelopes "$UNRECOVERABLE_BEFORE" before
  fi
  run_importer
  finalize_attempt true
else
  finalize_attempt false
fi
