# UMI: FB / IG missing inbound messages — investigation, instrumentation, fixes

## Problem

Reports (industry-wide and Chatwoot-specific) that platforms integrating with
Facebook Messenger / Instagram DM lose inbound messages. UMI runs Instagram via
the **Facebook-page-linked** path (`Channel::FacebookPage.instagram_id`), plus a
plain Facebook Messenger inbox. Known Chatwoot issues in this area: #11578
(Advanced-Access profile-fetch failure → DM dropped), #12055 / #10465 / #8333
(IG messages not created). Meta delivers each webhook **once** (a few retries,
no history/backfill API) — every drop is a permanent loss, and today most drop
paths leave **no trail**, so a production occurrence can't even be diagnosed.

All files audited below are byte-identical to upstream `v4.16.0` (verified with
`git diff v4.16.0`); the existing UMI patch #1 (`zz_umi_facebook_fix.rb`) only
touches the **outbound** path (Graph version + HUMAN_AGENT tag) and cannot cause
or mask inbound loss.

## Inbound pipelines (as of v4.16.0)

**Facebook Messenger**: `POST /bot` → `Facebook::Messenger::Server` (gem 2.0.1;
sha1 signature check) → `Bot.receive` → hooks in
`config/initializers/facebook_messenger.rb` → `Webhooks::FacebookEventsJob`
(Redis mutex) → `Integrations::Facebook::MessageCreator` →
`Messages::Facebook::MessageBuilder` (contact via Graph profile fetch → conversation →
`messages.create!` + attachments, all in one transaction).

**Instagram (both FB-page-linked and direct-login)**: `POST /webhooks/instagram`
→ `Webhooks::InstagramController` (sha256 signature check) →
`Webhooks::InstagramEventsJob` (Redis mutex) → per channel type →
`Instagram::Messenger::MessageText` (FB-page path: Koala profile fetch → contact →
`Messages::Instagram::Messenger::MessageBuilder`).

## Drop-point map

Facebook path:

| # | Where | Failure | Trail today |
|---|---|---|---|
| F1 | gem `Server#respond_with_error` | signature mismatch (wrong/rotated app secret) → 400 for **every** webhook | none (400 body only) |
| F2 | gem `Server#trigger` | `next unless entry['messaging']` → **`standby` entries dropped** (handover protocol: page also connected to another primary receiver, e.g. Meta Business Suite automations). Note upstream's own `MessageParser` reads `messaging \|\| standby` — the parser supports standby but the gem never forwards it | none |
| F3 | gem `Server#receive` | `Incoming.parse` raises `UnknownPayload` (new Meta event type) or any StandardError → 500 → Meta retries the batch. Messages **before** the bad item were already enqueued (hooks fire per item) and dedup on retry; items **after** it are unreachable and lost on retry exhaustion | 500s in nginx logs only |
| F4 | `FacebookEventsJob` | non-lock exception → Sidekiq retry (global cap 3) → dead set, no alert | dead set |
| F5 | `MessageCreator#create_contact_message` | `Channel::FacebookPage.where(page_id:)` empty → silent no-op | none |
| F6 | `Facebook::MessageBuilder#perform` | `return if reauthorization_required?` → **all** messages skipped until manual reconnect (admin does get one reauth email at threshold 2) | none per message |
| F7 | `Facebook::MessageBuilder#perform` | `rescue StandardError` → tracker + `logger.error`, message dropped | one error line, no mid/context |
| F8 | `Messenger::MessageBuilder#process_attachment` | `Down.download` failure (expired FB CDN URL, timeout) raises **inside the message transaction** → rollback → text + message both lost | error line via F7 rescue |

Instagram path (FB-page-linked unless noted):

