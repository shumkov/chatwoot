# Historical CRM reconciliation and audit

2 October 2026. Implements the approved order: identify customers, establish
purchase facts, classify complete histories, then audit sales/service quality.
User requested autonomous execution. Base: `fcc371c7e`, matching release 21.

## Execution checklist

This is the working task list for this pass. Checkboxes mean verified completion,
not merely implementation or an attempted request. Raw customer evidence stays
in private artifacts outside Git; this document contains only aggregate receipts.

- [x] Recover the approved historical approach and latest deployment boundary.
  Production image readback on 2 October: Rails and Sidekiq release 21.
- [x] Verify Shumabit historical Shopify access without changing credentials.
  Live GraphQL returned `read_all_orders: true`; oldest retained order:
  `2025-03-12T12:41:41Z`.
- [x] Isolate work in `crm-historical-audit`, based on `origin/umi` `fcc371c7e`;
  preserve older dirty `crm` checkout and all other worktrees.
- [x] Record the agreed sequence and persistence constraints in this spec.
- [x] Independent procedure review: identity/financial correctness and
  simplicity/side effects; incorporate required findings.
- [x] Capture initial read-only account-1 conversation/contact snapshot, including
  resolved chats. Correction-history completeness remains open below.
- [x] Capture paginated Shopify customer/order and existing Klaviyo profile
  inventories. Nested transaction completeness and analysis sanitization remain
  open below; inventory completion does not close those tasks.
- [x] Close export/proposal review findings in the next-actions checklist below
  before model input, financial conclusions or any enrichment application.
- [x] Prepare exact identity matches and a separate ambiguity queue. Include
  identity references found in full messages, reviewed with speaker/context.
- [x] Verify payments/refunds for matched customers; distinguish customer-level
  purchase history from evidence linking an individual order to a conversation.
- [x] Audit a varied full-history pilot with matched commerce context and the
  Mai playbook; verify references and correct evaluation criteria where needed.
- [ ] Run the remaining archive analysis with explicit full-history coverage;
  expose incomplete attachments/chronology/identity instead of inventing facts.
- [ ] Produce proposed customer links, conversation/order links and canonical
  labels/attributes as a concrete change list; preserve human corrections.
- [ ] Review write effects: Meta/Klaviyo events, Klaviyo profile-triggered flows,
  customer-context sync, private notes and live reminder eligibility.
- [ ] Implement only missing supported historical-write behavior if necessary,
  with reviewed design, meaningful tests and independent code review.
- [ ] Apply verified unambiguous enrichment in bounded batches with current-state
  checks, readback and reconciliation. Leave disputed associations for Ivan.
- [ ] Deliver the audit: readable PDF, short Telegram summary and private sortable
  action list with conversation links, evidence, next steps and unknown outcomes.
- [ ] Incorporate the agreed quality rubric in the recurring Friday report;
  verify a scheduled run and keep Chatwoot facts separate from Shumabit formatting.

### Current checkpoint — 2 October 2026

Identity evidence review and audit calibration are complete. The latest execution
receipt below supersedes the initial discovery limitations in this table. The 46 reviewed contact merges are applied with verified profile readback.
Full archive draft generation is running; no report publication has occurred.
Draft judgments require review before application/publication.

| Source | Initial snapshot coverage | Remaining limitation |
| --- | --- | --- |
| Chatwoot | 1,095 conversations, 1,027 referenced contacts, 12,175 visible messages; 17,725 account contacts checked for duplicates | Topic-correction events and their evidence must be added; 30 deleted messages excluded; 1,215 attachments have metadata only |
| Shopify | 870 customers, 601 orders; historical access and top-level pagination verified | Current financial snapshots do not prove past buyer status; nested transaction limits need explicit coverage |
| Klaviyo | 844 profiles; top-level pagination verified | Profile matching and independent ownership/conflict checks are not implemented in the initial proposal script |

Chatwoot snapshot time: `2026-10-01T18:27:03.712031Z`. Commerce read window:
`2026-10-01T18:28:57.691Z`–`2026-10-01T18:29:22.176Z`. These are separate
source snapshots, not an atomic cross-system transaction.

