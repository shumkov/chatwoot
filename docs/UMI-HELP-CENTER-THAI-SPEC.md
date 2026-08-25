# Thai Help Center — Chatwoot as the source of truth for both languages

**Status:** draft for review · **Audit date:** 2026-08-26 · **Store:** `pizeev-ys` / umi.store · **Portal:** `umi-help`

Companion to `UMI-SHOPIFY-HELP-CENTER-SPEC.md` (the English sync this extends) and to
`docs/THAI_LOCALIZATION_SPEC.md` in `umi-store-theme`, whose open decision **D3** this closes.

## 1. Problem

The storefront Help Center (`umi.store/pages/help`, blog handle `help`) is mirrored from
Chatwoot. Chatwoot owns the English. Thai exists **only in Shopify**, as `translationsRegister`
values written by hand over the Admin API.

That makes the Thai orphaned content. When an English article changes in Chatwoot, the sync
pushes new English to Shopify, Shopify marks the Thai translation `outdated`, and nothing
surfaces it. Before the 2026-08-25 refill, 33 of 48 articles were stale that way, and at least
one had drifted to saying the opposite of the current English — "Do your clothes run true to
size?" had become "Not always" in English while the Thai still read "ใช่แล้ว" (yes).

Refilling the Thai does not fix this. The next English edit re-orphans it.

## 2. What is true today (measured, not assumed)

### 2.1 The locale gate is real code, not a stale doc

`umi/app/models/shopify_help_center_syncable.rb:20`

```ruby
def umi_help_center_syncable?
  portal&.slug.present? &&
    portal.slug == ENV.fetch('UMI_HC_PORTAL_SLUG', 'umi-help') &&
    locale.to_s == ENV.fetch('UMI_HC_LOCALE', 'en')
end
```

`lib/tasks/umi_help_center.rake` repeats the same filter on its backfill query. Both the
event-driven path and the backfill are English-only. The comment states the reason: a non-`en`
translation would slugify to a colliding Shopify handle and fight the English article for it.

### 2.2 Chatwoot holds no Thai at all

```
GET /hc/umi-help/th/articles  ->  {"payload":[],"meta":{"articles_count":0}}
GET /hc/umi-help/th/categories ->  returns the 12 *en* categories (no th categories exist)
```

So this is not "flip the gate". There is nothing on the Chatwoot side to sync. The Thai in
Shopify is the only copy of that work anywhere.

### 2.3 The Shopify side, as of 2026-08-26

| | |
|---|---|
| Articles in the `help` blog | **48** (all published) |
| Chatwoot `umi-help` published `en` articles | **48** |
| Chatwoot categories (`en`) | 12 |
| Articles carrying `custom.chatwoot_id` | 48 / 48 |
| Translatable `ARTICLE` keys | `title`, `body_html`, `summary_html`, `handle`, `meta_title`, `meta_description` |
| `meta_description` present on | 36 (the sync writes `global.description_tag` only when the Chatwoot article has a `description`; 12 have none) |
| Thai translations present | 228 / 228 fields, **0 outdated** |
| `th` shop locale | exists, **`published: false`** |

228 = 48 title + 48 `body_html` + 48 `summary_html` + 48 `meta_title` + 36 `meta_description`.
`handle` is translatable and deliberately untranslated, which keeps `/th/blogs/help/<slug>` on
the same URL as English.

Because `th` is unpublished on the storefront, **no Thai reaches a customer today** and every
write to it is invisible. That is what makes this safe to build and verify incrementally.

### 2.4 Article bodies are simple enough to round-trip

Across all 48 English bodies the entire tag vocabulary is `p` (57), `a` (35), `li` (6), `ul` (2),
`strong` (3). The Thai bodies have **identical tag counts** — the translator preserved structure
exactly. There are no tables, images, headings or embeds. A markdown ⇄ HTML round-trip is
therefore mechanical and, more importantly, checkable.

Two details only showed up once the round-trip was actually run against the corpus:

