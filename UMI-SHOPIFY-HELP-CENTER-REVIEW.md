# Review — Chatwoot Help Center → Shopify FAQ (spec v2 + PR #2 implementation)

Multi-reviewer review of [`UMI-SHOPIFY-HELP-CENTER-SPEC.md`](./UMI-SHOPIFY-HELP-CENTER-SPEC.md)
and the implementation on branch `umi-shopify-help-center-sync`
([shumkov/chatwoot#2](https://github.com/shumkov/chatwoot/pull/2)). Eight
independent lenses: Shopify-API domain-fit, correctness, reliability, security,
performance, scope/simplicity, spec-flow, fork-hygiene. **Consensus** = flagged by
≥2 lenses independently (higher confidence).

## Top line

The pure mapper is sound and unit-tested, and the design instinct (in-process
plugin, reuse the token, idempotent-by-metafield) is right. Not merge-ready: the
idempotency mechanism can silently produce duplicate articles, the backfill will
rate-limit-storm on first run, and two Shopify-API assumptions need checking (both
since resolved — see the section below). Spec v2 is accurate on the happy path but
underspecifies lifecycle edges.

## ✅ Resolved — verified against the shopify_api 2025-01 spec (2026-06-18)

Both API assumptions were settled against the installed `shopify_api` 14.8.0 REST
resource definitions (auto-generated from Shopify's 2025-01 spec) + the
access-scopes docs — no live store needed.

- **V1 — Redirect OAuth scope → resolved.** URL redirects require
  `write_online_store_navigation` (the access-scopes table maps `UrlRedirect`
  there; `write_content` covers Article/Blog/Comment/Page only). The initializer
  requests `read/write_online_store_navigation` alongside `read/write_content`, so
  the rename/delete 301s work once the integration is reconnected. *(Operational
  check still applies: confirm the reconnect grants the scopes.)*
- **V2 — Article metafields endpoint → fixed.** The blog-nested path
  `blogs/{blog_id}/articles/{id}/metafields.json` is **not** in the 2025-01 spec;
  article metafields live at `articles/{id}/metafields.json`. The lookup was
  corrected, so idempotency-by-metafield works (no silent fall-through to
  handle-only matching, no duplicate-create risk).

## 🔴 Blockers (fix before merge)

- **B1 — Idempotency can silently produce duplicate articles** *(consensus:
  reliability, performance, correctness, Shopify-API)*. Three compounding holes:
  1. **Partial create.** `chatwoot_id` is written inline in the create payload,
     but the `POST` response is discarded (`help_center_sync_service.rb:60`). If
     Shopify drops the metafield (validation, `global.*` definition missing) while
     creating the article, the idempotency key never persists → next sync re-creates.
  2. **V2** (nested metafield endpoint) — if it 404s, same outcome for every article.
  3. **250-article cap.** `find_article_by_chatwoot_id` and `find_or_create_blog`
     read one page (`limit:250`, no cursor) — silently truncates past 250 → misses
     → duplicates. *(help_center_sync_service.rb:119, 134)*
  *Fix:* read back the created article id from the POST and confirm `chatwoot_id`
  landed (raise to retry if not); add a secondary `handle` guard before create;
  paginate or eliminate the list (see B2 fix).
- **B2 — Backfill 429 storm** *(consensus: performance [Blocker], reliability,
  Shopify-API, scope)*. `find_article_by_chatwoot_id` is **1 + N API calls per
  single sync** (~48 for 47 articles); the rake backfill enqueues all 47 at once →
  **~2,200 calls against Shopify's ~2 req/s leaky bucket ≈ 18 min of throttling +
  retry cascade**. `shopify_api` 14.8.0 does not auto-retry 429.
  *(help_center_sync_service.rb:133-139; umi_help_center.rake:21-24)*
  *Fix (structural):* persist the Shopify `article_id` on the Chatwoot side → direct
  `PUT/DELETE` with **0 lookup calls** (keep metafield match as reconcile fallback);
  **or** one GraphQL `articles(query:"metafield:custom.chatwoot_id=<id>")` call. Plus
  stagger the backfill (`set(wait:)`) and honor `Retry-After`.
- **B3 — 409 / 4xx = poison job** *(consensus: reliability, scope, Shopify-API)*.
  Spec §10 says title-collision should "skip + alert"; code re-raises **all**
  `HttpResponseError` (`help_center_sync_service.rb:27-29`) → Sidekiq retries 3× →
  dies silently in the Dead set, no alert. 4xx (401/403/404/422/409) must not retry;
  only 429/5xx should. (Shopify may also **auto-suffix** a duplicate handle rather
  than 409 — so the public URL silently drifts from `slugify(title)`; verify.)
  *Fix:* branch on status — log+Sentry+`return` on 4xx, re-raise only 429/5xx.

## 🟠 Majors

- **M1 — No `locale` filter** *(consensus: correctness, scope, spec-flow)*. Concern
  gates only on portal slug; spec says `en` only. A second locale in `umi-help` →
  handle collisions/duplicates. **One-line fix** in `umi_help_center_portal?`
  (shopify_help_center_syncable.rb:16-18) + the rake query (umi_help_center.rake:21).
- **M2 — Tag handling violates §6** *(correctness)*. `tags: @attrs[:category_name]`
  verbatim — Shopify tags are comma-separated, so a category name with `,` splits
  into multiple tags. The `'General'` fallback for uncategorized articles is an
  undocumented phantom category. *(help_center_sync_service.rb:47)* *Fix:* pass an
  array / strip commas; decide the no-category behavior and record it in §6.
- **M3 — Unpublish-with-rename breaks a live URL** *(correctness)*. The unpublish
  path still recomputes `handle` and 301s old→new — but new is now a private draft
  → **301 to a 404**. *(help_center_sync_service.rb:46, 63-67)* *Fix:* on unpublish,
  redirect old→`UMI_HC_DELETE_REDIRECT` (like delete), don't rename to a draft.
- **M4 — `find_or_create_blog` footgun + race** *(consensus: reliability,
  spec-flow, scope, correctness)*. Auto-creating a fresh `help` blog masks a
  missing/misnamed blog (silently resolves §10's "rename vs create" as "create
  fresh"); concurrent backfill jobs can create duplicate blogs.
  *(help_center_sync_service.rb:117-129)* *Fix:* resolve §10 (rename
  `help-center`→`help` first), then don't auto-create — fail loud if absent.
- **M5 — Lifecycle propagation gaps** *(spec-flow)*. Category rename/delete doesn't
  touch articles → stale `tags`/`category_slug` forever. Article moved **out** of
  `umi-help` → orphaned/published in Shopify (no delete). Both unhandled + spec gaps.
- **M6 — Namespace collision risk** *(fork-hygiene)*. Job/Service sit under the core
  `Shopify::` namespace (`app/jobs/shopify/`, `app/services/shopify/`) — exactly
  where upstream's native Shopify content sync (this patch's own remove-when) would
  land → rebase clobber. *Fix:* move to `Umi::Shopify::`, matching the concern.
- **M7 — Constant reassignment has no drift detection** *(fork-hygiene, security)*.
  `remove_const(:REQUIRED_SCOPES)` is rebase-invisible: if upstream renames/reshapes
  it, this silently no-ops and the feature goes dark. *(zz_umi_shopify_help_center.rb:26-33)*
  *Fix:* add a fail-loud shape/name guard; pin the current upstream value in
  UMI-PATCHES.md so a rebase can diff it.
- **M8 — Over-broad scope grant** *(security)*. `write_content` is added to the
  shared `REQUIRED_SCOPES`, so the orders-sidebar token also gains storefront write.
  Blast radius of a leaked token now includes blog defacement + arbitrary 301s.
  Deliberate trade-off — document it; confirm `Integrations::Hook#access_token` is
  encrypted at rest.
- **M9 — "Reconnect" understates the op** *(spec-flow)*. `app_id` is unique per
  account and the callback does `create!`, so reconnect = **disconnect first, then
  reconnect**; a naive reconnect throws into an opaque `?error=true`. Spell out in §8.
- **M10 — No Sentry on any error path** *(reliability)*. `sentry-sidekiq` is loaded
  but every failure only `Rails.logger`s. The swallowed enqueue failure
  (shopify_help_center_syncable.rb:45,53) is the one path with zero auto-recovery and
  should page. *Fix:* `Sentry.capture_exception` with a stable id on each error branch.

## 🟡 Minors / nits

- `summary_html` strips markdown but not HTML → broken tags mid-truncate
  (help_center_sync_service.rb:89).
- `description_tag` caps at 320 vs spec's 160 (`:101`) — confirm intent.
- SEO metafields `chatwoot_slug` / `chatwoot_category_slug` / `chatwoot_position`
  written but no consumer in this repo yet — YAGNI until the theme reads them (`:97-99`).
- 250-article cap should be documented even if not fixed.
- `UMI-PATCHES.md` #3 file list omits `lib/tasks/umi_help_center.rake` (+ the spec).
- `archived` and `draft` both just unpublish — confirm intended (vs archived→delete).
- `slugify` can leave a leading/trailing dash on odd titles (`:34-38`).
- `locale` is snapshotted into the job payload (shopify_help_center_syncable.rb:28)
  but never read by the service.

## ✅ What's solid (actively confirmed)

- **No XSS / injection.** `ChatwootMarkdownRenderer` uses CommonMarker `:DEFAULT`
  (raw HTML suppressed), `slugify` restricts to `[\w\s-]`, `summary_html` escapes,
  metafields are JSON-serialized. The only real security item is the scope blast
  radius (M8).
- `published: true/false` toggle is correct; inline metafield **write** is correct;
  `to_prepare` guards are idempotent across reloads; comments are timeless (no
  tracking-ref violations); the 6-file structure is proportionate.

## Suggested fix order

1. **Cheap + high-value:** M1 (locale), M3 (unpublish redirect), B3 (4xx/409
   handling), M6 (namespace), M10 (Sentry), M2 (tags).
2. **Resolve open items + spec:** M4/§10 (blog rename-vs-create), M9 (§8 reconnect),
   M8 (document scope), M5 (lifecycle behavior + spec).
3. **Structural (gated by V1/V2):** B1 + B2 idempotency rework (persist Shopify
   article_id or GraphQL lookup; pagination; backfill throttle).

## Live-store verification checklist (V1, V2, B3 handle behavior)

V1/V2 are resolved in code (above). The remaining items are operational —
confirm during the post-deploy reconnect/backfill, not blocking:

- [x] ~~Redirect scope~~ — **done in code**: initializer requests
      `read/write_online_store_navigation` (required for `UrlRedirect`). Operational:
      confirm the reconnect grants them.
- [x] ~~Article metafields path~~ — **done in code**: corrected to
      `articles/{id}/metafields.json` (verified against the 2025-01 spec).
- [ ] Create two articles whose titles slugify to the same handle — does Shopify
      `409`, or auto-suffix the handle (`-1`)? Either way the code now skips+alerts,
      but worth observing once. **(B3 / §10)**
- [ ] Confirm `global.title_tag` / `global.description_tag` metafields write without
      a pre-existing metafield definition on the shop. **(B1 partial-create)**