The initial Shopify-only proposal pass found six existing customer bindings and
1,021 unresolved contacts. This is not a verified combined identity manifest.
Forty-nine conversations contain candidate email/order references requiring
speaker/context review. Eighteen histories exceed 100 messages, so the remaining
bridge limit would materially affect this audit if that path were used.

Private artifacts are under
`/Users/ivanshumkov/Downloads/umi-crm-historical-audit-2026-10-02/` and the remote
commerce snapshot under
`/home/shumabit/.local/state/crm-historical-audit-20261002/`.
Do not attach raw snapshots to Git, reports or model requests. The initial order
query includes arbitrary custom attributes, which can contain the `__cw` bearer
token; sanitization is required before further analysis input or distribution.

### Next actions — independent review findings

Both independent reviews accepted the revised read-only procedure. Their tooling
findings remain open; none is silently treated as completed by that acceptance.

- [x] Remove arbitrary order `customAttributes` from the export, or explicitly
  whitelist only fields required by the audit and known not to contain secrets.
  Check existing artifacts without printing values; produce a sanitized analysis
  copy. Keep raw restricted artifacts out of model input and report distribution.
- [x] Export both `classification_changed` and `classification_topics_corrected`,
  including `event_type` and `evidence_message_ids`; verify operator topic-removal
  corrections remain effective in every proposed label change.
- [x] Validate typed nonempty Shopify IDs, Chatwoot IDs and uniqueness before
  indexing or writing proposals; fail rather than silently collapse records.
- [x] Hold duplicate ownership of a selected Shopify ID across all contacts,
  and matches through either selected customer identifier, even when the current
  contact has only the other identifier. Check Klaviyo ownership independently.
- [x] Align phone normalization with the existing buyer-lifecycle strict matcher; no
  inferred country codes or short invalid international numbers as exact matches.
- [x] Add Klaviyo matching/conflict checks before calling the output a combined
  identity manifest. Until then label it explicitly as Shopify-only and incomplete.
- [x] Record transaction coverage separately from top-level pagination. The
  current order query uses `transactions(first: 100)`; at-limit or otherwise
  incomplete payment histories must remain unknown until adequately verified.
- [x] Reproduce matching/export defects with focused synthetic tests, fix them,
  show failing-to-passing results and obtain independent review of the changes.
- [x] Regenerate coverage and proposals, then review message-supplied identity
  evidence before the varied 12-history commerce-aware audit pilot.

After those checks: pilot → complete archive audit → reviewed change manifest →
concrete historical-apply design and verification → bounded application/readback
→ readable report and recurring Friday integration. A finding in one phase does
not silently authorize bypassing the next phase's checks.

### Execution receipt — corrected snapshot and pilot preparation

- Current Chatwoot snapshot: `2026-10-02T00:26:31.797029Z`, schema 2,
  1,095 conversations and 12,175 messages. Includes campaign markers and both
  correction event types. Three status events exist; no topic-correction events
  were returned. Original private snapshots are preserved.
- Sanitized commerce analysis copy omits arbitrary order attributes. There were
  230 orders with attributes, zero observed `__cw` keys and zero orders at the
  100-transaction query limit. No token values were printed.
- Identity/proposal regression suite: ten passed, zero skipped. Reproduced six
  original failures and two subsequent Klaviyo collision failures before fixes.
  Independent identity review: CLEAN. Read-only export/side-effects review: CLEAN.
- Initial matching remains six existing Shopify bindings, five unheld existing
  Klaviyo bindings and one held Klaviyo ownership collision. No links applied.
  Message references: 53 email candidates and four order references across 49
  conversations; these still require evidence review.
- Existing lifecycle rules returned 42 repeat, 176 client, 582 non-buyer and 44
  unclassified Klaviyo profiles. This is current profile state, not historical
  conversion attribution or a count of customers acquired through chat.