- **Two articles use a *loose* list** — `<li><p>…</p></li>`, which CommonMark produces only from
  markdown with blank lines between the items. Emitting a tight list instead would rewrite those
  articles' HTML on the next sync for no reason, so the converter reads the shape off the source.
- **Today's renderer no longer reproduces two English bodies byte-for-byte.** "Where can I try
  things on in person?" and "Do you have a physical store?" hold `Tree%20O'clock` with a raw
  apostrophe in the `href`; the current renderer emits `&#x27;`. Identical in a browser, but it
  means the next edit to either article rewrites `body_html`, moves the digest, and marks the Thai
  outdated for no content reason. Independent of this work — worth knowing when one of them next
  changes.

The second one is why equivalence is checked **semantically** rather than byte-wise: both sides
are re-serialised through Nokogiri, which normalises entity spelling and the trailing newline
Shopify strips, and nothing else. A changed word, tag, or URL still fails.

### 2.5 A pre-existing English bug the Thai inherited

When a Chatwoot article has no `description`, `summary_html` falls back to
`strip_tags(content)[0, 160]` — a hard cut of **raw markdown** at 160 characters.
29 of the 48 summaries are truncated mid-word as a result:

- *"How do I find my size?"* ends `...compare them to a piece you already own and love. F`
  (the start of "For"). The Thai faithfully reproduces the stray `F`.
- *"Where can I try things on in person?"* leaks a raw URL fragment,
  `Tree%20O'clock%20Gallery%`, into its summary because markdown link syntax survives
  `strip_tags`.

**Deliberately out of scope here.** Fixing it rewrites 29 English summaries, changes their
digests, and marks every Thai summary outdated — the exact churn this spec exists to prevent.
It wants its own patch, sequenced *after* this one so the repair flows through the new pipe.

## 3. Chosen approach

**Chatwoot becomes the source of truth for Thai as well as English. A Thai article in Chatwoot
is projected onto the English article's Shopify record as a translation, never as a second
article.**

```
Chatwoot portal umi-help
  en category  ──┐
    en article ──┼──► REST  POST/PUT blogs/<help>/articles      ──► Shopify Article (en)
                 │                                                        │
  th category  ──┤                                                        │ same resource
    th article ──┴──► GraphQL translationsRegister(resourceId:)  ─────────►┘  locale "th"
       (associated_article_id -> the en article)
```

Three things follow from that shape:

1. **No handle collision.** A translation has no handle of its own; the `handle` key is left
   untranslated on purpose. The §2.1 objection to non-`en` locales disappears — it applied to
   syncing them *as articles*, which is precisely what this does not do.
2. **Registering with the current digest clears `outdated`.** There is no separate
   staleness-clearing mechanism to build; a correct write is the fix.
3. **The Thai lives next to the English in the editor an author already uses.** Chatwoot's
   article editor exposes a locale switcher over `associated_article_id`. Whoever edits the
   English sees that a Thai version exists, in the same screen. That is the structural half of
   the fix — the leak existed because Thai lived in a system the Chatwoot editor never mentions.

### 3.1 Why not the alternatives

| Option | Why not |
|---|---|
| Sync `th` articles as **separate Shopify articles** | Two articles compete for one handle (§2.1), `/pages/help` would list every question twice, and Shopify's language routing would never serve them under `/th/`. |
| Leave Thai in Shopify; add **drift alerting only** | Refills the bucket and installs a leak alarm. The Thai still has no home beside the English, the widget's Thai FAQ stays empty (§6.3), and every repair remains a hand-run Admin API script. |
| **Machine-translate on sync** | Rejected already in `THAI_LOCALIZATION_SPEC.md` §5 — fashion copy carries brand voice, and it would overwrite Mai's vocabulary on every English edit. |
| Author Thai in **Translate & Adapt** as the system of record | Correct tool for *review*, wrong one for authoring: not scriptable, no diff, and it keeps Chatwoot blind to the Thai. Keep it as Mai's review surface, reading what the pipe wrote. |
| Store Thai in the English article's `meta` jsonb | Invents a schema Chatwoot already has (`associated_article_id`), and hides Thai from the portal, the widget and search. |

