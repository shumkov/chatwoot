# UMI Assistance: conversation view as a transcript (Nov 2026, umi-v4.16.0-39)

Follows the drawer-chrome patch (`docs/UMI-ASSISTANCE-DRAWER-CHROME-SPEC.md`, umi-v4.16.0-38), which
covered the home view, header, font, focus and fields but left the message list as Chatwoot draws it.

Design: Figma `bCbGnaO7jCU5DQmLo8pAtT`, page "09 · Help Center", section 1411:3: "Chosen" desktop
1411:151 and mobile 1411:215. The owner chose this on 5 Nov 2026: a transcript without bubbles, the
sender's name and time under each group, a 20 px avatar for people. Thai fixes: `lang`, dates and
times in the reader's locale, and 1.6 line height. Also in scope: 16 px fields in iOS in-app browsers.

## Problem and evidence

The screenshots live in `~/Downloads/release-39/now/` (EN) and `thai/` (TH). They show the -38 widget
inside the live storefront, captured on 4 Nov 2026.

1. **Bubbles are Chatwoot's.** 20 px rounded bubbles (squared by -38's blanket rule, but still
   filled), a slate-2 grey chat background, a 24 px avatar column, the blue Chatwoot bot avatar
   labelled "Bot", blue file icons and "Download" links, and a grey rounded send square in the email
   prompt.
2. **Every image also shows a "Download" file card.** In `AgentMessage.vue` and `UserMessage.vue`,
   `<FileBubble v-else>` pairs with the `<VideoBubble v-if>` above it, not with the image. So every
   non-video attachment, images included, also renders a FileBubble. This is an upstream bug.
3. **Timestamps.** Only images and videos show a time, overlaid on the photo in English
   ("Nov 4 2026, 11:27 PM", even in Thai). Text messages show no time at all.
4. **Thai.**
   - `<html lang>` is empty in every locale.
   - Dates and times are English.
   - The 1.4–1.5 line heights are tight for Thai stacked marks.
   - Tone marks are not clipped. The fallback face and the 0.6 px tracking match the storefront
     (`/th/` does the same), so those stay.
5. **iOS zoom in in-app browsers.** -38 set every widget field to 14 px; the storefront's viewport
   cap stops iOS zooming on focus. Theme PR #257 now caps the viewport only in Mobile Safari. In-app
   browsers (Instagram, Facebook, LINE, TikTok…) and other iOS browsers get `html.ios-webview` and
   16 px fields instead. The widget is a cross-origin iframe that class cannot reach, so in those
   browsers focusing the chat composer zooms the page.

## Approach

The rule from -38 still holds. Cross-cutting overrides of core markup go in `_umi-theme.scss`, which
is imported last and keyed on Chatwoot's existing classes. UMI-owned markup goes in new `Umi*`
components. Edits to core files stay to a few lines each.

### 1. Images without a duplicate file card (core fix, own commit)

In `AgentMessage.vue` and `UserMessage.vue`, `VideoBubble`'s `v-if` becomes `v-else-if`. The chain then
reads image → video → audio (agent only) → file. A failed image or video still falls through to
FileBubble, because its error flag removes it from the chain. The patch registry gets its own row,
removed when upstream fixes it.

### 2. Transcript layout (CSS in `_umi-theme.scss`)

**Cascade rule for this section.** The conversation views are lazy-loaded, so their scoped styles
(`[data-v]`) arrive after `woot.scss`, and `_conversation.scss` nests everything under
`.conversation-wrap` (0,3,0)–(0,5,0). So every override here starts with `.conversation-wrap` and
carries `!important`, as the rest of the layer does. Only the transcript is restyled.
- `.chat-bubble.agent` is only touched as `.conversation-wrap .chat-bubble-wrap > .chat-bubble.agent`
  (the text bubble).
- `.has-attachment.agent` / `.user` is only touched under `.conversation-wrap`.
- Unread/campaign popouts (`UnreadMessage.vue`) and cards, options, forms, articles and CSAT
  (`ChatCard`, `ChatOptions`, `ChatForm`, `Article`, `CustomerSatisfaction`) keep Chatwoot's look in
  this release. CSAT and pre-chat are still under discussion with the owner.

**Surface and padding**
- `.bg-n-slate-2` becomes white. It is used only on the App root and `Messages.vue`.
- `.conversation-wrap` padding becomes `24px var(--umi-inset) 16px`.

