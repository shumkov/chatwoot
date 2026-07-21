# UMI fork upgrade: v4.14.2 → v4.16.0

**Status:** proposed — awaiting sign-off before the shared `umi` branch is touched.
**Working branch:** `umi-upgrade-v4-16` (holds the completed trial rebase).
**Date:** 2026-07-21. Incorporates 3-agent review (feasibility / failure-modes / scope).

## Problem / goal

The shared `umi` branch pins upstream Chatwoot **v4.14.2** and carries a linear
stack of UMI patch commits. Upstream has since shipped `v4.15.0`, `v4.15.1`,
`v4.16.0`. Goal: rebase the UMI stack onto **v4.16.0** (confirmed the newest
stable tag, `gh api …/tags`, 2026-07-21), keeping the stack linear and all
patches still applying / still needed, verified booting + building + passing UMI
specs — **without touching the shared branch until signed off.**

## Ground truth about the current stack (corrected)

The pre-existing `umi-upgrade-v4-16` branch was cut from a **stale** `umi`
(16 commits). The real shared branch is larger — and **actively moving**:

- **`origin/umi` = v4.14.2 + 25 UMI patch commits** (linear), tip `8dee6bfa`
  *as of this writing*. It gained the widget-home redesign + Call channel + a
  "featured articles manager" backend beyond the 16 the stale branch had.
- ⚠️ **The shared branch is under active development — a new commit
  (`8dee6bfae`, "featured articles manager") landed on `origin/umi` mid-analysis.**
  So the real upgrade MUST, at execution time: `git fetch origin umi`, rebase
  **whatever the current tip is**, re-verify, and `--force-with-lease` against
  that exact tip. Coordinate a quiet window so no patch lands during cutover.

All analysis below is against the current 25-commit stack. The 5 logical patches
in `UMI-PATCHES.md` are unchanged; the extra commits are follow-on iterations of
patch 2 (widget home) + new widget/admin features, almost all net-new files.

## Scale of the upstream jump

`git diff --shortstat v4.14.2 v4.16.0` → **1930 files, +94 305 / −11 373**,
concentrated in v4.15.1→v4.16.0 (1768 files). Large, but almost none overlaps
the files UMI touches. **Ruby `3.4.4` and Node `24.13.0` are unchanged** — no
toolchain migration. UMI touches **no gem** (`Gemfile.lock` untouched by UMI).

## Chosen approach: direct rebase `--onto v4.16.0`, single hop

```
git rebase --onto v4.16.0 v4.14.2 umi
```

**Rejected — stepwise** (v4.15.0 → v4.15.1 → v4.16.0). Stepwise only helps when a
direct rebase yields a large, hard-to-attribute conflict pile. The trial direct
rebase of all 24 commits produced **zero conflicts**, so stepwise adds two extra
verify/push cycles for no benefit.

### Trial-rebase evidence (full 24-commit stack)

`git rebase --onto v4.16.0 v4.14.2 umi-upgrade-v4-16` (from the current
`origin/umi`) **replayed all 25 commits with zero conflicts** (re-verified after
the mid-session push). Verified on-branch: 25 commits over the v4.16.0 base commit
(`00a50dd7`), history **linear (no merge commits)**, every commit `UMI:`-prefixed,
v4.16.0 is an ancestor.

Only in-place **core edits** can conflict (the other files are net-new: `umi/`
overlay, `zz_umi_*` initializers, `lib/tasks/umi_*`, docs, specs). Of the core
files UMI edits, six were also touched upstream in the window and **auto-merged
cleanly** (3-way, non-overlapping):

| Auto-merged file | note |
|---|---|
| `app/javascript/dashboard/helper/voice.js` | verified: upstream's new `RINGING` guard sits *before* UMI's `UMI_EXTERNAL_SOFTPHONE` return — suppression still fires |
| `app/javascript/dashboard/i18n/locale/en/conversation.json` | key merge |
| `app/javascript/widget/api/endPoints.js` | non-overlapping |
| `app/javascript/widget/assets/scss/woot.scss` | non-overlapping |
| `app/javascript/widget/i18n/locale/en.json` / `th.json` | key merge (note: `th.json` is a non-en locale UMI edits — outside the usual en-only rule) |

