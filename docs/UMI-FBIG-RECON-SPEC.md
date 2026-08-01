# UMI patch #12: FB/IG message reconciliation against the Graph API

## Problem

Patches 8–11 instrument and fix the webhook-side pipeline, but a whole class
of loss is invisible to any webhook-side code: **Meta never delivered** —
subscription outages/misconfiguration (the `message_echoes` gap found
2026-07-22 is a live example), delivery throttling after sustained errors, and
anything dropped before the patches deployed. The only ground truth for "what
messages exist" is Meta's own **Conversations API**. Reconciliation closes the
loop: daily, compare Meta's message ids against Chatwoot's
`messages.source_id` and report what's missing. It automates the check the
message-loss spec's runbook tells a human to do by hand ("absence of
`webhook_received` = Meta never delivered").

## Spike results (run read-only against prod, 2026-07-22)

- `GET /{page_id}/conversations?platform=instagram|messenger&fields=id,updated_time`
  works with the **existing page token** for both platforms (threads returned
  newest-updated first). Per-thread
  `GET /{thread_id}/messages?fields=id,created_time,from` works, newest first —
  and **`from` rides the bulk listing on both platforms** (IG: `id`+`username`;
  FB: `id`+`name`), so direction and sender id come with the anti-join data at
  zero extra calls. `from` is sender metadata, not message content, so IG's
  content-access limits don't apply.
- **Mid formats match Chatwoot's `source_id`** on both platforms (IG `aWdf…`,
  FB `m_…`) — the anti-join is valid. (Observed match, not a DB invariant —
  `index_messages_on_source_id` is non-unique; a duplicate mid reads as
  "present", which is the safe direction.) Outbound messages sent via Chatwoot
  persist the send-API mid to `source_id`
  (`facebook/send_on_facebook_service.rb:31`, `instagram/base_send_service.rb:59`).
- **A real missing message surfaced immediately**: FB thread
  `t_1683595579505486` contains a mid created 2026-06-29, while Chatwoot's
  last FB message is 2026-06-21 — consistent with the pre-fix missing-echo
  class (page reply sent from Meta Business Suite; `message_echoes` was not
  subscribed until 2026-07-22).
- IG threads span back far before the integration went live (~2026-07-06) —
  naive full-thread comparison would flag pre-integration history as
  "missing". The comparison must be **time-windowed**.
- IG `message_count` comes back empty — don't rely on it.

## Approach — phase 1: detect and report (this patch)

`Umi::Fbig::ConversationReconService` (per `Channel::FacebookPage`; the
`Umi::Fbig` namespace keeps the 8–12 family cohesive, and the `[UMI-FBIG]`
log prefix is load-bearing — the journald trail and planned Netdata check grep it):

1. For each platform in `%w[messenger instagram]`, **independently rescued**:
   - Page through `/{page_id}/conversations` (fields `id,updated_time`,
     `limit=50`). Stop only after **3 consecutive** out-of-window threads
     (Meta can return slightly out-of-order entries when a thread is touched
     mid-pagination; stopping on the first would silently under-cover — the
     worst failure for a detection net). `MAX_THREAD_PAGES` cap, logged via
     `caps_hit` when hit.
   - Per in-window thread: page `/{thread_id}/messages` (fields
     `id,created_time,from`), same 3-consecutive stop rule against
     `created_time`, `MAX_MESSAGE_PAGES` cap per thread.
