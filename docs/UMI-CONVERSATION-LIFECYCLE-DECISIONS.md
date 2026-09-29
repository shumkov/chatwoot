> Historical production receipts remain valid only for their recorded time. The final stage-one scope, cleanup and implementation acceptance are governed by [UMI-FUNNEL-STAGE-ONE-SPEC.md](UMI-FUNNEL-STAGE-ONE-SPEC.md); this file is not a second competing rollout plan.

# Conversation lifecycle and integration decisions

**Canonical field/UI contract:** [UMI CRM data contract](UMI-CRM-DATA-CONTRACT.md) supersedes the preliminary taxonomy, customer-attribute visibility, sync and note presentation decisions below. The operational receipts and conversation/ad lifecycle decisions remain valid.

29 September 2026. Product decisions accepted in the CRM discussion; implementation gaps below are not delivered changes. The user-authorized inbox 2, 3 and 7 setting changes below are delivered. No flow changes or customer messages were made during this audit; the remaining behavior changes are pending.

This addendum governs conversation boundaries and operator visibility alongside UMI-FUNNEL-CLASSIFICATION-SPEC.md. The initial proposal to classify the entire historical inbox before launch is withdrawn. Historical conversation classification is stage 2. Existing Shopify-derived payment-history/lifecycle work is separate and remains in place.

## Accepted behavior

- Stage 1 uses Chatwoot's native multiple-conversation mode for the pilot account 1 / FB-Instagram inbox 2: `lock_to_single_conversation=false` was applied and read back at 2026-09-29T07:07:22Z. The user subsequently authorized the same routing setting for WhatsApp inbox 3 and LINE inbox 7; both were applied and read back at 2026-09-29T07:50:44Z. This does not expand classifier eligibility to those channels.
- Native routing chooses the newest non-resolved matching conversation (including pending/snoozed); only when no matching non-resolved conversation remains does the next inbound message create a new conversation. Resolving the newest thread alone is not sufficient if an older unfinished thread remains. Resolve when the request is handled, not simply when payment arrives. Do not automatically close all existing threads, split old history or split a thread on every change of topic.
- Keep customer lifecycle (Client/Repeat from Shopify payment facts) separate from conversation sales result, overlapping topics, and Chatwoot operational status (Open/Snoozed/Resolved).
- Purchase followed by support within the same unfinished conversation preserves its paid result and adds support topics. A separate return-only conversation is not a new qualified sale. A later new shopping conversation can qualify independently. Refund facts remain attached to the order; never erase the historical purchase or infer payment from model text.
- A new conversation must not inherit an old conversation's sales status, topic labels, ad attribution or order-conversion result. Its managed customer labels are freshly projected from current contact facts under the canonical data contract, not copied from an old conversation. It may read known customer facts and prior conversations as context. Customer history is not evidence of a fresh qualification.
- Multiple channels may produce multiple conversations for one verified customer. Never merge identities from a matching display name. One order is still one sale. Automatic deduplication of the same buying attempt across channels is not delivered; the pilot does not claim one qualification per unique customer/opportunity. Record this reporting limitation and do not expand scope into a new opportunity engine.
- Bulk historical classification is stage 2, not a campaign-launch prerequisite. Repaired review examples use all available text/history needed for the judgment and known identity/order facts, preserve operator corrections, and disclose unavailable attachments. The previous arbitrary last-20-message review is not sufficient evidence of full-context accuracy. This does not authorize bulk historical writes or exports.

## Current state, verified 29 September

At 2026-09-29T07:07:22Z, production inbox 2 (FB/Instagram) was changed from true to false with persisted readback. Subsequently, at 2026-09-29T07:50:44Z, inbox 3 (WhatsApp) and 7 (LINE) were also changed from true to false, with persisted readback. Settings remain true for 5/6 (Twilio), and false for 1 (website), 8 (email), 9 (API). This is a configuration receipt, not yet a natural incoming-message acceptance test. No existing conversation was resolved or rewritten by the operation. Conversation display ID 390 is open with no `umi_sales_status` and one conversation on its contact.

The classifier currently requires fresh live evidence after the collection/activation boundaries, preserves qualified/order_placed/purchased results, and permits only one qualification occurrence per conversation. Production mode is shadow. Input is at most 100 public messages / 30,000 characters and currently excludes older pre-collection messages even as context. Keep fresh-evidence rules for new conversions; access to older context is a separate concern. Before quality acceptance, reconcile review and production context construction; do not solve that mismatch by treating old messages as fresh conversions.

