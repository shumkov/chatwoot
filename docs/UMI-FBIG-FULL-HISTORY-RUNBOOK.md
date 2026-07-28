# UMI Facebook and Instagram full-history import runbook

This is the executable runbook for the one-time UMI migration. It imports every
Messenger and Instagram conversation and message that Meta still exposes,
creates no empty archive, and then enriches the resulting contacts without
overwriting existing names, usernames, profile fields, or avatars.

Meta can omit old message bodies, attachments, profiles, or whole threads for
a particular release and Graph response. Those omissions are reported and approved by exact aggregate
fingerprints; they are never replaced with invented messages or user data.

The accepted release is an immutable
`ghcr.io/shumkov/chatwoot@sha256:<64 lowercase hex>` digest. Candidate evidence,
a moving tag, and evidence from another database are not production approval.

### Authoritative production programs

The long shell excerpts below document the evidence contract and the incident
history that led to it. They are not operator copy/paste inputs. Build the
complete reviewed programs from the merged candidate:

```bash
ruby script/umi_fbig/build_programs.rb /opt/umi/fbig-ops/<candidate-id>
```

The builder emits root-protectable, self-contained programs plus exact
checksums and rejects any pre-existing output. It syntax-checks and ShellChecks
the exact concatenated bytes before publishing:

- `fbig-acceptance.sh`
- `fbig-acceptance-control.sh`
- `fbig-delivery-checkpoint.sh`
- `fbig-history-attempt.sh`
- `fbig-profile-attempt.sh`
- `fbig-delivery-audit.sh`
- `fbig-final-audit.sh`
- `fbig-profile-wrapper.sh` (the exact reviewed maintenance/backup wrapper
  invoked by `fbig-profile-attempt.sh`)
- `fbig-storage-artifact.py` (the exact reviewed storage manifest, archive
  verification, and durability helper used by acceptance and profile attempts)

Every invocation consumes a strict, ordered, checksummed binding manifest.
Protect the output directory as root-owned `0700` and every program, checksum,
binding, and binding checksum as root-owned `0400`, single-link regular files.
Never assemble a production program by concatenating runbook fences.

The execution order is:

1. start cutoff-to-completion read-only delivery checkpoints from the exact
   candidate image;
2. launch and finalize protected clone acceptance;
3. deploy that exact accepted digest, run the migration, and take the
   coordinated pre-history backup;
4. run two Messenger dry attempts and two Instagram dry attempts, then bind
   each byte-identical successful pair into that platform's apply bindings;
5. run Messenger apply attempts until a separate Messenger attempt proves
   zero writes, then do the same for Instagram; every Instagram attempt seals
   exact accepted-envelope inspections immediately before and after the
   importer, while Messenger requires zero structural omissions;
6. run profile dry/apply attempts, with a new overlapping checkpoint and
   sealed delivery audit after every maintenance window, until a profile
   attempt proves zero writes; and
7. run `fbig-final-audit.sh`, which validates the complete result/checkpoint
   chains and seals concrete per-platform totals, unavailable-message
   fingerprints, and thread-conservation counters from one repeatable-read
   live database snapshot.

An interrupted history or profile host process is finalized through its
program's `finalize` action before a successor can start. The current R4 clone
invocation predates this protected launch contract and is rehearsal evidence
only; it cannot authorize production.

Before clone acceptance starts, `fbig-acceptance-control.sh` runs a disposable
same-host systemd probe. It proves that `RefuseManualStop=yes` rejects an
explicit `systemctl restart` without changing the disposable invocation, then
removes the probe completely. The accepted unit fragment carries the same
property, and its effective value is bound into the pre/post descriptors and
start intent. This protects the multi-hour clone process from compliant direct
service restarts such as Ubuntu `needrestart`; it does not prevent dependency
failure, process failure, forceful kill, OOM termination, reboot, or shutdown.

If an emergency operator abort is required, terminate the acceptance process
explicitly rather than weakening or editing the protected fragment:

```bash
systemctl kill --kill-whom=all --signal=TERM "$ACCEPTANCE_UNIT"
```

That invocation can never authorize production. Preserve its audit directory,
clone database, and clone storage as unsealed forensic evidence; investigate,
then generate a new acceptance id with fresh audit and clone roots.

## 1. Stop conditions

Stop immediately if any of these is true:

- Rails or Sidekiq does not use the expected digest.
- The compose image for a one-off does not resolve to that same digest.
- the connected database name is not the explicitly expected database;
- the clone database or storage mount is not isolated from production;
- a root-owned artifact is not in a `0700` non-link directory with immutable
  `0400`, single-link files;
- either approved dry run differs from the acceptance probe;
- an apply binding does not carry two distinct, successful, byte-identical
  dry-result artifacts for its selected platform;
- a history run reports a new contentless count/fingerprint;
- a history run reports a different unavailable-message thread
  count/fingerprint or violates thread conservation;
- the exact unrecoverable-envelope count/fingerprint differs before or after
  any Instagram-inclusive history stage;
- a history apply does not use `PROFILE_MODE=defer` from the approval;
- any profile run reports an authentication, identity, contract, pagination,
  lock, wait-budget, storage, association, or unclassified failure;
- profile pre/post comparison or avatar-staging reconciliation fails; or
- a profile wrapper exits nonzero. It intentionally leaves Rails and Sidekiq
  stopped for evidence review and coordinated restore.

Never edit an approval in place, selectively delete imported rows, restore only
PostgreSQL after avatar writes, or resume writers around failed profile
evidence.

## 2. Required values and artifacts

Use a VPS root shell with `set -Eeuo pipefail` and `umask 077`. Keep every log
under a new durable root-owned `0700` audit directory.

```bash
set -Eeuo pipefail
umask 077

INBOX_ID='<numeric inbox id>'
PRODUCTION_DATABASE='chatwoot_production'
CLONE_DATABASE='<fresh clone database name>'
APP_COMMIT='<40 lowercase hex merged commit>'
APP_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<64 lowercase hex>'
APPROVED_BY='<operator identity without tabs or newlines>'
STACK_DIR='/opt/umi/chatwoot'
AUDIT_DIR='/opt/umi/fbig-audit/<new acceptance id>'
CLONE_STORAGE='/opt/umi/fbig-clones/<new acceptance id>/storage'
HISTORY_DIR="$AUDIT_DIR/history-approval"
PROFILE_DIR="$AUDIT_DIR/profile-approval"
TARGET_DIR="$AUDIT_DIR/profile-targets"
CLONE_ROOT="$(dirname "$CLONE_STORAGE")"
EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS='1'
EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS='2'

test "$(id -u)" -eq 0
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$CLONE_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
test "$CLONE_DATABASE" != "$PRODUCTION_DATABASE"
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
test -n "$APPROVED_BY"
[[ "$APPROVED_BY" != *$'\t'* && "$APPROVED_BY" != *$'\n'* && "$APPROVED_BY" != *$'\r'* ]]
test "$(printf '%s' "$APPROVED_BY" | wc -c)" -le 255
test "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS" = 1
test "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS" = 2
test ! -e "$AUDIT_DIR"
test ! -L "$AUDIT_DIR"
mkdir -p "$AUDIT_DIR"
chmod 0700 "$AUDIT_DIR"
mkdir -m 0700 "$HISTORY_DIR" "$PROFILE_DIR" "$TARGET_DIR"

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

manifest_value() {
  local path="$1"
  local key="$2"
  awk -F $'\t' -v expected="$key" '
    $1 == expected { count += 1; value = $2 }
    END { if (count != 1) exit 1; print value }
  ' "$path"
}

stage_value() {
  local path="$1"
  local stage="$2"
  local key="$3"
  awk -v expected_stage="$stage" -v expected_key="$key" '
    $1 == "[UMI-FBIG]" {
      selected = 0
      for (field = 2; field <= NF; field += 1) {
        if ($field == "stage=" expected_stage) selected = 1
      }
      if (selected) {
        rows += 1
        for (field = 2; field <= NF; field += 1) {
          split($field, pair, "=")
          if (pair[1] == expected_key) {
            values += 1
            value = substr($field, length(expected_key) + 2)
          }
        }
      }
    }
    END {
      if (rows != 1 || values != 1 || value == "") exit 1
      print value
    }
  ' "$path"
}

verify_seed_target_conservation() {
  local log="$1"
  local summary="$2"
  local platforms
  local expected
  local seed_targets
  local seed_targets_complete
  local seed_targets_success
  local seed_targets_unavailable
  local seed_targets_blocking
  local seed_targets_repaired
  local seed_targets_preserved
  local seed_targets_blank_name
  local seed_targets_blocked
  local value

  platforms="$(stage_value "$log" history_profiles_start platforms)"
  expected="$(stage_value "$log" history_profiles_start seed_targets_expected)"
  [[ "$expected" =~ ^[0-9]+$ ]]
  if [[ ",$platforms," = *,instagram,* ]]; then
    test "$expected" -gt 0
  else
    test "$platforms" = messenger
    test "$expected" = 0
  fi

  seed_targets="$(stage_value "$summary" history_profiles_summary seed_targets)"
  seed_targets_complete="$(
    stage_value "$summary" history_profiles_summary seed_targets_complete
  )"
  seed_targets_success="$(
    stage_value "$summary" history_profiles_summary seed_targets_success
  )"
  seed_targets_unavailable="$(
    stage_value "$summary" history_profiles_summary seed_targets_unavailable
  )"
  seed_targets_blocking="$(
    stage_value "$summary" history_profiles_summary seed_targets_blocking
  )"
  seed_targets_repaired="$(
    stage_value "$summary" history_profiles_summary seed_targets_repaired
  )"
  seed_targets_preserved="$(
    stage_value "$summary" history_profiles_summary seed_targets_preserved
  )"
  seed_targets_blank_name="$(
    stage_value "$summary" history_profiles_summary seed_targets_blank_name
  )"
  seed_targets_blocked="$(
    stage_value "$summary" history_profiles_summary seed_targets_blocked
  )"
  for value in \
    "$seed_targets" "$seed_targets_complete" "$seed_targets_success" \
    "$seed_targets_unavailable" "$seed_targets_blocking" \
    "$seed_targets_repaired" "$seed_targets_preserved" \
    "$seed_targets_blank_name" "$seed_targets_blocked"; do
    [[ "$value" =~ ^[0-9]+$ ]]
  done

  test "$seed_targets" = "$expected"
  test "$seed_targets_complete" = "$expected"
  test "$expected" -eq \
    "$((seed_targets_success + seed_targets_unavailable + seed_targets_blocking))"
  test "$expected" -eq \
    "$((seed_targets_repaired + seed_targets_preserved + seed_targets_blank_name + seed_targets_unavailable + seed_targets_blocked))"
  test "$seed_targets_blocking" = "$seed_targets_blocked"
}

```

The immutable input artifacts are:

- `fbig-profile-targets-v1.tsv`: one to 10,000 sorted
  `contact_inbox_id<TAB>contact_id<TAB>source_id` rows;
- `fbig-approval-v2.tsv` plus `.sha256`: the exact 29-field
  `HistoryApprovalManifest::FIELD_NAMES` order;
- `fbig-unrecoverable-envelope-v1.tsv` plus `.sha256`: the strict
  release/scope/cutoff-bound pseudonymous exception evidence chained through
  the accepted probe log;
- `fbig-profile-state-v1.tsv` plus `.sha256`: captured by the no-Meta state
  task after clone history reaches zero writes; and
- `fbig-profile-approval-v1.tsv` plus `.sha256`: the exact 31-field
  `ProfileApprovalManifest::FIELD_NAMES` order.

Create each approval in a new directory, seal the file and checksum to `0400`,
then validate it by loading it through the merged image. The history approval
must bind:

- the merged commit and digest;
- the coordinated clone backup, database dump, and source/restored storage
  manifests;
- the exact account/inbox/Page/Instagram identity;
- `since=all`, the frozen cutoff, `outbound_policy=pre_presence`, and
  `profile_mode=defer`;
- both exact contentless count/fingerprints;
- both exact unavailable-message thread count/fingerprints;
- the strict unrecoverable-envelope sidecar checksum through the source probe
  log hash;
- the snapshot-bound target SHA; and
- the acceptance probe log and summary hashes.

The initial profile approval must bind that history approval, the same merged
commit/digest, distinct clone and production database names, both platforms,
the reviewed Graph delay/page/wait/avatar budgets, both stable-target
count/fingerprints, the clone source-state SHA, all clone profile
dry/apply/idempotency log and summary hashes, and `none` for both predecessor
fields.

## 3. Pin the current app and atomically install the operator tools

Before any deployment, resolve the current production Rails RepoDigest
read-only on the VPS:

```bash
cd "$STACK_DIR"
CURRENT_DIGEST="$(
  docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "$(docker inspect --format '{{.Image}}' "$(docker compose ps -q rails)")" |
    grep '^ghcr\.io/shumkov/chatwoot@sha256:' |
    head -1
)"
[[ "$CURRENT_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
printf 'current production digest: %s\n' "$CURRENT_DIGEST"
```

Copy that exact value into the local control-node shell. Pin it in the tracked
infra inventory, review the one-line change, commit, and push it before
deployment:

```bash
set -Eeuo pipefail
umask 077

INFRA_DIR='<local umi-vps-infra checkout>'
INVENTORY_FILE='ansible/group_vars/all/main.yml'
CURRENT_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<exact current 64-hex digest>'
CURRENT_VERSION="umi-latest@${CURRENT_DIGEST#*@}"

[[ "$CURRENT_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
[[ "$CURRENT_VERSION" =~ ^umi-latest@sha256:[0-9a-f]{64}$ ]]
cd "$INFRA_DIR"
test -z "$(git status --porcelain)"
ansible localhost --connection=local --inventory localhost, \
  --module-name ansible.builtin.lineinfile \
  --args "path='$INVENTORY_FILE' regexp='^chatwoot_version:' line='chatwoot_version: \"$CURRENT_VERSION\"'"
test "$(grep -Fxc "chatwoot_version: \"$CURRENT_VERSION\"" "$INVENTORY_FILE")" -eq 1
git diff --check
git diff -- "$INVENTORY_FILE"
git add "$INVENTORY_FILE"
git commit -m "ops(chatwoot): pin current image digest"
git push
test -z "$(git status --porcelain)"
git show "HEAD:$INVENTORY_FILE" |
  grep -Fx "chatwoot_version: \"$CURRENT_VERSION\""

cd ansible
ansible-playbook site.yml --tags chatwoot
```

This single locked deployment installs the reviewed backup/profile operator
tools while keeping the application bytes identical. There is no pre-pin
operator-tool deployment. Back on the VPS, re-establish `CURRENT_DIGEST`,
verify the configured image, Rails, and Sidekiq all resolve to it, and require
the coordinated-backup wrapper to be installed before taking the backup:

```bash
set -Eeuo pipefail
umask 077

cd "$STACK_DIR"
CURRENT_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<same exact current 64-hex digest>'
[[ "$CURRENT_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
test -x "$STACK_DIR/bin/fbig_coordinated_backup.sh"

RAILS_CONTAINER="$(docker compose ps -q rails)"
test -n "$RAILS_CONTAINER"
PRODUCTION_COMPOSE_PROJECT="$(
  docker inspect \
    --format '{{index .Config.Labels "com.docker.compose.project"}}' \
    "$RAILS_CONTAINER"
)"
test -n "$PRODUCTION_COMPOSE_PROJECT"
mapfile -t STALE_CLONE_REDIS_IDS < <(
  docker ps --all --quiet \
    --filter "label=com.docker.compose.project=$PRODUCTION_COMPOSE_PROJECT" \
    --filter label=com.docker.compose.service=clone-redis
)
test "${#STALE_CLONE_REDIS_IDS[@]}" -eq 1
for container_id in "${STALE_CLONE_REDIS_IDS[@]}"; do
  test "$(
    docker inspect \
      --format '{{index .Config.Labels "com.docker.compose.project"}}:{{index .Config.Labels "com.docker.compose.service"}}' \
      "$container_id"
  )" = "$PRODUCTION_COMPOSE_PROJECT:clone-redis"
  test "$(docker inspect --format '{{.Config.Image}}' "$container_id")" = "redis:7-alpine"
  test "$(docker inspect --format '{{len .Mounts}}' "$container_id")" -eq 1
  STALE_CLONE_REDIS_MOUNT="$(
    docker inspect \
      --format '{{range .Mounts}}{{.Type}}:{{.Source}}:{{.Destination}}{{end}}' \
      "$container_id"
  )"
  [[ "$STALE_CLONE_REDIS_MOUNT" =~ ^volume:/var/lib/docker/volumes/[^:]+/_data:/data$ ]]
  [[ "$STALE_CLONE_REDIS_MOUNT" != *"/opt/umi"* ]]
  docker stop --time 30 "$container_id"
  docker rm "$container_id"
  test -z "$(docker ps --all --quiet --filter "id=$container_id")"
done
test -z "$(
  docker ps --all --quiet \
    --filter "label=com.docker.compose.project=$PRODUCTION_COMPOSE_PROJECT" \
    --filter label=com.docker.compose.service=clone-redis
)"

"$STACK_DIR/bin/fbig_coordinated_backup.sh" "$INBOX_ID" "$CURRENT_DIGEST" |
  tee "$AUDIT_DIR/predeploy-backup.log"
```

The wrapper stops both writers, verifies retryable maintenance responses for
Facebook and Instagram webhook paths, proves zero other database clients,
creates and semantically restores a custom-format database dump, creates and
round-trips a canonical link-free storage archive, seals the backup, and only
then resumes the writers.

## 4. Fresh clone from the coordinated backup

Use the sealed directory printed by the wrapper:

```bash
BACKUP_DIR='<printed fbig-coordinated-backup directory>'
test -f "$BACKUP_DIR/fbig-coordinated-backup-v1.tsv"
(
  cd "$BACKUP_DIR"
  sha256sum --check fbig-coordinated-backup-v1.tsv.sha256
)

cd "$STACK_DIR"
docker compose exec -T postgres \
  createdb -U chatwoot --template=template0 "$CLONE_DATABASE"
docker compose exec -T postgres \
  pg_restore -U chatwoot -d "$CLONE_DATABASE" --no-owner --no-privileges \
  <"$BACKUP_DIR/database.dump"
test ! -e "$CLONE_ROOT"
test ! -L "$CLONE_ROOT"
mkdir -p "$CLONE_ROOT"
chmod 0700 "$CLONE_ROOT"
mkdir -m 0700 "$CLONE_STORAGE"
"$STACK_DIR/bin/fbig_storage_artifact.py" verify-archive \
  "$BACKUP_DIR/storage.tar" "$BACKUP_DIR/storage.manifest" "$CLONE_STORAGE"
```

Build the clone-only override with noclobber. `POSTGRES_DATABASE` selects the
fresh clone without copying a database password into another URL. Export every
value that Compose interpolates, use the production Compose project only so the
one-off can reach its PostgreSQL service, and never run `down` against this
combined project:

```bash
export APP_DIGEST CLONE_DATABASE CLONE_STORAGE
CLONE_OVERRIDE="$CLONE_ROOT/docker-compose.clone.yml"
test ! -e "$CLONE_OVERRIDE"
(
  set -o noclobber
  umask 077
  cat >"$CLONE_OVERRIDE" <<'YAML'
services:
  clone-redis:
    image: redis:7-alpine
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    restart: "no"
  rails:
    image: ${APP_DIGEST:?exact digest required}
    environment:
      POSTGRES_DATABASE: ${CLONE_DATABASE:?clone database required}
      ACTIVE_STORAGE_SERVICE: local
      REDIS_URL: redis://clone-redis:6379/0
      REDIS_PASSWORD: ""
      REDIS_SENTINELS: ""
      REDIS_SENTINEL_PASSWORD: ""
      REDIS_SENTINEL_MASTER_NAME: ""
    volumes:
      - "${CLONE_STORAGE:?isolated storage required}:/app/storage"
YAML
)
chmod 0600 "$CLONE_OVERRIDE"

clone_compose() {
  docker compose \
    --project-directory "$STACK_DIR" \
    --file "$STACK_DIR/docker-compose.yml" \
    --file "$CLONE_OVERRIDE" \
    "$@"
}

test "$(clone_compose config --images | grep -Fxc "$APP_DIGEST")" -eq 1
test -z "$(clone_compose ps --all -q clone-redis)"

CLONE_REDIS_ACTIVE=false
cleanup_clone_redis() {
  local status="$?"
  trap - EXIT
  set +e
  if [[ "${CLONE_REDIS_ACTIVE:-false}" == true ]]; then
    clone_compose stop --timeout 30 clone-redis >/dev/null 2>&1
    clone_compose rm --force --stop clone-redis >/dev/null 2>&1
  fi
  exit "$status"
}

clone_compose up --detach --no-deps clone-redis
CLONE_REDIS_ACTIVE=true
trap cleanup_clone_redis EXIT
CLONE_REDIS_CONTAINER="$(clone_compose ps -q clone-redis)"
test -n "$CLONE_REDIS_CONTAINER"
test "$(docker inspect --format '{{.State.Status}}' "$CLONE_REDIS_CONTAINER")" = running
```

Prove the database, Redis, storage mount, and private-network fetch policy from
inside the accepted merged image. The random sentinel must be visible through
`/app/storage` and absent from production storage; remove it before generating
the restored-storage manifest:

```bash
PRODUCTION_STORAGE='/opt/umi/data/storage'
test "$(realpath -e "$CLONE_STORAGE")" != "$(realpath -e "$PRODUCTION_STORAGE")"
CLONE_SENTINEL_BASENAME=".fbig-clone-storage-$(openssl rand -hex 8)"
CLONE_SENTINEL_VALUE="$(openssl rand -hex 32)"
printf '%s' "$CLONE_SENTINEL_VALUE" >"$CLONE_STORAGE/$CLONE_SENTINEL_BASENAME"
chmod 0600 "$CLONE_STORAGE/$CLONE_SENTINEL_BASENAME"
test ! -e "$PRODUCTION_STORAGE/$CLONE_SENTINEL_BASENAME"

clone_compose run --rm --no-deps -T \
  -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
  -e UMI_FBIG_CLONE_STORAGE_SENTINEL="$CLONE_SENTINEL_BASENAME" \
  -e UMI_FBIG_CLONE_STORAGE_SENTINEL_VALUE="$CLONE_SENTINEL_VALUE" \
  rails bundle exec rails runner '
    expected_database = ENV.fetch("UMI_FBIG_HISTORY_EXPECTED_DATABASE")
    actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
    abort("clone database mismatch") unless actual_database == expected_database
    abort("clone Redis mismatch") unless Redis.new(url: ENV.fetch("REDIS_URL")).ping == "PONG"
    sentinel = File.join("/app/storage", ENV.fetch("UMI_FBIG_CLONE_STORAGE_SENTINEL"))
    abort("clone storage mount mismatch") unless
      File.binread(sentinel) == ENV.fetch("UMI_FBIG_CLONE_STORAGE_SENTINEL_VALUE")
    abort("private-network fetching is enabled") if SafeFetch.allow_private_network?
    puts "[UMI-FBIG] stage=clone_isolation_verified database=#{actual_database}"
  ' || {
    status=$?
    rm -f "$CLONE_STORAGE/$CLONE_SENTINEL_BASENAME"
    exit "$status"
  }
rm -f "$CLONE_STORAGE/$CLONE_SENTINEL_BASENAME"
test ! -e "$CLONE_STORAGE/$CLONE_SENTINEL_BASENAME"

RESTORED_STORAGE_MANIFEST="$AUDIT_DIR/clone-restored-storage.manifest"
"$STACK_DIR/bin/fbig_storage_artifact.py" manifest \
  "$CLONE_STORAGE" "$RESTORED_STORAGE_MANIFEST"
cmp -s "$BACKUP_DIR/storage.manifest" "$RESTORED_STORAGE_MANIFEST"
chmod 0400 "$RESTORED_STORAGE_MANIFEST"
test "$(stat -c '%u:%a:%h' "$RESTORED_STORAGE_MANIFEST")" = "0:400:1"
```

Run the migration on the clone and require zero duplicate Contact avatars:

```bash
clone_compose run --rm --no-deps -T rails bundle exec rails db:migrate
clone_compose run --rm --no-deps -T rails bundle exec rails runner '
  duplicates = ActiveStorage::Attachment
    .where(record_type: "Contact", name: "avatar")
    .group(:record_id).having("COUNT(*) > 1").count
  abort("duplicate Contact avatars") if duplicates.any?
  abort("missing unique avatar index") unless
    ActiveRecord::Base.connection.indexes(:active_storage_attachments)
      .any? { |index| index.name == "index_active_storage_contact_avatar_uniqueness" }
'
```

Create the strict bounded Instagram placeholder target file from the restored
clone before history can add contacts. The query uses noclobber, selects every
exact generated placeholder with canonical Instagram-only conversation
evidence, fails on ambiguous cross-platform evidence, and derives the positive
row count from the strict parser:

```bash
clone_compose run --rm --no-deps -T \
  --volume "$TARGET_DIR:/run/fbig/targets" \
  -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
  -e UMI_FBIG_PROFILE_TARGET_OUTPUT=/run/fbig/targets/fbig-profile-targets-v1.tsv \
  -e UMI_FBIG_TARGET_INBOX_ID="$INBOX_ID" \
  rails bundle exec rails runner '
    expected_database = ENV.fetch("UMI_FBIG_HISTORY_EXPECTED_DATABASE")
    actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
    abort("clone database mismatch") unless actual_database == expected_database
    inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_TARGET_INBOX_ID"), 10))
    candidate_ids = inbox.contact_inboxes.includes(:contact).select do |contact_inbox|
      source_id = contact_inbox.source_id.to_s
      source_id.match?(/\A[1-9][0-9]*\z/) &&
        contact_inbox.contact&.name == "Instagram user #{source_id.last(4)}"
    end.map(&:id)
    candidates = inbox.contact_inboxes
                      .includes(:contact, :conversations)
                      .where(id: candidate_ids)
                      .to_a
    classified = candidates.group_by do |contact_inbox|
      Umi::Fbig::ContactInboxPlatformEvidence.classify(contact_inbox)
    end
    abort("ambiguous Instagram placeholder target") if classified[:ambiguous].present?
    rows = classified.fetch(:instagram, []).sort_by(&:id)
    abort("no Instagram placeholder targets") if rows.empty?
    bytes = rows.map do |contact_inbox|
      [contact_inbox.id, contact_inbox.contact_id, contact_inbox.source_id].join("\t")
    end.join("\n") + "\n"
    path = ENV.fetch("UMI_FBIG_PROFILE_TARGET_OUTPUT")
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o400) { |file| file.write(bytes) }
    Umi::Fbig::ProfileTargetManifest.parse(File.binread(path))
    puts "[UMI-FBIG] stage=profile_targets_sealed target_count=#{rows.size}"
  '
test "$(stat -c '%u:%a:%h' "$TARGET_DIR/fbig-profile-targets-v1.tsv")" = "0:400:1"
```

The profile service reruns the same canonical platform classifier immediately
before each Meta profile lookup and again under every scalar/avatar write lock.
Final audit independently validates each indexed result's checksummed attempt
manifest and binds the exact run-log and summary hashes before checking seed
conservation.

Capture the exact original importer baseline before any history scan can write.
The program emits only internal IDs, counts, file sizes, and SHA-256 hashes. It
pins the 22 original archive IDs, 48 message IDs, 6 Attachment/Active
Storage/blob associations and files, plus every pre-existing non-archive
conversation's stable identity/linkage fields. It also pins the complete
non-importer conversation and message ID sets so an accidental unmarked row
cannot hide outside the importer baseline:

```bash
SCOPED_SNAPSHOT_SCRIPT="$AUDIT_DIR/fbig-scoped-baseline.rb"
test ! -e "$SCOPED_SNAPSHOT_SCRIPT"
(
  set -o noclobber
  cat >"$SCOPED_SNAPSHOT_SCRIPT" <<'RUBY'
require 'digest'
require 'json'

mode = ENV.fetch('FBIG_BASELINE_MODE')
abort('invalid baseline mode') unless %w[capture clone_verify production_verify].include?(mode)
inbox_id = Integer(ENV.fetch('FBIG_INBOX_ID'), 10)
actual_database = ActiveRecord::Base.connection.select_value('SELECT current_database()')
abort("wrong snapshot database: #{actual_database}") unless
  actual_database == ENV.fetch('FBIG_EXPECTED_DATABASE')

parse_ids = lambda do |name|
  value = ENV.fetch(name)
  ids = value.split(',').reject(&:empty?).map { |item| Integer(item, 10) }
  abort("#{name} is not sorted and unique") unless ids == ids.sort.uniq
  ids
end

current_archive_ids = Conversation.where(inbox_id: inbox_id)
                                  .where("additional_attributes ? 'umi_history_import'")
                                  .reorder(:id).pluck(:id)
archive_ids = mode == 'capture' ? current_archive_ids : parse_ids.call('FBIG_ARCHIVE_IDS')
message_ids =
  if mode == 'capture'
    Message.where(conversation_id: archive_ids).reorder(:id).pluck(:id)
  else
    parse_ids.call('FBIG_MESSAGE_IDS')
  end
attachment_ids =
  if mode == 'capture'
    Attachment.where(message_id: message_ids).reorder(:id).pluck(:id)
  else
    parse_ids.call('FBIG_ATTACHMENT_IDS')
  end
current_live_conversation_ids = Conversation.where(inbox_id: inbox_id)
                                            .where.not(id: current_archive_ids)
                                            .reorder(:id).pluck(:id)
live_conversation_ids =
  mode == 'capture' ? current_live_conversation_ids : parse_ids.call('FBIG_LIVE_CONVERSATION_IDS')
current_importer_message_ids = Message.where(inbox_id: inbox_id)
                                      .where(
                                        "additional_attributes ->> :key = :value",
                                        key: "umi_history_import",
                                        value: "true"
                                      ).reorder(:id).pluck(:id)
current_nonimporter_message_ids = Message.where(inbox_id: inbox_id)
                                         .where.not(id: current_importer_message_ids)
                                         .reorder(:id).pluck(:id)
nonimporter_message_ids =
  mode == 'capture' ? current_nonimporter_message_ids : parse_ids.call('FBIG_NONIMPORTER_MESSAGE_IDS')

abort("expected 22 original archives, got #{archive_ids.length}") unless archive_ids.length == 22
abort("expected 48 original messages, got #{message_ids.length}") unless message_ids.length == 48
abort("expected 6 original attachments, got #{attachment_ids.length}") unless attachment_ids.length == 6
if mode == 'clone_verify'
  abort('non-importer conversation ID set changed') unless
    current_live_conversation_ids == live_conversation_ids
  abort('non-importer message ID set changed') unless
    current_nonimporter_message_ids == nonimporter_message_ids
end

puts "FBIG_IDS|archives|#{archive_ids.join(',')}"
puts "FBIG_IDS|messages|#{message_ids.join(',')}"
puts "FBIG_IDS|attachments|#{attachment_ids.join(',')}"
puts "FBIG_IDS|live_conversations|#{live_conversation_ids.join(',')}"
puts "FBIG_IDS|nonimporter_messages|#{nonimporter_message_ids.join(',')}"

canonical = lambda do |value|
  case value
  when Hash
    value.keys.sort.to_h { |key| [key, canonical.call(value[key])] }
  when Array
    value.map { |item| canonical.call(item) }
  else
    value
  end
end
digest = ->(value) { Digest::SHA256.hexdigest(JSON.generate(canonical.call(value))) }
emit_records = lambda do |type, model, ids, transform|
  records = model.where(id: ids).index_by(&:id)
  abort("#{type} ID set changed") unless records.keys.sort == ids
  ids.each do |id|
    puts "FBIG_HASH|#{type}|#{id}|#{digest.call(transform.call(records.fetch(id)))}"
  end
end

emit_records.call('archive', Conversation, archive_ids, lambda do |record|
  attributes = record.attributes.deep_dup
  %w[created_at updated_at last_activity_at agent_last_seen_at].each { |key| attributes.delete(key) }
  marker = attributes.dig('additional_attributes', 'umi_history_import')
  marker.delete('configuration') if marker.is_a?(Hash)
  attributes
end)
emit_records.call('message', Message, message_ids, ->(record) { record.attributes })
emit_records.call('attachment', Attachment, attachment_ids, ->(record) { record.attributes })

storage_attachments = ActiveStorage::Attachment
  .where(record_type: 'Attachment', record_id: attachment_ids, name: 'file')
  .order(:id)
abort("expected 6 original Active Storage joins, got #{storage_attachments.length}") unless
  storage_attachments.length == 6
storage_attachments.each do |record|
  puts "FBIG_HASH|storage_attachment|#{record.id}|#{digest.call(record.attributes)}"
end

blob_ids = storage_attachments.map(&:blob_id).sort.uniq
blobs = ActiveStorage::Blob.where(id: blob_ids).index_by(&:id)
abort('original blob ID set changed') unless blobs.keys.sort == blob_ids
service = ActiveStorage::Blob.service
abort('baseline requires local disk storage') unless service.respond_to?(:path_for, true)
blob_ids.each do |id|
  blob = blobs.fetch(id)
  puts "FBIG_HASH|blob|#{id}|#{digest.call(blob.attributes)}"
  path = service.send(:path_for, blob.key)
  abort("original blob file missing for blob #{id}") unless File.file?(path)
  puts "FBIG_STORAGE|blob|#{id}|#{File.size(path)}|#{Digest::SHA256.file(path).hexdigest}"
end

live_identity_fields = %w[
  id account_id inbox_id contact_id contact_inbox_id display_id uuid identifier created_at
]
emit_records.call(
  'live_conversation_identity',
  Conversation,
  live_conversation_ids,
  ->(record) { record.attributes.slice(*live_identity_fields) }
)
puts [
  'FBIG_COUNTS',
  'archives', archive_ids.length,
  'messages', message_ids.length,
  'attachments', attachment_ids.length,
  'live_conversations', live_conversation_ids.length,
  'nonimporter_messages', nonimporter_message_ids.length
].join('|')
RUBY
)
chmod 0400 "$SCOPED_SNAPSHOT_SCRIPT"
test "$(stat -c '%u:%a:%h' "$SCOPED_SNAPSHOT_SCRIPT")" = "0:400:1"

baseline_ids() {
  local baseline_file="$1"
  local kind="$2"
  awk -F '|' -v expected="$kind" '
    $1 == "FBIG_IDS" && $2 == expected { count += 1; value = $3 }
    END { if (count != 1) exit 1; print value }
  ' "$baseline_file"
}

load_scoped_baseline_ids() {
  local baseline_file="$1"
  FBIG_ARCHIVE_IDS="$(baseline_ids "$baseline_file" archives)"
  FBIG_MESSAGE_IDS="$(baseline_ids "$baseline_file" messages)"
  FBIG_ATTACHMENT_IDS="$(baseline_ids "$baseline_file" attachments)"
  FBIG_LIVE_CONVERSATION_IDS="$(baseline_ids "$baseline_file" live_conversations)"
  FBIG_NONIMPORTER_MESSAGE_IDS="$(baseline_ids "$baseline_file" nonimporter_messages)"
  test -n "$FBIG_ARCHIVE_IDS"
  test -n "$FBIG_MESSAGE_IDS"
  test -n "$FBIG_ATTACHMENT_IDS"
  export FBIG_ARCHIVE_IDS FBIG_MESSAGE_IDS FBIG_ATTACHMENT_IDS
  export FBIG_LIVE_CONVERSATION_IDS FBIG_NONIMPORTER_MESSAGE_IDS
}

clone_scoped_snapshot() {
  local snapshot_mode="$1"
  clone_compose run --rm --no-deps -T \
    -e FBIG_BASELINE_MODE="$snapshot_mode" \
    -e FBIG_INBOX_ID="$INBOX_ID" \
    -e FBIG_EXPECTED_DATABASE="$CLONE_DATABASE" \
    -e FBIG_ARCHIVE_IDS="${FBIG_ARCHIVE_IDS:-}" \
    -e FBIG_MESSAGE_IDS="${FBIG_MESSAGE_IDS:-}" \
    -e FBIG_ATTACHMENT_IDS="${FBIG_ATTACHMENT_IDS:-}" \
    -e FBIG_LIVE_CONVERSATION_IDS="${FBIG_LIVE_CONVERSATION_IDS:-}" \
    -e FBIG_NONIMPORTER_MESSAGE_IDS="${FBIG_NONIMPORTER_MESSAGE_IDS:-}" \
    rails bundle exec rails runner - <"$SCOPED_SNAPSHOT_SCRIPT" |
    grep '^FBIG_'
}

CLONE_BASELINE="$AUDIT_DIR/clone-scoped-baseline.txt"
test ! -e "$CLONE_BASELINE"
clone_scoped_snapshot capture >"$CLONE_BASELINE"
test "$(
  grep -Ec '^FBIG_COUNTS\|archives\|22\|messages\|48\|attachments\|6\|live_conversations\|[0-9]+\|nonimporter_messages\|[0-9]+$' \
    "$CLONE_BASELINE"
)" -eq 1
load_scoped_baseline_ids "$CLONE_BASELINE"
chmod 0400 "$CLONE_BASELINE"
test "$(stat -c '%u:%a:%h' "$CLONE_BASELINE")" = "0:400:1"
```

Use one fail-closed function after every history apply or recovery. It compares
the fixed original ID-bound baseline and the complete writer-free clone
non-importer conversation/message ID sets, then runs the exact structural
invariants: no duplicate imported message source, no empty archive, only inert
resolved archives, no duplicate inbox source mapping, and no duplicate Contact
avatar:

```bash
verify_clone_history_state() {
  local label="$1"
  local observed="$AUDIT_DIR/clone-scoped-$label.txt"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  test ! -e "$observed"
  clone_scoped_snapshot clone_verify >"$observed"
  cmp -s "$CLONE_BASELINE" "$observed"
  chmod 0400 "$observed"

  clone_compose run --rm --no-deps -T \
    -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
    -e UMI_FBIG_AUDIT_LABEL="$label" \
    -e UMI_FBIG_AUDIT_INBOX_ID="$INBOX_ID" \
    rails bundle exec rails runner '
      expected_database = ENV.fetch("UMI_FBIG_HISTORY_EXPECTED_DATABASE")
      actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
      abort("clone database mismatch") unless actual_database == expected_database
      inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_AUDIT_INBOX_ID"), 10))
      archives = inbox.conversations.where(
        "jsonb_exists(conversations.additional_attributes, :key)",
        key: "umi_history_import"
      )
      duplicate_message_sources = Message
        .where(inbox_id: inbox.id)
        .where(
          "additional_attributes ->> :key = :value",
          key: "umi_history_import",
          value: "true"
        )
        .reorder(nil)
        .group(:source_id).having("COUNT(*) > 1").count
      empty_archives = archives.left_joins(:messages)
                               .group("conversations.id")
                               .having("COUNT(messages.id) = 0").count
      resolved = Conversation.statuses.fetch("resolved")
      invalid_archives = archives.where(
        "status <> :resolved OR assignee_id IS NOT NULL OR team_id IS NOT NULL " \
        "OR waiting_since IS NOT NULL OR first_reply_created_at IS NOT NULL",
        resolved: resolved
      )
      duplicate_sources = inbox.contact_inboxes.group(:source_id).having("COUNT(*) > 1").count
      duplicate_avatars = ActiveStorage::Attachment
        .where(record_type: "Contact", name: "avatar")
        .group(:record_id).having("COUNT(*) > 1").count
      abort("duplicate imported message source") if duplicate_message_sources.any?
      abort("empty importer archive") if empty_archives.any?
      abort("importer archive is not inert and resolved") if invalid_archives.exists?
      abort("duplicate ContactInbox source_id") if duplicate_sources.any?
      abort("duplicate Contact avatar") if duplicate_avatars.any?
      label = ENV.fetch("UMI_FBIG_AUDIT_LABEL")
      puts "[UMI-FBIG] stage=clone_history_state_verified " \
           "label=#{label}"
    '
}

verify_clone_history_state prehistory
```

## 5. Exact history acceptance on the merged digest

Freeze a cutoff at least 15 minutes old. Run one unaccepted probe with no
approval artifact and no profile access:

```bash
CUTOFF='<ISO-8601 UTC>'
HISTORY_PROBE_LOG="$AUDIT_DIR/history-probe.log"
HISTORY_PROBE_SUMMARY="$AUDIT_DIR/history-probe-summary.tsv"
[[ "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
CUTOFF_EPOCH="$(date -u -d "$CUTOFF" +%s)"
test "$(date -u -d "@$CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ)" = "$CUTOFF"
test "$CUTOFF_EPOCH" -le "$(( $(date -u +%s) - 900 ))"
UNRECOVERABLE_INSPECTOR="$AUDIT_DIR/fbig-unrecoverable-envelope-inspector.rb"
UNRECOVERABLE_SIDECAR="$HISTORY_DIR/fbig-unrecoverable-envelope-v1.tsv"
UNRECOVERABLE_SIDECAR_CHECKSUM="$HISTORY_DIR/fbig-unrecoverable-envelope-v1.tsv.sha256"
test ! -e "$UNRECOVERABLE_INSPECTOR"
(
  set -o noclobber
  cat >"$UNRECOVERABLE_INSPECTOR" <<'RUBY'
require 'set'

inbox = Inbox.find(Integer(ENV.fetch('UMI_FBIG_INSPECT_INBOX_ID'), 10))
expected_database = ENV.fetch('UMI_FBIG_INSPECT_EXPECTED_DATABASE')
actual_database = ActiveRecord::Base.connection.select_value('SELECT current_database()')
abort('inspection database mismatch') unless actual_database == expected_database
before = Time.iso8601(ENV.fetch('UMI_FBIG_INSPECT_BEFORE')).utc
abort('inspection cutoff is not canonical UTC') unless
  before.strftime('%Y-%m-%dT%H:%M:%SZ') == ENV.fetch('UMI_FBIG_INSPECT_BEFORE')

channel = inbox.channel
business_id = channel.instagram_id.to_s
abort('missing Instagram business id') if business_id.blank?
client = Umi::Fbig::HistoryImportGraphClient.new(
  channel,
  delay_ms: 250,
  max_conversation_pages: 10_000,
  max_message_pages: 10_000
)
attachment_service = Umi::Fbig::HistoryImportAttachmentService.new
thread_ids = Set.new
global_mids = Set.new
message_pages = 0
ambiguous_threads = []

required_string = lambda do |value, label|
  abort("invalid #{label}") unless
    value.is_a?(String) && value.valid_encoding? &&
    value.encoding.in?([Encoding::UTF_8, Encoding::US_ASCII]) && value.present?
  value.encode(Encoding::UTF_8)
end
connection = lambda do |owner, key|
  abort("invalid #{key} owner") unless owner.is_a?(Hash)
  next ['missing', []] unless owner.key?(key)
  next ['null', []] if owner[key].nil?
  abort("invalid #{key} connection") unless owner[key].is_a?(Hash)
  next ['data_missing', []] unless owner[key].key?('data')
  next ['data_null', []] if owner[key]['data'].nil?
  abort("invalid #{key} data") unless owner[key]['data'].is_a?(Array)
  ['array', owner[key]['data']]
end
parse_time = lambda do |value, label|
  text = required_string.call(value, label)
  Time.iso8601(text)
rescue ArgumentError
  abort("invalid #{label}")
end

conversation_pages = client.each_thread('instagram') do |thread|
  abort('invalid thread') unless thread.is_a?(Hash)
  thread_id = required_string.call(thread['id'], 'thread id')
  abort('duplicate thread id') unless thread_ids.add?(thread_id)
  participants_state, participant_data = connection.call(thread, 'participants')
  participants = participant_data.map do |participant|
    abort('invalid participant') unless participant.is_a?(Hash)
    participant_id = required_string.call(participant['id'], 'participant id')
    {
      'id' => participant_id,
      'business' => participant_id == business_id
    }
  end.sort_by { |participant| [participant.fetch('id'), participant.fetch('business') ? 1 : 0] }
  external = participants.reject { |participant| participant.fetch('business') }
  next if external.size == 1

  result = client.messages('instagram', thread_id)
  message_pages += result.pages
  mids = Set.new
  messages = result.items.filter_map do |listing|
    abort('invalid message listing') unless listing.is_a?(Hash)
    mid = required_string.call(listing['id'], 'message id')
    abort('duplicate message id') unless mids.add?(mid)
    abort('message id repeated across threads') unless global_mids.add?(mid)
    listing_time = parse_time.call(listing['created_time'], 'listing time')
    next unless listing_time < before

    listing_sender = required_string.call(listing.dig('from', 'id'), 'listing sender')
    detail = client.detail(mid)
    abort('missing message detail') unless detail.is_a?(Hash)
    abort('detail id mismatch') unless required_string.call(detail['id'], 'detail id') == mid
    detail_time = parse_time.call(detail['created_time'], 'detail time')
    abort('detail time mismatch') unless detail_time.to_i == listing_time.to_i
    abort('detail outside cutoff') unless detail_time < before
    detail_sender = required_string.call(detail.dig('from', 'id'), 'detail sender')

    recipients_state, recipient_data = connection.call(detail, 'to')
    recipient_ids = Set.new
    recipients = recipient_data.map do |recipient|
      abort('invalid recipient') unless recipient.is_a?(Hash)
      recipient_id = required_string.call(recipient['id'], 'recipient id')
      abort('duplicate recipient id') unless recipient_ids.add?(recipient_id)
      recipient_id
    end.sort

    message_shape =
      if !detail.key?('message')
        'missing'
      elsif detail['message'].nil?
        'null'
      elsif detail['message'].is_a?(String) && detail['message'].valid_encoding? &&
            detail['message'].encoding.in?([Encoding::UTF_8, Encoding::US_ASCII])
        'string'
      else
        abort('invalid message shape')
      end
    attachments_state, = connection.call(detail, 'attachments')
    attachment_plan = attachment_service.plan(detail)
    omissions = attachment_plan.omissions.to_h.transform_keys(&:to_s).sort.to_h
    {
      'mid' => mid,
      'listing_time' => listing_time.utc.iso8601(6),
      'listing_sender' => listing_sender,
      'detail_sender' => detail_sender,
      'recipients_state' => recipients_state,
      'recipients' => recipients,
      'message_shape' => message_shape,
      'message_blank' => detail['message'].blank?,
      'attachments_state' => attachments_state,
      'attachment_descriptors' => attachment_plan.descriptors.size,
      'attachment_omissions' => omissions
    }
  end.sort_by { |message| message.fetch('mid') }
  abort('unrecoverable envelope participant shape changed') unless
    participants_state == 'array' &&
    participants == [{ 'id' => business_id, 'business' => true }]
  abort('unrecoverable envelope message shape changed') unless
    messages.size == 1 &&
    messages.all? do |message|
      message.fetch('listing_sender') == business_id &&
        message.fetch('detail_sender') == business_id &&
        message.fetch('recipients').empty? &&
        message.fetch('message_blank') &&
        message.fetch('attachment_descriptors').zero? &&
        message.fetch('attachment_omissions').empty?
    end
  ambiguous_threads << {
    'id' => thread_id,
    'participants_state' => participants_state,
    'participants' => participants,
    'messages' => messages
  }
end

record = {
  'domain' => 'umi-fbig-unrecoverable-envelope-v1',
  'platform' => 'instagram',
  'business_id' => business_id,
  'before' => before.iso8601(6),
  'threads' => ambiguous_threads.sort_by { |thread| thread.fetch('id') }
}
fingerprint = Umi::Fbig::TypedValueDigest.hexdigest(record)
puts [
  '[UMI-FBIG]',
  'stage=unrecoverable_envelope_inspection',
  'platform=instagram',
  "count=#{ambiguous_threads.size}",
  "fingerprint=#{fingerprint}",
  "conversation_pages=#{conversation_pages}",
  "message_pages=#{message_pages}"
].join(' ')
RUBY
)
chmod 0400 "$UNRECOVERABLE_INSPECTOR"
test "$(stat -c '%u:%a:%h' "$UNRECOVERABLE_INSPECTOR")" = "0:400:1"

run_clone_unrecoverable_inspection() {
  clone_compose run --rm --no-deps -T \
    -e UMI_FBIG_INSPECT_INBOX_ID="$INBOX_ID" \
    -e UMI_FBIG_INSPECT_EXPECTED_DATABASE="$CLONE_DATABASE" \
    -e UMI_FBIG_INSPECT_BEFORE="$CUTOFF" \
    rails bundle exec rails runner - <"$UNRECOVERABLE_INSPECTOR" |
    grep '^\[UMI-FBIG\] stage=unrecoverable_envelope_inspection '
}

inspect_unrecoverable_envelopes() {
  local label="$1"
  local output="$AUDIT_DIR/unrecoverable-$label.tsv"
  local observed_count
  local observed_fingerprint
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  test ! -e "$output"
  run_clone_unrecoverable_inspection >"$output"
  test "$(grep -c '^\[UMI-FBIG\] stage=unrecoverable_envelope_inspection ' "$output")" -eq 1
  observed_count="$(stage_value "$output" unrecoverable_envelope_inspection count)"
  observed_fingerprint="$(stage_value "$output" unrecoverable_envelope_inspection fingerprint)"
  test "$observed_count" = "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS"
  [[ "$observed_fingerprint" =~ ^[0-9a-f]{64}$ ]]
  if [[ -e "$UNRECOVERABLE_SIDECAR" ]]; then
    test "$observed_count" = "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
    test "$observed_fingerprint" = "$(manifest_value "$UNRECOVERABLE_SIDECAR" fingerprint)"
  fi
  chmod 0400 "$output"
}

inspect_unrecoverable_envelopes before-probe
test ! -e "$HISTORY_PROBE_LOG"
test ! -e "$HISTORY_PROBE_SUMMARY"
set +e
clone_compose run --rm --no-deps -T \
  -e UMI_FBIG_HISTORY_APPROVAL_MODE=unaccepted_probe \
  -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
  -e DRY_RUN=true \
  -e PLATFORMS=messenger,instagram \
  -e SINCE=all \
  -e BEFORE="$CUTOFF" \
  -e OUTBOUND_POLICY=pre_presence \
  -e PROFILE_MODE=defer \
  rails bundle exec rake "umi:fbig:history_import[$INBOX_ID]" \
  2>&1 | tee "$HISTORY_PROBE_LOG"
PROBE_STATUS=("${PIPESTATUS[@]}")
set -e
test "${#PROBE_STATUS[@]}" -eq 2
test "${PROBE_STATUS[0]}" -eq 1
test "${PROBE_STATUS[1]}" -eq 0
test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$HISTORY_PROBE_LOG")" -eq 1
grep '^\[UMI-FBIG\] stage=history_import_summary ' \
  "$HISTORY_PROBE_LOG" >"$HISTORY_PROBE_SUMMARY"
inspect_unrecoverable_envelopes after-probe
cmp -s \
  "$AUDIT_DIR/unrecoverable-before-probe.tsv" \
  "$AUDIT_DIR/unrecoverable-after-probe.tsv"

CONTENTLESS_MISMATCHES="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary contentless_acceptance_mismatches
)"
UNAVAILABLE_MESSAGE_MISMATCHES="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary \
    unavailable_message_thread_acceptance_mismatches
)"
EXIT_FAILURES="$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary exit_failures)"
AMBIGUOUS_PARTICIPANTS="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary ambiguous_participants
)"
STRUCTURAL_UNRECOVERABLE_THREADS="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary structural_unrecoverable_threads
)"
UNAVAILABLE_MESSAGE_THREADS="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary unavailable_message_threads
)"
CLASSIFIED_OMITTED_THREADS="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary classified_omitted_threads
)"
FAILED_THREADS="$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary failed_threads)"
[[ "$CONTENTLESS_MISMATCHES" =~ ^[1-9][0-9]*$ ]]
test "$UNAVAILABLE_MESSAGE_MISMATCHES" = 1
test "$EXIT_FAILURES" -eq "$((CONTENTLESS_MISMATCHES + UNAVAILABLE_MESSAGE_MISMATCHES))"
test "$AMBIGUOUS_PARTICIPANTS" = "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS"
test "$STRUCTURAL_UNRECOVERABLE_THREADS" = "$AMBIGUOUS_PARTICIPANTS"
test "$UNAVAILABLE_MESSAGE_THREADS" = "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS"
test "$CLASSIFIED_OMITTED_THREADS" -eq \
  "$((STRUCTURAL_UNRECOVERABLE_THREADS + UNAVAILABLE_MESSAGE_THREADS))"
test "$FAILED_THREADS" = 0
test "$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary listed_threads)" -eq \
  "$(( $(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary message_cursor_exhausted_threads) + \
       CLASSIFIED_OMITTED_THREADS + FAILED_THREADS ))"
test "$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary scan_complete)" = true
for counter in \
  ambiguous_senders partially_paginated_threads uncategorized_threads \
  platform_failures retry_exhaustion authentication_failures lock_loss \
  profile_requests profile_successes profile_unavailable profile_errors \
  profile_changes_projected profile_changes_applied avatars_offered avatars_preserved \
  avatars_attached avatars_raced avatars_unavailable avatar_failures \
  avatars_skipped_history_incomplete avatar_bytes; do
  test "$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary "$counter")" = 0
done
chmod 0400 "$HISTORY_PROBE_SUMMARY"
test "$(stat -c '%u:%a:%h' "$HISTORY_PROBE_SUMMARY")" = "0:400:1"
```

The inspector emits no digest unless the ambiguous envelope still has exactly
one business-only participant, one business-sent in-scope message listing and
detail, no recipients, a blank body, and no supported or omitted attachment.
The only allowed exit failures above are the two exact approval-set
mismatches. Structural and API-unavailable threads are classified omissions,
not failed threads, and the listed-thread conservation equation must close.
The structural omission is independently bound to its exact unrecoverable
envelope by the matching pre/post inspection. Review the per-platform
counts/fingerprints, then construct the strict sidecar and
approval in their exact field order. Every provenance hash is recomputed from
its immutable artifact, the full random-suffixed coordinated backup ID is
copied byte for byte, and permissions are sealed before the in-image loader
runs:

```bash
BACKUP_MANIFEST="$BACKUP_DIR/fbig-coordinated-backup-v1.tsv"
BACKUP_CHECKSUM="$BACKUP_DIR/fbig-coordinated-backup-v1.tsv.sha256"
(
  cd "$BACKUP_DIR"
  sha256sum --check "$(basename "$BACKUP_CHECKSUM")"
)
BACKUP_ID="$(manifest_value "$BACKUP_MANIFEST" backup_id)"
DATABASE_DUMP_SHA256="$(sha256_file "$BACKUP_DIR/database.dump")"
SOURCE_STORAGE_MANIFEST_SHA256="$(sha256_file "$BACKUP_DIR/storage.manifest")"
RESTORED_STORAGE_MANIFEST_SHA256="$(sha256_file "$RESTORED_STORAGE_MANIFEST")"
PLACEHOLDER_TARGETS_SHA256="$(sha256_file "$TARGET_DIR/fbig-profile-targets-v1.tsv")"
INSPECTOR_SCRIPT_SHA256="$(sha256_file "$UNRECOVERABLE_INSPECTOR")"
UNRECOVERABLE_COUNT="$(
  stage_value "$AUDIT_DIR/unrecoverable-before-probe.tsv" \
    unrecoverable_envelope_inspection count
)"
UNRECOVERABLE_FINGERPRINT="$(
  stage_value "$AUDIT_DIR/unrecoverable-before-probe.tsv" \
    unrecoverable_envelope_inspection fingerprint
)"
APPROVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
test ! -e "$UNRECOVERABLE_SIDECAR"
test ! -e "$UNRECOVERABLE_SIDECAR_CHECKSUM"
(
  set -o noclobber
  {
    printf 'schema_version\t1\n'
    printf 'repository_commit\t%s\n' "$APP_COMMIT"
    printf 'image_digest\t%s\n' "$APP_DIGEST"
    printf 'account_id\t%s\n' "$(manifest_value "$BACKUP_MANIFEST" account_id)"
    printf 'inbox_id\t%s\n' "$(manifest_value "$BACKUP_MANIFEST" inbox_id)"
    printf 'instagram_business_id\t%s\n' \
      "$(manifest_value "$BACKUP_MANIFEST" instagram_business_id)"
    printf 'before\t%s\n' "$CUTOFF"
    printf 'platform\tinstagram\n'
    printf 'count\t%s\n' "$UNRECOVERABLE_COUNT"
    printf 'fingerprint\t%s\n' "$UNRECOVERABLE_FINGERPRINT"
    printf 'inspector_script_sha256\t%s\n' "$INSPECTOR_SCRIPT_SHA256"
    printf 'approved_by\t%s\n' "$APPROVED_BY"
    printf 'approved_at\t%s\n' "$APPROVED_AT"
  } >"$UNRECOVERABLE_SIDECAR"
)
(
  set -o noclobber
  cd "$HISTORY_DIR"
  sha256sum "$(basename "$UNRECOVERABLE_SIDECAR")" \
    >"$(basename "$UNRECOVERABLE_SIDECAR_CHECKSUM")"
)
chmod 0400 "$UNRECOVERABLE_SIDECAR" "$UNRECOVERABLE_SIDECAR_CHECKSUM"
(
  cd "$HISTORY_DIR"
  sha256sum --check "$(basename "$UNRECOVERABLE_SIDECAR_CHECKSUM")"
)
EXPECTED_UNRECOVERABLE_FIELDS=(
  schema_version repository_commit image_digest account_id inbox_id
  instagram_business_id before platform count fingerprint
  inspector_script_sha256 approved_by approved_at
)
awk -F $'\t' 'NF != 2 { exit 1 } END { if (NR != 13) exit 1 }' \
  "$UNRECOVERABLE_SIDECAR"
mapfile -t OBSERVED_UNRECOVERABLE_FIELDS < <(cut -f1 "$UNRECOVERABLE_SIDECAR")
test "${#OBSERVED_UNRECOVERABLE_FIELDS[@]}" -eq \
  "${#EXPECTED_UNRECOVERABLE_FIELDS[@]}"
for field_index in "${!EXPECTED_UNRECOVERABLE_FIELDS[@]}"; do
  test "${OBSERVED_UNRECOVERABLE_FIELDS[$field_index]}" = \
    "${EXPECTED_UNRECOVERABLE_FIELDS[$field_index]}"
done
UNRECOVERABLE_SIDECAR_SHA256="$(sha256_file "$UNRECOVERABLE_SIDECAR")"
printf '[UMI-FBIG] stage=unrecoverable_envelope_approval sidecar_sha256=%s count=%s fingerprint=%s\n' \
  "$UNRECOVERABLE_SIDECAR_SHA256" "$UNRECOVERABLE_COUNT" "$UNRECOVERABLE_FINGERPRINT" \
  >>"$HISTORY_PROBE_LOG"
chmod 0400 "$HISTORY_PROBE_LOG"
test "$(stat -c '%u:%a:%h' "$HISTORY_PROBE_LOG")" = "0:400:1"
SOURCE_DRY_LOG_SHA256="$(sha256_file "$HISTORY_PROBE_LOG")"
SOURCE_DRY_SUMMARY_SHA256="$(sha256_file "$HISTORY_PROBE_SUMMARY")"
MESSENGER_CONTENTLESS_COUNT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary messenger_contentless_details
)"
MESSENGER_CONTENTLESS_FINGERPRINT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary messenger_contentless_fingerprint
)"
INSTAGRAM_CONTENTLESS_COUNT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary instagram_contentless_details
)"
INSTAGRAM_CONTENTLESS_FINGERPRINT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary instagram_contentless_fingerprint
)"
MESSENGER_UNAVAILABLE_MESSAGE_COUNT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary messenger_unavailable_message_thread_count
)"
MESSENGER_UNAVAILABLE_MESSAGE_FINGERPRINT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary messenger_unavailable_message_thread_fingerprint
)"
INSTAGRAM_UNAVAILABLE_MESSAGE_COUNT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary instagram_unavailable_message_thread_count
)"
INSTAGRAM_UNAVAILABLE_MESSAGE_FINGERPRINT="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary instagram_unavailable_message_thread_fingerprint
)"

test "$DATABASE_DUMP_SHA256" = "$(manifest_value "$BACKUP_MANIFEST" database_dump_sha256)"
test "$SOURCE_STORAGE_MANIFEST_SHA256" = \
  "$(manifest_value "$BACKUP_MANIFEST" storage_manifest_sha256)"
[[ "$BACKUP_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]]
[[ "$MESSENGER_CONTENTLESS_COUNT" =~ ^(0|[1-9][0-9]*)$ ]]
[[ "$INSTAGRAM_CONTENTLESS_COUNT" =~ ^(0|[1-9][0-9]*)$ ]]
[[ "$MESSENGER_CONTENTLESS_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
[[ "$INSTAGRAM_CONTENTLESS_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
test "$MESSENGER_UNAVAILABLE_MESSAGE_COUNT" = 0
test "$INSTAGRAM_UNAVAILABLE_MESSAGE_COUNT" = \
  "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS"
[[ "$MESSENGER_UNAVAILABLE_MESSAGE_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
[[ "$INSTAGRAM_UNAVAILABLE_MESSAGE_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
test "$UNRECOVERABLE_COUNT" = "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS"
[[ "$UNRECOVERABLE_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
[[ "$INSPECTOR_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ ]]

HISTORY_APPROVAL="$HISTORY_DIR/fbig-approval-v2.tsv"
HISTORY_APPROVAL_CHECKSUM="$HISTORY_DIR/fbig-approval-v2.tsv.sha256"
test ! -e "$HISTORY_APPROVAL"
test ! -e "$HISTORY_APPROVAL_CHECKSUM"
(
  set -o noclobber
  {
    printf 'schema_version\t2\n'
    printf 'repository_commit\t%s\n' "$APP_COMMIT"
    printf 'image_digest\t%s\n' "$APP_DIGEST"
    printf 'clone_backup_id\t%s\n' "$BACKUP_ID"
    printf 'clone_database_name\t%s\n' "$CLONE_DATABASE"
    printf 'database_dump_sha256\t%s\n' "$DATABASE_DUMP_SHA256"
    printf 'source_storage_manifest_sha256\t%s\n' "$SOURCE_STORAGE_MANIFEST_SHA256"
    printf 'restored_storage_manifest_sha256\t%s\n' "$RESTORED_STORAGE_MANIFEST_SHA256"
    printf 'account_id\t%s\n' "$(manifest_value "$BACKUP_MANIFEST" account_id)"
    printf 'inbox_id\t%s\n' "$(manifest_value "$BACKUP_MANIFEST" inbox_id)"
    printf 'facebook_page_id\t%s\n' "$(manifest_value "$BACKUP_MANIFEST" facebook_page_id)"
    printf 'instagram_business_id\t%s\n' "$(manifest_value "$BACKUP_MANIFEST" instagram_business_id)"
    printf 'since\tall\n'
    printf 'before\t%s\n' "$CUTOFF"
    printf 'outbound_policy\tpre_presence\n'
    printf 'profile_mode\tdefer\n'
    printf 'messenger_count\t%s\n' "$MESSENGER_CONTENTLESS_COUNT"
    printf 'messenger_fingerprint\t%s\n' "$MESSENGER_CONTENTLESS_FINGERPRINT"
    printf 'instagram_count\t%s\n' "$INSTAGRAM_CONTENTLESS_COUNT"
    printf 'instagram_fingerprint\t%s\n' "$INSTAGRAM_CONTENTLESS_FINGERPRINT"
    printf 'messenger_unavailable_message_thread_count\t%s\n' \
      "$MESSENGER_UNAVAILABLE_MESSAGE_COUNT"
    printf 'messenger_unavailable_message_thread_fingerprint\t%s\n' \
      "$MESSENGER_UNAVAILABLE_MESSAGE_FINGERPRINT"
    printf 'instagram_unavailable_message_thread_count\t%s\n' \
      "$INSTAGRAM_UNAVAILABLE_MESSAGE_COUNT"
    printf 'instagram_unavailable_message_thread_fingerprint\t%s\n' \
      "$INSTAGRAM_UNAVAILABLE_MESSAGE_FINGERPRINT"
    printf 'placeholder_targets_sha256\t%s\n' "$PLACEHOLDER_TARGETS_SHA256"
    printf 'source_dry_log_sha256\t%s\n' "$SOURCE_DRY_LOG_SHA256"
    printf 'source_dry_summary_sha256\t%s\n' "$SOURCE_DRY_SUMMARY_SHA256"
    printf 'approved_by\t%s\n' "$APPROVED_BY"
    printf 'approved_at\t%s\n' "$APPROVED_AT"
  } >"$HISTORY_APPROVAL"
)
(
  set -o noclobber
  cd "$HISTORY_DIR"
  sha256sum "$(basename "$HISTORY_APPROVAL")" >"$(basename "$HISTORY_APPROVAL_CHECKSUM")"
)
chmod 0400 "$HISTORY_APPROVAL" "$HISTORY_APPROVAL_CHECKSUM"
test "$(stat -c '%u:%a:%h' "$HISTORY_APPROVAL")" = "0:400:1"
test "$(stat -c '%u:%a:%h' "$HISTORY_APPROVAL_CHECKSUM")" = "0:400:1"

test "$(clone_compose config --images | grep -Fxc "$APP_DIGEST")" -eq 1
clone_compose run --rm --no-deps -T \
  --volume "$BACKUP_DIR:/run/fbig/backup:ro" \
  --volume "$AUDIT_DIR:/run/fbig/audit:ro" \
  --volume "$HISTORY_DIR:/run/fbig/history:ro" \
  --volume "$TARGET_DIR:/run/fbig/targets:ro" \
  -e UMI_FBIG_EXPECTED_COMMIT="$APP_COMMIT" \
  -e UMI_FBIG_EXPECTED_DIGEST="$APP_DIGEST" \
  -e UMI_FBIG_EXPECTED_CLONE_DATABASE="$CLONE_DATABASE" \
  -e UMI_FBIG_EXPECTED_BACKUP_ID="$BACKUP_ID" \
  -e UMI_FBIG_EXPECTED_INBOX_ID="$INBOX_ID" \
  rails bundle exec rails runner '
    require "digest"
    manifest = Umi::Fbig::HistoryApprovalManifest.load(
      manifest_path: "/run/fbig/history/fbig-approval-v2.tsv",
      checksum_path: "/run/fbig/history/fbig-approval-v2.tsv.sha256"
    )
    targets = Umi::Fbig::ProfileTargetManifest.load(
      path: "/run/fbig/targets/fbig-profile-targets-v1.tsv",
      expected_sha256: manifest.placeholder_targets_sha256
    )
    actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
    inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_EXPECTED_INBOX_ID"), 10))
    provenance = {
      "database_dump_sha256" => "/run/fbig/backup/database.dump",
      "source_storage_manifest_sha256" => "/run/fbig/backup/storage.manifest",
      "restored_storage_manifest_sha256" => "/run/fbig/audit/clone-restored-storage.manifest",
      "source_dry_log_sha256" => "/run/fbig/audit/history-probe.log",
      "source_dry_summary_sha256" => "/run/fbig/audit/history-probe-summary.tsv"
    }
    provenance_valid = provenance.all? do |field, path|
      File.file?(path) && Digest::SHA256.file(path).hexdigest == manifest.values.fetch(field)
    end
    image_commit = File.binread("/app/.git_sha").strip
    scope_valid = manifest.account_id == inbox.account_id &&
                  manifest.inbox_id == inbox.id &&
                  manifest.facebook_page_id.to_s == inbox.channel.page_id.to_s &&
                  manifest.instagram_business_id.to_s == inbox.channel.instagram_id.to_s
    valid = actual_database == ENV.fetch("UMI_FBIG_EXPECTED_CLONE_DATABASE") &&
            image_commit == ENV.fetch("UMI_FBIG_EXPECTED_COMMIT") &&
            manifest.repository_commit == ENV.fetch("UMI_FBIG_EXPECTED_COMMIT") &&
            manifest.image_digest == ENV.fetch("UMI_FBIG_EXPECTED_DIGEST") &&
            manifest.clone_database_name == actual_database &&
            manifest.clone_backup_id == ENV.fetch("UMI_FBIG_EXPECTED_BACKUP_ID") &&
            manifest.inbox_id == Integer(ENV.fetch("UMI_FBIG_EXPECTED_INBOX_ID"), 10) &&
            manifest.since == "all" &&
            manifest.outbound_policy == "pre_presence" &&
            manifest.profile_mode == "defer" &&
            targets.any?
    abort("history approval does not bind the accepted clone") unless
      provenance_valid && scope_valid && valid
    puts "[UMI-FBIG] stage=history_approval_validated sha256=#{manifest.sha256}"
  '
```

Run two accepted dry scans. Do not restate `SINCE`, `BEFORE`,
`OUTBOUND_POLICY`, `PROFILE_MODE`, or an accepted omission set; they come only
from the approval:

```bash
history_run() {
  local dry_run="$1"
  local platforms="$2"
  local budget="${3:-}"
  local extra=()
  if [[ "$dry_run" == false ]]; then
    extra+=(
      -e ACK_EXPAND_EXISTING=true
      -e ACK_SINGLE_CONVERSATION_REOPEN=true
      -e UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES="$budget"
    )
  fi
  clone_compose run --rm --no-deps -T \
    --volume "$HISTORY_DIR:/run/fbig/history:ro" \
    -e UMI_FBIG_HISTORY_APPROVAL_MODE=approved \
    -e UMI_FBIG_APPROVAL_MANIFEST_PATH=/run/fbig/history/fbig-approval-v2.tsv \
    -e UMI_FBIG_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-approval-v2.tsv.sha256 \
    -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
    -e UMI_FBIG_RUNTIME_REPOSITORY_COMMIT="$APP_COMMIT" \
    -e UMI_FBIG_RUNTIME_IMAGE_DIGEST="$APP_DIGEST" \
    -e DRY_RUN="$dry_run" \
    -e PLATFORMS="$platforms" \
    "${extra[@]}" \
    rails bundle exec rake "umi:fbig:history_import[$INBOX_ID]"
}

clone_database_fingerprint() {
  docker compose exec -T postgres \
    pg_dump -U chatwoot --dbname="$CLONE_DATABASE" \
      --data-only --no-owner --no-privileges --no-comments --large-objects \
      --restrict-key=UMIFBIGCLONEDATABASEFINGERPRINT |
    sha256sum |
    awk '{print "FBIG_IMMUTABLE|database|" $1}'
}

capture_clone_storage_manifest() {
  local output="$1"
  test ! -e "$output"
  "$STACK_DIR/bin/fbig_storage_artifact.py" manifest "$CLONE_STORAGE" "$output"
}

normalize_history_summary() {
  local summary="$1"
  awk '
    {
      output = ""
      for (field = 1; field <= NF; field += 1) {
        if ($field ~ /^(contentless_acceptance_mismatches|unavailable_message_thread_acceptance_mismatches|exit_failures)=/) continue
        output = output (output == "" ? "" : " ") $field
      }
      print output
    }
  ' "$summary"
}

validate_history_apply_summary() {
  local summary="$1"
  local require_zero_writes="$2"
  local platforms="$3"
  local expected_degraded=false
  local expected_ambiguous=0
  local expected_unavailable=0
  local expected_classified
  local observed_degraded
  local attachments_unavailable
  local platform
  local approved_count
  local approved_fingerprint
  local approved_unavailable_count
  local approved_unavailable_fingerprint
  local observed_count
  local observed_fingerprint
  local -a selected_platforms
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  [[ "$platforms" =~ ^(messenger|instagram|messenger,instagram)$ ]]
  test "$(stage_value "$summary" history_import_summary dry_run)" = false
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = true
  test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary unavailable_message_thread_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
  if [[ ",$platforms," == *,instagram,* ]]; then
    expected_ambiguous="$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  fi
  test "$(stage_value "$summary" history_import_summary ambiguous_participants)" = \
    "$expected_ambiguous"
  test "$(stage_value "$summary" history_import_summary structural_unrecoverable_threads)" = \
    "$expected_ambiguous"
  for counter in \
    ambiguous_senders partially_paginated_threads uncategorized_threads \
    foreign_source_id_anomalies \
    platform_failures retry_exhaustion authentication_failures \
    lock_loss reindex_failures download_budget_exhaustions; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done

  IFS=',' read -r -a selected_platforms <<<"$platforms"
  for platform in "${selected_platforms[@]}"; do
    approved_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" "${platform}_count"
    )"
    approved_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" "${platform}_fingerprint"
    )"
    observed_count="$(
      stage_value "$summary" history_import_summary "${platform}_contentless_details"
    )"
    observed_fingerprint="$(
      stage_value "$summary" history_import_summary "${platform}_contentless_fingerprint"
    )"
    [[ "$approved_count" =~ ^(0|[1-9][0-9]*)$ ]]
    [[ "$approved_fingerprint" =~ ^[0-9a-f]{64}$ ]]
    test "$observed_count" = "$approved_count"
    test "$observed_fingerprint" = "$approved_fingerprint"
    approved_unavailable_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" \
        "${platform}_unavailable_message_thread_count"
    )"
    approved_unavailable_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" \
        "${platform}_unavailable_message_thread_fingerprint"
    )"
    test "$(stage_value "$summary" history_import_summary \
      "${platform}_unavailable_message_thread_count")" = "$approved_unavailable_count"
    test "$(stage_value "$summary" history_import_summary \
      "${platform}_unavailable_message_thread_fingerprint")" = \
      "$approved_unavailable_fingerprint"
    expected_unavailable="$((expected_unavailable + approved_unavailable_count))"
    if [[ "$approved_count" != 0 || "$approved_unavailable_count" != 0 ]]; then
      expected_degraded=true
    fi
  done
  expected_classified="$((expected_ambiguous + expected_unavailable))"
  test "$(stage_value "$summary" history_import_summary unavailable_message_threads)" = \
    "$expected_unavailable"
  test "$(stage_value "$summary" history_import_summary classified_omitted_threads)" = \
    "$expected_classified"
  test "$(stage_value "$summary" history_import_summary failed_threads)" = 0
  test "$(stage_value "$summary" history_import_summary listed_threads)" -eq \
    "$(( $(stage_value "$summary" history_import_summary message_cursor_exhausted_threads) + \
         expected_classified ))"
  if [[ "$expected_classified" != 0 ]]; then
    expected_degraded=true
  fi

  attachments_unavailable="$(
    stage_value "$summary" history_import_summary attachments_unavailable
  )"
  [[ "$attachments_unavailable" =~ ^(0|[1-9][0-9]*)$ ]]
  if [[ "$attachments_unavailable" != 0 ]]; then
    expected_degraded=true
  fi
  observed_degraded="$(stage_value "$summary" history_import_summary degraded)"
  test "$observed_degraded" = "$expected_degraded"
  for counter in \
    profile_requests profile_successes profile_unavailable profile_errors \
    profile_changes_projected profile_changes_applied avatars_offered \
    avatars_preserved avatars_attached avatars_raced avatars_unavailable \
    avatar_failures avatars_skipped_history_incomplete avatar_bytes; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done

  if [[ "$require_zero_writes" == true ]]; then
    for counter in \
      imported_contacts imported_archives imported_incoming imported_outgoing \
      imported_messages imported_attachments marker_normalizations \
      history_evidence_changes_applied \
      messenger_history_evidence_changes_applied \
      instagram_history_evidence_changes_applied \
      profile_changes_applied avatars_attached avatars_raced; do
      test "$(stage_value "$summary" history_import_summary "$counter")" = 0
    done
  fi
}

accepted_history_dry_run() {
  local attempt="$1"
  local log="$AUDIT_DIR/history-$attempt.log"
  local summary="$AUDIT_DIR/history-$attempt-summary.tsv"
  local normalized="$AUDIT_DIR/history-$attempt-summary-normalized.tsv"
  local statuses
  [[ "$attempt" =~ ^dry-[12]$ ]]
  test ! -e "$log"
  test ! -e "$summary"
  test ! -e "$normalized"

  inspect_unrecoverable_envelopes "before-$attempt"
  set +e
  history_run true messenger,instagram 2>&1 | tee "$log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  inspect_unrecoverable_envelopes "after-$attempt"
  test "${#statuses[@]}" -eq 2
  test "${statuses[0]}" -eq 0
  test "${statuses[1]}" -eq 0
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$log")" -eq 1
  grep '^\[UMI-FBIG\] stage=history_import_summary ' "$log" >"$summary"
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = not_applicable
  test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary unavailable_message_thread_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
  test "$(stage_value "$summary" history_import_summary ambiguous_participants)" = \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  test "$(stage_value "$summary" history_import_summary structural_unrecoverable_threads)" = \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  test "$(stage_value "$summary" history_import_summary unavailable_message_threads)" = \
    "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS"
  test "$(stage_value "$summary" history_import_summary classified_omitted_threads)" -eq \
    "$(( $(manifest_value "$UNRECOVERABLE_SIDECAR" count) + \
         EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS ))"
  test "$(stage_value "$summary" history_import_summary failed_threads)" = 0
  test "$(stage_value "$summary" history_import_summary listed_threads)" -eq \
    "$(( $(stage_value "$summary" history_import_summary message_cursor_exhausted_threads) + \
         $(stage_value "$summary" history_import_summary classified_omitted_threads) ))"
  test "$(stage_value "$summary" history_import_summary ambiguous_senders)" = 0
  test "$(stage_value "$summary" history_import_summary partially_paginated_threads)" = 0
  test "$(stage_value "$summary" history_import_summary uncategorized_threads)" = 0
  normalize_history_summary "$summary" >"$normalized"
  chmod 0400 "$log" "$summary" "$normalized"
}

HISTORY_DRY_DATABASE_BEFORE="$AUDIT_DIR/history-dry-database-before.tsv"
HISTORY_DRY_STORAGE_BEFORE="$AUDIT_DIR/history-dry-storage-before.manifest"
test ! -e "$HISTORY_DRY_DATABASE_BEFORE"
clone_database_fingerprint >"$HISTORY_DRY_DATABASE_BEFORE"
capture_clone_storage_manifest "$HISTORY_DRY_STORAGE_BEFORE"
verify_clone_history_state before-accepted-dry

accepted_history_dry_run dry-1
HISTORY_DRY_DATABASE_AFTER_1="$AUDIT_DIR/history-dry-database-after-1.tsv"
HISTORY_DRY_STORAGE_AFTER_1="$AUDIT_DIR/history-dry-storage-after-1.manifest"
test ! -e "$HISTORY_DRY_DATABASE_AFTER_1"
clone_database_fingerprint >"$HISTORY_DRY_DATABASE_AFTER_1"
capture_clone_storage_manifest "$HISTORY_DRY_STORAGE_AFTER_1"
verify_clone_history_state after-accepted-dry-1

accepted_history_dry_run dry-2
HISTORY_DRY_DATABASE_AFTER_2="$AUDIT_DIR/history-dry-database-after-2.tsv"
HISTORY_DRY_STORAGE_AFTER_2="$AUDIT_DIR/history-dry-storage-after-2.manifest"
test ! -e "$HISTORY_DRY_DATABASE_AFTER_2"
clone_database_fingerprint >"$HISTORY_DRY_DATABASE_AFTER_2"
capture_clone_storage_manifest "$HISTORY_DRY_STORAGE_AFTER_2"
verify_clone_history_state after-accepted-dry-2

HISTORY_PROBE_NORMALIZED="$AUDIT_DIR/history-probe-summary-normalized.tsv"
test ! -e "$HISTORY_PROBE_NORMALIZED"
normalize_history_summary "$HISTORY_PROBE_SUMMARY" >"$HISTORY_PROBE_NORMALIZED"
cmp -s "$HISTORY_PROBE_NORMALIZED" "$AUDIT_DIR/history-dry-1-summary-normalized.tsv"
cmp -s "$HISTORY_PROBE_NORMALIZED" "$AUDIT_DIR/history-dry-2-summary-normalized.tsv"
cmp -s \
  "$AUDIT_DIR/history-dry-1-summary-normalized.tsv" \
  "$AUDIT_DIR/history-dry-2-summary-normalized.tsv"
cmp -s "$HISTORY_DRY_DATABASE_BEFORE" "$HISTORY_DRY_DATABASE_AFTER_1"
cmp -s "$HISTORY_DRY_DATABASE_BEFORE" "$HISTORY_DRY_DATABASE_AFTER_2"
cmp -s "$HISTORY_DRY_STORAGE_BEFORE" "$HISTORY_DRY_STORAGE_AFTER_1"
cmp -s "$HISTORY_DRY_STORAGE_BEFORE" "$HISTORY_DRY_STORAGE_AFTER_2"
chmod 0400 \
  "$HISTORY_DRY_DATABASE_BEFORE" "$HISTORY_DRY_DATABASE_AFTER_1" \
  "$HISTORY_DRY_DATABASE_AFTER_2" "$HISTORY_DRY_STORAGE_BEFORE" \
  "$HISTORY_DRY_STORAGE_AFTER_1" "$HISTORY_DRY_STORAGE_AFTER_2" \
  "$HISTORY_PROBE_NORMALIZED"
```

The comparisons above are the required proof: both accepted summaries equal
the probe after removing only its expected acceptance-mismatch/exit counters,
both accepted summaries equal each other, and the clone database, local
storage, original ID-bound baseline, and invariants remain unchanged.

## 6. Clone history apply and zero-write recovery

Use reviewed, positive, per-invocation media budgets:

```bash
MESSENGER_APPLY_BYTES='<messenger byte budget>'
MESSENGER_RECOVERY_BYTES='<messenger recovery byte budget>'
INSTAGRAM_APPLY_BYTES='<instagram byte budget>'
ALL_RECOVERY_BYTES='<two-platform recovery byte budget>'
for value in \
  "$MESSENGER_APPLY_BYTES" "$MESSENGER_RECOVERY_BYTES" \
  "$INSTAGRAM_APPLY_BYTES" "$ALL_RECOVERY_BYTES"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
done

history_apply_with_verification() {
  local label="$1"
  local platforms="$2"
  local budget="$3"
  local require_zero_writes="$4"
  local log="$AUDIT_DIR/history-$label.log"
  local summary="$AUDIT_DIR/history-$label-summary.tsv"
  local statuses
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  [[ "$budget" =~ ^[1-9][0-9]*$ ]]
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  test ! -e "$log"
  test ! -e "$summary"

  if [[ ",$platforms," == *,instagram,* ]]; then
    inspect_unrecoverable_envelopes "before-$label"
  fi
  set +e
  history_run false "$platforms" "$budget" 2>&1 | tee "$log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ ",$platforms," == *,instagram,* ]]; then
    inspect_unrecoverable_envelopes "after-$label"
  fi
  test "${#statuses[@]}" -eq 2
  test "${statuses[0]}" -eq 0
  test "${statuses[1]}" -eq 0
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$log")" -eq 1
  grep '^\[UMI-FBIG\] stage=history_import_summary ' "$log" >"$summary"
  validate_history_apply_summary "$summary" false "$platforms"
  verify_clone_history_state "$label"
  chmod 0400 "$log" "$summary"
  validate_history_apply_summary "$summary" "$require_zero_writes" "$platforms"
}

history_apply_with_verification \
  messenger-apply messenger "$MESSENGER_APPLY_BYTES" false
history_apply_with_verification \
  messenger-recovery messenger "$MESSENGER_RECOVERY_BYTES" true
history_apply_with_verification \
  instagram-apply instagram "$INSTAGRAM_APPLY_BYTES" false
history_apply_with_verification \
  all-idempotency messenger,instagram "$ALL_RECOVERY_BYTES" true
```

If a classified retryable attachment failure remains, repeat only the
two-platform recovery through the same verification wrapper with a new
positive attempt number so every recovery has a unique log and baseline
comparison:

```bash
NEXT_ALL_RECOVERY_ATTEMPT='<next positive attempt number>'
[[ "$NEXT_ALL_RECOVERY_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
history_apply_with_verification \
  "all-recovery-$NEXT_ALL_RECOVERY_ATTEMPT" \
  messenger,instagram "$ALL_RECOVERY_BYTES" true
```

Acceptance requires a final pass with:

- `scan_complete=true`, `write_complete=true`, and `exit_failures=0`;
- zero imported contacts, archives, messages, attachments, and history
  evidence changes;
- only the exact approved contentless omissions;
- every importer archive resolved and containing at least one message;
- no new non-importer conversations or messages;
- no duplicate `source_id` within the inbox;
- no duplicate Contact avatar attachment; and
- the original 22 archives, 48 messages, and 6 attachments still matching
  their ID-bound PII-free baseline.

Capture the PII-free source profile state after history is stable:

```bash
STATE_DIR="$AUDIT_DIR/profile-source-state"
mkdir -m 0700 "$STATE_DIR"
clone_compose run --rm --no-deps -T \
  --volume "$STATE_DIR:/run/fbig/state" \
  -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
  -e UMI_FBIG_PROFILE_STATE_OUTPUT_DIR=/run/fbig/state \
  rails bundle exec rake "umi:fbig:history_profile_state[$INBOX_ID]"
chmod 0400 "$STATE_DIR"/fbig-profile-state-v1.tsv*
```

## 7. Clone profile acceptance

Set the four reviewed positive budgets, then use this complete runner. It
creates a fresh root-owned attempt directory, mounts every immutable input,
captures the rake and `tee` statuses synchronously, and seals the exact log and
terminal summary used by profile approval:

```bash
PROFILE_GRAPH_DELAY_MS='<reviewed positive value>'
PROFILE_MAX_CONVERSATION_PAGES='<reviewed positive value>'
PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS='<reviewed positive value>'
PROFILE_MAX_DOWNLOAD_BYTES='<reviewed positive value>'
for value in \
  "$PROFILE_GRAPH_DELAY_MS" "$PROFILE_MAX_CONVERSATION_PAGES" \
  "$PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS" "$PROFILE_MAX_DOWNLOAD_BYTES"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
done
CLONE_PROFILE_ROOT="$AUDIT_DIR/clone-profile"
mkdir -m 0700 "$CLONE_PROFILE_ROOT"

clone_profile_run() {
  local phase="$1"
  local dry_run="$2"
  local attempt_directory="$3"
  local predecessor_directory="${4:-}"
  local predecessor=()
  [[ ! -e "$attempt_directory" ]]
  mkdir -m 0700 "$attempt_directory"
  mkdir -m 0700 "$attempt_directory/avatar-intents"
  if [[ "$phase" == idempotency ]]; then
    test -n "$predecessor_directory"
    predecessor=(
      --volume "$predecessor_directory:/run/fbig/predecessor:ro"
      -e UMI_FBIG_PROFILE_PREDECESSOR_STATE_PATH=/run/fbig/predecessor/fbig-profile-clone-poststate-v1.tsv
      -e UMI_FBIG_PROFILE_PREDECESSOR_STATE_CHECKSUM_PATH=/run/fbig/predecessor/fbig-profile-clone-poststate-v1.tsv.sha256
    )
  else
    test -z "$predecessor_directory"
  fi

  set +e
  clone_compose run --rm --no-deps -T \
    --volume "$HISTORY_DIR:/run/fbig/history:ro" \
    --volume "$TARGET_DIR:/run/fbig/targets:ro" \
    --volume "$STATE_DIR:/run/fbig/state:ro" \
    --volume "$attempt_directory:/run/fbig/attempt" \
    "${predecessor[@]}" \
    -e UMI_FBIG_PROFILE_APPROVAL_MODE=clone_evidence \
    -e UMI_FBIG_PROFILE_CLONE_PHASE="$phase" \
    -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
    -e PLATFORMS=messenger,instagram \
    -e DRY_RUN="$dry_run" \
    -e UMI_FBIG_APPROVAL_MANIFEST_PATH=/run/fbig/history/fbig-approval-v2.tsv \
    -e UMI_FBIG_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-approval-v2.tsv.sha256 \
    -e UMI_FBIG_PROFILE_TARGETS_PATH=/run/fbig/targets/fbig-profile-targets-v1.tsv \
    -e UMI_FBIG_PROFILE_STATE_PATH=/run/fbig/state/fbig-profile-state-v1.tsv \
    -e UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH=/run/fbig/state/fbig-profile-state-v1.tsv.sha256 \
    -e UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME="$PRODUCTION_DATABASE" \
    -e UMI_FBIG_RUNTIME_REPOSITORY_COMMIT="$APP_COMMIT" \
    -e UMI_FBIG_RUNTIME_IMAGE_DIGEST="$APP_DIGEST" \
    -e UMI_FBIG_PROFILE_GRAPH_DELAY_MS="$PROFILE_GRAPH_DELAY_MS" \
    -e UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES="$PROFILE_MAX_CONVERSATION_PAGES" \
    -e UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS="$PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS" \
    -e UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES="$PROFILE_MAX_DOWNLOAD_BYTES" \
    -e UMI_FBIG_PROFILE_ATTEMPT_DIR=/run/fbig/attempt \
    -e UMI_FBIG_PROFILE_AVATAR_INTENT_DIR=/run/fbig/attempt/avatar-intents \
    rails bundle exec rake "umi:fbig:history_profiles[$INBOX_ID]" \
    2>&1 | tee "$attempt_directory/clone-profile.log"
  local statuses=("${PIPESTATUS[@]}")
  set -e
  test "${#statuses[@]}" -eq 2
  test "${statuses[0]}" -eq 0
  test "${statuses[1]}" -eq 0
  test "$(grep -c '^\[UMI-FBIG\] stage=history_profiles_summary ' "$attempt_directory/clone-profile.log")" -eq 1
  grep '^\[UMI-FBIG\] stage=history_profiles_summary ' \
    "$attempt_directory/clone-profile.log" >"$attempt_directory/clone-profile-summary.tsv"
  chmod 0400 "$attempt_directory/clone-profile.log" "$attempt_directory/clone-profile-summary.tsv"
  (
    set -o noclobber
    cd "$attempt_directory"
    sha256sum clone-profile.log >clone-profile.log.sha256
    sha256sum clone-profile-summary.tsv >clone-profile-summary.tsv.sha256
    chmod 0400 clone-profile.log.sha256 clone-profile-summary.tsv.sha256
  )
}

DRY_ATTEMPT="$CLONE_PROFILE_ROOT/dry"
APPLY_ATTEMPT="$CLONE_PROFILE_ROOT/apply"
IDEMPOTENCY_ATTEMPT="$CLONE_PROFILE_ROOT/idempotency"

PROFILE_DRY_DATABASE_BEFORE="$AUDIT_DIR/profile-dry-database-before.tsv"
PROFILE_DRY_STORAGE_BEFORE="$AUDIT_DIR/profile-dry-storage-before.manifest"
test ! -e "$PROFILE_DRY_DATABASE_BEFORE"
clone_database_fingerprint >"$PROFILE_DRY_DATABASE_BEFORE"
capture_clone_storage_manifest "$PROFILE_DRY_STORAGE_BEFORE"
verify_clone_history_state before-profile-dry

clone_profile_run dry true "$DRY_ATTEMPT"

PROFILE_DRY_DATABASE_AFTER="$AUDIT_DIR/profile-dry-database-after.tsv"
PROFILE_DRY_STORAGE_AFTER="$AUDIT_DIR/profile-dry-storage-after.manifest"
test ! -e "$PROFILE_DRY_DATABASE_AFTER"
clone_database_fingerprint >"$PROFILE_DRY_DATABASE_AFTER"
capture_clone_storage_manifest "$PROFILE_DRY_STORAGE_AFTER"
cmp -s "$PROFILE_DRY_DATABASE_BEFORE" "$PROFILE_DRY_DATABASE_AFTER"
cmp -s "$PROFILE_DRY_STORAGE_BEFORE" "$PROFILE_DRY_STORAGE_AFTER"
verify_clone_history_state after-profile-dry
chmod 0400 \
  "$PROFILE_DRY_DATABASE_BEFORE" "$PROFILE_DRY_DATABASE_AFTER" \
  "$PROFILE_DRY_STORAGE_BEFORE" "$PROFILE_DRY_STORAGE_AFTER"

clone_profile_run apply false "$APPLY_ATTEMPT"
verify_clone_history_state after-profile-apply
clone_profile_run idempotency false "$IDEMPOTENCY_ATTEMPT" "$APPLY_ATTEMPT"
verify_clone_history_state after-profile-idempotency
```

The dry and apply phases require the current clone prestate to byte-match the
sealed source state. Idempotency requires the exact apply poststate artifact;
the task rejects any other allowed state basename.

Each start and terminal summary must repeat the validated clone/production
database identities, repository commit, image digest, history SHA, source-state
SHA, phase, and predecessor-state SHA. Reject an approval whose six log/summary
hashes do not contain those exact identities. The dry run must not change clone
DB/storage. Apply may only replace exact
`Instagram user <last four source-id digits>` names, fill blank/absent
Instagram usernames and absent optional fields, and attach safe missing
avatars. Existing non-placeholder names, values including `false`/`0`, and
avatars must remain unchanged. It must create no Contact, ContactInbox,
Conversation, Message, or Attachment product row.

The final clone profile pass must have zero scalar/avatar writes and one
terminal success, unavailable, or blocking outcome for every stable target and
every sealed seed. Blocking outcomes are not approval. Preserve and hash the three
logs, terminal summaries, source state, attempt evidence, and stable-target
counts/fingerprints.

Verify every immutable input and clone evidence artifact before constructing
the approval. The three phases must bind the same release, history approval,
source state, stable target set, and settings. Only idempotency may bind a
predecessor state, and it must be the exact apply poststate:

```bash
SOURCE_PROFILE_STATE="$STATE_DIR/fbig-profile-state-v1.tsv"
SOURCE_PROFILE_STATE_CHECKSUM="$STATE_DIR/fbig-profile-state-v1.tsv.sha256"
HISTORY_APPROVAL_SHA256="$(sha256_file "$HISTORY_APPROVAL")"
SOURCE_PROFILE_STATE_SHA256="$(sha256_file "$SOURCE_PROFILE_STATE")"

(
  cd "$STATE_DIR"
  sha256sum --check "$(basename "$SOURCE_PROFILE_STATE_CHECKSUM")"
)
test "$(stat -c '%u:%a:%h' "$SOURCE_PROFILE_STATE")" = "0:400:1"
test "$(stat -c '%u:%a:%h' "$SOURCE_PROFILE_STATE_CHECKSUM")" = "0:400:1"

verify_profile_attempt() {
  local attempt_directory="$1"
  local phase="$2"
  local expected_dry_run="$3"
  local expected_write_complete="$4"
  local expected_predecessor_sha256="$5"
  local log="$attempt_directory/clone-profile.log"
  local summary="$attempt_directory/clone-profile-summary.tsv"
  local expected_prestate_sha256="$SOURCE_PROFILE_STATE_SHA256"
  local artifact
  local stage
  local key
  local expected
  if [[ "$expected_predecessor_sha256" != none ]]; then
    expected_prestate_sha256="$expected_predecessor_sha256"
  fi

  test ! -L "$attempt_directory"
  test "$(stat -c '%u:%a' "$attempt_directory")" = "0:700"
  (
    cd "$attempt_directory"
    sha256sum --check clone-profile.log.sha256
    sha256sum --check clone-profile-summary.tsv.sha256
    sha256sum --check fbig-profile-clone-prestate-v1.tsv.sha256
    sha256sum --check fbig-profile-clone-poststate-v1.tsv.sha256
    sha256sum --check fbig-profile-avatar-staging-v1.tsv.sha256
  )
  for artifact in \
    "$log" "$log.sha256" "$summary" "$summary.sha256" \
    "$attempt_directory/fbig-profile-clone-prestate-v1.tsv" \
    "$attempt_directory/fbig-profile-clone-prestate-v1.tsv.sha256" \
    "$attempt_directory/fbig-profile-clone-poststate-v1.tsv" \
    "$attempt_directory/fbig-profile-clone-poststate-v1.tsv.sha256" \
    "$attempt_directory/fbig-profile-avatar-staging-v1.tsv" \
    "$attempt_directory/fbig-profile-avatar-staging-v1.tsv.sha256"; do
    test ! -L "$artifact"
    test "$(stat -c '%u:%a:%h' "$artifact")" = "0:400:1"
  done

  test "$(grep -c '^\[UMI-FBIG\] stage=history_profiles_start ' "$log")" -eq 1
  test "$(grep -c '^\[UMI-FBIG\] stage=history_profiles_summary ' "$log")" -eq 1
  cmp -s "$summary" <(
    grep '^\[UMI-FBIG\] stage=history_profiles_summary ' "$log"
  )

  for stage in history_profiles_start history_profiles_summary; do
    while IFS=$'\t' read -r key expected; do
      test "$(stage_value "$log" "$stage" "$key")" = "$expected"
    done < <(
      printf '%s\t%s\n' \
        approval_mode clone_evidence \
        clone_phase "$phase" \
        database "$CLONE_DATABASE" \
        production_database "$PRODUCTION_DATABASE" \
        repository_commit "$APP_COMMIT" \
        image_digest "$APP_DIGEST" \
        history_manifest_sha256 "$HISTORY_APPROVAL_SHA256" \
        profile_approval_sha256 none \
        source_state_sha256 "$SOURCE_PROFILE_STATE_SHA256" \
        predecessor_state_sha256 "$expected_predecessor_sha256" \
        dry_run "$expected_dry_run"
    )
  done

  verify_seed_target_conservation "$log" "$summary"
  while IFS=$'\t' read -r key expected; do
    test "$(stage_value "$log" history_profiles_start "$key")" = "$expected"
  done < <(
    printf '%s\t%s\n' \
      inbox_id "$INBOX_ID" \
      platforms messenger,instagram \
      graph_delay_ms "$PROFILE_GRAPH_DELAY_MS" \
      max_conversation_pages "$PROFILE_MAX_CONVERSATION_PAGES" \
      max_rate_limit_wait_seconds "$PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS" \
      max_download_bytes "$PROFILE_MAX_DOWNLOAD_BYTES"
  )

  while IFS=$'\t' read -r key expected; do
    test "$(stage_value "$summary" history_profiles_summary "$key")" = "$expected"
  done < <(
    printf '%s\t%s\n' \
      scan_complete true \
      write_complete "$expected_write_complete" \
      exit_failures 0 \
      lock_loss 0 \
      profile_errors 0 \
      avatar_failures 0 \
      messenger_targets_blocking 0 \
      instagram_targets_blocking 0
  )
  test "$(stage_value "$summary" history_profiles_summary prestate_sha256)" = \
    "$expected_prestate_sha256"
  test "$(stage_value "$summary" history_profiles_summary poststate_sha256)" = \
    "$(sha256_file "$attempt_directory/fbig-profile-clone-poststate-v1.tsv")"
  test "$(stage_value "$summary" history_profiles_summary avatar_staging_sha256)" = \
    "$(sha256_file "$attempt_directory/fbig-profile-avatar-staging-v1.tsv")"

  [[ "$(stage_value "$summary" history_profiles_summary stable_messenger_targets)" =~ ^[1-9][0-9]*$ ]]
  [[ "$(stage_value "$summary" history_profiles_summary stable_instagram_targets)" =~ ^[1-9][0-9]*$ ]]
  [[ "$(stage_value "$summary" history_profiles_summary stable_messenger_fingerprint)" =~ ^[0-9a-f]{64}$ ]]
  [[ "$(stage_value "$summary" history_profiles_summary stable_instagram_fingerprint)" =~ ^[0-9a-f]{64}$ ]]
}

APPLY_POSTSTATE_SHA256="$(
  sha256_file "$APPLY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv"
)"
verify_profile_attempt "$DRY_ATTEMPT" dry true not_applicable none
verify_profile_attempt "$APPLY_ATTEMPT" apply false true none
verify_profile_attempt \
  "$IDEMPOTENCY_ATTEMPT" idempotency false true "$APPLY_POSTSTATE_SHA256"
cmp -s \
  "$DRY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv" \
  "$DRY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv"
cmp -s \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv"

for key in \
  stable_messenger_targets stable_messenger_fingerprint \
  stable_instagram_targets stable_instagram_fingerprint; do
  DRY_VALUE="$(stage_value "$DRY_ATTEMPT/clone-profile-summary.tsv" history_profiles_summary "$key")"
  APPLY_VALUE="$(stage_value "$APPLY_ATTEMPT/clone-profile-summary.tsv" history_profiles_summary "$key")"
  IDEMPOTENCY_VALUE="$(
    stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" history_profiles_summary "$key"
  )"
  test "$DRY_VALUE" = "$APPLY_VALUE"
  test "$APPLY_VALUE" = "$IDEMPOTENCY_VALUE"
done

for counter in \
  scalar_changes_applied name_changes_applied username_changes_applied \
  optional_changes_applied avatars_attached; do
  test "$(
    stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
      history_profiles_summary "$counter"
  )" = 0
done
```

Construct the initial profile approval with both predecessor fields `none` in
the parser's exact 31-field order. Recompute every SHA from the sealed
artifact, seal the approval before loading it, and validate the complete
binding and current stable target set through the accepted merged image:

```bash
PROFILE_APPROVAL="$PROFILE_DIR/fbig-profile-approval-v1.tsv"
PROFILE_APPROVAL_CHECKSUM="$PROFILE_DIR/fbig-profile-approval-v1.tsv.sha256"
MESSENGER_STABLE_TARGET_COUNT="$(
  stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
    history_profiles_summary stable_messenger_targets
)"
MESSENGER_STABLE_TARGET_FINGERPRINT="$(
  stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
    history_profiles_summary stable_messenger_fingerprint
)"
INSTAGRAM_STABLE_TARGET_COUNT="$(
  stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
    history_profiles_summary stable_instagram_targets
)"
INSTAGRAM_STABLE_TARGET_FINGERPRINT="$(
  stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
    history_profiles_summary stable_instagram_fingerprint
)"

test ! -e "$PROFILE_APPROVAL"
test ! -e "$PROFILE_APPROVAL_CHECKSUM"
PROFILE_APPROVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(
  set -o noclobber
  {
    printf 'schema_version\t1\n'
    printf 'history_manifest_sha256\t%s\n' "$HISTORY_APPROVAL_SHA256"
    printf 'repository_commit\t%s\n' "$APP_COMMIT"
    printf 'image_digest\t%s\n' "$APP_DIGEST"
    printf 'clone_database_name\t%s\n' "$CLONE_DATABASE"
    printf 'production_database_name\t%s\n' "$PRODUCTION_DATABASE"
    printf 'account_id\t%s\n' "$(manifest_value "$HISTORY_APPROVAL" account_id)"
    printf 'inbox_id\t%s\n' "$(manifest_value "$HISTORY_APPROVAL" inbox_id)"
    printf 'facebook_page_id\t%s\n' "$(manifest_value "$HISTORY_APPROVAL" facebook_page_id)"
    printf 'instagram_business_id\t%s\n' "$(manifest_value "$HISTORY_APPROVAL" instagram_business_id)"
    printf 'platforms\tmessenger,instagram\n'
    printf 'graph_delay_ms\t%s\n' "$PROFILE_GRAPH_DELAY_MS"
    printf 'max_conversation_pages\t%s\n' "$PROFILE_MAX_CONVERSATION_PAGES"
    printf 'max_rate_limit_wait_seconds\t%s\n' "$PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS"
    printf 'max_avatar_download_bytes\t%s\n' "$PROFILE_MAX_DOWNLOAD_BYTES"
    printf 'placeholder_targets_sha256\t%s\n' "$PLACEHOLDER_TARGETS_SHA256"
    printf 'predecessor_profile_approval_sha256\tnone\n'
    printf 'predecessor_production_attempt_sha256\tnone\n'
    printf 'source_profile_state_sha256\t%s\n' "$SOURCE_PROFILE_STATE_SHA256"
    printf 'messenger_stable_target_count\t%s\n' "$MESSENGER_STABLE_TARGET_COUNT"
    printf 'messenger_stable_target_fingerprint\t%s\n' "$MESSENGER_STABLE_TARGET_FINGERPRINT"
    printf 'instagram_stable_target_count\t%s\n' "$INSTAGRAM_STABLE_TARGET_COUNT"
    printf 'instagram_stable_target_fingerprint\t%s\n' "$INSTAGRAM_STABLE_TARGET_FINGERPRINT"
    printf 'clone_profile_dry_log_sha256\t%s\n' "$(sha256_file "$DRY_ATTEMPT/clone-profile.log")"
    printf 'clone_profile_dry_summary_sha256\t%s\n' "$(sha256_file "$DRY_ATTEMPT/clone-profile-summary.tsv")"
    printf 'clone_profile_apply_log_sha256\t%s\n' "$(sha256_file "$APPLY_ATTEMPT/clone-profile.log")"
    printf 'clone_profile_apply_summary_sha256\t%s\n' "$(sha256_file "$APPLY_ATTEMPT/clone-profile-summary.tsv")"
    printf 'clone_profile_idempotency_log_sha256\t%s\n' "$(sha256_file "$IDEMPOTENCY_ATTEMPT/clone-profile.log")"
    printf 'clone_profile_idempotency_summary_sha256\t%s\n' "$(sha256_file "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv")"
    printf 'approved_by\t%s\n' "$APPROVED_BY"
    printf 'approved_at\t%s\n' "$PROFILE_APPROVED_AT"
  } >"$PROFILE_APPROVAL"
)
(
  set -o noclobber
  cd "$PROFILE_DIR"
  sha256sum "$(basename "$PROFILE_APPROVAL")" >"$(basename "$PROFILE_APPROVAL_CHECKSUM")"
)
chmod 0400 "$PROFILE_APPROVAL" "$PROFILE_APPROVAL_CHECKSUM"
test "$(stat -c '%u:%a:%h' "$PROFILE_APPROVAL")" = "0:400:1"
test "$(stat -c '%u:%a:%h' "$PROFILE_APPROVAL_CHECKSUM")" = "0:400:1"

test "$(clone_compose config --images | grep -Fxc "$APP_DIGEST")" -eq 1
clone_compose run --rm --no-deps -T \
  --volume "$HISTORY_DIR:/run/fbig/history:ro" \
  --volume "$PROFILE_DIR:/run/fbig/profile:ro" \
  --volume "$TARGET_DIR:/run/fbig/targets:ro" \
  --volume "$STATE_DIR:/run/fbig/state:ro" \
  --volume "$CLONE_PROFILE_ROOT:/run/fbig/clone-profile:ro" \
  -e UMI_FBIG_EXPECTED_COMMIT="$APP_COMMIT" \
  -e UMI_FBIG_EXPECTED_DIGEST="$APP_DIGEST" \
  -e UMI_FBIG_EXPECTED_CLONE_DATABASE="$CLONE_DATABASE" \
  -e UMI_FBIG_EXPECTED_PRODUCTION_DATABASE="$PRODUCTION_DATABASE" \
  -e UMI_FBIG_EXPECTED_INBOX_ID="$INBOX_ID" \
  -e UMI_FBIG_EXPECTED_GRAPH_DELAY_MS="$PROFILE_GRAPH_DELAY_MS" \
  -e UMI_FBIG_EXPECTED_MAX_CONVERSATION_PAGES="$PROFILE_MAX_CONVERSATION_PAGES" \
  -e UMI_FBIG_EXPECTED_MAX_RATE_LIMIT_WAIT_SECONDS="$PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS" \
  -e UMI_FBIG_EXPECTED_MAX_DOWNLOAD_BYTES="$PROFILE_MAX_DOWNLOAD_BYTES" \
  rails bundle exec rails runner '
    require "digest"
    history = Umi::Fbig::HistoryApprovalManifest.load(
      manifest_path: "/run/fbig/history/fbig-approval-v2.tsv",
      checksum_path: "/run/fbig/history/fbig-approval-v2.tsv.sha256"
    )
    profile = Umi::Fbig::ProfileApprovalManifest.load(
      manifest_path: "/run/fbig/profile/fbig-profile-approval-v1.tsv",
      checksum_path: "/run/fbig/profile/fbig-profile-approval-v1.tsv.sha256"
    )
    targets = Umi::Fbig::ProfileTargetManifest.load(
      path: "/run/fbig/targets/fbig-profile-targets-v1.tsv",
      expected_sha256: profile.placeholder_targets_sha256
    )
    source_state = Umi::Fbig::ProfileStateSnapshot.load(
      path: "/run/fbig/state/fbig-profile-state-v1.tsv",
      checksum_path: "/run/fbig/state/fbig-profile-state-v1.tsv.sha256"
    )
    image_commit = File.binread("/app/.git_sha").strip
    actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
    inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_EXPECTED_INBOX_ID"), 10))
    evidence_paths = {
      "clone_profile_dry_log_sha256" => "/run/fbig/clone-profile/dry/clone-profile.log",
      "clone_profile_dry_summary_sha256" => "/run/fbig/clone-profile/dry/clone-profile-summary.tsv",
      "clone_profile_apply_log_sha256" => "/run/fbig/clone-profile/apply/clone-profile.log",
      "clone_profile_apply_summary_sha256" => "/run/fbig/clone-profile/apply/clone-profile-summary.tsv",
      "clone_profile_idempotency_log_sha256" => "/run/fbig/clone-profile/idempotency/clone-profile.log",
      "clone_profile_idempotency_summary_sha256" =>
        "/run/fbig/clone-profile/idempotency/clone-profile-summary.tsv"
    }
    evidence_valid = evidence_paths.all? do |field, path|
      File.file?(path) && Digest::SHA256.file(path).hexdigest == profile.values.fetch(field)
    end
    scope_valid = profile.account_id == inbox.account_id &&
                  profile.inbox_id == inbox.id &&
                  profile.facebook_page_id.to_s == inbox.channel.page_id.to_s &&
                  profile.instagram_business_id.to_s == inbox.channel.instagram_id.to_s &&
                  source_state.account_id == inbox.account_id &&
                  source_state.inbox_id == inbox.id &&
                  profile.account_id == history.account_id &&
                  profile.inbox_id == history.inbox_id &&
                  profile.facebook_page_id == history.facebook_page_id &&
                  profile.instagram_business_id == history.instagram_business_id
    identity_valid =
      actual_database == ENV.fetch("UMI_FBIG_EXPECTED_CLONE_DATABASE") &&
      image_commit == ENV.fetch("UMI_FBIG_EXPECTED_COMMIT") &&
      profile.clone_database_name == actual_database &&
      history.clone_database_name == actual_database &&
      profile.production_database_name == ENV.fetch("UMI_FBIG_EXPECTED_PRODUCTION_DATABASE") &&
      profile.repository_commit == ENV.fetch("UMI_FBIG_EXPECTED_COMMIT") &&
      profile.image_digest == ENV.fetch("UMI_FBIG_EXPECTED_DIGEST") &&
      history.repository_commit == profile.repository_commit &&
      history.image_digest == profile.image_digest &&
      profile.history_manifest_sha256 == history.sha256 &&
      profile.placeholder_targets_sha256 == history.placeholder_targets_sha256 &&
      profile.source_profile_state_sha256 == source_state.sha256 &&
      profile.predecessor_profile_approval_sha256 == "none" &&
      profile.predecessor_production_attempt_sha256 == "none" &&
      profile.graph_delay_ms == Integer(ENV.fetch("UMI_FBIG_EXPECTED_GRAPH_DELAY_MS"), 10) &&
      profile.max_conversation_pages ==
        Integer(ENV.fetch("UMI_FBIG_EXPECTED_MAX_CONVERSATION_PAGES"), 10) &&
      profile.max_rate_limit_wait_seconds ==
        Integer(ENV.fetch("UMI_FBIG_EXPECTED_MAX_RATE_LIMIT_WAIT_SECONDS"), 10) &&
      profile.max_avatar_download_bytes ==
        Integer(ENV.fetch("UMI_FBIG_EXPECTED_MAX_DOWNLOAD_BYTES"), 10) &&
      profile.platforms == %w[messenger instagram] &&
      targets.any?
    abort("profile approval identity or evidence mismatch") unless
      evidence_valid && scope_valid && identity_valid

    observed = Umi::Fbig::HistoryProfileBackfillService.stable_target_summary(
      inbox,
      platforms: profile.platforms,
      history_configuration: {
        "since" => history.since,
        "before" => history.values.fetch("before"),
        "outbound_policy" => history.outbound_policy
      },
      seed_targets: targets
    )
    profile.platforms.each do |platform|
      expected_count = profile.public_send("#{platform}_stable_target_count")
      expected_fingerprint = profile.public_send("#{platform}_stable_target_fingerprint")
      current = observed.fetch(platform)
      abort("stable profile target set mismatch") unless
        current[:count] == expected_count && current[:fingerprint] == expected_fingerprint
    end
    puts "[UMI-FBIG] stage=profile_approval_validated sha256=#{profile.sha256}"
  '
```

The clone-only Redis must not survive into deployment or any production
wrapper. Stop and remove only that service from the combined project; do not
run `down`, and retain the clone database, storage, override, and sealed
evidence for audit:

```bash
clone_compose stop --timeout 30 clone-redis
clone_compose rm --force --stop clone-redis
test -z "$(clone_compose ps --all -q clone-redis)"
test -z "$(docker ps --all --quiet --filter id="$CLONE_REDIS_CONTAINER")"
CLONE_REDIS_ACTIVE=false
trap - EXIT
```

Only after every clone history/profile check above passes and clone Redis is
gone, seal one terminal acceptance record. New acceptance runs install the
program before launch as a root-owned, single-link `0400` file inside a
root-owned `0700` directory. The already-running R4 invocation is accepted only
because its exact systemd `InvocationID` and `ExecStart` path are bound, the
live `/tmp` program was independently hashed and changed to root-owned
single-link `0400` before completion, and the same bytes were copied into the
protected archive with an exact checksum. Any different invocation must use
the protected pre-launch layout. Record the loaded unit, invocation, live path,
protected archive, and both reviewed program/finalizer SHAs rather than
trusting a reusable unit name or exit status alone:

```bash
set -Eeuo pipefail
umask 077

INBOX_ID='<same numeric inbox id>'
PRODUCTION_DATABASE='chatwoot_production'
CLONE_DATABASE='<same clone database>'
APP_COMMIT='<same 40 lowercase hex merged commit>'
APP_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<same accepted 64-hex digest>'
AUDIT_DIR='/opt/umi/fbig-audit/<same acceptance id>'
HISTORY_DIR="$AUDIT_DIR/history-approval"
PROFILE_DIR="$AUDIT_DIR/profile-approval"
TARGET_DIR="$AUDIT_DIR/profile-targets"
CLONE_BASELINE="$AUDIT_DIR/clone-scoped-baseline.txt"
HISTORY_APPROVAL="$HISTORY_DIR/fbig-approval-v2.tsv"
PROFILE_APPROVAL="$PROFILE_DIR/fbig-profile-approval-v1.tsv"
UNRECOVERABLE_SIDECAR="$HISTORY_DIR/fbig-unrecoverable-envelope-v1.tsv"
IDEMPOTENCY_ATTEMPT="$AUDIT_DIR/clone-profile/idempotency"
STORAGE_HELPER='/opt/umi/chatwoot/bin/fbig_storage_artifact.py'
R4_ACCEPTANCE_UNIT='<loaded acceptance unit>'
R4_ACCEPTANCE_INVOCATION_ID='<32 lowercase hex invocation id>'
R4_ACCEPTANCE_EXEC_SCRIPT='<exact unit ExecStart script path>'
R4_ACCEPTANCE_SCRIPT_ARCHIVE='<protected root-only copy of that exact script>'
EXPECTED_R4_ACCEPTANCE_SCRIPT_SHA256='<reviewed 64-hex acceptance-program SHA>'
R4_ACCEPTANCE_MANIFEST="$AUDIT_DIR/fbig-r4-acceptance-complete-v1.tsv"
R4_ACCEPTANCE_CHECKSUM="${R4_ACCEPTANCE_MANIFEST}.sha256"

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

require_root_artifact() {
  local path="$1"
  local expected_basename="$2"
  local directory
  test "$path" = "$(realpath -e -- "$path")"
  test "$(basename "$path")" = "$expected_basename"
  test -f "$path"
  test ! -L "$path"
  test "$(stat -c '%u:%a:%h' "$path")" = '0:400:1'
  directory="$(dirname "$path")"
  test "$directory" = "$(realpath -e -- "$directory")"
  test ! -L "$directory"
  test "$(stat -c '%u:%a' "$directory")" = '0:700'
}

verify_checksum() {
  local artifact="$1"
  local checksum="$2"
  local expected
  expected="$(printf '%s  %s\n' "$(sha256_file "$artifact")" "$(basename "$artifact")")"
  test "$(cat "$checksum")" = "$expected"
}

require_ordered_fields() {
  local path="$1"
  shift
  local -a expected=("$@")
  local -a observed
  local field_index
  mapfile -t observed < <(awk -F $'\t' 'NF == 2 { print $1 }' "$path")
  test "${#observed[@]}" -eq "${#expected[@]}"
  for field_index in "${!expected[@]}"; do
    test "${observed[$field_index]}" = "${expected[$field_index]}"
  done
}

FINALIZER_PROGRAM="${BASH_SOURCE[0]}"
FINALIZER_CHECKSUM="${FINALIZER_PROGRAM}.sha256"
require_root_artifact "$FINALIZER_PROGRAM" "$(basename "$FINALIZER_PROGRAM")"
require_root_artifact "$FINALIZER_CHECKSUM" "$(basename "$FINALIZER_CHECKSUM")"
verify_checksum "$FINALIZER_PROGRAM" "$FINALIZER_CHECKSUM"
R4_ACCEPTANCE_FINALIZER_SHA256="$(sha256_file "$FINALIZER_PROGRAM")"

[[ "$R4_ACCEPTANCE_INVOCATION_ID" =~ ^[0-9a-f]{32}$ ]]
[[ "$EXPECTED_R4_ACCEPTANCE_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ ]]
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=LoadState --value)" = loaded
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=ActiveState --value)" = inactive
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=SubState --value)" = dead
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=Result --value)" = success
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=ExecMainStatus --value)" = 0
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=InvocationID --value)" = \
  "$R4_ACCEPTANCE_INVOCATION_ID"
systemctl show "$R4_ACCEPTANCE_UNIT" --property=ExecStart --value |
  grep -Fq "argv[]=/bin/bash $R4_ACCEPTANCE_EXEC_SCRIPT ;"

test "$R4_ACCEPTANCE_EXEC_SCRIPT" = \
  "$(realpath -e -- "$R4_ACCEPTANCE_EXEC_SCRIPT")"
test -f "$R4_ACCEPTANCE_EXEC_SCRIPT"
test ! -L "$R4_ACCEPTANCE_EXEC_SCRIPT"
test "$(stat -c '%u:%a:%h' "$R4_ACCEPTANCE_EXEC_SCRIPT")" = '0:400:1'
R4_ACCEPTANCE_SCRIPT_SHA256="$(sha256_file "$R4_ACCEPTANCE_EXEC_SCRIPT")"
test "$R4_ACCEPTANCE_SCRIPT_SHA256" = "$EXPECTED_R4_ACCEPTANCE_SCRIPT_SHA256"
require_root_artifact \
  "$R4_ACCEPTANCE_SCRIPT_ARCHIVE" "$(basename "$R4_ACCEPTANCE_SCRIPT_ARCHIVE")"
require_root_artifact \
  "${R4_ACCEPTANCE_SCRIPT_ARCHIVE}.sha256" \
  "$(basename "${R4_ACCEPTANCE_SCRIPT_ARCHIVE}.sha256")"
verify_checksum \
  "$R4_ACCEPTANCE_SCRIPT_ARCHIVE" "${R4_ACCEPTANCE_SCRIPT_ARCHIVE}.sha256"
test "$(sha256_file "$R4_ACCEPTANCE_SCRIPT_ARCHIVE")" = \
  "$R4_ACCEPTANCE_SCRIPT_SHA256"

for artifact in \
  "$CLONE_BASELINE" \
  "$HISTORY_APPROVAL" "${HISTORY_APPROVAL}.sha256" \
  "$PROFILE_APPROVAL" "${PROFILE_APPROVAL}.sha256" \
  "$TARGET_DIR/fbig-profile-targets-v1.tsv" \
  "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
  "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
  "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv.sha256" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv.sha256" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv.sha256" \
  "$UNRECOVERABLE_SIDECAR" "${UNRECOVERABLE_SIDECAR}.sha256"; do
  require_root_artifact "$artifact" "$(basename "$artifact")"
done
verify_checksum "$HISTORY_APPROVAL" "${HISTORY_APPROVAL}.sha256"
verify_checksum "$PROFILE_APPROVAL" "${PROFILE_APPROVAL}.sha256"
verify_checksum "$UNRECOVERABLE_SIDECAR" "${UNRECOVERABLE_SIDECAR}.sha256"
verify_checksum \
  "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
  "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv.sha256"
verify_checksum \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv.sha256"
verify_checksum \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv.sha256"
test "$(manifest_value "$HISTORY_APPROVAL" repository_commit)" = "$APP_COMMIT"
test "$(manifest_value "$HISTORY_APPROVAL" image_digest)" = "$APP_DIGEST"
test "$(manifest_value "$HISTORY_APPROVAL" clone_database_name)" = "$CLONE_DATABASE"
test "$(manifest_value "$HISTORY_APPROVAL" inbox_id)" = "$INBOX_ID"
test "$(manifest_value "$PROFILE_APPROVAL" repository_commit)" = "$APP_COMMIT"
test "$(manifest_value "$PROFILE_APPROVAL" image_digest)" = "$APP_DIGEST"
test "$(manifest_value "$PROFILE_APPROVAL" clone_database_name)" = "$CLONE_DATABASE"
test "$(manifest_value "$PROFILE_APPROVAL" production_database_name)" = \
  "$PRODUCTION_DATABASE"
test "$(manifest_value "$PROFILE_APPROVAL" inbox_id)" = "$INBOX_ID"
test "$(manifest_value "$PROFILE_APPROVAL" history_manifest_sha256)" = \
  "$(sha256_file "$HISTORY_APPROVAL")"
test "$(manifest_value "$PROFILE_APPROVAL" placeholder_targets_sha256)" = \
  "$(sha256_file "$TARGET_DIR/fbig-profile-targets-v1.tsv")"
test "$(manifest_value "$PROFILE_APPROVAL" clone_profile_idempotency_summary_sha256)" = \
  "$(sha256_file "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv")"
for counter in \
  imported_contacts imported_archives imported_incoming imported_outgoing \
  imported_messages imported_attachments marker_normalizations \
  history_evidence_changes_applied messenger_history_evidence_changes_applied \
  instagram_history_evidence_changes_applied profile_changes_applied \
  avatars_attached avatars_raced contentless_acceptance_mismatches \
  unavailable_message_thread_acceptance_mismatches \
  partially_paginated_threads uncategorized_threads \
  ambiguous_senders foreign_source_id_anomalies platform_failures \
  retry_exhaustion authentication_failures lock_loss reindex_failures \
  download_budget_exhaustions exit_failures; do
  test "$(
    stage_value "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
      history_import_summary "$counter"
  )" = 0
done
EXPECTED_CLASSIFIED_OMISSIONS="$(
  (
    manifest_value "$UNRECOVERABLE_SIDECAR" count
    manifest_value "$HISTORY_APPROVAL" messenger_unavailable_message_thread_count
    manifest_value "$HISTORY_APPROVAL" instagram_unavailable_message_thread_count
  ) | awk '{ total += $1 } END { print total + 0 }'
)"
test "$(stage_value "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
  history_import_summary failed_threads)" = 0
test "$(stage_value "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
  history_import_summary classified_omitted_threads)" = "$EXPECTED_CLASSIFIED_OMISSIONS"
test "$(stage_value "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
  history_import_summary listed_threads)" -eq \
  "$(( $(stage_value "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
           history_import_summary message_cursor_exhausted_threads) + \
       EXPECTED_CLASSIFIED_OMISSIONS ))"
for counter in \
  scalar_changes_applied name_changes_applied username_changes_applied \
  optional_changes_applied avatars_attached avatar_bytes mirror_jobs \
  exit_failures lock_loss profile_errors avatar_failures \
  messenger_targets_blocking instagram_targets_blocking seed_targets_blocking; do
  test "$(
    stage_value "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv" \
      history_profiles_summary "$counter"
  )" = 0
done
cmp -s \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-prestate-v1.tsv" \
  "$IDEMPOTENCY_ATTEMPT/fbig-profile-clone-poststate-v1.tsv"
test -z "$(
  docker ps --all --quiet --filter label=com.docker.compose.service=clone-redis
)"

verify_terminal_manifest() {
  local manifest="$1"
  require_ordered_fields "$manifest" \
    schema_version acceptance_id acceptance_unit acceptance_invocation_id \
    acceptance_script_path acceptance_script_archive_path \
    acceptance_script_sha256 acceptance_finalizer_path \
    acceptance_finalizer_sha256 repository_commit image_digest \
    clone_database_name production_database_name inbox_id \
    history_approval_sha256 profile_approval_sha256 profile_targets_sha256 \
    clone_baseline_sha256 history_idempotency_summary_sha256 \
    profile_idempotency_summary_sha256 unrecoverable_sidecar_sha256 completed_at
  test "$(manifest_value "$manifest" schema_version)" = 1
  test "$(manifest_value "$manifest" acceptance_id)" = "$(basename "$AUDIT_DIR")"
  test "$(manifest_value "$manifest" acceptance_unit)" = "$R4_ACCEPTANCE_UNIT"
  test "$(manifest_value "$manifest" acceptance_invocation_id)" = \
    "$R4_ACCEPTANCE_INVOCATION_ID"
  test "$(manifest_value "$manifest" acceptance_script_path)" = \
    "$R4_ACCEPTANCE_EXEC_SCRIPT"
  test "$(manifest_value "$manifest" acceptance_script_archive_path)" = \
    "$R4_ACCEPTANCE_SCRIPT_ARCHIVE"
  test "$(manifest_value "$manifest" acceptance_script_sha256)" = \
    "$R4_ACCEPTANCE_SCRIPT_SHA256"
  test "$(manifest_value "$manifest" acceptance_finalizer_path)" = \
    "$FINALIZER_PROGRAM"
  test "$(manifest_value "$manifest" acceptance_finalizer_sha256)" = \
    "$R4_ACCEPTANCE_FINALIZER_SHA256"
  test "$(manifest_value "$manifest" repository_commit)" = "$APP_COMMIT"
  test "$(manifest_value "$manifest" image_digest)" = "$APP_DIGEST"
  test "$(manifest_value "$manifest" clone_database_name)" = "$CLONE_DATABASE"
  test "$(manifest_value "$manifest" production_database_name)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$manifest" inbox_id)" = "$INBOX_ID"
  test "$(manifest_value "$manifest" history_approval_sha256)" = \
    "$(sha256_file "$HISTORY_APPROVAL")"
  test "$(manifest_value "$manifest" profile_approval_sha256)" = \
    "$(sha256_file "$PROFILE_APPROVAL")"
  test "$(manifest_value "$manifest" profile_targets_sha256)" = \
    "$(sha256_file "$TARGET_DIR/fbig-profile-targets-v1.tsv")"
  test "$(manifest_value "$manifest" clone_baseline_sha256)" = \
    "$(sha256_file "$CLONE_BASELINE")"
  test "$(manifest_value "$manifest" history_idempotency_summary_sha256)" = \
    "$(sha256_file "$AUDIT_DIR/history-all-idempotency-summary.tsv")"
  test "$(manifest_value "$manifest" profile_idempotency_summary_sha256)" = \
    "$(sha256_file "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv")"
  test "$(manifest_value "$manifest" unrecoverable_sidecar_sha256)" = \
    "$(sha256_file "$UNRECOVERABLE_SIDECAR")"
  [[ "$(manifest_value "$manifest" completed_at)" =~ \
    ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

if [[ -e "$R4_ACCEPTANCE_MANIFEST" ]]; then
  test ! -e "$R4_ACCEPTANCE_CHECKSUM"
  require_root_artifact \
    "$R4_ACCEPTANCE_MANIFEST" "$(basename "$R4_ACCEPTANCE_MANIFEST")"
  verify_terminal_manifest "$R4_ACCEPTANCE_MANIFEST"
  R4_ACCEPTANCE_CHECKSUM_RESUME="${R4_ACCEPTANCE_CHECKSUM}.$$.resume"
  printf '%s  %s\n' \
    "$(sha256_file "$R4_ACCEPTANCE_MANIFEST")" \
    "$(basename "$R4_ACCEPTANCE_MANIFEST")" \
    >"$R4_ACCEPTANCE_CHECKSUM_RESUME"
  chmod 0400 "$R4_ACCEPTANCE_CHECKSUM_RESUME"
  "$STORAGE_HELPER" fsync "$R4_ACCEPTANCE_CHECKSUM_RESUME"
  mv "$R4_ACCEPTANCE_CHECKSUM_RESUME" "$R4_ACCEPTANCE_CHECKSUM"
  "$STORAGE_HELPER" fsync "$AUDIT_DIR"
  require_root_artifact \
    "$R4_ACCEPTANCE_CHECKSUM" "$(basename "$R4_ACCEPTANCE_CHECKSUM")"
  verify_checksum "$R4_ACCEPTANCE_MANIFEST" "$R4_ACCEPTANCE_CHECKSUM"
  exit 0
fi
test ! -e "$R4_ACCEPTANCE_CHECKSUM"

R4_ACCEPTANCE_TEMPORARY="${R4_ACCEPTANCE_MANIFEST}.$$.tmp"
R4_ACCEPTANCE_CHECKSUM_TEMPORARY="${R4_ACCEPTANCE_CHECKSUM}.$$.tmp"
(
  set -o noclobber
  {
    printf 'schema_version\t1\n'
    printf 'acceptance_id\t%s\n' "$(basename "$AUDIT_DIR")"
    printf 'acceptance_unit\t%s\n' "$R4_ACCEPTANCE_UNIT"
    printf 'acceptance_invocation_id\t%s\n' "$R4_ACCEPTANCE_INVOCATION_ID"
    printf 'acceptance_script_path\t%s\n' "$R4_ACCEPTANCE_EXEC_SCRIPT"
    printf 'acceptance_script_archive_path\t%s\n' \
      "$R4_ACCEPTANCE_SCRIPT_ARCHIVE"
    printf 'acceptance_script_sha256\t%s\n' "$R4_ACCEPTANCE_SCRIPT_SHA256"
    printf 'acceptance_finalizer_path\t%s\n' "$FINALIZER_PROGRAM"
    printf 'acceptance_finalizer_sha256\t%s\n' "$R4_ACCEPTANCE_FINALIZER_SHA256"
    printf 'repository_commit\t%s\n' "$APP_COMMIT"
    printf 'image_digest\t%s\n' "$APP_DIGEST"
    printf 'clone_database_name\t%s\n' "$CLONE_DATABASE"
    printf 'production_database_name\t%s\n' "$PRODUCTION_DATABASE"
    printf 'inbox_id\t%s\n' "$INBOX_ID"
    printf 'history_approval_sha256\t%s\n' "$(sha256_file "$HISTORY_APPROVAL")"
    printf 'profile_approval_sha256\t%s\n' "$(sha256_file "$PROFILE_APPROVAL")"
    printf 'profile_targets_sha256\t%s\n' \
      "$(sha256_file "$TARGET_DIR/fbig-profile-targets-v1.tsv")"
    printf 'clone_baseline_sha256\t%s\n' "$(sha256_file "$CLONE_BASELINE")"
    printf 'history_idempotency_summary_sha256\t%s\n' \
      "$(sha256_file "$AUDIT_DIR/history-all-idempotency-summary.tsv")"
    printf 'profile_idempotency_summary_sha256\t%s\n' \
      "$(sha256_file "$IDEMPOTENCY_ATTEMPT/clone-profile-summary.tsv")"
    printf 'unrecoverable_sidecar_sha256\t%s\n' \
      "$(sha256_file "$UNRECOVERABLE_SIDECAR")"
    printf 'completed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$R4_ACCEPTANCE_TEMPORARY"
)
chmod 0400 "$R4_ACCEPTANCE_TEMPORARY"
"$STORAGE_HELPER" fsync "$R4_ACCEPTANCE_TEMPORARY"
printf '%s  %s\n' \
  "$(sha256_file "$R4_ACCEPTANCE_TEMPORARY")" \
  "$(basename "$R4_ACCEPTANCE_MANIFEST")" \
  >"$R4_ACCEPTANCE_CHECKSUM_TEMPORARY"
chmod 0400 "$R4_ACCEPTANCE_CHECKSUM_TEMPORARY"
"$STORAGE_HELPER" fsync "$R4_ACCEPTANCE_CHECKSUM_TEMPORARY"
mv "$R4_ACCEPTANCE_TEMPORARY" "$R4_ACCEPTANCE_MANIFEST"
mv "$R4_ACCEPTANCE_CHECKSUM_TEMPORARY" "$R4_ACCEPTANCE_CHECKSUM"
"$STORAGE_HELPER" fsync "$AUDIT_DIR"
require_root_artifact \
  "$R4_ACCEPTANCE_MANIFEST" "$(basename "$R4_ACCEPTANCE_MANIFEST")"
require_root_artifact \
  "$R4_ACCEPTANCE_CHECKSUM" "$(basename "$R4_ACCEPTANCE_CHECKSUM")"
verify_checksum "$R4_ACCEPTANCE_MANIFEST" "$R4_ACCEPTANCE_CHECKSUM"
verify_terminal_manifest "$R4_ACCEPTANCE_MANIFEST"
```

## 8. Pin and deploy the accepted merged digest

In `umi-vps-infra`, set:

```yaml
chatwoot_version: "umi-latest@sha256:<accepted 64-hex digest>"
```

The Ansible role rejects a value without `@sha256:`. It renders inert candidate
files, then holds `/run/lock/umi-fbig/production.lock` continuously while it
installs the live Compose/environment/Caddy configuration, pulls/starts the
stack, and verifies digest and readiness. It cannot overlap a migration
backup, history command, profile attempt, or recovery. Commit and push the
immutable pin, then:

```bash
cd ansible
ansible-playbook site.yml --tags chatwoot
```

The Rails entrypoint does not run migrations. On the VPS, use a root shell,
validate the shared lock path as described in section 4, acquire it, and run
the migration explicitly before creating any fixed production evidence:

```bash
set -Eeuo pipefail
APP_COMMIT='<same accepted 40-hex commit>'
APP_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<same accepted 64-hex digest>'
PRODUCTION_DATABASE='chatwoot_production'
PRODUCTION_MIGRATION='20260724000000'
PRODUCTION_LOCK='/run/lock/umi-fbig/production.lock'
cd /opt/umi/chatwoot

LOCK_PARENT='/run/lock'
LOCK_DIRECTORY="$(dirname "$PRODUCTION_LOCK")"
test "$LOCK_PARENT" = "$(realpath -e -- "$LOCK_PARENT")"
test ! -L "$LOCK_PARENT"
test "$(stat -c '%u:%g' "$LOCK_PARENT")" = '0:0'
test "$LOCK_DIRECTORY" = "$(realpath -e -- "$LOCK_DIRECTORY")"
test ! -L "$LOCK_DIRECTORY"
test "$(stat -c '%u:%g:%a' "$LOCK_DIRECTORY")" = '0:0:700'
test "$PRODUCTION_LOCK" = "$(realpath -e -- "$PRODUCTION_LOCK")"
test -f "$PRODUCTION_LOCK"
test ! -L "$PRODUCTION_LOCK"
test "$(stat -c '%u:%g:%h' "$PRODUCTION_LOCK")" = '0:0:1'
exec 9<>"$PRODUCTION_LOCK"
LOCK_PATH_IDENTITY="$(stat -Lc '%d:%i' "$PRODUCTION_LOCK")"
LOCK_DESCRIPTOR_IDENTITY="$(stat -Lc '%d:%i' /proc/self/fd/9)"
test "$LOCK_PATH_IDENTITY" = "$LOCK_DESCRIPTOR_IDENTITY"
flock --exclusive --nonblock 9
test "$(stat -Lc '%d:%i' "$PRODUCTION_LOCK")" = "$LOCK_DESCRIPTOR_IDENTITY"

CONFIGURED_IMAGE="$(
  docker compose config --images |
    awk '/ghcr\.io\/shumkov\/chatwoot/ { print; exit }'
)"
[[ "$CONFIGURED_IMAGE" =~ ^ghcr\.io/shumkov/chatwoot:[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]
test "ghcr.io/shumkov/chatwoot@${CONFIGURED_IMAGE##*@}" = "$APP_DIGEST"
docker image inspect \
  --format '{{range .RepoDigests}}{{println .}}{{end}}' "$CONFIGURED_IMAGE" |
  grep -Fxq "$APP_DIGEST"
for SERVICE in rails sidekiq; do
  CONTAINER="$(docker compose ps -q "$SERVICE")"
  test -n "$CONTAINER"
  IMAGE_ID="$(docker inspect --format '{{.Image}}' "$CONTAINER")"
  docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE_ID" |
    grep -Fxq "$APP_DIGEST"
  test "$(
    docker compose exec -T "$SERVICE" sh -c 'tr -d "\r\n" </app/.git_sha'
  )" = "$APP_COMMIT"
done
test "$(
  docker compose run --rm --no-deps -T rails \
    sh -c 'tr -d "\r\n" </app/.git_sha'
)" = "$APP_COMMIT"

docker compose run --rm --no-deps rails bundle exec rails db:migrate
docker compose run --rm --no-deps -T \
  -e UMI_FBIG_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
  -e UMI_FBIG_EXPECTED_MIGRATION="$PRODUCTION_MIGRATION" \
  rails bundle exec rails runner - <<'RUBY'
connection = ActiveRecord::Base.connection
abort("production database mismatch") unless
  connection.select_value("SELECT current_database()") ==
    ENV.fetch("UMI_FBIG_EXPECTED_DATABASE")
migration = connection.quote(ENV.fetch("UMI_FBIG_EXPECTED_MIGRATION"))
abort("Contact avatar migration is not applied") unless
  connection.select_value(
    "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = #{migration})"
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
valid_fields = %w[
  indisunique indisvalid indisready exact_attribute_count no_expressions columns_match
]
abort("Contact avatar index shape is invalid") unless
  index.values_at(*valid_fields).all? { |value| value == true }
expected_predicate = "record_type = 'Contact' AND name = 'avatar'"
predicate = index.fetch("predicate").gsub("::text", "").delete("() \n\t")
abort("Contact avatar index predicate changed") unless
  predicate == expected_predicate.delete("() \n\t")
duplicates = ActiveStorage::Attachment
  .where(record_type: "Contact", name: "avatar")
  .group(:record_id).having("COUNT(*) > 1").count
abort("duplicate Contact avatar rows remain") if duplicates.any?
RUBY

flock --unlock 9
exec 9>&-
```

Do not start section 9 until its preflight proves that Rails, Sidekiq, and
Compose resolve to `$APP_DIGEST`, both live containers report `$APP_COMMIT`
from `/app/.git_sha`, migration `20260724000000` exists, and the exact partial
unique Contact/avatar index is unique, valid, ready, uses only
`record_type,record_id,name`, has only the two expected predicates, and has
zero duplicate Contact/avatar rows.

## 9. Production history

Use only the production history root wrapper. Under the shared lock it loads
the immutable history approval, derives its commit/digest, proves Compose and
the live Rails/Sidekiq containers use that exact digest, rejects unexpected
one-offs, and then starts the production-database rake command. Run two
accepted production dry scans; they must match the accepted clone
counts/fingerprints exactly. Section 8 ran from the local control node, so
start a fresh VPS root shell and explicitly rehydrate the sealed paths and
helpers below. Production keeps Rails and Sidekiq live during history; unlike
the writer-free clone, it re-hashes the pinned pre-existing IDs and enforces
importer-owned markers/invariants without comparing the complete current
non-importer ID sets. Legitimate concurrent webhook rows are therefore not
misclassified as importer writes:

Do not execute an operator-owned file from `/tmp` as root. Assemble and review
each concretized stage program, install it and its GNU `sha256sum` checksum as
single-link `root:root 0400` files below a dedicated `root:root 0700`
`/opt/umi/fbig-ops/<acceptance-id>/` directory, and invoke it explicitly with
`/bin/bash`. The program verifies that sibling checksum before doing any work.

