# UMI: Shopify → Chatwoot contact sync — spec

**Status:** implementation spec, derived from `UMI-SHOPIFY-CONTACT-SYNC-INVESTIGATION.md`
(read that first — it carries the pros/cons, alternatives rejected, and scale analysis).
Reviewed by three independent lenses (feasibility, failure-modes, scope); their must-fixes
are folded in below and marked *(review)* where the design changed.

## 1. Problem

Shopify customers only become Chatwoot contacts reactively (when they message us), and the
integration persists no link either way. UMI wants every store customer to exist as a
Chatwoot contact so that: inbound calls/WhatsApp from a known customer resolve to a real
name on the first touch (voice caller-ID is synchronous — only a pre-existing row helps
without coupling the ring path to Shopify), agents can outbound-call/message any customer,
and the customer base is searchable/segmentable in Chatwoot.

## 2. Approach (agreed in the investigation)

One-time throttled backfill + scheduled incremental poll (watermark on Shopify customer
`updated_at`), REST Admin API `2025-01`, reusing the existing `Integrations::Hook`
(`app_id: 'shopify'`) token — `read_customers` is already granted, no reconnect needed.
Webhooks are **not** used for sync; the only webhook work is the `customers/redact` /
`customers/data_request` compliance topics (delivered via Partner-Dashboard config, not API
subscription). Inert by default: nothing runs until the backfill rake task is invoked, and
the poll only runs when explicitly enabled.

**Ship order** *(review)*: the compliance handler (§3f) and on-touch persistence (§3g) are
independent of the sync machinery and highest-legal-stakes — implement and land them first
in the commit sequence, then factory → mapper → sync engine → backfill → poll.

## 3. Components

All new code in the `umi/` overlay (constants under `Umi::`), initializer
`config/initializers/zz_umi_shopify_contacts.rb`, rake task `lib/tasks/umi_shopify_contacts.rake`.
All prepends happen inside `Rails.application.reloader.to_prepare` with an `include?`
guard, mirroring `zz_umi_voice.rb` (survives dev reloads).

### 3a. `Umi::Shopify::ClientFactory` (`umi/app/services/shopify/client_factory.rb`)

Extract of the help-center service's client construction, **shared** by both patches:

- `hook_for(account_id)` → the shopify `Integrations::Hook` or nil.
- `client_for(hook)` → `ShopifyAPI::Clients::Rest::Admin` for `hook.reference_id` +
  `hook.access_token`, after mutex-guarded `ShopifyAPI::Context.setup`.
- Owns the **single process-wide `CONTEXT_SETUP_MUTEX`**. This is a correctness
  requirement, not DRY: two services with separate mutexes could run `Context.setup`
  concurrently from different Sidekiq threads and reintroduce the Zeitwerk race fixed in
  patch #3 (`Context.setup` reloads the gem's shared loader; `Context.setup?` raises before
  first setup — never use it as a guard).
- `Umi::Shopify::HelpCenterSyncService` is refactored to call the factory. *(review)* Its
  spec's mutex/concurrency examples exercise the service's private
  `#client`/`#ensure_shopify_context!` — those examples **move to the new factory spec**
  (no delegating shims kept); the remaining help-center examples stay green unchanged.

### 3b. `Umi::Shopify::CustomerContactMapper` (`umi/app/services/shopify/customer_contact_mapper.rb`)

Pure mapping/normalization, unit-testable without Shopify:

- Input: one Shopify customer hash. Output: contact attributes or `nil` (skip).
- **Skip** customers with neither a valid email nor a valid phone (unmatchable by any
  channel; would be invisible "unresolved" rows).
- Email: downcase/strip; must match the Devise regexp or is dropped (field-level, not
  row-level). Downcasing is load-bearing: the unique index is on **raw**
  `(email, account_id)` (case-sensitive), dedup relies on consistent casing.