The existing once-per-conversation qualification rule fits separate completed requests better than a lifelong thread. Turning the inbox flag off alone does not close old open threads, make their old qualification repeatable, or fix multiple buying attempts inside one still-open thread. Until resolved, those remain the same request for pilot counting. Do not reset purchased status to manufacture a new lead.

## Taxonomy decision and value detection

The historical research is docs/UMI-LABEL-TAXONOMY-SPEC.md, particularly its list-attribute section and native-rule action limitation. Native rules can filter/read custom attributes but cannot write them. Our custom jobs/classifier can write either; that old limitation does not prevent an enum-based funnel.

Keep the existing hybrid, chosen by meaning/cardinality, not by a supposed inability to automate attributes:

- One conversation sales result: `umi_sales_status`, a list/enum attribute with allowed choices, already implemented.
- Several simultaneous/observed topics: `intent-*` / `support-*` labels. A sizing question and refund may coexist; a single-choice dropdown would discard that information. Labels accumulate observed topics, not necessarily the latest topic.
- `lead-qualified` / `lead-converted`: existing derived reporting mirrors of the sales attribute, not independently editable authoritative statuses. Keep these active mirrors. The final stage-one plan separately removes the explicit retired CRM catalog and all its assignments; unrelated active business labels are not silently classified as legacy.
- Customer Client/Repeat: Shopify-derived Klaviyo lifecycle properties; Instagram audience band is already a separate contact list attribute. These are not extra conversation sales stages.

There is no currently active automatic `value-*` or influencer classifier. Live rule inventory found no matching rules, and ClassificationClient only permits nine intent/support topics. Existing `value-influencer` and Potential Ambassadors are available pieces, not proof of classification. Explicit collaboration can be recognized from conversation evidence, but follower count alone only signals a candidate. The latest clarification includes basic relationship flags, operator visibility and their synchronization in stage 1, as specified below. Outreach, ambassador management and other full influencer workflows remain deferred; do not add another model or marketing automation framework.

## Field inventory and system ownership clarification

Production inventory on September 29 contains these 27 label definitions; definition does not mean an active writer:

- `intent-`: interested, size-advice, product-details, color-advice, waiting-reply, waiting-payment, ready-to-order.
- `support-`: after-sales, complaint, exchange, order-tracking, refund, special-request.
- `lead-`: new, qualified, converted, lost, unqualified.
- `value-`: first-time, high-value, influencer, returning, vip, wholesale.
- `source-`: organic, paid-ads; plus `spam`.

The classifier permits only nine topics: intent size-advice, color-advice, product-details, ready-to-order; support order-tracking, exchange, refund, complaint, after-sales. It remains in shadow. One intent dropdown and one support dropdown would allow one value in each group, but not two intent values (such as size advice and ready to order). Sales status is intentionally single-valued: `unevaluated`, `engaged`, `qualified`, `inactive`, `not_sales`, `order_placed`, `purchased`. Raw labels do not enforce cardinality; the current projection manages only the qualified/converted lead mirrors, not all legacy lead labels.

| Information | Chatwoot | Klaviyo | Shopify |
|---|---|---|---|
| Current conversation sales result | Authoritative `umi_sales_status` enum; derived lead mirrors | Custom qualification/verified-paid events for segmentation; not an identical copy of all conversation states | Linked order facts; no mirrored conversation funnel |
| Conversation topics | Multiple `intent-*` / `support-*` labels | Not automatically copied as profile categories | Not automatically copied as customer tags |
| Paid buyer history | Linked customer/order context; native order count is not paid count | `umi_paid_order_count`, `umi_paid_history_complete`, `umi_buyer_lifecycle` (unclassified/non_buyer/client/repeat), `umi_payment_snapshot_at` | Authoritative orders, transactions, refunds, customer identity |
| Relationship/value | Existing `value-*` labels available for manual grouping; no automatic writer | Separate segmentation, including the existing Potential Ambassadors audience; no automatic label mirror | Customer tags may exist, but no promised equivalent value taxonomy sync |
| Instagram context | Followers number, audience enum, verified/follows-us/followed-by-us booleans, bio/website | Selected integration-owned profile context where configured | No required copy |
| Ad origin | Raw referral evidence, meta_ad_id/ref/title attributes and private notes | Custom event attribution where exporter supports it | Specific order/conversation linkage; no wholesale label sync |

