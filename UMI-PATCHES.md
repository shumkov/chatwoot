# UMI patches

The `umi` branch currently sits on upstream **`v4.16.0`**.
Each patch below is a commit on top of that tag. Keep this list in sync on every rebase.

| # | Patch | Files | Why | Remove when |
|---|---|---|---|---|
| 1 | Facebook Graph API v21 + HUMAN_AGENT tag | `config/initializers/zz_umi_facebook_fix.rb` | Bundled `facebook-messenger` gem pins removed Graph API **v3.2** → outbound FB fails. Repins v21.0, and enables Chatwoot's built-in `ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT` (so replies use the 7-day `HUMAN_AGENT` window) instead of the default `RESPONSE` — via the flag, not a service override. | Upstream bumps the gem's Graph version (the HUMAN_AGENT part is just config — drop by unsetting the flag). |
| 2 | Widget home: storefront-aligned assistance UI | `app/javascript/widget/views/Home.vue`, `.../Home/UmiHomeComposer.vue`, `.../Home/UmiInboxLinks.vue`, `.../Home/UmiHomeWelcome.vue`, `.../Home/Article/{ArticleContainer,ArticleBlock,ArticleListItem}.vue`, `app/javascript/widget/components/{ChatHeader.vue,layouts/ViewWithHeader.vue}`, `app/javascript/widget/i18n/locale/{en,th}.json`, `app/javascript/widget/assets/scss/{woot.scss,_umi-theme.scss}`; docs: `docs/UMI-WIDGET-HOME-SPEC.md` | Make the widget home a self-contained assistant matching the UMI storefront (drawer shell shipped theme-side). Header shows a translatable **"Assistance"** (overrides the inbox name so the agent UI stays "Website"); a **time-aware welcome** ("available within minutes" during 9 AM–9 PM Bangkok, every day; otherwise a countdown to 9 AM); a single input block — **type-to-chat composer** when there's no conversation, **"Continue conversation"** when one exists; **quick links to WhatsApp / LINE / Messenger / Instagram**; and Help Center articles that open on the **storefront** (`/blogs/help/<slug>`, "View all" → `/pages/help`) instead of the in-drawer viewer. Order: welcome → articles → links → composer. A storefront-alignment SCSS layer (`_umi-theme.scss`, imported last in `woot.scss`) restyles the widget to Helvetica, squared corners, white surfaces, black accents, and flat (no shadows). | **Frontend core edit — keep** while the storefront relies on it (UMI product behaviour). Re-check `Home.vue`, `ViewWithHeader.vue`, `ArticleContainer` and the `conversation/sendMessage` action on each rebase. |
| 3 | Help Center → Shopify "help" blog sync | `umi/app/services/shopify/help_center_sync_service.rb`, `umi/app/jobs/shopify/help_center_sync_job.rb`, `umi/app/models/shopify_help_center_syncable.rb`, `config/initializers/zz_umi_shopify_help_center.rb`, `lib/tasks/umi_help_center.rake`, `spec/services/umi/shopify/help_center_sync_service_spec.rb`; **core edit:** `config/application.rb` (wires the `umi/` overlay under the `Umi::` namespace via `push_dir`); docs: `UMI-SHOPIFY-HELP-CENTER-SPEC.md`, `UMI-SHOPIFY-HELP-CENTER-REVIEW.md` | Mirror Chatwoot Help Center articles to the storefront so the FAQ is server-rendered + SEO-indexed at `/blogs/help/<article>`. Reuses the **existing Shopify integration token** (Integrations::Hook `app_id:"shopify"`) — adds `read_content`/`write_content` + `read_online_store_navigation`/`write_online_store_navigation` to its OAuth scopes. Chatwoot stays the source of truth. | A native Chatwoot ↔ Shopify content sync ships upstream, or UMI stops mirroring the FAQ to the storefront. |
| 4 | Voice (calls): inbound Twilio → SIP softphone | `umi/app/services/voice.rb`, `umi/app/services/voice/twiml/dial_builder.rb`, `umi/app/services/voice/inbound_resolver.rb`, `umi/app/controllers/voice/webhooks_controller.rb`, `umi/app/models/channel/twilio_sms.rb`, `config/initializers/zz_umi_voice.rb`, `spec/umi/voice/twiml/dial_builder_spec.rb`; docs: `docs/CALLS_BACKEND_SPEC.md`, `docs/GROUNDWIRE_AGENT_SETUP.md` | Agent calling on phones via Twilio + Acrobits Groundwire SIP softphone — no native app, no premium-gated EE voice. Inbound Twilio call → `<Dial><Sip>` rings the on-duty agents' Groundwire with the Chatwoot contact name injected via `Remote-Party-ID`, **and logs the call** (Contact→Conversation→`voice_call` message screen-pop + status/duration tracking). **Outbound click-to-call** rings the agent's softphone then bridges to the contact, plus **optional call recording**. WhatsApp follows. Includes `Umi::Call#direction_label` so upstream's native `GET /calls` serializer renders the repointed `calls` association without a 500. | **Remove-when now firing:** upstream v4.16.0 shipped native voice on the same `calls` table (a `GET /calls` endpoint + a native `Call` model). Reconcile `Umi::Call` with that native `Call` (extend it, or retire the repoint) — see the reconciliation note below — or drop this patch once native voice is unlocked/usable for UMI. |
| 5 | Email inbox: read a Gmail label, not INBOX | `umi/app/services/imap/configurable_folder.rb`, `umi/app/services/imap/preserve_provider_config.rb`, `config/initializers/zz_umi_email_imap_folder.rb` | Stock Chatwoot hardcodes `imap.select('INBOX')`, so a shared reader mailbox (`shumabit@`, a member of the `info@`/`support@` Google Groups) would pull its whole inbox in. Prepends a configurable folder read from `channel.provider_config['imap_folder']` (+ a companion that preserves that key across OAuth token refresh); a Gmail filter labels only the group mail → the inbox ingests only that label, leaving the mailbox's other mail untouched (no archiving, no extra Workspace seat). | Upstream adds a per-inbox source folder/label for the email channel. |
| 6 | Featured Help Center articles (storefront FAQ shortlist) | `umi/app/models/article_featurable.rb`, `umi/app/controllers/public/api/v1/portals/articles_controller.rb`, `config/initializers/zz_umi_featured_articles.rb`, `spec/models/umi/article_featurable_spec.rb`; **edits (UMI-owned):** `umi/app/models/shopify_help_center_syncable.rb`, `umi/app/services/shopify/help_center_sync_service.rb`, `spec/services/umi/shopify/help_center_sync_service_spec.rb`; **widget:** `app/javascript/widget/api/{article,endPoints}.js`, `app/javascript/widget/store/modules/articles.js` (+ spec) | A `featured` axis on Help Center articles, stored in `meta` (orthogonal to `category_id` — no duplication). Concern adds `featured` / `order_by_featured_position` scopes; a prepend extends the public articles endpoint with `?featured=true&sort=featured`; the sync projects `featured`→`featured` tag + `featured_position`→`custom.featured_position` metafield; the widget fetches the featured set (fallback to most-read). Drives the storefront Assistance drawer + Explore FAQ from one curated list. | Upstream ships native article tags / multi-category, or a first-class featured/pinned-article flag. |
| 7 | Shopify customers → Chatwoot contacts sync | `umi/app/services/shopify/{client_factory,sync_lock,contact_sync_watermark,customer_contact_mapper,contact_sync_service}.rb`, `umi/app/jobs/shopify/{contact_backfill_job,contact_poll_job}.rb`, `umi/app/controllers/webhooks/shopify_compliance.rb`, `umi/app/controllers/shopify/persist_customer_link.rb`, `config/initializers/zz_umi_shopify_contacts.rb`, `lib/tasks/umi_shopify_contacts.rake`, specs in `spec/services/umi/shopify/`, `spec/jobs/umi/shopify/`, `spec/controllers/`; refactors patch #3's client construction into the shared `Umi::Shopify::ClientFactory`; docs: `UMI-SHOPIFY-CONTACT-SYNC-INVESTIGATION.md`, `UMI-SHOPIFY-CONTACT-SYNC-SPEC.md` | Proactively seed every Shopify customer as a Chatwoot contact (one-time throttled backfill + 30-min watermark poll on the existing integration token) so first-ever inbound calls/WhatsApp resolve to a real name (voice caller-ID injection is synchronous — only a pre-existing contact helps), agents can outbound-call any customer, and the base is segmentable. Adds the `customers/redact`/`customers/data_request` compliance handlers (core ignores them) and on-touch persistence of `shopify_customer_id` from the orders sidebar. Inert by default: backfill is a manual rake task; the poll cron registers only with `UMI_SHOPIFY_CONTACT_SYNC_ENABLED`. | Upstream ships a native Shopify customer sync, or UMI stops proactive contact seeding. |
| 8 | FB/IG inbound message tracing | `config/initializers/zz_umi_fbig_trace.rb`, `umi/app/services/fbig_trace.rb`, `spec/umi/fbig_trace_spec.rb`; docs: `docs/UMI-FBIG-MESSAGE-LOSS-SPEC.md` | Meta delivers each webhook once (no history API) and the stock FB/IG inbound pipeline drops messages **silently** in many places (signature 400/401s, `standby` entries, unknown channels/pages, dedup, builder early-returns, reauth skips). Every decision point now logs one grep-able `[UMI-FBIG] stage=… key=value` line (`webhook_received` / `dispatch` / `rejected` / `dropped` / `persisted` with reasons + mids), so a production drop leaves a diagnosable trail. Never changes control flow; kill switch `UMI_FBIG_TRACE_DISABLED=true`. | Upstream ships equivalent per-message observability for the Meta webhook pipeline. |
| 9 | IG mixed-batch event dispatch fix | `config/initializers/zz_umi_ig_event_dispatch_fix.rb`, `umi/app/jobs/webhooks_instagram_event_dispatch.rb`, `spec/umi/webhooks/instagram_events_job_dispatch_spec.rb` | Upstream `Webhooks::InstagramEventsJob#event_name` memoizes the first messaging item's event type across the batch loop, so a webhook batching `read` + `message` items dispatches later items to the wrong handler — the message crashes ReadStatusService and is **permanently lost**. Prepend resolves the event per item. | Upstream drops the `@event_name ||=` memoization (good first-PR candidate to chatwoot/chatwoot). |
| 10 | IG fallback contact (persist DMs when profile fetch fails) | `config/initializers/zz_umi_ig_fallback_contact.rb`, `umi/app/services/instagram_fallback_contact.rb`, `spec/umi/services/instagram/messenger/message_text_fallback_spec.rb` | On the FB-page-linked IG path, a first-time contact's DM is silently dropped whenever the Graph profile fetch fails — missing **Advanced Access** to `instagram_manage_messages` (chatwoot#11578), error 230 (user consent), 9010, expired token. Prepend creates the contact from the IG-scoped id with a placeholder name (`Instagram user <last4>`) so the DM always persists; placeholder sticks until an agent renames it. | Upstream persists the message (or creates a fallback contact) on profile-fetch failure, and UMI's `instagram_manage_messages` Advanced Access is approved + verified. |
| 11 | Keep FB/IG message when attachment download fails | `config/initializers/zz_umi_fbig_attachment_resilience.rb`, `umi/app/builders/messenger_attachment_resilience.rb`, `spec/umi/builders/messages/facebook/message_builder_attachment_spec.rb` | Both Messenger-family builders download attachments **inside** the message-creation transaction; an expired Meta CDN URL (`Down::Error`) rolled back the message row and lost the whole message, text included. Prepend rescues per attachment (logs `stage=attachment_failed` + tracker) so the message survives with whatever attachments could be stored. | Upstream moves attachment downloads out of the message transaction or rescues per attachment. |
| 12 | FB/IG reconciliation vs Meta Conversations API (+opt-in auto-heal) | `umi/app/services/fbig/{conversation_recon_service,message_heal_service}.rb`, `umi/app/jobs/fbig/conversation_recon_job.rb`, `config/initializers/zz_umi_fbig_recon.rb`, specs in `spec/services/umi/fbig/`, `spec/jobs/umi/fbig/`; docs: `docs/UMI-FBIG-RECON-SPEC.md` | Webhook-side code can't see messages **Meta never delivered** (subscription outages/misconfig — e.g. the `message_echoes` gap found 2026-07-22 — or drops predating the pipeline patches). Daily cron (03:30 Bangkok, `low` queue) lists all in-window (48 h) message ids from the Graph Conversations API for both platforms and anti-joins against `messages.source_id`: misses log `reconcile_missing` lines (direction+sender, `suspect=multipart` labeling for the N-parts-one-row outbound class) + an always-emitted per-platform `reconcile_summary` (from `ensure`; auth errors stand down without retries). With `UMI_FBIG_RECON_HEAL=true` (default **off**), inbound hard misses are replayed through the regular webhook builders and stamped `umi_recovered`. Kill switch `UMI_FBIG_RECON_DISABLED=true`. Spike-validated against prod (mid formats match; found a real missing FB message from 2026-06-29 — the Business-Suite echo class). | Upstream ships webhook-delivery reconciliation for Meta channels, or Meta provides delivery guarantees/replay. |
| 13 | FB contact names via Conversations participants (John Doe fix) | `umi/app/services/fbig/participant_name_service.rb`, `umi/app/builders/facebook_contact_name_fallback.rb`, `config/initializers/zz_umi_fb_contact_name_fallback.rb`, `spec/umi/builders/messages/facebook/message_builder_name_fallback_spec.rb`; **core-spec edit:** one stub line in `spec/builders/messages/facebook/message_builder_spec.rb` | Meta denies the `/PSID` profile API without the **Business Asset User Profile Access** feature (never requested pre-2026-07-23; App Review pending) and for pre-app-connection threads (error 100/33) — upstream then permanently names contacts "John Doe". Fallback resolves the name via the page-inbox Conversations API `participants` field (`?user_id=<psid>`; the source Business Suite shows; needs only already-held permissions); any lookup failure keeps stock behaviour. Prod-verified: resolved all 12 profile-locked senders. | Business Asset User Profile Access granted + profile API resolving all new senders in practice (`stage=participant_name_used` lines go quiet), or upstream ships an equivalent fallback. |
| 14 | Historical FB/IG archive import | `umi/app/services/fbig/history_import_*.rb`, `umi/app/services/fbig/{history_approval_manifest,history_profile_backfill_service,history_state_*,profile_*,avatar_*,contentless_fingerprint,sanitized_koala_api,typed_value_digest}.rb`, `umi/app/services/fbig/message_heal_service.rb`, `lib/tasks/umi_fbig_history_import.rake`, `script/umi_fbig/{build_programs.rb,programs/*.sh,support/*}`, `db/migrate/*_add_unique_contact_avatar_attachment_index.rb`, `db/schema.rb`, focused specs in `spec/services/umi/fbig/`, `spec/script/umi_fbig/`, `spec/models/active_storage/`, and `spec/lib/tasks/rake/`; docs: `docs/UMI-FBIG-{HISTORY-IMPORT-SPEC,FULL-HISTORY-EXPANSION-SPEC,FULL-HISTORY-RUNBOOK}.md` | One-time, digest-bound import of every Messenger/Instagram thread and message Meta still exposes. History and profile enrichment are separate: approved history runs are always profile-deferred, append only missing messages, create no empty archives, durably reconcile interrupted attachment uploads, and accept unavailable bodies only by exact per-platform fingerprints. A later rate-aware profile task scans stable participants without rereading messages, repairs only exact generated placeholders, fills only blank/absent profile fields, preserves avatars, and seals PII-free pre/post/avatar-staging evidence. Production additionally requires protected standalone phase programs and immutable support helpers, protected root-path ancestry, a terminal clone-acceptance manifest, exact one-off/running image-and-commit proof, checksum-bound same-platform dry pairs before apply, crash-adoptable single-platform graph deltas with bounded snapshots, a cutoff-to-completion checkpoint chain, evidence-producing delivery audits between resumable profile windows, separate terminal zero-write history passes, a terminal zero-write profile pass, and final repeatable-read live reconciliation with audited platform totals and exact remaining-placeholder classification. Strict immutable approvals, same-process DB identity, a renewable writer lock, callback-free inert archives, coordinated DB/storage backups, and a partial unique Contact/avatar index make apply and recovery fail closed. | Upstream provides a callback-safe Meta history/profile importer with immutable acceptance evidence and equivalent recovery controls; or UMI completes and audits the one-time migration, then removes the manual importer while retaining any still-shared lock/index behavior. |

