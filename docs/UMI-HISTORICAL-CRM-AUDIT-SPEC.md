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
- [x] Run the remaining archive analysis with explicit full-history coverage;
  expose incomplete attachments/chronology/identity instead of inventing facts.
- [x] Produce proposed customer links, conversation/order links and canonical
  labels/attributes as a concrete change list; preserve human corrections.
- [x] Review write effects: Meta/Klaviyo events, Klaviyo profile-triggered flows,
  customer-context sync, private notes and live reminder eligibility.
- [x] Implement only missing supported historical-write behavior if necessary,
  with reviewed design, meaningful tests and independent code review.
- [x] Apply verified unambiguous enrichment in bounded batches with current-state
  checks, readback and reconciliation. Leave disputed associations for Ivan.
- [x] Deliver the audit: readable PDF, short Telegram summary and private sortable
  action list with conversation links, evidence, next steps and unknown outcomes.
- [x] Incorporate the agreed quality rubric in the recurring Friday report;
  keep Chatwoot facts separate from Shumabit formatting. Full21-history pilot,
  real PDF and production installation accepted on2October.
- [ ] Observe the next natural Friday delivery with the newly installed quality
  section. The2October scheduled aggregate report was verified separately; it
  is not resent or presented as proof of the later quality installation.

### Current checkpoint — 2 October 2026

Full archive analysis covers 1,095 conversations and 12,175 visible message rows.
48 verified customer identities are reconciled. 899 historical classification
decisions are applied and read back; nine test-only threads are excluded and
187 histories remain held. Customer roles are applied to 142 contacts: 112 remain
local pending a verified identity and 30 are verified in existing Klaviyo
profiles. Five approved candidates remain held; the separate 45 semantically
unapproved contact-role proposals were not applied. The final six-page archive
PDF and 1,095-row register are delivered to UMI Orders as messages22759/22760.
Recurring weekly quality is
installed after a 21-chat pilot. Telegram Shumabit has verified administrator API
and native Rake access. The latest receipts below supersede initial discovery
limitations, which are retained as history.

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
- [x] Deliver Mai's practical guide (Orders message22758). She and Ivan correct
  erroneous audit judgments rather than label every chat.
- [x] Deliver the separate archive PDF with evidence-backed training examples
  (Orders message22759), followed by the current review register (message22760).
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

### Delivery checkpoint — 2 October, 03:08 UTC

- Historical writer merged through Chatwoot PR71 as `769f28489`; automatic-email
  source fact merged through PR72 as `da5551f77`. Signed release tag
  `umi-v4.16.0-23` points to the latter and includes both changes. Relevant CI is
  green; upstream deployment/MFA checks were skipped by their workflow conditions.
  Image build and infrastructure-owned production acceptance remain outstanding.
- Single-conversation application manifest for #36 has 28 passing preparation
  checks and independent review. Previously uncaptured content attributes and
  attachment timestamps were explicitly reviewed as a fresh baseline amendment;
  this does not pretend they were captured in the original export. Locked preview,
  actual application and persisted side-effect checks remain outstanding.
- Weekly quality implementation merged through Shumabit PR23 as `91399dd4`.
  Two code reviews are clean; 78 tests passed, none skipped. Synthetic PDF pages
  were visually inspected. Real collection/inference pilot, measured coverage and
  production activation remain separate tasks. Today's accepted report is not
  resent or overwritten.
- All six text inboxes now use daily 09:00–21:00 Asia/Bangkok business hours.
  Native updates to inboxes3/6/7/8 were accepted at02:43:38Z with exact GET
  readback and unrelated settings preserved. No out-of-office message was added.
- Archive checkpoint03:02:50Z:699/1095 conversations and9786 messages validated.
  Six timed-out histories have separate manual review receipts; original failed
  calls were preserved, never blindly retried. The remaining396 are incomplete.
- Practical operator guide drafted in `UMI-MAI-CHAT-GUIDE.md`, aligned to the
  six-rule rubric and current private payment-command behavior. Independent review
  and inclusion in the final human-readable handoff remain outstanding.

### Additional exact order identity — 2 October, 03:25 UTC