- Pilot selection: conversations 1, 2, 16, 24, 25, 38, 251, 428, 31, 69, 216,
  246; all six inboxes, two longest histories, existing commerce context and
  message identity evidence. Total 750 available messages, no tail truncation.
- Model input privacy tests: five passed after reproducing two credential-format
  defects. Output validation: eight passed after seven deliberately invalid
  outputs were accepted by the earlier validator. Every supplied conversation
  needs a complete rubric and real evidence IDs; unsupported verified purchases
  and noncanonical topics are rejected. Model output cannot replace run metadata.
- Native-app outgoing echoes are retained as potential human replies, matching
  Chatwoot's definition; campaign/automation/bot/private messages are distinguished.
  Snapshot has 5,298 external echoes, so ignoring them would distort the audit.
- Configured analysis route readback: `gpt-6-sol`, effort `low`, pinned CLI
  `2.1.283`, through the existing Friday-report provider configuration. This is
  configuration evidence only; pilot completion will be recorded separately.

### Execution receipt — reviewed identities and calibrated audit

- Latest identity manifest contains 48 message-supported contact proposals:
  one existing binding, 46 duplicate-card pairs and one exact new proposal.
  Reviewers checked identifier ownership in conversation context, excluding
  quoted third-party addresses and test messages. Two additional phone matches
  use explicit international numbers supplied by the customers themselves.
- Concrete consolidation manifest: 46 distinct pairs, 51 retained conversations,
  46 retained inbox links and three retained profile-ledger rows. Fresh preflight
  at `2026-10-02T01:08:39Z`: every imported duplicate has zero conversations,
  sender messages, notes, calls, CSAT, UMI events, attributions, drafts or ledger
  rows. Neither side has pending/submitted roles or pending conversion deliveries.
  All identifiers agree; no retained card has a null/conflicting Shopify key.
- Consolidation direction: retain the existing social/conversation contact and
  merge the empty imported Shopify card into it through native ContactMergeAction.
  This preserves conversation IDs, message ownership and channel links without
  building general UMI event migration. Native merge removes the imported Klaviyo
  binding; async profile discovery must recover the exact same profile before a
  pair is accepted. Never merge the conversation-bearing card into the empty one.
- Independent merge review found no architectural blocker for this narrow cohort.
  Before each write also check blocked status, contact labels, company assignment
  and redaction markers: native merge does not preserve every contact field.
  Stop on meaningful loss, fresh dependencies or drift. Start with one canary;
  verify async binding, retained ownership and absence of new conversion events
  before the remaining pairs. An ambiguous response requires persisted readback,
  never an automatic second merge request.
- Live published n8n private-note consumer matches source (nine code-node hashes)
  and excludes private messages. Live Shumabit bridge matches source and requires
  a staff-authored private note beginning `@shumabit`; senderless customer-summary
  notes do not invoke it. No active Chatwoot automation rules were found.
- Full-history pilot plus independent calibration covered long, Thai, refund,
  collaboration, pickup and unresolved-identity histories. Low-effort drafts had
  unsupported criticisms, so this one-off archive audit uses `gpt-6-sol`, effort
  `high`, one complete conversation per call. Production model settings unchanged.
  Final isolated checks of #69, #246 and #333 were accepted by independent review.
- Final criteria: unavailable evidence is not operator failure; later fulfillment
  closes earlier promises; old silence is not today's outreach queue; captured
  money and refunds are separate; current customer ownership does not prove chat
  conversion. Explicit influencer/wholesale roles are proposals; VIP is not inferred.
- Validation: identity 10/10, privacy 5/5, output 9/9; zero skipped. Archive inputs
  contain all 1,095 conversations and 12,175 available messages, no tail truncation.
  Four bounded analysis processes are planned; receipts bind exact input, prompt,
  model and effort. Missing usage/cost remains unknown, not zero. Model/schema
  failures are held for inspection rather than silently dropped or blindly retried.

Remaining sequence: canary and bounded identity consolidation; complete archive
drafts and review; supported historical classification/projection design; apply
reviewed enrichment; publish readable report and incorporate recurring audit.
Resolved-chat label projection is still deliberately unsupported by the live path
and remains an explicit implementation task, not a reason to reopen old chats.

