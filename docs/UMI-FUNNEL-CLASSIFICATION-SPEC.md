# Automatic conversation classification

28 September 2026. Focused implementation specification for the approved funnel
plan U3. The user selected automatic status updates after quality evaluation,
with human correction. The design passed independent review; implementation is
under code review. Production remains disabled until the separate deployment
and quality checks below are completed.

29 September addendum: [conversation lifecycle and integration decisions](UMI-CONVERSATION-LIFECYCLE-DECISIONS.md) records the accepted conversation-boundary policy, stage-2 historical classification, and required private change notes. These additions identify pending implementation; production is now deployed in shadow, superseding the original pre-deployment status above.

The consolidated [CRM data contract](UMI-CRM-DATA-CONTRACT.md) now specifies the proposed stage-one field types, topic allowlist extension, correction behavior, customer visibility, synchronization and notes. It is not an implementation receipt. The complete [stage-one plan](UMI-FUNNEL-STAGE-ONE-SPEC.md) supersedes the old bounded-message context below: review and production must share full available current-conversation text with explicit oversized-input uncertainty, while retaining fresh-evidence requirements for conversion events.

## Purpose and authority

Classify incoming sales conversations so the operator does not have to evaluate
every thread manually. Keep Shopify as the only writer of order/payment facts,
Klaviyo as the customer-lifecycle owner, and the existing Shumabit private-note
assistant available for summaries and suggested replies.

The authoritative business sources are:

- [Original funnel plan](/Users/ivanshumkov/Projects/shumkov/chatwoot.crm/docs/plans/2026-09-27-1325-feat-funnel-messaging-integration-plan.md),
  “Qualification grounded in Linh's workflow,” “Conversation vocabulary and
  taxonomy,” R3–R5, KTD8/KTD9 and U3. Its source reconciliation records the
  authenticated 27 September read of Linh's documents and the Miro frame.
