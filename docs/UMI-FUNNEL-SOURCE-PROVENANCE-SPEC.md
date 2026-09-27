# Recovered-message provenance before funnel observation

Status: implementation design, 2026-09-27. Part of U2 in the CRM funnel plan
(`chatwoot.crm/docs/plans/2026-09-27-1325-feat-funnel-messaging-integration-plan.md`).
This independently useful prerequisite is authorized for local implementation;
no funnel dispatch, model call, account configuration or deployment is included.

## Problem and chosen approach

`Umi::Fbig::MessageHealService` reconstructs missed inbound FB/IG messages with
the normal builders. It currently sets `umi_recovered` only after those builders
commit. Message creation listeners can therefore observe an old recovered message
as fresh. The original provider time is fetched but not stored on the message.
A classifier or event recorder cannot reliably infer freshness from `created_at`.

Store recovery provenance in the builder's message parameters before persistence.
Keep `created_at` at recovery time, preserving existing thread ordering and native
inbox behavior. Persist the original provider time separately as
`content_attributes['external_created_at']` (UTC ISO 8601, null if absent or
invalid), beside the existing boolean `umi_recovered`. Future funnel consumers
must exclude recovered messages from fresh qualification regardless of whether
source time is known. This patch does not retroactively change inbox SLA metrics
or classify, export or backfill anything.

The healer establishes a block-scoped `Umi::Fbig::RecoveryContext`, based on
`ActiveSupport::CurrentAttributes#set`, carrying inbox ID, exact provider message
ID and parsed source time. A small shared UMI builder prepend merges these fields
only when inbox and source ID match and the message is inbound. The block restores
the previous context even when a builder fails. No external webhook field can
establish this trusted context.

Guard and prepend to `Messages::Facebook::MessageBuilder#message_params` and
`Messages::Instagram::BaseMessageBuilder#message_params` in a reload-safe
initializer. Assert the Instagram subclasses have not overridden the hook.
Preserve all existing content attributes, attachment handling, ad attribution,
contact creation and healer locking behavior. Delete the post-persistence marker
update. When IG dedup returns an existing live message, leave it live and return
`:already_present`; never stamp another writer's message after the fact.

## Alternatives considered

- Keep the post-create update or add a queue delay: rejected because neither can
  order all callbacks safely and neither preserves original time durably.
- Set historical `created_at`: rejected for this prerequisite because it changes
  thread ordering and existing inbox metrics; consumers need explicit provenance.
- Trust a synthetic payload field: rejected because the same parser handles live
  external webhook content and should not grant internal provenance authority.
- Separate recovery subclasses for FB builder, IG service and IG builder: avoids
  scoped context, but duplicates three upstream extension points and the IG
  contact-to-builder handoff. Matching the exact source and inbox keeps a single
  scoped context narrow without replacing normal ingestion.

## Interface and failure behavior

- Only `MessageHealService#replay` establishes the context. Live Meta webhook
  payloads cannot establish this context. The generic authenticated message API
  still accepts content attributes; this patch does not make them tamper-proof.
- Valid Graph `created_time` is normalized to UTC ISO 8601; absent/invalid time
  persists as null. Recovery still succeeds and remains visibly historical.
- Context matching cannot leak to a different message, inbox or outgoing echo.
- Normal Rails block restoration also applies to nested contexts and exceptions.
- The metadata is part of the original INSERT, visible to `after_create` and
  `after_create_commit`, with no provenance-only follow-up message update notification. Native story
  attachment processing can still update messages as before.
- The existing global duplicate check and per-message healer lock stay unchanged;
  this patch does not claim to fix all possible live/healer ingestion races.
- Existing historical recovered rows are unchanged. Downstream consumers treat
  recovered rows without source time as unknown-time historical evidence.
- No new PII is stored beyond a provider timestamp. No schema migration needed.

## Verification

Write failing regressions before implementation using real FB and IG recovery
builders. Observe the attributes at the normal Message creation event, not only
by reading the row after `heal` returns. Confirm failure on the current code,
then prove both paths expose recovery marker and original time before callbacks.

Also cover absent/malformed times; preservation of attachments/reply metadata;
normal live ingestion remains unmarked; a different message/inbox and outbound
echo cannot inherit the context; nested/failing replay restores prior state; and
IG dedup does not relabel an existing live message. Run existing heal, recon and
ad-attribution specs plus affected native FB/IG builder specs. Use an isolated
local test database and Redis instance. No real Graph/model calls.

Independent feasibility and failure-mode reviews precede implementation. Review
actual code separately afterwards. Register the additional recovery files under
the existing reconciliation patch, with its existing remove-when condition.

## Review record

Two independent reviews covered feasibility/simplicity and isolation/failure
modes. Both accepted the scoped builder approach. Incorporated corrections:
reuse the existing `external_created_at` field (no runtime consumers in this
checkout), and limit the provenance-authority claim to Meta ingestion; generic
authenticated metadata writes remain unchanged. No unresolved must-fixes.

Reference: [Rails CurrentAttributes block restoration](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html#method-i-set).
