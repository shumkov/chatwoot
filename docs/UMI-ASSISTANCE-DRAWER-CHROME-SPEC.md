# UMI Assistance drawer — theme chrome (Oct 2026)

Extends UMI patch #2 (`docs/UMI-WIDGET-HOME-SPEC.md`). The storefront theme standardised its
overlay chrome on 30 Oct 2026 (umi-store-theme `docs/OVERLAY_CHROME_SPEC.md`, sections "One close
cross, half the size" and "The back arrow and Klaviyo's cross match the one cross"). The Assistance
drawer is this widget in an iframe from `chat.umi.store`, so the theme's CSS cannot reach it. This
patch brings the widget's chrome and type to the same rules.

## Problem and evidence

Measured on live umi.store (theme main 03d5f084, widget dcd0ab2c) at 390 × 844 and 1440 × 900:

|               | Theme cart drawer (reference)                                                                                              | Assistance widget today                                                     |
| ------------- | -------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Panel         | 400 px desktop, 1 px left line; phones: full-width widget                                                                  | 400 px holder (theme-side), iframe 399 px                                   |
| Inset         | 16 px phones, 24 px desktop                                                                                                | 20 px everywhere                                                            |
| Header        | 16 px vertical padding, 56 px tall                                                                                         | 20 px padding, 68 px tall                                                   |
| Title         | Cy Grotesk Key 400, 16/24, 0.6 px tracking, #121212                                                                        | Helvetica 600, 20/28, #1c2024                                               |
| Close         | 10 px hairline cross (`icon-close.svg`), 44 px tap area overhanging the inset; cross 1 px inside the inset; hover ink 0.75 | 24 px Fluent "dismiss" glyph in a 24 px button                              |
| Section label | "COMPLETE YOUR LOOK": 400 12/16.8, uppercase, 0.72 px tracking                                                             | "FAQ": Helvetica 600 14/20                                                  |
| Lines         | 1 px rgba(18,18,18,.14)                                                                                                    | channel tiles: 1 px outline in `n-container`                                |
| Field         | 44 px, 16 px text, 1 px rgba(18,18,18,.55) border, placeholder #757575                                                     | 44 px, 15 px text (iOS zooms the page on focus below 16 px), #ececec border |
| Focus         | 1 px dashed currentColor, offset 2 px (−2 px inset where a control is flush)                                               | browser/Tailwind default                                                    |
| Font          | Cy Grotesk Key Regular only                                                                                                | Helvetica forced by `_umi-theme.scss`; Cy Grotesk never loads               |

Screenshots: `before-390.png`, `before-1440.png` (attached to the PR).

## Approach

All of it lives in the widget; the theme's drawer shell (`snippets/chatwoot-embed.liquid`) is
already 400 px with a 1 px line and is unchanged.

**Where styles go.** Cross-cutting overrides of core markup (font, weight reset, focus, inset,
field size, the `.close-button` box) go in `_umi-theme.scss`: Tailwind cannot express them
without editing core files, and the layer is the precedent that rebases cleanly. UMI-owned
components use Tailwind utilities. `@import 'umi-theme'` moves to the **end** of `woot.scss`: today
it sits at line 7 and woot.scss's own `.button`, `label` and `textarea` rules after it win ties.

1. **Font.** `_umi-theme.scss` declares `@font-face 'Cy Grotesk Key'` with the **exact URL
   (including `?v=`) the storefront preloads** (`snippets/cy-grotesk-key-font.liquid`), woff2 +
   woff, `font-display: swap`.
   - The CDN answers `Access-Control-Allow-Origin: *`; the widget page sends no `font-src` CSP
     (`content_security_policy.rb` is commented out, prod Caddy sends only `frame-ancestors`).
     Vite leaves absolute `https:` URLs untouched.
   - `chat.umi.store` is same-site with `umi.store`, so the iframe shares the storefront's
     partitioned HTTP cache: the file the storefront already downloaded is reused. The SDK loads
     the iframe at idle after page load, before the drawer is opened.
   - Stack: `'Cy Grotesk Key', 'Noto Sans Thai', 'IBM Plex Sans Thai', Thonburi, 'Leelawadee UI',
sans-serif` — the theme's Thai fallback stack (component-language-switch.css:12).
   - Weight: `*, *::before, *::after { font-weight: 400 !important }` and
     `html { font-synthesis: none }`. Both are needed: synthesis-off stops a fake bold of Cy
     Grotesk, but the Thai fallback faces have real bold files that only the weight reset stops.
     `strong`/`b` in messages get the theme's emphasis token (base.css:73).
   - Base tracking 0.6 px and ink #121212, as the theme body.
   - Every `input`, `textarea`, `select` computes 16 px, so iOS does not zoom the page on focus
     (home composer, pre-chat form, in-chat reply box).
2. **Inset.** `--umi-inset`: 24 px, and 16 px under `.is-mobile` (set on the root wrapper,
   `App.vue:376`, by the SDK's `toggle-close-button` message when the storefront window is
   ≤ 668 px; the iframe is ~400 px wide either way, so a media query inside it cannot tell). The
   theme's cart switches at 750 px, so between 669 and 749 px the drawer keeps 24 px while the
   cart uses 16 px; accepted.
3. **Header** (`ChatHeader.vue`, `HeaderActions.vue`):
   - 16 px vertical padding, title 400 16/24 #121212. Home header is 56 px; the 44 px header
     buttons take `margin-block: -10px` so they do not grow the row. The chat view adds a status
     line, so its header is taller.
   - Close: `HeaderActions.vue` keeps the `close-button` class (the visibility hook that
     `woot.scss` forces on under `.is-mobile` / `.is-bubble-hidden`; on desktop the button shows
     only because the storefront sets `hideMessageBubble: true`) but drops
     `button transparent compact`, whose `text-white`, `height: auto` and `outline-0` would hide
     the cross and its focus ring. The button is 44 × 44, ink #121212 (hover 0.75 under
     `@media (hover: hover)`), with `aria-label` `UMI.CLOSE`, and holds the theme's `icon-close`
     artwork drawn at 10 px. It overhangs the end inset by 16 px (`margin-inline-end: -16px`), so
     the cross's right edge sits 1 px inside the inset on both breakpoints, exactly as the cart
     drawer.
   - Back (chat and pre-chat views): the same box with the theme's `icon-back` artwork and
     `aria-label` `UMI.BACK`, overhanging the start inset, so the svg box's left edge = inset + 1.
   - Online dot: kept (the only live presence cue), 6 px circle, 6 px after the title, centred on
     the title's x-height, existing teal. Its class avoids the substring `rounded` (the global
     squaring rule matches `[class*='rounded']`) and sets `border-radius: 50%`; the theme rounds
     its own sheet grabber the same way. It carries visually hidden "Online" text (`UMI.ONLINE`).
   - Status line under "Chat": 400 12/16.8, ink 0.75 (override `text-n-slate-11` and the
     `text-xs leading-3` passed in `ChatHeader.vue`).
