# UMI patches

The `umi` branch currently sits on upstream **`v4.14.2`**.
Each patch below is a commit on top of that tag. Keep this list in sync on every rebase.

| # | Patch | Files | Why | Remove when |
|---|---|---|---|---|
| 1 | Facebook Graph API v21 + HUMAN_AGENT tag | `config/initializers/zz_umi_facebook_fix.rb` | Bundled `facebook-messenger` gem pins removed Graph API **v3.2** → outbound FB fails; Chatwoot also sends the deprecated **`ACCOUNT_UPDATE`** tag (Meta subcode 1893061). Repins v21.0 + switches to `HUMAN_AGENT`. | Upstream bumps the gem's Graph version AND replaces the ACCOUNT_UPDATE tag. |
| 2 | Widget home: composer + messenger links | `app/javascript/widget/views/Home.vue`, `app/javascript/widget/components/pageComponents/Home/UmiHomeComposer.vue`, `app/javascript/widget/components/pageComponents/Home/UmiInboxLinks.vue` | Make the widget home a self-contained assistant: a **type-to-chat composer** (start the chat by typing — skips the "Start conversation" step) and **quick links to WhatsApp / LINE / Messenger / Instagram**, alongside the existing Help Center articles. Lets the storefront "Assistance" button open the widget directly so the custom theme drawer can be retired. | **Frontend core edit — keep** while the storefront relies on it (UMI product behaviour). Re-check `Home.vue` and the `conversation/sendMessage` action on each rebase. |
| 3 | Help Center → Shopify "help" blog sync | `umi/app/services/shopify/help_center_sync_service.rb`, `umi/app/jobs/shopify/help_center_sync_job.rb`, `umi/app/models/shopify_help_center_syncable.rb`, `config/initializers/zz_umi_shopify_help_center.rb`, `lib/tasks/umi_help_center.rake`, `spec/services/umi/shopify/help_center_sync_service_spec.rb`; **core edit:** `config/application.rb` (wires the `umi/` overlay under the `Umi::` namespace via `push_dir`); docs: `UMI-SHOPIFY-HELP-CENTER-SPEC.md`, `UMI-SHOPIFY-HELP-CENTER-REVIEW.md` | Mirror Chatwoot Help Center articles to the storefront so the FAQ is server-rendered + SEO-indexed at `/blogs/help/<article>`. Reuses the **existing Shopify integration token** (Integrations::Hook `app_id:"shopify"`) — adds `read_content`/`write_content` + `read_online_store_navigation`/`write_online_store_navigation` to its OAuth scopes. Chatwoot stays the source of truth. | A native Chatwoot ↔ Shopify content sync ships upstream, or UMI stops mirroring the FAQ to the storefront. |

## Patch details

### 1. Facebook send fix (`zz_umi_facebook_fix.rb`)
Idempotent initializer (safe even if upstream fixes it): re-pins
`Facebook::Messenger::{Bot,Profile,Subscriptions}` base_uri to
`graph.facebook.com/v21.0/me` and prepends a module on
`Facebook::SendOnFacebookService` swapping the `ACCOUNT_UPDATE` message tag for
`HUMAN_AGENT`. Mirrors the runtime patch previously mounted by `umi-vps-infra`;
baking it into the image lets us drop that mount.

### 2. Widget home: composer + messenger links

Two new self-contained Vue components rendered on the widget **home** screen
(`views/Home.vue`, +2 imports / +2 template lines):

- `UmiHomeComposer.vue` — a textbox; on submit it dispatches
  `conversation/sendMessage` (the same action `ChatFooter` uses — it creates the
  conversation when none exists) and routes to the `messages` view. Visitors
  type to start chatting instead of clicking a "Start conversation" button.
  Falls back to the standard pre-chat-form flow when one is configured for a
  brand-new visitor.
- `UmiInboxLinks.vue` — quick links to UMI's other channels (WhatsApp, LINE,
  Messenger, Instagram). **URLs are hardcoded** for UMI; icons are inlined so the
  component doesn't depend on a bundled icon set.

