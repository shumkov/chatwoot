# UMI widget home — storefront alignment

Extends UMI patch #2 (widget home composer + messenger links). Makes the live-chat
widget home match the UMI storefront and the cart-drawer shell (shipped theme-side).

## Changes

1. **Header title → translatable "Assistance"** — the home header shows the inbox
   `channelConfig.websiteName` ("Website"). Override it to a fixed i18n string so
   the agent-facing inbox name stays "Website" while customers see "Assistance".
2. **Welcome text** — a short, translatable availability line at the top of home.
3. **Merge availability card + composer into one input block** — drop
   `TeamAvailability` (the "We are online / Start Conversation" card). The composer
   is the single input: **no conversation → "Type your message…"**, **conversation
   exists → "Continue conversation →"** (routes to `messages`).
4. **Send-button alignment** — the composer `<form>` is `items-end`; seat the button
   flush with the textarea.
5. **Articles open on the storefront help page** (not the in-drawer viewer):
   - each article → `<storefront>/blogs/help/<slug>` (same tab)
   - "View all articles" → `<storefront>/pages/help`
   - remove the "Popular Articles" `<h3>` header
6. **Home order**: welcome → articles → messenger links → composer (pinned bottom).

## Files

- `views/Home.vue` — remove `TeamAvailability`, add `UmiHomeWelcome`, reorder.
- `components/pageComponents/Home/UmiHomeWelcome.vue` — **new**, welcome text (i18n).
- `components/pageComponents/Home/UmiHomeComposer.vue` — composer/continue states, alignment.
- `components/pageComponents/Home/Article/ArticleContainer.vue` — article/view-all → storefront URLs.
- `components/pageComponents/Home/Article/ArticleBlock.vue` — drop the header, pass slug up.
- widget home header component — title override (locate: renders `channelConfig.websiteName`).
- `i18n/locale/en.json` + `th.json` — new `UMI` keys.

## i18n (new `UMI` namespace keys, en + th)

- `UMI.ASSISTANCE` = "Assistance"
- `UMI.WELCOME` = "Our team is here to help with sizing, orders, or anything else — Mon–Sat, 9 AM–9 PM (Bangkok). Message us below or use the links."

## Storefront origin

Navigate the top window (same tab). Storefront origin from `document.referrer`
(the embedding page), falling back to `https://umi.store`:
`window.top.location.href = origin + '/blogs/help/' + slug`.

## Test plan (local Docker — Acme Support inbox)

Embed the patched widget and verify: header reads "Assistance"; welcome text shows;
**no conversation → composer only**; **with a conversation → "Continue conversation"**;
send button aligned; article click → `/blogs/help/<slug>` (same tab); "View all" →
`/pages/help`; no "Popular Articles" header. Then eslint + prettier + vitest.

## Remove-when

Frontend core edits — keep while the storefront relies on the widget. Re-check
`Home.vue`, the header component, and `ArticleContainer` on each upstream rebase.