4. **Home content** (`Home.vue`, `UmiHomeWelcome.vue`, `ArticleBlock.vue`, `ArticleListItem.vue`,
   `UmiInboxLinks.vue`, `UmiHomeComposer.vue`):
   - Inset from `--umi-inset` (replaces `px-5`).
   - Welcome: theme body, 13/19.5, ink 0.75 (as "Add ฿3,310 more for free shipping").
   - Section labels "FAQ" and "Chat with us on": the cart's section label (cart-looks.css:20-25:
     400 12/16.8, uppercase, 0.06 em, ink #121212, 12 px below).
   - FAQ rows: `--type-page-text-m` 15/24, ink #121212, 10 px vertical padding (44 px rows =
     `--hit-area`), hover ink 0.75. The Lucide `›` becomes the theme's list arrow
     (`icon-arrow.svg`, 15 px wide) in full ink, as theme list arrows are (`currentColor`).
     "All topics" takes the same arrow after the label, 13 px.
   - Channel tiles: the theme's outlined control (component-cart-drawer.css:680-689) — 1 px
     rgba(18,18,18,.55) border at rest, ink on hover under `@media (hover: hover)`; squared;
     13 px label; 20 px brand glyphs unchanged; 44 px min height.
   - Composer: 44 px box, 1 px rgba(18,18,18,.55) border, 16 px text, placeholder #757575
     (the theme hides placeholders behind floating labels, so there is no token; #757575 is
     4.6:1 on white). Send is a 44 px button with the theme's `icon-arrow` (the newsletter submit's
     arrow) and `aria-label` `UMI.SEND`, replacing the core `ChatSendButton` in this component only;
     disabled at 0.35 as today. "Continue conversation" uses the same box and arrow (replacing
     `i-lucide-chevron-right`).
