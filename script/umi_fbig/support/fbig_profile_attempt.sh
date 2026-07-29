#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly STACK_DIR="${CHATWOOT_STACK_DIR:-/opt/umi/chatwoot}"
readonly DATA_DIR="${CHATWOOT_DATA_DIR:-/opt/umi/data}"
readonly BACKUP_ROOT="${FBIG_BACKUP_ROOT:-/opt/umi/fbig-profile-backups}"
readonly ATTEMPT_ROOT="${FBIG_ATTEMPT_ROOT:-/opt/umi/fbig-profile-attempts}"
readonly STORAGE_HELPER="${FBIG_STORAGE_HELPER:-${STACK_DIR}/bin/fbig_storage_artifact.py}"
readonly DATABASE_USER="${CHATWOOT_DATABASE_USER:-chatwoot}"
readonly DATABASE_NAME="${CHATWOOT_DATABASE_NAME:-chatwoot_production}"
readonly MAX_WRITER_OUTAGE_SECONDS="${FBIG_MAX_WRITER_OUTAGE_SECONDS:-3300}"
readonly LOCK_PATH="/run/lock/umi-fbig/production.lock"
readonly PROFILE_AUDIT_ROOT="${FBIG_PROFILE_AUDIT_ROOT:-none}"
readonly EXPECTED_AUTHORIZATION_MODE="${FBIG_PROFILE_AUTHORIZATION_MODE:-none}"
readonly EXPECTED_AUTHORIZATION_SHA256="${FBIG_PROFILE_AUTHORIZATION_SHA256:-none}"
readonly EXPECTED_PROFILE_APPROVAL_SHA256="${FBIG_PROFILE_APPROVAL_SHA256:-none}"
readonly EXPECTED_ACCEPTANCE_SHA256="${FBIG_PROFILE_ACCEPTANCE_SHA256:-none}"
readonly PROFILE_PREDECESSOR_RESULT="${FBIG_PROFILE_PREDECESSOR_RESULT:-none}"
readonly PROFILE_PREDECESSOR_AUDIT="${FBIG_PROFILE_PREDECESSOR_AUDIT:-none}"
readonly PROFILE_RESULT_FIELDS=(
  schema_version authorization_mode authorization_sha256 label profile_phase
  program_sha256 binding_sha256 profile_wrapper_sha256 storage_helper_sha256
  candidate_commit candidate_image production_database inbox_id acceptance_sha256
  profile_approval_sha256 predecessor_result_sha256 predecessor_audit_sha256
  before_checkpoint_sha256 attempt_identity_sha256 attempt_directory
  attempt_manifest_sha256 pre_attempt_backup_directory pre_attempt_backup_sha256
  wrapper_log_sha256 wrapper_exit_status_sha256 platforms dry_run
  zero_write_observed termination started_at finished_at sealed_at
)
readonly PROFILE_AUDIT_FIELDS=(
  schema_version authorization_mode authorization_sha256 label program_sha256
  binding_sha256 candidate_commit candidate_image acceptance_sha256
  attempt_result_sha256 attempt_manifest_sha256 attempt_started_at
  attempt_finished_at before_checkpoint_sha256 after_checkpoint_sha256
  audit_window_started_at audit_window_finished_at page_identity_sha256
  instagram_identity_sha256 page_subscription_evidence_sha256
  instagram_subscription_evidence_sha256 messenger_recon_summary_sha256
  instagram_recon_summary_sha256 messenger_missing instagram_missing
  messenger_threads_failed instagram_threads_failed messenger_caps_hit
  instagram_caps_hit zero_unrecovered_deliveries predecessor_audit_sha256
  audited_at
)
readonly PROFILE_ATTEMPT_FIELDS=(
  schema_version profile_approval_sha256 image_digest production_database_name
  platforms dry_run pre_attempt_backup_sha256 prestate_sha256 poststate_sha256
  avatar_staging_sha256 run_log_sha256 run_summary_sha256 exit_status started_at
  finished_at
)

usage() {
  cat >&2 <<'USAGE'
Usage:
  sudo fbig_profile_attempt.sh INBOX_ID DRY_RUN PLATFORMS \
    HISTORY_MANIFEST HISTORY_CHECKSUM PROFILE_APPROVAL PROFILE_CHECKSUM [PROFILE_TARGETS]
  sudo fbig_profile_attempt.sh --resume-pre-task INBOX_ID \
    PROFILE_APPROVAL PROFILE_CHECKSUM ATTEMPT_DIRECTORY

DRY_RUN must be true or false. Production apply requires messenger,instagram.
PROFILE_TARGETS is required exactly when PLATFORMS includes Instagram.
Every artifact path must be absolute, root-owned, immutable, and use its fixed basename.
The resume form is accepted only when a durable marker proves the task was
never authorized to start and no task evidence or avatar intent exists.
USAGE
  exit 64
}

die() {
  printf 'fbig profile attempt error: %s\n' "$*" >&2
  exit 70
}