```bash
set -Eeuo pipefail
umask 077

INBOX_ID='<same numeric inbox id>'
PRODUCTION_DATABASE='chatwoot_production'
CLONE_DATABASE='<same accepted clone database>'
APP_COMMIT='<same 40 lowercase hex merged commit>'
APP_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<same accepted 64-hex digest>'
STACK_DIR='/opt/umi/chatwoot'
AUDIT_DIR='/opt/umi/fbig-audit/<same acceptance id>'
HISTORY_DIR="$AUDIT_DIR/history-approval"
PROFILE_DIR="$AUDIT_DIR/profile-approval"
TARGET_DIR="$AUDIT_DIR/profile-targets"
CLONE_BASELINE="$AUDIT_DIR/clone-scoped-baseline.txt"
SCOPED_SNAPSHOT_SCRIPT="$AUDIT_DIR/fbig-scoped-baseline.rb"
UNRECOVERABLE_INSPECTOR="$AUDIT_DIR/fbig-unrecoverable-envelope-inspector.rb"
UNRECOVERABLE_SIDECAR="$HISTORY_DIR/fbig-unrecoverable-envelope-v1.tsv"
UNRECOVERABLE_SIDECAR_CHECKSUM="$HISTORY_DIR/fbig-unrecoverable-envelope-v1.tsv.sha256"
HISTORY_PROBE_LOG="$AUDIT_DIR/history-probe.log"
EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS='1'
EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS='2'
R4_ACCEPTANCE_UNIT='<same loaded acceptance unit>'
R4_ACCEPTANCE_INVOCATION_ID='<same 32 lowercase hex invocation id>'
R4_ACCEPTANCE_EXEC_SCRIPT='<exact unit ExecStart script path>'
R4_ACCEPTANCE_SCRIPT_ARCHIVE='<protected root-only copy of that exact script>'
R4_ACCEPTANCE_FINALIZER='<protected root-only terminal finalizer path>'
R4_ACCEPTANCE_SCRIPT_SHA256='<same reviewed 64-hex acceptance-program SHA>'
R4_ACCEPTANCE_FINALIZER_SHA256='<same reviewed 64-hex terminal-finalizer SHA>'
R4_ACCEPTANCE_MANIFEST="$AUDIT_DIR/fbig-r4-acceptance-complete-v1.tsv"
R4_ACCEPTANCE_CHECKSUM="${R4_ACCEPTANCE_MANIFEST}.sha256"
PRODUCTION_MIGRATION='20260724000000'
PRODUCTION_LOCK='/run/lock/umi-fbig/production.lock'

test "$(id -u)" -eq 0
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$PRODUCTION_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
[[ "$CLONE_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
[[ "$R4_ACCEPTANCE_INVOCATION_ID" =~ ^[0-9a-f]{32}$ ]]
[[ "$R4_ACCEPTANCE_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$R4_ACCEPTANCE_FINALIZER_SHA256" =~ ^[0-9a-f]{64}$ ]]
test "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS" = 1
test "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS" = 2
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=LoadState --value)" = loaded
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=ActiveState --value)" = inactive
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=SubState --value)" = dead
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=Result --value)" = success
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=ExecMainStatus --value)" = 0
test "$(systemctl show "$R4_ACCEPTANCE_UNIT" --property=InvocationID --value)" = \
  "$R4_ACCEPTANCE_INVOCATION_ID"
systemctl show "$R4_ACCEPTANCE_UNIT" --property=ExecStart --value |
  grep -Fq "argv[]=/bin/bash $R4_ACCEPTANCE_EXEC_SCRIPT ;"

require_root_artifact() {
  local path="$1"
  local expected_basename="$2"
  local directory
  test "$path" = "$(realpath -e -- "$path")"
  test "$(basename "$path")" = "$expected_basename"
  test -f "$path"
  test ! -L "$path"
  test "$(stat -c '%u:%a:%h' "$path")" = "0:400:1"
  directory="$(dirname "$path")"
  test "$directory" = "$(realpath -e -- "$directory")"
  test ! -L "$directory"
  test "$(stat -c '%u:%a' "$directory")" = "0:700"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

verify_checksum() {
  local artifact="$1"
  local checksum="$2"
  local expected
  expected="$(printf '%s  %s\n' "$(sha256_file "$artifact")" "$(basename "$artifact")")"
  test "$(cat "$checksum")" = "$expected"
}

require_ordered_fields() {
  local path="$1"
  shift
  local -a expected=("$@")
  local -a observed
  local field_index
  mapfile -t observed < <(awk -F $'\t' 'NF == 2 { print $1 }' "$path")
  test "${#observed[@]}" -eq "${#expected[@]}"
  for field_index in "${!expected[@]}"; do
    test "${observed[$field_index]}" = "${expected[$field_index]}"
  done
}

PRODUCTION_PROGRAM="${BASH_SOURCE[0]}"
test -n "$PRODUCTION_PROGRAM"
test "$PRODUCTION_PROGRAM" = "$(realpath -e -- "$PRODUCTION_PROGRAM")"
PRODUCTION_PROGRAM_CHECKSUM="${PRODUCTION_PROGRAM}.sha256"
require_root_artifact "$PRODUCTION_PROGRAM" "$(basename "$PRODUCTION_PROGRAM")"
require_root_artifact \
  "$PRODUCTION_PROGRAM_CHECKSUM" "$(basename "$PRODUCTION_PROGRAM_CHECKSUM")"
verify_checksum "$PRODUCTION_PROGRAM" "$PRODUCTION_PROGRAM_CHECKSUM"

for path in \
  "$CLONE_BASELINE" "$SCOPED_SNAPSHOT_SCRIPT" \
  "$AUDIT_DIR/history-dry-1-summary-normalized.tsv" \
  "$HISTORY_PROBE_LOG" "$UNRECOVERABLE_INSPECTOR" \
  "$UNRECOVERABLE_SIDECAR" "$UNRECOVERABLE_SIDECAR_CHECKSUM" \
  "$HISTORY_DIR/fbig-approval-v2.tsv" \
  "$HISTORY_DIR/fbig-approval-v2.tsv.sha256" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv.sha256" \
  "$TARGET_DIR/fbig-profile-targets-v1.tsv" \
  "$AUDIT_DIR/history-all-idempotency-summary.tsv" \
  "$AUDIT_DIR/clone-profile/idempotency/clone-profile-summary.tsv" \
  "$R4_ACCEPTANCE_SCRIPT_ARCHIVE" "${R4_ACCEPTANCE_SCRIPT_ARCHIVE}.sha256" \
  "$R4_ACCEPTANCE_FINALIZER" "${R4_ACCEPTANCE_FINALIZER}.sha256" \
  "$R4_ACCEPTANCE_MANIFEST" "$R4_ACCEPTANCE_CHECKSUM"; do
  require_root_artifact "$path" "$(basename "$path")"
done

manifest_value() {
  local path="$1"
  local key="$2"
  awk -F $'\t' -v expected="$key" '
    $1 == expected { count += 1; value = $2 }
    END { if (count != 1) exit 1; print value }
  ' "$path"
}

test "$R4_ACCEPTANCE_EXEC_SCRIPT" = \
  "$(realpath -e -- "$R4_ACCEPTANCE_EXEC_SCRIPT")"
test -f "$R4_ACCEPTANCE_EXEC_SCRIPT"
test ! -L "$R4_ACCEPTANCE_EXEC_SCRIPT"
test "$(stat -c '%u:%a:%h' "$R4_ACCEPTANCE_EXEC_SCRIPT")" = '0:400:1'
test "$(sha256_file "$R4_ACCEPTANCE_EXEC_SCRIPT")" = \
  "$R4_ACCEPTANCE_SCRIPT_SHA256"
verify_checksum \
  "$R4_ACCEPTANCE_SCRIPT_ARCHIVE" "${R4_ACCEPTANCE_SCRIPT_ARCHIVE}.sha256"
verify_checksum "$R4_ACCEPTANCE_FINALIZER" "${R4_ACCEPTANCE_FINALIZER}.sha256"
test "$(sha256_file "$R4_ACCEPTANCE_SCRIPT_ARCHIVE")" = \
  "$R4_ACCEPTANCE_SCRIPT_SHA256"
test "$(sha256_file "$R4_ACCEPTANCE_FINALIZER")" = \
  "$R4_ACCEPTANCE_FINALIZER_SHA256"
verify_checksum "$R4_ACCEPTANCE_MANIFEST" "$R4_ACCEPTANCE_CHECKSUM"
require_ordered_fields "$R4_ACCEPTANCE_MANIFEST" \
  schema_version acceptance_id acceptance_unit acceptance_invocation_id \
  acceptance_script_path acceptance_script_archive_path \
  acceptance_script_sha256 acceptance_finalizer_path \
  acceptance_finalizer_sha256 repository_commit image_digest \
  clone_database_name production_database_name inbox_id \
  history_approval_sha256 profile_approval_sha256 profile_targets_sha256 \
  clone_baseline_sha256 history_idempotency_summary_sha256 \
  profile_idempotency_summary_sha256 unrecoverable_sidecar_sha256 completed_at
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" schema_version)" = 1
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_id)" = \
  "$(basename "$AUDIT_DIR")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_unit)" = \
  "$R4_ACCEPTANCE_UNIT"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_invocation_id)" = \
  "$R4_ACCEPTANCE_INVOCATION_ID"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_script_path)" = \
  "$R4_ACCEPTANCE_EXEC_SCRIPT"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_script_archive_path)" = \
  "$R4_ACCEPTANCE_SCRIPT_ARCHIVE"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_script_sha256)" = \
  "$R4_ACCEPTANCE_SCRIPT_SHA256"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_finalizer_path)" = \
  "$R4_ACCEPTANCE_FINALIZER"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" acceptance_finalizer_sha256)" = \
  "$R4_ACCEPTANCE_FINALIZER_SHA256"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" repository_commit)" = "$APP_COMMIT"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" image_digest)" = "$APP_DIGEST"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" clone_database_name)" = \
  "$CLONE_DATABASE"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" production_database_name)" = \
  "$PRODUCTION_DATABASE"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" inbox_id)" = "$INBOX_ID"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" history_approval_sha256)" = \
  "$(sha256_file "$HISTORY_DIR/fbig-approval-v2.tsv")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" profile_approval_sha256)" = \
  "$(sha256_file "$PROFILE_DIR/fbig-profile-approval-v1.tsv")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" profile_targets_sha256)" = \
  "$(sha256_file "$TARGET_DIR/fbig-profile-targets-v1.tsv")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" clone_baseline_sha256)" = \
  "$(sha256_file "$CLONE_BASELINE")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" history_idempotency_summary_sha256)" = \
  "$(sha256_file "$AUDIT_DIR/history-all-idempotency-summary.tsv")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" profile_idempotency_summary_sha256)" = \
  "$(sha256_file "$AUDIT_DIR/clone-profile/idempotency/clone-profile-summary.tsv")"
test "$(manifest_value "$R4_ACCEPTANCE_MANIFEST" unrecoverable_sidecar_sha256)" = \
  "$(sha256_file "$UNRECOVERABLE_SIDECAR")"

stage_value() {
  local path="$1"
  local stage="$2"
  local key="$3"
  awk -v expected_stage="$stage" -v expected_key="$key" '
    $1 == "[UMI-FBIG]" {
      selected = 0
      for (field = 2; field <= NF; field += 1) {
        if ($field == "stage=" expected_stage) selected = 1
      }
      if (selected) {
        rows += 1
        for (field = 2; field <= NF; field += 1) {
          split($field, pair, "=")
          if (pair[1] == expected_key) {
            values += 1
            value = substr($field, length(expected_key) + 2)
          }
        }
      }
    }
    END {
      if (rows != 1 || values != 1 || value == "") exit 1
      print value
    }
  ' "$path"
}

HISTORY_APPROVAL="$HISTORY_DIR/fbig-approval-v2.tsv"
HISTORY_APPROVAL_CHECKSUM="$HISTORY_DIR/fbig-approval-v2.tsv.sha256"
verify_checksum "$HISTORY_APPROVAL" "$HISTORY_APPROVAL_CHECKSUM"
verify_checksum "$UNRECOVERABLE_SIDECAR" "$UNRECOVERABLE_SIDECAR_CHECKSUM"
EXPECTED_UNRECOVERABLE_FIELDS=(
  schema_version repository_commit image_digest account_id inbox_id
  instagram_business_id before platform count fingerprint
  inspector_script_sha256 approved_by approved_at
)
awk -F $'\t' 'NF != 2 { exit 1 } END { if (NR != 13) exit 1 }' \
  "$UNRECOVERABLE_SIDECAR"
mapfile -t OBSERVED_UNRECOVERABLE_FIELDS < <(cut -f1 "$UNRECOVERABLE_SIDECAR")
test "${#OBSERVED_UNRECOVERABLE_FIELDS[@]}" -eq \
  "${#EXPECTED_UNRECOVERABLE_FIELDS[@]}"
for field_index in "${!EXPECTED_UNRECOVERABLE_FIELDS[@]}"; do
  test "${OBSERVED_UNRECOVERABLE_FIELDS[$field_index]}" = \
    "${EXPECTED_UNRECOVERABLE_FIELDS[$field_index]}"
done
CUTOFF="$(manifest_value "$HISTORY_APPROVAL" before)"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" schema_version)" = 1
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" repository_commit)" = "$APP_COMMIT"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" image_digest)" = "$APP_DIGEST"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" account_id)" = \
  "$(manifest_value "$HISTORY_APPROVAL" account_id)"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" inbox_id)" = "$INBOX_ID"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" instagram_business_id)" = \
  "$(manifest_value "$HISTORY_APPROVAL" instagram_business_id)"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" before)" = "$CUTOFF"
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" platform)" = instagram
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)" = \
  "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS"
[[ "$(manifest_value "$UNRECOVERABLE_SIDECAR" fingerprint)" =~ ^[0-9a-f]{64}$ ]]
test "$(manifest_value "$UNRECOVERABLE_SIDECAR" inspector_script_sha256)" = \
  "$(sha256_file "$UNRECOVERABLE_INSPECTOR")"
test "$(manifest_value "$HISTORY_APPROVAL" source_dry_log_sha256)" = \
  "$(sha256_file "$HISTORY_PROBE_LOG")"
UNRECOVERABLE_SIDECAR_SHA256="$(sha256_file "$UNRECOVERABLE_SIDECAR")"
test "$(
  grep -Fxc \
    "[UMI-FBIG] stage=unrecoverable_envelope_approval sidecar_sha256=$UNRECOVERABLE_SIDECAR_SHA256 count=$(manifest_value "$UNRECOVERABLE_SIDECAR" count) fingerprint=$(manifest_value "$UNRECOVERABLE_SIDECAR" fingerprint)" \
    "$HISTORY_PROBE_LOG"
)" -eq 1

baseline_ids() {
  local baseline_file="$1"
  local kind="$2"
  awk -F '|' -v expected="$kind" '
    $1 == "FBIG_IDS" && $2 == expected { count += 1; value = $3 }
    END { if (count != 1) exit 1; print value }
  ' "$baseline_file"
}

load_scoped_baseline_ids() {
  local baseline_file="$1"
  FBIG_ARCHIVE_IDS="$(baseline_ids "$baseline_file" archives)"
  FBIG_MESSAGE_IDS="$(baseline_ids "$baseline_file" messages)"
  FBIG_ATTACHMENT_IDS="$(baseline_ids "$baseline_file" attachments)"
  FBIG_LIVE_CONVERSATION_IDS="$(baseline_ids "$baseline_file" live_conversations)"
  FBIG_NONIMPORTER_MESSAGE_IDS="$(baseline_ids "$baseline_file" nonimporter_messages)"
  test -n "$FBIG_ARCHIVE_IDS"
  test -n "$FBIG_MESSAGE_IDS"
  test -n "$FBIG_ATTACHMENT_IDS"
  export FBIG_ARCHIVE_IDS FBIG_MESSAGE_IDS FBIG_ATTACHMENT_IDS
  export FBIG_LIVE_CONVERSATION_IDS FBIG_NONIMPORTER_MESSAGE_IDS
}

normalize_history_summary() {
  local summary="$1"
  awk '
    {
      output = ""
      for (field = 1; field <= NF; field += 1) {
        if ($field ~ /^(contentless_acceptance_mismatches|unavailable_message_thread_acceptance_mismatches|exit_failures)=/) continue
        output = output (output == "" ? "" : " ") $field
      }
      print output
    }
  ' "$summary"
}

run_production_unrecoverable_inspection() {
  docker compose exec -T \
    -e UMI_FBIG_INSPECT_INBOX_ID="$INBOX_ID" \
    -e UMI_FBIG_INSPECT_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
    -e UMI_FBIG_INSPECT_BEFORE="$CUTOFF" \
    rails bundle exec rails runner - <"$UNRECOVERABLE_INSPECTOR" |
    grep '^\[UMI-FBIG\] stage=unrecoverable_envelope_inspection '
}

inspect_production_unrecoverable_envelopes() {
  local label="$1"
  local output="$AUDIT_DIR/production-unrecoverable-$label.tsv"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  if [[ -e "$output" ]]; then
    require_root_artifact "$output" "$(basename "$output")"
  else
    run_production_unrecoverable_inspection >"$output"
    chmod 0400 "$output"
  fi
  test "$(grep -c '^\[UMI-FBIG\] stage=unrecoverable_envelope_inspection ' "$output")" -eq 1
  test "$(stage_value "$output" unrecoverable_envelope_inspection count)" = \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  test "$(stage_value "$output" unrecoverable_envelope_inspection fingerprint)" = \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" fingerprint)"
}

validate_history_apply_summary() {
  local summary="$1"
  local require_zero_writes="$2"
  local platforms="$3"
  local expected_degraded=false
  local expected_ambiguous=0
  local expected_unavailable=0
  local expected_classified
  local observed_degraded
  local attachments_unavailable
  local platform
  local approved_count
  local approved_fingerprint
  local approved_unavailable_count
  local approved_unavailable_fingerprint
  local observed_count
  local observed_fingerprint
  local -a selected_platforms
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  [[ "$platforms" =~ ^(messenger|instagram|messenger,instagram)$ ]]
  test "$(stage_value "$summary" history_import_summary dry_run)" = false
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = true
  test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary unavailable_message_thread_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
  if [[ ",$platforms," == *,instagram,* ]]; then
    expected_ambiguous="$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  fi
  test "$(stage_value "$summary" history_import_summary ambiguous_participants)" = \
    "$expected_ambiguous"
  test "$(stage_value "$summary" history_import_summary structural_unrecoverable_threads)" = \
    "$expected_ambiguous"
  for counter in \
    ambiguous_senders partially_paginated_threads uncategorized_threads \
    foreign_source_id_anomalies \
    platform_failures retry_exhaustion authentication_failures \
    lock_loss reindex_failures download_budget_exhaustions; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done

  IFS=',' read -r -a selected_platforms <<<"$platforms"
  for platform in "${selected_platforms[@]}"; do
    approved_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" "${platform}_count"
    )"
    approved_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" "${platform}_fingerprint"
    )"
    observed_count="$(
      stage_value "$summary" history_import_summary "${platform}_contentless_details"
    )"
    observed_fingerprint="$(
      stage_value "$summary" history_import_summary "${platform}_contentless_fingerprint"
    )"
    [[ "$approved_count" =~ ^(0|[1-9][0-9]*)$ ]]
    [[ "$approved_fingerprint" =~ ^[0-9a-f]{64}$ ]]
    test "$observed_count" = "$approved_count"
    test "$observed_fingerprint" = "$approved_fingerprint"
    approved_unavailable_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" \
        "${platform}_unavailable_message_thread_count"
    )"
    approved_unavailable_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" \
        "${platform}_unavailable_message_thread_fingerprint"
    )"
    test "$(stage_value "$summary" history_import_summary \
      "${platform}_unavailable_message_thread_count")" = "$approved_unavailable_count"
    test "$(stage_value "$summary" history_import_summary \
      "${platform}_unavailable_message_thread_fingerprint")" = \
      "$approved_unavailable_fingerprint"
    expected_unavailable="$((expected_unavailable + approved_unavailable_count))"
    if [[ "$approved_count" != 0 || "$approved_unavailable_count" != 0 ]]; then
      expected_degraded=true
    fi
  done
  expected_classified="$((expected_ambiguous + expected_unavailable))"
  test "$(stage_value "$summary" history_import_summary unavailable_message_threads)" = \
    "$expected_unavailable"
  test "$(stage_value "$summary" history_import_summary classified_omitted_threads)" = \
    "$expected_classified"
  test "$(stage_value "$summary" history_import_summary failed_threads)" = 0
  test "$(stage_value "$summary" history_import_summary listed_threads)" -eq \
    "$(( $(stage_value "$summary" history_import_summary message_cursor_exhausted_threads) + \
         expected_classified ))"
  if [[ "$expected_classified" != 0 ]]; then
    expected_degraded=true
  fi

  attachments_unavailable="$(
    stage_value "$summary" history_import_summary attachments_unavailable
  )"
  [[ "$attachments_unavailable" =~ ^(0|[1-9][0-9]*)$ ]]
  if [[ "$attachments_unavailable" != 0 ]]; then
    expected_degraded=true
  fi
  observed_degraded="$(stage_value "$summary" history_import_summary degraded)"
  test "$observed_degraded" = "$expected_degraded"
  for counter in \
    profile_requests profile_successes profile_unavailable profile_errors \
    profile_changes_projected profile_changes_applied avatars_offered \
    avatars_preserved avatars_attached avatars_raced avatars_unavailable \
    avatar_failures avatars_skipped_history_incomplete avatar_bytes; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done

  if [[ "$require_zero_writes" == true ]]; then
    for counter in \
      imported_contacts imported_archives imported_incoming imported_outgoing \
      imported_messages imported_attachments marker_normalizations \
      history_evidence_changes_applied \
      messenger_history_evidence_changes_applied \
      instagram_history_evidence_changes_applied \
      profile_changes_applied avatars_attached avatars_raced; do
      test "$(stage_value "$summary" history_import_summary "$counter")" = 0
    done
  fi
}

cd "$STACK_DIR"
test -x "$STACK_DIR/bin/fbig_history_run.sh"

verify_production_running_release() {
  local service
  local container
  local image_id
  local configured_image
  local repo_digests

  configured_image="$(
    docker compose config --images |
      awk '/ghcr\.io\/shumkov\/chatwoot/ { print; exit }'
  )"
  [[ "$configured_image" =~ ^ghcr\.io/shumkov/chatwoot:[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]
  test "ghcr.io/shumkov/chatwoot@${configured_image##*@}" = "$APP_DIGEST"
  repo_digests="$(
    docker image inspect \
      --format '{{range .RepoDigests}}{{println .}}{{end}}' \
      "$configured_image"
  )"
  grep -Fxq "$APP_DIGEST" <<<"$repo_digests"

  for service in rails sidekiq; do
    container="$(docker compose ps -q "$service")"
    test -n "$container"
    image_id="$(docker inspect --format '{{.Image}}' "$container")"
    repo_digests="$(
      docker image inspect \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' \
        "$image_id"
    )"
    grep -Fxq "$APP_DIGEST" <<<"$repo_digests"
    test "$(
      docker compose exec -T "$service" sh -c 'tr -d "\r\n" </app/.git_sha'
    )" = "$APP_COMMIT"
  done
}

verify_production_release_and_schema() {
  local lock_directory
  local lock_path_identity
  local lock_descriptor_identity
  lock_directory="$(dirname "$PRODUCTION_LOCK")"
  test '/run/lock' = "$(realpath -e -- /run/lock)"
  test ! -L /run/lock
  test "$(stat -c '%u:%g' /run/lock)" = '0:0'
  test "$lock_directory" = "$(realpath -e -- "$lock_directory")"
  test ! -L "$lock_directory"
  test "$(stat -c '%u:%g:%a' "$lock_directory")" = '0:0:700'
  test "$PRODUCTION_LOCK" = "$(realpath -e -- "$PRODUCTION_LOCK")"
  test -f "$PRODUCTION_LOCK"
  test ! -L "$PRODUCTION_LOCK"
  test "$(stat -c '%u:%g:%h' "$PRODUCTION_LOCK")" = "0:0:1"
  exec 8<>"$PRODUCTION_LOCK"
  lock_path_identity="$(stat -Lc '%d:%i' "$PRODUCTION_LOCK")"
  lock_descriptor_identity="$(stat -Lc '%d:%i' /proc/self/fd/8)"
  test "$lock_path_identity" = "$lock_descriptor_identity"
  flock --exclusive --nonblock 8
  test "$(stat -Lc '%d:%i' "$PRODUCTION_LOCK")" = \
    "$lock_descriptor_identity"
  verify_production_running_release

  docker compose exec -T \
    -e UMI_FBIG_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
    -e UMI_FBIG_EXPECTED_MIGRATION="$PRODUCTION_MIGRATION" \
    rails bundle exec rails runner - <<'RUBY'
connection = ActiveRecord::Base.connection
abort("production database mismatch") unless
  connection.select_value("SELECT current_database()") ==
    ENV.fetch("UMI_FBIG_EXPECTED_DATABASE")
migration = connection.quote(ENV.fetch("UMI_FBIG_EXPECTED_MIGRATION"))
applied = connection.select_value(
  "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = #{migration})"
)
abort("Contact avatar migration is not applied") unless applied

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
      WHERE key.position <= i.indnkeyatts
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
valid_fields = %w[
  indisunique indisvalid indisready exact_attribute_count no_expressions columns_match
]
abort("Contact avatar index shape is invalid") unless
  index.values_at(*valid_fields).all? { |value| value == true }
expected_predicate = "record_type = 'Contact' AND name = 'avatar'"
predicate = index.fetch("predicate").gsub("::text", "").delete("() \n\t")
abort("Contact avatar index predicate changed") unless
  predicate == expected_predicate.delete("() \n\t")

duplicates = ActiveStorage::Attachment
  .where(record_type: "Contact", name: "avatar")
  .group(:record_id).having("COUNT(*) > 1").count
abort("duplicate Contact avatar rows remain") if duplicates.any?
puts "[UMI-FBIG] stage=production_release_schema_verified"
RUBY

  flock --unlock 8
  exec 8>&-
}

acquire_production_verification_lock() {
  local lock_directory
  local lock_path_identity
  local lock_descriptor_identity
  lock_directory="$(dirname "$PRODUCTION_LOCK")"
  test '/run/lock' = "$(realpath -e -- /run/lock)"
  test ! -L /run/lock
  test "$(stat -c '%u:%g' /run/lock)" = '0:0'
  test "$lock_directory" = "$(realpath -e -- "$lock_directory")"
  test ! -L "$lock_directory"
  test "$(stat -c '%u:%g:%a' "$lock_directory")" = '0:0:700'
  test "$PRODUCTION_LOCK" = "$(realpath -e -- "$PRODUCTION_LOCK")"
  test -f "$PRODUCTION_LOCK"
  test ! -L "$PRODUCTION_LOCK"
  test "$(stat -c '%u:%g:%h' "$PRODUCTION_LOCK")" = "0:0:1"
  exec 7<>"$PRODUCTION_LOCK"
  lock_path_identity="$(stat -Lc '%d:%i' "$PRODUCTION_LOCK")"
  lock_descriptor_identity="$(stat -Lc '%d:%i' /proc/self/fd/7)"
  test "$lock_path_identity" = "$lock_descriptor_identity"
  flock --exclusive --nonblock 7
  test "$(stat -Lc '%d:%i' "$PRODUCTION_LOCK")" = \
    "$lock_descriptor_identity"
  verify_production_running_release
}

release_production_verification_lock() {
  flock --unlock 7
  exec 7>&-
}

production_scoped_snapshot() {
  docker compose exec -T \
    -e FBIG_BASELINE_MODE=production_verify \
    -e FBIG_INBOX_ID="$INBOX_ID" \
    -e FBIG_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
    -e FBIG_ARCHIVE_IDS="$FBIG_ARCHIVE_IDS" \
    -e FBIG_MESSAGE_IDS="$FBIG_MESSAGE_IDS" \
    -e FBIG_ATTACHMENT_IDS="$FBIG_ATTACHMENT_IDS" \
    -e FBIG_LIVE_CONVERSATION_IDS="$FBIG_LIVE_CONVERSATION_IDS" \
    -e FBIG_NONIMPORTER_MESSAGE_IDS="$FBIG_NONIMPORTER_MESSAGE_IDS" \
    rails bundle exec rails runner - <"$SCOPED_SNAPSHOT_SCRIPT" |
    grep '^FBIG_'
}

verify_production_history_state() {
  local label="$1"
  local snapshot_path="$AUDIT_DIR/production-scoped-$label.txt"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  if [[ -e "$snapshot_path" ]]; then
    require_root_artifact "$snapshot_path" "$(basename "$snapshot_path")"
  else
    production_scoped_snapshot >"$snapshot_path"
    chmod 0400 "$snapshot_path"
  fi
  cmp -s "$CLONE_BASELINE" "$snapshot_path"

  docker compose exec -T \
    -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$PRODUCTION_DATABASE" \
    -e UMI_FBIG_AUDIT_LABEL="$label" \
    -e UMI_FBIG_AUDIT_INBOX_ID="$INBOX_ID" \
    rails bundle exec rails runner '
      expected_database = ENV.fetch("UMI_FBIG_HISTORY_EXPECTED_DATABASE")
      actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
      abort("production database mismatch") unless actual_database == expected_database
      inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_AUDIT_INBOX_ID"), 10))
      archives = inbox.conversations.where(
        "jsonb_exists(conversations.additional_attributes, :key)",
        key: "umi_history_import"
      )
      duplicate_message_sources = Message
        .where(inbox_id: inbox.id)
        .where(
          "additional_attributes ->> :key = :value",
          key: "umi_history_import",
          value: "true"
        )
        .reorder(nil)
        .group(:source_id).having("COUNT(*) > 1").count
      empty_archives = archives.left_joins(:messages)
                               .group("conversations.id")
                               .having("COUNT(messages.id) = 0").count
      resolved = Conversation.statuses.fetch("resolved")
      invalid_archives = archives.where(
        "status <> :resolved OR assignee_id IS NOT NULL OR team_id IS NOT NULL " \
        "OR waiting_since IS NOT NULL OR first_reply_created_at IS NOT NULL",
        resolved: resolved
      )
      duplicate_sources = inbox.contact_inboxes.group(:source_id).having("COUNT(*) > 1").count
      duplicate_avatars = ActiveStorage::Attachment
        .where(record_type: "Contact", name: "avatar")
        .group(:record_id).having("COUNT(*) > 1").count
      abort("duplicate imported message source") if duplicate_message_sources.any?
      abort("empty importer archive") if empty_archives.any?
      abort("importer archive is not inert and resolved") if invalid_archives.exists?
      abort("duplicate ContactInbox source_id") if duplicate_sources.any?
      abort("duplicate Contact avatar") if duplicate_avatars.any?
      label = ENV.fetch("UMI_FBIG_AUDIT_LABEL")
      puts "[UMI-FBIG] stage=production_history_state_verified label=#{label}"
    '
}

production_history_run_with_verification() {
  local label="$1"
  local dry_run="$2"
  local platforms="$3"
  local budget="${4:-}"
  local require_zero_writes="${5:-false}"
  local log="$AUDIT_DIR/production-history-$label.log"
  local summary="$AUDIT_DIR/production-history-$label-summary.tsv"
  local normalized="$AUDIT_DIR/production-history-$label-summary-normalized.tsv"
  local arguments=(
    "$INBOX_ID" "$dry_run" "$platforms"
    "$HISTORY_DIR/fbig-approval-v2.tsv"
    "$HISTORY_DIR/fbig-approval-v2.tsv.sha256"
  )
  local statuses
  local sealed=false
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  if [[ "$dry_run" == false ]]; then
    [[ "$budget" =~ ^[1-9][0-9]*$ ]]
    arguments+=("$budget")
  else
    test "$dry_run" = true
    test -z "$budget"
  fi

  if [[ -e "$log" || -e "$summary" ]]; then
    require_root_artifact "$log" "$(basename "$log")"
    require_root_artifact "$summary" "$(basename "$summary")"
    sealed=true
  fi

  if [[ "$sealed" == false ]]; then
    if [[ ",$platforms," == *,instagram,* ]]; then
      acquire_production_verification_lock
      inspect_production_unrecoverable_envelopes "before-$label"
      release_production_verification_lock
    fi
    set +e
    "$STACK_DIR/bin/fbig_history_run.sh" "${arguments[@]}" 2>&1 | tee "$log"
    statuses=("${PIPESTATUS[@]}")
    set -e
    test "${#statuses[@]}" -eq 2
    test "${statuses[0]}" -eq 0
    test "${statuses[1]}" -eq 0
    test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$log")" -eq 1
    grep '^\[UMI-FBIG\] stage=history_import_summary ' "$log" >"$summary"
    chmod 0400 "$log" "$summary"
  fi

  acquire_production_verification_lock
  if [[ ",$platforms," == *,instagram,* ]]; then
    inspect_production_unrecoverable_envelopes "after-$label"
  fi
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_start ' "$log")" -eq 1
  test "$(stage_value "$log" history_import_start inbox_id)" = "$INBOX_ID"
  test "$(stage_value "$log" history_import_start dry_run)" = "$dry_run"
  test "$(stage_value "$log" history_import_start platforms)" = "$platforms"
  test "$(stage_value "$log" history_import_start since)" = \
    "$(manifest_value "$HISTORY_APPROVAL" since)"
  test "$(stage_value "$log" history_import_start before)" = "$CUTOFF"
  test "$(stage_value "$log" history_import_start outbound_policy)" = \
    "$(manifest_value "$HISTORY_APPROVAL" outbound_policy)"
  test "$(stage_value "$log" history_import_start profile_mode)" = defer
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$log")" -eq 1
  test "$(cat "$summary")" = \
    "$(grep '^\[UMI-FBIG\] stage=history_import_summary ' "$log")"
  verify_production_history_state "$label"

  if [[ "$dry_run" == true ]]; then
    test "$require_zero_writes" = false
    test "$(stage_value "$summary" history_import_summary scan_complete)" = true
    test "$(stage_value "$summary" history_import_summary write_complete)" = not_applicable
    test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
    test "$(stage_value "$summary" history_import_summary unavailable_message_thread_acceptance_mismatches)" = 0
    test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
    test "$(stage_value "$summary" history_import_summary ambiguous_participants)" = \
      "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
    test "$(stage_value "$summary" history_import_summary structural_unrecoverable_threads)" = \
      "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
    test "$(stage_value "$summary" history_import_summary unavailable_message_threads)" = \
      "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS"
    test "$(stage_value "$summary" history_import_summary classified_omitted_threads)" -eq \
      "$(( $(manifest_value "$UNRECOVERABLE_SIDECAR" count) + \
           EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS ))"
    test "$(stage_value "$summary" history_import_summary failed_threads)" = 0
    test "$(stage_value "$summary" history_import_summary listed_threads)" -eq \
      "$(( $(stage_value "$summary" history_import_summary message_cursor_exhausted_threads) + \
           $(stage_value "$summary" history_import_summary classified_omitted_threads) ))"
    test "$(stage_value "$summary" history_import_summary ambiguous_senders)" = 0
    test "$(stage_value "$summary" history_import_summary partially_paginated_threads)" = 0
    test "$(stage_value "$summary" history_import_summary uncategorized_threads)" = 0
    if [[ -e "$normalized" ]]; then
      require_root_artifact "$normalized" "$(basename "$normalized")"
    else
      normalize_history_summary "$summary" >"$normalized"
      chmod 0400 "$normalized"
    fi
    test "$(cat "$normalized")" = "$(normalize_history_summary "$summary")"
    cmp -s "$AUDIT_DIR/history-dry-1-summary-normalized.tsv" "$normalized"
  else
    validate_history_apply_summary "$summary" false "$platforms"
  fi
  if [[ "$dry_run" == false ]]; then
    validate_history_apply_summary "$summary" "$require_zero_writes" "$platforms"
  fi
  release_production_verification_lock
}

verify_production_release_and_schema
load_scoped_baseline_ids "$CLONE_BASELINE"
acquire_production_verification_lock
verify_production_history_state before-production-history
release_production_verification_lock
production_history_run_with_verification dry-1 true messenger,instagram
production_history_run_with_verification dry-2 true messenger,instagram
cmp -s \
  "$AUDIT_DIR/production-history-dry-1-summary-normalized.tsv" \
  "$AUDIT_DIR/production-history-dry-2-summary-normalized.tsv"
```

