# UMI: Proactive Shopify → Chatwoot contact sync — investigation

**Status:** investigation / recommendation only. No code. If we proceed, the next step is a
spec (`UMI-SHOPIFY-CONTACT-SYNC-SPEC.md`) + multi-agent review, per the fork pipeline.

**Question:** should we proactively sync **all** customers from the connected Shopify store
into Chatwoot as contacts, instead of the current default where a Shopify customer only
surfaces in Chatwoot reactively — when they message us and the integration looks them up?

**TL;DR recommendation:** yes, but scoped: a **one-time throttled backfill + a scheduled
incremental poll** (watermark on Shopify `updated_at`), *not* a webhook-driven live sync, and
*not* unconditionally — skip customers with neither email nor phone, dedup phones at the
application level (no DB constraint protects them, §2b), never overwrite agent-entered
data, and verify + handle the `customers/redact` compliance webhook before shipping.
At UMI's store size this is cheap and it is the only option that combines **first-call /
first-message customer recognition** (without putting a live Shopify call in the ring
path — see Option B2) with **outbound click-to-call reach and customer-base segmentation**.
The design should mirror the existing help-center sync patch (patch #3) and the core
`DataImportJob` bulk-import machinery. If the store were 100k+ customers the cost calculus
changes (GraphQL bulk operations, list bloat) — quantified in §6.

---

## 1. Current behavior — confirmed reactive-only (and less than that)

The assumption holds, and is actually *weaker* than "reactive linking". The Shopify
integration never creates, updates, or links a Chatwoot contact at all. There is no
persisted association in either direction — not even the Shopify customer id.

The full OSS surface (v4.14.2):

- `app/controllers/api/v1/accounts/integrations/shopify_controller.rb`
  - `auth` — builds the OAuth authorize URL with `REQUIRED_SCOPES`.
  - `orders` (`shopify_controller.rb:24`) — called by the conversation sidebar
    (`ShopifyOrdersList.vue` via `ContactPanel.vue`) for an **existing** Chatwoot contact.
    It live-queries `customers/search.json` with `email:<contact.email> OR
    phone:<contact.phone_number>` (`fetch_customers`, `shopify_controller.rb:55`), takes the
    **first** match, and fetches that customer's orders. The result is rendered and
    discarded — nothing is written to the contact.
  - `destroy` — removes the `Integrations::Hook`.
- `app/controllers/shopify/callbacks_controller.rb` — OAuth callback; stores the offline
  access token + granted scopes on `Integrations::Hook` (`app_id: 'shopify'`,
  `reference_id: <shop domain>`).
- `app/controllers/webhooks/shopify_controller.rb` — HMAC-verified webhook endpoint
  (`POST /webhooks/shopify`, `routes.rb:626`) that currently handles **only**
  `shop/redact` (deletes the hook). `customers/data_request` and `customers/redact` are
  received-and-ignored.
- Gating: `shopify_integration` feature flag + `SHOPIFY_CLIENT_ID`/`SECRET`
  InstallationConfig (`app/models/integrations/app.rb:122`).

Contacts themselves are only ever created by the inbound-message path — each channel calls
`ContactInboxWithContactBuilder` (`app/builders/contact_inbox_with_contact_builder.rb`),
which dedups by `identifier` → `email` → `phone_number` (`find_contact`, line 62) and
otherwise creates a fresh contact (with a random Haikunator name if the channel provides
none). So today a Shopify customer "becomes" a Chatwoot contact only by messaging us, and
the "link" to Shopify is re-derived from email/phone on every sidebar render.

Two consequences worth naming:

1. **The reactive lookup stays fresh by construction** — it hits the Admin API live. Any
   proactive copy we store is, by definition, staler than what the sidebar already shows.
   Proactive sync is therefore *not* about order-data freshness; it's about existence,
   identity, and reachability of the contact before first inbound contact.
2. **The builder's email/phone dedup is what makes proactive sync safe**: a pre-synced
   contact with the customer's email/phone is automatically reused when that customer later
   writes in via email, WhatsApp/Twilio (phone), or a pre-chat form — no duplicate, and the
   agent sees the real name + orders sidebar immediately. Channels that carry neither email
   nor phone (LINE, Instagram, anonymous widget) will still create a separate contact and
   need a manual merge — proactive sync does not fix that, and nothing can, short of asking.

## 2. In-repo precedents to model on

### 2a. Help-center sync (UMI patch #3) — the bulk-job template

`umi/app/services/shopify/help_center_sync_service.rb`, `umi/app/jobs/shopify/help_center_sync_job.rb`,
`lib/tasks/umi_help_center.rake`, `config/initializers/zz_umi_shopify_help_center.rb`.
Everything a customer sync needs is already proven here:

- **Token reuse:** builds `ShopifyAPI::Clients::Rest::Admin` from the account's existing
  `Integrations::Hook` (`hook.reference_id` + `hook.access_token`) — same as the orders
  sidebar. No second OAuth app, no new secret.
- **Scope guard:** checks `hook.settings['scope']` before doing anything and no-ops with one
  log line if missing. **A customer sync is even easier: `read_customers` is already in the
  base `REQUIRED_SCOPES` (`app/helpers/shopify/integration_helper.rb:2`), so no scope
  extension and no reconnect are needed for read-only sync.** (Writing back to Shopify would
  need `write_customers` — out of scope here.)
- **`Context.setup` thread-safety:** `ShopifyAPI::Context.setup` reloads a shared Zeitwerk
  loader; concurrent Sidekiq threads race it. The service serializes setup with a class
  mutex (`CONTEXT_SETUP_MUTEX`, service line 15) and never uses `Context.setup?` as a guard
  (it raises before first setup). A customer sync must reuse this helper — ideally extracted
  to a shared `Umi::Shopify::ClientFactory` instead of copy-pasted (memory:
  `shopify-context-setup-gotchas`).
- **Error taxonomy:** 429/5xx re-raise → Sidekiq retries with backoff (eventually
  consistent); 4xx are permanent → report once via `ChatwootExceptionTracker`, skip, don't
  poison-retry (`handle_http_error`, service line 66).
- **Throttled backfill:** the rake task staggers job enqueues (`wait: index * spacing`,
  default 3–5 s) to thin the burst under Shopify's leaky bucket, and is idempotent so
  re-running repairs rather than duplicates. Its known weakness — a per-item N+1 metafield
  scan that caused 429s — does **not** apply to customers: one `customers.json` page returns
  250 full customer records with no sub-requests needed. (That's a REST property; a GraphQL
  variant pays per-object query cost instead — re-price if the spec goes GraphQL.)

### 2b. `DataImportJob` — the bulk contact-creation template

Chatwoot core already bulk-creates contacts from CSV (`app/jobs/data_import_job.rb` +
`DataImport::ContactManager`): validates each row, then
`Contact.import(..., on_duplicate_key_ignore: true, validate: true, batch_size: 1000)`
(line 77). Notables for us:

- `activerecord-import` **skips per-record AR callbacks** — no `contact_created` event
  storm, no per-contact webhook dispatch, no ip_lookup jobs. For a thousands-row backfill
  that's the right default (and it's what upstream chose); the incremental sync (small
  batches) can use normal `save` so events fire. Two corollaries the spec must own:
  callbacks skipped means `before_save` `Contacts::SyncAttributes` never runs, so
  `contact_type: :customer` and any location denormalization must be set explicitly on the
  imported attributes; and `import(validate: true)` **does not run uniqueness validations**
  (activerecord-import skips them by default).