**Team messages**
- `.agent-message` and its `.message-wrap` lose their margins and max-widths (`mb-0.5` included).
- `.avatar-wrap` is hidden, because the avatar moves under the group.
- The text bubble (`.chat-bubble-wrap > .chat-bubble.agent:not(.form)`; `ChatForm`'s root is also
  a `.chat-bubble.agent`) becomes transparent, with no padding, no radius, no shadow, and ink 14/21.
  Links and code in it are ink (Chatwoot paints links blue, 3.8:1).
  Radius and shadow come through `@apply`, so they are reset explicitly.
- The attachments wrapper is transparent with no padding.
- `.has-attachment { overflow: visible }`, so focus rings on image and file links are not clipped.

**Visitor messages**
- `.user-message` max-width becomes 78 % with no end margin.
- `.chat-bubble.user` becomes `rgba(18,18,18,.05)`, ink, 10 px 14 px, 14/21 and squared, over the
  inline `background`/`color`. `code` and `pre` inside it go to ink too; upstream sets them white.
- The attachments wrapper is transparent. The visitor's file row sits in the same 5 % block, so a
  visitor file still reads as theirs; images stay bare. Its inline white text is forced to ink.
- **Failed.** The block stays 5 % (Chatwoot's ruby is not in the theme's palette, and white on ruby
  is 3.9:1). The failure is said in words: the meta reads `UMI.NOT_SENT` ("Not sent" /
  "ส่งไม่สำเร็จ") in place of the time. Chatwoot's existing retry button stays, in ink, and gains an
  `aria-label` (`COMPONENTS.MESSAGE_BUBBLE.RETRY`; a one-attribute core edit).

**Spacing**
- Within a group: 8 px between team messages, 4 px between visitor messages.
- Between groups: 24 px.
- The roots of `AgentMessage` and `UserMessage` get `umi-group-end` when the message ends a group:
  `message.showAvatar || hasRecordedResponse || isASubmittedForm` for the team, and
  `message.showAvatar` for the visitor. The selectors:
  - `.conversation-wrap .messages-wrap > .agent-message-wrap { margin-top: 8px !important }`
  - `… > .user-message-wrap { 4px }`
  - `… > .umi-group-end + * { 24px }`
- Accepted: while a visitor message is sending, the temporary copy has no `sender`, so the previous
  visitor message briefly ends a group (time and 24 px). It snaps back when the server copy arrives.

**Media and files**
- Images keep `max-width: 250px`, squared, with no border. The `.image .wrap::before` gradient and
  the `.image .time` overlay are hidden, because the time lives under the group. Videos keep their
  overlay (no class to target; rare in this shop).
- Files: the Fluent document icon at 24 px in ink. The title is 14/20 ink (given a class,
  `umi-file-title`, in `FileBubble.vue`). "Download" is 12/16.8 ink, underlined.
- The row's `cursor-pointer` stays upstream's (no handler; the link is the target).

**Reply affordances**
- `MessageReplyButton` gets class `umi-reply-button` and `aria-label` (`UMI.REPLY`).
- No slate background, ink at 0.55, and a 24 px box.
- Shown on hover and when it has keyboard focus itself (`:focus-visible`).
- `ReplyToChip` and the composer's "Replying to" bar (`FooterReplyTo`): ink at 0.75 on the 5 %
  block, no opacity, hooked by their `umi-reply-to` snippet (`:has(> .umi-reply-to)`). The bar's
  dismiss button gets a name (`UMI.CLOSE`). Both get the Thai line height (section 4), because both
  truncate.

**Typing**
- `AgentTypingBubble.vue`'s template becomes the text `UMI.TYPING` ("Typing…" / "กำลังพิมพ์…"):
  12/16.8, ink at 0.75, in the team column, on white, sticky at the bottom as today, 8 px above.
- The scoped gif style block is removed (dead).
- No live region. The component mounts with its text, so most readers would not announce it anyway.
- Accepted: Chatwoot also shows it while the conversation is pending and the last message is the
  visitor's. Production has no bot, so that is rare.

**Email prompt** (`template/EmailInput.vue`)
- The form takes `umi-composer`, the input `umi-composer-input`, and the button `umi-composer-send`
  with `UmiIcon name="arrow" class="w-[15px] rtl:rotate-180"` and `aria-label` `UMI.SEND`.
- The button's inline colour binding and Fluent chevron are removed.
- It reuses the composer's 44 px box, borderless input, #757575 placeholder, `:has()` dashed ring
  and 0.35 disabled state. The disabled arrow is the invalid-email cue.

