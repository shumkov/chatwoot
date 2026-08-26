# Thai Help Center — rollout runbook

Companion to `UMI-HELP-CENTER-THAI-SPEC.md`. Branch: `umi-help-center-thai`
(patches 27 + 28). Every step is reversible except where marked.

**Read §0 before starting.** The ordering is not cosmetic — two of the steps make the Thai FAQ
*blank* if they run early, and one of them is customer-visible.

## 0. What must be true, in what order, and why

```
deploy the fork          gate lifted; nothing syncs yet (no th articles exist)
  ↓
portal allowed_locales   th categories cannot be created without it
  ↓
Shopify reconnect        translationsRegister needs write_translations
  ↓
import as DRAFT          public the moment they exist, so staged
  ↓
publish ONE, verify      the single-article round trip
  ↓
publish the other 47
  ↓
ship the theme change    drawer starts asking for th — must be last
```

Two corrections to the ordering as first drafted:

- **The inbox side is already wired in production.** `inbox.portal_id` is set — the live widget
  config renders the full portal object. It is a trap for a new environment, not a step here.
  (Spec §12.1a explains why it looks like one.)
- **The import is a step.** Adding `th` to `allowed_locales` without articles behind it leaves the
  intersection non-empty but the article list empty — still a blank FAQ, just for the third of the
  three reasons in §12.1a rather than the first.

## 1. Deploy the fork

**This restarts live chat.** Announce it, keep the window tight, confirm it is back.

```bash
cd ~/Projects/shumkov/chatwoot
git checkout umi && git pull --ff-only
git merge --ff-only umi-help-center-thai      # or via PR
git push origin umi
git tag umi-v4.16.0 && git push origin umi-v4.16.0   # match the base tag in UMI-PATCHES.md
```

**Check `origin/umi` before doing any of that** — someone may have merged already, and a stale
local ref makes it look otherwise. `git log --oneline -1 origin/umi` after a fetch.

### 1b. Wait for the *tag* build, then pin its digest

Two builds fire and they are not interchangeable. The push to `umi` builds `umi-latest`; the
**tag** build publishes the versioned image the infra pins. Only the second one matters here, and
it finishes later. `gh run list --repo shumkov/chatwoot` shows both — look for
`Build UMI Chatwoot image` against `umi-v4.16.0-<n>`, not against `umi`.

**Your work in this repo ends here.** `AGENTS.md` — "Deployment — never from this repo" — makes the
deploy `umi-vps-infra`'s, because `chatwoot_version` and the rendered compose file on the VPS are
contended state and two worktrees deploying would race on both. Hand over the tag and its digest;
do not bump or run ansible from here. The procedure lives in that repo's
`.claude/skills/deploy/SKILL.md`.

The digest is what you hand over, because the role there asserts
`chatwoot_version is match('^[^@]+@sha256:[0-9a-f]{64}$')` — a bare tag is rejected. Resolve it
from the registry once the build has published:

```bash
REPO=shumkov/chatwoot
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:$REPO:pull&service=ghcr.io" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/$REPO/manifests/umi-v4.16.0-<n>" | grep -i docker-content-digest
```

A 404 means the build has not published yet — that is a build gate, not a permissions problem, and
there is nothing to deploy until it clears. Sanity-check the method against the currently pinned
tag first: it should return the digest already in `main.yml`.

Then hand `umi-v4.16.0-<n>@sha256:<digest>` to whoever owns the deploy and wait for them to
confirm the VPS is running it. **Steps 2 onward are impossible until then** — `import_translations`,
`backfill_translations`, `translation_status` and `translation_review` all live in the image and do
not exist on the box until it deploys.

Two traps `AGENTS.md` names, worth repeating because they produce a *healthy-looking* wrong result:
`docker compose pull && up -d` is a **silent no-op** against a digest-pinned image, and
**migrations do not run on container boot** — the app comes up fine on the old schema. If the new
rake tasks are missing after a supposed deploy, that is the first thing to suspect.

### On the CI checks

`Lint PR` **always fails** on a `UMI:` branch — upstream's semantic-PR-title action rejects `UMI`
as a release type, and it does so on every patch branch in this fork. It is not a signal.
`Run Chatwoot CE spec` is the one worth reading, because it covers the whole suite rather than the
`umi/` tree.

**Smoke test before going further:** `/widget` returns 200, the drawer opens on the storefront,
Facebook and Instagram send, and a test message arrives. The English Help Center sync is untouched
by this change but it shares the deploy — confirm an English article edit still reaches Shopify.

**Nothing syncs to Shopify yet.** No `th` articles exist, so the widened locale gate has nothing to
act on. That is deliberate: the deploy and the first write are separate events.

## 2. Portal locales

```ruby
portal = Portal.find_by(slug: 'umi-help')
portal.update!(config: portal.config.merge('allowed_locales' => %w[en th]))
```

`Category` validates its locale against this, so the import in §4 fails loudly without it.

Optionally add `th` to `draft_locales` too — that hides the locale from the portal's own switcher
while it is being reviewed. It does **not** gate the API, and
`chat.umi.store/hc/umi-help/th` answers 200 either way, which is why §4 stages as drafts.

## 3. Reconnect the Shopify integration