| # | Where | Failure | Trail today |
|---|---|---|---|
| I1 | `InstagramController` / `MetaTokenVerifyConcern` | signature mismatch → `head :unauthorized`, **zero logging** | none |
| I2 | `InstagramEventsJob#process_messages` | `next if channel.blank?` (unknown instagram_id) | none |
| I3 | `InstagramEventsJob#event_name` | **`@event_name ||=` memoized across the whole job** (all entries — the controller enqueues the full entry array, so one-event-per-entry batching triggers it too, not just mixed messaging arrays): `[read, message]` → message routed to `ReadStatusService` → `params[:read][:mid]` → NoMethodError → job dies (retries crash identically) → **message permanently lost**; `[message, read]` → message commits first, then the mis-dispatched read crashes the batch (message survives; read lost + dead-set noise) | crash in Sidekiq dead set |
| I4 | `BaseMessageText#perform` | inbox blank → silent; `reauthorization_required?` → info log, permanent skip | 1 info line |
| I5 | `Messenger::MessageText#ensure_contact` | profile fetch fails for a **first-time contact** — Advanced-Access 401/403, error 230 (user consent), 9010, any client error → `{}` → contact never created → `create_message` → `return unless @contact_inbox` → **DM silently dropped** (= issue #11578; existing contacts unaffected — matches "some users' messages missing") | warn lines about the fetch, nothing says a message was dropped |
| I6 | `BaseMessageBuilder#message_already_exists?` | dedup by `Message.find_by(source_id:)` — **global, not scoped to inbox** → cross-inbox false-positive drop possible | none |
| I7 | `BaseMessageBuilder#build_message` | same attachment-in-transaction rollback as F8 (regular attachments; only story attachments are rescued) | error line |
| I8 | `BaseMessageBuilder#build_message` | `message_content.blank? && all_unsupported_files?` → skip | none |

Env-level causes (not code, listed for the runbook): missing Advanced Access for
`instagram_manage_messages`/`pages_messaging` (drives I5), token expiry (drives
F6/I4), replying from the native app (echo-only side effects), Meta webhook
subscription auto-disable after sustained 4xx/5xx (driven by F1/F3/I1).

## Deliverables

### A. Instrumentation (first deliverable — makes any future drop diagnosable)

New idempotent initializer `config/initializers/zz_umi_fbig_trace.rb` +
`Umi::FbigTrace` helper (in `umi/app/services/`). One grep-able prefix
`[UMI-FBIG]`, key=value lines, `Rails.logger` (works with or without Sentry):

- `stage=webhook_received` — FB gem `Server#receive` (prepend): object/entry
  count; log + keep behaviour for signature 400s (`stage=rejected
  reason=signature`), unknown-payload/StandardError 500s (`stage=error`),
  standby entries (`stage=dropped reason=standby`).
- `stage=rejected reason=signature` — `Webhooks::InstagramController` (prepend
  on `verify_meta_signature!`) before the silent 401.
- `stage=dropped reason=no_channel` — `InstagramEventsJob` (prepend) for the
  silent `next`; `stage=dispatch event=…` per messaging item.
- `stage=dropped reason=no_page|reauth_required|no_contact|dedup|unsupported` —
  prepends on `MessageCreator`, both builders, `Instagram::Messenger::MessageText`.
- `stage=persisted mid=… message_id=…` — after successful create in both builders.

Every line carries what's known of `mid`, `sender`, `recipient`, `entry_id`.
Guarded per fork rules: each prepend checks the target method exists, else logs
`[UMI-FBIG] patch-skipped …` loudly at boot (no silent rot on rebase).
Instrumentation **never changes control flow** — log-and-continue /
log-and-reraise only.

### B. Fix I3 — event-name memoization (TDD)

Prepend (same initializer) replacing `event_name(messaging)` with a non-memoized
per-messaging lookup. Regression spec first (mixed `[read, message]` batch →
expect the message row to exist), confirm red on stock code, then green.
Upstream-worthy; candidate to PR to chatwoot/chatwoot.

### C. Fix I5 — fallback contact instead of dropping the DM (TDD)

Prepend on `Instagram::Messenger::MessageText#ensure_contact`: when the profile
fetch yields no result (auth error, 230, 9010, client error), create the
contact anyway via `channel.create_contact_inbox(ig_scope_id, fallback_name)`
(name: `"Instagram user <last 4 of IGSID>"`) so the message persists. Known
limitation: `ensure_contact` only runs for a contact's **first** message, so the
placeholder name sticks until an agent renames the contact (documented in the
module). The DM is the valuable artifact; a placeholder name is strictly better
than silent loss. Spec: stub Koala 403 "Advanced Access" → expect message
created with placeholder contact (red on stock, green with patch).

### D. Fix F8/I7 — don't lose the message when an attachment download fails (TDD)

Prepend on `Messages::Messenger::MessageBuilder#attach_file` (the
download + blob-attach step **only** — rescuing the whole `process_attachment`
could swallow a DB-level error and leave the open transaction poisoned, so the
message would die at COMMIT anyway): rescue, log
`[UMI-FBIG] stage=attachment_failed`, report to the tracker, keep the
attachment row (already saved, carries `external_url` — note Meta CDN URLs
expire, so the link may already be dead; the win is the message text + trail).
Mirrors upstream's own rescue pattern for IG story attachments. Spec: FB
message with an attachment whose download raises `Down::Error` → message row
still exists (red on stock, green).

## Alternatives considered

- **Fork the gem / rack-middleware instead of prepends**: heavier to maintain;
  prepends in one initializer follow the proven pattern of patches #1/#5.
- **Fix upstream & rebase**: right long-term for B/D (and arguably C); PRs can
  be sent later, the fork needs protection now.
- **Metrics/alerting stack (StatsD, Prometheus)**: overkill for one VPS; greppable
  structured logs are queryable with `docker logs | grep '\[UMI-FBIG\]'` and can
  feed an alert later.
- **Changing 500→200 for unknown payloads (F3)**: deliberately NOT done —
  answering 200 tells Meta "delivered" and forfeits its retries. Instrument only.
- **Scoping the IG dedup (I6)**: real upstream bug but effectively unreachable
  single-tenant; documented, not patched (keep the diff minimal).

## Failure modes of the patch itself

- Upstream rebase changes a patched method → boot-time guard logs
  `patch-skipped`, stock behaviour continues (no crash, no silent divergence).
- Log volume: one line per webhook stage; FB/IG volume at UMI is low (« 1 rps).
  No payload bodies are logged (PII: only IDs/mids, same as upstream's own logs).
- Fallback contact (C) could create a contact for a sender whose profile fetch
  failed transiently → harmless; next successful fetch enriches it.
- Attachment rescue (D) can persist a message whose attachment is missing → the
  bubble shows text + external link; strictly better than losing the message.

## Test / verification plan

- Specs per fix (red→green, noted in commit messages), plus specs asserting the
  trace lines at the key decision points (webhook received / dropped / persisted).
- All existing FB/IG specs stay green (`spec/jobs/webhooks/`, `spec/builders/messages/`,
  `spec/services/instagram/`, `spec/controllers/webhooks/`, `spec/lib/integrations/facebook/`).
- Prod verification after deploy: send a test DM to IG + FB page, then
  `grep '\[UMI-FBIG\]'` should show `webhook_received` → `persisted`.
  Any real-world drop now leaves a `rejected/dropped/error` line with reason + ids.
- Limits of the trail (be honest when diagnosing):
  - **Absence of `webhook_received` for a known-active thread means Meta never
    delivered** (subscription auto-disabled after sustained 4xx/5xx, or app-level
    delivery issue) — not a code drop. Check the Meta app dashboard.
  - The trail is diagnostic, not alerting: a `dropped` line is still silent
    until someone greps. A log-based alert (e.g. a cron grepping the last hour)
    is deliberately out of scope for this patch set.
  - Docker json-file logs rotate; if drops are reported later than retention,
    the trail is gone. Check/raise `max-size`/`max-file` on the VPS.
  - Upstream `InstagramEventsJob` already logs each full messaging payload
    (including message text) at info level — that pre-existing line is the real
    log-PII/retention concern, not the id-only `[UMI-FBIG]` lines.

## Review outcome (three independent lenses)

Reviewed pre-implementation by correctness, scope/fork-fit, and failure-modes
agents. All three confirmed the core diagnosis (I3, I5, F8/I7) against the
code. Material corrections folded in:

- I3's `[message, read]` ordering does **not** lose the message (it commits
  before the crash) — only `[read, message]` does; and the memoization spans
  the whole job (all entries), so one-event-per-entry batching triggers it too.
- C's placeholder name is **permanent** (profile enrichment only runs on a
  contact's first message) — framed as such, plus an `UMI_IG_FALLBACK_CONTACT=off`
  kill switch and an echo-path spec (error 230 mints placeholder contacts for
  agent-initiated threads — accepted, the thread is logged instead of vanishing).
- D narrowed from `process_attachment` to `attach_file` to keep DB-level errors
  out of the rescue (transaction-poisoning risk).
- All trace-field computation is evaluated inside the helper's own rescue
  (`StandardError` — Sidekiq shutdown signals must propagate); a trace bug can
  lose a log line, never a webhook. Verified by a signed-webhook 200 spec.
- Job-level `stage=error` context lines added (Facebook + Instagram events
  jobs) so dead-set jobs are grep-able by mid/sender, not just class name.
- F3's blast radius corrected: only items after the unparseable one are lost.

## Runbook — executed 2026-07-22, verified findings

1. **Advanced Access — effectively working; not the live failure mode.** The
   page token (valid, non-expiring) holds `instagram_manage_messages` +
   `pages_messaging`, and ordinary customers' IG DMs arrived every day for the
   two weeks before this patch set (checked in the prod DB). The remaining IG
   risk is the intermittent per-message class fixed by patches 9–11.
2. **Webhook subscriptions — audited via `GET /{app}/subscriptions` and fixed.**
   `page` and `instagram` objects both active, callbacks correct
   (`/bot`, `/webhooks/instagram`). `message_echoes` + `messaging_handovers`
   were missing on the page — added 2026-07-22 at both the app level and the
   page level (`Channel::FacebookPage#subscribe`); without them, agent replies
   sent from the FB app / Business Suite never synced into Chatwoot. The
   `instagram` object has **no `message_echoes` field at all** (verified in the
   dashboard; the Graph API rejects it with a misleading permissions error) —
   IG echoes ride the subscribed `messages` field with `is_echo`, so nothing to
   enable; verify empirically post-deploy by replying once from the IG app.
   `messaging_seen` and `message_edit` deliberately left unsubscribed (no
   Chatwoot handler; seen-events also feed the I3 batch shape).
3. **`SENTRY_DSN` is NOT set in prod** (verified in the rails container env) —
   the `[UMI-FBIG]` lines are the primary forensic trail.
4. **Log retention fixed** (umi-vps-infra `4a50982`): rails/sidekiq json-file
   logs capped at 5×50 MB, and an hourly root cron appends all `[UMI-FBIG]`
   lines to `/var/log/umi-fbig-trail.log` — container logs are otherwise
   destroyed by every deploy (compose recreation).
5. **FB Messenger had zero inbound since 2026-06-21** (IG flowing daily) while
   the page subscription shows active — either genuinely no FB traffic or an
   upstream delivery problem; the `webhook_received` trace lines decide this
   after the first deploy.
6. Don't answer FB/IG DMs from the native apps while Chatwoot is the system of
   record (thread desync, read-state side effects) — though with
   `message_echoes` now subscribed, FB-app replies at least sync in as echoes.

## Follow-up candidates (not in this patch set)

- **Netdata alert**: add an `fbig_drops` check to the existing Layer-2
  `shumabit.check` health pattern (producer counts loss-indicating lines —
  stages `rejected`/`error`, `dropped` with reason ≠ `dedup` — from the trail
  file; the existing template alarm + Cloud push covers it).
- **Reconciliation (patch #12 candidate)**: daily job pulling thread/message
  ids from the Graph Conversations API (`GET /{page_id}/conversations?
  platform=messenger|instagram&fields=messages{id,created_time}`, works with
  the existing token) and anti-joining against `messages.source_id` — catches
  the class no webhook-side code can see (Meta never delivered). Phase 1
  detect-and-report; phase 2 auto-import through the builders (idempotent via
  source_id dedup). Needs a spike first: webhook-mid ↔ API-mid equality, IG
  per-thread content limits, unsend exclusion.