## 4. Field mapping

For a Chatwoot `th` article whose root (`associated_article_id`) is English article *E*, with
Shopify article *A* found by `custom.chatwoot_id == E.id`:

| Shopify translation key | Value | Notes |
|---|---|---|
| `title` | `th.title` | |
| `body_html` | `ChatwootMarkdownRenderer.new(th.content).render_article` | Same renderer as the English body, so the two languages render identically. |
| `summary_html` | `<p>escaped(th.description)</p>`, else the 160-char fallback | Same rule as English, so the two stay shaped alike. |
| `meta_title` | `th.title` | Mirrors `global.title_tag`. **See D5 — this overwrites 26 hand-written values.** |
| `meta_description` | `th.description`, squished, 320 chars | Only when *A* actually exposes the key (36 of 48). |
| `handle` | **not registered** | URLs stay language-neutral and stable. |

Every value is registered against the **current digest** of the corresponding English key, read
from `translatableResource(resourceId:)` immediately before the write. Keys absent from the
source's `translatableContent` are skipped rather than guessed at.

### 4.1 What this would change in Shopify today

Measured, not predicted — `translation_status` computes the value the sync would send for every
article and diffs it against what Shopify holds:

| Key | Identical | Would change |
|---|---|---|
| `title` | 48 | 0 |
| `body_html` | 48 | 0 |
| `meta_description` | 36 | 0 |
| `summary_html` | 38 | **10** |
| `meta_title` | 22 | **26** |

The bodies and titles are untouched — the pipe reproduces the existing Thai exactly. The two
non-zero rows are the honest cost of putting a single source of truth behind fields that did not
have one, and both are decisions rather than side effects: `summary_html` in §6.2, `meta_title`
in D5.

## 5. Components

All new files live in the `umi/` overlay or as a `zz_umi_*` initializer; the English sync path is
not modified.

| File | Role |
|---|---|
| `umi/app/services/shopify/article_translation_sync_service.rb` | New. Resolves the Shopify article for the root English article, reads digests, registers or removes the locale's translations. |
| `umi/app/services/shopify/help_center_graphql.rb` | New. The GraphQL plumbing the sync, importer and status report share: client, help-blog article lookup by `custom.chatwoot_id`, and a query helper that treats a GraphQL error as a failure rather than as empty data. |
| `umi/app/services/shopify/help_center_locales.rb` | New. The single place that decides which locales sync and how. |
| `umi/app/services/shopify/help_center_content.rb` | New. Body and summary mapping, shared with the English sync so the two languages cannot drift in shape. |
| `umi/app/services/help_center/html_to_markdown.rb` | New. Narrow HTML→markdown converter for the import, plus the equivalence check. Raises on anything it does not understand. |
| `umi/app/services/help_center/translation_import_service.rb` | New. The bootstrap (§6). |
| `umi/app/services/help_center/translation_status_service.rb` | New. Drift + the would-change diff (§7). |
| `umi/app/services/shopify/client_factory.rb` | **Edit (UMI-owned).** Adds `graphql_client_for(hook)` beside the existing REST client, behind the same `Context.setup` mutex. |
| `umi/app/models/shopify_help_center_syncable.rb` | **Edit (UMI-owned).** Widens the gate to the translation locales; carries `root_id` in the snapshot. |
| `umi/app/jobs/shopify/help_center_sync_job.rb` | **Edit (UMI-owned).** Dispatches on locale: source locale → existing service, translation locale → new one. |
| `umi/app/services/shopify/help_center_sync_service.rb` | **Edit (UMI-owned).** Body/summary/single-line helpers move to `HelpCenterContent`; behaviour unchanged, pinned by its existing spec. |
| `config/initializers/zz_umi_shopify_help_center.rb` | **Edit.** Adds `read_translations` / `write_translations` to the requested OAuth scopes. |
| `lib/tasks/umi_help_center_translations.rake` | New. `import_translations`, `backfill_translations`, `translation_status`, `translation_reviewed`. |