`translationsRegister` needs `write_translations`; reading digests needs `read_translations`.
Neither is on the token, and **an existing token does not gain scopes**.

**There is no CLI or rake path.** It is an OAuth round trip through a browser:
`POST …/integrations/shopify/auth` mints a state token and returns a Shopify authorize URL built
from `Shopify::IntegrationHelper::REQUIRED_SCOPES`, the merchant approves in Shopify, and
`GET /shopify/callback` creates the hook with the granted scope string.

**It must happen after §1.** The scope list is read from the constant this branch widens at boot,
so a reconnect against the old code requests the old scopes and silently fixes nothing.

Click path, in Chatwoot: **Settings → Integrations → Shopify → Disconnect**, confirm, then
**Connect**, enter `pizeev-ys.myshopify.com` in *Store URL*, and approve on Shopify's consent
screen — which should now list translation permissions it did not before.

Verify:

```ruby
Integrations::Hook.find_by(app_id: 'shopify').settings['scope']   # must contain write_translations
```

The sync logs `skip … missing write_translations scope` until this is done and stops afterwards.

### Two consequences of reconnecting, neither obvious

**The hook is destroyed and recreated**, so anything living in its `settings` is lost. That
includes `umi_contact_sync_watermark` (patch #7). A missing watermark is treated as "backfill
needed" and the contact poll **refuses to run** rather than syncing from epoch — safe, but it stays
stopped until somebody notices. Re-run it afterwards:

```bash
bundle exec rake 'umi:shopify_contacts:backfill[<account_id>]'
```

**Everything on that token is down while it is disconnected** — the orders sidebar (#21), contact
sync (#7), order attribution (#25) and the English Help Center sync (#3). Keep the gap to a minute,
and do not disconnect during a busy period.

## 4. Import the Thai, as drafts

```bash
bundle exec rake 'umi:help_center:import_translations[th]'          # report only
bundle exec rake 'umi:help_center:import_translations[th,apply,draft]'
```

Read the dry run first. Expect **48 to import, 0 refused**. A refusal means an article's body did
not survive the markdown round-trip; it is listed by name and is left alone — resolve it rather
than overriding it.

Drafts write nothing to Shopify (spec §5.1), so this step cannot damage the existing Thai.

Then read a few in the dashboard against their English. This is the review that the staging exists
for.

## 5. One article, end to end

Pick a short, low-traffic one. Publish **only that one**:

```ruby
Portal.find_by(slug: 'umi-help').articles.find_by(locale: 'th', associated_article_id: <en id>)
      .update!(status: :published)
```

Then read Shopify back over the Admin API and diff it against what was there before:

```graphql
query { translatableResource(resourceId: "gid://shopify/Article/<id>") {
  translations(locale: "th") { key value outdated } } }
```

**Expect no change at all.** The reconciler writes only absent-or-outdated fields, and this article
is complete and current, so a correct run is a no-op. `translation_status` says the same:

```bash
bundle exec rake 'umi:help_center:translation_status[th]'   # "the sync would change in shopify: 0"
```

If anything did change, stop and read it before publishing the rest.

## 6. The other 47

```ruby
Portal.find_by(slug: 'umi-help').articles.where(locale: 'th', status: :draft).find_each { |a| a.update!(status: :published) }
```

Each publish enqueues its own sync. Re-run `translation_status`: 48 counterparts, 0 missing,
0 behind, 0 would change.

## 7. Ship the theme change — last

`c7deacc` on `translate-thai` makes the storefront pass `locale` to the widget. **Do not merge it
before §6 is verified.** Until Chatwoot holds published Thai articles, a Thai visitor gets a drawer
with no FAQ at all, which is worse than the English one they get today. The commit carries this
warning in a comment at the line.

## Rolling back

| Step | Undo |
|---|---|
| 1 | redeploy the previous `chatwoot_version` |
| 2 | remove `th` from `allowed_locales` |
| 3 | reconnect without the scopes (the sync then skips, loudly) |
| 4–6 | unpublish or delete the `th` articles — **note** this does not remove their Shopify translations, because removal is off by default (spec §5.1). That is the safe direction: the Thai that was there before this work stays there. |
| 7 | revert the theme commit |

The one genuinely irreversible thing in this list is a `translationsRegister` that overwrites a
value nobody kept a copy of — and the reconciler is built so that cannot happen for a field that is
present and current. §5 is where you find out whether that holds, on one article, before 47 more.

## Afterwards

- `translation_status` is the standing check. It exits non-zero when anything is missing or behind,
  so it can gate a deploy or drive a scheduled run. Where it should shout is still open (spec D2).
- **`translation_review` is the translator's list.** When English moves, the reconciler replaces the
  Thai written against the old English with a derived one — correct, and the one case where a
  machine string supersedes a person's. Each replacement is stamped on the translation article and
  rendered by `rake 'umi:help_center:translation_review[th]'` with the English title, both Thai
  values readable, and a link to the editor. Forward it to Mai; sign off per article with
  `translation_reviewed`, which clears the entries.
- Mai's review of the 25 widget chrome strings: spec §12.4.
- Two English-side follow-ups, both deliberately out of scope and both sequenced *after* this:
  the `summary_html` truncation and the apostrophe drift (spec §2.4, §2.5).