All other UMI-edited core files (`widget/views/Home.vue`, `config/application.rb`
overlay wiring, `ConversationCallButton.vue`, the widget `Home/*` components +
specs, `ChatHeader.vue`, `ArticleContainer.vue`, articles store, `lint_pr.yml`)
were **untouched upstream** → applied verbatim.

## Per-patch "still applies / still needed" re-check

Verified against the `v4.16.0` tree — **anchors AND the reopened method bodies**
(the review checked body-drift, not just the anchor). All survive; nothing was
made redundant by upstream:

| Patch | v4.16.0 finding | Verdict |
|---|---|---|
| 1. Facebook Graph v21 + HUMAN_AGENT | `facebook-messenger (2.0.1)` unchanged; `SendOnFacebookService` incl. `merge_human_agent_tag` **byte-identical**; `ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT` still consumed | Keep — needed + clean |
| 2. Widget home composer + links (+8 follow-on commits) | `Home.vue` + widget components untouched upstream | Keep — clean |
| 3. Help Center → Shopify blog sync | `REQUIRED_SCOPES` + `ChatwootMarkdownRenderer#render_article` **byte-identical**; `shopify_api (14.8.0)` unchanged; `Article` fields/enum intact | Keep — see residual risk #3 (order drift) |
| 4. Voice (Twilio → SIP) | `Channel::TwilioSms`, `calls` table columns, enterprise `contacts/:id/call` route **byte-identical**; boots | **Keep, but remove-when partially triggered** — see residual risk #1 |
| 5. Email: read a Gmail label | `build_imap_client` (`imap.select('INBOX')`) + `update_channel_provider_config` **byte-identical** | Keep — clean |

## Residual risk (re-ranked per failure-modes review — a clean rebase proves *merge*, not *runtime*)

1. **Voice × upstream's new native voice (MED-HIGH).** v4.16.0 adds an
   enterprise `GET /api/v1/accounts/:id/calls` endpoint (`CallFinder#perform` →
   `@current_account.calls`) + `set_inbound_calls` + `Channel::TwilioSms#inbound_calls_enabled?`.
   UMI's `zz_umi_voice.rb` **repoints `account/conversation/inbox has_many :calls`
   and `message has_one :call` to `Umi::Call`** (same `calls` table). The `/calls`
   route is `if ChatwootApp.enterprise?`-gated and UMI **is** an enterprise build,
   so it is mounted; hitting it returns `Umi::Call` rows and could 500 if the
   calls serializer calls a method `Umi::Call` lacks. No method-name collision
   (UMI channel methods are `umi_`-prefixed). **Must smoke-test in enterprise mode
   before deploy.** Strategically: the patch's remove-when ("voice ships upstream
   unlocked") is now partially triggered — plan to reconcile/retire it.
2. **Frontend build (MED).** v4.15.1→v4.16.0 = 1768 files; the widget/dashboard
   build may have shifted even where the specific `.vue` files were untouched, and
   6 files auto-merged. A full `pnpm install` + production build + the widget
   specs must pass.
3. **Shopify article-order drift (LOW).** v4.16.0's `Article.update_positions`
   re-spaces via `update_column(:position)` (skips `after_commit`), so UMI's
   `umi_enqueue_help_center_sync` won't fire on the final re-spaced value →
   storefront ordering can lag the portal after drag-reorder. Freshness gap, not
   a crash. (Flip side positive: `increment_view_count`'s `update_column` avoids a
   per-view sync storm.)
4. **App boot (LOW).** All reopened constants/methods confirmed present; boot must
   still be run (single `rails runner` won't exercise the `to_prepare` reload or
   the Sidekiq-concurrency `ShopifyAPI::Context.setup` loader race — known, guarded).
5. **voice.js suppression untested (LOW).** Correct today, but no test pins it;
   the next upstream reshuffle could silently re-enable the in-browser widget.

## Verification plan (run on `umi-upgrade-v4-16`; all must pass before the sign-off gate)

1. **Structural / golden-rule gate** (cheap, run first):
   `git rev-list --merges v4.16.0..HEAD` empty · `git rev-list --count v4.16.0..HEAD`
   equals the count on `origin/umi` over v4.14.2 (25 as of this writing) ·
   `git merge-base --is-ancestor v4.16.0 HEAD` · every subject `^UMI:`.
2. **Boot (enterprise mode)** — `bundle install`; `bundle exec rails runner 'puts "boot ok"'`
   (loads all `zz_umi_*`; must not raise). Confirm overlay autoloads
   (`Umi::Shopify::HelpCenterSyncService`, `Umi::Voice`, `Umi::Call`).
