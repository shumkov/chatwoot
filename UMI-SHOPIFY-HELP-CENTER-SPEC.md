# Chatwoot Help Center → Shopify FAQ (Chatwoot plugin)

> **Provenance.** Mirrored from the canonical Google Doc
> ([spec v2](https://docs.google.com/document/d/1audvu50vAAvYfl1KqIUcSTmR-qACqFR1h1RE42HVwWI/edit)),
> "Updated: 2026-06-17". The Google Doc remains the single source of truth; keep
> this file in sync when the Doc changes.

**Status:** spec v2 — design locked, implementation in draft PR
[shumkov/chatwoot#2](https://github.com/shumkov/chatwoot/pull/2). Supersedes the
v1 "bridge service" design (dropped).
**Driver:** Ivan Shumkov. **Updated:** 2026-06-17.
**Repos:** `shumkov/chatwoot` (the plugin), `shumkov/umi-store-theme`
(PR #50, theme read side).

## 1. Goal

Keep the storefront FAQ in lock-step with the Chatwoot Help Center, with Chatwoot
as the single source of truth. Authors edit once in Chatwoot; every
create/edit/rename/delete propagates to the Shopify `help` blog automatically, so
the FAQ is server-rendered, SEO-indexed, and searchable at
`umi.store/blogs/help/<article>`.

## 2. Why a Chatwoot plugin (not a separate bridge)

The deployed fork is `umi-v4.14.2`, which already ships Chatwoot's native Shopify
integration: an OAuth app (`SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET`,
`/shopify/callback`) whose per-account access token is stored as an
`Integrations::Hook` (`app_id "shopify"`, `access_token`, `reference_id` = shop
domain). Rather than run a separate service with its own token, the sync lives
inside Chatwoot and reuses that existing connection. Fewer moving parts, one
token, in-process retries via Sidekiq.

## 3. Decisions (locked)

- **Source of truth:** Chatwoot Help Center — portal `umi-help`, locale `en`
  (~47 published articles, 12 categories).
- **Target:** Shopify blog handle `help` → `/blogs/help/<article>`. Index page
  `/pages/help` (theme).
- **Mechanism:** in-Chatwoot plugin. `Article after_commit` → Sidekiq job → sync
  service.
- **Auth:** reuse the existing Shopify integration token (`Integrations::Hook`).
  Add `read_content` + `write_content` (blog/article) and
  `read_online_store_navigation` + `write_online_store_navigation` (URL redirects)
  to its OAuth scopes; one-time reconnect.
- **Body HTML:** render with Chatwoot's own `ChatwootMarkdownRenderer#render_article`
  so storefront output matches the portal exactly.
- **Idempotency:** match by `custom.chatwoot_id` metafield. If the handle is
  already taken by an article we don't own (collision / dropped metafield), skip
  and alert — never overwrite or duplicate.
- **Deletion:** hard delete in Shopify on Chatwoot delete (+ `301` →
  `/pages/help`). Draft/archived → unpublish (`published:false`).
- **Redirects:** `301` on rename (old→new, only while published) and delete;
  covered by `write_content` / `write_online_store_navigation`.
- **Fork hygiene:** rebase-safe per `CONTRIBUTING-UMI` — one initializer + new
  files, no core-file edits.

## 4. Architecture

Author edits article in Chatwoot → `Article after_commit`
(create/update/destroy) → `Umi::Shopify::HelpCenterSyncJob` (Sidekiq) →
`Umi::Shopify::HelpCenterSyncService` → Shopify Admin API (using the account's
Shopify hook token) → blog `help` → theme renders `/pages/help` +
`/blogs/help/<article>`. All in-process; no external service, no public webhook
endpoint, no TLS/domain.

## 5. Components (in `shumkov/chatwoot`, PR #2)

> **Where UMI code goes:** all UMI-owned app code lives in the top-level **`umi/`
> overlay** (`umi/app/services/…`, `umi/app/jobs/…`, `umi/app/models/…`), under the
> `Umi::` namespace — **not** in `app/`. `config/application.rb` wires each
> `umi/app/*` dir under `Umi::` with `Rails.autoloaders.main.push_dir(dir,
> namespace: Umi)`, so paths stay flat (no `umi/app/services/umi/` nesting) while
> constants are namespaced (collision-safe). Concern modules go directly under
> `umi/app/models/` — an overlay `concerns/` folder is **not** auto-collapsed (it
> would land under `Umi::Concerns::`). Initializers stay in
> `config/initializers/zz_umi_*.rb`, rake tasks in `lib/tasks/umi_*.rake`, specs in
> `spec/`.

- `config/application.rb` — wires the `umi/` overlay under `Umi::` via `push_dir`
  (the one core edit).
- `config/initializers/zz_umi_shopify_help_center.rb` — at boot (`to_prepare`):
  adds `read_content` + `write_content` to
  `Shopify::IntegrationHelper::REQUIRED_SCOPES` (reassigns the frozen constant;
  no helper edit) and includes `Umi::ShopifyHelpCenterSyncable` into `Article`.
- `umi/app/models/shopify_help_center_syncable.rb` — `after_commit` hooks; enqueue
  the job only for portal `UMI_HC_PORTAL_SLUG` (default `umi-help`) and locale
  `UMI_HC_LOCALE` (default `en`). Snapshots article fields so deletes work too.
- `umi/app/jobs/shopify/help_center_sync_job.rb` — thin ActiveJob wrapper
  (queue `:low`).
- `umi/app/services/shopify/help_center_sync_service.rb` — builds
  `ShopifyAPI::Clients::Rest::Admin` from the hook (API `2025-01`);
  upsert/unpublish/delete; idempotent by `chatwoot_id` with a handle fallback;
  sets SEO + traceability metafields; manages `301`s; retries 429/5xx, skips 4xx.
- `lib/tasks/umi_help_center.rake` — `umi:help_center:backfill` — seed/repair:
  enqueue every published `en` article (the `after_commit` only fires on future
  changes), spaced out to respect Shopify's rate limit.
- `spec/services/umi/shopify/help_center_sync_service_spec.rb` — unit spec for the
  pure mapper (slug, payload, tags, metafields, summary, markdown render).

## 6. Field mapping (Chatwoot article → Shopify)

- `id` → metafield `custom.chatwoot_id` (`number_integer`) — idempotency key.
- `title` → `article.title`; `handle = slugify(title)` (Chatwoot slug has numeric
  ids, bad SEO).
- `content` (markdown) → `body_html` via
  `ChatwootMarkdownRenderer#render_article`.
- `description` → `summary_html` (fallback: first 160 chars of stripped body) +
  `global.description_tag`.
- `category.name` → `tags` (single tag, verbatim incl. `&`; uncategorized → empty
  tag, no phantom default); `category.slug` → `custom.chatwoot_category_slug`.
- `position` → `custom.chatwoot_position`; `slug` → `custom.chatwoot_slug`;
  `title` → `global.title_tag` (SEO).
- `status`: `published` → `published:true`; `draft`/`archived` →
  `published:false`; destroyed → delete + redirect.

## 7. Deployment

Per `CONTRIBUTING-UMI`: merge PR #2 into the `umi` branch → CI builds a preview
image (`ghcr.io/shumkov/chatwoot:umi-<branch>`) for staging smoke-test → tag
`umi-v4.14.2` (re-tag) or next release → GHCR build → bump `chatwoot_version` in
`umi-vps-infra` and deploy (pg_dump first).

## 8. Required manual steps

- Reconnect the Shopify integration in Chatwoot after deploy so the stored token
  gains `write_content`. Until then the sync no-ops (one log line).
- Run `umi:help_center:backfill` once to seed the existing 47 articles.
- Theme: rename the blog handle `help-center` → `help` in PR #50 (deferred until
  the plugin is ready).

## 9. Config (ENV, all optional)

- `UMI_HC_PORTAL_SLUG` (default `umi-help`) — only this portal syncs.
- `UMI_HC_LOCALE` (default `en`) — only this locale syncs.
- `UMI_HC_BLOG_HANDLE` (default `help`), `UMI_HC_BLOG_TITLE` (default
  `Help Center`).
- `UMI_HC_ARTICLE_AUTHOR` (default `UMI`), `UMI_HC_DELETE_REDIRECT` (default
  `/pages/help`).
- `UMI_HC_BACKFILL_SPACING_SECONDS` (default `5`) — delay between backfill jobs.
- Shopify OAuth app: `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` (already
  configured for the integration).

## 10. Open items

> Expanded by the multi-reviewer pass (2026-06-17) — see
> [`UMI-SHOPIFY-HELP-CENTER-REVIEW.md`](./UMI-SHOPIFY-HELP-CENTER-REVIEW.md) for
> the full findings, severities, and `file:line` references. **Reconcile these
> back into the Google Doc** so it stays the single source of truth.

### Verified against the shopify_api 2025-01 spec (2026-06-18)

- **Redirect OAuth scope — resolved.** URL redirects require
  `write_online_store_navigation` (Shopify's access-scopes table maps `UrlRedirect`
  there; `write_content` does **not** cover it). The initializer requests
  `read/write_online_store_navigation` alongside `read/write_content`, so the
  rename/delete 301s work once the integration is reconnected.
- **Article metafields endpoint — fixed.** The 2025-01 REST API addresses article
  metafields at `articles/<id>/metafields.json` — there is **no**
  `blogs/.../articles/.../metafields.json` path. The lookup was corrected, so
  idempotency-by-metafield works (no silent fall-through to handle-only matching).

### Must fix before merge

- **Idempotency / duplicates:** verify the `chatwoot_id` metafield actually landed
  after create (POST response is currently discarded); add a `handle` guard;
  paginate past the silent 250-article cap.
- **Backfill rate limits:** the per-sync metafield scan is `1 + N` API calls
  (~2,200 for a 47-article backfill vs Shopify's ~2 req/s) → 429 storm. Persist the
  Shopify `article_id` on the Chatwoot side (or use a single GraphQL metafield
  query) and stagger the backfill.
- **4xx / 409 handling:** branch on status — log + Sentry + skip on 4xx (incl. the
  title-collision case below), re-raise only `429`/`5xx`. Today all errors retry 3×
  then die silently.
- **Locale filter:** the concern gates only on portal slug; enforce `locale == 'en'`
  (spec §3) in both the concern and the rake query, or two locales collide on handle.
- **Unpublish-with-rename:** redirect the old handle to `/pages/help`, not to a
  now-private draft handle (which 301s to a 404).
- **Tags:** `category.name` is sent verbatim into Shopify's comma-separated `tags`;
  a comma in a category name splits it. Decide the uncategorized → `'General'` default.

### Decisions to lock

- **Title-collision:** does Shopify `409` or auto-suffix the handle? Either way,
  handle it (skip + alert) rather than letting it surface to retry.
- **Existing `help-center` blog:** rename to `help` before backfill, and have the
  service fail loud if the blog is absent rather than auto-creating a fresh one
  (auto-create masks a missing/misnamed blog and can race-create duplicates).
- **Reconnect = disconnect first:** `Integrations::Hook` is unique per
  `account_id`+`app_id` and the callback does `create!`, so §8's "reconnect" must
  delete the existing hook first; a naive reconnect throws into an opaque `?error=true`.
- **Lifecycle propagation:** category rename/delete and article-moved-out-of-portal
  currently don't propagate (stale tags / orphaned Shopify article). Decide whether
  to handle or document as a known limitation (a `Category after_commit` re-sync, or
  rely on backfill).
- **Scope blast radius:** `write_content` on the shared `REQUIRED_SCOPES` also
  re-scopes the orders-sidebar token — accept consciously; confirm token-at-rest
  encryption.
- **Rebase safety:** the `REQUIRED_SCOPES` `remove_const`/`const_set` is
  conflict-free but drift-invisible — add a fail-loud guard and pin the upstream
  value in `UMI-PATCHES.md`. Move `Shopify::HelpCenterSync{Job,Service}` under
  `Umi::` to avoid colliding with the upstream feature that is this patch's remove-when.

### Accepted / backstop

- **April-2026 token policy (#14462):** `write_content` (blogs) is not protected
  customer data, so adding it should be clean — confirm on reconnect.
- **Drift backstop:** in-process sync rarely misses; `umi:help_center:backfill`
  doubles as a manual reconcile. A scheduled reconcile can be added later if needed.