2. Anti-join in-window mids against the account's messages
   (`account.messages.where(source_id: mids)` — account-scoped so a mid in a
   foreign inbox can't mask a real miss).
3. Per missing mid (capped at `MAX_MISSING_LINES = 20` per platform, then
   `missing_lines_capped=true` — a systematic false-positive class must not
   flood the trail or the future alert):
   `[UMI-FBIG] stage=reconcile_missing platform=… thread=… mid=… created=… direction=in|out sender=<PSID/IGSID> [suspect=multipart]`
   — direction derived from `from.id == page/ig id`; sender id is the join key
   a human (or phase 2) needs to find the customer. Ids only, never content.

   **`suspect=multipart` labeling** (the one systematic `direction=out`
   false-positive class, found in review): a Chatwoot message sent as
   text + attachment makes one Meta send call **per part**, and each call
   overwrites the same row's `source_id`
   (`facebook/send_on_facebook_service.rb:8-31`,
   `instagram/base_send_service.rb:62`) — so N parts produce N Meta mids but
   Chatwoot keeps only the last, and the other N−1 look "missing". For each
   missing `direction=out` mid, one indexed query checks whether the account
   has an outgoing message created within ±90 s of the mid's `created_time`;
   if so the line is tagged `suspect=multipart` and counted separately
   (`missing_suspect=J` in the summary) so hard misses — like the
   Business-Suite echo class — stay a clean signal. (These self-heal as echo
   rows only while `message_echoes` delivery works, i.e. exactly not during
   the outages recon watches for — hence label, don't suppress.)
4. **Summary emitted from an `ensure` per platform** — it exists on every
   path, including failures:
   `[UMI-FBIG] stage=reconcile_summary platform=… threads=N mids=M missing=K threads_failed=F caps_hit=C [error=<class>]`.
   `missing=K` is always the full count (only the per-mid lines are capped),
   and is a **windowed re-count**: a 48 h window × daily cadence re-reports a
   still-missing mid ~2×, so the future alert must treat `missing>0` as the
   signal, not accumulate counts across days.

Failure semantics (from the failure-modes review):

- `Koala::Facebook::AuthenticationError` → summary with `error=auth`,
  **no re-raise and skip the remaining platform** — a 401 is not transient;
  3× daily Sidekiq retries would add sustained 4xx against Meta (which is
  itself a subscription-health risk) and dead-set churn with no Sentry in
  prod. The send path owns reauth semantics; recon never calls
  `authorization_error!`.
- Other per-thread errors → rescue, `threads_failed` count, continue.
- Platform-level non-auth errors → summary with `error=<class>`, continue to
  the next platform, then re-raise once so Sidekiq's retry covers genuine
  transients.

Constants (deliberately not env: the window is structurally coupled to the
hardcoded daily cadence — exposing one without the other invites breaking the
double-cover invariant): `WINDOW_HOURS = 48`, `RECENT_GRACE_MINUTES = 15`
(in-flight webhooks aren't "missing"), `MAX_THREAD_PAGES`, `MAX_MESSAGE_PAGES`,
`MAX_MISSING_LINES`, `OUT_OF_WINDOW_STOP = 3`.

`Umi::Fbig::ConversationReconJob` — iterates `Channel::FacebookPage`,
per-channel isolation; **first line of `perform` re-checks the kill switch**
(a job already enqueued before a disabling restart must no-op). Queue: `low`
(serial HTTP for minutes must not hold a default-queue worker).

Cron: daily **20:30 UTC (03:30 Bangkok, off-peak)**, registered in
`config/initializers/zz_umi_fbig_recon.rb` mirroring the proven
`zz_umi_shopify_contacts.rb` pattern exactly: `after_initialize` +
`next unless Sidekiq.server?`, fixed job name `umi_fbig_recon`, per-job
`Sidekiq::Cron::Job.new(...).save` with `source: 'umi'` (**never**
`load_from_hash!` — its purge is hardcoded to source "schedule" and would wipe
the core cron), loud tracker+log on save failure, and an explicit
`Sidekiq::Cron::Job.destroy('umi_fbig_recon')` in the disabled branch (a
previously-registered cron persists in Redis — a no-op branch leaves a zombie
schedule firing).

**Default ON, kill switch `UMI_FBIG_RECON_DISABLED=true`.** The precedent is
patch #8 (read-only observability, default-on, opt-out), not patch #7's
opt-in — #7 defaults off because it *writes* the CRM; recon's blast radius is
log lines and ~dozens of read calls against a ~4800/day page budget.

## Phase 2 — auto-heal (in this patch, flag-gated, default OFF)

`UMI_FBIG_RECON_HEAL=true` enables replay of **inbound hard misses only**
(`direction=in`; `suspect=multipart` is an outbound-only class), capped at
`MAX_HEALS_PER_PLATFORM = 10`. `Umi::Fbig::MessageHealService` per missing mid:

1. Fetch content: `GET /{mid}?fields=id,created_time,from,message,attachments`
   (spike 2026-07-22: works on both platforms, including 7-month-old IG
   messages; a fetch error → `stage=heal_skipped reason=content_unavailable`,
   the detection line remains).
2. Re-check the mid is still missing (a late webhook may have won the race),
   then synthesize the **webhook-shaped messaging payload** and feed it
   through the exact existing pipeline — `Instagram::Messenger::MessageText`
   (IG) / `Integrations::Facebook::MessageParser` +
   `Messages::Facebook::MessageBuilder` (FB) — reusing contact creation
   (incl. patch #10's fallback contact), conversation selection, dedup and
   attachment handling (incl. patch #11's resilience; late-fetched CDN URLs
   may be dead and must degrade, not destroy).
   API attachment shapes map to webhook shapes best-effort
   (`image_data`→image, `video_data`→video, `file_url`→file); unmappable
   attachments are skipped with the text still healed.
3. Mark the recovered row (`content_attributes.umi_recovered: true`) and log
   `stage=healed mid=… message_id=…`; summary gains `healed=H heal_failed=…`.

Known heal limitations (accepted): the recovered message's `created_at` is
the heal time, not the original send time — it appears late in the thread
(the builders don't take historical timestamps without a core edit; the
original timestamp is preserved in the log line and Meta's thread). Residual
race with a simultaneously-arriving webhook is bounded by the ≥15 min grace
and a just-before-write existence re-check (FB builder has no source-id dedup
of its own). Concurrent healers for the same channel/platform/mid are
serialized by a 15-minute Redis owner lock and return `heal_in_progress` when
another healer owns it. Outbound/echo healing is deliberately excluded until
real reports show the multipart-suspect labeling is reliable.

The retired one-time history importer formerly shared a per-channel writer
lock with healing. That lock and its importer-only skip result were removed
with the importer; no supported archive writer remains to acquire it. The
narrow healer owner lock above preserves same-message replay serialization
without carrying migration coupling. Patch 17's partial unique Active Storage
index still enforces at most one `avatar` attachment per Contact across
ordinary and healer writes.

Rollout: deploy with the flag **off**, watch a few days of detection
summaries, then enable via env + restart.

### What this patch deliberately does NOT do

- **No token-health side effects** (no `authorization_error!` from the read
  path).
- **No message content in logs** — content is fetched only when healing, and
  only ids ever reach the log lines.
- **No outbound healing** (see above).

## Alternatives rejected

- **Webhook-side-only assurance** (status quo): cannot see Meta-never-delivered.
- **Meta's Messaging Insights / delivery graphs**: dashboard-only, no
  per-message resolution.
- **Full-history comparison**: flags pre-integration history (spike-proven)
  and grows unbounded; the windowed comparison fully answers "are we currently
  losing messages".
- **Auto-import in phase 1**: write-risk without evidence of need.
- **Per-missing-mid detail fetches for direction**: obsoleted by `from` riding
  the bulk listing (spike-proven); also removed an N+1 that would have
  amplified a false-positive storm into a Graph-budget problem.

## Implementation notes (pinned by review)

- Koala calls use the in-repo precedent
  (`api/v1/accounts/callbacks_controller.rb:37-48`): args as an **explicit
  positional hash** — `get_connections(page_id, 'conversations',
  { platform: …, fields: …, limit: 50 })` — never trailing kwargs (Ruby-3
  kwarg/positional ambiguity), and pagination via
  `while collection.respond_to?(:next_page) && (np = collection.next_page)`.
- Anti-join scope: account-scoped is belt-and-braces; the spike showed mids
  are globally unique in practice (observation, not a constraint — the index
  is non-unique), and a duplicate reads as "present", the safe direction.

## Known limitations (stated, not silent)

- ~~Deploy fragility of the daily burst~~ — resolved: containers log via the
  journald driver (umi-vps-infra, 2026-07-22), which captures lines instantly
  and survives deploys; there is no cron-capture window anymore.
- **IG unsupported-only inbound** is intentionally dropped by upstream with
  no row (`base_message_builder.rb:101`: blank text + every attachment type ∈
  {template, unsupported_type, ephemeral}) — recon reports these as
  `direction=in` missing. Rare; can't be distinguished API-side without
  fetching content (which we don't). Triaged by grep; the line cap bounds it.
  The FB builder has no such skip (always creates a row).
- **Reactions**: IG job only handles `message`/`read` — the design assumes
  reactions do not appear as separate entries in the `/messages` edge; if
  Meta ever lists a reaction-mid there, it would false-positive as missing
  (expected, not a bug).
- `missing=K` counts message ids, not distinct incidents (windowed re-count —
  see above). Two *consecutive* failed daily runs can gap coverage (one
  cannot — 48 h window); Sidekiq retries mitigate.

## Test plan

Service specs with stubbed Koala: windowed thread pagination with the
3-consecutive stop (including an out-of-order thread that must NOT stop the
scan); message pagination stop; account-scoped anti-join (seed matching +
missing + foreign-account mid); direction + sender from listing `from`; grace
exclusion; per-thread error → `threads_failed` + continue; auth error →
summary `error=auth`, no raise, second platform skipped; missing-line cap;
`suspect=multipart` labeling (missing out-mid with a nearby outgoing row is
tagged and counted in `missing_suspect`, without one it stays a hard miss);
summary always emitted (ensure path) with full `missing=K`. Job spec: channel
iteration + kill-switch no-op. Initializer: registration guard mirror.

## Files

- `umi/app/services/fbig/conversation_recon_service.rb` → `Umi::Fbig::ConversationReconService`
- `umi/app/services/fbig/message_heal_service.rb` → `Umi::Fbig::MessageHealService`
- `umi/app/jobs/fbig/conversation_recon_job.rb` → `Umi::Fbig::ConversationReconJob`
- `config/initializers/zz_umi_fbig_recon.rb`
- `spec/services/umi/fbig/conversation_recon_service_spec.rb`,
  `spec/services/umi/fbig/message_heal_service_spec.rb`,
  `spec/jobs/umi/fbig/conversation_recon_job_spec.rb`
- `UMI-PATCHES.md` row 12

The independently useful Contact-avatar database invariant is registered as
`UMI-PATCHES.md` row 17.

The service logs through its own private helper (same `[UMI-FBIG]` prefix)
rather than `Umi::FbigTrace`, keeping patch #12 removable independently of
patch #8.

Remove-when: upstream ships webhook-delivery reconciliation for Meta channels,
or Meta provides delivery guarantees/replay.