- `on_duplicate_key_ignore` + the unique indexes on `lower(email), account_id` and
  `identifier, account_id` give race-safe dedup at the DB layer **for email and identifier
  only. There is no unique index on `(phone_number, account_id)`** — phone uniqueness is
  purely an application-level validation, which bulk import bypasses (above). Two Shopify
  customers sharing a phone, or a phone-only import racing the inbound builder, would create
  duplicate phone rows that fail validation on every later save and make
  `find_by(phone_number:)` non-deterministic — which would poison exactly the caller-ID
  lookup this sync exists to serve (`umi/app/services/voice/inbound_resolver.rb:16`). The
  sync must therefore dedup phones in-memory within each batch **and** check for an existing
  contact per phone before insert.
- `DataImport::ContactManager` is a template for *structure*, not semantics: its
  update path unconditionally saves every matched existing contact (per-row
  `dispatch_update_event` → webhook per contact) and **overwrites `name` last-write-wins**
  (`app/services/data_import/contact_manager.rb:62`) — both contradict the fill-blanks-only
  conflict rule in §5. The enrichment pass must be new code that skips no-change saves.
- Phone must be strict E.164 (`\+[1-9]\d{1,14}`, `contact.rb:56`) and email must match the
  Devise regexp — Shopify data is dirtier than that, so the sync must normalize or drop
  invalid values per field (precedent: `Contact#discard_invalid_attrs`).

