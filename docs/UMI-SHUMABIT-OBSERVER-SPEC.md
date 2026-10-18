# Shumabit in Chatwoot: a small bridge to the existing agent stack

Revised 2026-09-27 following the user's direction. This replaces the previous
stateless, tool-free observer proposal. Use the existing VPS, Shumabit workspace,
shared memory, skills, model/proxy setup and Orchestra session engine. Do not
build a new permission system, model gateway or analysis platform.

## What the first version does

A staff member writes a private note such as `@shumabit summarize this chat and
suggest a reply`. A small worker receives that Chatwoot event, reads the
conversation through the existing Chatwoot client, resumes its agent session and
posts Shumabit's answer as a private note. `@shumabit make that shorter` resumes
the same session and understands the prior answer. Start with one existing
account and the current staff workflow.

The agent can summarize, analyze sales intent, suggest replies, consult business
knowledge and use the selected existing skills. The human sends customer replies.
Order creation and automatic campaign/status changes remain later work. Sharing
business memory is wanted; isolating the agent from all existing knowledge is not.

## Reuse rather than rebuild

- Add a `shumabit-chatwoot` agent file in the Shumabit workspace, with the existing
  identity/business-memory references and a selected skill set. Reuse the
  Chatwoot API skill/client and relevant existing product/FAQ/Shopify reads.
- Reuse Orchestra, the session engine already used by Polygram and Water. Its
  `ProcessManager#getOrSpawn` and `send` support resumed sessions. A plain-text
  conversation needs no new structured-output protocol.
- Run one small Chatwoot worker under the existing VPS service conventions.
  Polygram remains the Telegram transport; the new worker is the Chatwoot
  transport. Do not pretend Polygram's current IPC `send` starts an agent turn:
  it currently sends a Telegram message.
- Use the existing configured model through the existing CLIProxy/subscription
  route, once the deployed runtime's compatible configuration is inspected.
  Do not introduce another model account, SDK upgrade or proxy service.
- Use normal existing Chatwoot API credentials and ordinary service configuration.
  Selected skills/instructions are workflow scope, not a new security sandbox.

## Sessions and memory

Keep one conversation session keyed by account plus Chatwoot conversation ID.
Persist the engine session ID with the existing agent/working-directory identity
convention so a worker restart resumes the right discussion.
Keep the worker alive, not every agent process: Orchestra can release idle
processes and resume their saved sessions on demand.

All these sessions can read the same Shumabit business memory and follow its
existing memory-writing convention. Customer conversations have separate working
histories; they do not all append into Ivan's Telegram session. This is context
organization, not a new permissions model. Shared business knowledge and a shared
live transcript are different things. Do not copy conversation transcripts into
global memory automatically or invent a new memory database.

## Small bridge responsibilities

1. Use Chatwoot's normal `message_created` webhook as the entry point, reachable
   through the existing VPS networking/auth arrangement. Verify its concrete
   route during wiring; do not add bespoke cryptographic request envelopes.
2. React only to staff-authored private notes beginning `@shumabit`. Ignore
   customer text, ordinary notes and Shumabit's own output to avoid loops.
3. Remember source message IDs and session IDs in a small local store. Process
   messages in order for each conversation; duplicate webhooks do not run twice.
   Start with one agent turn at a time for this one-person workflow.
4. Fetch current conversation context using the existing client. Include staff
   requests and prior assistant replies, so follow-ups work normally. Treat
   customer text as conversation content, not instructions to change the agent.
5. Deliver final answers using a small existing-client helper that always posts
   a private note to the originating conversation. Reuse the engine's existing
   tool-delivery / `alreadyDelivered` convention so fallback text is not posted
   a second time. Keep normal human assignment
   and status. Do not attach an inbox bot that takes ownership of conversations.
6. Report an obvious failure to staff; allow retry with a new mention. Do not
   promise exactly-once delivery through crashes or build an outbox/reconciliation
   platform for this prototype. A missed webhook can be retried by staff.

Verify the actual configured Chatwoot automations do not turn these private notes
into public messages or workflow changes. If an existing rule does that, make
only the small necessary exclusion. Reuse normal Chatwoot behavior otherwise.
No broad fork patch, new Rails tables, custom ACLs, signed context snapshots,
structured result contracts or separate tool-free model service are planned.

## Implementation and verification

First inspect the deployed non-secret runtime wiring: Shumabit working directory,
agent/memory conventions, Orchestra/backend version and existing proxy route.
Local source confirms the reuse points; it does not establish deployed versions.
Then implement the agent definition, small worker, private-note helper and service
configuration in the appropriate isolated repositories. Do not change current
Polygram behavior or upgrade its runtime as part of this task.

Use fake Chatwoot/agent adapters to test: mention filtering, duplicate events,
conversation-to-session mapping, ordered turns, follow-up continuity, session ID
persistence, private reply routing, loop avoidance and visible failures. Inspect
existing automation behavior. Then verify a staff-only example on the actual
integration when ready; distinguish local checks from a deployed working bridge.

