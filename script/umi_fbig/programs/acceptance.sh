readonly ACCEPTANCE_BINDING="${1:?acceptance binding is required}"
readonly ACCEPTANCE_BINDING_CHECKSUM="${ACCEPTANCE_BINDING}.sha256"
readonly ACCEPTANCE_BINDING_FIELDS=(
  schema_version acceptance_id inbox_id production_database clone_database
  candidate_commit candidate_image approved_by stack_dir audit_dir clone_storage
  production_storage backup_dir history_cutoff
  expected_instagram_unrecoverable_threads
  expected_instagram_unavailable_message_threads profile_graph_delay_ms
  profile_max_conversation_pages profile_max_rate_limit_wait_seconds
  profile_max_download_bytes history_max_download_bytes storage_helper
  storage_helper_sha256 ops_dir acceptance_unit unit_fragment_path
  acceptance_finalizer_lock
)

verify_checksum "$ACCEPTANCE_BINDING" "$ACCEPTANCE_BINDING_CHECKSUM"
require_ordered_manifest "$ACCEPTANCE_BINDING" "${ACCEPTANCE_BINDING_FIELDS[@]}"
test "$(manifest_value "$ACCEPTANCE_BINDING" schema_version)" = 1
ACCEPTANCE_ID="$(manifest_value "$ACCEPTANCE_BINDING" acceptance_id)"
INBOX_ID="$(manifest_value "$ACCEPTANCE_BINDING" inbox_id)"
PRODUCTION_DATABASE="$(manifest_value "$ACCEPTANCE_BINDING" production_database)"
CLONE_DATABASE="$(manifest_value "$ACCEPTANCE_BINDING" clone_database)"
APP_COMMIT="$(manifest_value "$ACCEPTANCE_BINDING" candidate_commit)"
APP_DIGEST="$(manifest_value "$ACCEPTANCE_BINDING" candidate_image)"
APPROVED_BY="$(manifest_value "$ACCEPTANCE_BINDING" approved_by)"
STACK_DIR="$(manifest_value "$ACCEPTANCE_BINDING" stack_dir)"
AUDIT_DIR="$(manifest_value "$ACCEPTANCE_BINDING" audit_dir)"
CLONE_STORAGE="$(manifest_value "$ACCEPTANCE_BINDING" clone_storage)"
PRODUCTION_STORAGE="$(manifest_value "$ACCEPTANCE_BINDING" production_storage)"
BACKUP_DIR="$(manifest_value "$ACCEPTANCE_BINDING" backup_dir)"
CUTOFF="$(manifest_value "$ACCEPTANCE_BINDING" history_cutoff)"
EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS="$(
  manifest_value "$ACCEPTANCE_BINDING" expected_instagram_unrecoverable_threads
)"
EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS="$(
  manifest_value "$ACCEPTANCE_BINDING" expected_instagram_unavailable_message_threads
)"
PROFILE_GRAPH_DELAY_MS="$(manifest_value "$ACCEPTANCE_BINDING" profile_graph_delay_ms)"
PROFILE_MAX_CONVERSATION_PAGES="$(
  manifest_value "$ACCEPTANCE_BINDING" profile_max_conversation_pages
)"
PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS="$(
  manifest_value "$ACCEPTANCE_BINDING" profile_max_rate_limit_wait_seconds
)"
PROFILE_MAX_DOWNLOAD_BYTES="$(
  manifest_value "$ACCEPTANCE_BINDING" profile_max_download_bytes
)"
HISTORY_MAX_DOWNLOAD_BYTES="$(
  manifest_value "$ACCEPTANCE_BINDING" history_max_download_bytes
)"
STORAGE_HELPER="$(manifest_value "$ACCEPTANCE_BINDING" storage_helper)"
STORAGE_HELPER_SHA256="$(
  manifest_value "$ACCEPTANCE_BINDING" storage_helper_sha256
)"
readonly ACCEPTANCE_ID INBOX_ID PRODUCTION_DATABASE CLONE_DATABASE APP_COMMIT
readonly APP_DIGEST APPROVED_BY STACK_DIR AUDIT_DIR CLONE_STORAGE
readonly PRODUCTION_STORAGE BACKUP_DIR CUTOFF
readonly EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS
readonly EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS PROFILE_GRAPH_DELAY_MS
readonly PROFILE_MAX_CONVERSATION_PAGES PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS
readonly PROFILE_MAX_DOWNLOAD_BYTES HISTORY_MAX_DOWNLOAD_BYTES
readonly STORAGE_HELPER STORAGE_HELPER_SHA256

