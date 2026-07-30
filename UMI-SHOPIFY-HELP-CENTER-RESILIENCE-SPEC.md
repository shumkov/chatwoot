# Help Center → Shopify sync: resilience

**Status:** spec v5 — five review passes; Codex verdict APPROVE WITH CHANGES, all folded in. Awaiting sign-off. No code yet.
**Driver:** Ivan Shumkov. **Updated:** 2026-07-30.
**Amends:** [`UMI-SHOPIFY-HELP-CENTER-SPEC.md`](./UMI-SHOPIFY-HELP-CENTER-SPEC.md) (patch #3).

**Review provenance.** v1 → v4 across five reviews (feasibility, scope, adversarial,
reliability, plus a Codex session). Two designs were killed outright and one
fork-wide defect was found that has nothing to do with the incident:

- **v1** cached the Shopify article id in `Article#meta`. Killed — `meta` is
  API-writable and assigned wholesale (`articles_controller.rb:84-91`), so the
  incident's own bulk-edit path erases it; and an id-only lookup silently breaks
  every rename 301.
- **v3** matched ownership by "tags containing `cw-<id>`". Killed — substring
  matching makes `cw-4` match `cw-43`, so an edit overwrites the wrong article's
  public page and a **delete removes the wrong article from the storefront**.
  Found independently by three reviewers.
- **New:** the Shopify API version pin is dead (§2e), fork-wide, and drifts quarterly.

## 1. Problem

**Production incident, 2026-07-29 09:00 UTC.** A 36-article bulk edit via the API
put **43 sync jobs in the Sidekiq Dead set**, all Shopify HTTP 429. Six dated from
2026-07-21 — live and unnoticed for eight days. Nothing alerted; the Chatwoot UI
showed every edit saved.

**Verified state after the 2026-07-30 repair** (content-level diff, 48 published
articles): 45 in sync, **3 drifted (8, 12, 47)**, 0 missing, 0 orphaned. The three
are defect (c), not the rate limit, and no amount of re-running fixes them. Article
8's storefront states a **wrong returns policy** — "Within 7 days of purchase" vs
Chatwoot's "Within 14 days of delivery".

## 2. Root causes

**(a) ~49 API calls per sync job.** `find_owned_article` lists the blog (1 call),
then issues `GET articles/<id>/metafields.json` **per article** hunting
`custom.chatwoot_id` (`help_center_sync_service.rb:180-195`), plus `blogs.json`
(`:158`). Shopify REST leaks **2 req/s** with a 40-request bucket, so one job needs
~25 s of the store's entire budget — a *single* edit overruns it, which is why 6
jobs died on 07-21 with no bulk edit behind them.

The N+1 is **only** the per-article metafield confirmation. The list is 1 call and
already returns ids, handles, tags **and full `body_html`** (verified live).

**(b) Retries give up in ~3 minutes.** The job declares no retry policy, so it
inherits `:max_retries: 3` (`config/sidekiq.yml:9`). Transport failures are worse:
`shopify_api` doesn't wrap `Net::ReadTimeout`, `SocketError`, `OpenSSL::SSL::SSLError`,
`JSON::ParserError`, and the service rescues only `HttpResponseError` (`:21`), so a
network blip escapes → 3 retries → dead. The fork's contact-sync job already solved
this (`contact_backfill_job.rb:24-31`); the help-center job never got it.

**(c) A newline permanently strands an article.** `global.description_tag` is sent as
`single_line_text_field` (`:136`) with the description verbatim; `description` is a
`t.text` column. Shopify rejects the **whole article** with a 422 → permanent → skipped
forever. **Confirmed on 8, 12, 47.**

Same class, also confirmed live: category 12 is named **"Wholesale, Press &
Influencers"**, and joining it verbatim into the comma-separated `tags` field makes
Shopify store it as **two** tags — so 3 articles carry two bogus category tags and
their real category never matches.

Related but **unproven**, so deliberately out of scope: `slugify` returns `""` for a
Thai title, and — worse — `"นโยบาย Return"` → `"return"`, a plausible-looking handle
that would silently collide. No such article exists today.

**(d) Nothing detects drift, and exceptions never will.**
`ChatwootExceptionTracker` reaches Sentry only if `SENTRY_DSN` is present
(`lib/chatwoot_exception_tracker.rb:15`). **Verified: empty in production, and
permanently so — this stack monitors with Netdata.** So (c) has been emitting its
"loud" signal into an unread container log for weeks. The repo also has **zero**
`death_handlers` / `sidekiq_retries_exhausted` hooks, so the Dead set is unwatched.

**Exception reporting is not what closes this incident class. A drift detector is.**

**(e) The Shopify API version pin is dead, fork-wide.** Not part of the incident;
found during review and independently serious.

```
ClientFactory pins:       2025-01
Shopify actually served:  2025-10          (+ x-shopify-api-version-warning)
```

Support for 2025-01 ended 2026-01-01, so **every call in this fork** — help-center
sync, contact sync, orders sidebar — silently falls forward. Three consequences:

- **It drifts quarterly with no deploy.** Shopify serves the oldest supported version;
  2025-07 expired 2026-07-16, which is why we're on 2025-10. On **2026-10-16** it
  becomes 2026-01.
- **The pin can't simply be bumped.** `shopify_api` 14.8.0 caps `SUPPORTED_ADMIN_VERSIONS`
  at 2025-01 and `Context.setup` **raises `UnsupportedVersionError`** otherwise. A gem
  upgrade is mandatory.
- **`ShopifyAPI::Context` is process-global.** Core `shopify_controller.rb:90` sets the
  version per request; `ClientFactory` sets it per job. Last writer wins per process, so
  the pin must move in **both** places.

Settled by this review: **REST Articles are not on a sunset path.** Only `/products`
and `/variants` have removal timelines; "legacy as of 2024-10-01" binds *new public
apps*. Investing in the REST design is defensible.

## 3. The four patches

Agreed sequencing: repair live customer harm, then the fork-wide time-bomb, then the
engineering, then the detector.

---

### P0 — Content normalization hotfix (ship first, standalone)

The only change that repairs articles serving wrong content **today**.

Collapse whitespace on every `single_line_text_field` value, in `text_mf` so it covers
`description_tag`, `title_tag` and both slug fields:

```ruby
value.to_s.gsub(/[[:space:]]+/, ' ').strip
```

- **`[[:space:]]`, not `\s`** — Ruby's `\s` is ASCII-only and misses U+2028/U+2029/NBSP
  (verified: `" " =~ /\s/` → nil, `=~ /[[:space:]]/` → 0). Deliberate deviation from
  `:124`; comment it.
- **Collapse before truncating, and move the truncation.** Today `description_tag` is
  cut to 320 chars at the call site (`:136`) *before* `text_mf` ever sees it, so
  normalizing inside `text_mf` would still run second. Move the cut into `text_mf` via
  an optional `limit:` argument so the order is normalize → truncate. Test a whitespace
  run straddling the 320-char boundary.
- **Do not switch to `multi_line_text_field`** — it's an SEO meta description, and a
  store-side metafield definition pinning the type would 422 anyway.
- **Strip commas from `category.name`** in `article_tags` — same defect class, confirmed
  live on category 12. **Storefront-visible:** "Wholesale, Press & Influencers" is two
  live tags today and becomes one after this. Check `umi-store-theme` for anything keyed
  on `Wholesale` or `Press & Influencers` as tag names before shipping.

**Files:** `help_center_sync_service.rb`, its spec.
**After deploy:** paced repair run for **8, 12, 47 *and* the three category-12
articles** — the comma fix changes their tags, so they need a push too. Six articles,
not three.

---

### P1 — Shopify API version (fork-wide)

- Upgrade `shopify_api` **14.8.0 → 16.2.0** (`Gemfile.lock` only; `Gemfile:210` is
  unpinned). Verified safe: the only breaking changes across 15.0/16.0 are the
  `Webhooks::Handler` interface, `LATEST_SUPPORTED_ADMIN_VERSION` /
  `RELEASE_CANDIDATE_ADMIN_VERSION`, `Session#serialize`/`deserialize`, and Ruby ≥3.2.
  **None are referenced anywhere** in `app enterprise lib umi config spec`;
  `.ruby-version` is 3.4.4. Only four files touch `ShopifyAPI`, all using
  `Context.setup`, `Auth::Session`, `Clients::Rest::Admin`, `Errors::HttpResponseError`.
- **Pin `2026-01`** (EOL 2027-01-16 — six months of field time).
- Pin it in **one shared constant**, consumed by both callers.

  **The core controller's pin is a literal inside a private method, not a constant:**

  ```ruby
  def setup_shopify_context          # shopify_controller.rb:84-95
    ShopifyAPI::Context.setup(
      api_version: '2025-01'.freeze,
      scope: REQUIRED_SCOPES.join(','), ... )
  end
  ```

  So an initializer cannot reassign it — `zz_umi_shopify_api_version.rb` must **prepend
  a module overriding `setup_shopify_context`**. That keeps `shopify_controller.rb`
  unedited and the fork rebasable, but the override is a *copied method body*: it will
  silently diverge if upstream changes the method. **Guard it** — assert at boot that
  the upstream method exists and its source still matches expectations, and fail loud
  otherwise, per the fork's "guard the patch so it fails loud if upstream changes the
  thing it depends on" rule.

  **A second, pre-existing defect surfaces here.** `ShopifyAPI::Context` is process-global
  and last-writer-wins, so the controller and `ClientFactory` already stomp each other on
  **`scope`** as well as version — the controller sets `REQUIRED_SCOPES.join(',')`,
  `ClientFactory` sets `''` (`client_factory.rb:35`). That ping-pong is live in production
  today. The controller also calls `Context.setup` **outside** `ClientFactory`'s mutex,
  violating the invariant `client_factory.rb:8-13` documents — the Zeitwerk-reload race
  that mutex exists to prevent.

  **Therefore the override should delegate to `Umi::Shopify::ClientFactory.ensure_shopify_context!`**
  rather than re-implement `Context.setup`. One override then fixes the version split-brain,
  the scope ping-pong and the mutex hole together. Verify first that `scope: ''` is
  inert for the controller's token-based REST calls (it is for the Sidekiq path today,
  which is why the jobs work) — if it is not, the shared setup must carry `REQUIRED_SCOPES`.