## Patch details

### 1. Facebook send fix (`zz_umi_facebook_fix.rb`)
Idempotent initializer (safe even if upstream fixes it): re-pins
`Facebook::Messenger::{Bot,Profile,Subscriptions}` base_uri to
`graph.facebook.com/v21.0/me`, and turns on Chatwoot's built-in
`ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT` (`ENV[...] ||= 'true'`, skipped in test) so
`Facebook::SendOnFacebookService#merge_human_agent_tag` (and the Instagram
equivalent) sends the `HUMAN_AGENT` tag. This replaces an earlier `prepend` that
hardcoded the tag — using the flag keeps the upstream default-`RESPONSE` specs
green and is one fewer service override to maintain on rebase.

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
   from an Array, the patch no-ops and logs loudly. Upstream value as of v4.16.0 (unchanged since v4.14.2):
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

`ShopifyAPI::Context.setup` reloads the `shopify_api` gem's shared Zeitwerk loader
on every call, so running it per job across Sidekiq's concurrent worker threads
raced the loader and raised `Zeitwerk::SetupRequired`. The service now configures
the context **once per process**, guarded by `ShopifyAPI::Context.setup?` +
a class `Mutex` (double-checked locking), instead of on every `#client` build.

The full design, the multi-reviewer findings, and the remaining open items /
accepted MVP limitations (per-edit N+1 metafield scan, 250-article lookup cap,
category-rename/portal-move propagation) live in `UMI-SHOPIFY-HELP-CENTER-SPEC.md`
and `UMI-SHOPIFY-HELP-CENTER-REVIEW.md`.