- Independently reviewed all15 messages of conversation246. Incoming2711 names
  the customer's own order1521 without a hash prefix; later substitution and
  pickup replies corroborate it. The initial reference scanner only recognized
  the outgoing `#1521` form, leaving this identity unresolved in the frozen input.
- Fresh Shopify order/customer, unique Klaviyo profile and contact ownership
  agreed, without a name/handle inference. Native reverse merge retained2146
  with conversation246 and removed empty imported377. The original46-pair plan
  is unchanged; this uses a separate reviewed one-pair plan and unchanged executor.
- Fresh dependency/automation/webhook and prospective commerce checks passed.
  Native POST returned200; subsequent async profile readback verified the exact
  binding, all15 messages, conversation and inbox ownership, no new private/public
  messages, and no events or deliveries. Private receipts:
  `identity-246-consolidation/merge-receipts/2146/`.
- Reconciled identities now48:47 reverse merges plus the earlier exact customer
  link. Current paid customer context does not credit this service conversation
  with acquisition or chat settlement. Its original audit receipt stays unchanged;
  application needs an explicit reviewed identity/commerce amendment.
- Mai guide received an independent domain review: CLEAN. Clarified that a pending
  payment-command cancellation takes effect only when its private result appears.


### Production acceptance — 2 October, 03:47 UTC

- Infrastructure PR114 is merged as `fc4bbc985`. Release23 is deployed and
  accepted: Rails and Sidekiq match the signed application source and image;
  thirteen sibling containers, seven owners, environment and schedules were
  preserved. Four health endpoints returned200. Schema and the pre-existing
  Sidekiq dead set are unchanged. The existing Caddy role reloaded its identical
  configuration without restarting the container. No migrations ran.
- Historical canary36 was applied once at03:36:21Z after an eligible locked
  preview. Event9126 and private note12294 record `qualified` plus
  `intent-ready-to-order`. All ten original messages, contact ownership and open
  status were preserved. Persisted readback found no conversion deliveries,
  public messages, live qualification events or live reminder activity. Original
  cutoff135 and frozen snapshot time remain recorded. Acceptance receipt:
  `canary36-accepted.json` in the private audit evidence directory.
- Bulk preparation must recognize this canary as already applied from its exact
  receipt. It must hold meaningful messages created after the frozen cutoff;
  amendments cannot bypass the native original-as-of guard. Erasure is an early
  branch in both classification and customer-role manifests: permitted IDs and
  hold codes only, never copied decision prose or identity details.
- The weekly-quality collector read383 candidates:21 eligible,362 excluded,
  zero unknown. Full inputs are frozen privately. The first two inference checks
  use the actual Friday model and low effort against complete135/60-message
  histories; inference acceptance and recurring activation are not yet complete.

### Archive reconciliation and weekly calibration — 2 October, 04:38 UTC

- All original inference lanes have finished. The last eleven untouched histories
  completed successfully; timed-out calls retain their original failure receipts
  and separate full-history manual reviews. Final combined coverage is being
  verified against all 1,095 original IDs and 12,175 visible message rows.
- The current native export is accepted at04:28:31Z:1,095 rows, including21
  deletion holds containing IDs and markers only. Rails stores some message
  attributes as a JSON-encoded string; the first bulk exporter did not decode
  that form. Offline erasure checks prevented application. The exporter,
  executor and postcheck now share the verified decoded deletion predicate;
  the old export and its provisional manifest are invalidated.
- The corrected export is `bulk-export-20261002T042446Z/current.json`. The
  exact703-row simple metadata rule and conversation246's independent reply
  metadata amendment have been accepted against this source. Neither approval
  supplies missing classification evidence or authorizes customer-role writes.
- A substantial set of archive judgments cites outgoing operator messages.
  Native historical classification correctly requires public incoming evidence.
  Original audit/coaching results remain immutable; affected classifications
  need a separate narrow review, not automatic removal of invalid citations.
  Histories with no public incoming message remain unclassified/held; writing
  uncertain events and private notes would add no useful customer evidence.