**In-chat send** (`ChatSendButton.vue`)
- `UmiIcon arrow` (`w-[15px] rtl:rotate-180`) replaces the Fluent `send` glyph and its colour style.
- The button takes `umi-composer-send` (44 × 42) and `aria-label` `UMI.SEND`.
- The spinner is unchanged. The attachment and emoji buttons keep Chatwoot's icons.

### 3. Name and time under each group

New files (Tailwind utilities, as UMI-owned markup):
- `widget/components/UmiMessageMeta.vue`
- `widget/components/UmiDateLabel.vue`
- `widget/helpers/umiMessageTime.js`

**`UmiMessageMeta` props:** `time` (unix seconds), `name` (string, optional), `avatarUrl` (optional),
`align` (`start`/`end`), `failed` (boolean).
- Renders 12/16.8 ink at 0.75 (`rgba(var(--umi-ink),.75)`, 8.4:1). The text is plain, not
  `v-dompurify-html`. The order:
  - a 20 px `<img class="umi-avatar" alt="" aria-hidden="true">` when `avatarUrl` is set (a circle;
    the class avoids "rounded");
  - the name;
  - a separator ` · ` (`aria-hidden`);
  - `<time datetime="ISO">` with the formatted time, or `UMI.NOT_SENT` when failed. A hidden
    comma follows the name, because the dot is `aria-hidden`.
- The visitor's row has an `sr-only` "You" (the existing `YOU` key) before the time, so screen readers can tell
  who wrote what.

**Team (`AgentMessage.vue`)**
- `<p class="agent-name">` is replaced by `UmiMessageMeta` under the same condition
  (`message.showAvatar || hasRecordedResponse`).
- The name is the existing `agentName` when the message has a `sender` or a
  `additional_attributes.sender_name`. Otherwise (templates such as the email prompt, and
  automation messages) it is `UMI.AUTOMATIC` ("UMI, automatic" / "UMI, ข้อความอัตโนมัติ").
- `avatarUrl` is `message.sender.avatar_url` only when `message.sender?.type === 'user'` and the URL
  is non-empty. Bots, automation and agents without a photo get no avatar. Chatwoot's blue bot image
  and the coloured initials disappear.

**Visitor (`UserMessage.vue`)**
- After the `.user-message` row, inside the root, so it sits under the bubble whatever the flex
  direction: `UmiMessageMeta align="end"` when `(message.showAvatar || isFailed) &&
  !isInProgress`, with `failed=isFailed`. A failed message also ends its group, so two failures in
  a row both say "Not sent".

**Time**
- `umiMessageTime(unixSeconds, locale)` returns
  `Intl.DateTimeFormat(normalised, { hour: 'numeric', minute: '2-digit' })` ("11:22 PM" in en,
  "23:22" in th).
- `normalised = locale.replace('_', '-')`. Chatwoot's codes such as `pt_BR` make `Intl` throw.
- The locale is the widget's i18n locale (`useI18n().locale.value`).

**Day label**
- `ConversationWrap.vue` swaps `DateSeparator` for `UmiDateLabel :timestamp="groupedMessage.messages[0].created_at"`.
  The group key is an English "MMM dd, yyyy" string and is not parsed.
- It shows `TODAY`/`YESTERDAY`, otherwise `Intl` `{ day: 'numeric', month: 'long' }`, with the year
  only when it is not this year (Thai shows the Buddhist year, normal for Thai readers).
- It is a `<div>`, not a `<p>` (`.conversation-wrap p` adds a margin): the cart section label,
  start-aligned, 24 px below.

### 4. Thai

- **`lang`.** `entrypoints/widget.js` watches `i18n.global.locale` (`immediate: true`) and writes
  `document.documentElement.lang` with the normalised code. `App.vue` is not touched. Every path
  that changes the locale (mount, `config-set`, `set-locale`) goes through it, and `lang` is never
  empty: it is `en` until a locale resolves.
- **Line height 1.6 under `:lang(th)`.** Declared after the transcript rules with the same
  specificity plus `:lang(th)`, and `!important`:
  - the team text bubble and the visitor bubble → 22.4 px;
  - `umi-file-title` → 22.4 px;
  - the Download link → 19.2 px;
  - `ReplyToChip`, `FooterReplyTo` → 1.6 × their size;
  - `.umi-header-status`, `.umi-section-label` → 19.2 px.
  UMI components use Tailwind's `[:lang(th)_&]:leading-[…]`: `UmiMessageMeta`, `UmiDateLabel`, the
  typing text and the `UmiHomeWelcome` paragraph (20.8 px). FAQ rows are already 1.6. Fields and the
  header title keep their fixed metrics.