Linh's saved Chatwoot-tab text explicitly recommends simultaneous customer-value labels VIP, Returning Customer, First-Time Buyer, High Value, Wholesale and Influencer, for filtering and automations (including VIP routing). It does not specify spend thresholds or automatic influencer criteria. These mix buyer history with business relationships; influencer can coexist with returning customer and a `not_sales` collaboration conversation. Existing `value-influencer` can currently provide manual grouping. The latest clarification below replaces the earlier proposal to defer all automatic relationship detection/sync. A follower band alone is not verified influencer identity. A fresh Google Docs read on September 29 failed with an expired OAuth grant, so this requirement attribution uses the prior session's saved document text rather than claiming a current reread.

Resolve reliable customer identity before using their purchase history in classification/review. Unknown identity must remain unknown; it does not prevent classifying a new anonymous enquiry. Linking a contact to a customer does not attribute that customer's past orders to the current conversation. No bulk historical linking is a campaign-launch prerequisite, and the candidate for conversation 390 still awaits specific identity confirmation.

## Stage-one customer context and synchronization

The current agreed field, managed-label, mobile visibility and sync contract is exclusively [UMI-CRM-DATA-CONTRACT.md](UMI-CRM-DATA-CONTRACT.md). It replaces the earlier proposal here: use contact attributes as canonical facts, eight managed customer labels (chooser, seeker, client, repeat, vip, influencer, wholesale, high-value) on active conversations, and private summary notes in the existing mobile/web UI. There is no custom Vue summary, mobile fork or bidirectional label-to-attribute writer. The canonical contract defines projection, close/reopen, identity correction, legacy normalization and review acceptance. The production inventory above is an observation, not proof that the target sync exists.

## Customer example 10 verification

Read-only production check: conversation 390/contact 2300 has no email, phone, Shopify customer link or Klaviyo profile link. Its full public history contains 31 messages and 1,308 text characters, with seven messages carrying attachments. It does not require 1M context or arbitrary last-20-message truncation.

A Shopify name-match candidate has five orders, of which exactly two meet the existing successful-payment rule: March 7, THB 3,000 and August 7, THB 4,491. The other three are voided/expired without completed payment. That candidate's existing Klaviyo profile already has `umi_paid_order_count=2`, `umi_paid_history_complete=true`, `umi_buyer_lifecycle=repeat` (snapshot 2026-09-29T06:40:02.051Z). The user was asked to confirm the identity before linking; a name match and matching products are not an automatic binding. No private identifiers or transcripts are stored here.

## Models and effort: Sol in stage 1, Sonnet comparison in stage 2

- Automatic classifier and the assisted 40-example batch use configured model alias `gpt-6-sol` through RubyLLM and CLIProxy. ClassificationClient sets max_completion_tokens=2048, but sends no explicit reasoning effort. Effective provider/default effort is unverified; token limit is not effort. Official OpenAI docs say medium is the API default, but the actual subscription-proxy behavior has not been measured.
- The running Shumabit Chatwoot worker also has `CHATWOOT_BRIDGE_MODEL=gpt-6-sol`, and explicitly passes `CHATWOOT_BRIDGE_EFFORT=low` to its CLI invocation. It is a separate agent/session path, not the classifier session. The deployed agent file still has `model: sonnet`; resolve/verify this default versus CLI override before claiming receipt-level model identity. No model or effort change is made here.
- The first-version Shumabit agent instructions currently allow reads, analysis and draft replies only, and explicitly prohibit label/status writes. The automatic classifier is a different writer. Requiring notes for future Shumabit mutations does not silently enable extra tools or expand first-version scope.

The latest user decision keeps Sol for stage 1 and defers the Sonnet high comparison to stage 2. Connecting Claude or running that comparison is not a launch prerequisite; retain the existing classifier model while completing its quality acceptance. The existing Sol choice reused the working authorized proxy model and a successful structured-output compatibility probe; no comparative quality study established that Sol is superior for UMI classification.

Fresh VPS `/v1/models` discovery returns `gpt-6-sol` and no Sonnet. Credential metadata shows two Codex providers and zero Claude providers. Do not silently replace the proxy, restart sibling consumers, or use a paid API key instead of the user's subscription. A Claude connection and exact model/effort/schema compatibility check are prerequisites for a real trial. The installed device-auth helper is Codex-specific; do not pretend its existing login procedure already handles Claude.