- Weekly quality prompt fixes are merged through Shumabit PR25 (`73bc2c3`).
  Optional additional advice is not a service failure after the actual question
  was answered. Explicit integration-test exchanges, including their greetings,
  are excluded from operator performance. Exact example13 went from an
  unsupported criticism/praise to all criteria not applicable. Existing78
  controls pass without skips. A final fixed21-history cohort under this prompt
  is authorized; runtime installation and real PDF acceptance remain pending.
- The accepted Friday report message22754 is preserved and will not be resent.
  The final archive report is a separate deliverable.

### Full archive acceptance and first batch — 2 October, 04:50 UTC

- Final archive coverage is verified:1,095 unique conversations,12,175 message
  rows,1,077 model receipts and18 independent manual replacements. No missing
  IDs remain. Original failed calls and their unknown usage remain recorded.
- Nine whole test threads are excluded from historical application. An
  independent full33-message review confirms the eight additional test IDs
  2,3,100,101,102,103,107,209 alongside14. Mixed13 remains included.
- The complete preparation reconciles260 eligible,825 held,9 tests and the
  already accepted canary36. A full-history semantic review corrected three
  otherwise citation-valid proposals461/736/772 to engaged: product links,
  basic prices/composition and a vague future visit do not establish qualified
  purchase consultation. Their original outputs remain unchanged.
- All257 other eligible rows passed native read-only preview. First batch
  5/6/56/210/246 applied once and passed persisted verification at04:49:44Z:
  five historical events/private notes, original histories and conversation
  status preserved, zero public messages or conversion deliveries. Remaining
 252 rows are being applied through the same reviewed locked executor.
- Remaining source-eligible classification work uses a separate short judgment
  pass over complete archived public histories plus retained metadata. It
  preserves the live classifier v5 meaning while explicitly using historical
  incoming evidence, not pretending old messages are fresh live events.
  Current customer facts are labeled with their capture time and cannot prove
  a historical purchase or conversation attribution. Original coaching and
  role outputs are never rewritten.
- Proposed correction cohort588 excludes erasure, manual/current classification,
  changed raw history, unreviewed events and material identity/commerce changes.
  Absent/null provider-key representation may normalize only when every
  non-null value and actual contact identifier is unchanged. Each new model
  result is an explicit contextual amendment, replacing hundreds of generic
  metadata waivers. No-incoming153 remain held without pointless status notes.
- Start with a reviewed varied batch of at most five full histories; validate
  exact IDs, incoming citations, complete byte-bounded inputs, source and
  prompt binding. Maximum four concurrent calls, no truncation or blind retries.
  Provider failures remain held; all qualification changes and a fixed domain
  sample receive independent semantic review before native preview/application.

### Production and access checkpoint — 2 October, 08:55 UTC

- The remaining 252 rows and three reviewed engagement corrections were applied
  and independently read back. Together with the first five, this is 260 new
  historical applications, plus the earlier canary: 261 total. Twenty uncertain
  results preserve the existing status; 241 establish a definitive status.
  Original histories and open/resolved state are preserved, with no public
  messages or conversion deliveries. Receipts include
  `historical-260-application-accepted.json`.
- The 588-history correction pilot passed source and independent semantic
  review: personal fit consultation is qualified, collaboration and automated
  verification are not sales, stock questions are engaged, and an unseen shared
  post stays uncertain. The remaining 117 batches are running in four disjoint
  lanes, with no retry of attempted histories. Their results still require
  review and fresh native preview before application.
- All historical role proposals have explicit decisions: 152 supported rows
  represent 147 contact-role groups; 45 proposals are held. Coordinator accepted
  the semantic reconciliation after verifying every source hash. These are
  candidates, not applied customer roles. Finish classification before role
  changes; preserve explicit no and unresolved consignment taxonomy.
- The weekly quality runtime from Shumabit commit `296da54` is installed.
  Its 21-conversation full-history pilot and readable PDF are accepted. The
  previously delivered Friday report is unchanged; the next natural scheduled
  quality report remains to be observed.