### 2c. Existing plumbing that helps

- `Contact.contact_type` enum has a `customer` value (`contact.rb:71`) — synced customers
  can be typed correctly (organic widget visitors default to `visitor`/`lead`).
- Labels (`Labelable`) — tag everything `shopify` so segments/filters can include or
  exclude the imported population in one click.
- `Internal::RemoveStaleContactsService` deletes only contacts with **no**
  email/phone/identifier and no conversations — synced contacts (which we'll require to
  have email or phone, §7) are never eligible. No fight between cleanup and sync.
- The webhook endpoint + HMAC verification already exist; adding topics is a `case` branch.

## 3. What proactive sync actually buys (and doesn't)

| Capability | Reactive today | With proactive sync |
|---|---|---|
| Orders sidebar for a contact who wrote in | ✅ live, always fresh | ✅ unchanged (keep the live lookup) |
| Agent sees real name/history when a known customer's **first** message arrives with email/phone | ⚠️ only what the channel provides | ✅ pre-linked via builder dedup |
| **Inbound voice caller-ID** (patch #4 injects `call.contact&.name` into `Remote-Party-ID` at TwiML-render time, synchronously — `umi/app/controllers/voice/webhooks_controller.rb:19`) | ⚠️ first-time caller shows as their bare phone number (`inbound_call_builder.rb:43` names the contact after the number) | ✅ real name on the softphone on the first-ever call |
| Outbound-first workflows: click-to-call / new conversation to any customer | ❌ contact doesn't exist yet; agent must create it by hand | ✅ every customer reachable from Chatwoot |
| Search/segment the customer base inside Chatwoot (e.g. "all customers in Bangkok with >3 orders") | ❌ | ✅ (attributes permitting) |
| LINE / IG / anonymous-widget dedup | ❌ | ❌ (no email/phone on those channels) |
| Order-data freshness | ✅ live | ⚠️ snapshot; keep sidebar live and treat synced order stats as approximate |

The voice row deserves precision, because it was the headline driver of an earlier draft:
caller-name injection is synchronous (the Twilio webhook builds the `<Dial>` TwiML with the
name inline while the call is ringing), so an *async* enrichment job can never help the
first call. But "only a pre-existing contact row helps" is too strong — a **timeboxed live
lookup** (`customers/search.json?query=phone:<caller>` inside the incoming-call webhook,
Twilio allows ~15 s for TwiML) could also deliver first-call caller-ID with no import at
all. That alternative is evaluated as Option B2 below. Pre-sync wins that comparison on
latency and on not coupling the ring path to Shopify availability — not on exclusivity.
Given UMI runs phone-first support in Thailand (Twilio voice + WhatsApp on +66975311301),
first-call recognition in some form is still the strongest concrete driver.

## 4. Options considered

- **A. Status quo (reactive only).** Zero cost, zero risk, none of the §3 gains.
- **B. Lazy persistence ("sync on touch").** When the orders sidebar (or an inbound-message
  hook) finds a Shopify match, persist `shopify_customer_id` + enrich the contact. Cheap,
  no bulk import, minimal privacy surface (data persisted only for people who contacted us)
  — but only enriches after first touch, so no outbound reach and no customer-base search.
  Caveat: the sidebar's `customers.first` from a loose `email:X OR phone:Y` query is fine
  for a transient render but **not** for persisting a durable link — persist only on exact
  email/phone equality with the returned record. Worth doing *anyway* as part of any option,
  but insufficient alone.
- **B2. Live lookup in the hot paths, no import.** Synchronous, timeboxed (~500 ms budget,
  fall back to the bare number) Shopify phone-search inside the incoming-call webhook, plus
  an async on-`contact_created` enrichment for messaging channels. Gets first-call
  caller-ID and first-message recognition with zero list bloat and no redact obligation for
  never-contacted customers. Costs: puts a third-party API call (and its p99, and its
  outages, and its 2 rps bucket shared with the sidebar) inside the call-setup path;
  Shopify's phone search must match Thai number formats reliably; still no outbound reach
  or segmentation. A reasonable fallback position if the import is rejected — but it trades
  a background data problem for a runtime availability problem in the most latency-sensitive
  path we have.
- **C. One-time backfill + scheduled incremental poll.** Recommended; detailed in §7.
  Compared with B2: recognition comes from a local indexed lookup (no runtime Shopify
  dependency), and it's the only option that enables outbound click-to-call reach and
  base segmentation.
- **D. C + live `customers/create|update` webhooks.** Best freshness (seconds vs. poll
  interval), but adds webhook-subscription lifecycle (registration after OAuth, re-registration
  on reconnect, missed-delivery reconciliation — Shopify webhooks are at-least-once with
  retries, and subscriptions vanish on app reinstall), and Chatwoot contact identity changes
  rarely enough that a 15–60 min poll is indistinguishable in practice. Defer; the poll's
  watermark design (§7) is forward-compatible with adding webhooks later.

## 5. Pros / cons analysis (requested dimensions)

### Data freshness
- **Pro:** contact identity (name, email, phone, marketing consent, order aggregates) exists
  before first contact; the live orders sidebar stays the freshness source for order detail.
- **Con:** any copied field can rot between syncs. Mitigation: sync only slow-moving fields;
  keep order *lists* out of the contact entirely (sidebar already does live); incremental
  poll bounds staleness to the poll interval. Conflict rule required: Shopify updates must
  not clobber agent edits (recommend: fill blanks + update Shopify-owned
  `additional_attributes` only, never overwrite `name`/`email`/`phone` that an agent changed
  — track "Shopify-managed" fields, or simplest: only write fields that are blank or still
  equal to the last-synced value stored in `additional_attributes`). One deliberate
  exception: **placeholder names must count as blank**, or enrichment never upgrades anyone
  who contacted us before the backfill — reactively-created contacts are never nameless
  (voice names them after the phone number, `inbound_call_builder.rb:43`; the builder falls
  back to a random Haikunator name). Core has the precedent:
  `Twilio::IncomingMessageService` overwrites the name exactly when
  `contact.name == phone_number` (`app/services/twilio/incoming_message_service.rb:211`).

### API rate-limit / cost impact (thousands → millions)
- REST `customers.json` returns 250/page with cursor (`page_info`) pagination; standard-plan
  REST bucket is 40 requests, leaking 2/s. Single-threaded, that's ~500 customers/s
  *sustained* worst-case:
  - 1k customers ≈ 4 requests — seconds.
  - 10k ≈ 40 requests — under a minute.
  - 100k ≈ 400 requests — a few minutes.
  - 1M ≈ 4,000 requests — ~35 min, and REST pagination that deep gets fragile.
- At ≥~100k the right tool is a **GraphQL bulk operation** (`bulkOperationRunQuery` →
  Shopify assembles a JSONL file offline, one poll + one download, effectively no rate-limit
  interaction). Also relevant: Shopify has marked the REST Admin API legacy (GraphQL is the
  forward path for customer/order objects) — the fork's REST usage on `2025-01` keeps
  working for a custom app, but a new sync is a natural place to consider GraphQL from the
  start. **Verify current deprecation timelines + plan-specific limits at spec time.**
- Incremental poll cost is trivial at any scale: `customers.json?updated_at_min=<watermark>`
  returns only changed customers; a quiet store costs 1 request per poll.
- Chatwoot-side cost: `Contact.import` batches of 1000 are the proven path; millions of rows
  would also bloat pg indexes and every per-account contact query — see bloat below. UMI's
  actual store is nowhere near that; the backfill should log `customers/count.json` first
  and abort above a configurable ceiling as a guard.

### Privacy / consent
- These are UMI's own customers, moved between two systems UMI already controls (Shopify =
  processor of record, Chatwoot = self-hosted support tool). Under GDPR-style analysis
  (Thailand PDPA is closely modeled on it) this is a compatible internal purpose /
  legitimate-interest processing — importing is defensible. But three obligations become
  real the moment we import people who never contacted us:
  1. **Erasure:** the `customers/redact` topic is ignored today
     (`webhooks/shopify_controller.rb` handles only `shop/redact`). Post-import, that's a
     compliance bug: the handler must delete/anonymize the matching Chatwoot contact (the
     payload carries the customer id + email/phone to match on). This is a **must-fix within
     the same patch** — with a deployment caveat: compliance webhooks are only *delivered*
     if the endpoint URLs are configured in the app's Partner Dashboard setup (or
     `shopify.app.toml`); admin-created custom apps never receive them at all. No code in
     this repo can make that happen, so the spec needs a verification step: confirm UMI's
     app type and that its compliance-webhook URLs point at `POST /webhooks/shopify`
     (HMAC-signed with the same `SHOPIFY_CLIENT_SECRET` the controller already verifies).
     The handler must also survive the hook being already gone (Shopify can deliver
     `customers/redact` after uninstall, and `shop/redact` deletes the hook) — single-tenant
     fallback: match by email/phone across the one account, or log loudly.
     `customers/data_request` should at least log actionably.
  2. **Marketing consent ≠ service contact.** Shopify's `email_marketing_consent` /
     `sms_marketing_consent` must be carried onto the contact (e.g.
     `additional_attributes['shopify_accepts_marketing']`) and respected before anyone uses
     the imported base for campaigns/broadcasts. Import for support ≠ license to blast.
  3. **Data minimization:** import identity + a few aggregates, not addresses/order lines.
     Less copied = less to keep fresh, less to redact, less to leak.