Config (all optional): `UMI_HC_PORTAL_SLUG`, `UMI_HC_LOCALE`, `UMI_HC_BLOG_HANDLE`
(default `help`), `UMI_HC_BLOG_TITLE`, `UMI_HC_ARTICLE_AUTHOR`,
`UMI_HC_DELETE_REDIRECT`, `UMI_HC_BACKFILL_SPACING_SECONDS` (default `3`).

### 4. Voice (calls): inbound Twilio → SIP softphone

Agents take calls on their phones in **Acrobits Groundwire** (a SIP softphone, ~$10,
no app to build) registered to a **Twilio SIP Domain**; Chatwoot orchestrates + logs.
This P0 increment wires the **inbound** path:

- `config/initializers/zz_umi_voice.rb` appends the Twilio webhook routes
  (`/umi/voice/:phone/{incoming,status,dial_status}`) and prepends
  `Umi::Channel::TwilioSms` onto `Channel::TwilioSms` (in `to_prepare`) — no core-file edits.
- `Umi::Voice::WebhooksController#incoming` resolves the channel by `:phone`, validates the
  Twilio request signature (proxy-aware URL via `FRONTEND_URL`; skippable in dev with
  `UMI_VOICE_SKIP_SIGNATURE`), and renders `Umi::Voice::Twiml::DialBuilder` output.