### 5.1 Events

The Thai article's own `after_commit` drives everything. The English article's does not touch
translations at all.

| Chatwoot event on the `th` article | Shopify |
|---|---|
| created / updated, `status: published` | `translationsRegister` for every mapped key |
| updated to `draft` or `archived` | `translationsRemove` for the locale |
| destroyed | `translationsRemove` for the locale |

Draft and archived remove the translation rather than leaving it. The alternative — a Chatwoot
draft while the storefront still serves the old Thai — is the same class of silent divergence
this spec exists to close. With `th` unpublished on the storefront the blast radius is nil
today, and once published the fallback is clean English, not a stale sentence.

### 5.2 Ordering

A `th` article can commit before its English counterpart exists in Shopify (a fresh portal, a
backfill run out of order). The service raises a retryable error in that case so Sidekiq backs
off and tries again, rather than dropping the translation with a log line nobody reads. The
`backfill_translations` task runs English first by construction.

## 6. Bootstrap: importing the existing Thai back into Chatwoot

The pipe needs a source. `rake umi:help_center:import_translations` reads the Thai out of
Shopify and writes it into Chatwoot as `th` articles.

### 6.1 The no-clobber guarantee

The one thing this must not do is degrade Mai's Thai. So the import does not translate anything
and does not paraphrase anything. It derives Thai **markdown** from the Thai **HTML** already in
Shopify, and then proves the derivation is lossless:

```
th_html (Shopify)  ──convert──►  th_markdown  ──ChatwootMarkdownRenderer──►  th_html'
                                              assert equivalent?(th_html', th_html)
```

An article whose round-trip is not equivalent is **refused, listed, and left alone** — never
imported on a guess. Because the assertion holds, the first sync after import re-registers what
is already in Shopify, against the same digest: a no-op, not a rewrite.

The converter handles only the tags that actually occur (§2.4) and raises on anything else,
so an unexpected construct fails loudly instead of being silently dropped.

**Measured against the live corpus: 96 of 96 bodies** — 48 English and 48 Thai — round-trip
equivalent. Zero refusals.

### 6.2 What the import creates

- 12 `th` categories mirroring the English ones, each with `associated_category_id` → its English
  category. **Required**: `Article#ensure_locale_in_article` takes an article's locale *from its
  category*, so a `th` article filed under an `en` category would be forced back to `en`.
- 48 `th` articles, each with `associated_article_id` → its English article, an explicit slug
  (`<en-slug>-th`; `ensure_article_slug` runs `parameterize`, which reduces a Thai title to an
  empty string), and `title` / `content` / `description` from the Thai translations.
- `description` is imported only where the English article has one (36 of 48). For the other 12,
  importing the current Thai `summary_html` would enshrine a translation of a truncation bug
  (§2.5); leaving it empty lets the fallback recompute a fresh cut from real Thai prose. It
  affects only `summary_html`, on 10 of those 12 (two already match), and the task prints the
  before for each so the change is reviewable rather than assumed. Some are near-identical
  rewordings (`…ให้คุณ—คุณเลือกได้เลย` → `…ให้คุณเลือก`); one loses the stray Latin `F` §2.5
  describes, though it is still cut mid-word because the underlying bug is out of scope.

`--dry-run` is the default. Nothing is written without an explicit `apply`.

### 6.3 Why this also fixes the widget

