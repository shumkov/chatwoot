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

It is also the second instance of a pattern worth naming, alongside the summary truncation in
§2.5: **a sync artifact that manufactures false staleness.** In both cases the English body or
summary in Shopify differs from what today's code would produce, for reasons that have nothing to
do with the content. The next edit to any affected article rewrites the field, moves the digest,
and marks the Thai outdated — so a translator is asked to re-check copy that did not change. Two
instances is a pattern; a third should prompt a rule rather than another note.

### 2.5 A pre-existing English bug the Thai mostly escaped

When a Chatwoot article has no `description`, `summary_html` falls back to
`strip_tags(content)[0, 160]` — a hard cut of **raw markdown** at 160 characters. By a
trailing-Latin-fragment / `%XX`-escape heuristic, **21 English** summaries are truncated or leaky:

- *"How do I find my size?"* ends `...compare them to a piece you already own and love. F`
  (the start of "For").
- *"Where can I try things on in person?"* leaks a raw URL fragment,
  `Tree%20O'clock%20Gallery%`, into its summary because markdown link syntax survives
  `strip_tags`.

**Only 4 Thai summaries share the defect, and two of those are the heuristic false-firing on a
legitimate trailing "THB".** The Thai summaries are not translations of the English summaries: each
was derived from the Thai *body* and cut at a word boundary at roughly the English summary's
proportion of the English body, so the English cut points were not inherited. "How do I find my
size?" ending `…ดูสิ F` is real, and is the exception rather than the pattern.

That matters for §6: an equality gate applied to `summary_html` would fail on most of the corpus
and read as "the data is untrustworthy" when the truth is "these two fields were produced by
different methods". The gate covers `body_html` only.

**Deliberately out of scope here.** Fixing it rewrites the affected English summaries, changes
their digests, and marks the corresponding Thai outdated — the exact churn this spec exists to
prevent. It wants its own patch, sequenced *after* this one so the repair flows through the pipe.

## 3. Chosen approach

**Chatwoot's Help Center is the source of truth for the storefront FAQ, in every language.
Shopify is downstream. A Thai article in Chatwoot is projected onto the English article's Shopify
record as a translation, never as a second article.**

That is a decision, not a workaround. Seeding Chatwoot from the Thai that currently lives in
Shopify is not a migration hack to get past an awkward starting state — it is how the intended end
state gets established, once. The pipe then keeps Shopify in step.

**Consequence for the translator, stated plainly because it moves somebody's workflow:** Thai Help
Center copy stops being something Mai edits in Shopify's Translate & Adapt and becomes something
she edits in Chatwoot, next to the English it translates. Translate & Adapt remains the right place
to *review* Thai across the store; it stops being the place Help Center Thai is authored. She should
learn that from this document rather than from a surprise.

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

### 4.1 The sync is a reconciler, not a writer

Per field, per article:

```
absent in Shopify                                        -> write it
present but marked outdated                              -> replace it
present, current, backed by a Chatwoot field, and ours
  differs from Shopify's                                 -> write it
present and current otherwise                            -> leave it alone
```

The first two clauses are the governing rule: *missing, translate; outdated, replace; matching,
don't touch.* Shopify hands both signals over directly — `translations(locale:"th"){ value outdated }` —
so nothing has to be inferred at write time, and a second run writes nothing.

The third clause is the one that makes Chatwoot the source of truth rather than merely the
storage. Without it a translator's edit in Chatwoot would never reach the storefront, because
Shopify would still be holding a present, not-outdated value — Chatwoot would own everything
except the edits people actually make.

**`backed` is what keeps clause three from becoming a licence to overwrite.** A key is backed when
an author can edit it directly:

| Key | Backed by | Notes |
|---|---|---|
| `title` | `Article#title` | |
| `body_html` | `Article#content` | |
| `summary_html` | `Article#description` | only when the article has one |
| `meta_description` | `Article#description` | only when the article has one |
| `meta_title` | — | backed only where the locale's own `meta_title` still equals its `title` |

`summary_html` on an article whose source has no description is a truncation of the body rather
than something anyone edits, so it is not backed there.