- `Umi::Voice::Twiml::DialBuilder` emits `<Dial answerOnBridge><Sip>` for each on-duty agent,
  **dialing the GLOBAL SIP domain** (`…sip.twilio.com`, not the edge — edge dialing fails with
  Twilio error 32220) and injecting the contact name into the **`Remote-Party-ID`** header.
  Groundwire shows that name only when its *Incoming Caller ID* priority lists Remote-Party-ID
  first (see `docs/GROUNDWIRE_AGENT_SETUP.md`).
- Agents register on the **Singapore edge** (`…sip.singapore.twilio.com`); the Twilio account is
  US1 (data residency US). Config: `UMI_VOICE_SIP_DOMAIN`, `UMI_VOICE_AGENTS` (override the
  ring set, e.g. the pilot's `agent1`), `FRONTEND_URL`.

Call logging is owned by `Umi::Call` (on the existing `calls` table); the host `:call`/`:calls`
associations are repointed to it in the initializer, and the inbound flow runs through
`Umi::Voice::{InboundCallBuilder, CallMessageBuilder, StatusUpdateService}` +
`Umi::Voice::CallStatus::Manager` (terminal-state guards). The `status` and `<Dial action>`
(`dial_status`) callbacks drive status/duration.

**Validated live** on a real iPhone + Trial account: a locked, backgrounded phone rings via
Acrobits SIPIS push, and the injected contact name shows on the call screen. App boots, 19 umi
voice specs green, rubocop clean. Full design + spike results: `docs/CALLS_BACKEND_SPEC.md`.

Outbound **click-to-call**: `POST contacts/:id/call` (overrides the premium-gated enterprise
route via `routes.prepend`) → `Umi::Voice::OutboundCallBuilder` rings the initiating agent's
SIP softphone via the Twilio REST API, then the agent's `outbound_twiml` bridges to the contact;
logged as an outgoing `voice_call`.

**Optional call recording** (opt-in via `UMI_VOICE_RECORDING`, off by default for consent/legal):
`<Dial record="record-from-answer-dual">` → the `recording` callback → `Umi::Voice::RecordingStatusService`
enqueues `Umi::Voice::RecordingAttachmentJob`, which downloads the audio via `SafeFetch` (SSRF-safe,
audio-only) and attaches it to the `Call` (idempotent, row-locked).

**Frontend** (core edits, `ConversationCallButton.vue`, `helper/voice.js`, `conversation.json`):
the header Call button fires click-to-call + a toast (no in-browser Twilio Device), and the
**inbound** in-browser call widget is suppressed via the `UMI_EXTERNAL_SOFTPHONE` flag in
`helper/voice.js` — agents answer on the softphone, while the `voice_call` bubble / call log
still renders and its status keeps updating.

**Mobile tap-to-call** (no app fork). Spiked on a real iOS device: a `link`-type custom attribute is
**copied, not opened**, so the primary mobile trigger is a **macro** (confirmed to run server-side
from the app). A global "📞 Call contact" macro (`umi:voice:create_call_macro[account_id]`) uses
Chatwoot's `send_webhook_event` action to POST the conversation to `POST /umi/voice/macro_dial`
(`macro_dial_controller.rb`, guarded by a static shared secret `Umi::Voice.macro_secret`). The
endpoint rings the conversation **assignee's** softphone and bridges to the contact (reusing the
click-to-call origination), so the call is logged and uses the business number.