The Assistance drawer fetches `/hc/<portal>/<locale>/articles.json`
(`app/javascript/widget/api/endPoints.js:118`). The widget already ships Thai UI strings
(`widget/i18n/locale/th.json`, patch #2). Today a Thai-locale widget would render an **empty**
FAQ list, because Chatwoot has no `th` articles — not an English fallback, nothing. The import
is a prerequisite for ever running the widget in Thai.

## 7. The staleness signal

The pipe alone does not close the leak. English changes, the Thai article in Chatwoot does not,
and the two drift again — one layer up.

**Shopify's `outdated` flag cannot be the signal.** Any save of a translation pins the current
digest and clears it, so an unrelated Thai typo fix would erase the warning while the Thai is
still semantically a version behind. That is true of Translate & Adapt too; it is a property of
the digest mechanism, not of this design.

**Chatwoot's own timestamps can.** For an English article *E* and its Thai counterpart *T*:

```
drift(E) = T.nil? || E.updated_at > T.updated_at
```

`rake umi:help_center:translation_status` prints, per article: whether a Thai counterpart
exists, whether it is behind, what Shopify reports for `translations(locale:"th"){ outdated }` as
an independent cross-check, and which keys the sync would change if it ran now (§4.1). It exits
non-zero when anything is missing or behind, so it can gate a deploy or drive a scheduled check.

This is an over-approximation: an English typo fix flags the Thai. That is the correct bias.
It cannot be cleared accidentally, it needs no Shopify call, and clearing it means exactly what
it should — someone opened the Thai article, looked at it, and saved.

`views` and `position` do not disturb it: both are written with `update_column`, which does not
touch `updated_at`.

**One hole, and its fix.** "I read the Thai against the new English and it still says the right
thing" is a real outcome, and it changes nothing — so saving the article writes no row, Rails
does not move `updated_at`, and the flag stays up forever on an article that is actually fine.
`rake 'umi:help_center:translation_reviewed[th,<source article id>]'` records that review by
touching the translation. Without it the over-approximation would accumulate into noise, which is
how a report stops being read.

That touch fires the normal sync, so the translation is re-registered against the English digest
as it now stands and Shopify's `outdated` flag clears too. That is the intended reading: somebody
looked, and the translation is current.

**Open question for Ivan (§10, D2).** A report nobody runs is not a signal. This install has no
push surface: `SENTRY_DSN` is empty and the Sidekiq dead set is unwatched (recorded in
`UMI-PATCHES.md` under patch #22, which posts a private note precisely because an exception is
not a signal here). Options, in ascending order of work: run the task by hand after content
edits; a daily cron that logs a WARN line; a daily cron that opens/updates a Chatwoot private
note; a Telegram nudge through polygram. This spec ships the task and the cron-shaped job; which
surface it should shout into is a decision, not an implementation detail.

## 8. Required manual steps

1. **Reconnect the Shopify integration.** `translationsRegister` needs `write_translations`, and
   reading digests needs `read_translations` (verified against the 2026-01 schema). Neither is in
   the token today. The initializer adds them to `REQUIRED_SCOPES`, but an existing token does not
   gain scopes — the integration must be disconnected and reconnected in Chatwoot, exactly as it
   was when `write_content` was added (`UMI-SHOPIFY-HELP-CENTER-SPEC.md` §8). Until then the
   service logs a one-line skip and writes nothing.
2. **Add `th` to the portal.** `config.allowed_locales = ['en', 'th']` on portal `umi-help`.
   Not paperwork: `Category` validates its locale against the portal's `allowed_locales`, so the
   import cannot create the `th` categories until this is done — it fails loudly rather than
   filing Thai articles under English categories. Optionally list `th` under `draft_locales`
   while the content is being reviewed; that only hides it from the portal's own locale switcher,
   it does not gate the API.
3. **Run the import**, review its report, then `apply`.
4. **Run `backfill_translations`** once to seed, then the event path carries it.

## 9. Failure modes

| Failure | Behaviour |
|---|---|
| Token lacks `write_translations` | One-line skip per article, no writes. Same posture as the existing `write_content` guard. |
| Digest moved between read and register | `userErrors` from Shopify; re-read once and retry, then let Sidekiq retry. Never force. |
| English article missing in Shopify | Retryable raise, so ordering races self-heal. |
| Chatwoot locale not in `shopLocales` | Skip with a loud log. Registering into a locale the shop does not have would be silently discarded. |
| Round-trip assertion fails on import | Article refused and listed. No partial write. |
| Shopify unreachable during import | Read once up front, so it reports one cause rather than 48 article failures. |
| Someone deletes the `th` article | Translation removed. This is source-of-truth semantics and matches the English path, but it means a mis-click removes live Thai — worth knowing before `th` is published. |
| `handle` gets translated by someone in the admin | Thai URLs fork from English. Nothing here writes it; the status task reports it if it appears. |

## 10. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Who reviews machine-derived Thai before `th` publishes? | Unchanged from `THAI_LOCALIZATION_SPEC.md` D1 — Mai, in Translate & Adapt. The import writes nothing new to review; it re-homes what she already has. |
| D2 | Where should the drift report shout? | See §7. Needs a call. |
| D3 | The 10 changed summaries (§6.2) | Recommend letting the fallback recompute. The alternative preserves a translated truncation bug. Reviewable in the import report either way. |
| D4 | Should `th` articles be `published` in Chatwoot? | Yes — publish status gates whether the translation exists in Shopify (§5.1). A Thai draft means "no Thai on the storefront". |
| D5 | `meta_title` — mirroring English overwrites 26 hand-written Thai SEO titles (§4.1) | **Needs a call.** Recommend mirroring. In English there is no SEO title distinct from the page title — the sync writes `global.title_tag` from `title` — so those 26 strings are translations of nothing and no source controls them: they are precisely the orphaned content this change exists to remove. Both phrasings are good Thai (e.g. `เสื้อผ้าของคุณเป็นไปตามขนาดมาตรฐานหรือไม่?` vs the article title's `เสื้อผ้าของคุณมีขนาดตรงตามจริงหรือไม่?`), so quality is equal and consistency improves. The alternatives: stop managing `meta_title` from Chatwoot (the 26 survive but drift forever — the leak, reinstated for that field), or give the Chatwoot article a real SEO-title field in `meta` for **both** languages (most correct, more work, English needs it too). Neither is built. |

## 11. Verification — what was actually run

Local, against the real corpus (48 English articles pulled from `chat.umi.store`, 48 Thai
translation sets pulled from the live Shopify store), with a fake in place of the Shopify socket
that replays those captured responses and records every mutation:

- **Round-trip:** 96/96 bodies (48 en + 48 th) convert to markdown and re-render equivalent.
  0 refusals. The two loose lists and the two apostrophe-in-href articles are in that 96.
- **Renderer drift check:** 48/48 English bodies re-render equivalent to what Shopify holds
  (byte-identical for 46; the other two are §2.4's apostrophe case).
- **Would-change diff:** the table in §4.1.
- **End-to-end (34 assertions, all passing):** seed the portal → dry run writes nothing → apply
  creates 48 `th` articles and their categories, each linked to its English root → the stored
  markdown re-renders to the Thai already in Shopify → a second apply is a no-op → editing the
  Thai registers against the **English article's** gid, in `th`, with every value digest-pinned
  and no `handle` → editing the English writes **no** translation and flags the pair as behind →
  editing the Thai clears it → a no-op save does not, `translation_reviewed` does → unpublishing
  and deleting each issue `translationsRemove` for `th` only and leave the English article alone.
- **Specs:** 342 examples across `spec/{services,models,jobs,controllers}/umi/`, 0 failures,
  including the pre-existing English sync spec (unchanged behaviour after the shared-helper
  extraction). Rubocop clean on every touched file.

**Not run:** a real `translationsRegister` against the production store. That is a production
write and Ivan's call. Note it would be a no-op for `title`/`body_html`/`meta_description` and is
invisible to customers regardless, since `th` is unpublished — but it is still a write.

## 12. Out of scope

The `summary_html` truncation bug (§2.5); publishing the `th` shop locale; the language selector;
translating the widget's own UI (done, patch #2); locales other than Thai — though nothing here
is Thai-specific beyond a default, and `UMI_HC_TRANSLATION_LOCALES` takes a list.