- Shopify-side: "protected customer data" requirements apply to app review for App
  Store-distributed apps; a store-owned custom app is exempt from the review process but
  still bound by the data-protection terms. UMI's app is its own — fine, note it in the spec.

### Contact-list bloat / agent workflows / search
- Every synced customer has email or phone → all are "resolved" contacts → **the default
  contacts view will show the entire customer base**, and its count becomes "customers"
  rather than "people we've talked to".
- Mitigations that fall out of existing features: default sort is `last_activity_at DESC
  NULLS LAST`, so never-active imports sink below every real conversation partner; the
  `shopify` label + saved segments give agents a one-click "has talked to us" vs "all
  customers" split; `contact_type: customer` keeps them distinguishable programmatically.
- Search: the contacts search is `ILIKE '%q%'` over name/email/phone/identifier backed by a
  GIN (trigram) index — fine at thousands, degrades gracefully at tens of thousands. At
  millions of imported rows per account, search UX and the conversations "new conversation"
  contact picker both get noticeably noisier and slower — another reason the ceiling guard
  matters more than clever engineering at UMI scale.
- Agent-workflow risk: duplicate-looking results (imported "Somchai P." + LINE contact
  "somchai_bkk") until merged. Reactive-only has the same problem, just later; the label at
  least tells the agent which row carries the order history.