3. **UMI specs** — `bundle exec rspec spec/umi spec/services/umi` (voice + help-center). Green.
4. **Upstream-regression guard for every patched surface** (expanded per review —
   the prepends must not break upstream contracts):
   `bundle exec rspec spec/services/facebook/send_on_facebook_service_spec.rb spec/services/imap spec/models/article_spec.rb` +
   the enterprise calls spec if present (`spec/enterprise/.../calls*`).
5. **Voice × /calls overlap** — with the app booted in enterprise mode, exercise
   `GET /api/v1/accounts/:id/calls` (or its request spec) and confirm it does not
   500 against `Umi::Call` rows. (Directly targets residual risk #1.)
6. **Frontend** — `pnpm install`; `pnpm test app/javascript/widget/components/pageComponents/Home`
   (+ the articles store spec); a full production build completes without error.
7. **Lint** — `bundle exec rubocop umi config/initializers/zz_umi_*`; `pnpm eslint` on UMI-touched JS/Vue.
8. **Migration review (gate, not an open item)** — 21 new migrations in the window
   (all inspected: concurrent index adds via `disable_ddl_transaction!` + `algorithm: :concurrently`;
   small `find_each` backfills on UMI's tiny account; a new `provider_config` jsonb column on
   `channel_twilio_sms`). Run `db:migrate` on a prod-shaped DB copy and confirm no long locks
   before any deploy.

Any red → fix on this branch, re-run. Never proceed to the shared branch on a red gate.

### Verification results (run 2026-07-21 on `umi-upgrade-v4-16` @ v4.16.0)

- **Structural gate:** ✅ 25 commits, 0 merges, v4.16.0 ancestor, all `UMI:`-prefixed.
- **Deps:** ✅ `bundle install` (376 gems), `pnpm install` — both clean, no lock conflicts.
- **Boot (test env):** ✅ app boots; all `zz_umi_*` load; overlay autoloads
  (`Umi::Voice`, `Umi::Call`→`calls`, `Umi::Shopify::HelpCenterSyncService`);
  Shopify `REQUIRED_SCOPES` shows the +4 content scopes; `Message`/`Account`
  `:call(s)` reflect `Umi::Call`. Facebook `base_uri` stays `v3.2` in test — correct
  (patch guards `next if Rails.env.test?`; repins to v21.0 elsewhere).
- **UMI specs:** ✅ `spec/umi spec/services/umi` — **65 examples, 0 failures**.
- **Upstream-regression sweep:** `send_on_facebook`, `spec/services/imap`,
  `article_spec`, `call_finder_spec` all ✅. **2 failures** in
  `spec/enterprise/controllers/api/v1/accounts/calls_controller_spec.rb` — the new
  `GET /calls` index 500s because the repointed `account.calls` returns `Umi::Call`,
  which lacks `direction_label` (rendered by the enterprise calls serializer). This
  is **residual risk #1, now confirmed and pinpointed to one missing method.** The
  endpoint is enterprise-gated but *not* license/feature-gated, yet **no UI in the
  fork or upstream v4.16.0 calls it** — so the 500 is latent (hand-hit only).
  → **Fix:** add `direction_label` to `Umi::Call` (1-method compat shim, greens both
  specs, closes the latent 500) as a new focused patch; file a follow-up for full
  `Umi::Call` ↔ upstream native `Call` reconciliation (the voice patch's remove-when
  is now firing). UMI's own voice stack (its `/umi/voice/*` webhooks + click-to-call
  override) is unaffected by the repoint.