HISTORY_DIR="$AUDIT_DIR/history-approval"
PROFILE_DIR="$AUDIT_DIR/profile-approval"
TARGET_DIR="$AUDIT_DIR/profile-targets"
CLONE_ROOT="$(dirname "$CLONE_STORAGE")"
RESUME_AFTER_PROBE=false

test "$(id -u)" -eq 0
require_safe_token acceptance_id "$ACCEPTANCE_ID"
[[ "$RESUME_AFTER_PROBE" =~ ^(true|false)$ ]]
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]]
[[ "$CLONE_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]]
test "$CLONE_DATABASE" != "$PRODUCTION_DATABASE"
[[ "$APP_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_DIGEST" =~ ^ghcr\.io/shumkov/chatwoot@sha256:[0-9a-f]{64}$ ]]
test -n "$APPROVED_BY"
[[ "$APPROVED_BY" != *$'\t'* && "$APPROVED_BY" != *$'\n'* && "$APPROVED_BY" != *$'\r'* ]]
test "$(printf '%s' "$APPROVED_BY" | wc -c)" -le 255
[[ "$EXPECTED_INSTAGRAM_UNRECOVERABLE_THREADS" =~ ^[0-9]+$ ]]
[[ "$EXPECTED_INSTAGRAM_UNAVAILABLE_MESSAGE_THREADS" =~ ^[0-9]+$ ]]
test "$ACCEPTANCE_ID" = "$(basename "$AUDIT_DIR")"
test "$(basename "$CLONE_ROOT")" = "$ACCEPTANCE_ID"
test "$(basename "$CLONE_STORAGE")" = storage
require_root_artifact "$STORAGE_HELPER"
test "$(sha256_file "$STORAGE_HELPER")" = "$STORAGE_HELPER_SHA256"
require_trusted_directory "$STACK_DIR"
require_root_readonly_file "$STACK_DIR/docker-compose.yml"
require_trusted_directory "$BACKUP_DIR"
for backup_artifact in \
  fbig-coordinated-backup-v1.tsv fbig-coordinated-backup-v1.tsv.sha256 \
  database.dump storage.tar storage.manifest; do
  require_root_artifact "$BACKUP_DIR/$backup_artifact"
done
require_trusted_directory "$PRODUCTION_STORAGE"
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
  require_new_root_directory_path "$AUDIT_DIR"
  require_new_root_directory_path "$CLONE_ROOT"
  require_new_root_subdirectory_path "$CLONE_STORAGE" "$CLONE_ROOT"
else
  require_root_directory "$AUDIT_DIR"
  require_root_directory "$HISTORY_DIR"
  require_root_directory "$PROFILE_DIR"
  require_root_directory "$TARGET_DIR"
  require_root_directory "$CLONE_ROOT"
  require_root_directory "$CLONE_STORAGE"
fi

if [[ "$RESUME_AFTER_PROBE" == false ]]; then
  mkdir -m 0700 -- "$AUDIT_DIR"
  require_root_directory "$AUDIT_DIR"
  mkdir -m 0700 "$HISTORY_DIR" "$PROFILE_DIR" "$TARGET_DIR"
  mkdir -m 0700 -- "$CLONE_ROOT"
  require_root_directory "$CLONE_ROOT"
  mkdir -m 0700 -- "$CLONE_STORAGE"
  require_root_directory "$CLONE_STORAGE"
fi

verify_checksum \
  "$BACKUP_DIR/fbig-coordinated-backup-v1.tsv" \
  "$BACKUP_DIR/fbig-coordinated-backup-v1.tsv.sha256"

cd "$STACK_DIR"
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
  docker compose exec -T postgres \
    createdb -U chatwoot --template=template0 "$CLONE_DATABASE"
  docker compose exec -T postgres \
    pg_restore -U chatwoot -d "$CLONE_DATABASE" --no-owner --no-privileges \
    <"$BACKUP_DIR/database.dump"
  python3 "$STORAGE_HELPER" verify-archive \
    "$BACKUP_DIR/storage.tar" "$BACKUP_DIR/storage.manifest" "$CLONE_STORAGE"
fi
export APP_DIGEST CLONE_DATABASE CLONE_STORAGE
CLONE_OVERRIDE="$CLONE_ROOT/docker-compose.clone.yml"
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
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
else
  test -f "$CLONE_OVERRIDE"
  test ! -L "$CLONE_OVERRIDE"
fi

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
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
  python3 "$STORAGE_HELPER" manifest \
    "$CLONE_STORAGE" "$RESTORED_STORAGE_MANIFEST"
  chmod 0400 "$RESTORED_STORAGE_MANIFEST"
fi
cmp -s "$BACKUP_DIR/storage.manifest" "$RESTORED_STORAGE_MANIFEST"
test "$(stat -c '%u:%a:%h' "$RESTORED_STORAGE_MANIFEST")" = "0:400:1"
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
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
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
fi
test "$(stat -c '%u:%a:%h' "$TARGET_DIR/fbig-profile-targets-v1.tsv")" = "0:400:1"
SCOPED_SNAPSHOT_SCRIPT="$AUDIT_DIR/fbig-scoped-baseline.rb"
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
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
fi
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
if [[ "$RESUME_AFTER_PROBE" == false ]]; then
  test ! -e "$CLONE_BASELINE"
  clone_scoped_snapshot capture >"$CLONE_BASELINE"
  chmod 0400 "$CLONE_BASELINE"
fi
test "$(
  grep -Ec '^FBIG_COUNTS\|archives\|22\|messages\|48\|attachments\|6\|live_conversations\|[0-9]+\|nonimporter_messages\|[0-9]+$' \
    "$CLONE_BASELINE"
)" -eq 1
load_scoped_baseline_ids "$CLONE_BASELINE"
test "$(stat -c '%u:%a:%h' "$CLONE_BASELINE")" = "0:400:1"
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

if [[ "$RESUME_AFTER_PROBE" == false ]]; then
  verify_clone_history_state prehistory
else
  test -f "$AUDIT_DIR/clone-scoped-prehistory.txt"
fi
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

if [[ "$RESUME_AFTER_PROBE" == false ]]; then
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
else
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$HISTORY_PROBE_LOG")" -eq 1
  test "$(grep -c '^\[UMI-FBIG\] stage=history_import_summary ' "$HISTORY_PROBE_SUMMARY")" -eq 1
fi
chmod 0400 "$HISTORY_PROBE_LOG" "$HISTORY_PROBE_SUMMARY"

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
chmod 0400 "$HISTORY_PROBE_LOG" "$HISTORY_PROBE_SUMMARY"
test "$(stat -c '%u:%a:%h' "$HISTORY_PROBE_LOG")" = "0:400:1"
test "$(stat -c '%u:%a:%h' "$HISTORY_PROBE_SUMMARY")" = "0:400:1"
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
  python3 "$STORAGE_HELPER" manifest "$CLONE_STORAGE" "$output"
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
  local platform_structural
  local platform_classified
  local platform_failed
  local platform_listed
  local platform_cursor_exhausted
  local approved_count
  local approved_fingerprint
  local approved_unavailable_count
  local approved_unavailable_fingerprint
  local observed_count
  local observed_fingerprint
  local observed_unavailable_count
  local observed_unavailable_fingerprint
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
    approved_unavailable_count="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" \
        "${platform}_unavailable_message_thread_count"
    )"
    approved_unavailable_fingerprint="$(
      manifest_value "$HISTORY_DIR/fbig-approval-v2.tsv" \
        "${platform}_unavailable_message_thread_fingerprint"
    )"
    observed_unavailable_count="$(
      stage_value "$summary" history_import_summary \
        "${platform}_unavailable_message_thread_count"
    )"
    observed_unavailable_fingerprint="$(
      stage_value "$summary" history_import_summary \
        "${platform}_unavailable_message_thread_fingerprint"
    )"
    [[ "$approved_count" =~ ^(0|[1-9][0-9]*)$ ]]
    [[ "$approved_fingerprint" =~ ^[0-9a-f]{64}$ ]]
    [[ "$approved_unavailable_count" =~ ^(0|[1-9][0-9]*)$ ]]
    [[ "$approved_unavailable_fingerprint" =~ ^[0-9a-f]{64}$ ]]
    test "$observed_count" = "$approved_count"
    test "$observed_fingerprint" = "$approved_fingerprint"
    test "$observed_unavailable_count" = "$approved_unavailable_count"
    test "$observed_unavailable_fingerprint" = "$approved_unavailable_fingerprint"
    test "$(stage_value "$summary" history_import_summary \
      "${platform}_unavailable_message_threads")" = "$approved_unavailable_count"

    expected_unavailable="$((expected_unavailable + approved_unavailable_count))"
    platform_structural=0
    if [[ "$platform" = instagram ]]; then
      platform_structural="$expected_ambiguous"
    fi
    test "$(stage_value "$summary" history_import_summary \
      "${platform}_structural_unrecoverable_threads")" = "$platform_structural"
    platform_classified="$(stage_value "$summary" history_import_summary \
      "${platform}_classified_omitted_threads")"
    test "$platform_classified" -eq \
      "$((platform_structural + approved_unavailable_count))"
    platform_failed="$(stage_value "$summary" history_import_summary \
      "${platform}_failed_threads")"
    test "$platform_failed" = 0
    platform_listed="$(stage_value "$summary" history_import_summary \
      "${platform}_listed_threads")"
    platform_cursor_exhausted="$(stage_value "$summary" history_import_summary \
      "${platform}_message_cursor_exhausted_threads")"
    test "$platform_listed" -eq \
      "$((platform_cursor_exhausted + platform_classified + platform_failed))"
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
[[ "$HISTORY_MAX_DOWNLOAD_BYTES" =~ ^[1-9][0-9]*$ ]]

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
  messenger-apply messenger "$HISTORY_MAX_DOWNLOAD_BYTES" false