**`meta_title` is the interesting one.** Chatwoot has no SEO-title field — it is derived from the
article title — so nothing in Chatwoot can answer whether it is ours to keep in step. The *locale*
can: if its `meta_title` still equals its `title`, nobody ever pulled the two apart, and a title fix
should carry. Where they differ, somebody phrased them separately in Translate & Adapt (which
presents them as two fields and invites exactly that), and the difference **is** the intent.

Against the live data that splits precisely along the line that matters: the **26 that differ** are
protected permanently and can only be refreshed by the outdated flag; the **22 that match** stay in
step with a Thai title edit instead of silently rotting away from the visible heading. The
heuristic is self-evident rather than clever — two identical strings express no intent to keep them
apart.

### 4.2 What this writes to Shopify today: nothing

Measured, not predicted. All 228 fields are present and none are outdated, so every field falls in
the "leave it alone" bucket:

| Key | Present and current | Would be written |
|---|---|---|
| `title` | 48 | 0 |
| `body_html` | 48 | 0 |
| `summary_html` | 48 | 0 |
| `meta_title` | 48 | 0 |
| `meta_description` | 36 | 0 |

`translation_status` reports the same thing per field — `0 would change` on all five, asserted in
the end-to-end run against the real corpus.

This is a stronger guarantee than the one an earlier draft of this spec offered. It is not "we
compared the values carefully and believe they match" — it is "the pipe does not write over current
translations at all." The semantic comparison in §2.4 is still worth having, but as *verification*
that the derivation is faithful, not as the thing standing between us and data loss.

For the record, had the sync been a plain writer it would have replaced **26 `meta_title`s** and
**10 `summary_html`s** with derived values. Those are the fields clause three deliberately cannot
reach.

## 5. Components

All new files live in the `umi/` overlay or as a `zz_umi_*` initializer; the English sync path is
not modified.

| File | Role |
|---|---|
| `umi/app/services/shopify/article_translation_sync_service.rb` | New. Resolves the Shopify article for the root English article, reads digests and the locale's current state, registers or removes. |
| `umi/app/services/shopify/translation_reconciler.rb` | New. The policy half, with no Shopify calls: what the locale should hold, and which of those fields may be written (§4.1). Kept apart so the dry-run report asks the same question the pipe answers, without standing up the pipe. |
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
| created / updated, `status: published` | reconcile every mapped key (§4.1) |
| updated to `draft` or `archived` | nothing, and the divergence is reported |
| destroyed | nothing, and the divergence is reported |

**Removal is off by default (`UMI_HC_TRANSLATION_REMOVE`), and that is not timidity.** An earlier
draft had draft/archived/deleted issue `translationsRemove`, reasoning that Chatwoot saying "not
published" while the storefront serves Thai is a silent divergence. It is. But that draft passed
**every** `TRANSLATABLE_KEYS` entry to the mutation, so it erased the whole locale for that article
— including values a human wrote in Translate & Adapt that this sync never touched. On a locale
populated by hand before Chatwoot owned it, which is exactly the state of a first rollout, one
mis-saved draft takes the whole article's translation with it.

That combination was live: the staging sequence in §8 creates the locale as **drafts**, so
"deploy the fork, then import as drafts" would have fired 48 removes and wiped all 228 Thai fields
off the store. Recoverable — Chatwoot would hold the Thai by then — but it would have destroyed the
originals, and it would have happened because we were being careful.

It also does not fit the governing rule. Reconciling is not deleting; a rule that says "if it
matches, don't touch" should not have a branch that erases wholesale. So the divergence is
reported instead: `translation_status` carries an `unpublished` state meaning "Chatwoot is not
publishing this, Shopify still serves it", and clearing it is a person's decision.

**The limit, stated accurately.** With removal off, unpublishing a Thai article in Chatwoot does not
take it off the Thai storefront, and the report is a mitigation rather than a fix.