- **Assert the served version.** One line reading `x-shopify-api-version` off any
  response and failing on mismatch converts the next silent quarterly fall-forward into
  an alarm. Zero extra API calls. Lands properly in P3's verify task; until then, assert
  it in a spec.

**Files:** `Gemfile.lock`, `client_factory.rb`, new `zz_umi_shopify_api_version.rb`, specs.

---

### P2 — The incident fix

**Ownership: `cw-<id>` tag as an index, `custom.chatwoot_id` as the authority.**

```ruby
def article_tags   # "Sizing, featured, cw-42"
  [category_name.presence, ('featured' if featured), "cw-#{id}"].compact.join(', ')
end
```

`find_owned_article`:

1. List the blog (**1 call**) — returns tags for every article.
2. **Exact-token match**, never substring:
   `tags.to_s.split(',').map { |t| t.strip.downcase }.include?("cw-#{id}")`.
   Substring matching is the v3 blocker: `"cw-43,…".include?("cw-4")` → true, so an
   edit clobbers the wrong public page and a **delete removes the wrong article**.
   Also guard `id` present — a nil id yields `"cw-"`, which substring-matches everything.
3. **Reject duplicate candidates** — more than one article carrying the same `cw-<id>`
   means a duplicate exists; fail loud rather than pick one.