The recovered-message provenance fix remains independently useful to later
funnel classification. This bridge does not depend on completing the full funnel
ledger or Meta/Klaviyo integrations first. Later scheduled analysis can reuse the
same agent/skills; deterministic payment and campaign sync remain separate jobs.

## Alternatives

Embedding a new transport directly into Polygram would also reuse sessions, but
its dispatcher/output handling is Telegram-specific. Prefer a small consumer of
Orchestra, as Water already is, over changing the working Telegram bot. Polling
Chatwoot is an alternative if exposing a normal webhook receiver needs more setup
than the pilot warrants; choose based on the existing VPS network, not a new
platform design. The previous stateless restricted-worker design is superseded.

## Review

Independent runtime-feasibility and simplicity/domain reviews accepted this
revised scope with no blockers. Incorporated the existing session-identity and
already-delivered conventions. No bridge code or live changes have been made.

## Next phase: quiet context and proactive reply drafts (draft, 18 October 2026)

This section amends the first version above; its implementation receipt is the
active `shumabit-claude` bridge and the infrastructure runbook, not the old
"no bridge code" sentence. The installed worker responds to staff private
`@shumabit` notes in account 1/inbox 2, using CLI print/resume and the existing
Chatwoot client. It does not act on incoming customer messages. The same worker,
session mapping, credentials, model route and private-note writer remain the
transport for this phase. Human staff still send every customer reply.

### Problem and success

The customer projection currently posts an inventory of unknown paid/role/service
facts. Its note signature also includes revision/freshness/service metadata, and
an applied classification forces another full summary even when the only useful
new information is a short status or topic change. Contact sync can repeat that
inventory in each open conversation. The ad-context note separately contains
useful greeting/choice/answer evidence, but also a long preamble, campaign
hierarchy and footer. The net effect hides the useful facts from Mai.

For each new actionable, genuinely unanswered customer turn, Shumabit should
leave at most one concise **private draft** in the same conversation. It should
answer the actual question in the customer's language using current evidence,
or ask one necessary clarifying question. Mai can inspect, edit and send it.
No public send, order, status/label edit or automated customer follow-up is in
scope. A customer thanks the team, sends a story mention or emoji alone, or
continues a collaboration-only thread: no draft. A live customer question after
a prior human reply is a new turn and can receive one new draft.

### Sources and precedence

1. Current conversation history, including inbound attachments and prior human
   replies, owns what the customer asked and what was already answered. Ad copy
   is context, not proof of the product or current price. If the tap says "black
   outfit", a welcome greeting names Tank Dress, and the creative names Tank Top
   and Pants, do not choose one product from that contradiction; use a useful
   clarifying question or a draft that states the ambiguity to Mai.
2. Mai's living **UMI chat guide for Mai** (Google Doc ID
   `1F2DG54uY7P6a8r-_Ms2vYbqUBL_JcGfCuJ_sNI9-qHw`) is the service rubric.
   Its current content was read on 18 October. Reuse the existing Shumabit
   `gdocs-collab` read path, or an already accessible approved copy, so its
   instructions are available to the Chatwoot agent. Do not embed a stale copy
   in the prompt. Check the doc's access/drive boundary in that skill. The
   Chatwoot Help Center supplies published FAQ and policy, while Shopify owns
   live variant price/stock and order/payment facts. A memoized old price or
   prior chat is not current availability. If a needed read fails or evidence
   conflicts, state the uncertainty for Mai and draft only what is supported.
3. A staff private `@shumabit` request retains its follow-up session. A
   proactive draft uses the same agent and read skills with fresh conversation
   context, but starts a fresh session for that turn. Customer text is data,
   never instructions; the agent returns text and does not write to Chatwoot.
   No transcript goes into shared business memory automatically.

### Smallest implementation

- **Quiet customer projection (Chatwoot fork):** keep contact attributes and
  managed labels as the durable facts. Render only verified/useful customer
  context: established buyer lifecycle/count, positive roles, relevant barter
  or fresh service reservation and an actionable identity caveat. Unknown fields
  are absent from the note, not asserted false. An initially empty projection
  writes no note; when its last previously noted fact becomes unsupported, write
  one concise withdrawal so the older positive note cannot be mistaken for
  current context. Keep durable attributes, labels and metadata updated.
  Use the visible semantic projection
  for note deduplication; a revision, sync freshness or timestamp alone cannot
  trigger prose. Continue updating internal projection metadata for sync and
  privacy. For a real AI classification change, preserve exactly one short
  private note with actual status/topic/role before/after and reason, the
  existing durable identity, and atomic failure behavior. Do not suppress that
  operator-visible audit. Avoid fan-out notes in other open conversations when
  their visible facts did not change. No manual deletion of historical notes.