### Related follow-ups that must not be lost

- [x] Fix and live-verify direct `@shumabit` full-history loading. PR22 is merged
  and the two bridge files deployed. Long reads matched database IDs for 313 and
  279 messages. Two authorized private checks in #251 used the same session,
  with 314/316 prompt messages; both retained the earliest message. Public
  messages and commerce counts were unchanged. No sibling service was restarted.
- [ ] Add the deferred command feedback behavior: immediate private in-progress
  note, then edit that same note to success/failure. Start with `/paid-in-chat`
  and reuse the pattern for actual existing commands; no new permission system.
- [ ] Finish Mai's practical guide and evidence-backed training examples. She
  and Ivan correct erroneous audit judgments rather than label every chat.
- [ ] Verify operator coverage of advertising comments and the real scheduled
  reminder/Friday-report deliveries; keep historical backlog out of live alerts.
- [ ] Meta follow-up after review: obtain granted scope, verify genuine eligible
  event acceptance and actual optimization availability before enabling Purchase.
  Request `2325891674853203` submitted 1 October with both new recordings;
  Meta UI confirmed **Review in progress**. Submission is not permission approval.

No new public AI customer replies, AI order-creation feature, runtime migration,
ad campaign setup/spend, or automatic historical customer outreach is added by
this work. Linh continues to own campaign operation.

## Approach

Use a private, dated research snapshot and existing business rules before any
bulk CRM writes. This is a one-off audit, not a new service or CRM entity.
The current operator queue deliberately excludes much of the resolved archive;
it is not the historical dataset. The private-note bridge previously capped input at 100 messages; that separate
repair is now deployed and accepted. This audit uses its own frozen full export.

1. Export account 1's six text inboxes (1,2,3,6,7,8), including resolved, spam
   and non-sale chats. Use a repeatable-read, read-only database transaction and
   explicit field selection. Exclude redacted contacts and deleted message bodies.
   Retain full available text, message IDs, timestamps, recovered markers,
   direction, author type, send status, current labels and operator corrections.
   Include all account contacts for duplicate identity detection, but evaluate
   only contacts referenced by scoped conversations. Do not export credentials,
   provider tokens, email HTML blobs or attachment download URLs. Record missing
   attachment/audio/image content and capture-time bounds.
2. Through the existing Shumabit Shopify credential, fetch all retained customers
   and orders with complete pagination. Live read on 2 October confirms
   `read_all_orders` and oldest order 12 March 2025. Fetch transactions for
   candidate matched orders when needed; reuse verified lifecycle paid facts and
   financial assessment code. Paid status, order creation, authorizations, gifts,
   deposits and unpaid TBYB are not equivalent to a completed paid purchase.
   Obtain existing Klaviyo profiles read-only, with full pagination, using the
   existing client. Separate current lifecycle from lifecycle as of each episode.
   Past buyer status requires dated evidence establishing completed payment
   before that episode. A current paid/refunded snapshot, current order total,
   or aggregate lifecycle alone does not establish earlier completion. An old
   refunded/edited order without contemporaneous paid evidence has unknown past
   lifecycle; later payment cannot retroactively make the customer a prior buyer.
3. Produce deterministic identity proposals: existing explicit provider IDs;
   exact normalized email or strict international phone with all shared fields
   consistent. No inferred country code, fuzzy name or social-handle auto-match.
   Duplicate contacts/provider identities, conflicting fields or stale existing
   IDs are held. Treat multi-channel contacts as separate records until supported
   merge/link behavior is established; do not merge them merely to improve counts.
4. Read entire histories to extract customer-supplied identity/order evidence,
   grounded by message ID and speaker. An email quoted by an operator or a gift
   recipient's phone is not necessarily the customer's identity. Such matches
   remain proposals until evidence is reviewed. An order URL/number is a candidate
   association, not proof of causal attribution. A customer's purchases must never
   be credited to all their conversations.
