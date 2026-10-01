# Operator reminders in UMI Orders

1 October 2026. Approved product brief: native Chatwoot notification immediately;
one internal reminder after ten working minutes without a human reply; hourly
action digest when needed; 09:00 overnight/day queue. Daily 09:00–21:00 Asia/Bangkok.
First-response SLA remains five minutes. No three-minute alert. User approved
implementation after explicitly choosing ten instead of fifteen minutes.

## Goal and scope

Help Mai notice outstanding customer work: unanswered questions, promised checks,
booking/order/service actions and appropriate follow-ups. Each item has a Chatwoot
link, evidence, and a concrete next action. Customer messages remain operator-owned.
No new task manager, permissions system, public AI replies or marketing flows.
Six customer text inboxes (1,2,3,6,7,8) in account1; existing configurable integration
scope must control this rather than changing upstream behavior for other accounts.
Support is eligible: not_sales does not mean spam. Public ad-comment coverage
remains explicitly outside the observed DM queue until its collector exists.

## Research and selected approach

Chatwoot already has native notifications and snooze/reopen. Its existing UMI
OperationalReport correctly excludes private/bot/automation/failed replies from
human-response measurement; native waiting_since can be cleared by nonhuman replies.
Shumabit has jobs.yaml, Bangkok cron, IPC-only lib/telegram.js and durable report
delivery receipts. Reuse those interfaces. Source: app/models/message.rb,
umi/app/services/funnel/operational_report.rb, scripts/crm-friday-report.js,
tools/scheduler/jobs.yaml and lib/telegram.js in their respective repositories.

Native SLA alone cannot produce the requested semantic Orders checklist. Repeated
Rails/rake boot each minute is unnecessarily expensive. A separate notification
service/database would duplicate deployed infrastructure. Select a small read-only
UMI API plus a Shumabit script, with local private state and existing scheduler.

Official references: https://chatwoot.help/hc/user-guide/articles/1713167310-service-level-agreemtns
and https://www.chatwoot.com/hc/user-guide/articles/1677235281-lesson-3-a-mastering-core-features .

## Chatwoot facts contract

Add GET /api/v1/accounts/:account_id/umi/operator_queue and
GET /api/v1/accounts/:account_id/umi/operator_queue/:conversation_id .
The latter ID is the account-visible display_id, as in native conversation URLs.
Use existing account authentication/admin authorization for this internal report;
no new credential/role system. Both endpoints are read-only. Account/inbox scope,
redaction and explicit spam exclusions apply equally to list/detail.

List accepts required `since` (consumer activation ISO8601), `after_id` (default0),
and `through_id` (first response maximum internal id, carried across pages).
Use immutable-id keyset order,50 rows, next_after_id or null; read all pages.
Scope changes must not cause offset-based skipping. Next poll catches records
newly eligible behind the cursor.
List schema_version=1, account_id, as_of, timezone, business_open, coverage, next_after_id, through_id,
conversations[]. Each row: id (internal), display_id, inbox_id, status, snoozed_until,
assignee_name, sales_status, revision, waiting {message_id, started_at,
business_seconds, first_response} or null. Revision changes when relevant messages
are edited/deleted, private commitments added, status/snooze changes, or identity
changes, including relevant supplied commerce facts; it is not just the last public message id.
Opening a conversation, contact activity timestamps and sent/delivered/read receipts
do not invalidate analysis. Delivery is normalized to sent/failed in context and revision. Do not include customer phone,
email, address or message bodies in list/log output. URLs are constructed by the
client from its configured Chatwoot origin/account/display_id, never model output.

Candidate scope: current open/pending/snoozed text conversations plus recently
updated resolved conversations since an explicit consumer activation boundary.
Resolved status alone does not prove a promised action complete. No silent
pagination/row cap. Initial backlog is visible, not bulk-relabelled. Exclude redacted
contacts, spam, unsupported channels; recovered/unknown chronology is surfaced as
unverifiable rather than a fabricated timer. Multiple incoming messages preserve
the start of one waiting episode. Successful public human reply ends that episode;
later incoming starts a new one. Recovered incoming cannot clear a verified live
wait. A later live incoming establishes a valid lower bound after unknown imported
history. A recovered successful human reply clears the old wait with unverifiable
chronology until a new live incoming. Private/bot/automation/failed replies do not end it.

The reminder clock follows the user-approved daily09–21 Bangkok schedule, explicitly
returned as its basis. It does not change the existing historical SLA report or
inbox schedules. A 20:55 incoming is due at09:05 next day; a23:00 incoming at09:10.
Snooze cannot hide a genuinely unanswered incoming message from the timer.