- **Widget specs (vitest):** `UmiHomeComposer` ✅, `articles` store ✅, `Home` ✅;
  **1 failure** in `UmiInboxLinks.spec.js` (expects 4 links, renders 5). **Pre-existing
  UMI test debt, NOT upgrade-induced** — the "add Call channel" commit (`a427c0a8`)
  added a 5th link without updating the spec; both files are byte-identical on
  `origin/umi` and untouched by upstream. → Fix the stale assertion (or fold into the
  Call-channel commit's intent) independently of the upgrade.
- **Production build:** ✅ `RAILS_ENV=production rake assets:precompile` → vite
  `✓ built in 34.98s`, exit 0, artifacts in `public/vite`. (The huge v4.16 frontend
  churn compiles clean with the UMI widget/dashboard edits in place.)
- **Rubocop:** ✅ 31 files (all `umi/` + 5 `zz_umi_*` initializers), no offenses.

**Net: the only upgrade-induced failure was the `direction_label` gap (2 enterprise
calls specs); everything else green or pre-existing.**

### Post-verification fixes applied (both red→green)

- **`Umi::Call#direction_label`** (`umi/app/models/call.rb`) — mirrors upstream
  `Call#direction_label` (`DISPLAY_DIRECTION` map) so the native `/calls` serializer
  renders the repointed association. `calls_controller_spec`: 2 failures → **3
  examples, 0 failures.** Closes the latent 500.
- **`UmiInboxLinks.spec.js`** — asserts the 5 links the component renders (the Call
  quick-link was added without updating the spec). 1 failure → **3 passed.**

**Follow-up (filed as open item):** reconcile `Umi::Call` with upstream's now-native
`Call` model (interface gaps beyond `direction_label`: `from/to_number`, `ringing?`,
`default_conference_sid`, conference scopes; `STATUSES` divergence `missed` vs
`rejected`). Upstream v4.16 shipping native voice means patch 4's *remove-when* is now
firing — the voice patch should be reworked to extend the native `Call`, or retired,
in a dedicated spec. Not required for this upgrade (no UI calls the endpoint).

## Rollout (each irreversible action gated on explicit user sign-off)

1. ✅ Trial rebase on `umi-upgrade-v4-16` (done — 24 commits, zero conflicts).
2. Run the full verification plan; report results.
3. **[GATE 1 — user approval to publish the branch].**
4. **Re-fetch, re-rebase the current tip, re-verify — then capture a backup and
   push the *verified bytes*.** Because the branch is live, do this at cutover:
   ```
   git fetch origin umi                                      # TIP = current origin/umi
   git rebase --onto v4.16.0 v4.14.2 <local-copy-of-TIP>     # replay onto v4.16.0
   # …re-run the verification plan on the result → VERIFIED sha…
   git push origin <TIP>:refs/tags/umi-pre-v4.16-rebase      # immutable pre-rebase anchor
   git branch -f umi <VERIFIED>
   git push origin umi --force-with-lease=umi:<TIP>          # fails if anyone pushed since
   ```
   `--force-with-lease=umi:<TIP>` aborts if the shared branch moved again since the
   fetch — the guard against the exact race we already hit this session. Push the
   verified artifact; don't re-derive it after verifying.
5. **Doc-hygiene** — bump every `v4.14.2` "sits on" reference to `v4.16.0`:
   `UMI-PATCHES.md` (l.3, l.58 upstream-value note), `FORK.md` (l.22/39/51),
   `AGENTS.md` l.122 (**= `CLAUDE.md`**, a symlink — one edit covers both),
   `UMI-SHOPIFY-HELP-CENTER-SPEC.md` (l.25/120), `docs/GO_LIVE_RUNBOOK.md` (l.9).
6. `git tag umi-v4.16.0 && git push origin umi-v4.16.0` → GHCR image build.
7. **Staging** — pull `ghcr.io/shumkov/chatwoot:umi-v4.16.0` on staging (or VPS with a
   temp `chatwoot_version`); run the `FORK.md` smoke checklist (FB reply, widget 200,
   `logs | grep -i error` clean) **+ the /calls enterprise check**.
8. **[GATE 2 — user approval to deploy to prod]**, gated on: staging smoke green
   **and** migration review (step 8 above) complete.
9. **Prod** — `pg_dump` first; bump `chatwoot_version` to `umi-v4.16.0`;
   `ansible-playbook site.yml --tags chatwoot`; smoke.

### Rollback

- **Shared-branch force-push:** undo with the immutable `umi-pre-v4.16-rebase`
  tag captured at step 4 (= the true pre-rebase tip). The `umi-v4.14.2` image tag /
  `1002b6c7` are ~25 commits behind — **not** valid rollback anchors.
- **Prod:** the old image `ghcr.io/shumkov/chatwoot:umi-v4.14.2` is immutable —
  revert `chatwoot_version` and redeploy. Restore the pre-deploy `pg_dump` only if
  a v4.16 migration proves incompatible (migrations are additive per step 8, so a
  code-only revert should suffice).
</content>