Immediately before the first production history apply, take a new coordinated
backup under the accepted digest:

```bash
PRE_HISTORY_BACKUP_LOG="$AUDIT_DIR/pre-history-production-backup.log"
if [[ -e "$PRE_HISTORY_BACKUP_LOG" ]]; then
  require_root_artifact \
    "$PRE_HISTORY_BACKUP_LOG" "$(basename "$PRE_HISTORY_BACKUP_LOG")"
else
  set +e
  "$STACK_DIR/bin/fbig_coordinated_backup.sh" "$INBOX_ID" "$APP_DIGEST" 2>&1 |
    tee "$PRE_HISTORY_BACKUP_LOG"
  PRE_HISTORY_BACKUP_STATUSES=("${PIPESTATUS[@]}")
  set -e
  test "${#PRE_HISTORY_BACKUP_STATUSES[@]}" -eq 2
  test "${PRE_HISTORY_BACKUP_STATUSES[0]}" -eq 0
  test "${PRE_HISTORY_BACKUP_STATUSES[1]}" -eq 0
  chmod 0400 "$PRE_HISTORY_BACKUP_LOG"
fi
test "$(
  grep -c '^\[UMI-FBIG\] stage=coordinated_backup_complete ' \
    "$PRE_HISTORY_BACKUP_LOG"
)" -eq 1
PRE_HISTORY_BACKUP_DIRECTORY="$(
  stage_value \
    "$PRE_HISTORY_BACKUP_LOG" coordinated_backup_complete backup_directory
)"
PRE_HISTORY_BACKUP_MANIFEST="$(
  printf '%s/fbig-coordinated-backup-v1.tsv' "$PRE_HISTORY_BACKUP_DIRECTORY"
)"
require_root_artifact \
  "$PRE_HISTORY_BACKUP_MANIFEST" fbig-coordinated-backup-v1.tsv
require_root_artifact \
  "${PRE_HISTORY_BACKUP_MANIFEST}.sha256" \
  fbig-coordinated-backup-v1.tsv.sha256
verify_checksum "$PRE_HISTORY_BACKUP_MANIFEST" "${PRE_HISTORY_BACKUP_MANIFEST}.sha256"
test "$(
  stage_value "$PRE_HISTORY_BACKUP_LOG" \
    coordinated_backup_complete manifest_sha256
)" = "$(sha256_file "$PRE_HISTORY_BACKUP_MANIFEST")"
```

Run Messenger apply and recovery first, then Instagram apply, then the
two-platform recovery:

```bash
PRODUCTION_MESSENGER_APPLY_BYTES='<messenger byte budget>'
PRODUCTION_MESSENGER_RECOVERY_BYTES='<messenger recovery byte budget>'
PRODUCTION_INSTAGRAM_APPLY_BYTES='<instagram byte budget>'
PRODUCTION_ALL_RECOVERY_BYTES='<two-platform recovery byte budget>'
for value in \
  "$PRODUCTION_MESSENGER_APPLY_BYTES" "$PRODUCTION_MESSENGER_RECOVERY_BYTES" \
  "$PRODUCTION_INSTAGRAM_APPLY_BYTES" "$PRODUCTION_ALL_RECOVERY_BYTES"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
done

production_history_run_with_verification \
  messenger-apply false messenger "$PRODUCTION_MESSENGER_APPLY_BYTES" false
production_history_run_with_verification \
  messenger-recovery false messenger "$PRODUCTION_MESSENGER_RECOVERY_BYTES" true
production_history_run_with_verification \
  instagram-apply false instagram "$PRODUCTION_INSTAGRAM_APPLY_BYTES" false
production_history_run_with_verification \
  all-idempotency false messenger,instagram "$PRODUCTION_ALL_RECOVERY_BYTES" true
```

If production requires another classified two-platform recovery, call the
same wrapper with a new positive attempt number:

```bash
NEXT_PRODUCTION_RECOVERY_ATTEMPT='<next positive attempt number>'
[[ "$NEXT_PRODUCTION_RECOVERY_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
production_history_run_with_verification \
  "all-recovery-$NEXT_PRODUCTION_RECOVERY_ATTEMPT" \
  false messenger,instagram "$PRODUCTION_ALL_RECOVERY_BYTES" true
```

The function requires the importer and `tee` statuses to be zero, then checks
the immutable ID-bound baseline and invariants before returning. History runs
keep `PROFILE_MODE=defer`; they do not fetch profile fields or avatars. Do not
use whole-production DB/storage hashes while live writers are running.
History is complete only after the final approved two-platform pass writes
zero rows.

## 10. Production profile

Do not call the production profile rake task directly. Each attempt must use
the root wrapper, which verifies the approved running/one-off digest, stops
Rails and Sidekiq, proves retryable webhook maintenance and DB quiescence,
takes a fresh semantically verified DB/storage backup, runs the profile task,
seals prestate/poststate/staging/log/summary/attempt evidence, and resumes
writers only on success.

Run production profiles as resumable phase programs. Every invocation performs
exactly one `attempt`, `audit`, or `finalize` operation. Build each concretized
program beneath the protected operations directory from section 9; prepend
section 9's exact constants and helper definitions, including its self-
checksum, production-release/schema verifier, history-state verifier, and
unrecoverable-envelope inspector. A later phase consumes immutable paths from
the earlier phase instead of shell-local state:

```bash
PROFILE_APPROVAL="$PROFILE_DIR/fbig-profile-approval-v1.tsv"
PROFILE_APPROVAL_CHECKSUM="${PROFILE_APPROVAL}.sha256"
PROFILE_ATTEMPT_ROOT='/opt/umi/fbig-profile-attempts'
PROFILE_RESULT_ROOT="$AUDIT_DIR/profile-results"
PROFILE_DELIVERY_AUDIT_ROOT="$AUDIT_DIR/profile-delivery-audits"
PROFILE_OPERATION='<attempt|audit|finalize>'
PROFILE_PHASE='<dry|apply|idempotency>'
PROFILE_LABEL='<unique lowercase phase label>'
PREVIOUS_PROFILE_RESULT='<none or prior fbig-profile-attempt-result-v1.tsv>'
PREVIOUS_PROFILE_AUDIT='<none or prior fbig-profile-delivery-audit-v1.tsv>'
CURRENT_PROFILE_RESULT='<result to audit/finalize, otherwise none>'
CURRENT_PROFILE_AUDIT='<audit to finalize, otherwise none>'

mkdir -p "$PROFILE_RESULT_ROOT" "$PROFILE_DELIVERY_AUDIT_ROOT"
chmod 0700 "$PROFILE_RESULT_ROOT" "$PROFILE_DELIVERY_AUDIT_ROOT"

verify_profile_attempt_result() {
  local result="$1"
  local result_checksum="${result}.sha256"
  local result_directory
  local attempt_directory
  local attempt_manifest
  local attempt_checksum
  local completion
  local summary
  local run_log
  local prestate
  local poststate
  local staging
  local backup_directory
  local backup_manifest
  local predecessor_result
  local predecessor_audit
  local observed_zero=true
  local counter
  local platform
  local timestamp_field
  local -a selected_platforms

  require_root_artifact "$result" fbig-profile-attempt-result-v1.tsv
  require_root_artifact \
    "$result_checksum" fbig-profile-attempt-result-v1.tsv.sha256
  verify_checksum "$result" "$result_checksum"
  require_ordered_fields "$result" \
    schema_version label profile_phase predecessor_result_path \
    predecessor_result_sha256 predecessor_audit_path \
    predecessor_audit_sha256 attempt_directory \
    attempt_manifest_sha256 pre_attempt_backup_directory \
    pre_attempt_backup_sha256 wrapper_log_sha256 platforms dry_run \
    zero_write_observed started_at finished_at sealed_at
  test "$(manifest_value "$result" schema_version)" = 1
  [[ "$(manifest_value "$result" label)" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  [[ "$(manifest_value "$result" profile_phase)" =~ ^(dry|apply|idempotency)$ ]]
  [[ "$(manifest_value "$result" platforms)" =~ \
    ^(messenger|instagram|messenger,instagram)$ ]]
  [[ "$(manifest_value "$result" dry_run)" =~ ^(true|false)$ ]]
  [[ "$(manifest_value "$result" zero_write_observed)" =~ ^(true|false)$ ]]
  for timestamp_field in started_at finished_at sealed_at; do
    [[ "$(manifest_value "$result" "$timestamp_field")" =~ \
      ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  done
  predecessor_result="$(manifest_value "$result" predecessor_result_path)"
  predecessor_audit="$(manifest_value "$result" predecessor_audit_path)"
  if [[ "$predecessor_result" == none ]]; then
    test "$(manifest_value "$result" profile_phase)" = dry
    test "$(manifest_value "$result" predecessor_result_sha256)" = none
    test "$predecessor_audit" = none
    test "$(manifest_value "$result" predecessor_audit_sha256)" = none
  else
    verify_profile_attempt_result "$predecessor_result"
    verify_profile_delivery_audit "$predecessor_audit" "$predecessor_result"
    test "$(manifest_value "$result" predecessor_result_sha256)" = \
      "$(sha256_file "$predecessor_result")"
    test "$(manifest_value "$result" predecessor_audit_sha256)" = \
      "$(sha256_file "$predecessor_audit")"
  fi

  result_directory="$(dirname "$result")"
  attempt_directory="$(manifest_value "$result" attempt_directory)"
  test "$attempt_directory" = "$(realpath -e -- "$attempt_directory")"
  test "$(dirname "$attempt_directory")" = "$PROFILE_ATTEMPT_ROOT"
  test ! -L "$attempt_directory"
  test "$(stat -c '%u:%a' "$attempt_directory")" = '0:700'
  attempt_manifest="$attempt_directory/fbig-profile-production-attempt-v1.tsv"
  attempt_checksum="${attempt_manifest}.sha256"
  completion="$attempt_directory/fbig-profile-attempt-complete-v1.tsv"
  summary="$attempt_directory/fbig-profile-production-run-summary.tsv"
  run_log="$attempt_directory/fbig-profile-production-run.log"
  prestate="$attempt_directory/fbig-profile-production-prestate-v1.tsv"
  poststate="$attempt_directory/fbig-profile-production-poststate-v1.tsv"
  staging="$attempt_directory/fbig-profile-avatar-staging-v1.tsv"
  for artifact in \
    "$attempt_manifest" "$attempt_checksum" "$completion" "$summary" "$run_log" \
    "$prestate" "${prestate}.sha256" "$poststate" "${poststate}.sha256" \
    "$staging" "${staging}.sha256"; do
    require_root_artifact "$artifact" "$(basename "$artifact")"
  done
  verify_checksum "$attempt_manifest" "$attempt_checksum"
  verify_checksum "$prestate" "${prestate}.sha256"
  verify_checksum "$poststate" "${poststate}.sha256"
  verify_checksum "$staging" "${staging}.sha256"
  require_ordered_fields "$attempt_manifest" \
    schema_version profile_approval_sha256 image_digest \
    production_database_name platforms dry_run pre_attempt_backup_sha256 \
    prestate_sha256 poststate_sha256 avatar_staging_sha256 run_log_sha256 \
    run_summary_sha256 exit_status started_at finished_at
  require_ordered_fields "$completion" \
    schema_version attempt_id attempt_manifest_sha256 completed_at

  test "$(manifest_value "$attempt_manifest" profile_approval_sha256)" = \
    "$(sha256_file "$PROFILE_APPROVAL")"
  test "$(manifest_value "$attempt_manifest" image_digest)" = "$APP_DIGEST"
  test "$(manifest_value "$attempt_manifest" production_database_name)" = \
    "$PRODUCTION_DATABASE"
  test "$(manifest_value "$attempt_manifest" platforms)" = \
    "$(manifest_value "$result" platforms)"
  test "$(manifest_value "$attempt_manifest" dry_run)" = \
    "$(manifest_value "$result" dry_run)"
  test "$(manifest_value "$attempt_manifest" exit_status)" = 0
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
  test "$(stage_value "$summary" history_profiles_summary prestate_sha256)" = \
    "$(sha256_file "$prestate")"
  test "$(stage_value "$summary" history_profiles_summary poststate_sha256)" = \
    "$(sha256_file "$poststate")"
  test "$(stage_value "$summary" history_profiles_summary avatar_staging_sha256)" = \
    "$(sha256_file "$staging")"
  test "$(manifest_value "$completion" attempt_manifest_sha256)" = \
    "$(sha256_file "$attempt_manifest")"
  test "$(manifest_value "$completion" attempt_id)" = \
    "${attempt_directory##*/fbig-profile-attempt-}"
  test "$(manifest_value "$result" attempt_manifest_sha256)" = \
    "$(sha256_file "$attempt_manifest")"
  test "$(manifest_value "$result" started_at)" = \
    "$(manifest_value "$attempt_manifest" started_at)"
  test "$(manifest_value "$result" finished_at)" = \
    "$(manifest_value "$attempt_manifest" finished_at)"

  backup_directory="$(manifest_value "$result" pre_attempt_backup_directory)"
  backup_manifest="$backup_directory/fbig-profile-pre-attempt-backup-v1.tsv"
  require_root_artifact \
    "$backup_manifest" fbig-profile-pre-attempt-backup-v1.tsv
  require_root_artifact \
    "${backup_manifest}.sha256" fbig-profile-pre-attempt-backup-v1.tsv.sha256
  verify_checksum "$backup_manifest" "${backup_manifest}.sha256"
  test "$(manifest_value "$attempt_manifest" pre_attempt_backup_sha256)" = \
    "$(sha256_file "$backup_manifest")"
  test "$(manifest_value "$result" pre_attempt_backup_sha256)" = \
    "$(sha256_file "$backup_manifest")"
  require_root_artifact \
    "$result_directory/fbig-profile-wrapper.log" fbig-profile-wrapper.log
  test "$(manifest_value "$result" wrapper_log_sha256)" = \
    "$(sha256_file "$result_directory/fbig-profile-wrapper.log")"
  test "$(grep -c '^\[UMI-FBIG\] stage=history_profiles_summary ' "$run_log")" = 1
  test "$(cat "$summary")" = \
    "$(grep '^\[UMI-FBIG\] stage=history_profiles_summary ' "$run_log")"
  test "$(stage_value "$summary" history_profiles_summary scan_complete)" = true

  if [[ "$(manifest_value "$result" dry_run)" == true ]]; then
    test "$(stage_value "$summary" history_profiles_summary write_complete)" = \
      not_applicable
    observed_zero=false
  else
    test "$(stage_value "$summary" history_profiles_summary write_complete)" = true
    cmp -s "$prestate" "$poststate" || observed_zero=false
    for counter in \
      scalar_changes_applied name_changes_applied username_changes_applied \
      optional_changes_applied avatars_attached avatar_bytes mirror_jobs; do
      if [[ "$(stage_value "$summary" history_profiles_summary "$counter")" != 0 ]]; then
        observed_zero=false
      fi
    done
  fi
  for counter in \
    exit_failures lock_loss profile_errors avatar_failures \
    messenger_targets_blocking instagram_targets_blocking \
    seed_targets_blocking; do
    test "$(stage_value "$summary" history_profiles_summary "$counter")" = 0
  done
  IFS=',' read -r -a selected_platforms <<<"$(
    manifest_value "$result" platforms
  )"
  for platform in "${selected_platforms[@]}"; do
    test "$(
      stage_value "$summary" history_profiles_summary \
        "stable_${platform}_targets"
    )" = "$(manifest_value "$PROFILE_APPROVAL" \
      "${platform}_stable_target_count")"
    test "$(
      stage_value "$summary" history_profiles_summary \
        "stable_${platform}_fingerprint"
    )" = "$(manifest_value "$PROFILE_APPROVAL" \
      "${platform}_stable_target_fingerprint")"
  done
  test "$(manifest_value "$result" zero_write_observed)" = "$observed_zero"
}

verify_profile_delivery_audit() {
  local audit_manifest="$1"
  local result="$2"
  local audit_checksum="${audit_manifest}.sha256"
  local audit_directory
  local messenger_subscription
  local instagram_subscription
  local messenger_recon
  local instagram_recon
  local platform
  local recon

  verify_profile_attempt_result "$result"
  require_root_artifact \
    "$audit_manifest" fbig-profile-delivery-audit-v1.tsv
  require_root_artifact \
    "$audit_checksum" fbig-profile-delivery-audit-v1.tsv.sha256
  verify_checksum "$audit_manifest" "$audit_checksum"
  require_ordered_fields "$audit_manifest" \
    schema_version attempt_result_sha256 attempt_manifest_sha256 \
    attempt_started_at attempt_finished_at audit_window_started_at \
    audit_window_finished_at page_identity_sha256 \
    instagram_identity_sha256 page_subscription_evidence_sha256 \
    instagram_subscription_evidence_sha256 messenger_recon_summary_sha256 \
    instagram_recon_summary_sha256 messenger_missing instagram_missing \
    messenger_threads_failed instagram_threads_failed messenger_caps_hit \
    instagram_caps_hit zero_unrecovered_deliveries audited_at
  test "$(manifest_value "$audit_manifest" schema_version)" = 1
  test "$(manifest_value "$audit_manifest" attempt_result_sha256)" = \
    "$(sha256_file "$result")"
  test "$(manifest_value "$audit_manifest" attempt_manifest_sha256)" = \
    "$(manifest_value "$result" attempt_manifest_sha256)"
  test "$(manifest_value "$audit_manifest" attempt_started_at)" = \
    "$(manifest_value "$result" started_at)"
  test "$(manifest_value "$audit_manifest" attempt_finished_at)" = \
    "$(manifest_value "$result" finished_at)"

  audit_directory="$(dirname "$audit_manifest")"
  messenger_subscription="$audit_directory/messenger-subscription.tsv"
  instagram_subscription="$audit_directory/instagram-subscription.tsv"
  messenger_recon="$audit_directory/messenger-recon-summary.tsv"
  instagram_recon="$audit_directory/instagram-recon-summary.tsv"
  for artifact in \
    "$messenger_subscription" "$instagram_subscription" \
    "$messenger_recon" "$instagram_recon"; do
    require_root_artifact "$artifact" "$(basename "$artifact")"
  done
  test "$(manifest_value "$audit_manifest" page_subscription_evidence_sha256)" = \
    "$(sha256_file "$messenger_subscription")"
  test "$(manifest_value "$audit_manifest" instagram_subscription_evidence_sha256)" = \
    "$(sha256_file "$instagram_subscription")"
  test "$(manifest_value "$audit_manifest" messenger_recon_summary_sha256)" = \
    "$(sha256_file "$messenger_recon")"
  test "$(manifest_value "$audit_manifest" instagram_recon_summary_sha256)" = \
    "$(sha256_file "$instagram_recon")"
  for platform in messenger instagram; do
    if [[ "$platform" == messenger ]]; then
      recon="$messenger_recon"
    else
      recon="$instagram_recon"
    fi
    test "$(stage_value "$recon" reconcile_summary missing)" = \
      "$(manifest_value "$audit_manifest" "${platform}_missing")"
    test "$(stage_value "$recon" reconcile_summary threads_failed)" = \
      "$(manifest_value "$audit_manifest" "${platform}_threads_failed")"
    test "$(stage_value "$recon" reconcile_summary caps_hit)" = \
      "$(manifest_value "$audit_manifest" "${platform}_caps_hit")"
    test "$(grep -c ' error=' "$recon")" = 0
    test "$(manifest_value "$audit_manifest" "${platform}_missing")" = 0
    test "$(manifest_value "$audit_manifest" "${platform}_threads_failed")" = 0
    test "$(manifest_value "$audit_manifest" "${platform}_caps_hit")" = 0
  done
  test "$(manifest_value "$audit_manifest" zero_unrecovered_deliveries)" = true
}

run_profile_attempt_phase() {
  local label="$1"
  local profile_phase="$2"
  local dry_run="$3"
  local platforms="$4"
  local require_zero_writes="$5"
  local result_directory="$PROFILE_RESULT_ROOT/$label"
  local result="$result_directory/fbig-profile-attempt-result-v1.tsv"
  local result_checksum="${result}.sha256"
  local wrapper_log="$result_directory/fbig-profile-wrapper.log"
  local arguments=(
    "$INBOX_ID" "$dry_run" "$platforms"
    "$HISTORY_DIR/fbig-approval-v2.tsv"
    "$HISTORY_DIR/fbig-approval-v2.tsv.sha256"
    "$PROFILE_APPROVAL" "$PROFILE_APPROVAL_CHECKSUM"
  )
  local statuses
  local attempt_directory
  local attempt_manifest
  local summary
  local prestate
  local poststate
  local backup_directory
  local backup_manifest
  local observed_zero=true
  local counter
  local temporary
  local checksum_temporary

  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  [[ "$profile_phase" =~ ^(dry|apply|idempotency)$ ]]
  test "$dry_run" = true || test "$dry_run" = false
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  test ! -e "$result_directory"
  mkdir "$result_directory"
  chmod 0700 "$result_directory"
  if [[ ",$platforms," == *,instagram,* ]]; then
    arguments+=("$TARGET_DIR/fbig-profile-targets-v1.tsv")
  fi

  set +e
  "$STACK_DIR/bin/fbig_profile_attempt.sh" "${arguments[@]}" 2>&1 |
    tee "$wrapper_log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  test "${#statuses[@]}" -eq 2
  test "${statuses[0]}" -eq 0
  test "${statuses[1]}" -eq 0
  chmod 0400 "$wrapper_log"
  test "$(grep -c '^\[UMI-FBIG\] stage=profile_attempt_complete ' "$wrapper_log")" = 1
  attempt_directory="$(
    stage_value "$wrapper_log" profile_attempt_complete attempt_directory
  )"
  backup_directory="$(
    stage_value "$wrapper_log" profile_attempt_complete backup_directory
  )"
  attempt_manifest="$attempt_directory/fbig-profile-production-attempt-v1.tsv"
  summary="$attempt_directory/fbig-profile-production-run-summary.tsv"
  prestate="$attempt_directory/fbig-profile-production-prestate-v1.tsv"
  poststate="$attempt_directory/fbig-profile-production-poststate-v1.tsv"
  backup_manifest="$backup_directory/fbig-profile-pre-attempt-backup-v1.tsv"

  if [[ "$dry_run" == true ]]; then
    observed_zero=false
  else
    cmp -s "$prestate" "$poststate" || observed_zero=false
    for counter in \
      scalar_changes_applied name_changes_applied username_changes_applied \
      optional_changes_applied avatars_attached avatar_bytes mirror_jobs; do
      if [[ "$(stage_value "$summary" history_profiles_summary "$counter")" != 0 ]]; then
        observed_zero=false
      fi
    done
  fi
  temporary="${result}.$$.tmp"
  checksum_temporary="${result_checksum}.$$.tmp"
  {
    printf 'schema_version\t1\n'
    printf 'label\t%s\n' "$label"
    printf 'profile_phase\t%s\n' "$profile_phase"
    printf 'predecessor_result_path\t%s\n' "$PREVIOUS_PROFILE_RESULT"
    if [[ "$PREVIOUS_PROFILE_RESULT" == none ]]; then
      printf 'predecessor_result_sha256\tnone\n'
      printf 'predecessor_audit_path\tnone\n'
      printf 'predecessor_audit_sha256\tnone\n'
    else
      printf 'predecessor_result_sha256\t%s\n' \
        "$(sha256_file "$PREVIOUS_PROFILE_RESULT")"
      printf 'predecessor_audit_path\t%s\n' "$PREVIOUS_PROFILE_AUDIT"
      printf 'predecessor_audit_sha256\t%s\n' \
        "$(sha256_file "$PREVIOUS_PROFILE_AUDIT")"
    fi
    printf 'attempt_directory\t%s\n' "$attempt_directory"
    printf 'attempt_manifest_sha256\t%s\n' "$(sha256_file "$attempt_manifest")"
    printf 'pre_attempt_backup_directory\t%s\n' "$backup_directory"
    printf 'pre_attempt_backup_sha256\t%s\n' "$(sha256_file "$backup_manifest")"
    printf 'wrapper_log_sha256\t%s\n' "$(sha256_file "$wrapper_log")"
    printf 'platforms\t%s\n' "$platforms"
    printf 'dry_run\t%s\n' "$dry_run"
    printf 'zero_write_observed\t%s\n' "$observed_zero"
    printf 'started_at\t%s\n' "$(manifest_value "$attempt_manifest" started_at)"
    printf 'finished_at\t%s\n' "$(manifest_value "$attempt_manifest" finished_at)"
    printf 'sealed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  chmod 0400 "$temporary"
  "$STORAGE_HELPER" fsync "$temporary"
  printf '%s  %s\n' "$(sha256_file "$temporary")" "$(basename "$result")" \
    >"$checksum_temporary"
  chmod 0400 "$checksum_temporary"
  "$STORAGE_HELPER" fsync "$checksum_temporary"
  mv "$temporary" "$result"
  mv "$checksum_temporary" "$result_checksum"
  "$STORAGE_HELPER" fsync "$result_directory"
  verify_profile_attempt_result "$result"
  printf '[UMI-FBIG] stage=profile_attempt_result result=%s zero_write_observed=%s\n' \
    "$result" "$observed_zero"
  if [[ "$require_zero_writes" == true && "$observed_zero" != true ]]; then
    return 42
  fi
}

produce_profile_delivery_audit() {
  local result="$1"
  local label
  local audit_directory
  local audit_manifest
  local audit_checksum
  local subscription_log
  local recon_log
  local messenger_subscription
  local instagram_subscription
  local messenger_recon
  local instagram_recon
  local grace_epoch
  local temporary
  local checksum_temporary

  verify_profile_attempt_result "$result"
  label="$(manifest_value "$result" label)"
  audit_directory="$PROFILE_DELIVERY_AUDIT_ROOT/$label"
  audit_manifest="$audit_directory/fbig-profile-delivery-audit-v1.tsv"
  audit_checksum="${audit_manifest}.sha256"
  subscription_log="$audit_directory/subscription-evidence.log"
  recon_log="$audit_directory/reconciliation.log"
  messenger_subscription="$audit_directory/messenger-subscription.tsv"
  instagram_subscription="$audit_directory/instagram-subscription.tsv"
  messenger_recon="$audit_directory/messenger-recon-summary.tsv"
  instagram_recon="$audit_directory/instagram-recon-summary.tsv"
  test ! -e "$audit_directory"
  grace_epoch="$(
    date -u -d "$(manifest_value "$result" finished_at) + 15 minutes" +%s
  )"
  test "$(date -u +%s)" -ge "$grace_epoch"
  mkdir "$audit_directory"
  chmod 0700 "$audit_directory"
  verify_production_release_and_schema

  docker compose exec -T \
    -e UMI_FBIG_AUDIT_INBOX_ID="$INBOX_ID" \
    rails bundle exec rails runner - <<'RUBY' >"$subscription_log"
require "digest"
inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_AUDIT_INBOX_ID"), 10))
channel = inbox.channel
abort("Facebook-page channel required") unless channel.is_a?(Channel::FacebookPage)
app_id = GlobalConfigService.load("FB_APP_ID", "").to_s
abort("FB_APP_ID missing") if app_id.blank?
api = Koala::Facebook::API.new(channel.page_access_token)
{
  messenger: [channel.page_id, %w[messages message_echoes]],
  instagram: [channel.instagram_id, %w[messages]]
}.each do |platform, (identity, required_fields)|
  abort("#{platform} identity missing") if identity.blank?
  rows = api.get_connections(
    identity, "subscribed_apps", fields: "id,subscribed_fields"
  ).to_a
  row = rows.find { |entry| entry.fetch("id").to_s == app_id }
  abort("#{platform} app subscription missing") unless row
  fields = Array(row["subscribed_fields"]).map(&:to_s).sort
  abort("#{platform} subscribed fields missing") unless
    (required_fields - fields).empty?
  puts [
    "[UMI-FBIG]", "stage=subscription_evidence", "platform=#{platform}",
    "identity_sha256=#{Digest::SHA256.hexdigest(identity.to_s)}",
    "app_id_sha256=#{Digest::SHA256.hexdigest(app_id)}",
    "subscribed_fields_sha256=#{Digest::SHA256.hexdigest(fields.join(','))}"
  ].join(" ")
end
RUBY
  grep '^\[UMI-FBIG\] stage=subscription_evidence platform=messenger ' \
    "$subscription_log" >"$messenger_subscription"
  grep '^\[UMI-FBIG\] stage=subscription_evidence platform=instagram ' \
    "$subscription_log" >"$instagram_subscription"
  test "$(wc -l <"$messenger_subscription")" = 1
  test "$(wc -l <"$instagram_subscription")" = 1

  docker compose exec -T \
    -e UMI_FBIG_RECON_HEAL=false \
    -e UMI_FBIG_AUDIT_INBOX_ID="$INBOX_ID" \
    rails bundle exec rails runner - <<'RUBY' >"$recon_log"
inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_AUDIT_INBOX_ID"), 10))
channel = inbox.channel
abort("Facebook-page channel required") unless channel.is_a?(Channel::FacebookPage)
Rails.logger = ActiveSupport::Logger.new($stdout)
Umi::Fbig::ConversationReconService.new(channel).perform
RUBY
  grep '^\[UMI-FBIG\] stage=reconcile_summary platform=messenger ' \
    "$recon_log" >"$messenger_recon"
  grep '^\[UMI-FBIG\] stage=reconcile_summary platform=instagram ' \
    "$recon_log" >"$instagram_recon"
  test "$(wc -l <"$messenger_recon")" = 1
  test "$(wc -l <"$instagram_recon")" = 1
  for recon in "$messenger_recon" "$instagram_recon"; do
    test "$(stage_value "$recon" reconcile_summary missing)" = 0
    test "$(stage_value "$recon" reconcile_summary threads_failed)" = 0
    test "$(stage_value "$recon" reconcile_summary caps_hit)" = 0
    test "$(grep -c ' error=' "$recon")" = 0
  done
  chmod 0400 \
    "$subscription_log" "$recon_log" "$messenger_subscription" \
    "$instagram_subscription" "$messenger_recon" "$instagram_recon"

  temporary="${audit_manifest}.$$.tmp"
  checksum_temporary="${audit_checksum}.$$.tmp"
  {
    printf 'schema_version\t1\n'
    printf 'attempt_result_sha256\t%s\n' "$(sha256_file "$result")"
    printf 'attempt_manifest_sha256\t%s\n' \
      "$(manifest_value "$result" attempt_manifest_sha256)"
    printf 'attempt_started_at\t%s\n' "$(manifest_value "$result" started_at)"
    printf 'attempt_finished_at\t%s\n' "$(manifest_value "$result" finished_at)"
    printf 'audit_window_started_at\t%s\n' \
      "$(manifest_value "$result" started_at)"
    printf 'audit_window_finished_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'page_identity_sha256\t%s\n' \
      "$(stage_value "$messenger_subscription" subscription_evidence identity_sha256)"
    printf 'instagram_identity_sha256\t%s\n' \
      "$(stage_value "$instagram_subscription" subscription_evidence identity_sha256)"
    printf 'page_subscription_evidence_sha256\t%s\n' \
      "$(sha256_file "$messenger_subscription")"
    printf 'instagram_subscription_evidence_sha256\t%s\n' \
      "$(sha256_file "$instagram_subscription")"
    printf 'messenger_recon_summary_sha256\t%s\n' "$(sha256_file "$messenger_recon")"
    printf 'instagram_recon_summary_sha256\t%s\n' "$(sha256_file "$instagram_recon")"
    printf 'messenger_missing\t0\n'
    printf 'instagram_missing\t0\n'
    printf 'messenger_threads_failed\t0\n'
    printf 'instagram_threads_failed\t0\n'
    printf 'messenger_caps_hit\t0\n'
    printf 'instagram_caps_hit\t0\n'
    printf 'zero_unrecovered_deliveries\ttrue\n'
    printf 'audited_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  chmod 0400 "$temporary"
  "$STORAGE_HELPER" fsync "$temporary"
  printf '%s  %s\n' \
    "$(sha256_file "$temporary")" "$(basename "$audit_manifest")" \
    >"$checksum_temporary"
  chmod 0400 "$checksum_temporary"
  "$STORAGE_HELPER" fsync "$checksum_temporary"
  mv "$temporary" "$audit_manifest"
  mv "$checksum_temporary" "$audit_checksum"
  "$STORAGE_HELPER" fsync "$audit_directory"
  verify_profile_delivery_audit "$audit_manifest" "$result"
  printf '[UMI-FBIG] stage=profile_delivery_audit_complete audit=%s\n' \
    "$audit_manifest"
}

case "$PROFILE_OPERATION" in
  attempt)
    if [[ "$PROFILE_PHASE" == dry ]]; then
      test "$PREVIOUS_PROFILE_RESULT" = none
      test "$PREVIOUS_PROFILE_AUDIT" = none
      run_profile_attempt_phase "$PROFILE_LABEL" dry true messenger false
    else
      verify_profile_attempt_result "$PREVIOUS_PROFILE_RESULT"
      verify_profile_delivery_audit \
        "$PREVIOUS_PROFILE_AUDIT" "$PREVIOUS_PROFILE_RESULT"
      if [[ "$PROFILE_PHASE" == apply ]]; then
        run_profile_attempt_phase \
          "$PROFILE_LABEL" apply false messenger,instagram false
      else
        test "$PROFILE_PHASE" = idempotency
        run_profile_attempt_phase \
          "$PROFILE_LABEL" idempotency false messenger,instagram true
      fi
    fi
    ;;
  audit)
    test "$CURRENT_PROFILE_RESULT" != none
    produce_profile_delivery_audit "$CURRENT_PROFILE_RESULT"
    ;;
  finalize)
    verify_profile_attempt_result "$CURRENT_PROFILE_RESULT"
    verify_profile_delivery_audit \
      "$CURRENT_PROFILE_AUDIT" "$CURRENT_PROFILE_RESULT"
    test "$(manifest_value "$CURRENT_PROFILE_RESULT" dry_run)" = false
    test "$(manifest_value "$CURRENT_PROFILE_RESULT" zero_write_observed)" = true
    verify_production_release_and_schema
    acquire_production_verification_lock
    inspect_production_unrecoverable_envelopes final-production
    release_production_verification_lock
    printf '[UMI-FBIG] stage=production_writes_complete final_audit_pending=true inbox_id=%s\n' \
      "$INBOX_ID"
    ;;
  *)
    printf 'invalid PROFILE_OPERATION\n' >&2
    exit 64
    ;;
esac
```

