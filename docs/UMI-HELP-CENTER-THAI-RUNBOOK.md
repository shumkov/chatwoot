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

Then in `umi-vps-infra`: **`pg_dump` first**, bump `chatwoot_version`, and
`ansible-playbook site.yml --tags chatwoot`.

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

## 3. Grant the translation scopes

`translationsRegister` needs `write_translations`, and **an existing token does not gain
scopes** — the grant has to be reissued.

**Reconnecting alone does not do it.** The app runs on Shopify **managed installation**, where
the granted scopes come from the app's own configuration, not from the `scope` parameter
Chatwoot puts in its authorize URL. `Shopify::IntegrationHelper::REQUIRED_SCOPES` — which this
branch widens at boot — is therefore *requested and ignored*. A disconnect/reconnect hands back
exactly what the app config already declared, which is how 2026-08-26 was spent discovering
this: the reconnect succeeded, the consent screen said nothing about translations, and the new
hook came back without `write_translations`.

The scopes live in **`umi-vps-infra`**, in `shopify/umi-chatwoot/shopify.app.toml`. Two steps,
in this order:

**a. Release an app version that declares them.** From `shopify/umi-chatwoot` in that repo, add
the scopes to `[access_scopes]` and:

```bash
shopify app deploy --allow-updates --message "add translation scopes"
```

The CLI logs in through a device code — it prints a verification code and opens
`accounts.shopify.com`; the login itself is interactive and cannot be scripted. Success looks
like `New version released to users.` with the app version name.

**b. Reconnect in Chatwoot, so the store approves the new access.** **Settings → Integrations →
Shopify → Delete**, confirm, then **Connect**, enter `pizeev-ys.myshopify.com` in *Store URL*,
and approve. The consent screen now names what was added — `Edit other data: Translations` — and
if it does not, step (a) did not take effect and there is no point approving.

Verify:

```ruby
Integrations::Hook.find_by(app_id: 'shopify').settings['scope']   # must contain write_translations
```

`read_translations` will **not** appear even if the toml declares it: Shopify folds read into
write for this resource. The sync's guard asks for `write_translations` only, so that is fine.

The sync logs `skip … missing write_translations scope` until this is done and stops afterwards.

**Mind what else the app config declares.** The grant is the whole toml, not a delta, so a
reconnect can also *remove* a scope that the old hook happened to carry from the legacy install
flow. `read_fulfillments` disappeared exactly this way before it was added to the toml on
2026-08-26.

### Two consequences of reconnecting, neither obvious

(Both apply to step (b), and to every later reconnect.)

**The hook is destroyed and recreated**, so anything living in its `settings` is lost. That
includes `umi_contact_sync_watermark` (patch #7). A missing watermark is treated as "backfill
needed" and the contact poll **refuses to run** rather than syncing from epoch — safe, but it stays
stopped until somebody notices. Re-run it afterwards:

```bash
bundle exec rake 'umi:shopify_contacts:backfill[<account_id>]'
```

A full backfill is only needed if the old value is gone. Read the watermark *before*
disconnecting and write it back afterwards — the poll then resumes from where it stopped and
picks up anything that changed during the gap, in seconds rather than a full re-sync:

```ruby
hook = Integrations::Hook.find_by(app_id: 'shopify')
hook.update!(settings: hook.settings.merge('umi_contact_sync_watermark' => '<saved value>'))
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