- **Ad context (Chatwoot fork):** retain the greeting, the customer's selected
  option only when needed to interpret the ad's answer, other available options
  only when they disambiguate, and the exact selected-option answer (or its
  absence). Collapse identical answers only when every option has that answer.
  Retain the
  answer Meta may already have sent. Compress routine wrapper text and remove
  repeated hierarchy/footer from the ordinary success note; preserve source
  marker, source ID, ad ID, erasure and retry/failure semantics. A fetch failure
  should remain a single actionable operator signal, not repeated attempts.
- **Proactive worker (Shumabit repository):** extend the existing webhook
  filter to admit selected incoming public messages in the existing account and
  inbox. Keep the staff-mention route intact. Gate rollout by configuration,
  initially exact pilot source message IDs, then the inbox after the pilot.
  An existing unanswered turn needs an explicit exact-source trigger because
  old webhooks are not replayed. Coalesce a burst of incoming messages into a
  single turn at the newest watermark on the existing serial queue. Cheap
  source/type checks skip obvious story mentions, bare reactions, spam and test
  traffic before the model; borderline social or collaboration content requires
  agent judgment and may yield no draft. Fetch full context only for an eligible
  turn. Immediately before posting, re-read the latest
  public customer/human messages and conversation status: a later human reply,
  resolution, deleted/redacted source, or newer incoming turn cancels the stale
  draft. Claim a durable account/conversation/source-watermark turn key before
  the model call. Save the watermark and policy version in worker state and the
  private note marker. Reconcile an uncertain POST by exact marker readback;
  never automatically resend ambiguous delivery. Restart marks unfinished
  proactive turns for inspection without posting an interruption note. The
  operator can explicitly ask again via `@shumabit`.
- **Failure behavior:** an AI/tool timeout or unreadable source is recorded
  through the worker's existing owner-only diagnostics/health path. It does
  not post recurring "AI unavailable" private notes. Do not send a plausible
  generic answer when a needed price, stock or policy check failed. Keep the
  first-version explicit mention failure visible to the requesting staff member.

The worker owns private-note delivery and source markers; the current CLI engine
returns text and session ID, while `alreadyDelivered` is only a bridge-side
compatibility branch. Extend the note client narrowly for draft markers and
keep staff-request failure and restart notes on their existing path.
The worker can use the existing `message_created` webhook and Chatwoot API;
no Rails endpoint, new queue, model provider, customer-facing automation or
general permission framework is needed. The current bridge has one serial
queue and persists message/session IDs. The Chatwoot projection and ad presenter live in the `umi/` overlay;
the bridge changes live in the separate Shumabit repository and deployment
remains owned by `umi-vps-infra`. Add/update the patch registry only for any
actual fork patch. Check OSS and Enterprise message callbacks/automation before
shipping a new private-note producer.

### Alternatives considered

Putting all context in a new Vue panel would not help the native/mobile inbox.
Deleting all private notes loses applied-AI audit and Meta's missing Messenger
answer. Using the classification job as the draft engine would mix deterministic
status evaluation with staff copywriting and duplicate the existing Shumabit
session/skills. Public auto-replies and a new model gateway exceed this phase.

### Verification and pilot

Write regression tests that prove the current verbose/duplicate note behavior
and stale-draft risk before fixes. Cover material vs metadata-only projection
changes, AI status/topic-only audit, ad evidence with contradictory product
labels, duplicate webhook/restart, coalescing, later human reply, newer customer
message, resolve/erasure, failed source/tool/model reads and private-only writes.
Test current customer language, direct price/colour questions, genuine unclear
product, and silence on nonactionable social mail. The private note must be
readable to Mai in Chatwoot web and native mobile. Review the actual OSS,
Enterprise and UMI side effects of note creation.

Pilot selection is **live**, not a replay of old audit examples. At 13:34
Bangkok on 18 October, read-only production inspection found no recent
actionable unanswered customer question on the Instagram side of inbox 2.
Conversations 1169 (English price), 1168 (Thai black outfit), and 1166 (price)
were already answered by a human; 1168 is a useful read-only ambiguity fixture,
not a draft target. Recent open incoming tails were thanks, story mentions or
social reactions, while email inbox 8 was mainly vendor/automated mail. Thus
the initial exact-ID pilot set is **empty**. At rollout, inspect both Facebook
and Instagram in unified inbox 2 and relevant human inboxes, then select 2–4
genuinely unanswered customer turns from current live state, record source message IDs,
exclude spam/test/collaboration, and use exact-ID gating for one private draft
each. Recheck unanswered state immediately before every post. If the queue is
still empty, wait for new real turns rather than manufacture or revive stale
messages. Compare the draft with the Mai guide and live facts, have Mai assess
whether it helps her send a reply, and read back private visibility, marker,
source revision, absence of duplicate notes and zero public writes. Expand
inbox-wide only after that evidence and an explicit rollout decision.