5. Audit complete histories with confirmed commerce context. Reuse the existing
   taxonomy and Mai playbook. Distinguish sales, support/returns, influencer work,
   social mentions, recruitment/spam and tests. Assess episodes with concrete
   message evidence and identify good practice as well as omissions. Deterministic
   code counts records, money and timing; the model judges meaning and suggestions.
   Long histories must be explicitly held or processed in ordered complete chunks
   followed by synthesis; never take only the tail and call it a full-history audit.
6. Produce a private sortable action/proposal list and readable audit. Each row
   identifies its evidence, uncertainty and scope. Missing links/payment evidence
   mean unknown, not a lost sale. Do not estimate lost revenue from silence.

## Persistence boundary and side effects

Read-only discovery and analysis proceed immediately. Before applying enrichment,
review an exact change manifest against current records and the existing write
paths. Preserve manual corrections and unrelated labels; no new legacy fields.
Current `ProfileBinding` enforces one profile owner; automatic `resolve` also
checks duplicate identifiers, but explicit `perform` does not. The manifest must
retain its independent duplicate-identity hold for either route. Binding itself
enqueues profile sync, which can flush pending/submitted roles to Klaviyo. Inspect
those roles before writing and read back asynchronous results and private notes.
Current order resolver uses Chatwoot's narrower token, so old
order writes must not bypass validation using the Shumabit token.

Historical classification must not create present-day QualifiedLead/Purchase
events, customer replies, marketing flow entries or live reminder tasks. Before
enabling writes, trace callbacks and exporter triggers, check profile-triggered
flows, and verify fresh counts/readback on a bounded batch. Existing APIs do not
provide an end-to-end historical apply mode: sales transitions require live
qualification evidence, and order linking requests paid-event reconciliation.
A narrow historical path requires a separate concrete design after the manifest
shows which operations are actually needed; direct database writes are not a
replacement. No historical Meta replay is in scope.

Identity writes can also unlock already-pending paid deliveries through
`PaidCustomerLink`, without creating a new event. Before applying, inventory
affected pending events/deliveries and establish durable historical exclusion for
those owned by this pass; a temporarily disabled export flag is not sufficient.
Do not suppress genuine unrelated live events. Customer lifecycle/role labels
represent current verified customer state; audit episode facts are timestamped
separately. Existing projection skips resolved conversations: a historical apply
path must support that deliberately without reopening chats or forging freshness.

Inspect active `conversation_updated` automation and webhook consumers: ordinary
label/attribute updates can send messages and change queue membership through
`updated_at`. Verify before/after reminder candidates and consumer eligibility,
not only counts of emitted conversions. An old audit write must not establish
the public-message activity boundary used by live reminders.

## Narrow historical application design

The read-only audit is not applied through `ConversationTransition`: that path
correctly treats qualification as a live advertising event. Add one UMI service,
`Umi::Funnel::HistoricalClassification`, called from an explicit one-off Rails
runner manifest. No new HTTP endpoint, scheduler, permission model or opportunity
entity. Live classification needs the small event-based guard correction below.

Input per row: account/conversation/contact IDs, run ID, snapshot timestamp,
expected public message IDs with original text/direction/timestamp and attachment
metadata plus relevant captured private staff guidance, expected provider identity and semantic customer/commerce facts used by
the review, expected current sales status/topics, reviewed decision and its evidence
IDs. The runner selects only reviewed rows; unknown identities do not become
matches. Raw history remains in the private manifest, never an event payload.
Read-only preview returns eligible/held plus the proposed deltas; apply validates
the same conditions again under the existing contact-then-conversation locks,
locking captured message rows before final comparison as the live classifier does.
The preparer refreshes direct commerce inputs and holds changes before generating
the manifest; the service compares the same provider binding and relevant persisted
customer facts. Unrelated sync timestamps do not invalidate a decision.

- Require configured account/inbox, unchanged contact, no redaction, no new or
  modified public history and no manual status/topic correction. A changed row
  is held for a new review. New customer-summary private notes from identity
  reconciliation do not invalidate the underlying public-history review. Any
  other new, modified or deleted private staff guidance also holds the row; lock
  and compare captured guidance alongside public evidence.
