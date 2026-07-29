
readonly BINDING_MANIFEST="${1:?binding manifest is required}"
readonly LABEL="${2:?checkpoint label is required}"
readonly BINDING_CHECKSUM="${BINDING_MANIFEST}.sha256"
PROGRAM_PATH="$(readlink -f "$0")"
readonly PROGRAM_PATH
readonly PROGRAM_CHECKSUM="${PROGRAM_PATH}.sha256"

readonly BINDING_FIELDS=(
  schema_version authorization_mode authorization_manifest
  authorization_checksum authorization_sha256
  candidate_commit candidate_image service_source_sha256
  stack_dir compose_file compose_file_sha256 compose_project rails_service
  sidekiq_service production_database audit_root inbox_id page_id
  instagram_business_id history_cutoff predecessor_manifest
  predecessor_checksum production_lock
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

require_root_artifact "$PROGRAM_PATH"
verify_checksum "$PROGRAM_PATH" "$PROGRAM_CHECKSUM"
verify_checksum "$BINDING_MANIFEST" "$BINDING_CHECKSUM"
require_ordered_manifest "$BINDING_MANIFEST" "${BINDING_FIELDS[@]}"
[[ "$(manifest_value "$BINDING_MANIFEST" schema_version)" = 1 ]] ||
  die "unsupported binding schema"
require_safe_token label "$LABEL"

AUTHORIZATION_MODE="$(manifest_value "$BINDING_MANIFEST" authorization_mode)"
AUTHORIZATION_MANIFEST="$(manifest_value "$BINDING_MANIFEST" authorization_manifest)"
AUTHORIZATION_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" authorization_checksum)"
AUTHORIZATION_SHA256="$(manifest_value "$BINDING_MANIFEST" authorization_sha256)"
CANDIDATE_COMMIT="$(manifest_value "$BINDING_MANIFEST" candidate_commit)"
CANDIDATE_IMAGE="$(manifest_value "$BINDING_MANIFEST" candidate_image)"
SERVICE_SOURCE_SHA256="$(manifest_value "$BINDING_MANIFEST" service_source_sha256)"
STACK_DIR="$(manifest_value "$BINDING_MANIFEST" stack_dir)"
COMPOSE_FILE="$(manifest_value "$BINDING_MANIFEST" compose_file)"
COMPOSE_FILE_SHA256="$(manifest_value "$BINDING_MANIFEST" compose_file_sha256)"
COMPOSE_PROJECT="$(manifest_value "$BINDING_MANIFEST" compose_project)"
RAILS_SERVICE="$(manifest_value "$BINDING_MANIFEST" rails_service)"
SIDEKIQ_SERVICE="$(manifest_value "$BINDING_MANIFEST" sidekiq_service)"
PRODUCTION_DATABASE="$(manifest_value "$BINDING_MANIFEST" production_database)"
AUDIT_ROOT="$(manifest_value "$BINDING_MANIFEST" audit_root)"
INBOX_ID="$(manifest_value "$BINDING_MANIFEST" inbox_id)"
PAGE_ID="$(manifest_value "$BINDING_MANIFEST" page_id)"
INSTAGRAM_BUSINESS_ID="$(manifest_value "$BINDING_MANIFEST" instagram_business_id)"
HISTORY_CUTOFF="$(manifest_value "$BINDING_MANIFEST" history_cutoff)"
PREDECESSOR_MANIFEST="$(manifest_value "$BINDING_MANIFEST" predecessor_manifest)"
PREDECESSOR_CHECKSUM="$(manifest_value "$BINDING_MANIFEST" predecessor_checksum)"
PRODUCTION_LOCK="$(manifest_value "$BINDING_MANIFEST" production_lock)"
readonly AUTHORIZATION_MODE AUTHORIZATION_MANIFEST AUTHORIZATION_CHECKSUM
readonly AUTHORIZATION_SHA256 CANDIDATE_COMMIT CANDIDATE_IMAGE SERVICE_SOURCE_SHA256
readonly STACK_DIR COMPOSE_FILE COMPOSE_FILE_SHA256 COMPOSE_PROJECT
readonly RAILS_SERVICE SIDEKIQ_SERVICE PRODUCTION_DATABASE
readonly AUDIT_ROOT INBOX_ID PAGE_ID INSTAGRAM_BUSINESS_ID HISTORY_CUTOFF
readonly PREDECESSOR_MANIFEST PREDECESSOR_CHECKSUM PRODUCTION_LOCK

[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "candidate commit must be a full SHA"
[[ "$CANDIDATE_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] ||
  die "candidate image must be digest-pinned"
[[ "$SERVICE_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid service source SHA"
[[ "$INBOX_ID" =~ ^[1-9][0-9]*$ ]] || die "invalid inbox id"
[[ "$PAGE_ID" =~ ^[1-9][0-9]*$ ]] || die "invalid page id"
[[ "$INSTAGRAM_BUSINESS_ID" =~ ^[1-9][0-9]*$ ]] ||
  die "invalid Instagram business id"
[[ "$HISTORY_CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  die "history cutoff must be canonical UTC"
[[ "$AUTHORIZATION_MODE" = clone_authorized ||
  "$AUTHORIZATION_MODE" = production_first ]] || die "invalid authorization mode"
if [[ "$AUTHORIZATION_MODE" = production_first ]]; then
  verify_checksum "$AUTHORIZATION_MANIFEST" "$AUTHORIZATION_CHECKSUM"
  require_ordered_manifest \
    "$AUTHORIZATION_MANIFEST" "${PRODUCTION_FIRST_AUTHORIZATION_FIELDS[@]}"
  [[ "$(sha256_file "$AUTHORIZATION_MANIFEST")" = "$AUTHORIZATION_SHA256" &&
    "$(manifest_value "$AUTHORIZATION_MANIFEST" repository_commit)" = "$CANDIDATE_COMMIT" &&
    "$(manifest_value "$AUTHORIZATION_MANIFEST" image_digest)" = "$CANDIDATE_IMAGE" &&
    "$(manifest_value "$AUTHORIZATION_MANIFEST" delivery_checkpoint_program_sha256)" = \
      "$(sha256_file "$PROGRAM_PATH")" ]] ||
    die "production-first authorization does not bind this delivery checkpoint"
else
  [[ "$AUTHORIZATION_MANIFEST" = none && "$AUTHORIZATION_CHECKSUM" = none &&
    "$AUTHORIZATION_SHA256" = none ]] || die "clone checkpoint contains production-first authorization"
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

readonly RESULT_DIRECTORY="$AUDIT_ROOT/$LABEL"
readonly RESULT_MANIFEST="$RESULT_DIRECTORY/fbig-delivery-checkpoint-v1.tsv"

validate_checkpoint() {
  local manifest="$1"
  local checksum="${manifest}.sha256"

  verify_checksum "$manifest" "$checksum"
  require_ordered_manifest "$manifest" "${CHECKPOINT_FIELDS[@]}"
  [[ "$(manifest_value "$manifest" schema_version)" = 1 ]] ||
    die "unsupported checkpoint schema"
  [[ "$(manifest_value "$manifest" label)" = "$LABEL" ]] ||
    die "sealed checkpoint label mismatch"
  [[ "$(manifest_value "$manifest" program_sha256)" = "$(sha256_file "$PROGRAM_PATH")" ]] ||
    die "sealed checkpoint program mismatch"
  [[ "$(manifest_value "$manifest" binding_sha256)" = "$(sha256_file "$BINDING_MANIFEST")" ]] ||
    die "sealed checkpoint binding mismatch"
  [[ "$(manifest_value "$manifest" candidate_commit)" = "$CANDIDATE_COMMIT" ]] ||
    die "sealed checkpoint candidate mismatch"
  [[ "$(manifest_value "$manifest" candidate_image)" = "$CANDIDATE_IMAGE" ]] ||
    die "sealed checkpoint image mismatch"
  [[ "$(manifest_value "$manifest" service_source_sha256)" = "$SERVICE_SOURCE_SHA256" ]] ||
    die "sealed checkpoint implementation mismatch"
  [[ "$(manifest_value "$manifest" production_database)" = "$PRODUCTION_DATABASE" ]] ||
    die "sealed checkpoint database mismatch"
  [[ "$(manifest_value "$manifest" inbox_id)" = "$INBOX_ID" ]] ||
    die "sealed checkpoint inbox mismatch"
  [[ "$(manifest_value "$manifest" page_identity_sha256)" = \
    "$(printf '%s' "$PAGE_ID" | sha256sum | awk '{ print $1 }')" ]] ||
    die "sealed checkpoint Page identity mismatch"
  [[ "$(manifest_value "$manifest" instagram_identity_sha256)" = \
    "$(printf '%s' "$INSTAGRAM_BUSINESS_ID" | sha256sum | awk '{ print $1 }')" ]] ||
    die "sealed checkpoint Instagram identity mismatch"
  [[ "$(manifest_value "$manifest" history_cutoff)" = "$HISTORY_CUTOFF" ]] ||
    die "sealed checkpoint cutoff mismatch"
  [[ "$(manifest_value "$manifest" messenger_missing)" = 0 ]] ||
    die "sealed Messenger checkpoint is not zero-missing"
  [[ "$(manifest_value "$manifest" instagram_missing)" = 0 ]] ||
    die "sealed Instagram checkpoint is not zero-missing"
  local entry
  local field
  local filename
  local artifact
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
    artifact="$RESULT_DIRECTORY/$filename"
    require_root_artifact "$artifact"
    [[ "$(sha256_file "$artifact")" = "$(manifest_value "$manifest" "${field}_sha256")" ]] ||
      die "sealed checkpoint evidence mismatch: $field"
  done
}

if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_checkpoint "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=delivery_checkpoint_validated label=%s manifest=%s\n' \
    "$LABEL" "$RESULT_MANIFEST"
  exit 0
fi

acquire_descriptor_verified_lock "$PRODUCTION_LOCK"
if [[ -e "$RESULT_DIRECTORY" ]]; then
  require_root_directory "$RESULT_DIRECTORY"
  validate_checkpoint "$RESULT_MANIFEST"
  printf '[UMI-FBIG] stage=delivery_checkpoint_validated label=%s manifest=%s\n' \
    "$LABEL" "$RESULT_MANIFEST"
  exit 0
fi

readonly STAGING_DIRECTORY="$AUDIT_ROOT/.${LABEL}.in-progress"
[[ ! -e "$STAGING_DIRECTORY" ]] || die "staging directory already exists"
mkdir "$STAGING_DIRECTORY"
chmod 0700 "$STAGING_DIRECTORY"
readonly OVERRIDE_FILE="$STAGING_DIRECTORY/candidate-compose.yml"
readonly RAW_LOG="$STAGING_DIRECTORY/reconciliation.log"
readonly WINDOW_EVIDENCE="$STAGING_DIRECTORY/window.tsv"
readonly MESSENGER_SUBSCRIPTION="$STAGING_DIRECTORY/messenger-subscription.tsv"
readonly INSTAGRAM_SUBSCRIPTION="$STAGING_DIRECTORY/instagram-subscription.tsv"
readonly MESSENGER_RECON="$STAGING_DIRECTORY/messenger-recon-summary.tsv"
readonly INSTAGRAM_RECON="$STAGING_DIRECTORY/instagram-recon-summary.tsv"

running_container_identity() {
  local service="$1"
  local container
  local image
  local commit

  container="$(
    cd "$STACK_DIR"
    docker compose \
      --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" ps -q "$service"
  )"
  [[ -n "$container" && "$(wc -w <<<"$container")" -eq 1 ]] ||
    die "expected one running $service container"
  image="$(docker inspect --format '{{.Image}}' "$container")"
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid running image id"
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "$image" | grep -Fxq -- "$CANDIDATE_IMAGE" ||
    die "running $service image is not the candidate digest"
  commit="$(
    cd "$STACK_DIR"
    docker compose \
      --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
      exec -T "$service" sh -c 'tr -d "\r\n" </app/.git_sha'
  )"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid running commit"
  printf '%s\t%s\n' "$image" "$commit"
}

IFS=$'\t' read -r running_rails_image running_rails_commit < <(
  running_container_identity "$RAILS_SERVICE"
)
IFS=$'\t' read -r running_sidekiq_image running_sidekiq_commit < <(
  running_container_identity "$SIDEKIQ_SERVICE"
)
running_rails_service_sha="$(
  cd "$STACK_DIR"
  docker compose \
    --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
    exec -T "$RAILS_SERVICE" sha256sum \
    /app/umi/app/services/fbig/conversation_recon_service.rb |
    awk '{ print $1 }'
)"
[[ "$running_rails_service_sha" =~ ^[0-9a-f]{64}$ ]] ||
  die "invalid running reconciliation implementation SHA"
[[ "$running_rails_commit" = "$CANDIDATE_COMMIT" ]] ||
  die "running Rails commit is not the candidate"
[[ "$running_sidekiq_commit" = "$CANDIDATE_COMMIT" ]] ||
  die "running Sidekiq commit is not the candidate"
[[ "$running_rails_service_sha" = "$SERVICE_SOURCE_SHA256" ]] ||
  die "running reconciliation implementation is not the candidate"

printf 'services:\n  %s:\n    image: %s\n' "$RAILS_SERVICE" "$CANDIDATE_IMAGE" >"$OVERRIDE_FILE"
chmod 0400 "$OVERRIDE_FILE"

compose=(
  docker compose
  --project-name "$COMPOSE_PROJECT"
  --file "$COMPOSE_FILE"
  --file "$OVERRIDE_FILE"
)
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(
  cd "$STACK_DIR"
  "${compose[@]}" run --rm --no-deps -T \
    -e UMI_FBIG_CHECKPOINT_COMMIT="$CANDIDATE_COMMIT" \
    -e UMI_FBIG_CHECKPOINT_SERVICE_SHA="$SERVICE_SOURCE_SHA256" \
    -e UMI_FBIG_CHECKPOINT_DATABASE="$PRODUCTION_DATABASE" \
    -e UMI_FBIG_CHECKPOINT_INBOX_ID="$INBOX_ID" \
    -e UMI_FBIG_CHECKPOINT_PAGE_ID="$PAGE_ID" \
    -e UMI_FBIG_CHECKPOINT_INSTAGRAM_ID="$INSTAGRAM_BUSINESS_ID" \
    -e UMI_FBIG_CHECKPOINT_CUTOFF="$HISTORY_CUTOFF" \
    -e UMI_FBIG_RECON_HEAL=false \
    "$RAILS_SERVICE" bundle exec rails runner - <<'RUBY'
require "digest"
require "time"

class UmiFbigCheckpointLogger
  attr_reader :summaries

  def initialize
    @summaries = []
  end

  def info(line)
    capture(line)
  end

  def warn(line)
    capture(line)
  end

  private

  def capture(line)
    text = line.to_s
    @summaries << text if text.start_with?("[UMI-FBIG] stage=reconcile_summary ")
  end
end

expected_commit = ENV.fetch("UMI_FBIG_CHECKPOINT_COMMIT")
actual_commit = File.binread("/app/.git_sha").strip
abort("candidate commit mismatch") unless actual_commit == expected_commit
service_path = "/app/umi/app/services/fbig/conversation_recon_service.rb"
actual_service_sha = Digest::SHA256.file(service_path).hexdigest
abort("reconciliation implementation mismatch") unless
  actual_service_sha == ENV.fetch("UMI_FBIG_CHECKPOINT_SERVICE_SHA")
abort("reconciliation healing must remain disabled") unless
  ENV.fetch("UMI_FBIG_RECON_HEAL") == "false"

cutoff = Time.iso8601(ENV.fetch("UMI_FBIG_CHECKPOINT_CUTOFF"))
now = Time.current
rolling_start = now - Umi::Fbig::ConversationReconService::WINDOW_HOURS.hours
effective_start = [rolling_start, cutoff].max
grace_end = now - Umi::Fbig::ConversationReconService::RECENT_GRACE_MINUTES.minutes
abort("empty checkpoint window") unless effective_start < grace_end

connection = ActiveRecord::Base.connection
connection.transaction(requires_new: true) do
  connection.execute("SET TRANSACTION READ ONLY")
  abort("production database mismatch") unless
    connection.select_value("SELECT current_database()") ==
      ENV.fetch("UMI_FBIG_CHECKPOINT_DATABASE")
  inbox = Inbox.find(Integer(ENV.fetch("UMI_FBIG_CHECKPOINT_INBOX_ID"), 10))
  channel = inbox.channel
  abort("Facebook-page channel required") unless channel.is_a?(Channel::FacebookPage)
  abort("Facebook Page identity mismatch") unless
    channel.page_id.to_s == ENV.fetch("UMI_FBIG_CHECKPOINT_PAGE_ID")
  abort("Instagram business identity mismatch") unless
    channel.instagram_id.to_s == ENV.fetch("UMI_FBIG_CHECKPOINT_INSTAGRAM_ID")

  app_id = GlobalConfigService.load("FB_APP_ID", "").to_s
  abort("FB_APP_ID missing") if app_id.blank?
  api = Koala::Facebook::API.new(channel.page_access_token)
  subscriptions = {
    messenger: [channel.page_id, %w[messages message_echoes]],
    instagram: [channel.instagram_id, %w[messages]]
  }.map do |platform, (identity, required_fields)|
    rows = api.get_connections(
      identity, "subscribed_apps", fields: "id,subscribed_fields"
    ).to_a
    row = rows.find { |entry| entry.fetch("id").to_s == app_id }
    abort("#{platform} app subscription missing") unless row
    fields = Array(row["subscribed_fields"]).map(&:to_s).sort
    abort("#{platform} subscribed fields missing") unless (required_fields - fields).empty?
    [
      "[UMI-FBIG]", "stage=subscription_evidence", "platform=#{platform}",
      "identity_sha256=#{Digest::SHA256.hexdigest(identity.to_s)}",
      "app_id_sha256=#{Digest::SHA256.hexdigest(app_id)}",
      "subscribed_fields_sha256=#{Digest::SHA256.hexdigest(fields.join(','))}"
    ].join(" ")
  end

  logger = UmiFbigCheckpointLogger.new
  Rails.logger = logger
  Umi::Fbig::ConversationReconService.new(
    channel,
    window_start: effective_start,
    grace_end: grace_end
  ).perform
  abort("checkpoint did not emit two platform summaries") unless logger.summaries.size == 2

  puts [
    "[UMI-FBIG]", "stage=checkpoint_window",
    "service_rolling_window_start=#{rolling_start.utc.iso8601}",
    "effective_window_start=#{effective_start.utc.iso8601}",
    "grace_end=#{grace_end.utc.iso8601}"
  ].join(" ")
  subscriptions.each { |line| puts line }
  logger.summaries.each { |line| puts line }
end
RUBY
) >"$RAW_LOG"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

grep '^\[UMI-FBIG\] stage=checkpoint_window ' "$RAW_LOG" >"$WINDOW_EVIDENCE"
grep '^\[UMI-FBIG\] stage=subscription_evidence platform=messenger ' \
  "$RAW_LOG" >"$MESSENGER_SUBSCRIPTION"
grep '^\[UMI-FBIG\] stage=subscription_evidence platform=instagram ' \
  "$RAW_LOG" >"$INSTAGRAM_SUBSCRIPTION"
grep '^\[UMI-FBIG\] stage=reconcile_summary platform=messenger ' \
  "$RAW_LOG" >"$MESSENGER_RECON"
grep '^\[UMI-FBIG\] stage=reconcile_summary platform=instagram ' \
  "$RAW_LOG" >"$INSTAGRAM_RECON"
for evidence in \
  "$WINDOW_EVIDENCE" "$MESSENGER_SUBSCRIPTION" "$INSTAGRAM_SUBSCRIPTION" \
  "$MESSENGER_RECON" "$INSTAGRAM_RECON"; do
  [[ "$(wc -l <"$evidence")" -eq 1 ]] || die "ambiguous checkpoint evidence"
done

for recon in "$MESSENGER_RECON" "$INSTAGRAM_RECON"; do
  [[ "$(stage_value "$recon" reconcile_summary missing)" = 0 ]] ||
    die "checkpoint found missing deliveries"
  [[ "$(stage_value "$recon" reconcile_summary threads_failed)" = 0 ]] ||
    die "checkpoint has failed threads"
  [[ "$(stage_value "$recon" reconcile_summary caps_hit)" = 0 ]] ||
    die "checkpoint hit an API page cap"
  ! grep -q ' error=' "$recon" || die "checkpoint reconciliation errored"
done

rolling_start="$(stage_value "$WINDOW_EVIDENCE" checkpoint_window service_rolling_window_start)"
effective_start="$(stage_value "$WINDOW_EVIDENCE" checkpoint_window effective_window_start)"
grace_end="$(stage_value "$WINDOW_EVIDENCE" checkpoint_window grace_end)"
predecessor_sha=none
if [[ "$PREDECESSOR_MANIFEST" = none ]]; then
  [[ "$PREDECESSOR_CHECKSUM" = none ]] || die "orphan predecessor checksum"
  [[ "$effective_start" = "$HISTORY_CUTOFF" ]] ||
    die "first checkpoint no longer reaches the history cutoff"
else
  [[ "$PREDECESSOR_CHECKSUM" = "${PREDECESSOR_MANIFEST}.sha256" ]] ||
    die "predecessor checksum path mismatch"
  verify_checksum "$PREDECESSOR_MANIFEST" "$PREDECESSOR_CHECKSUM"
  require_ordered_manifest "$PREDECESSOR_MANIFEST" "${CHECKPOINT_FIELDS[@]}"
  [[ "$(manifest_value "$PREDECESSOR_MANIFEST" candidate_commit)" = "$CANDIDATE_COMMIT" ]] ||
    die "checkpoint chain candidate changed"
  [[ "$(manifest_value "$PREDECESSOR_MANIFEST" candidate_image)" = "$CANDIDATE_IMAGE" ]] ||
    die "checkpoint chain image changed"
  [[ "$(manifest_value "$PREDECESSOR_MANIFEST" service_source_sha256)" = "$SERVICE_SOURCE_SHA256" ]] ||
    die "checkpoint chain implementation changed"
  [[ "$(manifest_value "$PREDECESSOR_MANIFEST" history_cutoff)" = "$HISTORY_CUTOFF" ]] ||
    die "checkpoint chain cutoff changed"
  predecessor_grace_end="$(manifest_value "$PREDECESSOR_MANIFEST" grace_end)"
  [[ "$(date -u -d "$effective_start" +%s)" -le "$(date -u -d "$predecessor_grace_end" +%s)" ]] ||
    die "checkpoint chain has a coverage gap"
  predecessor_sha="$(sha256_file "$PREDECESSOR_MANIFEST")"
fi

for artifact in \
  "$OVERRIDE_FILE" "$RAW_LOG" "$WINDOW_EVIDENCE" "$MESSENGER_SUBSCRIPTION" \
  "$INSTAGRAM_SUBSCRIPTION" "$MESSENGER_RECON" "$INSTAGRAM_RECON"; do
  chmod 0400 "$artifact"
  fsync_path "$artifact"
done

{
  printf 'schema_version\t1\n'
  printf 'label\t%s\n' "$LABEL"
  printf 'program_sha256\t%s\n' "$(sha256_file "$PROGRAM_PATH")"
  printf 'binding_sha256\t%s\n' "$(sha256_file "$BINDING_MANIFEST")"
  printf 'candidate_commit\t%s\n' "$CANDIDATE_COMMIT"
  printf 'candidate_image\t%s\n' "$CANDIDATE_IMAGE"
  printf 'service_source_sha256\t%s\n' "$SERVICE_SOURCE_SHA256"
  printf 'running_rails_image_id\t%s\n' "$running_rails_image"
  printf 'running_rails_commit\t%s\n' "$running_rails_commit"
  printf 'running_rails_service_source_sha256\t%s\n' "$running_rails_service_sha"
  printf 'running_sidekiq_image_id\t%s\n' "$running_sidekiq_image"
  printf 'running_sidekiq_commit\t%s\n' "$running_sidekiq_commit"
  printf 'production_database\t%s\n' "$PRODUCTION_DATABASE"
  printf 'inbox_id\t%s\n' "$INBOX_ID"
  printf 'page_identity_sha256\t%s\n' \
    "$(stage_value "$MESSENGER_SUBSCRIPTION" subscription_evidence identity_sha256)"
  printf 'instagram_identity_sha256\t%s\n' \
    "$(stage_value "$INSTAGRAM_SUBSCRIPTION" subscription_evidence identity_sha256)"
  printf 'history_cutoff\t%s\n' "$HISTORY_CUTOFF"
  printf 'service_rolling_window_start\t%s\n' "$rolling_start"
  printf 'effective_window_start\t%s\n' "$effective_start"
  printf 'grace_end\t%s\n' "$grace_end"
  printf 'started_at\t%s\n' "$started_at"
  printf 'finished_at\t%s\n' "$finished_at"
  printf 'compose_override_sha256\t%s\n' "$(sha256_file "$OVERRIDE_FILE")"
  printf 'reconciliation_log_sha256\t%s\n' "$(sha256_file "$RAW_LOG")"
  printf 'window_evidence_sha256\t%s\n' "$(sha256_file "$WINDOW_EVIDENCE")"
  printf 'messenger_subscription_evidence_sha256\t%s\n' \
    "$(sha256_file "$MESSENGER_SUBSCRIPTION")"
  printf 'instagram_subscription_evidence_sha256\t%s\n' \
    "$(sha256_file "$INSTAGRAM_SUBSCRIPTION")"
  printf 'messenger_recon_summary_sha256\t%s\n' "$(sha256_file "$MESSENGER_RECON")"
  printf 'instagram_recon_summary_sha256\t%s\n' "$(sha256_file "$INSTAGRAM_RECON")"
  printf 'messenger_threads\t%s\n' \
    "$(stage_value "$MESSENGER_RECON" reconcile_summary threads)"
  printf 'messenger_mids\t%s\n' "$(stage_value "$MESSENGER_RECON" reconcile_summary mids)"
  printf 'messenger_missing\t0\n'
  printf 'messenger_threads_failed\t0\n'
  printf 'messenger_caps_hit\t0\n'
  printf 'instagram_threads\t%s\n' \
    "$(stage_value "$INSTAGRAM_RECON" reconcile_summary threads)"
  printf 'instagram_mids\t%s\n' "$(stage_value "$INSTAGRAM_RECON" reconcile_summary mids)"
  printf 'instagram_missing\t0\n'
  printf 'instagram_threads_failed\t0\n'
  printf 'instagram_caps_hit\t0\n'
  printf 'predecessor_manifest_sha256\t%s\n' "$predecessor_sha"
  printf 'sealed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv"
chmod 0400 "$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv"
fsync_path "$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv"
printf '%s  %s\n' \
  "$(sha256_file "$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv")" \
  fbig-delivery-checkpoint-v1.tsv \
  >"$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv.sha256"
chmod 0400 "$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv.sha256"
fsync_path "$STAGING_DIRECTORY/fbig-delivery-checkpoint-v1.tsv.sha256"
fsync_path "$STAGING_DIRECTORY"
publish_directory_no_replace "$STAGING_DIRECTORY" "$RESULT_DIRECTORY"
fsync_path "$AUDIT_ROOT"

validate_checkpoint "$RESULT_MANIFEST"
printf '[UMI-FBIG] stage=delivery_checkpoint_complete label=%s manifest=%s\n' \
  "$LABEL" "$RESULT_MANIFEST"
