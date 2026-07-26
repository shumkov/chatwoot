readonly ACTION="${1:?action is required (launch|finalize)}"
readonly ACCEPTANCE_BINDING="${2:?acceptance binding is required}"
readonly ACCEPTANCE_BINDING_CHECKSUM="${ACCEPTANCE_BINDING}.sha256"
readonly ACCEPTANCE_BINDING_FIELDS=(
  schema_version acceptance_id inbox_id production_database clone_database
  candidate_commit candidate_image approved_by stack_dir audit_dir clone_storage
  production_storage backup_dir history_cutoff
  expected_instagram_unrecoverable_threads profile_graph_delay_ms
  profile_max_conversation_pages profile_max_rate_limit_wait_seconds
  profile_max_download_bytes history_max_download_bytes storage_helper
  storage_helper_sha256 ops_dir acceptance_unit unit_fragment_path
  acceptance_finalizer_lock
)
readonly TERMINAL_FIELDS=(
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
readonly LAUNCH_FIELDS=(
  schema_version acceptance_id invocation_id started_at
  acceptance_binding_sha256 acceptance_program_sha256
  acceptance_control_sha256 unit_fragment_sha256
  prelaunch_descriptor_sha256 start_intent_sha256
)
readonly START_INTENT_FIELDS=(
  schema_version acceptance_id created_at previous_invocation_id
  acceptance_binding_sha256 acceptance_program_sha256
  acceptance_control_sha256 unit_fragment_sha256
  prelaunch_descriptor_sha256
)

[[ "$ACTION" =~ ^(launch|finalize)$ ]] || die 'action must be launch|finalize'
test "$(id -u)" -eq 0
verify_checksum "$ACCEPTANCE_BINDING" "$ACCEPTANCE_BINDING_CHECKSUM"
require_ordered_manifest "$ACCEPTANCE_BINDING" "${ACCEPTANCE_BINDING_FIELDS[@]}"
test "$(manifest_value "$ACCEPTANCE_BINDING" schema_version)" = 1

ACCEPTANCE_ID="$(manifest_value "$ACCEPTANCE_BINDING" acceptance_id)"
INBOX_ID="$(manifest_value "$ACCEPTANCE_BINDING" inbox_id)"
PRODUCTION_DATABASE="$(manifest_value "$ACCEPTANCE_BINDING" production_database)"
CLONE_DATABASE="$(manifest_value "$ACCEPTANCE_BINDING" clone_database)"
APP_COMMIT="$(manifest_value "$ACCEPTANCE_BINDING" candidate_commit)"
APP_DIGEST="$(manifest_value "$ACCEPTANCE_BINDING" candidate_image)"
STACK_DIR="$(manifest_value "$ACCEPTANCE_BINDING" stack_dir)"
AUDIT_DIR="$(manifest_value "$ACCEPTANCE_BINDING" audit_dir)"
CLONE_STORAGE="$(manifest_value "$ACCEPTANCE_BINDING" clone_storage)"
PRODUCTION_STORAGE="$(manifest_value "$ACCEPTANCE_BINDING" production_storage)"
BACKUP_DIR="$(manifest_value "$ACCEPTANCE_BINDING" backup_dir)"
OPS_DIR="$(manifest_value "$ACCEPTANCE_BINDING" ops_dir)"
ACCEPTANCE_UNIT="$(manifest_value "$ACCEPTANCE_BINDING" acceptance_unit)"
UNIT_FRAGMENT_PATH="$(manifest_value "$ACCEPTANCE_BINDING" unit_fragment_path)"
FINALIZER_LOCK="$(manifest_value "$ACCEPTANCE_BINDING" acceptance_finalizer_lock)"
STORAGE_HELPER="$(manifest_value "$ACCEPTANCE_BINDING" storage_helper)"
STORAGE_HELPER_SHA256="$(
  manifest_value "$ACCEPTANCE_BINDING" storage_helper_sha256
)"
CLONE_ROOT="$(dirname "$CLONE_STORAGE")"
readonly ACCEPTANCE_ID INBOX_ID PRODUCTION_DATABASE CLONE_DATABASE APP_COMMIT
readonly APP_DIGEST STACK_DIR AUDIT_DIR CLONE_STORAGE PRODUCTION_STORAGE BACKUP_DIR
readonly CLONE_ROOT OPS_DIR ACCEPTANCE_UNIT UNIT_FRAGMENT_PATH
readonly FINALIZER_LOCK
readonly STORAGE_HELPER STORAGE_HELPER_SHA256

readonly CONTROL_PROGRAM="${BASH_SOURCE[0]}"
readonly CONTROL_CHECKSUM="${CONTROL_PROGRAM}.sha256"
readonly ACCEPTANCE_PROGRAM="$OPS_DIR/fbig-acceptance.sh"
readonly ACCEPTANCE_PROGRAM_CHECKSUM="${ACCEPTANCE_PROGRAM}.sha256"
readonly UNIT_FRAGMENT_ARCHIVE="$OPS_DIR/$ACCEPTANCE_UNIT"
readonly UNIT_FRAGMENT_ARCHIVE_CHECKSUM="${UNIT_FRAGMENT_ARCHIVE}.sha256"
readonly PRELAUNCH_DESCRIPTOR="$OPS_DIR/fbig-acceptance-unit-prelaunch-v1.tsv"
readonly POSTLAUNCH_DESCRIPTOR="$OPS_DIR/fbig-acceptance-unit-postlaunch-v1.tsv"
readonly START_INTENT="$OPS_DIR/fbig-acceptance-start-intent-v1.tsv"
readonly START_INTENT_CHECKSUM="${START_INTENT}.sha256"
readonly LAUNCH_MANIFEST="$OPS_DIR/fbig-acceptance-launch-v1.tsv"
readonly LAUNCH_CHECKSUM="${LAUNCH_MANIFEST}.sha256"
readonly TERMINAL_MANIFEST="$AUDIT_DIR/fbig-acceptance-complete-v1.tsv"
readonly TERMINAL_CHECKSUM="${TERMINAL_MANIFEST}.sha256"
readonly ARTIFACT_INDEX="$AUDIT_DIR/fbig-acceptance-artifact-index-v1.tsv"
readonly ARTIFACT_INDEX_CHECKSUM="${ARTIFACT_INDEX}.sha256"
readonly SYSTEM_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

