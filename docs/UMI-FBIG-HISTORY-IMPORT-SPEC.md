# UMI patch #14: Historical FB/IG conversation import

## Problem

UMI patches 8–13 make the live Facebook Messenger and Instagram Direct
pipelines observable, repair known webhook-side loss, reconcile a recent
window against Meta, and improve participant names. They do not restore the
conversation history that predates the Chatwoot connection or messages that
were missed outside the reconciliation window.

Meta's Conversations API exposes that older history, but replaying it through
Chatwoot's live message builders is unsafe. A normal `Message` commit can
reopen a resolved conversation, update activity timestamps to the import time,
dispatch message and first-reply events, enqueue reply delivery, and fan out to
automations, bots, notifications, webhooks, reporting, and realtime clients.
Resolving the conversation or rewriting its timestamps afterwards is too late:
the side effects have already occurred.

Patch 14 is a manual, one-off importer that reconstructs the history as
resolved archive conversations with original Meta timestamps. It must be
rerunnable, dry-run first, and inert with respect to customer communication
and the live inbox.

This document is the design and review target only. It does not authorize or
include implementation.

## Verified facts and remaining unknowns

### Verified against production on 2026-07-23

- Both `platform=messenger` and `platform=instagram` conversation listings
  reach substantially farther back than the current 48-hour reconciliation
  window.
- Old per-message detail requests return successfully for the sampled history.
- Meta message ids match Chatwoot `messages.source_id` for both platforms.
- Conversation `participants` contain usable names in the sampled threads.
- The 17-day audit found four absent mids, all outbound. This makes outbound
  overlap handling a real requirement, not a theoretical edge case.

These observations establish feasibility for the current UMI account and
token. They are not API guarantees.

### Verified in this repository

- The current heal path deliberately replays the live builders and stamps
  messages at heal time. That is suitable for a small, flag-gated recent
  repair, but not for a historical import.
- `Message` create callbacks can reopen conversations, set activity to now,
  dispatch `MESSAGE_CREATED`, `FIRST_REPLY_CREATED`, and `REPLY_CREATED`,
  enqueue `SendReplyJob`, and run greeting/out-of-office/email-collection
  hooks. The dispatcher then reaches automations, integrations, webhooks,
  notifications, unread counts, reporting, Action Cable, and agent bots.
- The Intercom historical importer establishes the safe in-repo precedent:
  direct inserts for contacts, conversations, and messages, followed only by
  explicit best-effort search indexing.
- A Chatwoot outbound bubble with text and attachments can make several Meta
  sends while retaining only the final returned mid. Facebook sends text and
  then each attachment; Instagram sends attachments and then text. Importing
  every absent outbound mid in that era can therefore create duplicate
  bubbles.
- `messages.source_id` is indexed but not unique. Sequential source-id checks
  make reruns idempotent, but the database cannot make a global
  check-and-insert atomic.
- The live attachment resilience patch preserves an `Attachment` row with an
  external URL when a download fails. That is a poor historical fallback:
  expired Meta CDN URLs render as broken attachments.
- The current Conversations API mapper has only verified
  `image_data.url`, `video_data.url`, and `file_url`.
- A conversation database trigger allocates `display_id`, so callback-free
  conversation insertion does not need to emulate that logic.
- Resolved conversations are excluded from rebuilt unread memberships.
  Setting `agent_last_seen_at` to the latest imported timestamp also keeps the
  ordinary unread presenter at zero.

### External documentation and unverified assumptions

Meta's official Messenger Platform collection documents listing conversations,
listing their messages, reading message details, pagination, and using this API
to synchronize past conversations:

- [Messenger Platform Conversations API collection](https://www.postman.com/meta/messenger-platform-api/folder/22794852-255610cd-47f5-4f4d-b3fa-71aec360be9a)
- [Get message details](https://www.postman.com/meta/messenger-platform-api/request/22794852-c2849780-5883-4b61-a217-87fb631df7b4)
- [Get messages in a conversation](https://www.postman.com/meta/messenger-platform-api/request/22794852-2e906fea-77ff-479d-be31-0ae6063596f1)

The implementation must keep the following limitations explicit:

- "All history" means all history Meta returns. Meta documents that Requests
  folder conversations inactive for more than 30 days may not be returned.
- No ordering guarantee was found for conversation or message pages. The
  importer must exhaust cursors and must not stop because timestamps appear
  old.
- No fixed universal quota was found. Usage is account/app dependent, so the
  importer must surface rate limiting and incomplete scans instead of
  promising a fixed safe throughput.
- The sampled Page-linked Instagram API returned old details, but the official
  material found does not guarantee the same archival depth. A separate
  Instagram Login API documents a recent-message detail limit; that is not the
  API path this channel uses and must not be applied as a fabricated limit.
- The production probe, not the official collection, verifies the
  `participants` shape and old attachment shapes used here.
- It is unverified that every Instagram participant id exactly equals the
  webhook sender/contact-inbox source id. A mismatched or ambiguous thread
  must be skipped rather than guessed.
- Meta detail does not identify whether an outbound entry came from Chatwoot,
  Meta Business Suite, the native app, or an automation.
- Attachment URL lifetime, audio/share/story/reel shapes, reactions, deleted
  content, and equal-second ordering are not guaranteed. Chatwoot orders equal
  message timestamps without a persisted Meta sequence.

## Approach

### 1. Manual task and safety contract

Expose one synchronous task:

`UMI_FBIG_HISTORY_EXPECTED_DATABASE='<EXPECTED_DATABASE_NAME>' bundle exec rake "umi:fbig:history_import[<INBOX_ID>]"`

`UMI_FBIG_HISTORY_EXPECTED_DATABASE` is mandatory on dry and applying runs.
The rake process reads `current_database()` and requires an exact name match
before loading the inbox, acquiring the writer lock, calling Meta, or writing.
The inbox must then exist and use `Channel::FacebookPage`; otherwise the task
exits nonzero before calling Meta. There is no initializer, cron, job chain,
or feature flag. A long-running import remains attached to the operator's
terminal and prints progress continuously.

Configuration is explicit:

- `DRY_RUN` defaults to `true`. Only `DRY_RUN=false` permits writes or binary
  downloads.
- `PLATFORMS` is a comma-separated subset of `messenger,instagram`, defaulting
  to both identities available on the channel. Requesting Instagram when the
  channel has no `instagram_id` is an error, not a silent skip.
- `SINCE` is required and is either `all` or an ISO-8601 UTC timestamp.
- `BEFORE` is an ISO-8601 UTC timestamp. A dry run may omit it and freezes
  `run_started_at - 15 minutes` once at startup. Apply mode requires the exact
  cutoff printed by the reviewed dry run and rejects a value newer than
  15 minutes before apply startup.
- `OUTBOUND_POLICY` is one of `no_native_presence`, `pre_presence`, or `all`.
  A dry run may omit it and report the counts under all three policies. An
  applying run must provide it explicitly because the product decision is
  intentionally unresolved in this spec.
- `ACK_SINGLE_CONVERSATION_REOPEN=true` is required in apply mode when the
  inbox has `lock_to_single_conversation` enabled. Dry run prints the warning
  without requiring acknowledgement.
- `ACK_EXPAND_EXISTING=true` is required when selected archives use the
  earlier contained import window. Apply accepts only the exact target
  configuration, one unique contained predecessor, or a crash-resume mixture
  of those two configurations.
- `UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES` is a required positive
  single-invocation byte budget in apply mode. Historical attachments across
  every platform selected in that invocation spend it first; profile avatars
  may use only the remainder after those selected platforms complete history
  persistence. Separate platform and recovery commands each start a new
  allowance; the importer does not carry a remainder between invocations. Dry
  run downloads neither.

The frozen `BEFORE` cutoff excludes the most recent 15 minutes. Live webhooks
own that interval, and the grace period bounds the race created by the
non-unique `source_id` index. Reusing the dry-run cutoff makes apply execute
the same time-bounded plan; a later verification rerun must also reuse it.

Before scanning, acquire a Redis single-writer lock scoped to the channel,
using a random run id, `SET NX`, and a 15-minute lease. A dedicated lock helper
atomically compare-and-renews the lease every five minutes and before each
write transaction, and atomically compare-and-deletes it in `ensure` on every
exit. The TTL is crash recovery; a non-owner must never extend or release a
new owner's lease. Failure to acquire or renew exits nonzero. Dry runs also
take the lock so their classification is not competing with another import.

Patch 12's optional healer must acquire the same channel lock around each
write and return/log `history_import_running` when the importer owns it. This
is an implementation change in patch 14, not a manual environment promise:
the rake process cannot prove what environment a separate Sidekiq process is
running. It closes the 15-minute-to-48-hour overlap while leaving patch 12's
detection scan free to report.

The normalized `SINCE`, `BEFORE`, and `OUTBOUND_POLICY` form an import
configuration. Apply preflights the union of marker-owned and deterministic
prefix archives before calling Meta. It rejects malformed identity, multiple
predecessors, policy changes, narrower intervals, and non-import-only archive
state. An acknowledged contained expansion appends missing rows, then
atomically normalizes every selected-platform archive marker only after that
platform's history scan and persistence are structurally complete. Profile or
avatar enrichment failure remains nonzero but does not leave structurally
complete history on the predecessor marker.

Technical safety controls are printed in the normalized startup line:
`UMI_FBIG_HISTORY_GRAPH_DELAY_MS` (default 250),
`UMI_FBIG_HISTORY_MAX_CONVERSATION_PAGES` (default 10,000 per platform), and
`UMI_FBIG_HISTORY_MAX_MESSAGE_PAGES` (default 10,000 per thread). Invalid or
non-positive values fail preflight.

### 2. Exhaustive API traversal

For each requested platform:

1. Exhaust `/{page_id}/conversations` with
   `fields=id,updated_time,participants`, `platform`, and `limit` supplied as
   an explicit positional options hash, matching patch 12's Koala calling
   convention. The `participants` field is production-observed, not an
   official contract found in the Meta collection.
2. For each thread, read `participants` and exhaust
   `/{thread_id}/messages?fields=id,created_time,from`.
3. Apply the selected date boundary only after reading pages. Do not assume
   page ordering and do not use patch 12's recent-window early stops.
   Stop only at cursor exhaustion. Track opaque cursors in memory to detect a
   repeat, and enforce the high startup ceilings. A repeated cursor or reached
   ceiling is a loud incomplete failure, never successful truncation; cursor
   values themselves are never logged.
4. Account/inbox-scope the planning anti-join, then classify every absent mid
   by direction and outbound policy.
5. Fetch full details only for eligible absent mids, requesting the observed
   fields `id,created_time,from,to,message,reply_to,attachments`.

No records for a thread are written until all of that thread's listing pages
and all eligible detail requests have completed. Transient transport,
rate-limit, and server failures go through one request wrapper shared by
initial list calls, `next_page`, and detail calls. The wrapper delays after
every Graph call, retries transport failures, HTTP 429/5xx, and explicitly
recognized Graph rate-limit codes (`4`, `17`, `32`, `613`, `80004`) at most
three times with exponential backoff capped at 30 seconds and full jitter, and
never retries authentication/code `190` failures. Koala 3.4.0 does not expose a
reliable `Retry-After`, so the design does not claim to honor it or derive
behaviour from usage headers. Exhausted retries fail the thread or platform as
described under failure modes; they never turn into a truncated success.

Dry run performs the same pagination, identity resolution, anti-join,
direction classification, policy comparison, and detail fetching as apply
mode. It does not download attachment bytes, so its summary must distinguish
`attachment_urls_found` from `attachments_downloadable`; the latter remains
unknown until apply mode. When `OUTBOUND_POLICY` is omitted, dry run fetches
details for the union of all policy candidates (equivalent to `all`) so content
and attachment counts are comparable for every displayed policy.

After every detail fetch, revalidate the response as a separate trust
boundary: returned id equals the requested mid; `created_time` remains within
`SINCE` and the frozen `BEFORE`; `from.id` and `to.data` match the selected
participant and platform-specific business identity; and the detail remains
consistent with the listing's direction and thread. A mismatch fails the
thread rather than importing cross-thread or cross-platform data.

### 3. Participant, profile, and direction mapping

A normal imported thread must have exactly one external participant:

- Use `page_id` as the Messenger business identity and `instagram_id` as the
  Instagram business identity. The other id is not silently accepted for the
  selected platform.
- Remove the selected business identity from `participants.data`.
- Require exactly one remaining participant with an id.
- Use that id as the `ContactInbox.source_id`.
- Reuse an existing `ContactInbox` only by the exact platform participant id.
- Request the Page-linked Graph profile once per
  `[platform, participant_id]` in a run. The response id must exactly match the
  requested participant.
- Prefer profile name, then thread participant name. Prefer Instagram profile
  username, then the observed incoming sender username. Never derive a display
  name from a username.
- Existing attributes are fill-only. Replace a name only when it is exactly
  the importer fallback `Instagram user <source-id-last4>`; preserve custom,
  near-match, and different-suffix names. Existing avatars are never fetched
  or overwritten.

For each message, `from.id` equal to the external participant means incoming;
`from.id` equal to the selected platform's business identity means outbound.
The detail `to` set must contain the opposite expected identity. Any other
sender, zero external participants, or multiple external participants makes
the thread ambiguous. Log it and write nothing for that thread.

The Messenger-specific `ParticipantNameService` proves the participant-name
source but is not itself the import abstraction: its lookup is per PSID and
hardcodes `platform=messenger`. The importer consumes the already-fetched
thread participants for both platforms and does not issue redundant name
requests.

If the contact inbox exists, reuse it exactly and apply the fill-only scalar
profile merge with direct columns, even when all thread messages are already
present. If it does not, do not request its profile until at least one absent
message detail is prepared. Create the Contact with the planned scalar data
inside the successful thread transaction so contact events, IP lookup, avatar
jobs, and Enterprise contact callbacks cannot run. Then create the
ContactInbox with its normal token-generation callback. If its unique
`(inbox_id, source_id)` insert loses to a live writer, roll back the entire
thread transaction, reuse the winner, safely reapply the same evidence, and
queue an avatar only after commit. Do not leave the speculative Contact
orphaned.

Create no Contact, ContactInbox, or Conversation when the thread has no
eligible messages after source-id and outbound-policy checks. New contacts use
the participant name or the existing platform fallback convention. Set their
record timestamps from the imported range, never from import time. Set a new
contact's `last_activity_at` only from the latest imported incoming message;
leave it nil for an outbound-only thread. For an existing contact, only
advance `last_activity_at` with a callback-free maximum of the existing value
and latest imported incoming timestamp; leave all other attributes untouched.

Because direct inserts bypass `ApplicationRecord` and model validation,
normalize and validate every Meta-derived value before the transaction. Match
the repository's 255-character string, 20,000-character generic text,
150,000-character message content/processed content, URL, JSON attribute, and
15-attachment limits. Truncate human text and filenames deterministically with
an omission counter; never truncate ids used for identity or idempotency—fail
the thread if one cannot fit its target field. Build complete JSON defaults
and enum values explicitly rather than relying on callbacks.

### 4. Outbound overlap policy

The production full-history expansion uses `pre_presence`. It recovers history
clearly older than native Chatwoot presence while retaining the multipart
guard. The other policies remain explicit diagnostic/controlled alternatives.

Meta thread ids are not persisted on live Chatwoot conversations. Presence
must therefore be conservatively derived from non-imported messages for the
same account, inbox, platform, and participant/contact. Instagram presence uses
only `instagram_direct_message` conversations; Messenger presence must not be
influenced by a merged contact's Instagram messages. Presence excludes an
existing row only when that individual Message carries the import marker; it
never excludes an entire conversation merely because the conversation is an
archive. Any later native/live message counts as presence even if
`lock_to_single_conversation` placed it inside the archive. A partial rerun
therefore cannot hide new live activity or change its own classification.

The three apply-time policies are:

| Policy | Behaviour | Trade-off |
| --- | --- | --- |
| `no_native_presence` | Import outbound only when the participant/inbox/platform has no native Chatwoot message at all. Missing inbound is still imported. | Safest and simplest, but loses legitimate pre-Chatwoot outbound history when a long-lived participant later entered Chatwoot. |
| `pre_presence` | Find the earliest native Chatwoot message for the participant/inbox/platform. Import outbound strictly older than that timestamp minus 90 seconds; skip outbound at or after the boundary. With no native presence, import all outbound. | Recovers clearly pre-Chatwoot history while retaining the existing multipart safety window. Presence is participant-scoped rather than true Meta-thread-scoped. |
| `all` | Import every absent outbound mid. | Most complete, but can create duplicate bubbles for Chatwoot multipart sends and cannot distinguish native-app echoes from Chatwoot sends. |

Recommendation: use `pre_presence`. It preserves the one-off import's purpose
without pretending Chatwoot-era outbound provenance can be inferred. The 90
second guard matches the multipart heuristic already reviewed for patch 12.

This is a recommendation, not a decision. The dry-run summary must show how
many outbound messages each policy would import or skip, and apply mode must
require the operator's explicit policy.

### 5. One resolved archive conversation per Meta thread

Never append historical rows to a live Chatwoot conversation. Create or reuse
one deterministic archive conversation for each platform/thread, identified
as:

`umi-fbig-history:<inbox-id>:<platform>:<meta-thread-id>`

The marker is also stored in `additional_attributes` with the platform and
Meta thread id, normalized import configuration, and schema version. Instagram
archives retain
`type: instagram_direct_message`, preserving the stock conversation scope.

Insert the conversation directly with:

- the mapped account, inbox, contact, and contact inbox;
- `status: resolved`;
- no assignee, team, campaign, bot, SLA, priority, snooze, or waiting state;
- `created_at` equal to the earliest imported message time;
- `last_activity_at` and `updated_at` equal to the latest imported message
  time;
- `agent_last_seen_at` equal to the latest imported message time;
- `first_reply_created_at: nil`; and
- the deterministic identifier and import metadata.

Do not call `mute!`: it blocks the contact and creates an activity message.
Do not infer first reply: Meta cannot establish whether an outbound was a
human Chatwoot reply. Do not stamp `updated_at` at import time, because that
would make archives appear recently updated.

On rerun, recompute archive times using the minimum existing/imported
`created_at` and maximum existing/imported activity time so timestamps never
regress. Existing live conversations—including status, assignment, unread
state, waiting state, activity times, and first-reply data—are never updated.
Lookup is scoped by account, inbox, identifier, platform, thread metadata, and
contact because the identifier index itself is not unique. A mismatched row is
a hard failure.

An existing archive is reusable only while every existing message has this
importer's marker and the conversation still has its canonical resolved,
unassigned, read, non-waiting archive state. A later native message or live
state mutation makes it a live conversation: count its non-imported messages
as native presence, hard-fail that thread, and do not append or "repair" the
conversation back to archive state.

When `lock_to_single_conversation` is enabled and this archive is the
participant's only conversation, a future live inbound will reuse and reopen
it because that is the inbox's configured stock behaviour. The importer must
not change the inbox setting or patch the builder to avoid that. Apply refuses
without the explicit acknowledgement described above; dry run prints the
affected inbox and projected archive count.

### 6. Callback-free message persistence

Do not call patch 12's `MessageHealService`, the Facebook/Instagram message
builders, `Message#create!`, or a global callback/dispatcher suppression
switch. Global suppression is process-unsafe and would still miss direct job
enqueues and Enterprise callbacks.

For each eligible detail, build the complete row and insert it directly:

- original Meta `created_time` for both `created_at` and `updated_at`;
- exact Meta mid as `source_id`;
- `content_type: text`, `private: false`;
- incoming: `message_type: incoming`, `status: sent`, sender Contact;
- outbound: `message_type: outgoing`, `status: delivered`, no sender, and
  `content_attributes.external_echo: true`;
- content and `processed_message_content` populated explicitly;
- `content_attributes.in_reply_to_external_id` when `reply_to.mid` exists;
  and
- an import marker in `additional_attributes`, including platform and Meta
  thread id.

Immediately before insert, recheck
`Message.exists?(account_id:, inbox_id:, source_id: mid)`. A foreign-only match
is counted as an anomaly but does not suppress the target insert. A global
blocking lookup would deliberately recreate the cross-inbox false-positive
loss documented as I6; the schema's non-unique source-id index permits the
correct scoped row. Insert messages oldest first inside one database
transaction per thread.

Sequential idempotency comes from the single-writer lock, the deterministic
archive identifier, the pre-scan anti-join, and the just-before-write scoped
mid check. This is not a database uniqueness guarantee; a concurrent live
webhook remains theoretically able to race between check and insert. The
15-minute exclusion materially bounds that risk without adding a fork-only
schema constraint for a one-off operation.

Direct insertion intentionally bypasses message events and report listeners.
Historical rows may still appear in reports that query the messages table by
timestamp, but no first-response or event-stream history is reconstructed.
After commit, explicitly invoke the existing message search reindex operation
for rows that qualify, best-effort as the Intercom importer does. The summary
reports reindex jobs enqueued, not completed; asynchronous failures use the
existing separate reindex recovery path. Search indexing and an
Active Storage `MirrorJob` when the installation uses a Mirror service are the
only allowed post-import jobs. Both are internal persistence work, not product
events; failures are logged and do not roll back valid history.

### 7. Attachments and unavailable content

Only map the Conversations API shapes already observed in production and used
by the current healer:

- `image_data.url` as image;
- `video_data.url` as video; and
- `file_url` as file.

Unknown audio, share, story, reel, nested-media, reaction, or deleted-content
shapes are not guessed. Count and log them as unsupported.

Apply mode refuses attachment import when
`SAFE_FETCH_ALLOW_PRIVATE_NETWORK=true`. Fetch mapped HTTPS URLs one at a time
with `SafeFetch`, public-network SSRF/redirect protection, bounded open/read
timeouts, the configured maximum upload bytes, image/video prefixes, and an
explicit allowlist based on `Attachment::ACCEPTABLE_FILE_TYPES` for files.
Generic file content types are accepted only with an allowed extension. Do not
log signed CDN URLs or retain every attachment in a thread on local disk.

The applying service validates public-only fetching before its lock, first
Meta request, or write. Every attachment is also bounded by the remaining
`UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES`. If one thread crosses the remainder,
purge all of that thread's staged blobs, insert no rows from it, consume the
run budget, mark history incomplete, and skip the global avatar phase. Exact
equality succeeds. Count every successfully streamed file against the budget,
including a generic file omitted after its extension is rejected.

A successful fetch is uploaded through the Active Storage Blob API outside
the thread database transaction so checksum, byte size, service name, and
storage metadata are populated normally. Track the persisted blob id/key
before upload. Inside the transaction, direct-insert the Chatwoot `Attachment`
and the Active Storage join (`record_type: Attachment`, `name: file`) so
Attachment callbacks cannot enqueue Enterprise audio transcription or
broadcast a message update. Preserve the message's historical timestamps and
derive `Attachment.extension` from the sanitized blob filename because
`set_extension` is bypassed.

Tempfile removal, tracked-unattached-blob purge, and lock release run in
`ensure`. Upload or transaction failure purges all blobs staged for the
uncommitted thread; cleanup failure is itself an incomplete nonzero outcome.
If the configured Active Storage service is a Mirror, its internal
`ActiveStorage::MirrorJob` is allowed and counted.

A permanently expired URL, unsupported shape, or invalid/oversized file must
not roll back or hide the text message. Do not persist an Attachment row whose
only representation is an already-failed external URL. Instead:

- keep any available text and append a stable
  `[Historical attachment unavailable: N]` marker;
- when no text is available, use the marker as the message content so the
  historical event remains visible; and
- log only platform/thread/mid, omission reason, and counts—not message text,
  participant names, or URLs.

Permanent media omissions—unsupported shape, invalid content, size limit, or
HTTP 404/410—commit the marker and are terminal for this importer. The stored
message marker records omission count/reason so that limitation remains
queryable, but ordinary source-id reruns do not retry its media. Retryable
transport, HTTP 429/5xx, or storage failures fail the whole thread before the
mid is inserted, allowing a later rerun to recover the binary.

If message detail is permanently unavailable, the listing still supplies a
trustworthy id, timestamp, and sender direction, but content is unknown. Do not
invent a content row: log and count `content_unavailable`, leave the mid absent
for a future rerun, and mark the import outcome degraded/incomplete as defined
below.

After every selected platform has normalized history, process queued missing
avatars sequentially with the remaining shared budget and a 15 MB per-avatar
cap. Use `SafeFetch` and direct Active Storage association, not
`AvatarFromUrlJob` or an ordinary Contact save. A partial unique index for
`Contact/avatar` serializes importer and live writers; a uniqueness loser
purges its blob and preserves the live winner. Permanent profile/avatar denial
is degradation. Retry/storage/association/budget/cleanup failure is nonzero,
but the current history marker remains normalized so an exact rerun can retry
enrichment.

### 8. Transactions, progress, and completion

The execution unit is one Meta thread:

1. Fetch and validate all listing pages and participants.
2. Classify source-id presence, direction, and outbound policy.
3. Fetch and revalidate every eligible detail and all direct-insert limits.
4. In dry run, record the plan and stop for that thread.
5. In apply mode, fetch and stage eligible attachment blobs one at a time.
6. Atomically renew and verify lock ownership.
7. Open a database transaction.
8. Recheck mids in the target account/inbox.
9. find/create the participant records with the prepared fill-only profile
   plan;
10. find/create the deterministic resolved archive;
11. insert messages and successful attachment associations oldest first; and
12. directly recompute archive and incoming-only contact activity timestamps.
13. Commit, queue any missing avatar, then best-effort enqueue search reindex,
    purge any unattached staged blobs, and remove temporary files.

Only after all selected platforms finish and normalize history does the global
avatar phase spend the remaining budget.

If any write in the transaction fails, the thread writes nothing. Already
completed threads remain committed; rerunning safely resumes through the
anti-join. A ContactInbox uniqueness race rolls back and retries the entire
thread from fresh state. No cursor or run-state table is added for a one-off
operation.

Every log line uses `[UMI-FBIG]` and structured key/value fields. Emit
platform progress per page and a per-thread result. The final summary includes
at least:

- conversation pages and threads scanned;
- message pages and mids scanned;
- already-present mids;
- candidate incoming and outbound mids;
- per-policy outbound import/skip counts;
- details fetched and `content_unavailable`;
- attachment URLs found, downloaded, unsupported, and unavailable;
- profile requests/successes/unavailability/errors and projected/applied
  changes;
- avatar offered/preserved/attached/raced/unavailable/failure outcomes;
- attachment, avatar, and total downloaded bytes plus budget exhaustion;
- imported contacts, archives, incoming messages, outgoing messages, and
  attachments;
- ambiguous participants/senders and foreign-account source-id anomalies;
- failed threads, retry exhaustion, rate limits, and lock loss; and
- normalized scope/policy/cutoff/budget, marker normalizations, complete
  platforms, previously imported rows, reindex/Mirror jobs,
  `dry_run=true|false`, `scan_complete=true|false`,
  `write_complete=true|false`, and `degraded=true|false`.

Error logging is allowlist-only: platform, inbox/thread/mid, exception class,
HTTP status, Graph code/subcode and trace id, omission category, and counts.
Do not interpolate raw exception messages, response bodies, request URLs,
cursor values, raw usage headers, tokens, message content, participant names,
or signed attachment URLs. Treat ids as pseudonymous customer data: cap
per-thread/mid detail lines and keep routine progress as compact stdout plus
structured aggregate Rails logs.

Completion has three dimensions so omissions cannot hide behind one success
flag:

| Outcome | Summary | Exit |
| --- | --- | --- |
| Intentional date/outbound-policy skip or already-present target mid | Counted; no degradation | zero if nothing else failed |
| Permanent unsupported/404/410/oversized attachment represented by a marker | `degraded=true`, scan/write remain complete | zero with explicit degradation count |
| Permanent per-mid content unavailable | `scan_complete=true`, `write_complete=false`, `degraded=true` | nonzero |
| Ambiguous participant for a new thread with no archive | Counted omission, creates nothing, `degraded=true` | zero if nothing else failed |
| Ambiguous participant for a pre-existing archive, or ambiguous sender | `scan_complete=true`, `write_complete=false`, `degraded=true` | nonzero |
| Expected profile/avatar unavailability with complete history | `degraded=true`; history marker remains current | zero if nothing else failed |
| Profile request/contract or importer-controlled avatar failure with complete history | History marker remains current; enrichment incomplete | nonzero; exact rerun retries |
| Foreign-only mid anomaly with target row inserted | `scan_complete=true`, `write_complete=true`, `degraded=true` | nonzero |
| Repeated cursor, safety ceiling, auth/platform failure, or retry exhaustion | `scan_complete=false`; write reflects committed eligible threads | nonzero |
| Thread transaction, blob cleanup, or lock failure | `write_complete=false`, `degraded=true` | nonzero |

`scan_complete=true` means every requested cursor was exhausted and every
eligible API request reached a terminal classified result.
`write_complete=true` means every unambiguously eligible, content-available
item committed or was already present under the pinned import configuration.
A dry run has no write result; it reports `write_complete=not_applicable` and
may be scan-complete while binary downloadability remains unknown.

## Scope choice

The approved migration uses `SINCE=all` and the reviewed fixed `BEFORE`.
“All” means every cursor and message Meta still exposes, not deleted, hidden,
expired, restricted, or otherwise unavailable data.

| Scope | Behaviour | Trade-off |
| --- | --- | --- |
| `SINCE=all` | Traverse every page Meta exposes up to the fixed `BEFORE`. | Best fit for a one-time historical restoration and avoids guessing the integration start date; potentially slow and still cannot recover Meta's hidden/expired history. |
| `SINCE=<UTC timestamp>` | Import only messages at or after an operator-supplied boundary and before the fixed cutoff, while still exhausting cursors because ordering is unverified. | Reduces detail/download/write volume, but not listing traversal; choosing the wrong date leaves older recoverable history absent. |

Recommendation: run a complete dry run with `all`, inspect counts and
limitations, then apply `all` if the volume is operationally acceptable. Use
`since` only when there is a known business retention boundary or the all-time
dry run demonstrates an unacceptable volume.

The task requires the scope on every run, pins it in archive markers, and
echoes it in every summary.

## Alternatives rejected

### Replay the live Facebook/Instagram builders

Rejected for historical bulk import. It would create rows at the current time
and run the exact callbacks, dispatchers, automations, bots, notifications,
webhooks, reply jobs, and reporting events this patch must avoid. Rewriting
state after creation cannot retract those side effects.

### Temporarily disable callbacks, dispatchers, or outbound integrations

Rejected as incomplete and process-unsafe. Side effects originate in several
layers, including direct job enqueues and Enterprise Attachment callbacks.
Global switches could also suppress unrelated live traffic in the same
process. Direct insertion gives the import an explicit inert boundary.

### Append history to an existing live conversation

Rejected because imported timestamps and outbound echoes would change a
working queue object and could alter unread, waiting, first-reply, assignment,
and activity semantics. A deterministic resolved archive preserves history
without mutating the live conversation.

### Import all absent outbound mids unconditionally

Not selected as the default design because a single Chatwoot multipart bubble
can own several Meta mids while retaining only one. It remains an explicit
operator policy for completeness-oriented runs.

### Skip every outbound mid

Rejected as the only behaviour because the production audit's four confirmed
misses are outbound and pre-Chatwoot/native-app history is part of the desired
archive. The explicit policy surface keeps the trade-off visible.

### Keep failed attachment URLs

Rejected for historical imports. The serializer exposes `external_url` when
no blob exists, so an expired signed URL becomes a broken attachment. A
visible omission marker and structured count are more honest.

### Add broad import-run schema or global Active Storage uniqueness

Rejected. Persistent run tables and a broad attachment constraint add
unnecessary rebase/migration cost. A narrow partial unique index only for
`record_type='Contact' AND name='avatar'` is required because Rails'
`has_one_attached` is not database-unique and a Contact row lock cannot
serialize ordinary Active Storage writers. Deployment is gated on a
zero-duplicate clone/production preflight.

### Schedule the import or split it into Sidekiq jobs

Rejected. This is an operator-supervised one-time repair with two unresolved
scope decisions. A synchronous task has a clear exit status, keeps dry-run and
apply intent explicit, and avoids durable partial job chains.

## Failure modes

- **Authentication failure:** abort the whole run because both platforms share
  the Page token. A platform-specific permission/content denial may abort only
  that platform. Report incomplete, exit nonzero, and do not call
  `channel.authorization_error!`; a manual historical read must not disable a
  live channel.
- **Conversation pagination failure:** stop that platform. Previously
  committed threads remain; the summary is incomplete and rerun is safe.
- **Repeated cursor or safety ceiling:** stop the affected scan, report the
  reason without the cursor value, and exit incomplete/nonzero.
- **Thread message pagination or transient detail failure:** write nothing for
  that thread, continue other threads where possible, and exit nonzero.
  Permanently unavailable individual details are omissions, leave no row, and
  remain eligible on rerun.
- **Rate limit or transient Graph/server failure:** use the centralized
  bounded backoff/jitter policy. Retry exhaustion is visible and incomplete,
  never a successful short scan.
- **Listing/detail mismatch:** fail the thread; never trust changed ids,
  platform identity, participant, direction, or timestamp.
- **Ambiguous participants or sender identity:** write nothing for the thread
  and log ids/reason. Do not guess by participant name.
- **Foreign-account duplicate mid:** flag the anomaly but insert the correctly
  scoped target row. The database and the known I6 failure establish that
  foreign presence is not target idempotency.
- **Concurrent import:** the per-channel Redis lock rejects the second run.
  Atomic lease renewal prevents a stale owner from extending a new owner's
  lease; lost ownership stops new transactions.
- **Concurrent patch 12 healer:** the healer takes the same channel lock for
  its write. It skips/logs when history import owns the lease; history import
  fails lock acquisition when a heal is already writing.
- **Concurrent late webhook:** a residual race remains because source id is
  not unique. The recent grace and just-before-insert check reduce but cannot
  eliminate it.
- **Configuration mismatch on rerun:** reject before scanning. Append-only rows
  cannot be made to obey a later narrower date or outbound policy.
- **Archive identifier collision:** reuse only a row whose import metadata,
  platform, thread id, account, inbox, and contact all match. Any mismatch is
  a hard thread failure.
- **Archive became live:** any non-imported message or mutation away from
  canonical archive state makes reuse a hard failure. Do not append history or
  overwrite the live state.
- **Permanent attachment omission:** preserve the message with an omission
  marker; do not keep a broken external URL. This import does not later repair
  media on an already-present marked message.
- **Transient attachment/storage failure:** leave the whole thread
  uncommitted after cleanup so rerun can recover it.
- **Blob upload followed by transaction failure:** remove tracked orphan
  objects and leave the thread uncommitted; cleanup failure is nonzero.
- **Search indexing failure:** log and continue. The database archive remains
  canonical and can be reindexed separately.
- **Operator interruption:** committed threads remain valid; no in-progress
  thread commits partially. The final summary may be absent, so the next run
  must re-scan rather than trust terminal output as a cursor.
- **Requests-folder retention or other Meta omission:** cannot be detected by
  Chatwoot. "Complete" covers cursor exhaustion, not proof that Meta returned
  every historical event.
- **`lock_to_single_conversation`:** a future inbound may reopen the archive
  when it is the participant's only conversation. Apply requires explicit
  acknowledgement rather than silently weakening the archive boundary.

## Test plan

Service specs use stubbed Koala pages and exact production-shaped payloads.
They must prove:

- all conversation and message cursors are exhausted without timestamp-based
  early stopping, including deliberately out-of-order pages; repeated cursors
  and both safety ceilings fail incomplete/nonzero;
- the centralized Graph wrapper throttles every call, retries only the
  documented transport/429/5xx/Graph-limit cases with bounded jitter, and
  never retries authentication;
- both platforms use the correct business identity and IG archive type, and
  listing/detail id, timestamp, sender, recipient, scope, and thread mismatch
  all fail before writes;
- `SINCE=all` and timestamp classification, one frozen `BEFORE`, the
  15-minute validation, dry-run/apply cutoff reuse, and invalid argument
  failures;
- dry run fetches details but performs no Contact, ContactInbox, Conversation,
  Message, Attachment, Active Storage, notification, or search-index writes,
  and does not download binaries;
- dry run without a policy fetches the union of candidates and reports all
  three outbound-policy outcomes with detail-confirmed counts;
- apply mode refuses to start without explicit scope, cutoff, and outbound
  policy; while another FB/IG writer owns the lock; or without the
  single-conversation acknowledgement when applicable;
- exact rerun configuration is accepted, mismatched date/cutoff/policy is
  rejected before scanning, and summaries still count previously imported
  rows;
- atomic lock acquire/compare-and-renew/ownership-check/release, contention,
  expiry takeover, stale-owner renewal/release rejection, and release on every
  failure path;
- exact participant mapping, existing contact-inbox reuse, callback-free new
  contact creation, and loud zero/multiple/mismatched participant failures;
- a ContactInbox late-winner rolls back and retries the whole thread without an
  orphan Contact or an aborted outer transaction;
- existing contact attributes are untouched except for a callback-free,
  incoming-only monotonic historical `last_activity_at`; outbound-only history
  leaves it unchanged/nil;
- overlong content/name/filename/json/id handling and the 15-attachment limit
  enforce the same invariants model callbacks would have enforced;
- deterministic archives are resolved, unassigned, not waiting, historically
  timestamped, read at the latest imported time, and have no inferred first
  reply; their identifier includes the inbox and their metadata pins the
  configuration;
- existing live/open conversations retain status, waiting/read state,
  timestamps, assignment, first reply, and messages unchanged;
- a future live inbound creates a new conversation in ordinary mode, while
  acknowledged `lock_to_single_conversation` mode reuses/reopens the archive
  exactly as disclosed;
- an archive containing a later non-imported message or mutated live state
  counts that message as native presence and hard-fails reuse without changing
  the conversation;
- imported messages preserve exact Meta time, source id, direction, sender,
  delivery status, reply id, processed content, and import metadata;
- no dispatcher call for contact, conversation, message, reply, status, or
  assignment events;
- no `EventDispatcherJob`, `SendReplyJob`, Action Cable, webhook, hook,
  notification, agent-bot, greeting, out-of-office, template, automation
  message, reporting, contact IP/avatar, or audio-transcription job;
- an active `message_created` automation that sends a message plus enabled
  greeting/out-of-office settings still produce zero outbound work;
- `no_native_presence`, `pre_presence`, and `all` produce the documented
  outcomes for zero-presence, pre-presence, boundary-window, and
  Chatwoot-era outbound, with platform-scoped presence;
- the production multipart shapes are pinned: Facebook text plus two
  attachments and Instagram two attachments plus text do not create duplicate
  historical bubbles under the recommended policy;
- importer-marked messages are excluded from presence on partial rerun, while
  later native messages inside an archive count as presence;
- exact rerun inserts no duplicate contacts, archives, messages, attachments,
  or blobs;
- a foreign-only mid is logged but the correctly scoped target row inserts;
- scoped source-id recheck handles a simulated target late winner before
  insert;
- successful image/video/file attachment import; expired, oversized, and
  unmappable attachment degradation; and a visible attachment-only omission;
- SafeFetch rejects private-network mode, unsafe redirects, oversized bodies,
  and unapproved content types; filenames/extensions and Active Storage join
  fields are populated explicitly;
- permanent media failure commits a terminal marker, while transient
  network/storage failure leaves no mid and succeeds on rerun;
- Attachment and Active Storage association insertion does not enqueue
  Enterprise transcription or broadcast a message update; Mirror storage may
  enqueue only its allowlisted internal job;
- per-thread transaction rollback, orphan-blob/tempfile cleanup including
  upload-before-failure, cleanup failure, pagination failure, retry exhaustion,
  auth failure, patch-12 healer/importer shared-lock exclusion, and every
  completion-matrix exit;
- search reindex runs only after commit, reports enqueued rather than
  completed, and failure remains best-effort; and
- logs use only the field allowlist and never raw exception messages, response
  bodies, request/cursor URLs, usage headers, content, names, tokens, or signed
  URLs.

The task spec exercises environment/argument parsing, same-process database
identity mismatch/missing-variable exits before inbox lookup, and process exit
status.
The regression suite should include or mirror the Intercom importer's
side-effect test so future refactoring cannot accidentally replace direct
inserts with model creation.

Manual verification is two-stage:

1. Run:

   `UMI_FBIG_HISTORY_EXPECTED_DATABASE='<EXPECTED_DATABASE_NAME>' DRY_RUN=true SINCE=all BEFORE='<FIXED_UTC_CUTOFF>' bundle exec rake "umi:fbig:history_import[<INBOX_ID>]"`

   Save the normalized configuration and fixed `BEFORE`, compare the three
   outbound-policy counts, and spot-check Meta mids/details without downloading
   or writing.
2. After the scope, outbound policy, retention, and any single-conversation
   caveat are explicitly approved, run one platform first:

   `UMI_FBIG_HISTORY_EXPECTED_DATABASE='<EXPECTED_DATABASE_NAME>' DRY_RUN=false SINCE=all BEFORE='<DRY_RUN_UTC_CUTOFF>' OUTBOUND_POLICY=pre_presence PLATFORMS=messenger ACK_EXPAND_EXISTING=true UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES='<REVIEWED_BYTES>' bundle exec rake "umi:fbig:history_import[<INBOX_ID>]"`

   Add `ACK_SINGLE_CONVERSATION_REOPEN=true` only when the reviewed preflight
   requires it. Verify archive timestamps/state and the absence of outbound
   side effects, run the second platform with the same pinned configuration,
   then rerun both with the same `BEFORE` and expect zero newly importable
   rows. Known content/identity omissions may recur as candidates and must
   reproduce the same explicit omission counters.

## Files

Planned implementation footprint:

- `umi/app/services/fbig/history_import_service.rb` →
  `Umi::Fbig::HistoryImportService`
- `umi/app/services/fbig/history_import_graph_client.rb` → centralized
  throttled/retrying Graph reads and cursor safety
- `umi/app/services/fbig/history_import_attachment_service.rb` → SafeFetch,
  Blob staging, direct association data, and cleanup
- `umi/app/services/fbig/history_import_profile_service.rb` → exact/fill-only
  profile planning and direct avatar association
- `umi/app/services/fbig/history_import_lock.rb` → atomic renewable
  per-channel lease
- `umi/app/services/fbig/message_heal_service.rb` → acquire the shared writer
  lock around patch 12 healing
- `lib/tasks/umi_fbig_history_import.rake` → manual task only
- specs under `spec/services/umi/fbig/` for the service, Graph client,
  attachment service, lock, and healer lock coordination
- `spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`
- `db/migrate/*_add_unique_contact_avatar_attachment_index.rb` → concurrent
  partial uniqueness for Contact avatars
- `docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md`
- `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md`
- `UMI-PATCHES.md` row and detail 14

No OSS `app/` edit, Enterprise override, route, initializer, scheduled job, or
frontend change is planned. The narrow Active Storage migration plus the
service and task live
in UMI-owned paths, so the patch should rebase cleanly. The shared writer lock
is one explicit coupling to patch 12; removing either write path must retain or
remove its lock coordination deliberately. Patch 14 removal must remove the
healer's lock call before deleting the helper. Patch 12 removal may delete the
healer call while retaining the helper for history-import single-writer
protection. Record that dependency in both UMI patch-registry details.

Remove-when: upstream Chatwoot provides a callback-safe Meta history importer
that preserves original timestamps and archive state, handles outbound
multipart overlap, and degrades unavailable historical media explicitly; or
the one-time UMI import is complete and its rerun capability is no longer
needed.