5. **Focus.** Mirror theme base.css:858-867 with `!important` so Chatwoot's
   `outline-none`/`focus:outline-none` utilities and ring box-shadows lose:
   `*:focus { outline: 0; box-shadow: none }`,
   `*:focus-visible { outline: 1px dashed currentColor; outline-offset: 2px; box-shadow: none }`.
   Header buttons (flush with the panel edge on phones) use −2 px. The composer rings on its box
   via `.umi-composer:has(.umi-composer-input:focus-visible)`, not `:focus-within` (which would
   double-ring when the send button has focus).
6. **Icons.** One component, `UmiIcon.vue` (beside the other `Umi*` widget files), renders the
   three theme artworks (`close`, `back`, `arrow`) from the theme's `assets/icon-*.svg` and always
   adds `aria-hidden="true"` and `focusable="false"` (the theme's `icon-arrow.svg` lacks them).
7. **Patch registry.** Update `UMI-PATCHES.md` row 2 and section "### 2." (Cy Grotesk instead of
   Helvetica; add `HeaderActions.vue`, `UmiIcon.vue`, `woot.scss` and this spec; re-check
   `HeaderActions.vue` on rebase; remove-when adds "the theme changes its font file") and the
   header comment of `_umi-theme.scss`. One `UMI:` commit.

Not changed: the theme's drawer shell; the in-chat message list and reply box beyond the font,
weight, 16 px field, ink and focus they inherit; the popout button and the expanded header
(`ChatHeaderExpanded`, shown only when the inbox has a welcome title/tagline — prod's has neither);
"Powered by Chatwoot" (installation branding config, not this layer).

## Alternatives rejected

- **Self-host the woff2 in the fork's assets.** A second copy, a second download (different
  URL), and a font file baked into the image. The Shopify CDN URL is the one the storefront
  already ships.
- **Inject the font from the storefront (postMessage / SDK `cssUrl`).** The iframe is a separate
  document; the SDK has no supported hook for custom CSS in the iframe.
- **Media queries for the inset.** The iframe is ~400 px wide on desktop and 390 px on phones;
  only `.is-mobile` reflects the storefront's breakpoint.
- **Keep Fluent icons, resize them.** Fluent's `dismiss` is a filled outline; scaled to 10 px it
  thins below a pixel — the reason the theme redrew its own cross.
- **Drop the online dot.** It is the only agent-presence cue; the welcome copy is time-based and
  says nothing about who is online right now.

## Failure modes

- **CDN file renamed/removed in Shopify.** The stack falls back to the system sans; the layout
  still holds (no metrics depend on the font). The URL is the one in the theme's
  `snippets/cy-grotesk-key-font.liquid`; a font change in the theme must update both.
- **Upstream rebase.** Edits stay inside files patch #2 already owns (`ChatHeader.vue`, the
  Home components) plus a three-line icon swap in `HeaderActions.vue`. Re-check on rebase.
- **`.is-mobile` arrives by postMessage after first paint.** First paint uses the 24 px inset,
  then snaps to 16 px on phones. The drawer is opened by the user long after the iframe has loaded
  (idle load), so the snap is not visible.
- **Global `font-weight: 400`** would flatten Chatwoot's bold everywhere in the widget, including
  the in-chat view; that is the theme rule, intended.
- **Half pixels.** The cross is 10 px in a 44 px box: offset 17 px, whole pixels at 1×.