require_root_artifact() {
  local path="$1"
  local basename="$2"
  local directory
  [[ "$path" = /* && "$(basename "$path")" == "$basename" ]] || die "invalid ${basename} path"
  [[ "$(realpath -e -- "$path")" == "$path" ]] || die "artifact path contains a link: ${basename}"
  [[ -f "$path" && ! -L "$path" ]] || die "missing regular artifact ${basename}"
  [[ "$(stat -c '%u:%a:%h' "$path")" == "0:400:1" ]] || die "unsafe ownership or mode for ${basename}"
  directory="$(dirname "$path")"
  [[ -d "$directory" && ! -L "$directory" && "$(stat -c '%u:%a' "$directory")" == "0:700" ]] ||
    die "unsafe parent directory for ${basename}"
}

verify_checksum() {
  local artifact="$1"
  local checksum="$2"
  local expected
  expected="$(printf '%s  %s\n' "$(sha256 "$artifact")" "$(basename "$artifact")")"
  [[ "$(cat "$checksum")" == "$expected" ]] || die "checksum mismatch for $(basename "$artifact")"
}

manifest_value() {
  local path="$1"
  local key="$2"
  local value
  value="$(awk -F $'\t' -v expected="$key" '$1 == expected { count += 1; value = $2 } END { if (count != 1) exit 1; print value }' "$path")" ||
    die "missing or duplicate ${key}"
  printf '%s' "$value"
}

require_ordered_fields() {
  local path="$1"
  shift
  local expected=("$@")
  local observed
  mapfile -t observed < <(awk -F $'\t' 'NF == 2 { print $1 }' "$path")
  [[ "${#observed[@]}" == "${#expected[@]}" ]] || die "invalid field count in $(basename "$path")"
  local index
  for index in "${!expected[@]}"; do
    [[ "${observed[$index]}" == "${expected[$index]}" ]] ||
      die "invalid field order in $(basename "$path")"
  done
}

require_canonical_path() {
  local path="$1"
  [[ "$path" = /* && "$(realpath -m -- "$path")" == "$path" ]] ||
    die "path is not canonical and link-free: ${path}"
}

sha256() {
  sha256sum "$1" | awk '{print $1}'
}

fsync_path() {
  python3 "$STORAGE_HELPER" fsync "$1"
}

compose() {
  docker compose --project-directory "$STACK_DIR" "$@"
}

acquire_operation_lock() {
  local lock_parent="/run/lock"
  local lock_directory mode path_identity descriptor_identity
  lock_directory="$(dirname "$LOCK_PATH")"
  [[ "$(realpath -e -- "$lock_parent")" == "$lock_parent" &&
     -d "$lock_parent" && ! -L "$lock_parent" &&
     "$(stat -c '%u:%g' "$lock_parent")" == "0:0" ]] ||
    die "deployment lock parent is not protected"
  mode="$(stat -c '%a' "$lock_parent")"
  (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) ||
    die "deployment lock parent is writable without sticky protection"
  if [[ ! -e "$lock_directory" && ! -L "$lock_directory" ]]; then
    mkdir --mode=0700 -- "$lock_directory" 2>/dev/null || true
  fi
  [[ "$(realpath -e -- "$lock_directory")" == "$lock_directory" &&
     -d "$lock_directory" && ! -L "$lock_directory" &&
     "$(stat -c '%u:%g' "$lock_directory")" == "0:0" ]] ||
    die "deployment lock directory is not protected"
  mode="$(stat -c '%a' "$lock_directory")"
  (( (8#$mode & 0022) == 0 )) || die "deployment lock directory is writable by non-root users"
  chmod 0700 "$lock_directory"
  if [[ ! -e "$LOCK_PATH" && ! -L "$LOCK_PATH" ]]; then
    ( set -o noclobber; : >"$LOCK_PATH" ) 2>/dev/null || true
  fi
  [[ -f "$LOCK_PATH" && ! -L "$LOCK_PATH" &&
     "$(stat -c '%u:%g:%h' "$LOCK_PATH")" == "0:0:1" ]] ||
    die "deployment lock must be a root-owned single-link regular file"
  chmod 0600 "$LOCK_PATH"
  exec 9<>"$LOCK_PATH"
  path_identity="$(stat -Lc '%d:%i' "$LOCK_PATH")"
  descriptor_identity="$(stat -Lc '%d:%i' "/proc/self/fd/9")"
  [[ "$descriptor_identity" == "$path_identity" ]] || die "deployment lock changed while opening"
  flock --exclusive --nonblock 9 || die "another FB/IG production operation owns the deployment lock"
  [[ "$(stat -Lc '%d:%i' "$LOCK_PATH")" == "$descriptor_identity" ]] ||
    die "deployment lock changed after acquisition"
}

paths_overlap() {
  local first="$1"
  local second="$2"
  [[ "$first" == "$second" || "$first" == "${second}/"* || "$second" == "${first}/"* ]]
}

validate_root_paths() {
  local storage_root="${DATA_DIR}/storage"
  local path operator_root protected
  for path in "$STACK_DIR" "$DATA_DIR" "$storage_root" "$BACKUP_ROOT" "$ATTEMPT_ROOT"; do
    [[ "$path" = /* && "$(realpath -m -- "$path")" == "$path" ]] || die "path is not canonical and link-free: ${path}"
  done
  for operator_root in "$BACKUP_ROOT" "$ATTEMPT_ROOT"; do
    for protected in "$STACK_DIR" "$DATA_DIR"; do
      ! paths_overlap "$operator_root" "$protected" ||
        die "operator root overlaps protected production path: ${protected}"
    done
  done
  ! paths_overlap "$BACKUP_ROOT" "$ATTEMPT_ROOT" || die "backup and attempt roots overlap"
}

validate_profile_predecessor_chain() {
  PROFILE_PREDECESSOR_STATE_PATH=none
  [[ "$AUTHORIZATION_MODE" = production_first ]] || return
  [[ "$EXPECTED_AUTHORIZATION_MODE" = production_first &&
     "$EXPECTED_AUTHORIZATION_SHA256" =~ ^[0-9a-f]{64}$ &&
     "$EXPECTED_PROFILE_APPROVAL_SHA256" =~ ^[0-9a-f]{64}$ &&
     "$EXPECTED_ACCEPTANCE_SHA256" = none ]] ||
    die "production-first profile predecessor scope is invalid"
  [[ "$PROFILE_AUDIT_ROOT" = /* &&
     "$(realpath -e -- "$PROFILE_AUDIT_ROOT")" = "$PROFILE_AUDIT_ROOT" &&
     -d "$PROFILE_AUDIT_ROOT" && ! -L "$PROFILE_AUDIT_ROOT" &&
     "$(stat -c '%u:%a' "$PROFILE_AUDIT_ROOT")" = "0:700" ]] ||
    die "production-first profile audit root is invalid"

  local candidate predecessor possible_head referenced
  local current_head=none
  local -a result_shas=()
  local -a predecessor_shas=()
  local -a heads=()
  while IFS= read -r -d '' candidate; do
    require_root_artifact "$candidate" fbig-profile-attempt-result-v1.tsv
    require_root_artifact "${candidate}.sha256" fbig-profile-attempt-result-v1.tsv.sha256
    verify_checksum "$candidate" "${candidate}.sha256"
    require_ordered_fields "$candidate" "${PROFILE_RESULT_FIELDS[@]}"
    if [[ "$(manifest_value "$candidate" authorization_mode)" = production_first &&
       "$(manifest_value "$candidate" authorization_sha256)" = "$EXPECTED_AUTHORIZATION_SHA256" &&
       "$(manifest_value "$candidate" profile_approval_sha256)" = "$EXPECTED_PROFILE_APPROVAL_SHA256" ]]; then
      result_shas+=("$(sha256 "$candidate")")
      predecessor="$(manifest_value "$candidate" predecessor_result_sha256)"
      [[ "$predecessor" = none ]] || predecessor_shas+=("$predecessor")
    fi
  done < <(
    find "$PROFILE_AUDIT_ROOT" -mindepth 2 -maxdepth 2 -type f \
      -name fbig-profile-attempt-result-v1.tsv -print0
  )
  for possible_head in "${result_shas[@]}"; do
    referenced=false
    for predecessor in "${predecessor_shas[@]}"; do
      if [[ "$possible_head" = "$predecessor" ]]; then
        referenced=true
        break
      fi
    done
    [[ "$referenced" = true ]] || heads+=("$possible_head")
  done
  [[ "${#heads[@]}" -le 1 ]] || die "production-first profile chain has multiple heads"
  [[ "${#heads[@]}" -eq 0 ]] || current_head="${heads[0]}"

  if [[ "$PROFILE_PREDECESSOR_RESULT" = none ]]; then
    [[ "$PROFILE_PREDECESSOR_AUDIT" = none && "$current_head" = none ]] ||
      die "initial production-first profile attempt has a predecessor head"
    return
  fi

  require_root_artifact "$PROFILE_PREDECESSOR_RESULT" fbig-profile-attempt-result-v1.tsv
  require_root_artifact "${PROFILE_PREDECESSOR_RESULT}.sha256" fbig-profile-attempt-result-v1.tsv.sha256
  require_root_artifact "$PROFILE_PREDECESSOR_AUDIT" fbig-profile-delivery-audit-v1.tsv
  require_root_artifact "${PROFILE_PREDECESSOR_AUDIT}.sha256" fbig-profile-delivery-audit-v1.tsv.sha256
  verify_checksum "$PROFILE_PREDECESSOR_RESULT" "${PROFILE_PREDECESSOR_RESULT}.sha256"
  verify_checksum "$PROFILE_PREDECESSOR_AUDIT" "${PROFILE_PREDECESSOR_AUDIT}.sha256"
  require_ordered_fields "$PROFILE_PREDECESSOR_RESULT" "${PROFILE_RESULT_FIELDS[@]}"
  require_ordered_fields "$PROFILE_PREDECESSOR_AUDIT" "${PROFILE_AUDIT_FIELDS[@]}"
  local result_sha audit_sha audit_matches=0 matching_audit_sha=none
  result_sha="$(sha256 "$PROFILE_PREDECESSOR_RESULT")"
  audit_sha="$(sha256 "$PROFILE_PREDECESSOR_AUDIT")"
  [[ "$result_sha" = "$current_head" ]] ||
    die "profile predecessor is not the unique current result head"
  while IFS= read -r -d '' candidate; do
    require_root_artifact "$candidate" fbig-profile-delivery-audit-v1.tsv
    require_root_artifact "${candidate}.sha256" fbig-profile-delivery-audit-v1.tsv.sha256
    verify_checksum "$candidate" "${candidate}.sha256"
    require_ordered_fields "$candidate" "${PROFILE_AUDIT_FIELDS[@]}"
    if [[ "$(manifest_value "$candidate" authorization_mode)" = production_first &&
       "$(manifest_value "$candidate" authorization_sha256)" = "$EXPECTED_AUTHORIZATION_SHA256" &&
       "$(manifest_value "$candidate" attempt_result_sha256)" = "$current_head" ]]; then
      audit_matches=$((audit_matches + 1))
      matching_audit_sha="$(sha256 "$candidate")"
    fi
  done < <(
    find "$PROFILE_AUDIT_ROOT" -mindepth 2 -maxdepth 2 -type f \
      -name fbig-profile-delivery-audit-v1.tsv -print0
  )
  [[ "$audit_matches" -eq 1 && "$matching_audit_sha" = "$audit_sha" ]] ||
    die "profile predecessor audit is not the unique current audit head"
  [[ "$(manifest_value "$PROFILE_PREDECESSOR_RESULT" authorization_sha256)" = \
       "$EXPECTED_AUTHORIZATION_SHA256" &&
     "$(manifest_value "$PROFILE_PREDECESSOR_RESULT" profile_approval_sha256)" = \
       "$EXPECTED_PROFILE_APPROVAL_SHA256" &&
     "$(manifest_value "$PROFILE_PREDECESSOR_RESULT" acceptance_sha256)" = \
       "$EXPECTED_ACCEPTANCE_SHA256" &&
     "$(manifest_value "$PROFILE_PREDECESSOR_RESULT" dry_run)" = false &&
     "$(manifest_value "$PROFILE_PREDECESSOR_AUDIT" authorization_sha256)" = \
       "$EXPECTED_AUTHORIZATION_SHA256" &&
     "$(manifest_value "$PROFILE_PREDECESSOR_AUDIT" attempt_result_sha256)" = "$result_sha" &&
     "$(manifest_value "$PROFILE_PREDECESSOR_AUDIT" zero_unrecovered_deliveries)" = true &&
     "$(manifest_value "$PROFILE_PREDECESSOR_AUDIT" predecessor_audit_sha256)" = \
       "$(manifest_value "$PROFILE_PREDECESSOR_RESULT" predecessor_audit_sha256)" ]] ||
    die "profile predecessor result and delivery audit do not match"

  local attempt_directory attempt_manifest poststate
  attempt_directory="$(manifest_value "$PROFILE_PREDECESSOR_RESULT" attempt_directory)"
  [[ "$(dirname "$attempt_directory")" = "$ATTEMPT_ROOT" &&
     "$(realpath -e -- "$attempt_directory")" = "$attempt_directory" &&
     -d "$attempt_directory" && ! -L "$attempt_directory" &&
     "$(stat -c '%u:%a' "$attempt_directory")" = "0:700" ]] ||
    die "profile predecessor attempt directory is invalid"
  attempt_manifest="$attempt_directory/fbig-profile-production-attempt-v1.tsv"
  poststate="$attempt_directory/fbig-profile-production-poststate-v1.tsv"
  require_root_artifact "$attempt_manifest" fbig-profile-production-attempt-v1.tsv
  require_root_artifact "${attempt_manifest}.sha256" fbig-profile-production-attempt-v1.tsv.sha256
  require_root_artifact "$poststate" fbig-profile-production-poststate-v1.tsv
  require_root_artifact "${poststate}.sha256" fbig-profile-production-poststate-v1.tsv.sha256
  verify_checksum "$attempt_manifest" "${attempt_manifest}.sha256"
  verify_checksum "$poststate" "${poststate}.sha256"
  require_ordered_fields "$attempt_manifest" "${PROFILE_ATTEMPT_FIELDS[@]}"
  [[ "$(manifest_value "$PROFILE_PREDECESSOR_RESULT" attempt_manifest_sha256)" = \
       "$(sha256 "$attempt_manifest")" &&
     "$(manifest_value "$attempt_manifest" poststate_sha256)" = "$(sha256 "$poststate")" ]] ||
    die "profile predecessor poststate binding is invalid"
  PROFILE_PREDECESSOR_STATE_PATH="$poststate"
}

postgres() {
  compose exec -T postgres "$@"
}

writers_running_count() {
  local count=0 service
  for service in rails sidekiq; do
    [[ -n "$(compose ps -q "$service")" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

check_database_quiescence() {
  local sessions
  sessions="$(
    postgres psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -AtX -v ON_ERROR_STOP=1 -c \
      "SELECT count(*) FROM pg_stat_activity
       WHERE datname = current_database()
         AND pid <> pg_backend_pid()
         AND backend_type = 'client backend';"
  )"
  [[ "$sessions" == "0" ]] || die "database still has ${sessions} non-administrative client sessions"
}

verify_maintenance_response() {
  local path="$1"
  local status
  status="$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
    --resolve chat.umi.store:443:127.0.0.1 \
    --request POST --header 'Content-Type: application/json' --data '{}' \
    "https://chat.umi.store${path}")" || true
  [[ "$status" == "502" || "$status" == "503" ]] ||
    die "maintenance ingress did not return a retryable 502/503 for ${path}; observed ${status}"
}

verify_running_release() {
  local service container image_id digests commit
  for service in rails sidekiq; do
    container="$(compose ps -q "$service")"
    [[ -n "$container" ]] || return 1
    image_id="$(docker inspect --format '{{.Image}}' "$container")"
    digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id")"
    grep -Fxq "$APPROVED_IMAGE_DIGEST" <<<"$digests" || return 1
    commit="$(compose exec -T "$service" sh -c 'tr -d "\r\n" </app/.git_sha')" ||
      return 1
    [[ "$commit" = "$APPROVED_REPOSITORY_COMMIT" ]] || return 1
  done
}

verify_compose_release() {
  local configured_image digest_suffix digests
  configured_image="$(compose config --images | awk '/ghcr\.io\/shumkov\/chatwoot/ { print; exit }')"
  [[ "$configured_image" =~ ^ghcr\.io/shumkov/chatwoot:[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] ||
    die "compose Chatwoot image is not pinned by tag and digest"
  digest_suffix="${configured_image#*@}"
  [[ "ghcr.io/shumkov/chatwoot@${digest_suffix}" == "$APPROVED_IMAGE_DIGEST" ]] ||
    die "compose digest suffix differs from the profile approval"
  digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$configured_image")"
  grep -Fxq "$APPROVED_IMAGE_DIGEST" <<<"$digests" ||
    die "compose one-offs do not resolve to the profile-approved image digest"
}

verify_stopped_release() {
  local service container image_id digests
  for service in rails sidekiq; do
    container="$(compose ps --all -q "$service")"
    [[ -n "$container" ]] || die "${service} container is missing during maintenance"
    image_id="$(docker inspect --format '{{.Image}}' "$container")"
    digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id")"
    grep -Fxq "$APPROVED_IMAGE_DIGEST" <<<"$digests" ||
      die "${service} maintenance container changed image digest"
  done
}

verify_no_unexpected_containers() {
  local observed expected
  observed="$(compose ps --status running --services | LC_ALL=C sort -u)"
  expected=$'caddy\npostgres\nredis'
  [[ "$observed" == "$expected" ]] || die "unexpected running Compose service during quiescence"
}

create_database_backup() {
  postgres pg_dump -U "$DATABASE_USER" -d "$DATABASE_NAME" -Fc >"${BACKUP_BUILD}/database.dump"
  postgres pg_restore --list <"${BACKUP_BUILD}/database.dump" >"${BACKUP_BUILD}/database.restore.list"
  [[ -s "${BACKUP_BUILD}/database.dump" && -s "${BACKUP_BUILD}/database.restore.list" ]] ||
    die "database backup is empty"

  local verification_database="fbig_verify_${RANDOM_HEX}"
  [[ "$verification_database" =~ ^[a-z_][a-z0-9_]*$ ]] || die "invalid verification database name"
  postgres createdb -U "$DATABASE_USER" --template=template0 "$verification_database"
  VERIFY_DATABASE="$verification_database"
  postgres pg_restore -U "$DATABASE_USER" -d "$verification_database" --no-owner --no-privileges \
    <"${BACKUP_BUILD}/database.dump"

  postgres psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -AtX -v ON_ERROR_STOP=1 \
    -c 'SELECT version FROM schema_migrations ORDER BY version' >"${BACKUP_BUILD}/schema.live"
  postgres psql -U "$DATABASE_USER" -d "$verification_database" -AtX -v ON_ERROR_STOP=1 \
    -c 'SELECT version FROM schema_migrations ORDER BY version' >"${BACKUP_BUILD}/schema.restored"
  cmp -s "${BACKUP_BUILD}/schema.live" "${BACKUP_BUILD}/schema.restored" ||
    die "restored database migration set differs"

  local identity_count
  identity_count="$(
    postgres psql -U "$DATABASE_USER" -d "$verification_database" -AtX -v ON_ERROR_STOP=1 -c \
      "SELECT count(*)
       FROM accounts accounts
       JOIN inboxes inboxes
         ON inboxes.account_id = accounts.id
       JOIN channel_facebook_pages channels
         ON channels.id = inboxes.channel_id
        AND inboxes.channel_type = 'Channel::FacebookPage'
       WHERE accounts.id = ${ACCOUNT_ID}
         AND inboxes.id = ${INBOX_ID}
         AND channels.page_id = '${FACEBOOK_PAGE_ID}'
         AND channels.instagram_id = '${INSTAGRAM_BUSINESS_ID}';"
  )"
  [[ "$identity_count" == "1" ]] || die "restored database does not contain the approved FB/IG identity"
  postgres dropdb -U "$DATABASE_USER" "$verification_database"
  VERIFY_DATABASE=""
  rm -f "${BACKUP_BUILD}/schema.live" "${BACKUP_BUILD}/schema.restored"
}

create_storage_backup() {
  local storage_root="${DATA_DIR}/storage"
  [[ -d "$storage_root" && ! -L "$storage_root" ]] || die "production storage root is invalid"
  python3 "$STORAGE_HELPER" manifest "$storage_root" "${BACKUP_BUILD}/storage.manifest"
  tar --create --file "${BACKUP_BUILD}/storage.tar" \
    --format=pax --sort=name --numeric-owner --owner=0 --group=0 --mtime='@0' \
    --directory "$storage_root" .
  local scratch="${BACKUP_BUILD}/storage.verify"
  mkdir -m 0700 "$scratch"
  python3 "$STORAGE_HELPER" verify-archive \
    "${BACKUP_BUILD}/storage.tar" "${BACKUP_BUILD}/storage.manifest" "$scratch"
  rm -rf --one-file-system "$scratch"
}

seal_backup() {
  local created_at
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  chmod 0400 \
    "${BACKUP_BUILD}/database.dump" \
    "${BACKUP_BUILD}/database.restore.list" \
    "${BACKUP_BUILD}/storage.tar" \
    "${BACKUP_BUILD}/storage.manifest"
  local manifest="${BACKUP_BUILD}/fbig-profile-pre-attempt-backup-v1.tsv"
  {
    printf 'schema_version\t1\n'
    printf 'backup_id\t%s\n' "$BACKUP_ID"
    printf 'production_database_name\t%s\n' "$DATABASE_NAME"
    printf 'image_digest\t%s\n' "$APPROVED_IMAGE_DIGEST"
    printf 'database_dump_sha256\t%s\n' "$(sha256 "${BACKUP_BUILD}/database.dump")"
    printf 'database_restore_list_sha256\t%s\n' "$(sha256 "${BACKUP_BUILD}/database.restore.list")"
    printf 'storage_archive_sha256\t%s\n' "$(sha256 "${BACKUP_BUILD}/storage.tar")"
    printf 'storage_manifest_sha256\t%s\n' "$(sha256 "${BACKUP_BUILD}/storage.manifest")"
    printf 'created_at\t%s\n' "$created_at"
  } >"$manifest"
  printf '%s  %s\n' "$(sha256 "$manifest")" "$(basename "$manifest")" >"${manifest}.sha256"
  chmod 0400 "$manifest" "${manifest}.sha256"
  local component
  for component in \
    database.dump database.restore.list storage.tar storage.manifest \
    fbig-profile-pre-attempt-backup-v1.tsv fbig-profile-pre-attempt-backup-v1.tsv.sha256; do
    fsync_path "${BACKUP_BUILD}/${component}"
  done
  fsync_path "$BACKUP_BUILD"
  mv "$BACKUP_BUILD" "$BACKUP_FINAL"
  fsync_path "$BACKUP_ROOT"
  BACKUP_SEALED=true
  BACKUP_MANIFEST_SHA256="$(sha256 "${BACKUP_FINAL}/fbig-profile-pre-attempt-backup-v1.tsv")"
}

create_backup() {
  install -d -m 0700 "$BACKUP_ROOT"
  [[ ! -e "$BACKUP_BUILD" && ! -e "$BACKUP_FINAL" ]] || die "backup id already exists"
  mkdir -m 0700 "$BACKUP_BUILD"
  create_database_backup
  create_storage_backup
  seal_backup
}

seal_run_log() {
  local log="${ATTEMPT_DIRECTORY}/fbig-profile-production-run.log"
  if [[ -f "$RUN_LOG_TEMP" ]]; then
    mv "$RUN_LOG_TEMP" "$log"
  elif [[ ! -f "$log" ]]; then
    printf '[UMI-FBIG] stage=profile_wrapper_failure task_started=%s\n' "$TASK_STARTED" >"$log"
  fi
  chmod 0400 "$log"
  fsync_path "$log"
  RUN_LOG_PATH="$log"
}

seal_run_summary() {
  local summary="${ATTEMPT_DIRECTORY}/fbig-profile-production-run-summary.tsv"
  local count
  count="$(grep -c '^\[UMI-FBIG\] stage=history_profiles_summary ' "$RUN_LOG_PATH" || true)"
  if [[ "$count" == "1" ]]; then
    grep '^\[UMI-FBIG\] stage=history_profiles_summary ' "$RUN_LOG_PATH" >"$summary"
    chmod 0400 "$summary"
    fsync_path "$summary"
    RUN_SUMMARY_SHA256="$(sha256 "$summary")"
  else
    RUN_SUMMARY_SHA256="none"
  fi
}

seal_attempt_binding() {
  local manifest="$ATTEMPT_BINDING_PATH"
  local temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-attempt-binding-v1.tsv.$$.tmp"
  local checksum_temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-attempt-binding-v1.tsv.sha256.$$.tmp"
  [[ ! -e "$manifest" && ! -e "${manifest}.sha256" ]] || die "attempt binding already exists"
  {
    printf 'schema_version\t1\n'
    printf 'attempt_id\t%s\n' "$ATTEMPT_ID"
    printf 'inbox_id\t%s\n' "$INBOX_ID"
    printf 'profile_approval_sha256\t%s\n' "$PROFILE_APPROVAL_SHA256"
    printf 'image_digest\t%s\n' "$APPROVED_IMAGE_DIGEST"
    printf 'production_database_name\t%s\n' "$DATABASE_NAME"
    printf 'backup_id\t%s\n' "$BACKUP_ID"
    printf 'pre_attempt_backup_sha256\t%s\n' "$BACKUP_MANIFEST_SHA256"
    printf 'started_at\t%s\n' "$STARTED_AT"
  } >"$temporary"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  printf '%s  %s\n' "$(sha256 "$temporary")" "$(basename "$manifest")" >"$checksum_temporary"
  chmod 0400 "$checksum_temporary"
  fsync_path "$checksum_temporary"
  mv "$temporary" "$manifest"
  mv "$checksum_temporary" "${manifest}.sha256"
  fsync_path "$ATTEMPT_DIRECTORY"
}

repair_attempt_binding_checksum() {
  local manifest="${ATTEMPT_DIRECTORY}/fbig-profile-attempt-binding-v1.tsv"
  local checksum="${manifest}.sha256"
  [[ -e "$manifest" || -e "$checksum" ]] || return 1
  [[ -f "$manifest" ]] || die "attempt binding checksum exists without its manifest"
  require_root_artifact "$manifest" fbig-profile-attempt-binding-v1.tsv
  if [[ ! -e "$checksum" ]]; then
    local temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-attempt-binding-v1.tsv.sha256.$$.repair"
    printf '%s  %s\n' "$(sha256 "$manifest")" "$(basename "$manifest")" >"$temporary"
    chmod 0400 "$temporary"
    fsync_path "$temporary"
    mv "$temporary" "$checksum"
    fsync_path "$ATTEMPT_DIRECTORY"
  fi
  require_root_artifact "$checksum" fbig-profile-attempt-binding-v1.tsv.sha256
  verify_checksum "$manifest" "$checksum"
}

seal_attempt_stage() {
  local basename="$1"
  local stage="$2"
  local path="${ATTEMPT_DIRECTORY}/${basename}"
  local temporary="${ATTEMPT_DIRECTORY}/.${basename}.$$.tmp"
  [[ ! -e "$path" ]] || die "attempt stage already exists: ${basename}"
  {
    printf 'schema_version\t1\n'
    printf 'attempt_id\t%s\n' "$ATTEMPT_ID"
    printf 'inbox_id\t%s\n' "$INBOX_ID"
    printf 'profile_approval_sha256\t%s\n' "$PROFILE_APPROVAL_SHA256"
    printf 'image_digest\t%s\n' "$APPROVED_IMAGE_DIGEST"
    printf 'production_database_name\t%s\n' "$DATABASE_NAME"
    printf 'stage\t%s\n' "$stage"
    printf 'recorded_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  mv "$temporary" "$path"
  fsync_path "$ATTEMPT_DIRECTORY"
}

safe_pre_task_resume_allowed() {
  local task_stage="${ATTEMPT_DIRECTORY}/fbig-profile-task-start-authorized-v1.tsv"
  [[ ! -e "$task_stage" && ! -L "$task_stage" ]] || return 1
  local evidence
  for evidence in \
    fbig-profile-production-prestate-v1.tsv \
    fbig-profile-production-prestate-v1.tsv.sha256 \
    fbig-profile-production-poststate-v1.tsv \
    fbig-profile-production-poststate-v1.tsv.sha256 \
    fbig-profile-avatar-staging-v1.tsv \
    fbig-profile-avatar-staging-v1.tsv.sha256; do
    [[ ! -e "${ATTEMPT_DIRECTORY}/${evidence}" && ! -L "${ATTEMPT_DIRECTORY}/${evidence}" ]] || return 1
  done
  [[ -d "${ATTEMPT_DIRECTORY}/avatar-intents" ]] || return 1
  ! find "${ATTEMPT_DIRECTORY}/avatar-intents" -mindepth 1 -print -quit | grep -q .
}

validate_pre_task_marker() {
  local marker="${ATTEMPT_DIRECTORY}/fbig-profile-pre-task-v1.tsv"
  require_root_artifact "$marker" fbig-profile-pre-task-v1.tsv
  require_ordered_fields "$marker" \
    schema_version attempt_id inbox_id profile_approval_sha256 image_digest \
    production_database_name stage recorded_at
  [[ "$(manifest_value "$marker" schema_version)" == "1" &&
     "$(manifest_value "$marker" attempt_id)" == "$ATTEMPT_ID" &&
     "$(manifest_value "$marker" inbox_id)" == "$INBOX_ID" &&
     "$(manifest_value "$marker" profile_approval_sha256)" == "$PROFILE_APPROVAL_SHA256" &&
     "$(manifest_value "$marker" image_digest)" == "$APPROVED_IMAGE_DIGEST" &&
     "$(manifest_value "$marker" production_database_name)" == "$DATABASE_NAME" &&
     "$(manifest_value "$marker" stage)" == "pre_task_ready" ]] ||
    die "pre-task marker does not match the selected attempt"
}

evidence_digest_or_none() {
  local basename="$1"
  local path="${ATTEMPT_DIRECTORY}/${basename}"
  if [[ -f "$path" && -f "${path}.sha256" ]]; then
    local expected
    expected="$(printf '%s  %s\n' "$(sha256 "$path")" "$basename")"
    [[ "$(cat "${path}.sha256")" == "$expected" ]] || return 1
    printf '%s' "$(sha256 "$path")"
  else
    printf 'none'
  fi
}

seal_attempt_manifest() {
  local exit_status="$1"
  [[ "$exit_status" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] ||
    exit_status=70
  seal_run_log
  seal_run_summary

  local prestate poststate staging
  prestate="$(evidence_digest_or_none fbig-profile-production-prestate-v1.tsv)" ||
    die "prestate checksum is invalid"
  poststate="$(evidence_digest_or_none fbig-profile-production-poststate-v1.tsv)" ||
    die "poststate checksum is invalid"
  staging="$(evidence_digest_or_none fbig-profile-avatar-staging-v1.tsv)" ||
    die "avatar staging checksum is invalid"
  local backup_sha="none"
  [[ "$BACKUP_SEALED" == true ]] && backup_sha="$BACKUP_MANIFEST_SHA256"
  if (( exit_status == 0 )); then
    [[ "$backup_sha" != "none" &&
       "$prestate" != "none" &&
       "$poststate" != "none" &&
       "$staging" != "none" &&
       "$RUN_SUMMARY_SHA256" != "none" ]] ||
      die "successful profile task is missing required terminal evidence"
  fi
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local manifest="${ATTEMPT_DIRECTORY}/fbig-profile-production-attempt-v1.tsv"
  local temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-production-attempt-v1.tsv.$$.tmp"
  local checksum_temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-production-attempt-v1.tsv.sha256.$$.tmp"
  [[ ! -e "$manifest" && ! -e "${manifest}.sha256" ]] || die "attempt manifest already exists"
  {
    printf 'schema_version\t1\n'
    printf 'profile_approval_sha256\t%s\n' "$PROFILE_APPROVAL_SHA256"
    printf 'image_digest\t%s\n' "$APPROVED_IMAGE_DIGEST"
    printf 'production_database_name\t%s\n' "$DATABASE_NAME"
    printf 'platforms\t%s\n' "$PLATFORMS"
    printf 'dry_run\t%s\n' "$DRY_RUN"
    printf 'pre_attempt_backup_sha256\t%s\n' "$backup_sha"
    printf 'prestate_sha256\t%s\n' "$prestate"
    printf 'poststate_sha256\t%s\n' "$poststate"
    printf 'avatar_staging_sha256\t%s\n' "$staging"
    printf 'run_log_sha256\t%s\n' "$(sha256 "$RUN_LOG_PATH")"
    printf 'run_summary_sha256\t%s\n' "$RUN_SUMMARY_SHA256"
    printf 'exit_status\t%s\n' "$exit_status"
    printf 'started_at\t%s\n' "$STARTED_AT"
    printf 'finished_at\t%s\n' "$finished_at"
  } >"$temporary"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  printf '%s  %s\n' "$(sha256 "$temporary")" "$(basename "$manifest")" >"$checksum_temporary"
  chmod 0400 "$checksum_temporary"
  fsync_path "$checksum_temporary"
  mv "$temporary" "$manifest"
  mv "$checksum_temporary" "${manifest}.sha256"
  fsync_path "$ATTEMPT_DIRECTORY"
  ATTEMPT_SEALED=true
}

validate_sealed_attempt() {
  local profile_directory
  profile_directory="$(dirname "$PROFILE_APPROVAL")"
  compose run --rm --no-deps \
    --env UMI_FBIG_PROFILE_AUTHORIZATION_MODE="$AUTHORIZATION_MODE" \
    --volume "${profile_directory}:/run/fbig/profile:ro" \
    --volume "${BACKUP_FINAL}:/run/fbig/backup:ro" \
    --volume "${ATTEMPT_DIRECTORY}:/run/fbig/attempt:ro" \
    rails bundle exec rails runner '
      approval = if ENV.fetch("UMI_FBIG_PROFILE_AUTHORIZATION_MODE") == "production_first"
                   Umi::Fbig::ProductionFirstProfileApproval.load(
                     manifest_path: "/run/fbig/profile/fbig-production-first-profile-approval-v1.tsv",
                     checksum_path: "/run/fbig/profile/fbig-production-first-profile-approval-v1.tsv.sha256"
                   )
                 else
                   Umi::Fbig::ProfileApprovalManifest.load(
                     manifest_path: "/run/fbig/profile/fbig-profile-approval-v1.tsv",
                     checksum_path: "/run/fbig/profile/fbig-profile-approval-v1.tsv.sha256"
                   )
                 end
      backup = Umi::Fbig::ProfilePreAttemptBackupManifest.load(
        manifest_path: "/run/fbig/backup/fbig-profile-pre-attempt-backup-v1.tsv",
        checksum_path: "/run/fbig/backup/fbig-profile-pre-attempt-backup-v1.tsv.sha256"
      )
      attempt = Umi::Fbig::ProfileProductionAttemptManifest.load(
        manifest_path: "/run/fbig/attempt/fbig-profile-production-attempt-v1.tsv",
        checksum_path: "/run/fbig/attempt/fbig-profile-production-attempt-v1.tsv.sha256"
      )
      prestate = Umi::Fbig::ProfileStateSnapshot.load(
        path: "/run/fbig/attempt/fbig-profile-production-prestate-v1.tsv",
        checksum_path: "/run/fbig/attempt/fbig-profile-production-prestate-v1.tsv.sha256"
      )
      poststate = Umi::Fbig::ProfileStateSnapshot.load(
        path: "/run/fbig/attempt/fbig-profile-production-poststate-v1.tsv",
        checksum_path: "/run/fbig/attempt/fbig-profile-production-poststate-v1.tsv.sha256"
      )
      staging = Umi::Fbig::AvatarStagingManifest.load(
        path: "/run/fbig/attempt/fbig-profile-avatar-staging-v1.tsv",
        checksum_path: "/run/fbig/attempt/fbig-profile-avatar-staging-v1.tsv.sha256"
      )
      valid = attempt.exit_status == "0" &&
              attempt.profile_approval_sha256 == approval.sha256 &&
              attempt.pre_attempt_backup_sha256 == backup.sha256 &&
              attempt.prestate_sha256 == prestate.sha256 &&
              attempt.poststate_sha256 == poststate.sha256 &&
              attempt.avatar_staging_sha256 == staging.sha256 &&
              attempt.image_digest == approval.image_digest &&
              attempt.production_database_name == approval.production_database_name
      abort("invalid sealed production profile attempt") unless valid
    '
}

run_profile_task() {
  local history_directory profile_directory target_directory predecessor_directory
  local target_arguments=()
  local authorization_arguments=()
  local predecessor_arguments=()
  history_directory="$(dirname "$HISTORY_MANIFEST")"
  profile_directory="$(dirname "$PROFILE_APPROVAL")"
  if [[ -n "$PROFILE_TARGETS" ]]; then
    target_directory="$(dirname "$PROFILE_TARGETS")"
    target_arguments=(
      --volume "${target_directory}:/run/fbig/targets:ro"
      --env UMI_FBIG_PROFILE_TARGETS_PATH=/run/fbig/targets/fbig-profile-targets-v1.tsv
    )
  fi
  if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
    authorization_arguments=(
      --env UMI_FBIG_PROFILE_APPROVAL_MODE=production_first
      --env UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_PATH=/run/fbig/history/fbig-production-first-history-approval-v1.tsv
      --env UMI_FBIG_PRODUCTION_FIRST_HISTORY_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-production-first-history-approval-v1.tsv.sha256
      --env UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_PATH=/run/fbig/profile/fbig-production-first-authorization-v1.tsv
      --env UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_CHECKSUM_PATH=/run/fbig/profile/fbig-production-first-authorization-v1.tsv.sha256
      --env UMI_FBIG_PRODUCTION_FIRST_AUTHORIZATION_SHA256="$(manifest_value "$PROFILE_APPROVAL" production_first_authorization_sha256)"
      --env UMI_FBIG_PRODUCTION_FIRST_PROFILE_APPROVAL_PATH=/run/fbig/profile/fbig-production-first-profile-approval-v1.tsv
      --env UMI_FBIG_PRODUCTION_FIRST_PROFILE_APPROVAL_CHECKSUM_PATH=/run/fbig/profile/fbig-production-first-profile-approval-v1.tsv.sha256
      --env UMI_FBIG_MESSENGER_TERMINAL_HISTORY_RESULT_PATH=/run/fbig/profile/fbig-messenger-terminal-history-result-v1.tsv
      --env UMI_FBIG_MESSENGER_TERMINAL_HISTORY_RESULT_CHECKSUM_PATH=/run/fbig/profile/fbig-messenger-terminal-history-result-v1.tsv.sha256
      --env UMI_FBIG_INSTAGRAM_TERMINAL_HISTORY_RESULT_PATH=/run/fbig/profile/fbig-instagram-terminal-history-result-v1.tsv
      --env UMI_FBIG_INSTAGRAM_TERMINAL_HISTORY_RESULT_CHECKSUM_PATH=/run/fbig/profile/fbig-instagram-terminal-history-result-v1.tsv.sha256
      --env UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_PATH=/run/fbig/profile/fbig-coordinated-pre-profile-backup-v1.tsv
      --env UMI_FBIG_COORDINATED_PRE_PROFILE_BACKUP_CHECKSUM_PATH=/run/fbig/profile/fbig-coordinated-pre-profile-backup-v1.tsv.sha256
      --env UMI_FBIG_PROFILE_STATE_PATH=/run/fbig/profile/fbig-profile-state-v1.tsv
      --env UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH=/run/fbig/profile/fbig-profile-state-v1.tsv.sha256
      --env ACK_PRODUCTION_FIRST_LIVE_IMPORT=true
    )
    if [[ "$PROFILE_PREDECESSOR_STATE_PATH" != none ]]; then
      predecessor_directory="$(dirname "$PROFILE_PREDECESSOR_STATE_PATH")"
      predecessor_arguments=(
        --volume "${predecessor_directory}:/run/fbig/predecessor:ro"
        --env UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH=/run/fbig/predecessor/fbig-profile-production-poststate-v1.tsv
        --env UMI_FBIG_PROFILE_PREDECESSOR_STATE_CHECKSUM_PATH=/run/fbig/predecessor/fbig-profile-production-poststate-v1.tsv.sha256
      )
    fi
  else
    authorization_arguments=(
      --env UMI_FBIG_PROFILE_APPROVAL_MODE=production
      --env UMI_FBIG_APPROVAL_MANIFEST_PATH=/run/fbig/history/fbig-approval-v2.tsv
      --env UMI_FBIG_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-approval-v2.tsv.sha256
      --env UMI_FBIG_PROFILE_APPROVAL_MANIFEST_PATH=/run/fbig/profile/fbig-profile-approval-v1.tsv
      --env UMI_FBIG_PROFILE_APPROVAL_CHECKSUM_PATH=/run/fbig/profile/fbig-profile-approval-v1.tsv.sha256
    )
  fi
  TASK_STARTED=true
  set +e
  # shellcheck disable=SC2016
  compose run --rm --no-deps \
    --volume "${history_directory}:/run/fbig/history:ro" \
    --volume "${profile_directory}:/run/fbig/profile:ro" \
    --volume "${BACKUP_FINAL}:/run/fbig/backup:ro" \
    --volume "${ATTEMPT_DIRECTORY}:/run/fbig/attempt" \
    "${target_arguments[@]}" \
    "${authorization_arguments[@]}" \
    "${predecessor_arguments[@]}" \
    --env UMI_FBIG_HISTORY_EXPECTED_DATABASE="$DATABASE_NAME" \
    --env DRY_RUN="$DRY_RUN" \
    --env PLATFORMS="$PLATFORMS" \
    --env UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_PATH=/run/fbig/backup/fbig-profile-pre-attempt-backup-v1.tsv \
    --env UMI_FBIG_PROFILE_PRE_ATTEMPT_BACKUP_CHECKSUM_PATH=/run/fbig/backup/fbig-profile-pre-attempt-backup-v1.tsv.sha256 \
    --env UMI_FBIG_PROFILE_ATTEMPT_DIR=/run/fbig/attempt \
    --env UMI_FBIG_PROFILE_AVATAR_INTENT_DIR=/run/fbig/attempt/avatar-intents \
    --env UMI_FBIG_RUNTIME_REPOSITORY_COMMIT="$APPROVED_REPOSITORY_COMMIT" \
    --env UMI_FBIG_RUNTIME_IMAGE_DIGEST="$APPROVED_IMAGE_DIGEST" \
    rails sh -c '
      actual_commit="$(tr -d "\r\n" </app/.git_sha)"
      test "$actual_commit" = "$UMI_FBIG_RUNTIME_REPOSITORY_COMMIT"
      exec bundle exec rake "$1"
    ' sh "umi:fbig:history_profiles[${INBOX_ID}]" \
    2>&1 | tee "$RUN_LOG_TEMP"
  local pipeline_status=("${PIPESTATUS[@]}")
  set -e
  TASK_STATUS="${pipeline_status[0]:-70}"
  TASK_RETURNED=true
  [[ "${#pipeline_status[@]}" == 2 && "${pipeline_status[1]}" == 0 ]] ||
    die "profile task log pipeline failed"
}

resume_writers() {
  local status sidekiq_container
  if ! compose start rails sidekiq; then
    compose stop rails sidekiq >/dev/null 2>&1 || true
    return 1
  fi
  if ! verify_running_release; then
    compose stop rails sidekiq >/dev/null 2>&1 || true
    return 1
  fi
  sidekiq_container="$(compose ps -q sidekiq)"
  if ! docker top "$sidekiq_container" -eo pid,args | grep -Eq '[s]idekiq'; then
    compose stop rails sidekiq >/dev/null 2>&1 || true
    return 1
  fi
  status=""
  for _attempt in {1..30}; do
    status="$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
      --resolve chat.umi.store:443:127.0.0.1 "https://chat.umi.store/")" || true
    [[ "$status" =~ ^[23][0-9]{2}$ ]] && break
    sleep 2
  done
  if [[ ! "$status" =~ ^[23][0-9]{2}$ ]]; then
    compose stop rails sidekiq >/dev/null 2>&1 || true
    return 1
  fi
  printf '[UMI-FBIG] stage=profile_writer_resume retry_audit_required=true\n'
}

seal_attempt_completion() {
  local attempt_manifest="${ATTEMPT_DIRECTORY}/fbig-profile-production-attempt-v1.tsv"
  local completion="${ATTEMPT_DIRECTORY}/fbig-profile-attempt-complete-v1.tsv"
  local temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-attempt-complete-v1.tsv.$$.tmp"
  [[ ! -e "$completion" ]] || die "attempt completion already exists"
  require_root_artifact "$attempt_manifest" fbig-profile-production-attempt-v1.tsv
  {
    printf 'schema_version\t1\n'
    printf 'attempt_id\t%s\n' "$ATTEMPT_ID"
    printf 'attempt_manifest_sha256\t%s\n' "$(sha256 "$attempt_manifest")"
    printf 'completed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  mv "$temporary" "$completion"
  fsync_path "$ATTEMPT_DIRECTORY"
}

seal_failure_coordinates() {
  local wrapper_status="$1"
  local coordinates="${ATTEMPT_DIRECTORY}/fbig-profile-recovery-coordinates-v1.tsv"
  local temporary="${ATTEMPT_DIRECTORY}/.fbig-profile-recovery-coordinates-v1.tsv.$$.tmp"
  local binding_sha="none"
  local backup_sha="none"
  local task_status="none"
  local safe_resume=false
  [[ ! -e "$coordinates" ]] || return
  if [[ -f "$ATTEMPT_BINDING_PATH" && -f "${ATTEMPT_BINDING_PATH}.sha256" ]]; then
    binding_sha="$(sha256 "$ATTEMPT_BINDING_PATH")"
  fi
  [[ "$BACKUP_SEALED" == true ]] && backup_sha="$BACKUP_MANIFEST_SHA256"
  [[ "$TASK_RETURNED" == true ]] && task_status="$TASK_STATUS"
  safe_pre_task_resume_allowed && safe_resume=true
  {
    printf 'schema_version\t1\n'
    printf 'wrapper_status\t%s\n' "$wrapper_status"
    printf 'task_status\t%s\n' "$task_status"
    printf 'task_started\t%s\n' "$TASK_STARTED"
    printf 'task_returned\t%s\n' "$TASK_RETURNED"
    printf 'safe_pre_task_resume\t%s\n' "$safe_resume"
    printf 'attempt_directory\t%s\n' "$ATTEMPT_DIRECTORY"
    printf 'backup_directory\t%s\n' "$BACKUP_FINAL"
    printf 'attempt_binding_sha256\t%s\n' "$binding_sha"
    printf 'pre_attempt_backup_sha256\t%s\n' "$backup_sha"
  } >"$temporary"
  chmod 0400 "$temporary"
  fsync_path "$temporary"
  mv "$temporary" "$coordinates"
  fsync_path "$ATTEMPT_DIRECTORY"
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ -n "${VERIFY_DATABASE:-}" ]]; then
    postgres dropdb -U "$DATABASE_USER" --if-exists "$VERIFY_DATABASE" >/dev/null 2>&1 || true
  fi
  local attempt_manifest="${ATTEMPT_DIRECTORY:-}/fbig-profile-production-attempt-v1.tsv"
  if [[ -n "${ATTEMPT_DIRECTORY:-}" &&
        "${ATTEMPT_SEALED:-false}" != true &&
        ! -e "$attempt_manifest" &&
        ! -e "${attempt_manifest}.sha256" ]]; then
    local attempt_status="$status"
    [[ "${TASK_RETURNED:-false}" == true ]] && attempt_status="$TASK_STATUS"
    seal_attempt_manifest "$attempt_status" || true
  fi
  if [[ -f "${ATTEMPT_BINDING_PATH:-}" ]]; then
    repair_attempt_binding_checksum
  fi
  if [[ -f "${ATTEMPT_DIRECTORY:-}/fbig-profile-pre-task-v1.tsv" ]]; then
    seal_failure_coordinates "$status" || true
    printf '[UMI-FBIG] stage=profile_attempt_failed wrapper_status=%s task_status=%s task_started=%s task_returned=%s attempt_directory=%s backup_directory=%s\n' \
      "$status" "$([[ "$TASK_RETURNED" == true ]] && printf '%s' "$TASK_STATUS" || printf none)" \
      "$TASK_STARTED" "$TASK_RETURNED" "$ATTEMPT_DIRECTORY" "$BACKUP_FINAL" >&2
  fi
  if [[ "${WRITERS_STOPPED:-false}" == true ]]; then
    if safe_pre_task_resume_allowed && resume_writers; then
      WRITERS_STOPPED=false
      printf '[UMI-FBIG] stage=profile_pre_task_failure_resumed wrapper_status=%s attempt_directory=%s\n' \
        "$status" "$ATTEMPT_DIRECTORY" >&2
    else
      compose stop rails sidekiq >/dev/null 2>&1 || true
      printf 'FB/IG profile attempt stopped with Rails and Sidekiq still down. Do not resume until evidence is reviewed.\n' >&2
    fi
  fi
  exit "$status"
}

resume_pre_task_attempt() {
  [[ "$#" == 5 ]] || usage
  INBOX_ID="$2"
  PROFILE_APPROVAL="$3"
  PROFILE_CHECKSUM="$4"
  ATTEMPT_DIRECTORY="$5"
  [[ "$EUID" == "0" ]] || die "run as root"
  [[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]] || usage
  require_canonical_path "$ATTEMPT_DIRECTORY"
  [[ "$(dirname "$ATTEMPT_DIRECTORY")" == "$ATTEMPT_ROOT" ]] ||
    die "attempt directory is outside the configured attempt root"
  ATTEMPT_ID="${ATTEMPT_DIRECTORY##*/fbig-profile-attempt-}"
  [[ "$ATTEMPT_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ &&
     "$(basename "$ATTEMPT_DIRECTORY")" == "fbig-profile-attempt-${ATTEMPT_ID}" ]] ||
    die "invalid attempt directory basename"
  local profile_basename
  profile_basename="$(basename "$PROFILE_APPROVAL")"
  [[ "$profile_basename" = fbig-profile-approval-v1.tsv ||
    "$profile_basename" = fbig-production-first-profile-approval-v1.tsv ]] ||
    die "invalid profile approval basename"
  require_root_artifact "$PROFILE_APPROVAL" "$profile_basename"
  require_root_artifact "$PROFILE_CHECKSUM" "${profile_basename}.sha256"
  verify_checksum "$PROFILE_APPROVAL" "$PROFILE_CHECKSUM"
  PROFILE_APPROVAL_SHA256="$(sha256 "$PROFILE_APPROVAL")"
  APPROVED_IMAGE_DIGEST="$(manifest_value "$PROFILE_APPROVAL" image_digest)"
  APPROVED_DATABASE_NAME="$(manifest_value "$PROFILE_APPROVAL" production_database_name)"
  APPROVED_INBOX_ID="$(manifest_value "$PROFILE_APPROVAL" inbox_id)"
  [[ "$APPROVED_IMAGE_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ &&
     "$APPROVED_DATABASE_NAME" == "$DATABASE_NAME" &&
     "$APPROVED_INBOX_ID" == "$INBOX_ID" ]] ||
    die "pre-task marker approval identity is invalid"
  validate_root_paths
  validate_pre_task_marker
  safe_pre_task_resume_allowed || die "attempt may have reached task execution"
  acquire_operation_lock
  cd "$STACK_DIR"
  verify_compose_release
  running="$(writers_running_count)"
  if [[ "$running" == "1" ]]; then
    compose stop rails sidekiq >/dev/null 2>&1 || true
  fi
  resume_writers || die "pre-task attempt is clean but writers could not be resumed"
  printf '[UMI-FBIG] stage=profile_pre_task_resume_complete attempt_directory=%s\n' "$ATTEMPT_DIRECTORY"
}

if [[ "${1:-}" == "--resume-pre-task" ]]; then
  resume_pre_task_attempt "$@"
  exit 0
fi

[[ "$#" == 7 || "$#" == 8 ]] || usage
readonly INBOX_ID="$1"
readonly DRY_RUN="$2"
readonly PLATFORMS="$3"
readonly HISTORY_MANIFEST="$4"
readonly HISTORY_CHECKSUM="$5"
readonly PROFILE_APPROVAL="$6"
readonly PROFILE_CHECKSUM="$7"
readonly PROFILE_TARGETS="${8:-}"
AUTHORIZATION_MODE=clone_authorized
HISTORY_BASENAME=fbig-approval-v2.tsv
PROFILE_BASENAME=fbig-profile-approval-v1.tsv
if [[ "$(basename "$PROFILE_APPROVAL")" = fbig-production-first-profile-approval-v1.tsv ]]; then
  AUTHORIZATION_MODE=production_first
  HISTORY_BASENAME=fbig-production-first-history-approval-v1.tsv
  PROFILE_BASENAME=fbig-production-first-profile-approval-v1.tsv
fi
readonly AUTHORIZATION_MODE HISTORY_BASENAME PROFILE_BASENAME
[[ "$EUID" == "0" ]] || die "run as root"
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$DRY_RUN" == "true" || "$DRY_RUN" == "false" ]] || usage
[[ "$PLATFORMS" == "messenger" || "$PLATFORMS" == "instagram" || "$PLATFORMS" == "messenger,instagram" ]] || usage
[[ "$DRY_RUN" == "true" || "$PLATFORMS" == "messenger,instagram" ]] ||
  die "production apply requires both approved platforms"
if [[ "$PLATFORMS" == *instagram* ]]; then
  [[ -n "$PROFILE_TARGETS" ]] || die "Instagram profile runs require the target sidecar"
else
  [[ -z "$PROFILE_TARGETS" ]] || die "Messenger-only profile runs must not receive the target sidecar"
fi
require_root_artifact "$HISTORY_MANIFEST" "$HISTORY_BASENAME"
require_root_artifact "$HISTORY_CHECKSUM" "${HISTORY_BASENAME}.sha256"
require_root_artifact "$PROFILE_APPROVAL" "$PROFILE_BASENAME"
require_root_artifact "$PROFILE_CHECKSUM" "${PROFILE_BASENAME}.sha256"
if [[ -n "$PROFILE_TARGETS" ]]; then
  require_root_artifact "$PROFILE_TARGETS" fbig-profile-targets-v1.tsv
fi
verify_checksum "$HISTORY_MANIFEST" "$HISTORY_CHECKSUM"
verify_checksum "$PROFILE_APPROVAL" "$PROFILE_CHECKSUM"
if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
  profile_directory="$(dirname "$PROFILE_APPROVAL")"
  for basename in \
    fbig-production-first-authorization-v1.tsv \
    fbig-messenger-terminal-history-result-v1.tsv \
    fbig-instagram-terminal-history-result-v1.tsv \
    fbig-coordinated-pre-profile-backup-v1.tsv \
    fbig-profile-state-v1.tsv; do
    require_root_artifact "${profile_directory}/${basename}" "$basename"
    require_root_artifact "${profile_directory}/${basename}.sha256" "${basename}.sha256"
    verify_checksum \
      "${profile_directory}/${basename}" "${profile_directory}/${basename}.sha256"
  done
fi
[[ -f "$STORAGE_HELPER" && -r "$STORAGE_HELPER" && ! -L "$STORAGE_HELPER" ]] ||
  die "storage artifact helper is missing"
[[ -d "$STACK_DIR" && -d "${DATA_DIR}/storage" ]] || die "Chatwoot stack paths are missing"
validate_root_paths

APPROVED_REPOSITORY_COMMIT="$(manifest_value "$PROFILE_APPROVAL" repository_commit)"
APPROVED_IMAGE_DIGEST="$(manifest_value "$PROFILE_APPROVAL" image_digest)"
APPROVED_DATABASE_NAME="$(manifest_value "$PROFILE_APPROVAL" production_database_name)"
ACCOUNT_ID="$(manifest_value "$PROFILE_APPROVAL" account_id)"
APPROVED_INBOX_ID="$(manifest_value "$PROFILE_APPROVAL" inbox_id)"
FACEBOOK_PAGE_ID="$(manifest_value "$PROFILE_APPROVAL" facebook_page_id)"
INSTAGRAM_BUSINESS_ID="$(manifest_value "$PROFILE_APPROVAL" instagram_business_id)"
readonly APPROVED_REPOSITORY_COMMIT APPROVED_IMAGE_DIGEST APPROVED_DATABASE_NAME
readonly ACCOUNT_ID APPROVED_INBOX_ID FACEBOOK_PAGE_ID INSTAGRAM_BUSINESS_ID
[[ "$APPROVED_REPOSITORY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid approved repository commit"
[[ "$APPROVED_IMAGE_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]] ||
  die "invalid approved image digest"
[[ "$APPROVED_DATABASE_NAME" == "$DATABASE_NAME" ]] || die "approved production database mismatch"
[[ "$ACCOUNT_ID" =~ ^[1-9][0-9]*$ &&
   "$APPROVED_INBOX_ID" == "$INBOX_ID" &&
   "$FACEBOOK_PAGE_ID" =~ ^[1-9][0-9]*$ &&
   "$INSTAGRAM_BUSINESS_ID" =~ ^[1-9][0-9]*$ ]] || die "invalid approved FB/IG identity"

acquire_operation_lock
validate_profile_predecessor_chain
readonly PROFILE_PREDECESSOR_STATE_PATH
cd "$STACK_DIR"
verify_running_release || die "Rails or Sidekiq is not running the profile-approved image digest"
verify_compose_release

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STARTED_EPOCH="$(date +%s)"
RANDOM_HEX="$(openssl rand -hex 8)"
BACKUP_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM_HEX}"
readonly BACKUP_BUILD="${BACKUP_ROOT}/.fbig-profile-pre-attempt-${BACKUP_ID}.building"
readonly BACKUP_FINAL="${BACKUP_ROOT}/fbig-profile-pre-attempt-${BACKUP_ID}"
ATTEMPT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 8)"
readonly ATTEMPT_DIRECTORY="${ATTEMPT_ROOT}/fbig-profile-attempt-${ATTEMPT_ID}"
readonly ATTEMPT_BINDING_PATH="${ATTEMPT_DIRECTORY}/fbig-profile-attempt-binding-v1.tsv"
readonly RUN_LOG_TEMP="${ATTEMPT_DIRECTORY}/.fbig-profile-production-run.log.tmp"
PROFILE_APPROVAL_SHA256="$(sha256 "$PROFILE_APPROVAL")"
readonly STARTED_AT STARTED_EPOCH RANDOM_HEX BACKUP_ID ATTEMPT_ID PROFILE_APPROVAL_SHA256
BACKUP_SEALED=false
BACKUP_MANIFEST_SHA256=""
ATTEMPT_SEALED=false
TASK_STARTED=false
TASK_RETURNED=false
TASK_STATUS=70
WRITERS_STOPPED=false
VERIFY_DATABASE=""
RUN_LOG_PATH=""
RUN_SUMMARY_SHA256="none"
install -d -m 0700 "$ATTEMPT_ROOT"
[[ ! -e "$ATTEMPT_DIRECTORY" ]] || die "attempt id already exists"
mkdir -m 0700 "$ATTEMPT_DIRECTORY"
mkdir -m 0700 "${ATTEMPT_DIRECTORY}/avatar-intents"
trap on_exit EXIT

seal_attempt_stage fbig-profile-pre-task-v1.tsv pre_task_ready
WRITERS_STOPPED=true
compose stop rails sidekiq
verify_maintenance_response /bot
verify_maintenance_response /webhooks/instagram
check_database_quiescence
verify_no_unexpected_containers
create_backup
seal_attempt_binding
elapsed="$(($(date +%s) - STARTED_EPOCH))"
(( elapsed < MAX_WRITER_OUTAGE_SECONDS )) || die "writer outage ceiling reached before the task"
require_root_artifact "$HISTORY_MANIFEST" "$HISTORY_BASENAME"
require_root_artifact "$HISTORY_CHECKSUM" "${HISTORY_BASENAME}.sha256"
require_root_artifact "$PROFILE_APPROVAL" "$PROFILE_BASENAME"
require_root_artifact "$PROFILE_CHECKSUM" "${PROFILE_BASENAME}.sha256"
verify_checksum "$HISTORY_MANIFEST" "$HISTORY_CHECKSUM"
verify_checksum "$PROFILE_APPROVAL" "$PROFILE_CHECKSUM"
if [[ -n "$PROFILE_TARGETS" ]]; then
  require_root_artifact "$PROFILE_TARGETS" fbig-profile-targets-v1.tsv
fi
verify_compose_release
verify_stopped_release
verify_no_unexpected_containers
check_database_quiescence
seal_attempt_stage fbig-profile-task-start-authorized-v1.tsv task_start_authorized
run_profile_task
seal_attempt_manifest "$TASK_STATUS"
if (( TASK_STATUS != 0 )); then
  die "profile task exited ${TASK_STATUS}; writers remain stopped pending evidence review"
fi
validate_sealed_attempt
verify_compose_release
verify_stopped_release
verify_no_unexpected_containers
check_database_quiescence
elapsed="$(($(date +%s) - STARTED_EPOCH))"
(( elapsed < MAX_WRITER_OUTAGE_SECONDS )) ||
  printf 'FB/IG profile attempt exceeded the planned retry-safe window; audit Meta subscription state immediately.\n' >&2
resume_writers
seal_attempt_completion
WRITERS_STOPPED=false
trap - EXIT
printf '[UMI-FBIG] stage=profile_attempt_complete attempt_directory=%s backup_directory=%s\n' \
  "$ATTEMPT_DIRECTORY" "$BACKUP_FINAL"