Official docs checked September 29 list Sonnet 5 and Sonnet 5.5 at 1M context and $2/$10 per million input/output tokens; Sol at 1.05M and $2/$10. Sonnet 4.6 is also 1M, but $3/$15. There is no lower per-token rate for selecting a smaller context window on Sonnet 5: the full 1M window is available at standard pricing, and only tokens actually sent/generated are billed. These are public API list prices, not charges for subscription accounts. Same text can tokenize differently; high effort can consume more thinking/output. A 10,000-input/1,000-output-token request would cost $0.03 at the first two list rates, assuming no cache/other modifiers. This is arithmetic, not measured UMI usage.

Stage-2 comparison contract: freeze the repaired review packet and policy; run current Sol configuration and the exact available Sonnet high target on identical inputs with no writes, record returned model, requested/effective effort where observable, input/output/cache/reasoning usage where provided, latency, schema failures, uncertainty and user-corrected errors. Missing usage remains unknown. No automatic model fallback/retry. Do not count unknown/default Sol effort as explicitly medium, or infer quality from context size. No Sonnet inference or customer-data transmission to Anthropic happened in this audit because no Claude route exists.

## Visible change notes — stage 1

Every applied AI change to sales status, labels or customer relationship attributes must produce one private operator-visible note, whether initiated by automatic classification or a future authorized Shumabit action. Use the actual persisted before/after state, added/removed labels, short reason, and actual actor. Do not claim Shumabit performed a background classifier action.

Example: “AI classification: Sales status engaged → qualified. Added intent-size-advice. Reason: customer supplied measurements and asked to reserve the selected dress.” If paid status is preserved and only a topic changes, say only that the topic changed.

Use one existing durable change/evaluation identity to prevent duplicate notes on replay. Publish a note only for committed changes; persist the note in the same database transaction as the combined local status/label/customer-attribute change and any pending relationship-sync record, using the existing evaluation/change identity. Remote Klaviyo synchronization is subsequent: the local note must not claim remote success before verified readback. If note persistence fails, roll back that applied change and record a visible failure through the existing error path; do not build a separate audit transport. No note for unchanged state or shadow-only evaluations. Notes must remain private, must not invoke Shumabit recursively, and must not become incoming sales evidence or conversion events. Manual operator changes and ordinary AI suggestions are not falsely attributed as automatic applied changes.

## Ad attribution — stage 1 repairs

Existing code captures raw Meta ad referral on the inbound message, projects meta_ad_id/ref/title onto conversation attributes, and posts an ad-context private note including fetched creative/campaign context. The raw message occurrence is the authority; mutable sidebar fields and human-readable notes are not conversion evidence.

Source inspection found three cases needing coverage before declaring repeat-ad attribution complete:

1. AdContextNoteJob suppresses another successful note for the entire conversation, regardless of ad ID. A later ad referral in a reused open conversation can change the sidebar while leaving the old note. Support a distinct source referral/ad occurrence without duplicating webhook retries; guard against an earlier async fetch posting misleading current-ad context after a newer referral.
2. ConversationTransition builds qualification attribution only from cited qualifying messages. A referral may be present on the first incoming message while actual qualification occurs in later messages without referral. Preserve the relevant same-request referral separately from qualification evidence; do not silently drop it or borrow another conversation's old ad.
3. A new conversation must not borrow its source from the contact's previous conversation. Multiple referrals must retain their original timestamps and message references; never rewrite an already frozen conversion attribution using the latest sidebar value. Chosen local qualification attribution rule: use the latest valid, already-recorded live same-conversation/channel ad referral at or before the qualification evidence cutoff. Break ordering ties by source message ID; conflicting identity or missing trustworthy time leaves attribution unknown. A later/delayed referral never rewrites a frozen positive event; retain it as separate evidence. This is a local association rule, not a claim to reproduce Meta attribution. Acquisition/cohort first-message source remains a separately named dimension and must not be relabeled as the qualification touch. No cross-conversation carry-forward or speculative multi-touch model.

The current Meta sender supports Messenger QualifiedLead using page/scoped-user identity and event time. Its current payload does not include ad_id; local ad capture is for evidence/reporting, not a claim that CAPI accepts arbitrary ad IDs or that attribution is proven. Instagram permission and Purchase mapping remain separate unresolved delivery scope. Do not advertise full Meta optimization readiness from the private note alone.

## Klaviyo integration audit and ownership

No built-in Klaviyo app was found in the deployed version's `config/integration/apps.yml`, current upstream catalog, or official integration listing. This is bounded evidence, not a claim that no third-party connector exists. Our repository contains custom n8n workflows, plus the Rails funnel exporter and the separate paid-customer projection job.