Execute dry attempt → dry audit → apply attempt → apply audit → idempotency
attempt → idempotency audit → finalize. If an intended idempotency attempt
returns `42`, its result was sealed first; treat it as another apply, audit it,
and use a new label for the next idempotency attempt. Never begin a new
maintenance window until the predecessor result and delivery audit recursively
validate. Re-running a completed phase means validating and supplying its
sealed path, not invoking the wrapper again.


If any wrapper exits nonzero, Rails and Sidekiq remain stopped. Review the
sealed attempt and its bound pre-attempt backup. If pre/post/staging evidence
is complete and the only deltas are counter-attributed fill-only transitions,
the same accepted release/settings may be retried only after a separately
reviewed decision. If evidence is partial, protected, unattributed, or a
different release/settings is required, use the exact binding, attempt, and
backup directories printed by the failed wrapper:

```bash
"$STACK_DIR/bin/fbig_profile_recover.sh" \
  "$INBOX_ID" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv.sha256" \
  '<failed fbig-profile-attempt directory>' \
  '<bound fbig-profile-pre-attempt directory>'
```

The recovery wrapper acquires the shared deployment lock, requires Rails and
Sidekiq to remain stopped, recursively validates the profile approval,
attempt binding, optional failed-attempt manifest, and backup components,
restores the database and storage into isolated targets, and proves the
regenerated PII-free state matches the attempt prestate. It then activates the
pair while writers remain stopped, verifies the activated state again, retains
the failed database/storage for audit, and resumes only after Rails readiness
and a live Sidekiq process are proven. Its sealed stage files make an
interrupted activation resumable with the same command. This rollout does not
authorize a predecessor approval override.

## 11. Final audit

Record per platform:

- threads and pages scanned;
- messages scanned, already present, imported incoming, imported outgoing, and
  accepted contentless omissions;
- the one exact pre/post/final-fingerprinted Instagram envelope with no
  external identity or representable message, reported as unrecoverable and
  excluded from conversation totals;
- contacts and non-empty archives created;
- attachments offered/downloaded/unavailable and bytes consumed;
- stable profile targets, successes, permanent unavailability, and blocking
  failures;
- the strict-parser-derived sealed Instagram seed count and its per-result
  conservation;
- exact placeholder-name repairs, username/optional-field fills, avatars
  offered/preserved/attached/unavailable, and avatar bytes; and
- the final zero-write history and profile summaries.

Also record the merged commit/digest, history/profile approval SHAs, all
coordinated backup and production attempt directories, migration/index proof,
and delivery audit. Profile mutation counters are aggregate across the selected
profile platforms because that task does not expose trustworthy per-platform
mutation counters; do not manufacture a split.

The final count artifact emits concrete `messenger_imported_messages` and
`instagram_imported_messages` fields, together with matching pre-existing/
current, direction, archive, attachment, and linked-contact fields. The
producer constructs the two identical field groups in a loop.

Produce and seal the final live-database reconciliation under the shared
production lock. This program reuses all exact constants/helpers from sections
9–10 and is installed as another protected, self-checksummed phase program:

```bash
FINAL_HISTORY_SUMMARY='<sealed final two-platform zero-write history summary>'
PRODUCTION_DRY_1_NORMALIZED="$AUDIT_DIR/production-history-dry-1-summary-normalized.tsv"
PRODUCTION_DRY_2_NORMALIZED="$AUDIT_DIR/production-history-dry-2-summary-normalized.tsv"
MESSENGER_APPLY_SUMMARY="$AUDIT_DIR/production-history-messenger-apply-summary.tsv"
INSTAGRAM_APPLY_SUMMARY="$AUDIT_DIR/production-history-instagram-apply-summary.tsv"
FINAL_PROFILE_RESULT='<sealed final zero-write profile result>'
FINAL_PROFILE_AUDIT='<sealed audit for final zero-write profile result>'
PRE_HISTORY_BACKUP_MANIFEST='<sealed pre-history coordinated backup manifest>'
FINAL_AUDIT_DIR="$AUDIT_DIR/final-production-audit"
FINAL_PLATFORM_COUNTS="$FINAL_AUDIT_DIR/fbig-production-platform-counts-v1.tsv"
FINAL_PLATFORM_COUNTS_CHECKSUM="${FINAL_PLATFORM_COUNTS}.sha256"
FINAL_SCHEMA_EVIDENCE="$FINAL_AUDIT_DIR/production-release-schema.tsv"
FINAL_ENVELOPE_EVIDENCE="$FINAL_AUDIT_DIR/production-unrecoverable-final.tsv"
FINAL_AUDIT_MANIFEST="$FINAL_AUDIT_DIR/fbig-production-migration-audit-v1.tsv"
FINAL_AUDIT_CHECKSUM="${FINAL_AUDIT_MANIFEST}.sha256"

produce_final_migration_audit() {
  local temporary
  local checksum_temporary
  local platform
  local current_value
  local summary_value
  local -a expected_final_count_fields

  test ! -e "$FINAL_AUDIT_DIR"
  mkdir "$FINAL_AUDIT_DIR"
  chmod 0700 "$FINAL_AUDIT_DIR"
  for artifact in \
    "$FINAL_HISTORY_SUMMARY" "$PRODUCTION_DRY_1_NORMALIZED" \
    "$PRODUCTION_DRY_2_NORMALIZED" "$MESSENGER_APPLY_SUMMARY" \
    "$INSTAGRAM_APPLY_SUMMARY" "$CLONE_BASELINE" \
    "$PRE_HISTORY_BACKUP_MANIFEST" "${PRE_HISTORY_BACKUP_MANIFEST}.sha256"; do
    require_root_artifact "$artifact" "$(basename "$artifact")"
  done
  verify_checksum \
    "$PRE_HISTORY_BACKUP_MANIFEST" "${PRE_HISTORY_BACKUP_MANIFEST}.sha256"
  cmp -s "$PRODUCTION_DRY_1_NORMALIZED" "$PRODUCTION_DRY_2_NORMALIZED"
  validate_history_apply_summary \
    "$FINAL_HISTORY_SUMMARY" true messenger,instagram
  verify_profile_attempt_result "$FINAL_PROFILE_RESULT"
  verify_profile_delivery_audit "$FINAL_PROFILE_AUDIT" "$FINAL_PROFILE_RESULT"
  test "$(manifest_value "$FINAL_PROFILE_RESULT" dry_run)" = false
  test "$(manifest_value "$FINAL_PROFILE_RESULT" zero_write_observed)" = true

  verify_production_release_and_schema >"$FINAL_SCHEMA_EVIDENCE"
  acquire_production_verification_lock
  load_scoped_baseline_ids "$CLONE_BASELINE"
  docker compose exec -T \
    -e UMI_FBIG_AUDIT_INBOX_ID="$INBOX_ID" \
    -e UMI_FBIG_AUDIT_DATABASE="$PRODUCTION_DATABASE" \
    -e FBIG_ARCHIVE_IDS="$FBIG_ARCHIVE_IDS" \
    -e FBIG_MESSAGE_IDS="$FBIG_MESSAGE_IDS" \
    -e FBIG_ATTACHMENT_IDS="$FBIG_ATTACHMENT_IDS" \
    rails bundle exec rails runner - <<'RUBY' >"$FINAL_PLATFORM_COUNTS"
inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_AUDIT_INBOX_ID"), 10))
actual_database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
abort("production database mismatch") unless
  actual_database == ENV.fetch("UMI_FBIG_AUDIT_DATABASE")
parse_ids = lambda do |name|
  value = ENV.fetch(name)
  value.empty? ? [] : value.split(",").map { |item| Integer(item, 10) }
end
baseline_archive_ids = parse_ids.call("FBIG_ARCHIVE_IDS")
baseline_message_ids = parse_ids.call("FBIG_MESSAGE_IDS")
baseline_attachment_ids = parse_ids.call("FBIG_ATTACHMENT_IDS")
archives = inbox.conversations.where(
  "jsonb_exists(conversations.additional_attributes, :key)",
  key: "umi_history_import"
)
messages = Message.where(inbox_id: inbox.id).where(
  "messages.additional_attributes ->> 'umi_history_import' = 'true'"
)
attachments = Attachment.joins(:message).where(messages: { inbox_id: inbox.id }).where(
  "attachments.meta ->> 'umi_history_import' = 'true'"
)
values = { "schema_version" => 1 }
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
  values["#{platform}_preexisting_archives"] =
    platform_archives.where(id: baseline_archive_ids).count
  values["#{platform}_current_archives"] =
    values.fetch("#{platform}_archives") -
    values.fetch("#{platform}_preexisting_archives")
  values["#{platform}_imported_messages"] = platform_messages.count
  values["#{platform}_preexisting_messages"] =
    platform_messages.where(id: baseline_message_ids).count
  values["#{platform}_current_messages"] =
    values.fetch("#{platform}_imported_messages") -
    values.fetch("#{platform}_preexisting_messages")
  values["#{platform}_incoming"] =
    platform_messages.where(message_type: Message.message_types.fetch("incoming")).count
  values["#{platform}_current_incoming"] =
    platform_messages.where.not(id: baseline_message_ids)
                     .where(message_type: Message.message_types.fetch("incoming")).count
  values["#{platform}_outgoing"] =
    platform_messages.where(message_type: Message.message_types.fetch("outgoing")).count
  values["#{platform}_current_outgoing"] =
    platform_messages.where.not(id: baseline_message_ids)
                     .where(message_type: Message.message_types.fetch("outgoing")).count
  values["#{platform}_attachments"] = platform_attachments.count
  values["#{platform}_preexisting_attachments"] =
    platform_attachments.where(attachments: { id: baseline_attachment_ids }).count
  values["#{platform}_current_attachments"] =
    values.fetch("#{platform}_attachments") -
    values.fetch("#{platform}_preexisting_attachments")
  values["#{platform}_linked_contacts"] =
    platform_archives.distinct.count(:contact_id)
  values["#{platform}_preexisting_linked_contacts"] =
    platform_archives.where(id: baseline_archive_ids).distinct.count(:contact_id)
end
values["empty_importer_archives"] =
  archives.left_joins(:messages).group("conversations.id")
          .having("COUNT(messages.id) = 0").count.size
values["duplicate_imported_source_ids"] =
  messages.group(:source_id).having("COUNT(*) > 1").count.size
values["invalid_importer_archives"] = archives.where(
  "status <> :resolved OR assignee_id IS NOT NULL OR team_id IS NOT NULL " \
  "OR waiting_since IS NOT NULL OR first_reply_created_at IS NOT NULL",
  resolved: Conversation.statuses.fetch("resolved")
).count
values["duplicate_contact_avatars"] = ActiveStorage::Attachment
  .where(record_type: "Contact", name: "avatar")
  .group(:record_id).having("COUNT(*) > 1").count.size
values["unclassified_importer_messages"] = messages.where.not(
  "messages.additional_attributes ->> 'umi_history_platform' IN (?)",
  %w[messenger instagram]
).count
order = [
  "schema_version",
  *%w[messenger instagram].flat_map do |platform|
    %W[
      #{platform}_archives #{platform}_preexisting_archives
      #{platform}_current_archives #{platform}_imported_messages
      #{platform}_preexisting_messages #{platform}_current_messages
      #{platform}_incoming #{platform}_current_incoming
      #{platform}_outgoing #{platform}_current_outgoing
      #{platform}_attachments #{platform}_preexisting_attachments
      #{platform}_current_attachments #{platform}_linked_contacts
      #{platform}_preexisting_linked_contacts
    ]
  end,
  "empty_importer_archives", "duplicate_imported_source_ids",
  "invalid_importer_archives", "duplicate_contact_avatars",
  "unclassified_importer_messages"
]
order.each { |key| puts "#{key}\t#{values.fetch(key)}" }
RUBY
  inspect_production_unrecoverable_envelopes final-audit
  cp "$AUDIT_DIR/production-unrecoverable-final-audit.tsv" \
    "$FINAL_ENVELOPE_EVIDENCE"
  chmod 0400 \
    "$FINAL_PLATFORM_COUNTS" "$FINAL_SCHEMA_EVIDENCE" \
    "$FINAL_ENVELOPE_EVIDENCE"
  release_production_verification_lock
  expected_final_count_fields=(schema_version)
  for platform in messenger instagram; do
    expected_final_count_fields+=(
      "${platform}_archives" "${platform}_preexisting_archives"
      "${platform}_current_archives" "${platform}_imported_messages"
      "${platform}_preexisting_messages" "${platform}_current_messages"
      "${platform}_incoming" "${platform}_current_incoming"
      "${platform}_outgoing" "${platform}_current_outgoing"
      "${platform}_attachments" "${platform}_preexisting_attachments"
      "${platform}_current_attachments" "${platform}_linked_contacts"
      "${platform}_preexisting_linked_contacts"
    )
  done
  expected_final_count_fields+=(
    empty_importer_archives duplicate_imported_source_ids
    invalid_importer_archives duplicate_contact_avatars
    unclassified_importer_messages
  )
  require_ordered_fields \
    "$FINAL_PLATFORM_COUNTS" "${expected_final_count_fields[@]}"

  for invariant in \
    empty_importer_archives duplicate_imported_source_ids \
    invalid_importer_archives duplicate_contact_avatars \
    unclassified_importer_messages; do
    test "$(manifest_value "$FINAL_PLATFORM_COUNTS" "$invariant")" = 0
  done
  for platform in messenger instagram; do
    if [[ "$platform" == messenger ]]; then
      apply_summary="$MESSENGER_APPLY_SUMMARY"
    else
      apply_summary="$INSTAGRAM_APPLY_SUMMARY"
    fi
    for equation in \
      current_archives:imported_archives \
      current_messages:imported_messages \
      current_incoming:imported_incoming \
      current_outgoing:imported_outgoing \
      current_attachments:imported_attachments; do
      current_value="$(
        manifest_value "$FINAL_PLATFORM_COUNTS" \
          "${platform}_${equation%%:*}"
      )"
      summary_value="$(
        stage_value "$apply_summary" history_import_summary "${equation##*:}"
      )"
      test "$current_value" = "$summary_value"
    done
    test "$(
      manifest_value "$FINAL_PLATFORM_COUNTS" "${platform}_imported_messages"
    )" = "$(
      (
        printf '%s\n' \
          "$(manifest_value "$FINAL_PLATFORM_COUNTS" "${platform}_incoming")" \
          "$(manifest_value "$FINAL_PLATFORM_COUNTS" "${platform}_outgoing")"
      ) | awk '{ total += $1 } END { print total + 0 }'
    )"
  done
  test "$(stage_value "$FINAL_ENVELOPE_EVIDENCE" \
    unrecoverable_envelope_inspection count)" = \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
  test "$(stage_value "$FINAL_ENVELOPE_EVIDENCE" \
    unrecoverable_envelope_inspection fingerprint)" = \
    "$(manifest_value "$UNRECOVERABLE_SIDECAR" fingerprint)"

  printf '%s  %s\n' \
    "$(sha256_file "$FINAL_PLATFORM_COUNTS")" \
    "$(basename "$FINAL_PLATFORM_COUNTS")" \
    >"$FINAL_PLATFORM_COUNTS_CHECKSUM"
  chmod 0400 "$FINAL_PLATFORM_COUNTS_CHECKSUM"
  verify_checksum "$FINAL_PLATFORM_COUNTS" "$FINAL_PLATFORM_COUNTS_CHECKSUM"

  temporary="${FINAL_AUDIT_MANIFEST}.$$.tmp"
  checksum_temporary="${FINAL_AUDIT_CHECKSUM}.$$.tmp"
  {
    printf 'schema_version\t1\n'
    printf 'repository_commit\t%s\n' "$APP_COMMIT"
    printf 'image_digest\t%s\n' "$APP_DIGEST"
    printf 'inbox_id\t%s\n' "$INBOX_ID"
    printf 'r4_acceptance_sha256\t%s\n' \
      "$(sha256_file "$R4_ACCEPTANCE_MANIFEST")"
    printf 'history_approval_sha256\t%s\n' \
      "$(sha256_file "$HISTORY_APPROVAL")"
    printf 'profile_approval_sha256\t%s\n' \
      "$(sha256_file "$PROFILE_APPROVAL")"
    printf 'pre_history_backup_sha256\t%s\n' \
      "$(sha256_file "$PRE_HISTORY_BACKUP_MANIFEST")"
    printf 'platform_counts_sha256\t%s\n' \
      "$(sha256_file "$FINAL_PLATFORM_COUNTS")"
    printf 'production_dry_1_sha256\t%s\n' \
      "$(sha256_file "$PRODUCTION_DRY_1_NORMALIZED")"
    printf 'production_dry_2_sha256\t%s\n' \
      "$(sha256_file "$PRODUCTION_DRY_2_NORMALIZED")"
    printf 'messenger_apply_summary_sha256\t%s\n' \
      "$(sha256_file "$MESSENGER_APPLY_SUMMARY")"
    printf 'instagram_apply_summary_sha256\t%s\n' \
      "$(sha256_file "$INSTAGRAM_APPLY_SUMMARY")"
    printf 'messenger_contacts_created_current_apply\t%s\n' \
      "$(stage_value "$MESSENGER_APPLY_SUMMARY" \
        history_import_summary imported_contacts)"
    printf 'instagram_contacts_created_current_apply\t%s\n' \
      "$(stage_value "$INSTAGRAM_APPLY_SUMMARY" \
        history_import_summary imported_contacts)"
    printf 'final_history_summary_sha256\t%s\n' \
      "$(sha256_file "$FINAL_HISTORY_SUMMARY")"
    printf 'final_profile_result_sha256\t%s\n' \
      "$(sha256_file "$FINAL_PROFILE_RESULT")"
    printf 'final_profile_audit_sha256\t%s\n' \
      "$(sha256_file "$FINAL_PROFILE_AUDIT")"
    printf 'pre_history_backup_directory\t%s\n' \
      "$(dirname "$PRE_HISTORY_BACKUP_MANIFEST")"
    printf 'final_profile_attempt_directory\t%s\n' \
      "$(manifest_value "$FINAL_PROFILE_RESULT" attempt_directory)"
    printf 'final_profile_backup_directory\t%s\n' \
      "$(manifest_value "$FINAL_PROFILE_RESULT" pre_attempt_backup_directory)"
    printf 'final_profile_audit_directory\t%s\n' \
      "$(dirname "$FINAL_PROFILE_AUDIT")"
    printf 'release_schema_evidence_sha256\t%s\n' \
      "$(sha256_file "$FINAL_SCHEMA_EVIDENCE")"
    printf 'unrecoverable_evidence_sha256\t%s\n' \
      "$(sha256_file "$FINAL_ENVELOPE_EVIDENCE")"
    printf 'unrecoverable_instagram_envelopes\t%s\n' \
      "$(manifest_value "$UNRECOVERABLE_SIDECAR" count)"
    printf 'profile_mutations_are_aggregate\ttrue\n'
    printf 'audited_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  chmod 0400 "$temporary"
  "$STORAGE_HELPER" fsync "$temporary"
  printf '%s  %s\n' \
    "$(sha256_file "$temporary")" "$(basename "$FINAL_AUDIT_MANIFEST")" \
    >"$checksum_temporary"
  chmod 0400 "$checksum_temporary"
  "$STORAGE_HELPER" fsync "$checksum_temporary"
  mv "$temporary" "$FINAL_AUDIT_MANIFEST"
  mv "$checksum_temporary" "$FINAL_AUDIT_CHECKSUM"
  "$STORAGE_HELPER" fsync "$FINAL_AUDIT_DIR"
  require_root_artifact \
    "$FINAL_AUDIT_MANIFEST" fbig-production-migration-audit-v1.tsv
  require_root_artifact \
    "$FINAL_AUDIT_CHECKSUM" fbig-production-migration-audit-v1.tsv.sha256
  verify_checksum "$FINAL_AUDIT_MANIFEST" "$FINAL_AUDIT_CHECKSUM"
  require_ordered_fields "$FINAL_AUDIT_MANIFEST" \
    schema_version repository_commit image_digest inbox_id \
    r4_acceptance_sha256 history_approval_sha256 profile_approval_sha256 \
    pre_history_backup_sha256 platform_counts_sha256 \
    production_dry_1_sha256 production_dry_2_sha256 \
    messenger_apply_summary_sha256 instagram_apply_summary_sha256 \
    messenger_contacts_created_current_apply \
    instagram_contacts_created_current_apply \
    final_history_summary_sha256 final_profile_result_sha256 \
    final_profile_audit_sha256 pre_history_backup_directory \
    final_profile_attempt_directory final_profile_backup_directory \
    final_profile_audit_directory release_schema_evidence_sha256 \
    unrecoverable_evidence_sha256 unrecoverable_instagram_envelopes \
    profile_mutations_are_aggregate audited_at
  printf '[UMI-FBIG] stage=production_migration_complete audit_sha256=%s inbox_id=%s\n' \
    "$(sha256_file "$FINAL_AUDIT_MANIFEST")" "$INBOX_ID"
}

produce_final_migration_audit
```

Only the checksummed final manifest authorizes the completion statement: all
history and profile data still exposed by Meta was migrated; exact
API-unavailable data is counted and retained as a limitation.