- **Dates and times** come from `Intl` (section 3).
- **Not in this release:**
  - tracking on Thai, which waits for the theme;
  - translating the server-written prompt/CSAT text (a later server-side patch);
  - 1.6 for Thai typed on the English site (the owner decided "Thai body and meta");
  - the image link's English alt "Picture message".

### 5. 16 px fields in iOS in-app browsers

- **Detection.** `widget/helpers/umiIosWebview.js` (new) exports `isIosWebview({ platform,
  userAgent, maxTouchPoints })`. It is a character-for-character copy of the theme's
  `snippets/ios-field-zoom.liquid` test (umi-store-theme main `da41074c`):
  - iOS = `/^iP(hone|ad|od)/.test(platform)` or iPadOS (`MacIntel` with `maxTouchPoints > 1`);
  - Safari = `/Version\/[\d.]+.*Safari\//` and not
    `/CriOS|FxiOS|EdgiOS|OPiOS|OPT\/|DuckDuckGo|GSA\/|Instagram|FBAN|FBAV|Line\/|musical_ly|TikTok|BytedanceWebview|MicroMessenger|Snapchat/`;
  - a webview = iOS and not Safari.
  `markIosWebview(doc, nav)` adds `ios-webview` to `<html>`.
- **Where it runs.** `entrypoints/widget.js` calls `markIosWebview(document, navigator)` at module
  load, before mount and first paint.
- **CSS.** `html.ios-webview input, html.ios-webview textarea, html.ios-webview select { font-size:
  16px !important }`, which is more specific than the 14 px rule. The comment above the 14 px rule
  is corrected: the storefront caps the viewport only in Mobile Safari since theme PR #257.
- **Unproven locally:** the zoom itself inside a real in-app browser. Chromium with an Instagram user
  agent and `platform` overridden proves the class and the 16 px, not iOS's zoom behaviour.

### 6. Patch registry

- Each commit updates row 2 (Assistance UI) and its "### 2." narrative for its own files.
- Commit 2 also adds this spec and updates the `_umi-theme.scss` header comment.
- The re-check-on-rebase list in row 2 gains `AgentMessage`, `UserMessage`, `ConversationWrap`,
  `AgentTypingBubble`, `EmailInput`, `ChatSendButton`, `MessageReplyButton`, `FileBubble` and
  `entrypoints/widget.js`.
- Row 2's remove-when gains: "the theme stops treating iOS in-app browsers differently" (section 5).
- Row 68 is the duplicate-file-card fix (commit 1, done). Row 67 is Powered by (done).

## Commits (one logical change each, signed)

1. `UMI: Images in Assistance no longer repeat as a file card`: section 1, with a regression spec
   (red, then green).
2. `UMI: Assistance conversation reads as a transcript`: sections 2–3.
3. `UMI: Assistance speaks Thai properly`: section 4 (`lang`, Thai line height).
   The spec doc itself lands with commit 2.
4. `UMI: 16 px fields in iOS in-app browsers`: section 5.
   Already present: `UMI: Assistance widget without "Powered by Chatwoot"` (e2f08f089).

## Alternatives rejected

- **Rewrite the message components as UMI copies.** It would mean full forks of `AgentMessage`,
  `UserMessage` and the bubble templates, so every upstream fix (like section 1) needs a manual port.
  CSS on existing classes plus three small UMI components touches less.
- **`DateSeparator` changed in `shared/`.** It is shared with other surfaces. A widget-only
  component keeps the dashboard unchanged.
- **Keep the time overlay on images.** It is English-only, unreadable over light photos, and
  redundant once every group carries a time.
- **Detect in-app browsers with `postMessage` from the storefront.** The SDK has no supported channel
  for page classes, and the user agent is identical inside the iframe, so the same test gives the same
  answer.
- **`:lang(th) *` line height.** It would break fixed-height controls (the 44 px composer and header
  buttons). An explicit list is safer.

## Failure modes

- **Upstream renames a hooked class** (`chat-bubble`, `agent-message`, `user-message`,
  `has-attachment`, `conversation-wrap`). The transcript silently falls back to Chatwoot's look, with
  nothing broken functionally. The rebase checklist in row 2 names these files.
- **`showAvatar` grouping changes upstream.** Meta could repeat or vanish; the specs pin it.
- **Inline styles.** `UserMessageBubble` and `FileBubble` set inline colours, and only `!important`
  overrides them. If upstream moves the colour to a class, the overrides stay harmless.
- **`Intl` and locale codes.** Chatwoot's `pt_BR`-style codes throw in `Intl`, so every caller normalises `_` to `-`. An unknown but well-formed code falls back to the runtime default.
- **A misclassified user agent** only changes the font size (14 vs 16 px). The worst cases are a
  zoom on focus, or a slightly larger field.