Note what the limit is *not*: `translationsRemove` takes `translationKeys: [String!]!` — required —
so removal is inherently per-field and there is no whole-locale wipe to be afraid of. The blast
radius above was chosen by the caller, not imposed by the API. And the provenance needed to choose
better already exists: **the `backed` predicate** (§4.1) answers "is this field Chatwoot's" for
exactly this purpose. So "unpublish means unpublish" reduces to passing an article's backed keys
instead of all of them — Mai's 26 `meta_title`s and the derived summaries survive because they are
not in that list, the same predicate protecting them in both directions. Not wired up yet; that is
a small, well-understood gap rather than missing tracking.

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
(`app/javascript/widget/api/endPoints.js:118`), and the import is a prerequisite for ever running
it in Thai. See §12 — this is not a prediction, it is measured against production.

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

**The Thai portal route is already public.** `chat.umi.store/hc/umi-help/th` answers 200 today with
an empty shell, so articles created under it are readable the moment they exist. Stage with
`import_translations[th,apply,draft]` and publish after review; the draft state writes nothing to
Shopify (§5.1).

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
| D5a | When English moves, the reconciler replaces a translator's Thai with a derived one | **Settled by Ivan: do it, and produce a review list.** Clause two stands — outdated means the Thai was written against English that no longer exists, so re-deriving it is right. What was missing was the loop on the other side. Every such replacement is now stamped on the translation article and rendered by `translation_review` for a translator: English title, both Thai values with markup stripped, and a link to the editor. Deliberately narrow — a field that was *absent* had no prior translation to review, and one written because the Chatwoot article changed is the translator's own edit arriving, so neither is listed. |
| D5 | `meta_title` — 26 Thai SEO titles differ from their article titles | **Closed by the reconciler rule (§4.1).** They are present and not outdated, so nothing overwrites them, and no export is needed because nothing is lost. Two earlier positions were wrong and are recorded because the reasoning matters: mirroring English was argued on the premise that the 26 were machine output being deduplicated (they are pre-existing human translation), and an export-then-overwrite compromise followed (superseded — there is nothing to export). The residual limit is now confined to those 26 rather than all 48: a `meta_title` that matches its title stays in step with a Thai title edit; one that differs can only be refreshed by the outdated flag. Giving Chatwoot articles a real SEO-title field, in `meta`, for **both** languages would remove even that. Not built. |
| D6 | Mai's three "quick question guide" strings match no surface that exists (§12.3) | **Product decision, not a translation one.** The drawer has no quick-reply prompts. Building them to hold three translated strings would be inventing a feature off a translation ticket. Recommend asking Mai where she saw them before deciding; her Thai is kept in §12.3 either way. |
| D7 | 25 widget chrome strings were translated here rather than by the translator (§12.4) | They are Chatwoot's own UI (day names, emoji picker, "we will be back online…"), not brand copy, and the alternative was leaving a Thai reader with English. Listed in §12.4 for Mai to correct. |

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
- **Specs:** 353 backend examples across `spec/{services,models,jobs,controllers}/umi/` and 240
  widget tests, 0 failures, including the pre-existing English sync spec (unchanged behaviour after
  the shared-helper extraction). Rubocop and prettier clean on every touched file.

For the drawer:

- **The failure was measured on production**, not predicted: `?locale=th` returns Thai chrome and
  **no FAQ block at all** (§12.1).
- **The fix was measured locally**: against a seeded portal that allows `th` and holds the imported
  Thai articles, the exact call the drawer makes —
  `/hc/umi-help/th/articles.json?sort=views&status=1&per_page=6` — returns Thai titles
  (`เครดิตร้านค้าใช้งานอย่างไร?`, `อ่านเรื่องราวของ UMI เพิ่มเติม`, …) where the `en` call returns the English
  ones. That is the data path for acceptance criterion 2, end to end.
- A **locale-coverage spec** now fails the build if a `UMI.*` string ships without Thai, or if any
  reachable widget string reverts to English.