| Path | Responsibility | Decision |
|---|---|---|
| Shopify → Klaviyo native integration | Customer/order/product/checkout/fulfillment/refund data and configured storefront activity | Keep as commerce sync; do not replay native Placed Order/Ordered Product/Refunded Order from Chatwoot. |
| Shopify → Chatwoot | Operator customer/order context and verified conversation-order links | Keep for support and attribution; this is not a replacement for Shopify → Klaviyo. |
| Chatwoot → Klaviyo funnel exporter | UMI Conversation Qualified, plus distinct UMI verified-paid semantics under the existing delivery spec | Keep only business facts not equivalent to native metrics; one writer per custom metric. Do not count native order and custom paid event as two sales. |
| Existing Shopify financial/lifecycle job → Klaviyo | Verified paid buyer stage/count for TBYB/pickup, based on actual transactions/final basket | Retain this semantic supplement, not a second full Shopify integration. Do not equate Placed Order with paid. |
| Existing n8n Chatwoot → Klaviyo | WhatsApp/LINE inbound and explicitly attributed outbound message lifecycle events | Distinct from sales qualification; inbox 2 is currently excluded by declared routing. No new duplicate qualification writer. |
| Existing n8n Klaviyo → Chatwoot | Selected contact attributes (segment, campaign, engagement, loyalty) and internal campaign-send notes where configured | Optional operator context only; never the writer of Shopify payment facts or a competing sales status. Existence of workflow code does not prove live flow wiring. |

Native Shopify `Placed Order` is recorded on order creation/checkout; it is not our final-paid rule. Klaviyo also documents that later order changes do not rewrite the original synced metric. For TBYB edited baskets and deferred payment, the separate final-paid evidence remains useful. Klaviyo owns segments and sends; consent is not granted by a conversation, profile match or tag. Do not add a new connector/framework or auto-create ambiguous profiles during this audit.

## Implementation and verification before activation

1. Inspect/refine the pilot inbox transition with real unfinished-versus-resolved examples; preserve legacy history and existing manual decisions. Setting readback is complete; verify native open/new routing without generating fake campaign conversions. Do not couple this change to other channel migrations.
2. Pin regressions before behavior fixes: all matching threads resolved→new, open→same, and older unfinished thread still present→reuse; buyer→return→new purchase; existing lifelong open thread; two channels/one order; old ad→new referral; referral on first message plus qualification on later messages; missing/conflicting referral; duplicate webhook; delayed ad fetch.
3. Add private-note acceptance cases for actual status delta, topic-only change on purchased, no-op, shadow, replay, failed write, and loop prevention. Reuse existing services, no permission framework.
4. Repair assisted review context without erasing existing corrections. Explicitly show customer history separately from current sales judgment; human correction is not model training. Auto activation still waits for quality acceptance.
5. Inventory actual Klaviyo metrics and connected flows before changing sync ownership. Verify that commerce-native and custom-paid events cannot double-trigger the intended paid lifecycle flow. Current flow attachment/sending is not changed by this document.

Rejected alternatives: keep one lifelong conversation and reset its conversion status (loses meaning and conflicts with current occurrence identity); add opportunity/session entities now (too much scope); automatically split on every topic or arbitrary inactivity threshold (unnecessary policy guessing); run all historical classification before launch (deferred by user); replace native Shopify commerce sync with Chatwoot (duplicates authoritative data).

## Stage-one remaining acceptance checklist