- **Dark mode.** Prod's widget is light (the theme forces white). Dark-scheme colours are not
  designed.

## Verification

1. Vitest:
   - the existing widget suite stays green;
   - new specs: image attachment → no FileBubble (agent and visitor; red on today's code); image
     error → FileBubble;
   - `UmiMessageMeta` (name, time, avatar only for people, the automatic label for templates);
   - `umiMessageTime` (en "11:22 PM", th "23:22");
   - `UmiDateLabel` (today, yesterday, a Thai month name, the year only when it differs);
   - `isIosWebview` UA cases. The theme's `test/field-type.test.js` covers Safari iPhone and iPad,
     Instagram, Facebook, LINE, Chrome iOS, DuckDuckGo, Opera, Mac and Android. Extra cases beyond
     the theme: TikTok, WeChat, Snapchat, Firefox, Edge and the Google app. Plus `markIosWebview`.
   - Time specs run with `TZ=UTC` and match the en time with `/11:22\sPM/` (ICU may use U+202F).
     `UmiDateLabel` uses `vi.setSystemTime`.
   - `MessageAttachments.spec.js` needs no stub: `vitest.setup.js` installs a global i18n, so
     `UmiMessageMeta`'s `useI18n()` resolves.
2. eslint and prettier on changed files.
3. Local stack inside the live storefront: desktop Chrome via Playwright request routing, at 390 and
   1440, EN and `/th/`. Assert:
   - no FileBubble next to an image;
   - meta under the last message of each group, with the avatar for agents only;
   - times as `Intl` gives them; `<html lang>` is `en`/`th`;
   - Thai message text computes a 22.4 px line height;
   - no horizontal overflow;
   - with an Instagram iOS user agent and `navigator.platform` overridden to `iPhone` through
     `addInitScript` (it also runs in the iframe), fields compute 16 px; with Safari's, 14 px;
   - keyboard focus is visible on reply, Download, image, email arrow and send;
   - fixtures: a long URL, a reply-to chip in Thai, a failed message, text plus attachment, two
     agents in a row, an agent without a photo.
4. iOS Simulator, Mobile Safari, real WebKit and the Thai system font: the widget embedded in the
   storefront, EN and TH screenshots.
5. Tag `umi-v4.16.0-39` after merging to `umi`; verify the GHCR image builds. Production only after
   the owner's go.

## Spec review corrections

Three independent reviews (CSS/Vue feasibility, design and accessibility with Thai, scope and rebase
safety with tests). Folded in above:

- **Cascade.**
  - Lazy-loaded scoped styles and `_conversation.scss` nesting beat plain selectors. Every override
    is `.conversation-wrap`-anchored with `!important`.
  - Spacing selectors are explicit.
  - Radius and shadow reset explicitly (they come through `@apply`, not class names).
- **Scope.**
  - The bubble rules are limited to the transcript's text bubble and attachment wrappers.
  - Unread/campaign popouts, cards, options, forms, articles and CSAT are explicitly unchanged.
- **Failed message.** The failure is said in words ("Not sent") instead of ruby, which also fixes
  the contrast. The retry button gets a name. The meta is placed under the row, outside the
  flex-reversed wrap.
- **Locale codes** are normalised (`pt_BR` throws in `Intl` and is an invalid `lang`).
- **`lang`** is set by a watcher in the entrypoint instead of an edit in `setLocale`; it was never
  empty-safe there.
- **Thai line height** uses rules that out-rank the transcript rules, with a complete list (reply
  chip, "Replying to" bar, file title, Download link).
- **People only get an avatar** (`sender.type === 'user'` with a photo). Templates and automation are
  "UMI, automatic" (no doubled middle dot).
- **Email prompt** reuses the composer classes: one ring, the #757575 placeholder, and no
  white-on-white arrow.
- **Accessibility.**
  - Names on the reply, send and email-arrow buttons; 44 px send targets.
  - The reply button is visible on keyboard focus.
  - Screen readers get "You", a `<time>` element and a hidden separator.
  - No live region on the typing text.
  - Focus rings are no longer clipped by `overflow: hidden`.
- **Tests.**
  - UTC and the U+202F-safe time match.
  - The attachments spec stubs the meta.
  - The iOS case list says what goes beyond the theme's.
  - Chromium needs the `platform` override.
- **Registry.** Row 2 is updated per commit with a remove-when for section 5. The stale "whole page"
  comment is corrected.