- **The drawer was read in a browser, in Thai, at both of its real widths** — 640px (the desktop
  drawer's `width: 40rem`) and 390px (mobile, full-width). It renders end to end:

  ```
  ช่วยเหลือ
  ทีมงานของเราจะพร้อมให้บริการในอีก 4 ชั่วโมง 36 นาที (9 โมงเช้า GMT+7) …
  คำถามที่พบบ่อย
  เครดิตร้านค้าใช้งานอย่างไร?
  อ่านเรื่องราวของ UMI เพิ่มเติมได้ที่ไหน?
  …
  หัวข้อทั้งหมด
  แชทกับเราได้ที่
  WhatsApp  LINE  Messenger  Instagram  โทร
  ขับเคลื่อนโดย Chatwoot
  ```

  **No clipping and no overflow at either width**, checked programmatically as well as by eye:
  `document.scrollWidth == clientWidth`, and no element whose `scrollWidth`/`scrollHeight` exceeds
  its client box. Tone marks are not cut; the long titles wrap to two lines at 390px with the
  chevron staying aligned. Thai line-breaking inside a compound (`สั่ง` / `ซื้อไปแล้ว`) is the
  browser's ICU behaviour, identical on any site, not something this layout causes.

  The same page at `?locale=en` is unchanged, so the `UMI.CHANNELS_HEADING` / `UMI.CALL` extraction
  did not regress English.

**Not run:** a real `translationsRegister` against the production store.

**Note for whoever runs the preview next:** the `chatwoot-widget-preview` skill is stale.
`~/Projects/shumkov/chatwoot-umi-widget-drawer` no longer exists; the stack in
`~/Projects/shumkov/chatwoot` serves the same purpose. Two things bite: the `vite` service's
entrypoint does not `bundle install` (only `rails`'s does, and gems land in the image layer rather
than a volume), and Vite 6 rejects vite_ruby's proxy with a 403 unless it is started with
`__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=vite`. Rails also has to reach it by the `vite` hostname,
which a `docker compose run` container only gets with an explicit
`docker network connect --alias vite`.

## 12. The Assistance drawer

Content existing is not the bar. Thai has to reach the reader, and the drawer is where it fails
quietly.

### 12.1 Measured against production, not predicted

The widget resolves its own locale from `chatwootSettings.locale` on the host page
(`entrypoints/sdk.js:51` → `$chatwoot.locale` → the `config-set` message → `App.vue#setLocale`),
and outside an iframe also from `?locale=` on the query string. So production can be asked for Thai
directly. Loading
`chat.umi.store/widget?website_token=…&locale=th` at the drawer's real width returns:

```
ช่วยเหลือ
ทีมงานของเราจะพร้อมให้บริการในอีก 5 ชั่วโมง 12 นาที (9 โมงเช้า GMT+7) …
Chat with us on
WhatsApp  LINE  Messenger  Instagram  Call
Powered by Chatwoot
```

Two things to read off that. The header and welcome are already Thai — patch #2 translated the
`UMI.*` keys. And **the entire FAQ block is gone.** Not English, not a fallback: absent.

`ArticleContainer.vue` computes its fetch locale as
`getMatchingLocale(i18n.locale, portal.config.allowed_locales)`. Production's portal allows
`["en"]`, so the intersection with `th` is `null`, `hasArticles` is false, and the block renders
nothing. A Thai reader loses the FAQ entirely.

This is the acceptance criterion that fails silently, and it fails **today**, before any of this
work ships. It is also a hard sequencing constraint: the storefront must not start passing
`locale: th` until the portal allows `th` and holds Thai articles, or the drawer gets worse rather
than better.

### 12.1a "No FAQ block" has three causes and one appearance

Read this before debugging a blank drawer. The symptom is identical in all three cases — chrome
renders, the FAQ section is simply not there — and the causes are unrelated. **All three fail
silently**, which is what makes the list worth keeping:

| Cause | How to tell | Fix |
|---|---|---|
| The locale is not in the portal's `allowed_locales` | `window.chatwootWebChannel.portal.config.allowed_locales` lacks it | add it to the portal |
| The portal is not linked to the inbox | `window.chatwootWebChannel.portal` is **`null`** | set **`inbox.portal_id`** |
| The locale has no published articles | portal and locale both fine, `/hc/<slug>/<locale>/articles.json` returns `payload: []` | import/publish the articles |

**The second one is the trap.** `Portal#channel_web_widget_id` exists, is named as though it were
the link, and setting it changes nothing — the widget view reads `@web_widget.inbox.portal`
(`app/views/widgets/show.html.erb:17`), and `Inbox belongs_to :portal`. Setting only the portal
side produces a drawer that looks exactly like a locale misconfiguration. One console read of
`window.chatwootWebChannel.portal` separates them: `null` means the link, a populated object means
look at the locale.

Production already has the inbox side set — the live widget config renders the full portal object —
so this is a trap for a new environment or a fresh inbox, not a step in the rollout below.

### 12.1b And a fourth cause, with a different appearance

The three above all leave the chrome Thai and the FAQ missing. There is one more failure in this
area and it looks the opposite way round: **the whole widget stays English even though the
storefront passed the locale correctly.**

`App.vue#setLocale` applies a locale only if it appears in the inbox's `enabledLanguages`, and
**returns silently otherwise** — no warning, no fallback notice, nothing in the console. A locale
the inbox does not enable is indistinguishable from a storefront that never passed one.

Verified against production: `th` **is** in `enabledLanguages` (Thai among the ~40 the inbox
carries), so this path is clear for Thai. It is recorded because it is the only one of the four
that cannot be diagnosed by reading `window.chatwootWebChannel.portal`, and because it will bite
whoever adds a second locale.

| Symptom | Look at |
|---|---|
| Chrome Thai, no FAQ block | the three causes in §12.1a |
| Chrome English despite passing `locale` | `window.chatwootWebChannel.enabledLanguages` |

### 12.1c How the locale actually reaches the widget

Worth writing down because it removes a worry rather than adding one. The SDK forwards
`window.$chatwoot.locale` into the iframe by `postMessage` (`sdk/IFrameHelper.js:161`), and
`App.vue` applies it over the inbox default on receipt.

**Shopify's language switch is a full page navigation** to `/th/…`, so the widget re-boots with the
new locale rather than having to change one at runtime. The theme therefore needs no `setLocale`
call and no reactivity story — passing `locale` in `chatwootSettings` at boot is the whole
integration. That also settles a question this work left open: whether the channel labels, which are
resolved through a computed rather than a template `$t`, would update on a live locale switch. There
is no live locale switch to survive.

### 12.2 What was wrong in the widget itself

- **`UmiInboxLinks.vue` hardcoded `'Chat with us on'`** as a JavaScript literal, and labelled the
  phone link `'Call'` the same way. Nothing outside that file mentioned either string, so no
  translator could reach them — exactly the class of bug that makes a string invisible. Both now go
  through `UMI.CHANNELS_HEADING` / `UMI.CALL`; the four messenger names stay literals because they
  are proper nouns. Its spec now asserts the keys rather than the English, so a regression fails
  the build rather than shipping.
- **`widget/i18n/locale/th.json` had 40 keys still in English.** 25 of them are reachable in UMI's
  configuration and are now Thai: the day names and every "we will be back online…" variant, `YOU`,
  `VIEW_UNREAD_MESSAGES`, `POWERED_BY`, the emoji picker, the reply-to chip, the agent-name
  fallback.
- **15 are deliberately left English**, because nothing in UMI's configuration renders them: the
  pre-chat form (disabled on this inbox), the Dyte integration (not enabled), and `PORTAL.*`, which
  is dead in this fork since patch #2 replaced the in-drawer article view with links to the
  storefront.

**These 25 strings are Chatwoot's own chrome, not brand copy, and they were written here rather
than by the translator.** Day names and "Frequently used" carry no brand voice; the register was
matched to the existing `UMI.*` Thai. They should still go past Mai — §12.4 lists them.

There is **no search box** in this drawer, so there is no search placeholder to translate. Patch #2
replaced the upstream home with welcome → articles → links → composer.

### 12.3 What "the quick question guide" turned out to be

Mai's three strings — *"what are your shipping details"*, *"what is your return policy?"*,
*"what is your contact info?"* — **are not defined anywhere.** Checked, in order:

- exact-phrase grep across the whole fork, including every locale file;
- the widget's rendered output on production, read in a browser;
- the widget channel config: `welcomeTitle` and `welcomeTagline` are empty, the pre-chat form is
  disabled;
- the Help Center article titles, both the featured set the drawer shows and the most-read fallback;
- the storefront theme and the live storefront HTML.

The closest match on the storefront is **Shopify's own MCP tool description** — `Shopify.MCP.tools`
carries `search_shop_policies_and_faqs`, whose description lists *"What is your return policy?"*,
*"What is your shipping policy?"*, *"What is your phone number?"*. That is machine-facing text
Shopify injects for AI agents, not customer copy, not translatable, and not UMI's to change.

So either Mai is **proposing** quick-question prompts the drawer does not have, or she saw them on
a surface outside these two systems. Her Thai is good and worth keeping either way, but building a
quick-reply feature to hold it would be inventing a feature off a translation ticket. That is a
product decision, not a translation one — see D6.

### 12.4 Thai written here, for review

| Key | Thai |
|---|---|
| `UMI.CHANNELS_HEADING` | แชทกับเราได้ที่ |
| `UMI.CALL` | โทร |
| `POWERED_BY` | ขับเคลื่อนโดย Chatwoot |
| `YOU` | คุณ |
| `VIEW_UNREAD_MESSAGES` | คุณมีข้อความที่ยังไม่ได้อ่าน |
| `THUMBNAIL.AUTHOR.NOT_AVAILABLE` | ไม่ระบุ |
| `TEAM_AVAILABILITY.BACK_AS_SOON_AS_POSSIBLE` | เราจะกลับมาโดยเร็วที่สุด |
| `REPLY_TIME.BACK_IN_HOURS` | เราจะกลับมาออนไลน์ในอีก {n} ชั่วโมง |
| `REPLY_TIME.BACK_IN_MINUTES` | เราจะกลับมาออนไลน์ในอีก {time} นาที |
| `REPLY_TIME.BACK_AT_TIME` | เราจะกลับมาออนไลน์เวลา {time} |
| `REPLY_TIME.BACK_ON_DAY` | เราจะกลับมาออนไลน์ใน{day} |
| `REPLY_TIME.BACK_TOMORROW` | เราจะกลับมาออนไลน์ในวันพรุ่งนี้ |
| `REPLY_TIME.BACK_IN_SOME_TIME` | เราจะกลับมาออนไลน์ในไม่ช้า |
| `DAY_NAMES.*` | วันอาทิตย์ … วันเสาร์ |
| `EMOJI.PLACEHOLDER` / `EMOJI_ICON_PICKER.SEARCH_EMOJI` | ค้นหาอิโมจิ |
| `EMOJI.NOT_FOUND` / `EMOJI_ICON_PICKER.NO_EMOJI` | ไม่พบอิโมจิที่ตรงกับการค้นหา |
| `EMOJI.ARIA_LABEL` | ตัวเลือกอิโมจิ |
| `EMOJI_ICON_PICKER.FREQUENTLY_USED` | ใช้บ่อย |
| `FOOTER_REPLY_TO.REPLY_TO` | กำลังตอบกลับ: |

`BACK_IN_HOURS` carries the singular and plural forms as the same string on purpose: Thai has no
plural inflection, and the branch is upstream's, not ours.

### 12.5 Verified in the drawer

Both acceptance criteria were read in a browser rather than inferred — see §11 for the Thai render
at 640px and 390px, the overflow/clipping check, and the English no-regression pass.

### 12.6 The storefront side

`snippets/chatwoot-embed.liquid` passes no locale, so the widget falls back to the inbox's
language. It now passes `locale: {{ request.locale.iso_code | json }}`, which is one line and is
the whole of surface 2's storefront half — with the §12.1 sequencing constraint attached to it in
a comment, because shipping it early makes the drawer worse.

## 13. Out of scope

The `summary_html` truncation bug and the apostrophe drift (§2.4, §2.5) — both are English-side
sync artifacts that manufacture false staleness, and both want their own patch, sequenced *after*
this one so the repair flows through the pipe. Publishing the `th` shop locale and the storefront
language selector (`THAI_LOCALIZATION_SPEC.md` iteration 3). The Shopify Help page itself, which
serves Thai from the article translations automatically. Locales other than Thai — though nothing
here is Thai-specific beyond a default, and `UMI_HC_TRANSLATION_LOCALES` takes a list.