An alternative signed-link trigger (`GET/POST /umi/voice/dial/:token`, `mobile_dial_controller.rb`,
`Umi::Voice.dial_url`; attribute + per-contact links provisioned via `Umi::Voice::CallLinkSetup` —
`umi:voice:create_call_attribute` + `backfill_call_links`) remains for surfaces that *open* links
(e.g. a link inside a message) rather than copy them.

**Number onboarding helper** (`otp_capture`): a phoneless Twilio number can't receive a normal
verification call, so `POST /umi/voice/:phone/otp_capture` bridges a provider's voice OTP to a
human. With `?to=+E164` it forwards to a real phone with **answerOnBridge** (the provider waits for
the human to answer before reading, so the full code is heard — and a human answer avoids the
machine-answer errors some providers return); with no `to` it falls back to `<Record transcribe>`.
Point a number's Twilio **Voice URL** here while registering it on a provider that delivers the OTP
by voice (e.g. Meta/WhatsApp Cloud API), then revert the Voice URL to `incoming`. Signature-validated.

**Still WIP** (next): hide the `voice_call` bubble's Join/Call-back buttons for the external-softphone
model; optionally ring the whole on-duty group (conference) on tap-to-call instead of just the
assignee; WhatsApp-via-Twilio — gated on the WhatsApp↔SIP live spike (spec §12 R1).