4. **Confirm `custom.chatwoot_id` before every mutation** (1 call). The tag narrows 49
   metafield reads to **one**; it does not make them unnecessary. A *wrong* tag — an
   article duplicated in the Shopify admin copies its tags — is otherwise undetectable,
   and the next PUT would rewrite `custom.chatwoot_id` to match the wrong article.
   This is what keeps the metafield the authority rather than decoration.
5. No tag → existing metafield scan → create.

**Cost: ~49 → 4 calls** — `blogs.json` + list + metafield confirm + PUT. Not 2, and not
3: with plain per-instance memoization of the blog id (the option chosen in §"missing
blog" below) every job still pays `blogs.json`. A 36-article batch drops from ~1,700 to
~144 — still well over the 40-request bucket, so **retries remain load-bearing**. Both
halves matter; I claimed otherwise in two earlier drafts and was wrong both times.

**Fail loud past 250 articles.** `blog_articles` reads one page. Past 250 the tag match,
metafield scan **and** handle guard fail *simultaneously* and silently duplicate. Raise
if `response.next_page_info` is present — the governing count is the Shopify blog's
**total including unpublished**, not Chatwoot's 48, and nobody has measured it.

**Re-derive from the live record — content *and* publish state.** With retries extended,
a stale snapshot can land after a newer edit. Re-loading only the content is not enough:
`dispatch` branches on the snapshot's `event` (`:56-61`), so an `upserted` retry landing
after an unpublish **re-publishes an article you deliberately pulled**. Derive
`published:` from the reloaded record's `status`; `upserted`/`unpublished` collapse into
one branch. Use `find_by` (a `RecordNotFound` is not retryable and would die into the
Dead set). Skip-if-gone applies to upserts **only** — never short-circuit a delete.
Reuse the existing private mapper `umi_help_center_attrs` rather than duplicating 15 fields.

**Serialize per article.** The current handle guard **cannot** catch a concurrent create:
`blog_articles` is memoized (`:181`) *before* either job writes, so job B's snapshot
predates job A's POST and both create. Use a Redis `nx/ex` lock keyed by **account +
article** — do *not* reuse `SyncLock`'s key, which is account-wide and contact-specific
(`sync_lock.rb:12`).

Full protocol, because an underspecified lease recreates the very race it prevents — a
cold 49-call path can exceed 25 s:

- Acquire **before** the live-record reload and the ownership lookup.
- Contention → raise `RetryableError`. **Never block a Sidekiq thread waiting.**
- A concrete TTL (or a renewable lease) sized above the cold path, not the warm one.
- **Re-check token ownership immediately before every POST / PUT / DELETE**; lost
  ownership → `RetryableError`.
- Release in an `ensure`, via compare-and-delete.
- **Fail closed:** Redis unavailable → typed retryable error, never proceed unlocked.
  Given the 24 s Redis outage observed on 2026-07-30, that means a delayed sync rather
  than a corrupted storefront.

Consequently "a retry cannot regress the storefront" holds **only** for an extant,
still-syncable record processed while holding the lease — state it that narrowly.

**Retry posture**, mirroring `contact_backfill_job.rb`:

```ruby
class RetryableError < StandardError; end
retry_on RetryableError, wait: :polynomially_longer, jitter: 0.5, attempts: 8 do |job, error|
  Rails.logger.error("[umi-hc-sync] gave up after retries: #{error.message}")
  raise error
end
```

- `attempts: 8` = **78 min at jitter 0** (the sibling job's documented figure is accurate
  *because it passes no jitter*). At `jitter: 0.5` the real span is **78 min min / ~98
  mean / 117 max**; at 1.0 it stretches to ~117 mean / 156 worst. Use **0.5** and quote
  78–117.
- **Be honest about what jitter does here: it is not a first-wave fix.** Jitter scales
  with the delay, so at `executions=1` it spreads 36 jobs over at most 0.5 s — nothing
  against a 2 req/s budget. Its real value is modest desynchronization across the *later*
  retries. If genuine first-wave spreading is wanted, that needs a wider randomized
  initial wait or bucket pacing (§5) — not a jitter tweak.
- Status mapping matches `contact_backfill_job.rb:122`: `nil || 429 || >= 500` and
  `TRANSPORT_ERRORS` → retryable; other 4xx permanent.
- **The block re-raises** so the payload still reaches the Dead set — the 43 dead jobs
  are what made this incident diagnosable. Note it then passes through Sidekiq's own 3
  retries (each immediately re-raising) before landing there.

**Fail loud on a missing blog.** Replace `find_or_create_blog`'s create path with a
`find` that raises — N concurrent jobs against a misconfigured store would otherwise
create N duplicate blogs. (The "transient empty `blogs.json`" rationale from v3 was
unsupported; the real trigger is a renamed/deleted blog.)

**Blog-id memoization: keep the existing per-instance `@blog_id ||=` and accept the
4-call cold path.** The alternative — a process-wide class cache — needs thread safety
plus invalidation on blog deletion, recreation, handle change and 404, which is real
machinery to save one call out of four. Explicitly *not* a bare global on
`ClientFactory`: that class is account-agnostic (`client_factory.rb:26`), so an unkeyed
memo would leak across every Shopify-connected account and survive a
`UMI_HC_BLOG_HANDLE` change.

**Files:** `help_center_sync_service.rb`, `help_center_sync_job.rb`,
`shopify_help_center_syncable.rb`, new per-article lock, `umi_help_center.rake`
(seeding), specs. Companion: `umi-store-theme` filters `/^cw-\d+$/`.

---

### P3 — The detector

Built to the house Netdata pattern (`health.d/shumabit.conf`): a cron job writes a
heartbeat, `go.d/filecheck` watches mtime/existence, `health.d` alarms to `sysadmin`.

**`rake umi:help_center:verify`** — exits **0** clean, **1** drift, **2**
could-not-determine. The host cron touches **two** files: `verify.ran` on any completed
run (short threshold → catches a dead cron/container) and `verify.ok` on exit 0 only
(threshold **≥3× the interval** → two consecutive failures required, so one unrelated 429
doesn't page anyone). Two alarms, two runbooks, one extra `touch`, and **the rake task
stays ignorant of Netdata** — it only sets an exit code.

It must:

- **Compare content, not timestamps** — Shopify doesn't bump `updated_at` on a no-op PUT
  (16 false positives out of 48 when I tried it).
- **Normalize before comparing — but do not flatten to text.** `CGI.unescapeHTML` →
  collapse `[[:space:]]+` → strip handles the real trap (Chatwoot emits `&#x27;` where
  Shopify stores `'`, which produced false drift on articles 6 and 43). **Do not compare
  `strip_tags`-ed text** — that was an overcorrection: it hides broken links, changed
  `href`/`src`, missing images, dropped headings and altered list structure, all of which
  are exactly the storefront damage this detector exists to catch. Canonicalize *parsed*
  HTML instead, retaining meaningful elements and attributes, and normalize only the
  cosmetic axes (`<br>` vs `<br/>`, attribute order, `\r\n`).
- **Compare publication via the REST response's `published_at.present?`**, not a
  derived flag.
- **Compare tags as a set** — Shopify reorders alphabetically, so a string compare
  reports drift on every article, every hour, forever.
- **Confirm the authoritative metafield, not just the tag.** P2 makes
  `custom.chatwoot_id` the authority, so a verifier that checks only tags and content
  **false-greens on exactly the failure P2's confirmation step exists to catch** — a
  wrong tag whose `chatwoot_id` disagrees. Honest cost is then ~N+2 calls, paced off the
  bucket headers. Acceptable alternative: a 2-call content check plus a separately paced
  authority audit — but **both must gate `verify.ok`**, or the cheap one silently becomes
  the only one that runs.
- **Build expected payloads by calling `article_payload`**, never by re-implementing the
  mapping — a second copy diverges the moment either side changes. Accepted trade: it
  can't catch payload-builder bugs, but it does catch "the PUT never landed".
- **Assert `write_content` is in `hook.settings['scope']`** — zero API calls, and it
  closes the silent-no-op hole where a re-auth disables all writes while verify still
  reads green.
- **Assert `x-shopify-api-version` matches the pin** (from P1).
- **Assert exactly one article per `cw-<id>`**, or duplicates stay invisible.
- Cost: 2 calls for the content pass (the list returns `body_html`), **~N+2 with the
  authority audit** — paced off `api_call_limit`.
- **Define Dead-set matching and exit semantics in the verifier contract itself**, not
  only as a deploy step: match on Sidekiq's ActiveJob wrapper payload, and state which
  entries count (post-deploy only, or all).

**Purge the 41 historical dead jobs before enabling the alarm** — otherwise verify exits
non-zero on day one, the heartbeat is never touched, and the alarm fires forever until
someone mutes it, reproducing the exact blindness this exists to end. Match on Sidekiq's
ActiveJob wrapper payload, not a top-level class name.

**Provide a way to clear every drift class** — an alarm with no clear action gets muted.
`rake umi:help_center:resync[id]` covers the common case (someone edited an article in
the Shopify admin). It does **not** cover an orphan whose Chatwoot record was deleted or
moved outside the configured portal/locale — there is no id to resync. That needs a
**confirmed-owner delete/reconcile command plus a runbook entry**, or the orphan class
latches the alarm permanently.

**Export the 41 historical dead jobs before purging** if their forensic value matters —
purging is a one-way step.

**Sidekiq death handler — moved out of P3.** It is fork-wide, forensic only, and does not
drive the detector, so it does not earn a place in the detector patch. Ship it as an
optional **P4** or omit. If it ships: **truncate args** (they carry full article
`content`) and **never raise** — a raising death handler breaks death processing for
every job class in the install. Rebase-safe: Sidekiq 7.3.1 exposes `config.death_handlers`.

**Files:** `umi_help_center.rake`, `zz_umi_sidekiq_death_handler.rb`; `umi-vps-infra`
(`roles/netdata`: heartbeat paths + thresholds, `filecheck.conf.j2`, new
`health.d/chatwoot.conf.j2`, cron entry).

## 4. Deploy order (hard requirement)

1. **P0** → paced repair of 8, 12, 47.
2. **P1** gem + pin.
3. `umi-store-theme` tag filter — **before** P2. The theme derives its FAQ chips from
   `article.tags`, and Shopify sorts alphabetically, so an unfiltered `cw-42` lands
   *mid-list* beside the real category. **Accepted residual exposure:** the filter hides
   chips but does **not** remove Shopify's auto-created `/blogs/help/tagged/cw-42`
   routes, which exist for as long as the tag does. Deploying the filter first prevents
   the visible chip, not the route.
4. **P2** deploy → **pause all Help Center mutation jobs** → run the seeding pass → only
   then resume. Pausing bulk *editing* is not enough: ordinary `after_commit` events stay
   active (`shopify_help_center_syncable.rb:8`), and any one of them during the window is
   a ~49-call job — under retry, ~8 × 49 ≈ 392 calls.

   The seeding pass needs a **dedicated seed-only code path**. The current rake task
   enqueues the normal upsert job (`umi_help_center.rake:27`), which can reach the create
   branch (`help_center_sync_service.rb:85`) — exactly the duplicate window seeding is
   supposed to close. Seed-only means: PUT to stamp tags, never create.

   **The gate must be measurable, not assumed.** Seeding exits non-zero unless *every*
   syncable published article has exactly one tag candidate whose metafield confirms
   ownership — zero missing, zero duplicate, zero mismatched, zero over-250. "Only PUTs
   what it finds" silently skips an article that is missing from Shopify entirely, which
   is precisely a case the gate must catch. It also needs its own throttle, 429 retry, and
   resumability (skip already-tagged articles).
5. Purge the 41 dead jobs → **P3** → enable alarms.

## 5. Alternatives rejected

- **Cache the Shopify id in `Article#meta`** (v1) — the articles API replaces `meta`
  wholesale, so the incident's own path erases it; an erased id plus a changed title
  takes the create branch and **duplicates the article**.
- **Cache in `Integrations::Hook#settings`** — immune to that API, but still a cache with
  an invalidation story, on one row every job writes concurrently.
- **Exact-token match alone, without metafield confirmation** — fixes prefix collisions
  and duplicates, but not a *wrong* tag, which is silent and self-reinforcing.
- **Redis-cached blog id** — optimizes 1 call out of 49, invents invalidation, leaks
  across specs (the suite never flushes Redis), and prod Redis is demonstrably flaky.
- **`?handle=` lookup** — returns strictly less than the list call we already make, loses
  the collision guard, and regresses deletes after a rename.
- **Paginating `blog_articles`** — 48 articles; a loud failure past 250 is the smaller,
  more honest change.
- **Version fence instead of a lock** — can't close the gap between the DB read and the
  remote PUT, and doesn't cover create/delete races.
- **Debounce/coalesce into one reconcile job** — right end-state at hundreds of articles;
  needs a debounce window, dirty set and scheduler, and would have done nothing for (c).
- **Client-side pacing off `api_call_limit`/`retry_request_after`** — accessors confirmed
  to exist (`http_response.rb:22,25`) and the `1/40` header is live, so this is viable and
  would also protect the orders sidebar (2 calls per conversation open, no retry, same
  token). Deferred on scope, not feasibility.
- **GraphQL migration** — REST Articles have no sunset date, so this is a real follow-up
  rather than a countdown.
- **Raise `:max_retries` globally, or put `retry_on` on `ApplicationJob`** — changes every
  job class in Chatwoot to fix one integration, in core files the fork would carry forever.

## 6. Failure modes

| Failure | Behavior |
|---|---|
| Tag missing (pre-existing article, admin edit) | Metafield scan recovers and re-stamps. Costs the 49-call path once. |
| Tag **wrong** (article duplicated in admin) | Caught by the pre-mutation metafield confirmation (P2 step 4). Without it this is silent and rewrites the authority to match itself. |
| Prefix collision (`cw-4` vs `cw-43`) | Excluded by exact-token matching + a test. |
| Duplicate `cw-<id>` candidates | Fail loud; `verify` asserts one owner per id. |
| Blog exceeds 250 articles | Raise on `next_page_info` rather than silently duplicating. |
| Retry lands after a newer edit | Cannot regress — content *and* publish state re-derived. |
| Concurrent jobs, same article | Per-article Redis lock; fail closed on Redis loss. |
| Redis unavailable | Lock acquisition raises retryable → sync delayed, storefront uncorrupted. ActiveJob retries are themselves Redis writes and OSS Sidekiq uses non-reliable `brpop`, so a blip can still lose a job — `verify` is the backstop. |
| Article moved off portal/locale | No further events fire and the job no-ops, leaving a **stale-but-live** storefront article. `verify` must define orphan as *tagged Shopify article with no syncable published Chatwoot article* or this stays invisible. |
| Locale changed then deleted | Delete hook never fires (pre-existing, `umi_help_center_syncable?`); only `verify` catches it. |
| Permanent 4xx after normalization | Payload-builder bug. Logged, skipped, surfaced only by `verify`. |
| `write_scope?` false after re-auth | All writes and deletes silently no-op; `verify` asserts the scope directly. |
| Rename 301 | The list row carries the current handle, so rename detection survives the fast path. |
| Redirect chains accumulate | Pre-existing; loops unreachable because Shopify only serves a redirect for a path that 404s — an assumption retry-safety rests on, now written down. |
| API version drifts next quarter | `verify` asserts the served version against the pin. |

## 7. Verification plan

The existing spec file is **119 lines covering only pure helpers** — `.slugify`,
`#article_payload`, `#metafields`, `#client`. **Zero** coverage of `find_owned_article`,
`upsert_article`, `destroy_article` or any redirect path, and no job spec. Building the
harness is part of the work. Note lines 76 and 94 assert exact tag strings and **will go
red** the moment `cw-<id>` is appended — they need editing, not just extending.

Each test red before, green after:

1. **Multi-line description** (P0) → single-line metafield values. Red today → 422 →
   stranded. Use article 8's real shape, plus a U+2028 case.
2. **Comma in category name** (P0) → one tag, not two. Uses category 12's real name.
3. **Prefix collision** (P2) — an article tagged `cw-43` must **not** match id 4. The
   single most important test in this patch.
4. **Nil id** must not produce a wildcard `"cw-"` match.
5. **Duplicate `cw-<id>`** → raises rather than picking one.
6. **Metafield confirmation** — a tag matching but `chatwoot_id` mismatching must abort
   the mutation.
7. **Per-job call count** — a tagged article's update issues list + confirm + PUT = 3.
8. **429 behavior, not configuration** — stub a 429; assert typed error, no escape, retry
   enqueued (`queue_adapter = :test`). Stub a 404; assert **no** retry.
9. **Transport error** (`Net::ReadTimeout`) is retryable.
10. **Retry cannot revert content or publish state** — stale `upserted` retry after an
    unpublish must not re-publish.
11. **Rename 301 survives the fast path.**
12. **Delete after a rename** finds its article rather than logging "already absent".
13. **251st article** → raises.
14. **Lock contention** — second concurrent job for the same article waits or retries,
    never double-creates. Redis unavailable → retryable error, not an unlocked write.
15. **Gem-behavior guard** — a stubbed 429 surfaces as `HttpResponseError` with
    `code == 429`. Doubles as the P1 upgrade's regression test (`tries: 1` semantics).
16. **API version** — `Context.setup` accepts the pin; a spec asserts the served
    `x-shopify-api-version` matches.
17. **Existing suite green** after editing lines 76/94.
18. **Production** — `verify` reports zero drift including 8, 12, 47.
19. **Staging soak** — bulk-edit all 48 **after seeding**. Assert **call and 429 counts**,
    not "zero dead jobs" — `retry_on` makes that unfalsifiable.

## 8. Out of scope / follow-ups

- **Thai slugify** — genuinely unproven; no affected article. Note the mixed-script case
  (`"นโยบาย Return"` → `"return"`) is worse than empty, and an `article-<id>` fallback
  wouldn't catch it. Needs a real slug contract, not a patch.
- **Client-side bucket pacing** (§5) — feasible, deferred on scope.
- **GraphQL migration** — no forcing date.
- **`meta` wipe via the articles API** — `articles_controller.rb:84-91` assigns `meta`
  wholesale, **already silently destroying `meta['featured']`/`featured_position`** from
  patch #6. Live bug, its own patch.
- **Category rename propagation**, **redirect-chain pruning** — pre-existing.
- **`SENTRY_DSN` stays unset — decided.** Do not write code whose failure path assumes
  anyone reads an exception.