- [Linh's workflow](https://docs.google.com/document/d/1B9-mRJwcMriPouySXRb4jIAJpZD3h2qOrSonKYjC2LE/edit),
  as reconciled by that plan: meaningful product consultation or a concrete
  buying step, not a mechanical count of messages.
- [Label taxonomy](UMI-LABEL-TAXONOMY-SPEC.md): labels stay flat and topics can
  overlap. The newer funnel plan supersedes the older proposal to remove all
  topic/qualification labels.
- [Pilot contract](UMI-FUNNEL-PILOT-CONTRACT.md): human classification was the
  earlier launch shortcut. This unit supplies the separately deferred automatic
  classification; it does not activate offers or customer messaging.

Qualify a concrete request to reserve identified items, arrange fitting/pickup,
obtain an order/payment link, or provide details to progress that purchase.
Also qualify substantive reciprocal consultation about size, fit, colour,
material, styling or delivery that demonstrates purchase consideration.
A single clear buying step can suffice. Greetings, a phone number alone, raw
message count, support-only requests and profile appearance cannot qualify.
A price-only question is engagement unless context establishes more.

## Chosen approach and alternatives

Use the existing RubyLLM 1.15.0 dependency for one stateless, tool-free structured
call through the existing CLIProxy endpoint, key and configured Shumabit model.
Classification needs the supplied conversation evidence and business rule;
it does not need agent tools, persistent assistant sessions or global memory.

Existing patterns: request-local configuration in `lib/llm/config.rb`;
schema-constrained calls in
`enterprise/app/services/captain/llm/assistant_action_classifier_service.rb`.
Keep new application code in the UMI overlay. Reuse RubyLLM without requiring
Captain assistants or changing global Captain configuration. No dependency
upgrade belongs to this unit.

Alternatives considered:

- Extend Shumabit's CLI worker with a classification endpoint. Its transport is
  proven, but adding another request/response contract and subprocess operation
  is more work for a judgment that needs no tools or session. Retain it as a
  fallback only if the direct proxy compatibility prerequisite fails.
- Use keyword rules or native Chatwoot automation. These cannot reliably judge
  reciprocal Thai/English buying intent; native rules also cannot directly
  write the protected custom attribute. Keep code for routing and transitions,
  and the model for message meaning.
- Build another agent/service or workflow platform. Unnecessary: the evidence,
  scheduler, transition writer and provider exports already exist.

### Provider compatibility prerequisite

Before implementing around an assumed provider contract, verify the installed
RubyLLM version and a bounded synthetic, non-customer structured request through
the existing proxy/model from the intended worker network. Check endpoint,
authentication, model name, schema response shape, timeout/error behavior and
whether the proxy accepts the request parameters actually emitted by 1.15.0.
Use request-local configuration, no tools, no streaming, a bounded response and
an explicit request deadline. Do not silently fall back to another provider,
model, paid key or unstructured response.

[Custom endpoints](https://rubyllm.com/custom-endpoints/) and
[structured output](https://rubyllm.com/structured-output/) document the library
capabilities; current public pages describe a newer release, so installed
1.15.0 source and the actual request are the implementation authority.
`assume_model_exists` bypasses a registry lookup, not compatibility testing.
This probe is model inference and must be reported as such; the compatibility
receipt is recorded at the end of this document. Infra supplies the existing key and private network route.
The Shumabit private worker, its credentials and session mappings are unchanged.

## Input and structured result

Start with configured account 1 / FB–IG inbox 2. Both Messenger and Instagram
can be classified; existing destination rules continue to exclude Instagram
Meta exports. Do not automatically widen to other inboxes.

Use durable `message_received` occurrences with live provenance, known source
time, and no redaction. Private notes, outgoing messages, recovered/imported
messages and pre-boundary history cannot trigger or serve as positive sales
evidence. Outgoing public staff replies may supply context for reciprocal
consultation. Do not fetch attachments or invoke tools to interpret them;
insufficient text/attachment context produces uncertainty.

For each conversation, select the latest eligible incoming message as the
input watermark. Supply at most the latest 100 public, non-recovered messages
within the collection boundary, excluding soft-deleted records, ordered by source time and ID, bounded to
30,000 characters. Allocate text budget from newest to oldest, then present
chronologically. If content must be truncated, identify truncation explicitly;
the model must abstain where missing context could change the result.
Message bodies are quoted data, never classifier instructions. Include current
sales status and the latest human correction as controlling context.

Return one object with no additional keys:

| Field | Contract |
|---|---|
| `status` | `engaged`, `qualified`, `not_sales`, or `uncertain` |
| `topics` | Unique values from the allowlist below |
| `reason` | Brief explanation, 1–1000 characters; do not copy unnecessary personal details |
| `evidence_message_ids` | IDs of supplied live incoming messages supporting the decision |

Require valid incoming evidence for every applied decision. A new automatic
qualification must cite only qualifying incoming evidence newer than both the latest
human-correction watermark and the automatic-activation boundary. An unrelated
new greeting does not unlock an earlier rejected or shadow buying request;
older messages are context only for this positive transition. Reject malformed
JSON, unknown fields/statuses/topics, foreign/private/recovered evidence IDs,
empty evidence, or a decision unsupported by the supplied window. A valid
schema alone does not prove semantic correctness; the evaluation gate does.
Store uncertainty as a classifier result, not another sales-status enum value.

## Exact projection rules

### Sales status

| Existing status | Automatic result | Projection |
|---|---|---|
| Absent / `unevaluated`, `engaged`, `not_sales`, or `inactive` | Clear `engaged`, `qualified`, or `not_sales` with new eligible evidence | Apply through the shared transition service |
| Any | `uncertain`, invalid result or provider failure | Leave status unchanged; retain a visible evaluation outcome |
| `qualified` | Later support, uncertainty, silence or lower sales intent | Preserve `qualified`; applicable topics may be added |
| `order_placed` or `purchased` | Any model result | Preserve Shopify's status; applicable topics may be added |

The model never emits `order_placed`, `purchased` or `inactive`.
Inactivity scheduling and promotional follow-up are separate work. A status
change never closes a conversation, changes assignment, sends a customer
message or subscribes anyone.

An automatic qualification uses the existing unique conversation qualification
occurrence and destination outbox. Repeated classification cannot create a
second positive occurrence. Extend the transition service with explicit
classifier provenance/model-version metadata; do not impersonate a human user
or bypass its evidence validation.

An existing qualification remains preserved even if an operator later sets
engaged or inactive. Only an explicit human not_sales/unevaluated correction
revokes that preservation.

Only an explicit human correction may apply the existing qualification-reversal
behavior. The classifier must not send a later support-only assessment through
the current `not_sales` correction branch, which excludes pending qualification
deliveries. Historical qualification, order/payment occurrences and existing
terminal delivery states remain intact.

### Topics

Initial allowlist reuses the established label names:

- `intent-size-advice`: sizing, measurements or fit consultation.
- `intent-color-advice`: colour choice or matching.
- `intent-product-details`: material, construction, care or other product detail.
- `intent-ready-to-order`: an explicit reservation, fitting/pickup booking or
  order/payment-link step.
- `support-order-tracking`: an existing order's delivery/progress enquiry.
- `support-exchange`: exchange request.
- `support-refund`: return/refund request.
- `support-complaint`: an explicit service/product complaint.
- `support-after-sales`: another identifiable post-purchase service request.

These labels mean topics observed in this conversation, not mutually exclusive
current stages or payment facts. Add supported labels; do not automatically
remove previously observed topics or unrelated/manual labels. The operator may
remove an incorrect topic. Do not reapply it from the same already-evaluated
input; genuinely new incoming evidence may justify it again.

Provision missing allowlisted labels idempotently in the configured account.
No wholesale taxonomy cleanup or new nested labels. Do not infer `spam`,
`recruitment`, `source-paid-ads`, waiting-for-payment or waiting-for-reply
labels through this classifier. Non-sales reasons can identify collaboration or
recruitment without introducing another label dimension. Existing status
projection continues to own `lead-qualified` / `lead-converted`.

### Human correction

Keep the existing Sales status control and manual transition validation.
A correction wins for the current evidence window and invalidates any in-flight
model result based on an earlier correction state. Record the latest eligible
incoming watermark with the manual change so repeated scheduling cannot undo
it using the same customer input. Genuinely new customer messages may be
evaluated again, with that correction included in context.

This is the proposed simple correction policy for alignment: correction is not
a permanent “disable AI for this conversation” switch. No new permissions or
override-management UI is introduced. Shopify's existing protection of
`order_placed` / `purchased` remains unchanged.

## Scheduling, durability and failures

Use the existing five-minute reconciliation job and low-priority Sidekiq queue.
Consider only conversations with a newer eligible incoming watermark than their
last terminal evaluation/manual correction. A short quiet interval of 30 seconds
before selection coalesces immediate message bursts. Enqueue at most 100
conversations per pass; no new polling service.

Add a non-exporting `classification_evaluated` event type and `classifier`
provenance to the existing event model. Its unique occurrence key includes
conversation, input watermark and classifier policy version. Record selected
evidence IDs, mode, model/version, decision and outcome
(`shadow`, `applied`, `uncertain`, `stale`, `manual_override`, or
`failed`). Failures retain sanitized error class, not provider bodies or
conversation text in logs. Store no duplicate raw transcript.

No database lock is held during inference. Under the existing contact then
conversation lock order, recheck account/mode, input watermark, current human
correction, source ownership and erasure after inference. Persist the unique
evaluation and any permitted transition/topic projection atomically. A
duplicate job may perform another inference, but only the winning persisted
result may apply once; a losing response must not be applied independently.

A newer incoming message makes the old response stale; the next normal pass
evaluates the new watermark. A failed/malformed response does not loop on the
same input automatically; the operator can classify manually, and a new
incoming message supplies a new evaluation opportunity. Worker loss before a
result commits can cause a repeated inference, but cannot duplicate the durable
qualification occurrence or provider send claim.

Existing privacy redaction must clear classifier reasons and evidence along
with other conversation events. A redacted/deleted source cannot receive a
post-inference result or projection. Do not add classifier data to shared
Shumabit memory.

## Modes and quality acceptance

One independent `off | shadow | auto` mode, default `off`, scoped to the
configured accounts/inboxes:

- `off`: no calls or classifier writes; manual status and commerce processing
  continue.
- `shadow`: persist judgments and evaluation outcomes only. No status/topic
  projection, qualification occurrence or provider event from model judgments.
- `auto`: apply validated new judgments under the rules above.

Switching shadow to auto or changing the policy version does not replay old
judgments as live conversions. Automatic application requires new incoming
evidence after the selected automatic-activation boundary. Existing collection
and provider-export boundaries do not move.

### Required quality evidence

On 29 September the user selected assisted review: show the AI status/topics,
reason and supporting messages first; the operator corrects only mistakes and
explains why. This supersedes the initial blinded-label/90%-agreement proposal.
It is qualitative acceptance, not an unbiased accuracy measurement or training.

1. Repair the approximately 40-example packet with sufficient available history
   and known customer facts; preserve existing corrections. Cover Thai/English,
   clear buying steps, consultation, greetings/price-only and phone-only messages,
   existing-buyer support/refunds, Instagram mentions, collaboration/recruitment,
   ambiguity, negation and injected instructions. Declare missing attachments
   and authored examples separately; reconcile review/production input semantics.
2. Any operator comment disputes the complete proposal, including topic/reason
   errors without a status change. Only explicit final confirmation accepts
   unchanged proposals; prefilled fields and autosaved drafts are not approval.
3. Resolve reviewed errors and require zero false qualifications on designated
   hard-negative cases. Report uncertainty, topic errors and coverage separately;
   do not present assisted confirmations as blinded 90% accuracy.
4. Require zero evidence-ownership, payment-status, human-correction or
   customer-send violations in deterministic checks. Model changes do not relax
   deterministic transition and provider-eligibility rules.
5. Record operator acceptance, exact model/effort (unknown when unobserved),
   policy, input version and covered cases before auto activation. Reevaluate
   affected cases after a material model/prompt/context change.

If real examples or Sales review are unavailable, ship shadow mode and report
the pending gate plainly. Do not substitute test-suite success for approval.
After activation, use the existing bounded report/private operator review to
sample classifications and corrections; no new dashboard or notification bot.

### Historical examples and live eligibility

The original 40 examples also contain conversations from before event
collection. Export them with `REVIEW_MODE=retrospective_semantic_qa` through
`umi:funnel:classification:export`. This mode evaluates the meaning of retained
historical messages in a simulated evidence window; it does not create events,
change CRM records or authorize any provider export. The default `live_context`
mode continues to use the unmodified production context.

Retrospective evidence uses the existing eligible incoming IDs, excludes
recovered, deleted and private messages, and respects both ID and time fences
from persisted operator corrections. Original sample IDs, prior proposals and
human expectations remain separate from the new model response. The packet
retains `original_export_fresh_evidence_ids` as provenance; those IDs alone are
not proof of complete production auto eligibility. Topic correction fences
remain subject to the separate production application check.

The review page prominently identifies retrospective mode. Acceptance records
must identify this exact packet and mode as well as the unchanged model/prompt
configuration. Historical semantic quality and fresh live conversion eligibility
are separate checks; passing one does not establish the other.

## Files and verification

Expected narrow application changes:

- New `umi/app/services/funnel/conversation_classifier.rb` plus schema/prompt,
  and `umi/app/jobs/funnel/classification_job.rb`.
- Extend `umi/app/jobs/funnel/reconcile_job.rb`,
  `umi/app/services/funnel/configuration.rb`,
  `umi/app/models/conversation_event.rb` and
  `umi/app/services/funnel/conversation_transition.rb`.
- Extend manual correction evidence in
  `umi/app/controllers/funnel/operator_status.rb` and reuse
  `umi/app/models/funnel/conversation_projection.rb`.
- Extend the existing bounded funnel report/rake output only enough to expose
  evaluation outcomes, uncertainty and failures for operator review; no new UI.
- Focused service/job/model/privacy/operator specs and sanitized evaluation
  fixtures under `spec/fixtures/umi/funnel/`.
- Registry/status documentation and a separately reviewed infra configuration
  change for the existing proxy key/route and classifier mode.

Check OSS/enterprise/UMI extension behavior before edits. No Shumabit bridge
change, library upgrade, lifecycle segment edit, public reply or new credential.

Verification must include: duplicate jobs; mode disabled during inference;
shadow creates no exports; invalid/foreign evidence; recovered/private/outgoing
exclusion; Thai/English paraphrases and negation; truncation and attachments;
human correction during inference; rejected/pre-auto buying evidence followed
by a fresh greeting creates no qualification/export; new input during inference; preservation of
qualified/payment status on later support; additive topic preservation; contact
erasure; malformed provider JSON; provider timeout; one durable qualification
and one destination delivery despite repeat assessments.

Run a synthetic proxy-compatibility check separately from deterministic tests.
Run Sales-reviewed shadow evaluation separately from both. Deployment acceptance
must prove configured mode, inference/result persistence, a permitted automatic
status/topic change, human correction, and no customer-message creation. Any
production qualified outcome must be genuine because existing exporters may
dispatch it; synthetic examples stay in the evaluation path.

## Boundary with customer lifecycle work

This unit changes conversation meaning, not the customer's funnel stage.
The original plan's “Funnel, evidence and actions” table and U4 remain the source
for the next unit: Stranger/Familiar primarily belong to audience evidence,
Chooser requires observed browsing, Seeker requires cart/checkout, Client means
exactly one qualifying paid purchase, and Repeat means at least two.
Conversation qualification is additional intent evidence, not automatically
Seeker. The proposed 30-day targeting window and historical paid coverage must
be settled in that separate lifecycle specification.

## Compatibility and review checkpoint

Two independent reviews accepted the design after requiring fresh qualifying
support beyond both the latest correction and auto-activation boundaries.
On 28 September a temporary container using the production release 12 image,
RubyLLM 1.15.0 and existing private CLIProxy network/key completed one synthetic
structured request to the configured `gpt-6-sol` model. It returned the expected
Hash (`engaged`, evidence ID 101), with 97 input and 37 output tokens. No customer
text, customer message, classification record or profile was sent or written.
The container was removed after the probe. This verifies adapter compatibility,
not classifier quality. Rails/Sidekiq still need the reviewed private-network
attachment and key configuration before live shadow evaluation.