### Staleness handling
- **Watermark poll:** store `last_synced_at` per hook; every N minutes fetch
  `updated_at_min=watermark - safety_overlap`, upsert, advance watermark only after a fully
  successful page run. That ordering is **load-bearing correctness, not caution**: REST
  customer results are id-ordered and cannot be sorted by `updated_at`, so a partial run
  that advanced the watermark would drop updates permanently. Idempotent by
  `shopify_customer_id`; a crashed run re-fetches overlap harmlessly.
- **Watermark storage:** `hook.settings` is feasible (the shopify app has no
  `settings_json_schema`, and the OAuth callback already stores `scope` there) but has two
  named hazards: the generic hooks-update endpoint replaces `settings` **wholesale**
  (`api/v1/accounts/integrations/hooks_controller.rb:10` — a UI/API settings write would
  silently wipe both watermark and `scope`), and reconnecting the integration
  destroys/recreates the hook, losing the watermark (survivable — missing watermark must
  mean "backfill needed", never "sync from epoch"). It also races the OAuth reconnect's own
  settings write. The spec must pick storage deliberately (merged `hook.settings` writes vs.
  a dedicated key/table).
- **Deletes:** polling can't see deletions (`updated_at_min` never returns a deleted
  customer). Scope webhook handling to **`customers/redact` only** — needed for compliance
  regardless, and delivered via Partner-Dashboard configuration with no subscription code.
  `customers/delete`, by contrast, is an ordinary API-subscribed topic: handling it would
  re-import exactly the subscription-lifecycle machinery Option D was deferred to avoid, so
  it's out — orphaned contacts from non-redact deletions wait for the full reconcile.