Detail shape: {schema_version:1, account_id, as_of, conversation: row-with-context}.
Detail requires the same since parameter. Return404 for confirmed excluded/missing
records; distinguish network/auth/server errors. Detail returns the same row plus messages [{id, created_at, direction, private,
human, delivery_status, content, attachment_types, recovered, source_created_at}] for the full available conversation history,
and relevant existing customer/commerce context with payment facts clearly labelled.
Revision covers every supplied persisted input (including attachment/sync metadata,
classification and scope); context and revision describe a coherent snapshot.
Recheck time-derived freshness at dispatch. List uses batched metadata queries,
not full message bodies; contexts are fetched only for changed analyses. Partial
page reads cannot clear state or authorize sends.
No fetching attachment URLs or following instructions inside content. Mark missing
attachment interpretation. If too large for the configured model context, report
unavailable; never silently truncate history or assert no work remains.

## Shumabit processing and task contract

One script with tick and analyze modes; reuse existing report proxy/CLI route and
Telegram IPC. Two cron entries avoid long inference blocking deterministic timers:
tick every minute, analyze every five minutes. Each mode has its own flock. Analyzer
writes only atomic per-conversation analysis files; tick owns its own delivery state.
No service restart or changes to public/private-note bridge behavior are required.

Analyze changed revisions only. Bind saved results to account, internal conversation
id, revision, schema/prompt version and model configuration. Use isolated CLI
configuration with tools/MCP/settings/session persistence disabled as in the report.
Transcripts and private notes are untrusted data, never instructions. Closed-schema
validation includes evidence membership, field lengths and ISO deadlines; model
output cannot supply links, destinations or customer contact/payment details.
Private state is outside git (directories0700/files0600), with no raw transcript
or provider output in receipts. Keep the complete prompt and input within the
existing classifier's conservative operational ceiling of131072 bytes; exceeding
it produces an explicit unavailable result, never truncation. This is an operational
limit, not a claim about the model's context capacity, and belongs in model binding.
Each inference has a timeout and the analysis run
has a total budget. Process never-attempted/oldest-attempted revisions first, persist
each result immediately; failures/oversize mean unavailable, not an empty success.
Retry only on later scheduled runs, no inline retry loop. Discard stale results.
 Use the six-rule Mai framework (read/answer,
understand, recommend, next step, promises, useful follow-up); read full history but
identify the current episode. Return strict structured JSON: needs_reply boolean,
tasks [{kind, evidence_message_ids, action, due_at|null}], and uncertainty.
Kinds: reply, promise, booking, order, service, follow_up, review. A partial human
reply ends the factual response timer but an unanswered part of the customer
question remains an evidenced semantic reply task in the digest. A task needs source
message IDs; evidence must exist. due_at only from an explicit grounded deadline,
otherwise null means no established deadline, not arbitrarily overdue or a
requirement to negotiate one. Keep the actual next action. Current model
judgment cannot prove payment, inventory, delivery, prices, promotions, size/fabric
claims, return/fitting terms or channel permission. Historical messages prove a
request/promise, not current policy authority; missing facts mean check them. Never output
payment/identity changes or sending commands. Marketing follow-up is a suggestion
to the operator, not permission to message outside the allowed channel window.

Fresh analysis with needs_reply=false suppresses no-response alerts for thanks,
automatic mentions and other no-action messages. Stale analysis is never used to
assert an outstanding promise or suppress a new unanswered episode. If analysis
is unavailable, the deterministic 10-minute fallback says 'Check this incoming
message: no human reply recorded; AI assessment unavailable', rather than asserting
the customer needs an answer. Record coverage errors without sending repeated
system warnings every minute. Model failure must not erase valid factual waiting.

Immediately before EACH chunk recheck the send window and current facts; stop
unsent chunks at21:00. Confirmed exclusion removes items; fetch failures hold them
without consuming their notification identity. Preview delivery uses the same
ledger as scheduled delivery. Revalidation reduces but cannot eliminate the race
between the last read and Telegram acceptance. Before sending, fetch current facts again: replies remove waiting alerts; changed
revisions remove stale semantic tasks until reanalysis; removed/redacted/out-of-scope
conversations disappear. Snoozed semantic work is held until snoozed_until, unless
an explicitly promised earlier deadline has passed. Human closing alone doesn't
prove an evidenced promise fulfilled: analyze the changed conversation.

## Delivery and deduplication

Destination is the existing verified UMI Orders chat/topic, not a new Telegram
connection. English concise messages for Mai, no PDF for reminders. Group items
into one message per dispatch; split only to obey Telegram text limits, with a
receipt per chunk. Show conversation number/link, waiting age or due time, and
one concrete action. Evidence IDs remain in private state; do not show database
message IDs or repeated empty-deadline labels to Mai. A waiting alert and the
semantic reply task for that same episode share one item and delivery identity,
even when the cited question is later in the incoming burst. No semantic reply
notification bypasses the ten-minute timer while that factual wait exists.
Do not put raw transcripts or personal contact details in Telegram.