- Backfill only conversations whose current sales status is absent/unevaluated;
  preserve already classified/qualified/order_placed/purchased conversations.
  Latest-episode judgments in the report do not overwrite existing live events.
  `uncertain` stays unevaluated; never infer an order or paid outcome. Add only
  evidenced canonical topics, preserving unrelated labels. Existing operator
  topic corrections hold the row instead of trying to reconstruct intent.
- Historical `qualified` is a displayed reconstruction, not a live qualification.
  Live guards must use the existing nonredacted `conversation_qualified` event to
  retain qualification, rather than the displayed status alone. Remove the
  unconditional qualified shortcut in ConversationClassifier; ConversationTransition
  keeps qualified sticky only when that event exists. Preserve order_placed and
  purchased as before. A later genuinely qualifying incoming can therefore emit
  its first live event with fresh evidence; historical evidence never qualifies it.
  Persist the reviewed public-history cutoff and snapshot time in every completed
  historical evaluation, including uncertain results. Projection uses only applied
  evaluations; fresh-evidence eligibility uses the latest completed review. ClassificationContext and ConversationTransition share that boundary
  when selecting qualification evidence: evidence must be after both the captured
  ID cutoff and snapshot time. This is separate from the processing watermark.
  A new greeting cannot turn an archived buying message into fresh qualification.
- Persist one `classification_evaluated` event with provenance `historical`, mode
  `historical`, original evidence time and today's observed time. Recovered
  messages use their original external timestamp; missing/invalid timestamps
  remain unknown, and an uncertain review with no evidence has no occurrence time. Do not emit
  `classification_changed`, `conversation_qualified`, `order_paid` or deliveries.
  Do not set the live classifier's `input_message_id` watermark. Existing weekly
  operational classification metrics only accept auto-mode evaluations, so this
  event does not pretend an old chat was classified on time. CommerceProjection
  reads the applied historical evaluation only as fallback when no live/manual
  classification_changed exists; the latter always takes precedence. This keeps
  normal commerce refresh from erasing the reconstruction.
- Apply the native managed sales projection and current verified customer labels.
  Extend CustomerProjection with an explicit historical option that also assigns
  resolved conversations, without changing open/pending/resolved or reopening.
  Ordinary recurring customer projection keeps its existing resolved snapshot
  behavior. A single private summary explains actual changes and their historical
  basis; use the existing senderless customer-summary marker so consumers ignore it.
- Replay the same run/conversation returns its prior receipt without a second
  note. A different decision under the same run key is rejected. Event and local
  projection/note changes are one transaction; a note failure rolls back changes.
- Customer role proposals remain a separate reviewed manifest. Apply influencer/
  wholesale through existing CustomerMutation with source ai, preserving explicit
  no and VIP. Before that phase inspect live Klaviyo flow triggers; profile writes
  are not covered by the private-note webhook check. No marketing-flow activation.
- Customer order ownership and conversation attribution remain separate. Current
  order resolver scope limitations still apply; no historical paid replay and no
  linking every customer order to every conversation.

Verification: full-history drift, manual override, redaction, unchanged contact,
invalid evidence, qualified backfill with zero conversion deliveries, resolved
label/note application without reopening, preserved unrelated labels/statuses,
uncertain evaluation, one-note replay, changed replay rejection, transactional
note failure, live classifier watermark unchanged and unchanged reminder activity
boundary (candidate membership may change through updated_at, but downstream
alerts must still reject absent post-activation public activity). Test historical
qualified → genuinely new buying evidence → exactly one live qualification, plus
commerce refresh retaining historical state and later manual/live precedence.
Include a new greeting plus archived qualifying evidence (zero live events),
concurrent message deletion/edit and edited prior private guidance coverage.
Existing customer-projection/
live-classifier tests must still pass.
Two independent spec reviews precede implementation; code review and a bounded
production canary precede any archive application. Until then all AI labels are
proposals. The exact change list will be generated from completed reviewed audit
receipts rather than trusting arbitrary model output directly.