The placeholder string ("Type your message…") and the "Chat with us on" label are
**hardcoded English** (no i18n key) to avoid touching the locale files.

Help Center articles already render on home via `ArticleContainer` — connect a
portal to the inbox to populate them.

### 3. Help Center → Shopify "help" blog sync

Rebase-safe initializer (`zz_umi_shopify_help_center.rb`) that, at boot:

1. Adds `read_content` + `write_content` + `read_online_store_navigation` +
   `write_online_store_navigation` to `Shopify::IntegrationHelper::REQUIRED_SCOPES`
   (reassigns the frozen constant — no edit to the helper file), so the
   **existing** Shopify OAuth token can write blog content and URL redirects.
   **Requires a one-time reconnect** of the Shopify integration to grant the new
   scopes. The reassign is guarded: if upstream renames the constant or changes it
   from an Array, the patch no-ops and logs loudly. Upstream value as of v4.14.2:
   `%w[read_customers read_orders read_fulfillments]` (re-verify on each rebase).
2. Includes `Umi::ShopifyHelpCenterSyncable` into `Article` — `after_commit`
   hooks enqueue `Umi::Shopify::HelpCenterSyncJob` on create/update/destroy, but
   only for the configured portal + locale (`UMI_HC_PORTAL_SLUG` default
   `umi-help`, `UMI_HC_LOCALE` default `en`).

`Umi::Shopify::HelpCenterSyncService` (namespaced under `Umi::` to avoid colliding
with a future upstream `Shopify::` content sync) does the work off the save path:
- builds a `ShopifyAPI::Clients::Rest::Admin` from the account's
  `Integrations::Hook` (same pattern as the orders sidebar), API `2025-01`;
- renders the body with **`ChatwootMarkdownRenderer#render_article`** so the
  storefront HTML matches the portal exactly;
- upserts the article into the `help` blog, matched idempotently by the
  `custom.chatwoot_id` metafield, falling back to handle match so a dropped or
  unavailable metafield can't duplicate (also sets `chatwoot_slug`,
  `chatwoot_category_slug`, `chatwoot_position`, and `global.title_tag` /
  `description_tag` for SEO);
- published → `published:true`; draft/archived → `published:false`;
  destroyed → delete + a `301` from `/blogs/help/<slug>` to
  `UMI_HC_DELETE_REDIRECT` (default `/pages/help`); slug rename → `301` old→new
  (only while published — never 301s to a draft handle);
- transient Shopify errors (429/5xx) re-raise so Sidekiq retries; permanent 4xx
  (incl. a duplicate-handle 409) are reported once and skipped, not retried forever.

If the Shopify hook is absent or lacks `write_content`, the sync no-ops with a
single log line (so it's inert until the integration is reconnected).

The full design, the multi-reviewer findings, and the remaining open items /
accepted MVP limitations (per-edit N+1 metafield scan, 250-article lookup cap,
category-rename/portal-move propagation) live in `UMI-SHOPIFY-HELP-CENTER-SPEC.md`
and `UMI-SHOPIFY-HELP-CENTER-REVIEW.md`.

Config (all optional): `UMI_HC_PORTAL_SLUG`, `UMI_HC_LOCALE`, `UMI_HC_BLOG_HANDLE`
(default `help`), `UMI_HC_BLOG_TITLE`, `UMI_HC_ARTICLE_AUTHOR`,
`UMI_HC_DELETE_REDIRECT`, `UMI_HC_BACKFILL_SPACING_SECONDS` (default `3`).

<!-- Add new patches here as commits, newest last. -->

## Notes / candidates (not yet patched)
- Instagram-via-Instagram-Login long-lived token exchange fails for Facebook-Page-linked
  accounts ("Unsupported request"). UMI uses the **Facebook-page IG path** instead
  (`Channel::FacebookPage.instagram_id`), so no patch needed — documented in
  `umi-vps-infra/docs/INFRA_SPEC.md`.