require_safe_token acceptance_id "$ACCEPTANCE_ID"
require_safe_token acceptance_unit "$ACCEPTANCE_UNIT"
[[ "$ACCEPTANCE_UNIT" =~ ^umi-fbig-[a-z0-9.-]+\.service$ ]]
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$CLONE_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
[[ "$PRODUCTION_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
test "$CLONE_DATABASE" != "$PRODUCTION_DATABASE"
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
require_root_artifact "$STORAGE_HELPER"
test "$(sha256_file "$STORAGE_HELPER")" = "$STORAGE_HELPER_SHA256"
test "$ACCEPTANCE_ID" = "$(basename "$AUDIT_DIR")"
test "$ACCEPTANCE_BINDING" = "$OPS_DIR/fbig-acceptance-binding-v1.tsv"
test "$CONTROL_PROGRAM" = "$OPS_DIR/fbig-acceptance-control.sh"
test "$UNIT_FRAGMENT_PATH" = "/etc/systemd/system/$ACCEPTANCE_UNIT"
test "$FINALIZER_LOCK" = "$OPS_DIR/fbig-acceptance-finalizer.lock"
test "$(basename "$CLONE_ROOT")" = "$ACCEPTANCE_ID"
test "$(basename "$CLONE_STORAGE")" = storage

require_root_directory "$OPS_DIR"
verify_checksum "$CONTROL_PROGRAM" "$CONTROL_CHECKSUM"
verify_checksum "$ACCEPTANCE_PROGRAM" "$ACCEPTANCE_PROGRAM_CHECKSUM"
require_trusted_directory "$STACK_DIR"
require_root_readonly_file "$STACK_DIR/docker-compose.yml"
require_trusted_directory "$BACKUP_DIR"
for backup_artifact in \
  fbig-coordinated-backup-v1.tsv fbig-coordinated-backup-v1.tsv.sha256 \
  database.dump storage.tar storage.manifest; do
  require_root_artifact "$BACKUP_DIR/$backup_artifact"
done
require_trusted_directory "$PRODUCTION_STORAGE"
if [[ -e "$AUDIT_DIR" || -L "$AUDIT_DIR" ]]; then
  require_root_directory "$AUDIT_DIR"
else
  require_new_root_directory_path "$AUDIT_DIR"
fi
if [[ -e "$CLONE_ROOT" || -L "$CLONE_ROOT" ]]; then
  require_root_directory "$CLONE_ROOT"
  if [[ -e "$CLONE_STORAGE" || -L "$CLONE_STORAGE" ]]; then
    require_root_directory "$CLONE_STORAGE"
  else
    require_new_root_directory_path "$CLONE_STORAGE"
  fi
else
  require_new_root_directory_path "$CLONE_ROOT"
fi
CONTROL_SHA256="$(sha256_file "$CONTROL_PROGRAM")"
ACCEPTANCE_PROGRAM_SHA256="$(sha256_file "$ACCEPTANCE_PROGRAM")"
ACCEPTANCE_BINDING_SHA256="$(sha256_file "$ACCEPTANCE_BINDING")"
readonly CONTROL_SHA256 ACCEPTANCE_PROGRAM_SHA256 ACCEPTANCE_BINDING_SHA256

unit_property() {
  local property="$1"
  systemctl show "$ACCEPTANCE_UNIT" --property="$property" --value
}

validate_unit_fragment() {
  local fragment="$1"

  require_root_artifact "$fragment"
  test "$(grep -c '^ExecStart=' "$fragment")" -eq 1
  test "$(grep -c '^Environment=' "$fragment")" -eq 1
  test "$(grep -c '^EnvironmentFile=' "$fragment")" -eq 0
  test "$(grep -c '^PassEnvironment=' "$fragment")" -eq 0
  grep -Fxq 'Type=exec' "$fragment"
  grep -Fxq 'User=root' "$fragment"
  grep -Fxq 'Group=root' "$fragment"
  grep -Fxq 'WorkingDirectory=/' "$fragment"
  grep -Fxq "Environment=PATH=$SYSTEM_PATH" "$fragment"
  grep -Fxq \
    "ExecStart=/bin/bash $ACCEPTANCE_PROGRAM $ACCEPTANCE_BINDING" \
    "$fragment"
}

publish_unit_fragment_archive() {
  local temporary

  if [[ -e "$UNIT_FRAGMENT_ARCHIVE_CHECKSUM" && ! -e "$UNIT_FRAGMENT_ARCHIVE" ]]; then
    die 'unit fragment checksum exists without its artifact'
  fi
  if [[ -e "$UNIT_FRAGMENT_ARCHIVE" ]]; then
    require_root_artifact "$UNIT_FRAGMENT_ARCHIVE"
    validate_unit_fragment "$UNIT_FRAGMENT_ARCHIVE"
    if [[ -e "$UNIT_FRAGMENT_ARCHIVE_CHECKSUM" ]]; then
      verify_checksum "$UNIT_FRAGMENT_ARCHIVE" "$UNIT_FRAGMENT_ARCHIVE_CHECKSUM"
    else
      seal_in_place "$UNIT_FRAGMENT_ARCHIVE"
    fi
    return
  fi

  temporary="${UNIT_FRAGMENT_ARCHIVE}.$$.tmp"
  (
    set -o noclobber
    {
      printf '[Unit]\n'
      printf 'Description=UMI FB/IG clone acceptance %s\n' "$ACCEPTANCE_ID"
      printf 'After=docker.service\n'
      printf 'Requires=docker.service\n\n'
      printf '[Service]\n'
      printf 'Type=exec\n'
      printf 'User=root\n'
      printf 'Group=root\n'
      printf 'WorkingDirectory=/\n'
      printf 'UMask=0077\n'
      printf 'Environment=PATH=%s\n' "$SYSTEM_PATH"
      printf 'ExecStart=/bin/bash %s %s\n' \
        "$ACCEPTANCE_PROGRAM" "$ACCEPTANCE_BINDING"
      printf 'KillMode=control-group\n'
      printf 'StandardOutput=journal\n'
      printf 'StandardError=journal\n'
    } >"$temporary"
  )
  publish_artifact "$temporary" "$UNIT_FRAGMENT_ARCHIVE"
  validate_unit_fragment "$UNIT_FRAGMENT_ARCHIVE"
}

install_unit_fragment() {
  local temporary

  if [[ -e "$UNIT_FRAGMENT_PATH" ]]; then
    require_root_artifact "$UNIT_FRAGMENT_PATH"
    test "$(sha256_file "$UNIT_FRAGMENT_PATH")" = \
      "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
    validate_unit_fragment "$UNIT_FRAGMENT_PATH"
    return
  fi

  temporary="${UNIT_FRAGMENT_PATH}.$$.tmp"
  cp --reflink=never --no-clobber "$UNIT_FRAGMENT_ARCHIVE" "$temporary"
  test -f "$temporary"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  test "$(sha256_file "$temporary")" = "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
  ln "$temporary" "$UNIT_FRAGMENT_PATH"
  rm -f "$temporary"
  fsync_path "$(dirname "$UNIT_FRAGMENT_PATH")"
  require_root_artifact "$UNIT_FRAGMENT_PATH"
}

capture_effective_descriptor() {
  local output="$1"
  local fragment_path
  local exec_start
  local environment
  local environment_files
  local pass_environment
  local working_directory
  local drop_in_paths
  local temporary

  test "$(unit_property LoadState)" = loaded
  fragment_path="$(unit_property FragmentPath)"
  exec_start="$(unit_property ExecStart)"
  environment="$(unit_property Environment)"
  environment_files="$(unit_property EnvironmentFiles)"
  pass_environment="$(unit_property PassEnvironment)"
  working_directory="$(unit_property WorkingDirectory)"
  drop_in_paths="$(unit_property DropInPaths)"

  test "$fragment_path" = "$UNIT_FRAGMENT_PATH"
  test "$(printf '%s\n' "$exec_start" | grep -o '{ path=' | wc -l)" -eq 1
  [[ "$exec_start" == *"path=/bin/bash ;"* ]]
  [[ "$exec_start" == *"argv[]=/bin/bash $ACCEPTANCE_PROGRAM $ACCEPTANCE_BINDING ;"* ]]
  [[ "$exec_start" == *"ignore_errors=no"* ]]
  test "$environment" = "PATH=$SYSTEM_PATH"
  test -z "$environment_files"
  test -z "$pass_environment"
  test "$working_directory" = /
  test -z "$drop_in_paths"
  test "$(unit_property User)" = root
  test "$(unit_property Group)" = root
  test "$(unit_property Type)" = exec

  temporary="${output}.$$.tmp"
  (
    set -o noclobber
    {
      printf 'schema_version\t1\n'
      printf 'fragment_path\t%s\n' "$fragment_path"
      printf 'fragment_sha256\t%s\n' "$(sha256_file "$UNIT_FRAGMENT_PATH")"
      printf 'exec_start\t/bin/bash %s %s\n' \
        "$ACCEPTANCE_PROGRAM" "$ACCEPTANCE_BINDING"
      printf 'environment\tPATH=%s\n' "$SYSTEM_PATH"
      printf 'environment_files\tnone\n'
      printf 'pass_environment\tnone\n'
      printf 'working_directory\t/\n'
      printf 'drop_in_paths\tnone\n'
      printf 'user\troot\n'
      printf 'group\troot\n'
      printf 'type\texec\n'
    } >"$temporary"
  )

  if [[ -e "${output}.sha256" && ! -e "$output" ]]; then
    rm -f "$temporary"
    die 'unit descriptor checksum exists without its artifact'
  fi
  if [[ -e "$output" ]]; then
    require_root_artifact "$output"
    cmp -s "$temporary" "$output" || {
      rm -f "$temporary"
      die 'effective unit descriptor changed'
    }
    rm -f "$temporary"
    if [[ -e "${output}.sha256" ]]; then
      verify_checksum "$output" "${output}.sha256"
    else
      seal_in_place "$output"
    fi
  else
    publish_artifact "$temporary" "$output"
  fi
}

validate_launch_manifest() {
  local manifest="$1"

  require_ordered_manifest "$manifest" "${LAUNCH_FIELDS[@]}"
  test "$(manifest_value "$manifest" schema_version)" = 1
  test "$(manifest_value "$manifest" acceptance_id)" = "$ACCEPTANCE_ID"
  [[ "$(manifest_value "$manifest" invocation_id)" =~ ^[0-9a-f]{32}$ ]]
  [[ "$(manifest_value "$manifest" started_at)" =~ \
    ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  test "$(manifest_value "$manifest" acceptance_binding_sha256)" = \
    "$ACCEPTANCE_BINDING_SHA256"
  test "$(manifest_value "$manifest" acceptance_program_sha256)" = \
    "$ACCEPTANCE_PROGRAM_SHA256"
  test "$(manifest_value "$manifest" acceptance_control_sha256)" = \
    "$CONTROL_SHA256"
  test "$(manifest_value "$manifest" unit_fragment_sha256)" = \
    "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
  test "$(manifest_value "$manifest" prelaunch_descriptor_sha256)" = \
    "$(sha256_file "$PRELAUNCH_DESCRIPTOR")"
  test "$(manifest_value "$manifest" start_intent_sha256)" = \
    "$(sha256_file "$START_INTENT")"
}

validate_start_intent() {
  local manifest="$1"

  verify_checksum "$manifest" "${manifest}.sha256"
  require_ordered_manifest "$manifest" "${START_INTENT_FIELDS[@]}"
  test "$(manifest_value "$manifest" schema_version)" = 1
  test "$(manifest_value "$manifest" acceptance_id)" = "$ACCEPTANCE_ID"
  [[ "$(manifest_value "$manifest" created_at)" =~ \
    ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ "$(manifest_value "$manifest" previous_invocation_id)" = none ||
    "$(manifest_value "$manifest" previous_invocation_id)" =~ ^[0-9a-f]{32}$ ]]
  test "$(manifest_value "$manifest" acceptance_binding_sha256)" = \
    "$ACCEPTANCE_BINDING_SHA256"
  test "$(manifest_value "$manifest" acceptance_program_sha256)" = \
    "$ACCEPTANCE_PROGRAM_SHA256"
  test "$(manifest_value "$manifest" acceptance_control_sha256)" = \
    "$CONTROL_SHA256"
  test "$(manifest_value "$manifest" unit_fragment_sha256)" = \
    "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
  test "$(manifest_value "$manifest" prelaunch_descriptor_sha256)" = \
    "$(sha256_file "$PRELAUNCH_DESCRIPTOR")"
}

unit_timestamp() {
  local property="$1"
  local observed

  observed="$(unit_property "$property")"
  test -n "$observed"
  date -u --date="$observed" +%Y-%m-%dT%H:%M:%SZ
}

launch_acceptance() {
  local active_state
  local created_at
  local invocation_id
  local previous_invocation_id
  local started_at
  local temporary

  publish_unit_fragment_archive
  install_unit_fragment
  systemctl daemon-reload
  capture_effective_descriptor "$PRELAUNCH_DESCRIPTOR"

  if [[ -e "$LAUNCH_CHECKSUM" && ! -e "$LAUNCH_MANIFEST" ]]; then
    die 'acceptance launch checksum exists without its manifest'
  fi
  if [[ -e "$LAUNCH_MANIFEST" ]]; then
    require_root_artifact "$LAUNCH_MANIFEST"
    validate_launch_manifest "$LAUNCH_MANIFEST"
    if [[ -e "$LAUNCH_CHECKSUM" ]]; then
      verify_checksum "$LAUNCH_MANIFEST" "$LAUNCH_CHECKSUM"
    else
      seal_in_place "$LAUNCH_MANIFEST"
    fi
    test "$(unit_property InvocationID)" = \
      "$(manifest_value "$LAUNCH_MANIFEST" invocation_id)"
    printf '[UMI-FBIG] stage=acceptance_launched invocation_id=%s resumed=true\n' \
      "$(manifest_value "$LAUNCH_MANIFEST" invocation_id)"
    return
  fi

  active_state="$(unit_property ActiveState)"
  if [[ -e "$START_INTENT_CHECKSUM" && ! -e "$START_INTENT" ]]; then
    die 'acceptance start-intent checksum exists without its manifest'
  fi
  if [[ -e "$START_INTENT" ]]; then
    validate_start_intent "$START_INTENT"
  else
    test "$active_state" = inactive
    test ! -e "$AUDIT_DIR"
    previous_invocation_id="$(unit_property InvocationID)"
    [[ "$previous_invocation_id" =~ ^[0-9a-f]{32}$ ]] ||
      previous_invocation_id=none
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    temporary="${START_INTENT}.$$.tmp"
    (
      set -o noclobber
      {
        printf 'schema_version\t1\n'
        printf 'acceptance_id\t%s\n' "$ACCEPTANCE_ID"
        printf 'created_at\t%s\n' "$created_at"
        printf 'previous_invocation_id\t%s\n' "$previous_invocation_id"
        printf 'acceptance_binding_sha256\t%s\n' "$ACCEPTANCE_BINDING_SHA256"
        printf 'acceptance_program_sha256\t%s\n' "$ACCEPTANCE_PROGRAM_SHA256"
        printf 'acceptance_control_sha256\t%s\n' "$CONTROL_SHA256"
        printf 'unit_fragment_sha256\t%s\n' \
          "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
        printf 'prelaunch_descriptor_sha256\t%s\n' \
          "$(sha256_file "$PRELAUNCH_DESCRIPTOR")"
      } >"$temporary"
    )
    publish_artifact "$temporary" "$START_INTENT"
    validate_start_intent "$START_INTENT"
  fi

  if [[ "$active_state" = inactive ]]; then
    if [[ ! -e "$AUDIT_DIR" ]]; then
      systemctl start "$ACCEPTANCE_UNIT"
    else
      test "$(unit_property Result)" = success
      [[ "$(unit_property InvocationID)" =~ ^[0-9a-f]{32}$ ]] ||
        die 'completed acceptance invocation cannot be adopted'
    fi
  elif [[ "$active_state" != active && "$active_state" != activating ]]; then
    die "acceptance unit cannot be adopted from state $active_state"
  fi

  invocation_id="$(unit_property InvocationID)"
  [[ "$invocation_id" =~ ^[0-9a-f]{32}$ ]]
  started_at="$(unit_timestamp ExecMainStartTimestamp)"
  previous_invocation_id="$(manifest_value "$START_INTENT" previous_invocation_id)"
  test "$previous_invocation_id" = none ||
    test "$invocation_id" != "$previous_invocation_id"
  test "$(date -u -d "$started_at" +%s)" -ge "$(
    date -u -d "$(manifest_value "$START_INTENT" created_at)" +%s
  )"
  temporary="${LAUNCH_MANIFEST}.$$.tmp"
  (
    set -o noclobber
    {
      printf 'schema_version\t1\n'
      printf 'acceptance_id\t%s\n' "$ACCEPTANCE_ID"
      printf 'invocation_id\t%s\n' "$invocation_id"
      printf 'started_at\t%s\n' "$started_at"
      printf 'acceptance_binding_sha256\t%s\n' "$ACCEPTANCE_BINDING_SHA256"
      printf 'acceptance_program_sha256\t%s\n' "$ACCEPTANCE_PROGRAM_SHA256"
      printf 'acceptance_control_sha256\t%s\n' "$CONTROL_SHA256"
      printf 'unit_fragment_sha256\t%s\n' "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
      printf 'prelaunch_descriptor_sha256\t%s\n' \
        "$(sha256_file "$PRELAUNCH_DESCRIPTOR")"
      printf 'start_intent_sha256\t%s\n' "$(sha256_file "$START_INTENT")"
    } >"$temporary"
  )
  publish_artifact "$temporary" "$LAUNCH_MANIFEST"
  validate_launch_manifest "$LAUNCH_MANIFEST"
  printf '[UMI-FBIG] stage=acceptance_launched invocation_id=%s resumed=false\n' \
    "$invocation_id"
}

validate_history_terminal_summary() {
  local summary="$1"
  local platform="$2"
  local counter

  require_root_artifact "$summary"
  test "$(stage_value "$summary" history_import_summary platforms)" = "$platform"
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = true
  for counter in \
    imported_contacts imported_archives imported_incoming imported_outgoing \
    imported_messages imported_attachments marker_normalizations \
    history_evidence_changes_applied \
    messenger_history_evidence_changes_applied \
    instagram_history_evidence_changes_applied \
    profile_changes_applied avatars_attached avatars_raced \
    contentless_acceptance_mismatches ambiguous_senders \
    foreign_source_id_anomalies platform_failures retry_exhaustion \
    authentication_failures lock_loss reindex_failures \
    download_budget_exhaustions exit_failures; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done
}

validate_profile_terminal_summary() {
  local summary="$1"
  local counter
  local remaining
  local unavailable
  local blank_name

  require_root_artifact "$summary"
  test "$(stage_value "$summary" history_profiles_summary scan_complete)" = true
  test "$(stage_value "$summary" history_profiles_summary write_complete)" = true
  for counter in \
    scalar_changes_applied name_changes_applied username_changes_applied \
    optional_changes_applied avatars_attached avatar_bytes mirror_jobs \
    exit_failures lock_loss profile_errors avatar_failures \
    messenger_targets_blocking instagram_targets_blocking \
    seed_targets_blocking; do
    test "$(stage_value "$summary" history_profiles_summary "$counter")" = 0
  done
  test "$(stage_value "$summary" history_profiles_summary \
    instagram_placeholders_projected_repair)" = 0
  test "$(stage_value "$summary" history_profiles_summary \
    instagram_placeholders_unclassified)" = 0
  remaining="$(stage_value "$summary" history_profiles_summary \
    instagram_placeholders_remaining)"
  unavailable="$(stage_value "$summary" history_profiles_summary \
    instagram_placeholders_unavailable)"
  blank_name="$(stage_value "$summary" history_profiles_summary \
    instagram_placeholders_blank_name)"
  test "$remaining" = "$((unavailable + blank_name))"
  test "$(stage_value "$summary" history_profiles_summary \
    instagram_placeholders_remaining_fingerprint)" = "$(
    stage_value "$summary" history_profiles_summary \
      instagram_placeholders_classified_fingerprint
  )"
}

seal_audit_tree() {
  local artifact
  local audit_device
  local base
  local directory
  local relative
  local index_source
  local index_temporary

  test -z "$(find "$AUDIT_DIR" -xdev -mindepth 1 \
    ! -type d ! -type f -print -quit)"
  audit_device="$(stat -Lc '%d' "$AUDIT_DIR")"

  while IFS= read -r -d '' directory; do
    require_root_directory "$directory"
    test "$(stat -Lc '%d' "$directory")" = "$audit_device"
    relative="${directory#"$AUDIT_DIR"/}"
    if [[ "$directory" != "$AUDIT_DIR" ]]; then
      [[ "$relative" =~ ^[a-zA-Z0-9._/-]+$ ]] ||
        die 'audit directory path contains unsupported characters'
    fi
  done < <(find "$AUDIT_DIR" -xdev -type d -print0 | sort -z)

  while IFS= read -r -d '' artifact; do
    case "$artifact" in
      *.sha256|"$ARTIFACT_INDEX"|"$TERMINAL_MANIFEST")
        continue
        ;;
    esac
    seal_in_place "$artifact"
  done < <(find "$AUDIT_DIR" -xdev -type f -print0 | sort -z)

  while IFS= read -r -d '' artifact; do
    test "$(stat -Lc '%d' "$artifact")" = "$audit_device"
    base="${artifact%.sha256}"
    require_root_artifact "$base"
    verify_checksum "$base" "$artifact"
  done < <(
    find "$AUDIT_DIR" -xdev -type f -name '*.sha256' \
      ! -path "$ARTIFACT_INDEX_CHECKSUM" \
      ! -path "$TERMINAL_CHECKSUM" -print0 | sort -z
  )

  index_source="$OPS_DIR/.fbig-acceptance-artifact-index.$$.tmp"
  (
    set -o noclobber
    while IFS= read -r -d '' artifact; do
      case "$artifact" in
        *.sha256|"$ARTIFACT_INDEX"|"$TERMINAL_MANIFEST")
          continue
          ;;
      esac
      relative="${artifact#"$AUDIT_DIR"/}"
      [[ "$relative" =~ ^[a-zA-Z0-9._/-]+$ ]] ||
        die 'audit artifact path contains unsupported characters'
      verify_checksum "$artifact" "${artifact}.sha256"
      printf '%s\t%s\n' "$relative" "$(sha256_file "$artifact")"
    done < <(find "$AUDIT_DIR" -xdev -type f -print0 | sort -z)
  ) >"$index_source"

  if [[ -e "$ARTIFACT_INDEX_CHECKSUM" && ! -e "$ARTIFACT_INDEX" ]]; then
    rm -f "$index_source"
    die 'acceptance artifact index checksum exists without its artifact'
  fi
  if [[ -e "$ARTIFACT_INDEX" ]]; then
    require_root_artifact "$ARTIFACT_INDEX"
    cmp -s "$index_source" "$ARTIFACT_INDEX" || {
      rm -f "$index_source"
      die 'acceptance artifact index changed'
    }
    rm -f "$index_source"
    if [[ -e "$ARTIFACT_INDEX_CHECKSUM" ]]; then
      verify_checksum "$ARTIFACT_INDEX" "$ARTIFACT_INDEX_CHECKSUM"
    else
      seal_in_place "$ARTIFACT_INDEX"
    fi
  else
    index_temporary="${ARTIFACT_INDEX}.$$.tmp"
    cp --reflink=never --no-clobber "$index_source" "$index_temporary"
    test -f "$index_temporary"
    rm -f "$index_source"
    publish_artifact "$index_temporary" "$ARTIFACT_INDEX"
  fi
}