## Alternatives rejected

- Classify first, match later: biases repeat/support and outcome judgments.
- Use the live reminder queue or last 100 messages: misses resolved/history context.
- Match names/handles automatically: risks assigning another person's purchases.
- Widen dates on live funnel reports: does not reconstruct historical coverage.
- Build a new agent runtime: unnecessary; reuse existing read access and prompts.

## Verification and delivery

Record source versions, snapshot dates, counts, date ranges and pagination
completion. Reconcile IDs without duplicates and verify every proposed reference
exists in the snapshot. Tests cover ambiguous email/phone, shared contacts,
conflicting identifiers, old repeat buyer plus return, free gifts, unpaid TBYB,
refunds and message histories longer than 100 messages. Compare a varied sample
including payment after an episode and refunded orders without prior paid proof
manually before interpreting aggregate AI conclusions. Independent reviewers
inspect this procedure and any resulting code before bulk writes.

Deliver a short Russian summary, detailed readable PDF and private action list.
Telegram publication to UMI group / Orders is already requested; publish only a
reviewed report, not raw customer exports. Record unresolved identity questions
with prepared recommendations so Ivan only corrects errors/ambiguities.

## Sources

- Existing `UMI-HISTORICAL-CRM-AUDIT-APPROACH.md`, CRM data contract, stage-one spec.
- `ClassificationContext`, `OperatorQueue`, `ProfileBinding`, `CustomerContextSync`.
- https://shopify.dev/docs/api/usage/access-scopes : historical order scope.
- https://developers.klaviyo.com/en/reference/events_api_overview : historical
  event semantics; profile changes are a separate potential flow trigger.

### Execution receipt — identity consolidation and bridge repair

- 46 native reverse merges accepted on 2 October, last verified at
  `2026-10-02T01:27:08Z`: 51 retained conversations and 3,106 original messages
  preserved, 29 new senderless private customer-summary notes, zero unexpected
  conversion events/deliveries. Every expected Shopify ID and exact previous
  Klaviyo profile read back after async context acknowledgement. Imported cards
  were empty; blocked/company/contact-label fields were checked.
- One initial canary attempt stopped before HTTP because the default credential
  file had no Chatwoot token. No merge occurred. Fresh preflight followed by the
  existing bridge service environment completed the canary; both attempt receipts
  remain private. One batch paused for delayed async sync, then resumed only after
  successful readback; no duplicate merge requests.
- Direct bridge full-history fix: reviewed signed commit `eeaa6030`, merged through
  Shumabit PR22 as `5014a5346baece56b343e352fa1fabe0cf23bc7d`. Sixty tests passed,
  zero skipped; demonstrated 100 versus 151-message RED before the fix. Runtime
  deployed at `2026-10-02T01:41:25Z`; hashes and health verified. Private requests
  12277/12279 received replies 12278/12280 in the same CLI session. Full prompts
  contained 314/316 messages; oldest message 2823 remained in both answers.
  Seven sibling owners, existing session state, public messages and commerce
  counts were unchanged. Private receipts are in `bridge-release/`, under
  `deployed-20261002T014125Z/` and `acceptance-251/`.