- Telegram Shumabit's missing Chatwoot credential was repaired in canonical
  Infisical configuration, reusing administrator user 1/account 1. Ordinary
  skill requests, without bridge ENV overrides, now read conversations, full
  message pages, contacts, inboxes and attributes. No bot restart was needed.
  A separate account-label API HTTP 500 was reproduced and is being repaired.
- Linh's two Meta-reported messaging conversations are not yet matched to
  particular Chatwoot histories. Today's real product inquiry is conversation
  1109; 1110 and 1102 contain story mentions. None has stored ad referral IDs.
  Do not identify the story mentions as campaign leads or use timing alone to
  attribute 1109. Meta Ads Insights and original webhook payloads were not
  independently reconciled in this read-only check.

### Review and operator guide checkpoint — 2 October, 09:25 UTC

- Mai's four-page English guide was visually checked and delivered separately
  to UMI Orders, message22758 at09:19UTC. It covers complete answers, product
  and fit advice, customer/order links, QR payment, classification corrections,
  five-working-minute response target and daily09:00–21:00Bangkok hours.
  The existing Friday report was not resent.
- Telegram Shumabit's skill index and full-history helper are installed from
  reviewed Shumabit PR27. Ordinary access retrieves all318messages in251,
  matching the database. A fresh Polygram agent load sees the skill; existing
  cached prompts were not refreshed, and no active session was interrupted.
- All118classification-correction batches are terminal:578successful model
  decisions and10independently reviewed manual replacements after two timeouts.
  Failed calls remain recorded with unknown accounting. All47model-qualified
  cases and the manual qualified case were independently reviewed, alongside a
  fixed29-history domain sample. Four false qualifications were corrected to
  engaged; two unsupported topic assignments were removed in a successor only.
- The accepted preparation distribution is408not_sales,113engaged,44qualified,
  23uncertain. These are reviewed decisions, not yet applied production counts.
  Fresh persistent application-ledger readback still contains260attempts plus
  the separately accepted canary36; none may be applied again.
- Chatwoot PR73 is merged after its required checks passed. Release24 repairs
  the labels API callback order; its image is being prepared for deployment.

### Bounded application checkpoint — 2 October, 09:50 UTC

- All588successor classifications passed a native read-only preview. The
  reviewed five-case pilot33/52/53/82/284 was applied once and persisted checks
  passed at09:42:34UTC: five historical events/private notes, unchanged original
  history and conversation state, zero public messages or Meta deliveries.
  The remaining583 are authorized through the same serial native writer and
  durable attempt ledger; completion still requires persisted readback.
- A separate42-history identity-aware classification cohort is prepared from
  already accepted customer links and complete unchanged histories. Its first
  five results passed status review: repeat/VIP history in199 stays engaged
  for ordinary location/stock/return-policy questions. Customer payment history
  does not turn a conversation into a paid conversion.
- Topic review introduced a conservative historical criterion refinement:
  pure gift/barter fulfilment does not establish retail intent. The broad
  existing topic definitions did not state this explicitly. Exact208/216
  topic-only corrections are retained separately from original model output;
  live-prompt calibration is a follow-up, not claimed implemented here.
- Eight further identity-linked histories contain only37exact new customer
  summary notes; all original messages are unchanged. Root reviewed their full
  text/metadata and accepted this concrete context amendment. Conversation40
  changed only its projected client label, not open/resolved state. This is not
  a general permission to ignore arbitrary marked private notes.
- Fresh read-only role preflight found30unique bound Klaviyo targets with
  matching identifiers and absent role properties. Three unbound contacts
  have no existing exact profile; one bound case has conflicting ownership.
  Those four remain held. The113contacts without usable provider identifiers
  can retain local roles pending a future verified customer link. No role
  application or provider write has occurred at this checkpoint.

### Persisted classification result — 2 October, 09:52 UTC

All588additional classifications were applied and read back successfully,
including the five-case pilot. Combined with the earlier261, this is849unique
historical decisions. No held execution, public customer message or Meta
conversion delivery occurred in this batch. Original messages, conversation
ownership and open/resolved state are preserved. Receipts are persisted outside
containers before release24 activation:
`classification-correction-preview-stage/apply-pilot5-accepted.json` and
`classification-correction-preview-stage/apply-rest583-accepted.json`.