history_apply_with_verification \
  messenger-recovery messenger "$HISTORY_MAX_DOWNLOAD_BYTES" true
history_apply_with_verification \
  instagram-apply instagram "$HISTORY_MAX_DOWNLOAD_BYTES" false
history_apply_with_verification \
  instagram-recovery instagram "$HISTORY_MAX_DOWNLOAD_BYTES" true
STATE_DIR="$AUDIT_DIR/profile-source-state"
mkdir -m 0700 "$STATE_DIR"
clone_compose run --rm --no-deps -T \
  --volume "$STATE_DIR:/run/fbig/state" \
  -e UMI_FBIG_HISTORY_EXPECTED_DATABASE="$CLONE_DATABASE" \
  -e UMI_FBIG_PROFILE_STATE_OUTPUT_DIR=/run/fbig/state \
  rails bundle exec rake "umi:fbig:history_profile_state[$INBOX_ID]"
chmod 0400 "$STATE_DIR"/fbig-profile-state-v1.tsv*
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
  verify_seed_target_conservation "$log" "$summary"

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
clone_compose stop --timeout 30 clone-redis
clone_compose rm --force --stop clone-redis
test -z "$(clone_compose ps --all -q clone-redis)"
test -z "$(docker ps --all --quiet --filter id="$CLONE_REDIS_CONTAINER")"
CLONE_REDIS_ACTIVE=false
trap - EXIT