- Delivered in this audit: inbox 2, 3 and 7 multiple-conversation settings with readback; explicit stage-2 historical classification; clarified hybrid taxonomy and verified model/integration inventory.
- Still required before automatic classification: repair evaluation/production context parity, retain old context without making it new conversion evidence, account for verified customer history, complete the accepted correction-only review, and pin accepted model/effort/policy. Use current Sol for stage-1 quality acceptance; Sonnet comparison is stage 2 and is not an activation prerequisite. Current production stays shadow until quality acceptance.
- Stage 1 customer context: implement the reviewed schema for paid buyer context and independent relationship flags, bidirectional named-property sync and expanded influencer/wholesale quality cases. VIP/high-value numerical rules require a real business definition; no AI guessing. No property sync has been deployed yet.
- Stage 1 code work: same-request referral→qualification linkage, repeated-ad note correctness, and private notes for every actual AI status/label mutation, with regression tests and independent reviews. These are not stage 2.
- Stage 1 delivery proof: demonstrate actual eligible provider events accepted/matched for the intended channel/objective. Today Messenger QualifiedLead is the only implemented Meta mapping. Instagram permission and Purchase support must be resolved for the desired optimization; campaign collection can run without claiming those optimizations are complete. No fake sales for acceptance.
- Klaviyo: native Shopify metrics were freshly verified; UMI Conversation Qualified/paid custom metrics were absent from the current list. Confirm first genuine custom-event readback and add the recent-conversation audience; verify flow dependencies and no duplicate paid triggers. Existing native buyer segments remain in place.
- Commerce: genuine paid/refund linked-conversation acceptance remains; unresolved TBYB/pickup reservation marker/suppression and service denominators must not be described as delivered. Suppression is required before turning on associated recovery flows, not a reason to send those flows now.
- The latest user correction includes human response-time/SLA statistics in stage one, including verified business-hours coverage. The user subsequently included the whole Linh operating block: ad-comment coverage/ownership verification, approved scripts/FAQ/welcome, and evaluation-within-24h reporting. Comment coverage remains separate from private DM handling and is not yet established; autonomous public replies remain outside the first iteration. Friday reporting is generated automatically by the existing Shumabit scheduler under U14 of UMI-FUNNEL-STAGE-ONE-SPEC.md; delivery awaits the selected internal destination. Spend/ROAS and attendance/no-show reports remain unavailable until their source inputs are defined.
- Deferred: Sonnet comparison/model migration, bulk historical classification, full influencer outreach/management workflows, customer-facing Shumabit, order creation inside Chatwoot, additional channels and an opportunity engine. Basic relationship flags and their sync are stage 1, not part of the deferred full influencer workflow.

### Review agreement

The user-approved AI-proposal/correction-only review supersedes the original blinded-label/90%-agreement procedure in UMI-FUNNEL-CLASSIFICATION-SPEC.md. Operator comments dispute the entire row even if status is unchanged. Only an explicit final confirmation accepts unchanged proposals. This is qualitative assisted acceptance, not a blind accuracy estimate or fine-tuning. Preserve hard-negative coverage and zero false qualifications on the designated reviewed hard-negative cases, plus deterministic invariants for evidence, payment ownership, corrections and no customer sends. Any material model/effort/prompt/context change requires evaluating the affected cases again.

Earlier independent read-only spec reviews covered the preceding lifecycle/ad attribution/acceptance and taxonomy/simplicity/Klaviyo ownership decisions. The current managed customer-label/mobile contract has its own review record in UMI-CRM-DATA-CONTRACT.md; the old receipt does not cover that new projection. The latest customer-attribute and two-way-sync refinement received a separate clean re-review from both reviewers after resolving native unknown rendering, paid-field protection, canonical-contact binding, durable negative corrections, local note/sync atomicity and the polling concurrency limitation. Their must-fixes were incorporated: native routing nuance, hybrid rationale/reporting mirrors, absent value detection, deterministic same-request attribution, transactional private notes, and assisted-review gate. This is a reviewed specification, not implementation or end-to-end production acceptance.

## Sources

- Chatwoot inbox options: https://chatwoot.help/hc/user-guide/articles/1677492191-adding-inboxes
- Current upstream built-in app catalog: https://github.com/chatwoot/chatwoot/blob/develop/config/integration/apps.yml
- Chatwoot integration listing: https://www.chatwoot.com/features/integrations
- Klaviyo Shopify data reference: https://help.klaviyo.com/hc/en-us/articles/115005080447
- Local: builders/messages/{facebook,instagram}, Umi::Funnel::{ConversationClassifier,ConversationTransition,EventRecorder,DeliveryService}, Umi::FbigAdAttribution, Umi::Meta::{AdContextNoteJob,AdContextNoteTrigger}.
- Infra: n8n/{chatwoot-to-klaviyo-events,klaviyo-to-chatwoot-attributes}.json and roles/{shumabit_chatwoot,klaviyo_sync}; current readiness evidence remains in umi-vps-infra/docs/UMI-FUNNEL-STAGE-ONE-READINESS.md.

- Model references: https://developers.openai.com/api/docs/models/gpt-6-sol ; https://platform.claude.com/docs/en/about-claude/pricing ; https://platform.claude.com/docs/en/build-with-claude/context-windows ; https://platform.claude.com/docs/en/build-with-claude/effort

- Customer attribute types/UI: https://www.chatwoot.com/hc/user-guide/articles/1677502327-how-to-create-and-use-custom-attributes
- Klaviyo profile properties: https://developers.klaviyo.com/en/v2026-04-15/reference/profiles_api_overview