- **Weekly full reconcile** (re-run the backfill) is cheap at UMI scale and catches
  everything polling missed; make it a rake task like `umi:help_center:backfill`, not a cron
  default, until proven needed.

### What a reliable backfill + incremental sync needs (checklist for the spec)
1. Shared `Umi::Shopify` client factory (hook lookup, scope check, mutex-guarded
   `Context.setup`, REST client) extracted from the help-center service.
2. Backfill job: count guard → paginate 250/page single-threaded → normalize (E.164 phone,
   email downcase/validate, skip customers with neither) → **dedup phones in-memory within
   each batch and against existing contacts** (no unique index protects phone, §2b; decide
   at spec time: add a fork migration making `(phone_number, account_id)` unique, or
   serialize the phone-upsert path) → `Contact.import` batches with
   `on_duplicate_key_ignore` → second pass (or upsert logic) to enrich pre-existing contacts
   by email/phone match without overwriting agent data (placeholder names count as blank,
   §5; skip no-change saves so reconciles don't fire an update-webhook per contact).
   Because bulk import skips callbacks, set explicitly what `before_save` would have done:
   `contact_type: :customer`, and the `location`/`country_code` **columns** if city/country
   go into `additional_attributes` (`Contacts::SyncAttributes` won't run — without this the
   "customers in Bangkok" segmentation doesn't actually work). Resumable: persist
   `page_info` or re-run idempotently. 429/5xx → retry with backoff; 4xx → stop loud.
3. Identity: store `shopify_customer_id` in `additional_attributes` (dedup/merge key on our
   side). **Leave `Contact#identifier` alone** — it's the API-channel identity slot and the
   first key the inbound builder matches on; occupying it couples us to a core semantic we
   don't control.
4. Incremental poll job every 15–60 min. Scheduling is solved in-repo: sidekiq-cron ships in
   the Gemfile and `config/schedule.yml` is loaded at Sidekiq boot via
   `Sidekiq::Cron::Job.load_from_hash!` (`config/initializers/sidekiq.rb:36`). **Register
   the UMI job with `Sidekiq::Cron::Job.create` from a `zz_umi_*` initializer — never via
   `load_from_hash!`**: in sidekiq-cron 2.4.0 that method's purge filter is hardcoded to
   jobs tagged `source: "schedule"` regardless of the `source:` option you pass, so a
   second `load_from_hash!` call would destroy the entire core schedule on every Sidekiq
   boot (spec-review finding). A single `create` with `source: 'umi'` is safe in both
   directions (the core loader's purge ignores non-`schedule` jobs). Watermark + overlap,
   same upsert path, per-run cap with carry-over.
5. `customers/redact` handler in `Webhooks::ShopifyController` — ship in the same patch.
   Decide **anonymize vs. delete** deliberately: `Contact` has
   `has_many :conversations, dependent: :destroy_async` (`contact.rb:59`), so "delete"
   erases the conversation history / agent audit trail too. Handler must survive the hook
   being absent (§5 privacy).
6. Config knobs (ENV, per fork convention): enable flag, poll interval, backfill ceiling,
   spacing. All inert-by-default so the patch is a no-op until switched on.
7. `UMI-PATCHES.md` row with remove-when: "upstream ships native Shopify customer sync" (the
   integration surface suggests upstream may grow one — re-check on every rebase).
8. Specs: normalization, dedup/enrich-not-overwrite, watermark advance, redact handler.

## 6. Scale decision matrix

| Store size | Backfill | Incremental | List/search impact | Verdict |
|---|---|---|---|---|
| ≤10k (UMI today) | REST pages, minutes | poll, trivial | negligible | ✅ do it |
| 10k–100k | REST OK, run off-hours | poll, trivial | noticeable list inflation; segments required | ✅ with ceiling raised deliberately |
| ≥100k–millions | GraphQL bulk operation only | webhooks start to pay for themselves | search/picker degradation, pg bloat, redact-handling at volume | ⚠️ re-spec: import a *segment* (recent purchasers, opted-in) rather than "all", or don't |

"Sync ALL contacts" is the right call **because** UMI is small. The same patch should refuse
to be the wrong call elsewhere — hence the count guard rather than trusting the operator.

## 7. Recommendation

Proceed with **Option C, phased**, as a new UMI patch modeled on patch #3:

1. **Phase 0 (independent, do regardless):** verify the app's compliance-webhook
   configuration in the Partner Dashboard actually delivers to `POST /webhooks/shopify`
   (test with a real delivery — a handler nothing calls is the worst compliance mode),
   implement the `customers/redact` handler, and add lazy on-touch persistence of
   `shopify_customer_id` in the orders-sidebar path (persist only on exact email/phone
   equality, not `customers.first` from the OR-query).
2. **Phase 1:** shared client factory + idempotent backfill rake task (inert until run),
   ceiling-guarded, labels + `contact_type: customer`, fill-blanks-only enrichment.
3. **Phase 2:** incremental watermark poll on a 30 min cadence.
4. **Not now:** create/update webhooks, GraphQL migration, write-back to Shopify, syncing
   order lines onto contacts (sidebar already does this live), any campaign use of the
   imported base (blocked on consent review).

Primary drivers: first-call caller-ID and first-touch recognition served from a **local**
lookup (B2 could deliver the recognition too, but only by coupling the ring path to
Shopify's availability and rate bucket), plus the two things no reactive/live variant can
provide — outbound click-to-call reach to the whole customer base and in-Chatwoot
segmentation. Primary risks accepted: contact-list inflation (mitigated by sort/label/
segments) and a second Shopify sync surface to maintain across rebases (mitigated by
sharing the client factory and keeping the patch inert-by-default).

## 8. Open questions for the spec stage

- Actual customer count + growth rate of the UMI store (sets the ceiling; `customers/count.json`).
- REST vs GraphQL for the new code path, given Shopify's REST-legacy direction — verify
  current guidance/limits for custom apps on `2025-01`+ at spec time.
- UMI's Shopify app type (Partner-created vs. admin-created custom app) and whether the
  compliance-webhook endpoints are configured — admin-created custom apps never receive
  `customers/redact` at all, which changes the erasure story to a manual runbook.
- Redact policy: anonymize (keep conversations, strip PII) vs. delete (destroys the
  conversation history via `dependent: :destroy_async`).
- Phone dedup enforcement: fork migration adding a unique index on
  `(phone_number, account_id)` (also protects the inbound-builder race) vs. app-level-only.
- Whether to auto-create a `shopify` label vs. reuse an existing taxonomy.
- Merge policy details for conflicting phone/email (same phone on two Shopify customers,
  Shopify phone stored on address instead of customer, non-E.164 Thai local formats).
- Whether `customers/data_request` needs a real export path (likely: log + manual, given
  self-hosted single-tenant).