The remaining50identity/context judgments completed without provider failures.
Every newly qualified result received full-history independent review. Case40
is engaged because it only asks which location stocks sizes for fitting; case300
is qualified because the person confirms the concrete fitting visit after the
store supplies the specific location/item/size availability. A date is not
required, but a vague future wish to visit is insufficient. These successors
still require preparation, native preview and application before being counted.


### Shumabit access and release acceptance — 2 October, 10:11 UTC

Telegram Shumabit has administrator access to account 1 through its ordinary
credential fallback. Profile, conversations, full messages, contacts, inboxes,
attributes and account labels have all returned HTTP 200. The existing skill was
updated; no separate integration or permission system was introduced. Existing
Polygram prompt caches were not refreshed and no bot session was interrupted.

Chatwoot release 24 is deployed at image digest
`sha256:e9060204c5161f2f692aafe40a10b96a16d0c22a1e38f1532c8f31213412d0cc`.
The account-label API correction is merged in PR73; infra PR115 pins the image.
The first attempt stopped at the busy-work guard before mutation. A separately
accepted second attempt replaced only Rails and Sidekiq after queues drained.
Thirteen sibling containers, eight service owners, seven protected configuration
files and the cron remained unchanged. Ordinary Shumabit profile/labels requests
both returned 200. Four HTTP health checks passed; schema and existing dead-job
count were unchanged. No customer messages or conversion events were sent by
deployment. Receipts: `labels-release24-preparation/attempt2/`,
`ordinary-access-accepted.json` and `http-health.json`.

Fresh Meta token inspection at 10:14:16 UTC returned valid system-user and inbox-2
page tokens for app2163627007746338. Both lack `instagram_manage_events`;
`page_events` is present. This verifies the current missing scope, not the
current App Review UI status. No event, permission or advertisement was changed.
Receipt: `labels-release24-preparation/meta-scope-readonly-proof.json`.


### Historical classification application — 2 October, 10:17 UTC

The final 50 identity/context decisions passed fresh native preview on release
24. The five-case pilot and remaining 45 were applied once and passed persisted
readback at 10:16:00 and 10:16:54 UTC. Combined acceptance is 899 unique historical
decisions, with no public messages or Meta conversion deliveries. These decisions
preserve conversation ownership, open/resolved state and original history.
The final cohort contains 31 not-sales, 16 qualified and three engaged outcomes.
Nine test-only threads remain excluded; 187 histories remain held rather than
forcing a classification from missing, deleted or changed evidence.
Receipts: `final50-native-stage/apply-pilot5-accepted.json` and
`final50-native-stage/apply-rest45-accepted.json`.

Ordinary Shumabit also executed `umi:funnel:report` successfully inside the
production Rails container, without sudo, at 10:24 UTC. It returned the native
JSON aggregate for an explicit account/time range. `rake -T umi` successfully
listed the deployed tasks. This verifies native application access separately
from REST credentials; it does not claim that every mutating task was exercised.
Receipt: `shumabit-rake-access-accepted.json`.

Shumabit PR28 adds explicit local Rails/Rake instructions to the existing API
skill. The exact merged skill was installed at 10:27:54 UTC, with its owner/mode
preserved and no restart. It documents task inputs, native container credentials
and the ordinary user's Docker access. Receipt:
`shumabit-rake-skill-install-accepted.json`.

### Shumabit system map and attribution research — 2 October, 10:50 UTC

Shumabit PR29 extends the same API skill with the system map and authoritative
specification/patch paths. Seventeen release-matched paths were checked inside
`/app`; bridge and report specifications that are absent from the installed
workspace use source-repository links. The data contract takes precedence over
the older taxonomy proposal. Shopify payment facts, Klaviyo customer properties,
Chatwoot contact/conversation fields and managed labels have explicit owners.

The ordinary user's native examples now use `docker exec`, correcting PR28's
Compose examples: `/opt/umi` is root-only, although Docker access works without
sudo. Protected host paths require `sudo -n`. Only the reviewed skill file from
merge `2c84d464e40c0ddddb2cda9996bc201b4f720bfa` was installed at 10:50:11 UTC;
its owner/mode were preserved, with no restart. Receipt:
`skill-map-install-accepted.json`.

