# UMI patches

The `umi` branch currently sits on upstream **`v4.14.2`**.
Each patch below is a commit on top of that tag. Keep this list in sync on every rebase.

| # | Patch | Files | Why | Remove when |
|---|---|---|---|---|
| 1 | Facebook Graph API v21 + HUMAN_AGENT tag | `config/initializers/zz_umi_facebook_fix.rb` | Bundled `facebook-messenger` gem pins removed Graph API **v3.2** → outbound FB fails. Repins v21.0, and enables Chatwoot's built-in `ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT` (so replies use the 7-day `HUMAN_AGENT` window) instead of the default `RESPONSE` — via the flag, not a service override. | Upstream bumps the gem's Graph version (the HUMAN_AGENT part is just config — drop by unsetting the flag). |
| 2 | Widget home: composer + messenger links | `app/javascript/widget/views/Home.vue`, `app/javascript/widget/components/pageComponents/Home/UmiHomeComposer.vue`, `app/javascript/widget/components/pageComponents/Home/UmiInboxLinks.vue` | Make the widget home a self-contained assistant: a **type-to-chat composer** (start the chat by typing — skips the "Start conversation" step) and **quick links to WhatsApp / LINE / Messenger / Instagram**, alongside the existing Help Center articles. Lets the storefront "Assistance" button open the widget directly so the custom theme drawer can be retired. | **Frontend core edit — keep** while the storefront relies on it (UMI product behaviour). Re-check `Home.vue` and the `conversation/sendMessage` action on each rebase. |
| 3 | Help Center → Shopify "help" blog sync | `umi/app/services/shopify/help_center_sync_service.rb`, `umi/app/jobs/shopify/help_center_sync_job.rb`, `umi/app/models/shopify_help_center_syncable.rb`, `config/initializers/zz_umi_shopify_help_center.rb`, `lib/tasks/umi_help_center.rake`, `spec/services/umi/shopify/help_center_sync_service_spec.rb`; **core edit:** `config/application.rb` (wires the `umi/` overlay under the `Umi::` namespace via `push_dir`); docs: `UMI-SHOPIFY-HELP-CENTER-SPEC.md`, `UMI-SHOPIFY-HELP-CENTER-REVIEW.md` | Mirror Chatwoot Help Center articles to the storefront so the FAQ is server-rendered + SEO-indexed at `/blogs/help/<article>`. Reuses the **existing Shopify integration token** (Integrations::Hook `app_id:"shopify"`) — adds `read_content`/`write_content` + `read_online_store_navigation`/`write_online_store_navigation` to its OAuth scopes. Chatwoot stays the source of truth. | A native Chatwoot ↔ Shopify content sync ships upstream, or UMI stops mirroring the FAQ to the storefront. |
| 4 | Voice (calls): inbound Twilio → SIP softphone | `umi/app/services/voice.rb`, `umi/app/services/voice/twiml/dial_builder.rb`, `umi/app/services/voice/inbound_resolver.rb`, `umi/app/controllers/voice/webhooks_controller.rb`, `umi/app/models/channel/twilio_sms.rb`, `config/initializers/zz_umi_voice.rb`, `spec/umi/voice/twiml/dial_builder_spec.rb`; docs: `docs/CALLS_BACKEND_SPEC.md`, `docs/GROUNDWIRE_AGENT_SETUP.md` | Agent calling on phones via Twilio + Acrobits Groundwire SIP softphone — no native app, no premium-gated EE voice. Inbound Twilio call → `<Dial><Sip>` rings the on-duty agents' Groundwire with the Chatwoot contact name injected via `Remote-Party-ID`, **and logs the call** (Contact→Conversation→`voice_call` message screen-pop + status/duration tracking). **Outbound click-to-call** rings the agent's softphone then bridges to the contact, plus **optional call recording**. WhatsApp follows. | Voice/calls ships upstream unlocked, or is extracted into a standalone engine. |
| 5 | Email inbox: read a Gmail label, not INBOX | `umi/app/services/imap/configurable_folder.rb`, `umi/app/services/imap/preserve_provider_config.rb`, `config/initializers/zz_umi_email_imap_folder.rb` | Stock Chatwoot hardcodes `imap.select('INBOX')`, so a shared reader mailbox (`shumabit@`, a member of the `info@`/`support@` Google Groups) would pull its whole inbox in. Prepends a configurable folder read from `channel.provider_config['imap_folder']` (+ a companion that preserves that key across OAuth token refresh); a Gmail filter labels only the group mail → the inbox ingests only that label, leaving the mailbox's other mail untouched (no archiving, no extra Workspace seat). | Upstream adds a per-inbox source folder/label for the email channel. |

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

<!-- Add new patches here as commits, newest last. -->

## Notes / candidates (not yet patched)
- Instagram-via-Instagram-Login long-lived token exchange fails for Facebook-Page-linked
  accounts ("Unsupported request"). UMI uses the **Facebook-page IG path** instead
  (`Channel::FacebookPage.instagram_id`), so no patch needed — documented in
  `umi-vps-infra/docs/INFRA_SPEC.md`.