- Phone: must normalize to strict E.164 (`\+[1-9]\d{1,14}`) or is dropped. Shopify may
  store the phone on the default address instead of the customer — fall back to
  `default_address.phone`. Thai local formats (`0xx…`) are **not** guessed into `+66…`;
  Shopify already stores E.164 for checkout-collected phones, and wrong guesses poison
  caller-ID. Non-E.164 values are dropped and counted in the run summary (the counters
  come from the mapper — `Contact.import` won't report field drops).
- Name: `first_name + last_name`, else email local part, else phone.
- `contact_type: :customer` and `location`/`country_code` columns set **explicitly**
  (bulk import skips the `before_save` `Contacts::SyncAttributes` denormalization, and
  `SyncAttributes` never promotes past `lead` on its own).
- `additional_attributes` (Shopify-owned, minimal per data-minimization):
  `shopify_customer_id`, `shopify_orders_count`, `shopify_total_spent`,
  `shopify_currency`, `shopify_tags`, `shopify_accepts_email_marketing`,
  `shopify_accepts_sms_marketing`, `city`, `country`. *(review)* No per-contact
  `shopify_synced_at` — it would defeat no-change detection (every reconcile would differ)
  and its diagnostic value is covered by run counters/logs.

### 3c. `Umi::Shopify::ContactSyncService` (`umi/app/services/shopify/contact_sync_service.rb`)

The upsert engine, used by both backfill and poll. Given a page (≤250) of Shopify
customers for an account and a mode (`:bulk` for backfill, `:per_record` for poll —
*(review)* the poll creates via `Contact.create!` so `contact_created` events fire; bulk
uses `Contact.import` which deliberately doesn't):

1. Map all via the mapper; drop skips.
2. **In-batch dedup**: if two mapped rows share a phone, the **most recently updated**
   customer keeps it *(review — REST pages are id-ordered, oldest-first; the newest record
   is usually the live one)*; the loser keeps its email or is skipped. Same for email.
   There is **no unique index on `(phone_number, account_id)`** (schema fact) — phone
   dedup is entirely our job. No fork migration (schema.rb churn is a rebase hazard; at
   UMI scale app-level dedup + the single-writer lock (§3h) suffices).
3. Bulk-query existing contacts by all emails (`lower(email)`) and phones in the page.
4. Partition: **new** → `Contact.import(validate: true, on_duplicate_key_ignore: true,
   track_validation_failures: true, batch_size: 1000)` (targetless `ON CONFLICT DO
   NOTHING` covers every unique constraint) or per-record `create!` in poll mode.
   **Existing** → enrich individually:
   - **Identity guard** *(review — cross-page identity bleed)*: if the contact already has
     a `shopify_customer_id` **different** from this customer's, do not touch the row —
     count `conflicted`, log both ids. Without this, two customers sharing a phone
     (family/staff — common in a Thai store) flap the contact's identity and aggregates on
     every run, and redact could destroy the wrong person's contact.
   - Fill-blanks only, with one exception: a **placeholder name** counts as blank —
     name == the contact's phone number, name == its **full email or email local part**
     *(review — the mapper's own fallback and the email channel's full-address names must
     be upgradeable later)*, or the Haikunator pattern (`/\A[a-z]+-[a-z]+-\d+\z/i` —
     deliberately narrower than `\w` to misclassify fewer real names). Precedent:
     `Twilio::IncomingMessageService` overwrites when `name == phone_number`. Accepted
     residual risk: a real name matching the Haikunator shape is overwritten (rare;
     noted in §5).
   - **Split-identity guard** *(code review)*: if the customer's email matched contact A
     but its phone already belongs to contact B, the phone is NOT filled into A —
     duplicating a phone across contacts (no unique index prevents it) would make
     caller-ID resolution nondeterministic.
   - **Removals propagate** *(code review)*: the mapper emits sync-owned `shopify_*`
     keys with nil when absent/cleared in Shopify, and the enrich merge deletes the
     stored key (create paths compact) — otherwise a cleared tag/consent would freeze
     stale forever.
   - `additional_attributes`: `contact.reload` immediately before merge+save *(review —
     jsonb writes are whole-column last-write-wins; shrink the window against concurrent
     agent edits)*, merge Shopify-owned keys only, never touch other keys, never overwrite
     non-blank `email`/`phone_number`. Set `contact_type: :customer` unless already
     customer; keep `location`/`country_code` in step with city/country.
   - **Skip no-change saves** (compare before write) so reconciles don't fire an
     update-webhook per contact.
5. Returns counters: `created / enriched / unchanged / conflicted / skipped_no_identity /
   dropped_phone / dropped_email / deduped` (+ import's `failed_instances` count).

### 3d. Backfill: `Umi::Shopify::ContactBackfillJob` + rake task

- `rake umi:shopify_contacts:backfill[account_id]` — acquires the sync lock (§3h; refuses
  loudly if held), then enqueues the first `Umi::Shopify::ContactBackfillJob` (queue
  `:low`) with `run_id` + no cursor.
- Job: guard — hook present, `read_customers` in scope, customer count from
  `customers/count.json` ≤ `UMI_SHOPIFY_CONTACT_SYNC_MAX_CUSTOMERS` (default 20_000; abort
  loud above; log expected page count so a dead chain is diagnosable). Then fetch one page
  (`customers.json?limit=250`; subsequent pages via the response's `next_page_info` —
  `ShopifyAPI::Clients::HttpResponse#next_page_info`, no manual Link parsing), verify the
  lock still holds this `run_id` (abort loud on mismatch — TTL takeover), run
  `ContactSyncService` (`:bulk`), log counters, and **self-enqueue the next page**
  (`set(wait: UMI_SHOPIFY_CONTACT_SYNC_PAGE_WAIT_SECONDS)`) until `next_page_info` is nil.
- **Retry posture** *(review — `config/sidekiq.yml` caps global retries at 3 ≈ a 3-minute
  window)*: ActiveJob `retry_on RetryableError` with polynomial backoff (8 attempts ≈ 78
  min cumulative, within the lock TTL) + a retries-exhausted handler that reports via
  `ChatwootExceptionTracker` **and releases the lock** — a dead chain must be loud, not a
  mystery "backfill needed" log two days later. **Transient = 429/5xx AND transport-level
  errors** *(code review — shopify_api does not wrap `SocketError`/timeouts/`ECONNRESET`/
  SSL/`JSON::ParserError`; unwrapped they'd fall through to the 3-retry global cap and
  strand the lock)*. Every permanent exit (4xx, ceiling, unusable/disabled hook,
  exhausted) releases the lock and pages — the chain owns the lock once the rake task
  hands over. Hard-kill loss of an in-flight job (OSS Sidekiq has no super_fetch) is
  accepted: the lock TTL expires, the failure is visible (watermark absent → §3e alerts),
  and the idempotent re-run repairs.
- The **final** page job writes the watermark = `run_started_at` (carried in job args; not
  completion time — anything updated mid-run is re-fetched by the first poll), then
  releases the lock. *(review)* Watermark write: **re-find the hook by id first**
  (`Integrations::Hook.find_by(id:)`) and merge into its freshly-loaded settings — a stale
  instance would silently UPDATE 0 rows after an OAuth reconnect (destroy+recreate);
  `nil` → loud tracker event, no write.
- 429/5xx → re-raise (Sidekiq retries the same cursor); 4xx → tracker + stop the chain
  loudly, release the lock. Re-running the whole rake task is idempotent (upserts).
- Runbook line (goes in UMI-PATCHES): after a backfill, **verify the watermark exists**;
  its absence means the chain died.

### 3e. Incremental poll: `Umi::Shopify::ContactPollJob`

- Registered from the initializer via **`Sidekiq::Cron::Job.create(name:
  'umi_shopify_contact_poll', cron: ..., class: ..., source: 'umi')`** inside
  `Sidekiq.server?`, only when `UMI_SHOPIFY_CONTACT_SYNC_ENABLED=true`; when the flag is
  off, `Sidekiq::Cron::Job.destroy('umi_shopify_contact_poll')` (also behind
  `Sidekiq.server?`) so disabling doesn't leave a zombie. *(review — MUST NOT use
  `load_from_hash!`: sidekiq-cron 2.4.0 hardcodes its purge filter to `source: "schedule"`
  regardless of the passed option, so a second `load_from_hash!` would destroy the entire
  core `schedule.yml` schedule on every boot. Single-job `create`/`destroy` is safe in
  both directions.)* Cadence `UMI_SHOPIFY_CONTACT_SYNC_CRON` (default `*/30 * * * *`).
- Job (never retried by the adapter — the whole perform body is rescued to the tracker;
  the next cron tick is the retry, avoiding pile-up): for each **enabled** shopify hook
  (disabled hooks are skipped — a stale token must not alert every 30 minutes):
  - Acquire the sync lock (§3h) with a 25-minute TTL; if held (backfill running, or the
    previous poll still running on the starved `:low` queue) → skip this run, log info.
  - No watermark → **`error`-level log every run** *(review — this is the only symptom of
    a dead backfill chain or wiped settings; it must not be a one-time info line)*, skip.
  - Fetch `customers.json?updated_at_min=<watermark - 5.minutes>&limit=250`; *(review)*
    subsequent pages carry **only** `page_info` + `limit` — Shopify 400s when filters are
    combined with a cursor (the filter is baked into the cursor).
  - **Page cap** *(review — a store-wide bulk tag edit bumps `updated_at` on the whole
    base)*: at most `UMI_SHOPIFY_CONTACT_SYNC_POLL_MAX_PAGES` (default 20) pages; if
    exceeded → abort **without advancing the watermark** + tracker alert ("run the
    backfill instead"). Partial advancement is impossible by design (REST results are
    id-ordered, not update-ordered).
  - Upsert via `ContactSyncService` (`:per_record`), advance watermark to this run's start
    time only after all pages succeed (same fresh-hook-reload discipline as §3d), release
    the lock. *(code review)* The write is additionally guarded by lock ownership: a run
    that outlived its 25-min TTL lost the account to a newer tick and must not regress
    the newer watermark with its older start time.
- Clock assumption *(review)*: the watermark is our clock compared against Shopify's
  `updated_at`; the 5-minute overlap absorbs modest skew/visibility lag. The VPS runs
  NTP-synced systemd-timesyncd — verify at deploy; drift > 5 min would drop updates
  silently.
- Deletes: not handled by polling (invisible to `updated_at_min`); non-redact deletions
  wait for a manual backfill re-run. `customers/delete` webhook explicitly out of scope
  (API-subscription lifecycle rejected with Option D).

### 3f. Compliance webhooks (prepend on `Webhooks::ShopifyController`)

`Umi::Webhooks::ShopifyCompliance` prepended in the initializer; overrides `events`:

- **Never 500** *(review)*: the base action only reaches `head :ok` on the happy path; the
  prepended handling wraps its work in `rescue => e` → `ChatwootExceptionTracker` + error
  log, **still returning 200**. A 200 means Shopify never redelivers, so the rescue is the
  last chance to notice — it must be loud.
- **Replay protection** *(security review)*: the HMAC proves origin, not freshness — a
  captured delivery is valid forever. Delivery ids (`X-Shopify-Webhook-Id`) are claimed
  atomically in Redis (7-day TTL); repeats are dropped. Without this, a replayed redact
  could destroy a future contact that reuses the same email.
- `customers/redact`: resolve account via hook `reference_id` == `shop_domain`; fallback
  when the hook is already gone (Shopify may deliver after uninstall; `shop/redact`
  deletes the hook): if exactly one account exists (single-tenant reality) **and the
  shop_domain equals `UMI_SHOPIFY_SHOP_DOMAIN`** *(security review — every shop that
  installs the app shares one signing secret, so an unpinned fallback would let any such
  shop redact contacts in the one account)*, use it; else report to the tracker (manual
  redaction runbook). **Match order matters** *(review)*:
  `additional_attributes->>'shopify_customer_id'` first (unindexed jsonb scan — fine at
  ≤20k, cold path only), then exact email. A **phone-only** match is never destroyed
  (shared phones → could erase a different person's contact + conversations): strip its
  `shopify_*` attributes and **page via the tracker** *(security review — statutory-
  deadline work must not rot in a log file)*. Log which key matched (audit trail). Policy
  for id/email matches:
  - contact has **no conversations** → `destroy!` (the imported-never-contacted majority);
  - contact **has conversations** → anonymize: name → "Redacted customer", clear
    email/phone/identifier and all `shopify_*` + `city`/`country` additional attributes,
    clear location columns, keep the conversation record (business/audit record; message
    *content* the customer sent is out of scope for this patch — flagged in the PR for a
    human decision).
- `customers/data_request`: report via `ChatwootExceptionTracker` *(review — a statutory
  deadline shouldn't depend on someone reading info logs)* + error log with shop and
  customer id; runbook: manual export. Never silently drop.
- All other topics → `super` (existing `shop/redact` behavior untouched).
- **Deployment gate (not code):** verify in the Partner Dashboard that compliance webhook
  URLs point at `POST /webhooks/shopify` and test a real delivery. If UMI's app turns out
  to be an admin-created custom app (never receives these), the handler stays as dead-code
  insurance and the runbook is manual — recorded in UMI-PATCHES.

### 3g. On-touch persistence (prepend on the orders controller)

`Umi::Shopify::PersistCustomerLink` prepended onto
`Api::V1::Accounts::Integrations::ShopifyController`; wraps `fetch_customers`: when a
returned customer **exactly** matches the contact's email (case-insensitive) or E.164
phone (never `customers.first` blindly), persist `shopify_customer_id` into
`additional_attributes` if absent (single UPDATE, skip when present). No behavior change
for the response. *(review)* Its consumer is §3f: the id makes redact matching survive
later agent edits to email/phone — this is why it ships even before the bulk sync.

### 3h. Sync lock

One Redis lock per account, via the in-repo primitive *(review — production `Rails.cache`
is per-container FileStore (no `cache_store` configured), dev is `:null_store`: a
`Rails.cache` "lock" would never actually lock)*:
`Redis::Alfred.set("UMI_SHOPIFY_CONTACT_SYNC_LOCK::<account_id>", run_id, nx: true, ex: ttl)`
— atomic check-and-set. Backfill TTL 6 hours (bounded chain duration on a starved `:low`
queue); poll TTL 25 minutes. Every backfill page job verifies the stored value still
equals its `run_id` (TTL-expiry takeover → abort loud). Released by: final page job,
retries-exhausted handler, 4xx abort, poll completion. All writers (backfill chain, poll)
share the one key, so concurrent-writer corruption (double chains, watermark regression,
run-long phone races) is excluded by construction; the residual race window is the one
page in flight when a TTL expires, accepted.

## 4. Config (all ENV, inert defaults)

| Var | Default | Meaning |
|---|---|---|
| `UMI_SHOPIFY_CONTACT_SYNC_ENABLED` | unset (off) | registers/unregisters the cron poll |
| `UMI_SHOPIFY_CONTACT_SYNC_CRON` | `*/30 * * * *` | poll cadence |
| `UMI_SHOPIFY_CONTACT_SYNC_MAX_CUSTOMERS` | `20000` | backfill ceiling guard |
| `UMI_SHOPIFY_CONTACT_SYNC_PAGE_WAIT_SECONDS` | `3` | backfill inter-page spacing |
| `UMI_SHOPIFY_CONTACT_SYNC_POLL_MAX_PAGES` | `20` | poll per-run page cap |
| `UMI_SHOPIFY_SHOP_DOMAIN` | unset | pins the redact hook-gone fallback to the expected shop (unset = no fallback) |

The redact/data_request handler and on-touch persistence are always on (compliance +
harmless), independent of the flag.

## 5. Failure modes

| Failure | Behavior |
|---|---|
| Shopify 429/5xx mid-backfill | job re-raises; `retry: 10` backoff (hours, not the global 3); same cursor resumes |
| Retries exhausted / 4xx | tracker alert + lock released; chain stops loudly; no watermark |
| Hard-kill (OOM/SIGKILL) loses in-flight page job | accepted: lock TTL expires, watermark absent → poll alerts every run; idempotent re-run repairs |
| Two backfill invocations / poll overlapping backfill | excluded by the Redis lock (atomic NX) |
| Poll partial failure / page cap exceeded | watermark not advanced; tracker alert on cap; next run (or backfill) re-covers |
| Watermark lost (settings wiped / reconnect) | poll error-logs every run, does nothing |
| Duplicate phone in store | in-batch dedup (most-recent keeps it) + identity guard; residual dup only across a lock-TTL takeover window |
| Two customers share a phone across pages | identity guard: contact keeps first `shopify_customer_id`; `conflicted` counted, never flapped, never cross-redacted |
| Real name matching Haikunator pattern | accepted rare overwrite by placeholder rule |
| Concurrent agent edit vs enrich (jsonb column) | `reload`-before-merge shrinks window; residual last-write-wins accepted |
| Redact handler raises | tracker + error log, still 200 (Shopify won't redeliver — loudness is mandatory) |
| Redact for phone-only match | never destroyed; shopify keys stripped + human-review log |
| Ceiling exceeded | backfill aborts before page 1 with explicit message |

## 6. Test plan

Unit (webmock, no live Shopify): mapper normalization matrix (email/phone/E.164/skip
rules, placeholder-name predicate incl. email local part); sync service dedup
(most-recent-keeps-phone), identity guard (`conflicted`), partition, fill-blanks,
no-change-skip (a second identical run saves nothing — the unit mirror of the real-data
idempotency check), counters; backfill job cursor chaining, ceiling guard,
watermark-on-final-page-only with fresh hook reload (stale/absent hook → tracker, no
silent 0-row update), 429 re-raise, retries-exhausted handler (tracker + lock release),
lock verification abort; poll job watermark gate (error log), advance-only-on-success,
page-cap abort without advancing, cursor pages carry no filter params; redact handler
match order, destroy-vs-anonymize, phone-only-never-destroys, hook-absent fallback,
**returns 200 when the handler raises**, HMAC (reuses existing controller spec harness);
on-touch exact-match persistence; factory spec carries the relocated
`Context.setup`-mutex concurrency examples. Lock specs run against `Redis::Alfred`
(available in test), **not** `Rails.cache` (test store is `:null_store` — a cache-based
lock spec would pass vacuously). Specs under `spec/services/umi/shopify/` +
`spec/jobs/umi/shopify/` mirroring the help-center layout; remaining help-center examples
stay green.

Real-data verification (local, read-only against the store): dev DB + production hook
token; run backfill; verify counts vs `customers/count.json`, spot-check E.164/name
quality, run twice → second run all-`unchanged`; simulate a poll with a backdated
watermark.

## 7. UMI-PATCHES registry row (to add)

Patch #6: Shopify customer → contact sync. Files as above. Remove-when: upstream ships a
native Shopify customer sync, or UMI drops proactive contact seeding. Runbook notes:
verify watermark after backfill; Partner-Dashboard compliance-webhook verification.