The website-purchase ad investigation is recorded separately in
[Messages associated with website-purchase ads](UMI-WEBSITE-AD-MESSAGING-INVESTIGATION.md).
The observed two starts comprise one view-attributed and one click-attributed
result. Existing capture covers Meta's documented nested ADS referral regardless
of campaign objective; the exact website messaging add-on and its live payload
are not yet verified. Missing ad metadata is not evidence of organic traffic.
Identifying Linh's individual conversations is left to Shumabit.

### Classification closure and accepted customer-note context

Final classification closure reconciles all 1,095 frozen histories: 899 accepted
applications, 187 held and nine test exclusions. The decisions are 578 not-sales,
208 engaged, 70 qualified and 43 uncertain. An uncertain evaluation preserves
the existing sales status; 899 applications do not mean 899 status changes.
No public customer messages or historical Meta deliveries were added.

All 899 generated private notes were captured with complete message attributes
and independently reviewed against accepted decisions and native customer
context. Original messages, attachments and ownership remain unchanged. The
earlier application receipts did not retain every new note's exact body bytes;
this is a fresh acceptance of current note context, not a claim to have recovered
missing historical body receipts. No current context holds remained.

Closure receipt: `historical-classification-closure-v2.json`, SHA256
`957952141696f8a7d58a47abf5f42ae896ede562d4be0ec8549b262aae544c03`.
Independent context receipt:
`historical-classification-context-independent-accepted.json`.

### Native role application: callback correction

The first local role cohort exposed a defect in the private, one-time audit
executor. Reloading the saved Contact inside the outer transaction cleared
Rails' saved-change metadata before the native after-commit callbacks inspected
it. The role and explicit historical explanation persisted, but one customer's
other open conversation did not receive its projected labels. The same issue
would also suppress profile synchronization for a bound customer.

Verification now reads a separate Contact instance, preserving callback state.
Two native tests with real commits failed against the old expression and passed
after the one-line correction; the 25 existing guard tests also passed, with
67 assertions and no failures or skips. Independent source review accepted
executor SHA256 `598a85becad5a0ef747968f07bb662fe78f8c3ecab93673a1db78b0a79d7fb6e`.
No deployed Chatwoot application change was required.

Readback identified exactly one missing active projection among the 111 local
role applications: contact214, conversation46. Recovery uses the existing native
CustomerProjectionJob only for that contact, with unchanged role facts and
pending revisions, preserved histories and a separate recovery receipt. It does
not repeat role mutations or alter the original attempt ledger. Final persisted
and reminder-consumer acceptance is recorded with the role closure below.

The local cohort is accepted: all 111 contacts passed persisted and asynchronous
projection checks after the single native recovery. The actual reminder consumer
returned zero eligible historical targets and zero planned actions. No Klaviyo
profile was created and this cohort made no provider writes; roles remain local
pending a future verified identity. Receipt:
`historical-role-local111-accepted.json`.

### Native role application: prewrite comparison correction

Fresh profile checks exposed another false hold in the private audit executor:
routine synchronization changed bookkeeping timestamps without changing the
customer facts being approved. The prewrite comparison now ignores exactly
`contact.updated_at` and the `segments.observed_at`, `checked_at` and
`next_sync_at` timestamps inside `contact.additional_attributes.umi_klaviyo_sync`.
The containers, segment membership, identity, role revisions, consent and all
other facts remain part of the comparison. Full snapshots and the provider,
acknowledgement and postwrite checks are unchanged.

The actual held-contact fixture failed before the correction and passed after
it. Independent review accepted 26 tests, 76 assertions and zero failures,
errors or skips. Receipt: `historical-role-bookkeeping-correction-receipt.json`;
executor SHA256
`b821791e1826057cfdaf1a6ff36d2a96e54a6b42620726df05c907f544fc785d`.
This changes the one-time executor only, not the deployed application.

### Native role application: asynchronous readback correction

