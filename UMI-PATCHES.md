# UMI patches

The `umi` branch currently sits on upstream **`v4.14.2`**.
Each patch below is a commit on top of that tag. Keep this list in sync on every rebase.

| # | Patch | Files | Why | Remove when |
|---|---|---|---|---|
| 1 | Facebook Graph API v21 + HUMAN_AGENT tag | `config/initializers/zz_umi_facebook_fix.rb` | Bundled `facebook-messenger` gem pins removed Graph API **v3.2** → outbound FB fails; Chatwoot also sends the deprecated **`ACCOUNT_UPDATE`** tag (Meta subcode 1893061). Repins v21.0 + switches to `HUMAN_AGENT`. | Upstream bumps the gem's Graph version AND replaces the ACCOUNT_UPDATE tag. |
| 2 | Widget home: composer + messenger links | `app/javascript/widget/views/Home.vue`, `app/javascript/widget/components/pageComponents/Home/UmiHomeComposer.vue`, `app/javascript/widget/components/pageComponents/Home/UmiInboxLinks.vue` | Make the widget home a self-contained assistant: a **type-to-chat composer** (start the chat by typing — skips the "Start conversation" step) and **quick links to WhatsApp / LINE / Messenger / Instagram**, alongside the existing Help Center articles. Lets the storefront "Assistance" button open the widget directly so the custom theme drawer can be retired. | **Frontend core edit — keep** while the storefront relies on it (UMI product behaviour). Re-check `Home.vue` and the `conversation/sendMessage` action on each rebase. |

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

<!-- Add new patches here as commits, newest last. -->

## Notes / candidates (not yet patched)
- Instagram-via-Instagram-Login long-lived token exchange fails for Facebook-Page-linked
  accounts ("Unsupported request"). UMI uses the **Facebook-page IG path** instead
  (`Channel::FacebookPage.instagram_id`), so no patch needed — documented in
  `umi-vps-infra/docs/INFRA_SPEC.md`.