**Reconciliation with upstream native voice (follow-up, triggered by v4.16.0).** Upstream
v4.16 now ships its own voice on the shared `calls` table: an enterprise `GET /calls`
index (`CallFinder` → `@current_account.calls`) with a native `Call` model, plus
`Channel::TwilioSms#inbound_calls_enabled?` + `set_inbound_calls`, and native
`twilio/voice`/conference webhooks. Because `zz_umi_voice.rb` repoints
`account/conversation/inbox has_many :calls` and `message has_one :call` to `Umi::Call`
(same table), the native `/calls` serializer runs against `Umi::Call`. That endpoint is
enterprise-gated but **has no UI caller in the fork or upstream**, so the only real gap was
its serializer calling `direction_label` — added to `Umi::Call` (mirrors upstream) so it
renders instead of 500-ing; pinned by `spec/enterprise/controllers/api/v1/accounts/calls_controller_spec.rb`.
Remaining `Umi::Call` vs native `Call` gaps (only reached via the dormant native
webhooks/conference flow, which UMI doesn't wire): `from/to_number`, `ringing?`,
`in_progress?`, `default_conference_sid`, `by_conference_sid` scopes, several class
methods/consts, and a `STATUSES` divergence (`Umi::Call` has `missed`, upstream has
`rejected`). **Follow-up:** rework the voice patch to extend the native `Call` (or retire
the repoint and adopt native voice) in a dedicated spec — don't chase full parity inside a
rebase. Re-check this note on each upstream bump; the surface will keep growing as upstream
builds out native voice.

### 5. Email inbox: read a Gmail label instead of INBOX

`Imap::BaseFetchEmailService#build_imap_client` hardcodes `imap.select('INBOX')` (and
`fetch_available_mail_sequence_numbers` searches everything `SINCE` yesterday — no label
or read/unread filter). So an Email inbox connected to a **shared reader mailbox** —
`shumabit@`, a member of the `info@` and `support@` Google Groups — would ingest that
mailbox's *entire* inbox, not just the group mail.

`zz_umi_email_imap_folder.rb` prepends `Umi::Imap::ConfigurableFolder`, which re-selects
the folder named in `channel.provider_config['imap_folder']` after `super` (unset / `INBOX`
→ stock behaviour; a bad label name fails loud on the next fetch rather than silently
ingesting the whole inbox). Paired with a Gmail filter that applies a label (e.g. `Chatwoot`)
to mail addressed to the groups, and that label set to **Show in IMAP**, the inbox ingests
only the labelled group mail — the reader mailbox's other inbox mail is left untouched (no
archiving, no dedicated Workspace seat).

It also prepends `Umi::Imap::PreserveProviderConfig` onto `BaseRefreshOauthTokenService`:
stock `update_channel_provider_config` *replaces* the whole `provider_config` with just the
refreshed tokens, which would drop `imap_folder` on the first Google token refresh (~hourly)
and silently revert to a full-INBOX read — so it **merges** the tokens instead.