Ten-minute identity = conversation internal id + waiting start message id. Exactly
one attempted alert per waiting episode; hourly digests do not keep repeating that
unchanged wait. New incoming before a reply does not create another reminder.
Morning summary is separate: include outstanding overnight waits and day's tasks
once starting at the first healthy09:00-hour tick. A night's zero-business-minute wait may
appear at09:00 and get its single overdue warning at09:10; these have distinct meaning.

Semantic identity = conversation internal id + kind + sorted unique evidence IDs.
Paraphrasing alone does not create new work. Track grounded deadline changes and
a newly reached deadline separately, each notified once. Each chunk receipt stores
its item identities, including unknown attempts, across digest and alert paths.

Hourly digest: first healthy tick of each10:00–20:00 hour. Only new/changed actionable
tasks or a newly reached due time; same unchanged task is not resent each hour.
09:00 summary may repeat still-open work on a new day. Empty message is not sent.
At the first tick of each summary hour, freeze its conversation membership.
If analysis is unavailable or stale, retry those initial rows for the remainder
of that hour; completed rows retire independently. Later arrivals wait for the
next hourly digest (their ten-minute alerts still run). Discard the old membership
at the next hour. Morning waits must have started before09:00, so delayed analysis
cannot generate an early reminder for a newly arrived daytime message.
No sends outside09:00<=localtime<21:00. A missed hour is not replayed as multiple
old digests; current work appears in the next permitted dispatch.

Persist a sending marker before IPC; accepted only after a real message_id.
Timeout/ambiguous send stays unknown and is not blindly retried. Known/unknown
attempts and startup/read failures are visible through nonzero job exit and private
receipt. Failed or absent upstream data is not an empty queue. Do not mark a whole
hour delivered before its actual chunks have receipts. Concurrent ticks serialize;
successful analysis never marks Telegram delivery complete.

## Verification and delivery

Before code: independent simplicity/domain and failure-mode reviews of this spec.
User's accepted behavior is alignment authority; explain any material deviation
before implementation. Work in isolated Chatwoot and Shumabit branches.

Chatwoot tests: account authorization/isolation, read-only endpoints, display IDs,
business-hour boundaries, burst/private/bot/failed reply, edits/deletes/reopen,
snooze, support vs spam, redaction, existing unresolved backlog and complete context.
Keep existing OperationalReport regression suite green if shared helpers are extracted.
Shumabit tests:9:00/9:10,20:55→9:05; ten-minute once; later reply/new episode;
hourly changed/due-only; silence when empty; snooze and promise deadline; source
revision changed during analysis/before send; model failure; bad evidence/due time;
Telegram escaping/limits; concurrent lock; crash/unknown receipt no duplicate.

Stage without scheduled sends. Analyze the existing queue before enabling alerts
and inspect the resulting workload, so old no-action messages do not produce a
burst of unavailable-analysis fallback reminders at first launch.
Run read-only production preview and inspect representative genuine candidates
before enabling sends. Verify endpoint candidate count, duration and payload size so complete polling
finishes within its minute interval; optimize before activation if it cannot.
No fake customer conversation/purchase. Deliver one real actionable internal preview
only if there is current eligible work; otherwise record empty and observe the
natural schedule. Enable the approved jobs with scoped deployment and preserve all
existing cron entries. Confirm installed source hashes, schedule, destination,
health and one natural tick; morning/hourly windows may need later natural receipts.
Independent code review and fixes before signed commits/PRs and production delivery.

Rollback disables only these two jobs; retains receipts and leaves all customer
messages, funnel classification, Friday reporting and Meta configuration untouched.

## Review disposition

Two independent spec reviews completed. Incorporated partial-answer tasks,
no invented deadlines, authoritative product/policy checks, full input revision
binding, stable task identities, analysis fairness/timeouts, explicit pagination,
existing isolated CLI reuse, private receipt boundaries and per-chunk revalidation.
No change to the user-approved reminder timing or destination.

## Infrastructure delivery detail

Use a scoped crm-operator-reminders Ansible entry under the existing shumabit_chatwoot
role. It installs only this script's reviewed files from an exact committed local
checkout, creates private state, reads the existing Chatwoot operator token with
the existing helper (never creates/rotates it), and renders
/etc/umi/crm-operator-reminders.env (root:shumabit0640). Existing Friday model env
remains unchanged. Stage with scheduling disabled; activation installs only the
two named cron jobs, preserving the exact other entries. Back up touched remote
files/cron first and read back hashes and destination. No bot package, service
restart or broad workspace git pull. The live workspace has unrelated commits
and must retain them. Defaults leave activation false; explicit scoped rollout
turns it on after real previews. Readiness/errors integrate with existing job
health, not a new monitoring service.

## Final code review disposition

Completed independent code review found six issues, all addressed before release:
bounded late-analysis catchup for summary windows, case-insensitive model URL
rejection, shared identity for an entire unanswered burst, semantic-only revisions,
direction-aware recovered chronology, and schema-validated test fixtures. New
regressions demonstrated failure before the fixes. Runtime inference, polling cost
and accepted Telegram delivery remain production verification steps.
