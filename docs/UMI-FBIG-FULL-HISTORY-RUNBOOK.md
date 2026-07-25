# UMI Facebook and Instagram full-history import runbook

This is the executable runbook for the one-time UMI migration. It imports every
Messenger and Instagram conversation and message that Meta still exposes,
creates no empty archive, and then enriches the resulting contacts without
overwriting existing names, usernames, profile fields, or avatars.

Meta can permanently omit old message bodies, attachments, profiles, or whole
threads. Those omissions are reported and approved by exact aggregate
fingerprints; they are never replaced with invented messages or user data.

The accepted release is an immutable
`ghcr.io/shumkov/chatwoot@sha256:<64 lowercase hex>` digest. Candidate evidence,
a moving tag, and evidence from another database are not production approval.

## 1. Stop conditions

Stop immediately if any of these is true:

- Rails or Sidekiq does not use the expected digest.
- The compose image for a one-off does not resolve to that same digest.
- the connected database name is not the explicitly expected database;
- the clone database or storage mount is not isolated from production;
- a root-owned artifact is not in a `0700` non-link directory with immutable
  `0400`, single-link files;
- either approved dry run differs from the acceptance probe;
- a history run reports a new contentless count/fingerprint;
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

test "$(id -u)" -eq 0
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$CLONE_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
test "$CLONE_DATABASE" != "$PRODUCTION_DATABASE"
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
test -n "$APPROVED_BY"
[[ "$APPROVED_BY" != *$'\t'* && "$APPROVED_BY" != *$'\n'* && "$APPROVED_BY" != *$'\r'* ]]
test "$(printf '%s' "$APPROVED_BY" | wc -c)" -le 255
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
      for (index = 2; index <= NF; index += 1) {
        if ($index == "stage=" expected_stage) selected = 1
      }
      if (selected) {
        rows += 1
        for (index = 2; index <= NF; index += 1) {
          split($index, pair, "=")
          if (pair[1] == expected_key) {
            values += 1
            value = substr($index, length(expected_key) + 2)
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
```

The immutable input artifacts are:

- `fbig-profile-targets-v1.tsv`: exactly six sorted
  `contact_inbox_id<TAB>contact_id<TAB>source_id` rows;
- `fbig-approval-v1.tsv` plus `.sha256`: the exact 25-field
  `HistoryApprovalManifest::FIELD_NAMES` order;
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
- the six-row target SHA; and
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

Create the strict six-row Instagram placeholder target file from the restored
clone before history can add contacts. The query uses noclobber and fails unless
the persisted production snapshot contains exactly the six exact legacy
placeholder names:

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
    rows = inbox.contact_inboxes.includes(:contact).select do |contact_inbox|
      source_id = contact_inbox.source_id.to_s
      source_id.match?(/\A[1-9][0-9]*\z/) &&
        contact_inbox.contact&.name == "Instagram user #{source_id.last(4)}"
    end.sort_by(&:id)
    abort("expected exactly six Instagram placeholder targets") unless rows.size == 6
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
        "jsonb_exists(additional_attributes, :key)",
        key: "umi_history_import"
      )
      duplicate_message_sources = Message
        .where(inbox_id: inbox.id)
        .where(
          "additional_attributes ->> :key = :value",
          key: "umi_history_import",
          value: "true"
        )
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

CONTENTLESS_MISMATCHES="$(
  stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary contentless_acceptance_mismatches
)"
EXIT_FAILURES="$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary exit_failures)"
[[ "$CONTENTLESS_MISMATCHES" =~ ^[1-9][0-9]*$ ]]
test "$EXIT_FAILURES" = "$CONTENTLESS_MISMATCHES"
test "$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary scan_complete)" = true
for counter in \
  failed_threads platform_failures retry_exhaustion authentication_failures lock_loss \
  profile_requests profile_successes profile_unavailable profile_errors \
  profile_changes_projected profile_changes_applied avatars_offered avatars_preserved \
  avatars_attached avatars_raced avatars_unavailable avatar_failures \
  avatars_skipped_history_incomplete avatar_bytes; do
  test "$(stage_value "$HISTORY_PROBE_SUMMARY" history_import_summary "$counter")" = 0
done
chmod 0400 "$HISTORY_PROBE_LOG" "$HISTORY_PROBE_SUMMARY"
test "$(stat -c '%u:%a:%h' "$HISTORY_PROBE_LOG")" = "0:400:1"
test "$(stat -c '%u:%a:%h' "$HISTORY_PROBE_SUMMARY")" = "0:400:1"
```

The only allowed failure above is exact contentless-set mismatch. Review the
per-platform counts/fingerprints, then construct the approval in the parser's
exact field order. Every provenance hash is recomputed from its immutable
artifact, the full random-suffixed coordinated backup ID is copied byte for
byte, and permissions are sealed before the in-image loader runs:

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

test "$DATABASE_DUMP_SHA256" = "$(manifest_value "$BACKUP_MANIFEST" database_dump_sha256)"
test "$SOURCE_STORAGE_MANIFEST_SHA256" = \
  "$(manifest_value "$BACKUP_MANIFEST" storage_manifest_sha256)"
[[ "$BACKUP_ID" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]]
[[ "$MESSENGER_CONTENTLESS_COUNT" =~ ^(0|[1-9][0-9]*)$ ]]
[[ "$INSTAGRAM_CONTENTLESS_COUNT" =~ ^(0|[1-9][0-9]*)$ ]]
[[ "$MESSENGER_CONTENTLESS_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]
[[ "$INSTAGRAM_CONTENTLESS_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]

HISTORY_APPROVAL="$HISTORY_DIR/fbig-approval-v1.tsv"
HISTORY_APPROVAL_CHECKSUM="$HISTORY_DIR/fbig-approval-v1.tsv.sha256"
test ! -e "$HISTORY_APPROVAL"
test ! -e "$HISTORY_APPROVAL_CHECKSUM"
APPROVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(
  set -o noclobber
  {
    printf 'schema_version\t1\n'
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
      manifest_path: "/run/fbig/history/fbig-approval-v1.tsv",
      checksum_path: "/run/fbig/history/fbig-approval-v1.tsv.sha256"
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
            targets.size == 6
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
    -e UMI_FBIG_APPROVAL_MANIFEST_PATH=/run/fbig/history/fbig-approval-v1.tsv \
    -e UMI_FBIG_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-approval-v1.tsv.sha256 \
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
      --restrict-key=UMI_FBIG_CLONE_DATABASE_FINGERPRINT |
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
      for (index = 1; index <= NF; index += 1) {
        if ($index ~ /^(contentless_acceptance_mismatches|exit_failures)=/) continue
        output = output (output == "" ? "" : " ") $index
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
  local observed_degraded
  local attachments_unavailable
  local platform
  local approved_count
  local approved_fingerprint
  local observed_count
  local observed_fingerprint
  local -a selected_platforms
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  [[ "$platforms" =~ ^(messenger|instagram|messenger,instagram)$ ]]
  test "$(stage_value "$summary" history_import_summary dry_run)" = false
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = true
  test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
  for counter in \
    ambiguous_participants ambiguous_senders foreign_source_id_anomalies \
    failed_threads platform_failures retry_exhaustion authentication_failures \
    lock_loss reindex_failures download_budget_exhaustions; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done

  IFS=',' read -r -a selected_platforms <<<"$platforms"
  for platform in "${selected_platforms[@]}"; do
    approved_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v1.tsv" "${platform}_count"
    )"
    approved_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v1.tsv" "${platform}_fingerprint"
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
    if [[ "$approved_count" != 0 ]]; then
      expected_degraded=true
    fi
  done

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

  set +e
  history_run true messenger,instagram 2>&1 | tee "$log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  test "${#statuses[@]}" -eq 2
  test "${statuses[0]}" -eq 0
  test "${statuses[1]}" -eq 0
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$log")" -eq 1
  grep '^\[UMI-FBIG\] stage=history_import_summary ' "$log" >"$summary"
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = not_applicable
  test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
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

  set +e
  history_run false "$platforms" "$budget" 2>&1 | tee "$log"
  statuses=("${PIPESTATUS[@]}")
  set -e
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
    -e UMI_FBIG_APPROVAL_MANIFEST_PATH=/run/fbig/history/fbig-approval-v1.tsv \
    -e UMI_FBIG_APPROVAL_CHECKSUM_PATH=/run/fbig/history/fbig-approval-v1.tsv.sha256 \
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
all six seeds. Blocking outcomes are not approval. Preserve and hash the three
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
      instagram_targets_blocking 0 \
      seed_targets 6 \
      seed_targets_complete 6 \
      seed_targets_blocking 0
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
      manifest_path: "/run/fbig/history/fbig-approval-v1.tsv",
      checksum_path: "/run/fbig/history/fbig-approval-v1.tsv.sha256"
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
      targets.size == 6
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

On the VPS, require Rails, Sidekiq, and the compose image to resolve to
`$APP_DIGEST`. Verify `schema_migrations` contains the Contact/avatar unique
index migration and rerun the duplicate-avatar/index check from section 4
against `$PRODUCTION_DATABASE`.

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

```bash
set -Eeuo pipefail
umask 077

INBOX_ID='<same numeric inbox id>'
PRODUCTION_DATABASE='chatwoot_production'
APP_COMMIT='<same 40 lowercase hex merged commit>'
APP_DIGEST='ghcr.io/shumkov/chatwoot@sha256:<same accepted 64-hex digest>'
STACK_DIR='/opt/umi/chatwoot'
AUDIT_DIR='/opt/umi/fbig-audit/<same acceptance id>'
HISTORY_DIR="$AUDIT_DIR/history-approval"
PROFILE_DIR="$AUDIT_DIR/profile-approval"
TARGET_DIR="$AUDIT_DIR/profile-targets"
CLONE_BASELINE="$AUDIT_DIR/clone-scoped-baseline.txt"
SCOPED_SNAPSHOT_SCRIPT="$AUDIT_DIR/fbig-scoped-baseline.rb"

test "$(id -u)" -eq 0
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$PRODUCTION_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
for path in \
  "$CLONE_BASELINE" "$SCOPED_SNAPSHOT_SCRIPT" \
  "$AUDIT_DIR/history-dry-1-summary-normalized.tsv" \
  "$HISTORY_DIR/fbig-approval-v1.tsv" \
  "$HISTORY_DIR/fbig-approval-v1.tsv.sha256"; do
  test "$(stat -c '%u:%a:%h' "$path")" = "0:400:1"
done

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
      for (index = 2; index <= NF; index += 1) {
        if ($index == "stage=" expected_stage) selected = 1
      }
      if (selected) {
        rows += 1
        for (index = 2; index <= NF; index += 1) {
          split($index, pair, "=")
          if (pair[1] == expected_key) {
            values += 1
            value = substr($index, length(expected_key) + 2)
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
      for (index = 1; index <= NF; index += 1) {
        if ($index ~ /^(contentless_acceptance_mismatches|exit_failures)=/) continue
        output = output (output == "" ? "" : " ") $index
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
  local observed_degraded
  local attachments_unavailable
  local platform
  local approved_count
  local approved_fingerprint
  local observed_count
  local observed_fingerprint
  local -a selected_platforms
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  [[ "$platforms" =~ ^(messenger|instagram|messenger,instagram)$ ]]
  test "$(stage_value "$summary" history_import_summary dry_run)" = false
  test "$(stage_value "$summary" history_import_summary scan_complete)" = true
  test "$(stage_value "$summary" history_import_summary write_complete)" = true
  test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
  test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
  for counter in \
    ambiguous_participants ambiguous_senders foreign_source_id_anomalies \
    failed_threads platform_failures retry_exhaustion authentication_failures \
    lock_loss reindex_failures download_budget_exhaustions; do
    test "$(stage_value "$summary" history_import_summary "$counter")" = 0
  done

  IFS=',' read -r -a selected_platforms <<<"$platforms"
  for platform in "${selected_platforms[@]}"; do
    approved_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v1.tsv" "${platform}_count"
    )"
    approved_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v1.tsv" "${platform}_fingerprint"
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
    if [[ "$approved_count" != 0 ]]; then
      expected_degraded=true
    fi
  done

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
  local observed="$AUDIT_DIR/production-scoped-$label.txt"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  test ! -e "$observed"
  production_scoped_snapshot >"$observed"
  cmp -s "$CLONE_BASELINE" "$observed"
  chmod 0400 "$observed"

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
        "jsonb_exists(additional_attributes, :key)",
        key: "umi_history_import"
      )
      duplicate_message_sources = Message
        .where(inbox_id: inbox.id)
        .where(
          "additional_attributes ->> :key = :value",
          key: "umi_history_import",
          value: "true"
        )
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
    "$HISTORY_DIR/fbig-approval-v1.tsv"
    "$HISTORY_DIR/fbig-approval-v1.tsv.sha256"
  )
  local statuses
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]
  test "$require_zero_writes" = true || test "$require_zero_writes" = false
  test ! -e "$log"
  test ! -e "$summary"
  if [[ "$dry_run" == false ]]; then
    [[ "$budget" =~ ^[1-9][0-9]*$ ]]
    arguments+=("$budget")
  else
    test "$dry_run" = true
    test -z "$budget"
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
  verify_production_history_state "$label"

  if [[ "$dry_run" == true ]]; then
    test "$require_zero_writes" = false
    test "$(stage_value "$summary" history_import_summary scan_complete)" = true
    test "$(stage_value "$summary" history_import_summary write_complete)" = not_applicable
    test "$(stage_value "$summary" history_import_summary contentless_acceptance_mismatches)" = 0
    test "$(stage_value "$summary" history_import_summary exit_failures)" = 0
    normalize_history_summary "$summary" >"$normalized"
    cmp -s "$AUDIT_DIR/history-dry-1-summary-normalized.tsv" "$normalized"
    chmod 0400 "$normalized"
  else
    validate_history_apply_summary "$summary" false "$platforms"
  fi
  chmod 0400 "$log" "$summary"
  if [[ "$dry_run" == false ]]; then
    validate_history_apply_summary "$summary" "$require_zero_writes" "$platforms"
  fi
}

load_scoped_baseline_ids "$CLONE_BASELINE"
verify_production_history_state before-production-history
production_history_run_with_verification dry-1 true messenger,instagram
production_history_run_with_verification dry-2 true messenger,instagram
cmp -s \
  "$AUDIT_DIR/production-history-dry-1-summary-normalized.tsv" \
  "$AUDIT_DIR/production-history-dry-2-summary-normalized.tsv"
```

Immediately before the first production history apply, take a new coordinated
backup under the accepted digest:

```bash
"$STACK_DIR/bin/fbig_coordinated_backup.sh" "$INBOX_ID" "$APP_DIGEST" |
  tee "$AUDIT_DIR/pre-history-production-backup.log"
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

```bash
"$STACK_DIR/bin/fbig_profile_attempt.sh" \
  "$INBOX_ID" true messenger \
  "$HISTORY_DIR/fbig-approval-v1.tsv" \
  "$HISTORY_DIR/fbig-approval-v1.tsv.sha256" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv.sha256"

"$STACK_DIR/bin/fbig_profile_attempt.sh" \
  "$INBOX_ID" false messenger,instagram \
  "$HISTORY_DIR/fbig-approval-v1.tsv" \
  "$HISTORY_DIR/fbig-approval-v1.tsv.sha256" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv.sha256" \
  "$TARGET_DIR/fbig-profile-targets-v1.tsv"

"$STACK_DIR/bin/fbig_profile_attempt.sh" \
  "$INBOX_ID" false messenger,instagram \
  "$HISTORY_DIR/fbig-approval-v1.tsv" \
  "$HISTORY_DIR/fbig-approval-v1.tsv.sha256" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv" \
  "$PROFILE_DIR/fbig-profile-approval-v1.tsv.sha256" \
  "$TARGET_DIR/fbig-profile-targets-v1.tsv"
```

The third command is the zero-write idempotency proof. Audit webhook retry and
subscription state after every maintenance window.

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
- contacts and non-empty archives created;
- attachments offered/downloaded/unavailable and bytes consumed;
- stable profile targets, successes, permanent unavailability, and blocking
  failures;
- exact placeholder-name repairs, username/optional-field fills, avatars
  offered/preserved/attached/unavailable, and avatar bytes; and
- the final zero-write history and profile summaries.

Also record the merged commit/digest, history/profile approval SHAs, all
coordinated backup and production attempt directories, migration/index proof,
and webhook retry audit. The honest completion statement is: all history and
profile data still exposed by Meta was migrated; exact API-unavailable data is
counted and retained as a limitation.