`provider_config['imap_folder']` has no UI/API (it's excluded from `Channel::Email::EDITABLE_ATTRS`);
set it via console:
`channel.update!(provider_config: channel.provider_config.merge('imap_folder' => 'Chatwoot'))`.

### 7. Shopify customers → Chatwoot contacts sync

Full design + three-lens review record in `UMI-SHOPIFY-CONTACT-SYNC-SPEC.md`
(pros/cons + alternatives in `UMI-SHOPIFY-CONTACT-SYNC-INVESTIGATION.md`). Summary:

- **Backfill**: `rake umi:shopify_contacts:backfill[account_id]` — a self-enqueuing
  page chain (250 customers/page, spaced, own `retry_on` with long backoff because
  the global Sidekiq retry cap is 3), ceiling-guarded by `customers/count.json`.
  Idempotent. **Runbook: after the chain finishes, verify
  `hook.settings['umi_contact_sync_watermark']` exists** — absence means the chain
  died (also reported to the tracker).
- **Poll**: every 30 min (sidekiq-cron, registered via per-job `create` with
  `source: 'umi'` — never `load_from_hash!`, whose purge filter is hardcoded to
  `source: "schedule"` and would wipe the core schedule), fetches
  `updated_at_min=watermark−5min`, advances the watermark only after a fully
  successful run, aborts (without advancing) past a page cap.
- **Single-writer Redis lock** per account (`Redis::Alfred`, NX+EX; the production
  Rails.cache is per-container FileStore and can't lock) shared by backfill + poll.
- **Upsert rules**: match by email then phone; fill-blanks-only (placeholder names —
  phone number / email local part / Haikunator — count as blank); never overwrite a
  different existing `shopify_customer_id` (`conflicted`); in-batch phone dedup
  (no unique DB index on phone); no-change saves skipped.
- **Compliance**: `customers/redact` → destroy (no conversations) / anonymize (has
  conversations) / strip-only on a phone-only match; `customers/data_request` →
  tracker + error log (manual export). Always answers 200 (Shopify never
  redelivers — failures go to the tracker). **Deploy gate closed 2026-07-22**: the
  app is a Dev-Dashboard app (org UMI, handle `umi-chatwoot` — not Partner/admin-
  created); app version `umi-chatwoot-4` subscribes all three privacy-compliance
  topics to `https://chat.umi.store/webhooks/shopify`, and the app config is
  version-controlled at `umi-vps-infra/shopify/umi-chatwoot/shopify.app.toml`
  (redeploy with `shopify app deploy --allow-updates`).
- Patch #3's help-center sync now builds its client through the shared
  `Umi::Shopify::ClientFactory` (single `Context.setup` mutex for all UMI Shopify
  services — two mutexes would reintroduce the Zeitwerk race).

Rollout status (2026-07-22): backfill run on production (787 contacts linked, 175
E.164 phones, watermark set); poll enabled via `UMI_SHOPIFY_CONTACT_SYNC_ENABLED`
+ `UMI_SHOPIFY_SHOP_DOMAIN` in `umi-vps-infra` (chatwoot env template) and
verified advancing the watermark each tick. **Known gap: production has no Sentry
DSN configured, so every "reported to the tracker" path (dead chains, compliance
alerts, data_request pages) currently degrades to container-log lines only** —
wire up error tracking or a log alert on `[umi-contact-sync]`/`[umi-shopify-compliance]`
errors to make those alerts real.

### 8–11. FB/IG inbound message loss (tracing + three fixes)

One investigation, four patches — full drop-point map (F1–F8 / I1–I8), design,
alternatives and runbook in `docs/UMI-FBIG-MESSAGE-LOSS-SPEC.md`. Background:
Meta delivers webhooks once; upstream drops inbound FB/IG messages silently in
several places (chatwoot#11578, #12055, #10465, #8333). All patched files were
verified byte-identical to upstream v4.16.0 before patching.

- **#8 tracing** (`zz_umi_fbig_trace.rb` + `Umi::FbigTrace`): one
  `[UMI-FBIG] stage=… key=value` line per decision point — gem rack server
  (`webhook_received`, signature `rejected`, `standby` drops, batch `error`),
  IG controller signature rejects, IG job unknown-channel drops, FB creator
  unknown-page drops, job-level `stage=error` lines with mids/sender ids
  (dead-set jobs become grep-able), and per-message `persisted` /
  `dropped reason=…` from the builders. Log-only (no control-flow change);
  every trace-field computation runs inside the helper's own rescue so a trace
  bug can lose a log line, never a webhook (pinned by a signed-webhook 200
  spec); `UMI_FBIG_TRACE_DISABLED=true` silences. Ids/mids only — never
  message text.
- **#9 dispatch fix**: red→green regression specs proved a `[read, message]`
  batch (mixed messaging array AND read-entry-before-message-entry) loses the
  message via the memoized `@event_name`.
- **#10 fallback contact**: red→green spec proved a first-time contact's DM is
  dropped when the profile fetch raises (Advanced Access / 230 / auth errors);
  now persists with contact name `Instagram user <last4>`. **Product-visible
  behaviour change**: placeholder contacts appear in the CRM (name is permanent
  until renamed — enrichment only runs on first contact), including for echo
  threads (agent DMs a new user from the native app). Kill switch:
  `UMI_IG_FALLBACK_CONTACT=off` restores stock drop behaviour.
- **#11 attachment resilience**: red→green spec proved a `Down::TimeoutError`
  during attachment download rolled back the whole FB message; the prepend on
  `Messages::Messenger::MessageBuilder#attach_file` (covers the FB and IG
  builders; deliberately NOT the whole `process_attachment`, so a rescued
  DB-level error can't poison the open transaction) keeps the row's
  `external_url`, reports to the tracker, and lets the message survive.

Prod verification: DM the IG account + FB page, then
`docker compose logs rails | grep '\[UMI-FBIG\]'` should show
`webhook_received → persisted`; any real drop now leaves a
`rejected/dropped/error reason=…` line. Env-level causes still apply (Advanced
Access approval, token freshness, subscription fields) — see the spec's runbook.

### 12. FB/IG reconciliation vs Meta's Conversations API

Design + three-lens review record + spike results in
`docs/UMI-FBIG-RECON-SPEC.md`. The third layer of the FB/IG stack: webhooks
(live) → trace #8 (diagnose) → recon #12 (detect what Meta never delivered).
Daily scan, 48 h window (double-covers the daily cadence), grep-able
`reconcile_missing` / `reconcile_summary` lines in the same `[UMI-FBIG]`
prefix (own logging helper — removable independently of #8). Auth failures
stand down without Sidekiq retries (sustained 4xx against Graph is itself a
subscription-health risk). Auto-heal (`UMI_FBIG_RECON_HEAL=true`, default
off) replays inbound hard misses through the regular webhook builders —
contact creation, dedup and attachment degradation behave exactly as live —
and stamps rows `content_attributes.umi_recovered`. Enable heal only after a
few days of clean detection summaries. Recovered rows carry heal-time
`created_at` (accepted; original timestamp stays in the log line).

Patch #14 adds one deliberate dependency: `MessageHealService` acquires the
same per-channel writer lock as the historical importer before replaying a
miss. This prevents the recent heal window from racing the older archive
write. Removing #14 requires removing the healer's lock call before deleting
`HistoryImportLock`; removing #12 may delete the healer call while retaining
the lock for #14.

### 13. FB contact names via Conversations participants (John Doe fix)

Meta's `/PSID` User Profile API answers only for apps with the **Business
Asset User Profile Access** feature (App Review submitted 2026-07-23, was
never requested before) and denies pre-app-connection threads outright with
error 100/33 — upstream then names the contact "John Doe" forever. The same
names ride the page-inbox Conversations API (`?user_id=<psid>&fields=participants`,
the source Business Suite itself displays), which needs only permissions the
app already holds. `Umi::FacebookContactNameFallback` prepends
`process_contact_params_result` to use it before accepting a placeholder;
`Umi::Fbig::ParticipantNameService` does the lookup (nil on any failure →
stock behaviour, pinned by spec). Red→green: profile-denied sender named from
participants; lookup-also-fails path keeps John Doe. **Core-spec edit:** one
`get_connections` stub line added to
`spec/builders/messages/facebook/message_builder_spec.rb` (the new call the
fallback makes). One-off backfill run 2026-07-23: 12 existing John Does
renamed via the same data (console, not code).

### 14. Historical FB/IG archive import

The reviewed design and exact operator sequence are
`docs/UMI-FBIG-FULL-HISTORY-EXPANSION-SPEC.md` and
`docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md`. This remains a manual synchronous
repair: no initializer, route, scheduled job, or automatic retry is installed.

`umi:fbig:history_import` has two explicit modes. `unaccepted_probe` is a
two-platform, all-history, `pre_presence`, profile-deferred dry scan that exits
nonzero on the exact unavailable-body set. `approved` loads a root-owned,
checksummed, release/clone/scope-bound manifest; the cutoff, policy, omission
sets, and profile-deferred mode cannot be overridden. Apply additionally
requires an explicit expansion acknowledgement and positive per-invocation
historical-media budget. It creates no empty conversation and never invents
content for a body Meta no longer returns.

The runbook separately binds the one Meta envelope that exposes only the
Instagram business identity and no representable content. A strict,
checksummed pseudonymous fingerprint is verified immediately before and after
every Instagram history stage; drift aborts, and the envelope is reported as
unrecoverable rather than becoming an empty or misattributed conversation.
The inspector also aborts before first approval if that envelope gains an
external identity, nonblank body, attachment, or any other shape outside the
reviewed business-only empty event.

`umi:fbig:history_profiles` is a separate, rate-aware pass over the union of
importer-owned archive identities, current Conversations participants, and the
six strict Instagram seed targets. It never lists messages or creates product
rows. Fill-only contact/profile changes and missing safe avatars are bounded
by an immutable profile approval. Production runs seal PII-free pre/post state,
crash-safe avatar intents/staging, aggregate counters, logs, and attempt
evidence while Rails and Sidekiq are quiesced around a fresh coordinated
database/storage backup. `umi:fbig:history_profile_state` captures the no-Meta
source state used by clone acceptance.

History still exhausts every cursor without assuming ordering, validates
platform/participant/message identity before callback-free inert persistence,
and commits each thread atomically under the shared renewable channel lock.
Attachments are fetched through SafeFetch and Active Storage; classified
permanent media failure becomes a visible unavailable marker, while transient,
storage, cleanup, lock, structural, or unapproved omission failure exits
nonzero. Search reindex and counted Active Storage mirror jobs are the only
allowed asynchronous side effects.

Patch #14 owns `HistoryImportLock` and changes patch #12's healer to use it.
Remove #14 only after removing that healer call; if #12 is removed first,
retain the lock for the importer.

<!-- Add new patches here as commits, newest last. -->

## Notes / candidates (not yet patched)
- Instagram-via-Instagram-Login long-lived token exchange fails for Facebook-Page-linked
  accounts ("Unsupported request"). UMI uses the **Facebook-page IG path** instead
  (`Channel::FacebookPage.instagram_id`), so no patch needed — documented in
  `umi-vps-infra/docs/INFRA_SPEC.md`.