After all 28 remaining bound contacts committed, readback found a separate
verification mismatch on seven contacts. The native SegmentRefreshJob had
republished identical segment membership with a later `segments.observed_at`.
The other 21 contacts matched without this adjustment. Provider role, identity
and consent checks had passed before the local acknowledgement comparison.

The verifier now accepts only a valid, forward-or-equal observation timestamp
when that field exists in both segment snapshots. It still compares all other
segment fields and customer facts exactly. The real contact207 fixture failed
against the previous verifier and passed after the correction; independent
review accepted 28 tests, 92 assertions and zero failures, errors or skips.
The combined reviewed executor SHA256 is
`ddee6987912b661cebf531aaded4b8dd1f90e248db30ea87d271b494662b6175`.
Verification is repeated read-only; no role is reapplied to these contacts.

### Final role application and historical reminder boundary

All 28 bound contacts passed persisted, provider, consent and asynchronous
projection verification with the corrected verifier. Together with the earlier
bound canary and the accepted successor below, 30 contacts are verified in
existing Klaviyo profiles. No new profile was created.

Two separately reviewed successor attempts completed the original no-write
cases: contact195 had been held before mutation, and contact2361's original
transaction had rolled back completely. Each successor bound the retained
original attempt and accepted zero-write evidence to a fresh snapshot. The
original ledgers remain unchanged; each successor has its own exclusive attempt
file. Contact195 is provider-verified; contact2361 remains local pending identity.
There was no repeat application to any previously committed contact.

The approved 147-contact application cohort therefore closes with 142 applied:
112 local/provider-pending and 30 provider-verified. Five remain held. The final
membership check finds deleted history for contact239, so its role row retains
only the identifier/reason and does not claim current conversation membership.
The other four holds are three absent existing exact profiles and one ownership
ambiguity. Separately, 45 contact-role proposal groups were never semantically
approved; they are not part of this 147-contact application cohort.

The actual reminder consumer was read at 12:31:58 UTC. None of the 158 historical
conversation targets appeared in its eligible queue or planned actions. The
global queue contained seven unrelated targets; this is not a claim that the
whole operational queue was empty. No message was sent by this check.

Final receipt: `historical-role-application-final.json`, SHA256
`bf77701564be8d490582a900d08f773f096d8167386df2fad855215de6ba2d7b`.
It records 140 influencer and two wholesale applications, 145 native private
notes/projections and 146 verified current contact memberships. Source bindings
are retained separately in `historical-role-final-execution-source-bindings.json`,
SHA256 `968c2ce80602fa25e27ccb11f32c74ce637aba58ec29d2233050b311d2cafa20`.

### Final audit delivery — 2 October, 12:42 UTC

The six-page archive PDF was rendered and all pages visually checked. Its
figures, examples and remaining limitations passed independent factual review.
The current CSV contains 1,095 unique conversation rows with classification,
customer-role application, evidence/note references, provider outcome and
projection context. Every row explicitly disables automatic execution. Deleted
history remains minimal; blank role cells do not mean a negative role, and the
45 semantically unapproved proposal groups are not represented as applied roles.

Both files were sent once through Shumabit's existing Telegram helper. The
returned chat and topic matched UMI Orders; receipts were persisted and copied
locally. The PDF's short Russian caption gives the main results and coaching
priorities, with the detailed report attached. Delivery acceptance:

- PDF: message22759 at 12:42:31 UTC; SHA256
  `f72c61bb6648aa3e1a6b1f1580ec5af07d1db74ee49900b5d021afc5cfd00cb3`;
  receipt `archive-pdf-delivery-receipt.json`.
- CSV: message22760 at 12:42:45 UTC; SHA256
  `ca8201d01182c0f5b47e251f66e790fed4dfb764d59cb15f787d7e3ab2bdc007`;
  receipt `review-register-delivery-receipt.json`.

The earlier scheduled report and Mai guide were not resent. The corrected local
guide and the archive report clarify the influencer evidence rule. No public
customer message, fabricated purchase or historical Meta replay was part of this
delivery. The next natural quality-report/reminder observations, advertising
comment coverage, deferred command feedback and Meta permission/optimization
acceptance remain the explicit follow-ups above.