- Archive validator corrected a false rejection of an empty incoming plus private
  context notes (#48): no episode needs inventing for absent visible content.
  Reproduced RED then 11/11 GREEN; saved model output reused without re-inference.
- User supplied Meta annual Data Access Renewal completion for app2163627007746338.
  This is not evidence of `instagram_manage_events` approval. Live App Review UI
  recheck failed through browser/AppleEvent timeout; no permission status changed
  on that basis.

### Execution receipt — scheduled reporting and side-effect inspection

- Natural Friday09:00 Bangkok run completed and delivered the2October PDF to
  UMI Orders, message22754, accepted`2026-10-02T02:01:31Z`. This confirms the
  existing aggregate report schedule; archive quality integration remains open.
- Two identical Friday cron entries existed. The period lock rejected the second
  invocation before delivery. Removed only the old duplicate outside the managed
  scheduler block, verified one remaining and exact preservation of all other
  entries; private before/after/receipt retained. Scheduler source has one entry.
- Natural reminder tick and analysis at02:00–02:01Z: five candidates, zero
  actionable items, zero unavailable/unknown results, no sends. Morning/hourly
  delivery with a genuine actionable item remains unverified.
- Klaviyo live flow inventory and full definition read02:00Z: one live Welcome
  Series, triggered by joining listQQBFkf. No segment/property trigger exists.
  This pass does not add list membership or consent. Definition saved privately;
  recheck before role application. No flow was modified or activated.
- Archive collection checkpoint02:01Z:369/1095 conversations and6410messages
  validated, including two separately attributed manual timeout reviews.
  Remaining726 are visibly incomplete, not counted as reviewed. Collector tests
  passed7/7, zero skipped; independent review pending.

### Execution receipt — final exact identity and historical writer checks

- Contact2433 / conversation513 linked through the existing Shopify customer PUT
  and native email-only contact update. Fresh exact provider ownership, current
  and prospective paid-event dependencies, integration hooks and message identity
  were checked before each stage. Expected Shopify customer and Klaviyo profile
  read back with a completed newer sync; all136 original messages, resolved status
  and inbox links preserved. No order attribution or conversion delivery created.
  Exact private receipts: `identity-2433-application/`. One initial provider-read
  preflight failed before any write because the client library is root-readable;
  the read was rerun through existing sudo access without changing permissions.
- Independent fresh reconciliation of all46 earlier merges at02:05Z again found
  all51 original conversation owners and3106 message hashes unchanged,46 exact
  Shopify/Klaviyo bindings and no surviving imported duplicate cards.
- Historical service tests cover transactional note rollback, idempotency,
  public/private/attachment drift, real database message-delete contention and
  actual operator-queue index/show remaining inactive after archive projection.
  Initial missing-service RED:9 failures; first service/projection/boundary GREEN:
  38 examples, no failures or pending.
- Independent domain review added three must-fixes: persisted semantic commerce
  drift, uncertain historical freshness boundary and recovered source timestamps.
  Reproduced failures before fixes; combined historical suite now30/30 GREEN.
  Full existing-classifier/commerce regression run and final reviews are underway.
- Two archive responses (#378/#397) correctly reported no episode for outgoing
  thanks with no incoming context. Validator wrongly demanded an invented episode.
  Reproduced RED, corrected the narrow uncertain/unknown/no-incoming case,12/12
  GREEN. Saved successful model responses reused without inference retries;
  resumed remaining batches with separate continuation logs.

### Final review checkpoint — 2 October, 02:30 UTC

- Delivery status and campaign provenance now participate in the historical review
  comparison. Both missing-field regressions were reproduced before the fix;
  independent source review is clean. Final combined regression suite passed109
  examples, zero failures or pending; scoped Ruby lint passed all9 files.
- The existing qualified-preservation test used a status-only fixture, which no
  longer represents a genuine live qualification. It now creates the real native
  qualification, then a new refund request, and verifies preserved status/topics
  without additional qualification or delivery rows. Production guards remain.
- Archive collection reached497/1095 conversations and7673 messages at02:29Z.
  Two further CLI timeouts (#402/#524) are preserved and separately reviewed from
  all three available outgoing messages: uncertain, no inferred purchase/role or
  criticism. Two reviewers agree; remaining never-attempted batches continue.
  Collector extension tests:15/15, zero skipped; source/prompt/duplicate checks
  apply to each explicit manual source. No failed model request was retried.
- Independent quality review covers10 conversations/126 messages. Test conversation
  #14 is excluded from commercial totals and application. Unsupported criticism
  in #215/#373 and stale current-service proposals are held; proposed actions
  require fresh verification, not automatic outreach. Corrections are an immutable
  private overlay; original model receipts are unchanged.
- Weekly conversation-quality integration is separately designed in
  `UMI-WEEKLY-CONVERSATION-QUALITY-SPEC.md`; it is not included in this release.
  Existing Friday report delivery does not prove quality-audit coverage.