## Verification

1. Vitest for the touched UMI components (existing specs stay green; new assertions: the close
   and back buttons render the theme artwork with an accessible name, the composer's send button
   carries the arrow).
2. eslint + prettier on changed files.
3. Local stack (`chatwoot-widget-preview` §A) at 390 (`.is-mobile`) and 400 (desktop iframe)
   widths, EN and TH:
   - computed font family `Cy Grotesk Key` loaded (`document.fonts.check`);
   - no element with font-weight > 400;
   - title 16/24, header 56 px; cross 10 × 10, button 44 × 44, cross right edge = panel width −
     inset − 1;
   - back arrow left edge = inset + 1;
   - no horizontal overflow; keyboard focus ring visible on close, rows, tiles, composer.
4. Screenshots 390 and 1440 before/after for Ivan, then PR → `umi` → tag → deploy through
   `umi-vps-infra` (Ivan's go), then the live check on umi.store EN and `/th/`.

## Spec review corrections

Three reviews (CSS feasibility, design-system fit and accessibility, scope and rebase safety).
Folded in above:

- `_umi-theme` moves to the end of `woot.scss`; it was not last in the cascade.
- The close button drops `button transparent compact` (white ink, auto height, no outline) and
  keeps `close-button`; header buttons take a negative block margin so the home header stays 56 px.
- Focus rules mirror the theme with `!important`; the composer rings via `:has()`.
- Accessible names for close, back, send and "Continue"; `UmiIcon` always hides its svg; the
  online dot gets hidden text.
- List arrows in full ink (theme list arrows are `currentColor`), 44 px FAQ rows.
- Tiles use the theme's outlined-control border (0.55, ink on hover), not the 0.14 separator.
- 16 px on every field, not only the home composer.
- Weight reset on `*` plus `font-synthesis: none` (Thai fallbacks have real bold faces).
- Patch registry and `_umi-theme.scss` header updates are part of the change.

## Code review corrections

Two code reviews (whole-widget CSS/Vue regressions; theme fit and accessibility). Folded in:

- Fields whose border Chatwoot draws as an outline (pre-chat form, email/CSAT bubbles, emoji
  search, phone field) kept their border on focus only after a field rule: the border darkens to
  ink instead of vanishing. The emoji-search selector uses `[class~='outline-1']`, because a
  `.outline-1` selector in this file makes Tailwind's `@apply outline-1` circular.
- The in-chat reply box gets the composer's border, ring and placeholder; its textarea outline
  is off for good (Chatwoot transitions it, which flashed a dark box on blur).
- Specs pin the three artworks byte-for-byte and the names of close, back, send and the online
  dot. The home composer's textarea is named.
- "All topics" is a 44 px target; header buttons do not shrink; the back arrow mirrors in RTL;
  long titles truncate.

## Local verification receipt

Native local stack (Rails :3010, Vite :3046, own database), with the live umi.store storefront
loaded in Playwright and every `chat.umi.store` request routed to the local server in that
browser only (nothing reached production). Widget colour set to production's `#121212`.

- 390 (`.is-mobile`): header 56 px; close button 346–390, cross 363–373 × 23–33 (the cart
  drawer's cross: 363–373); title at x 16, Cy Grotesk Key 16/24.
- 1440 (iframe 399 px): cross right edge 25 px from the panel edge and title at panel x 24, both
  equal to the cart drawer (1415 / 1065 on the page).
- Chat view: back button 0–44, arrow left edge 17 (= inset + 1); status 12/16.8.
- `document.fonts.check('16px "Cy Grotesk Key"')` true; no element computes above 400; every
  field computes 16 px; no horizontal overflow at 390 or 399; Thai home renders with the fallback
  faces and no overflow.
- Keyboard focus rings on close, FAQ rows (full row), tiles and the composer box; pre-chat
  textarea keeps an ink border on focus.
- `vitest` widget suite: 42 files, 248 tests pass. eslint and prettier clean on changed files.

Not proven locally: real iOS Safari (zoom, font rendering), Thai on a device, the production
image build.