validate_terminal_manifest() {
  local manifest="$1"
  local history_approval="$AUDIT_DIR/history-approval/fbig-approval-v1.tsv"
  local profile_approval="$AUDIT_DIR/profile-approval/fbig-profile-approval-v1.tsv"
  local profile_targets="$AUDIT_DIR/profile-targets/fbig-profile-targets-v1.tsv"
  local clone_baseline="$AUDIT_DIR/clone-scoped-baseline.txt"
  local messenger_summary="$AUDIT_DIR/history-messenger-recovery-summary.tsv"
  local instagram_summary="$AUDIT_DIR/history-instagram-recovery-summary.tsv"
  local profile_summary="$AUDIT_DIR/clone-profile/idempotency/clone-profile-summary.tsv"
  local sidecar="$AUDIT_DIR/history-approval/fbig-unrecoverable-envelope-v1.tsv"
  local field

  require_ordered_manifest "$manifest" "${TERMINAL_FIELDS[@]}"
  test "$(manifest_value "$manifest" schema_version)" = 1
  test "$(manifest_value "$manifest" acceptance_id)" = "$ACCEPTANCE_ID"
  test "$(manifest_value "$manifest" candidate_commit)" = "$APP_COMMIT"
  test "$(manifest_value "$manifest" candidate_image)" = "$APP_DIGEST"
  test "$(manifest_value "$manifest" clone_database_name)" = "$CLONE_DATABASE"
  test "$(manifest_value "$manifest" production_database_name)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$manifest" account_id)" = \
    "$(manifest_value "$history_approval" account_id)"
  test "$(manifest_value "$manifest" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$manifest" facebook_page_id)" = \
    "$(manifest_value "$history_approval" facebook_page_id)"
  test "$(manifest_value "$manifest" instagram_business_id)" = \
    "$(manifest_value "$history_approval" instagram_business_id)"
  test "$(manifest_value "$manifest" history_approval_sha256)" = \
    "$(sha256_file "$history_approval")"
  test "$(manifest_value "$manifest" profile_approval_sha256)" = \
    "$(sha256_file "$profile_approval")"
  test "$(manifest_value "$manifest" profile_targets_sha256)" = \
    "$(sha256_file "$profile_targets")"
  test "$(manifest_value "$manifest" clone_baseline_sha256)" = \
    "$(sha256_file "$clone_baseline")"
  test "$(manifest_value "$manifest" messenger_history_terminal_summary_sha256)" = \
    "$(sha256_file "$messenger_summary")"
  test "$(manifest_value "$manifest" instagram_history_terminal_summary_sha256)" = \
    "$(sha256_file "$instagram_summary")"
  test "$(manifest_value "$manifest" profile_terminal_summary_sha256)" = \
    "$(sha256_file "$profile_summary")"
  test "$(manifest_value "$manifest" unrecoverable_sidecar_sha256)" = \
    "$(sha256_file "$sidecar")"
  test "$(manifest_value "$manifest" artifact_index_sha256)" = \
    "$(sha256_file "$ARTIFACT_INDEX")"
  test "$(manifest_value "$manifest" acceptance_binding_sha256)" = \
    "$ACCEPTANCE_BINDING_SHA256"
  test "$(manifest_value "$manifest" acceptance_program_sha256)" = \
    "$ACCEPTANCE_PROGRAM_SHA256"
  test "$(manifest_value "$manifest" acceptance_control_sha256)" = \
    "$CONTROL_SHA256"
  test "$(manifest_value "$manifest" unit_fragment_sha256)" = \
    "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
  test "$(manifest_value "$manifest" prelaunch_descriptor_sha256)" = \
    "$(sha256_file "$PRELAUNCH_DESCRIPTOR")"
  test "$(manifest_value "$manifest" start_intent_sha256)" = \
    "$(sha256_file "$START_INTENT")"
  test "$(manifest_value "$manifest" postlaunch_descriptor_sha256)" = \
    "$(sha256_file "$POSTLAUNCH_DESCRIPTOR")"
  test "$(manifest_value "$manifest" invocation_id)" = \
    "$(manifest_value "$LAUNCH_MANIFEST" invocation_id)"
  test "$(manifest_value "$manifest" exit_status)" = 0
  test "$(manifest_value "$manifest" started_at)" = \
    "$(manifest_value "$LAUNCH_MANIFEST" started_at)"
  for field in started_at finished_at sealed_at; do
    [[ "$(manifest_value "$manifest" "$field")" =~ \
      ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  done
}

publish_terminal_manifest() {
  local history_approval="$AUDIT_DIR/history-approval/fbig-approval-v1.tsv"
  local profile_approval="$AUDIT_DIR/profile-approval/fbig-profile-approval-v1.tsv"
  local profile_targets="$AUDIT_DIR/profile-targets/fbig-profile-targets-v1.tsv"
  local clone_baseline="$AUDIT_DIR/clone-scoped-baseline.txt"
  local messenger_summary="$AUDIT_DIR/history-messenger-recovery-summary.tsv"
  local instagram_summary="$AUDIT_DIR/history-instagram-recovery-summary.tsv"
  local profile_summary="$AUDIT_DIR/clone-profile/idempotency/clone-profile-summary.tsv"
  local sidecar="$AUDIT_DIR/history-approval/fbig-unrecoverable-envelope-v1.tsv"
  local finished_at="$1"
  local temporary

  if [[ -e "$TERMINAL_CHECKSUM" && ! -e "$TERMINAL_MANIFEST" ]]; then
    die 'acceptance terminal checksum exists without its manifest'
  fi
  if [[ -e "$TERMINAL_MANIFEST" ]]; then
    require_root_artifact "$TERMINAL_MANIFEST"
    validate_terminal_manifest "$TERMINAL_MANIFEST"
    if [[ -e "$TERMINAL_CHECKSUM" ]]; then
      verify_checksum "$TERMINAL_MANIFEST" "$TERMINAL_CHECKSUM"
    else
      seal_in_place "$TERMINAL_MANIFEST"
    fi
    printf '[UMI-FBIG] stage=acceptance_complete manifest_sha256=%s resumed=true\n' \
      "$(sha256_file "$TERMINAL_MANIFEST")"
    return
  fi

  temporary="${TERMINAL_MANIFEST}.$$.tmp"
  (
    set -o noclobber
    {
      printf 'schema_version\t1\n'
      printf 'acceptance_id\t%s\n' "$ACCEPTANCE_ID"
      printf 'candidate_commit\t%s\n' "$APP_COMMIT"
      printf 'candidate_image\t%s\n' "$APP_DIGEST"
      printf 'clone_database_name\t%s\n' "$CLONE_DATABASE"
      printf 'production_database_name\t%s\n' "$PRODUCTION_DATABASE"
      printf 'account_id\t%s\n' "$(manifest_value "$history_approval" account_id)"
      printf 'inbox_id\t%s\n' "$INBOX_ID"
      printf 'facebook_page_id\t%s\n' \
        "$(manifest_value "$history_approval" facebook_page_id)"
      printf 'instagram_business_id\t%s\n' \
        "$(manifest_value "$history_approval" instagram_business_id)"
      printf 'history_approval_sha256\t%s\n' "$(sha256_file "$history_approval")"
      printf 'profile_approval_sha256\t%s\n' "$(sha256_file "$profile_approval")"
      printf 'profile_targets_sha256\t%s\n' "$(sha256_file "$profile_targets")"
      printf 'clone_baseline_sha256\t%s\n' "$(sha256_file "$clone_baseline")"
      printf 'messenger_history_terminal_summary_sha256\t%s\n' \
        "$(sha256_file "$messenger_summary")"
      printf 'instagram_history_terminal_summary_sha256\t%s\n' \
        "$(sha256_file "$instagram_summary")"
      printf 'profile_terminal_summary_sha256\t%s\n' \
        "$(sha256_file "$profile_summary")"
      printf 'unrecoverable_sidecar_sha256\t%s\n' "$(sha256_file "$sidecar")"
      printf 'artifact_index_sha256\t%s\n' "$(sha256_file "$ARTIFACT_INDEX")"
      printf 'acceptance_binding_sha256\t%s\n' "$ACCEPTANCE_BINDING_SHA256"
      printf 'acceptance_program_sha256\t%s\n' "$ACCEPTANCE_PROGRAM_SHA256"
      printf 'acceptance_control_sha256\t%s\n' "$CONTROL_SHA256"
      printf 'unit_fragment_sha256\t%s\n' "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"
      printf 'prelaunch_descriptor_sha256\t%s\n' \
        "$(sha256_file "$PRELAUNCH_DESCRIPTOR")"
      printf 'start_intent_sha256\t%s\n' "$(sha256_file "$START_INTENT")"
      printf 'postlaunch_descriptor_sha256\t%s\n' \
        "$(sha256_file "$POSTLAUNCH_DESCRIPTOR")"
      printf 'invocation_id\t%s\n' \
        "$(manifest_value "$LAUNCH_MANIFEST" invocation_id)"
      printf 'exit_status\t0\n'
      printf 'started_at\t%s\n' \
        "$(manifest_value "$LAUNCH_MANIFEST" started_at)"
      printf 'finished_at\t%s\n' "$finished_at"
      printf 'sealed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$temporary"
  )
  chmod 0400 "$temporary"
  validate_terminal_manifest "$temporary"
  publish_artifact "$temporary" "$TERMINAL_MANIFEST"
  validate_terminal_manifest "$TERMINAL_MANIFEST"
  printf '[UMI-FBIG] stage=acceptance_complete manifest_sha256=%s resumed=false\n' \
    "$(sha256_file "$TERMINAL_MANIFEST")"
}

finalize_acceptance() {
  local history_approval="$AUDIT_DIR/history-approval/fbig-approval-v1.tsv"
  local profile_approval="$AUDIT_DIR/profile-approval/fbig-profile-approval-v1.tsv"
  local profile_targets="$AUDIT_DIR/profile-targets/fbig-profile-targets-v1.tsv"
  local clone_baseline="$AUDIT_DIR/clone-scoped-baseline.txt"
  local messenger_summary="$AUDIT_DIR/history-messenger-recovery-summary.tsv"
  local instagram_summary="$AUDIT_DIR/history-instagram-recovery-summary.tsv"
  local profile_directory="$AUDIT_DIR/clone-profile/idempotency"
  local profile_summary="$profile_directory/clone-profile-summary.tsv"
  local sidecar="$AUDIT_DIR/history-approval/fbig-unrecoverable-envelope-v1.tsv"
  local finished_at

  acquire_descriptor_verified_lock "$FINALIZER_LOCK"
  verify_checksum "$LAUNCH_MANIFEST" "$LAUNCH_CHECKSUM"
  validate_launch_manifest "$LAUNCH_MANIFEST"
  verify_checksum "$UNIT_FRAGMENT_ARCHIVE" "$UNIT_FRAGMENT_ARCHIVE_CHECKSUM"
  validate_unit_fragment "$UNIT_FRAGMENT_ARCHIVE"
  require_root_artifact "$UNIT_FRAGMENT_PATH"
  test "$(sha256_file "$UNIT_FRAGMENT_PATH")" = \
    "$(sha256_file "$UNIT_FRAGMENT_ARCHIVE")"

  test "$(unit_property ActiveState)" = inactive
  test "$(unit_property SubState)" = dead
  test "$(unit_property Result)" = success
  test "$(unit_property ExecMainStatus)" = 0
  test "$(unit_property InvocationID)" = \
    "$(manifest_value "$LAUNCH_MANIFEST" invocation_id)"
  finished_at="$(unit_timestamp ExecMainExitTimestamp)"

  capture_effective_descriptor "$POSTLAUNCH_DESCRIPTOR"
  cmp -s "$PRELAUNCH_DESCRIPTOR" "$POSTLAUNCH_DESCRIPTOR" ||
    die 'effective unit descriptor differs after acceptance'

  require_root_directory "$AUDIT_DIR"
  for artifact in \
    "$history_approval" "${history_approval}.sha256" \
    "$profile_approval" "${profile_approval}.sha256" \
    "$profile_targets" "$clone_baseline" \
    "$messenger_summary" "$instagram_summary" "$profile_summary" \
    "$profile_directory/fbig-profile-clone-prestate-v1.tsv" \
    "$profile_directory/fbig-profile-clone-prestate-v1.tsv.sha256" \
    "$profile_directory/fbig-profile-clone-poststate-v1.tsv" \
    "$profile_directory/fbig-profile-clone-poststate-v1.tsv.sha256" \
    "$sidecar" "${sidecar}.sha256"; do
    require_root_artifact "$artifact"
  done
  verify_checksum "$history_approval" "${history_approval}.sha256"
  verify_checksum "$profile_approval" "${profile_approval}.sha256"
  verify_checksum "$sidecar" "${sidecar}.sha256"

  test "$(manifest_value "$history_approval" repository_commit)" = "$APP_COMMIT"
  test "$(manifest_value "$history_approval" image_digest)" = "$APP_DIGEST"
  test "$(manifest_value "$history_approval" clone_database_name)" = \
    "$CLONE_DATABASE"
  test "$(manifest_value "$history_approval" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$profile_approval" repository_commit)" = "$APP_COMMIT"
  test "$(manifest_value "$profile_approval" image_digest)" = "$APP_DIGEST"
  test "$(manifest_value "$profile_approval" clone_database_name)" = \
    "$CLONE_DATABASE"
  test "$(manifest_value "$profile_approval" production_database_name)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$profile_approval" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$profile_approval" history_manifest_sha256)" = \
    "$(sha256_file "$history_approval")"
  test "$(manifest_value "$profile_approval" placeholder_targets_sha256)" = \
    "$(sha256_file "$profile_targets")"
  test "$(manifest_value "$profile_approval" clone_profile_idempotency_summary_sha256)" = \
    "$(sha256_file "$profile_summary")"

  validate_history_terminal_summary "$messenger_summary" messenger
  validate_history_terminal_summary "$instagram_summary" instagram
  validate_profile_terminal_summary "$profile_summary"
  verify_checksum \
    "$profile_directory/fbig-profile-clone-prestate-v1.tsv" \
    "$profile_directory/fbig-profile-clone-prestate-v1.tsv.sha256"
  verify_checksum \
    "$profile_directory/fbig-profile-clone-poststate-v1.tsv" \
    "$profile_directory/fbig-profile-clone-poststate-v1.tsv.sha256"
  cmp -s \
    "$profile_directory/fbig-profile-clone-prestate-v1.tsv" \
    "$profile_directory/fbig-profile-clone-poststate-v1.tsv"
  test -z "$(
    docker ps --all --quiet --filter label=com.docker.compose.service=clone-redis
  )"

  seal_audit_tree
  publish_terminal_manifest "$finished_at"
}

case "$ACTION" in
  launch)
    launch_acceptance
    ;;
  finalize)
    finalize_acceptance
    ;;
esac
