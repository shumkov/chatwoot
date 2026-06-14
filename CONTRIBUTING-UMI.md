# Contributing to the UMI Chatwoot fork

This fork carries UMI's patches on top of an upstream **stable release tag**.
Read `FORK.md` (branch model + build/deploy) and `UMI-PATCHES.md` (patch registry)
first. This doc is the step-by-step recipe.

## Golden rules

1. **Prefer an idempotent initializer over editing core files.**
   A `config/initializers/zz_umi_*.rb` that monkey-patches/reopens classes
   survives upstream rebases with **zero conflicts**. Only edit core Chatwoot
   files when an initializer genuinely can't do the job.
2. **One patch = one focused commit**, message prefixed `UMI:`.
3. **Every patch gets a row in `UMI-PATCHES.md`** (what / why / files / remove-when).
   If it has no "remove-when", it's probably a feature that belongs upstream, not a patch.
4. **Never commit secrets.** Config comes from ENV / Chatwoot InstallationConfig,
   not the image.
5. Keep the `umi` branch a **clean linear stack** on top of the base tag — no merge
   commits from upstream (we rebase, see below).

## Add a new patch

```bash
git checkout umi
git pull --ff-only            # or re-create from base, see FORK.md
git checkout -b umi/<short-name>

# Make the change. Prefer:
#   config/initializers/zz_umi_<name>.rb   (idempotent, rebase-safe)

git add -A
git commit -m "UMI: <what it does and why>"
# Add a row to UMI-PATCHES.md describing it, then:
git commit -am "UMI: document <name> in UMI-PATCHES.md"   # or fold into the patch commit

git push -u origin umi/<short-name>
```

Open a PR into `umi`. CI builds a **preview image** tagged with the branch name
(`ghcr.io/shumkov/chatwoot:umi-<short-name>`) — pull it on a staging box (or the
VPS with a temporary `chatwoot_version`) and smoke-test the affected channel
(FB send, IG send, widget) before merging.

## Release an image

```bash
# after merging to umi:
git checkout umi && git pull --ff-only
git tag umi-v<UPSTREAM_TAG>          # e.g. umi-v4.14.2 (matches the base release)
git push origin umi-v<UPSTREAM_TAG>
```
The `umi-v*` tag triggers `.github/workflows/umi-build.yml` →
`ghcr.io/shumkov/chatwoot:umi-v<UPSTREAM_TAG>`. Then bump `chatwoot_version` in
`umi-vps-infra` and deploy (`pg_dump` first).

## Rebase onto a new upstream release

When Chatwoot ships a new stable tag (e.g. `v4.15.0`):

```bash
git fetch upstream --tags
git rebase --onto v4.15.0 <OLD_BASE_TAG> umi    # OLD_BASE_TAG from UMI-PATCHES.md
# resolve conflicts — they only ever touch UMI patch files
# re-check each patch: does it still apply? still needed? (drop if upstream fixed it)
git push origin umi --force-with-lease
# update the "sits on" tag in UMI-PATCHES.md, then tag + build:
git tag umi-v4.15.0 && git push origin umi-v4.15.0
```

`setup-umi-branch.sh` can recreate the stack from scratch on a given base tag if
a rebase gets messy.

## Smoke-test checklist (before any deploy)

- Facebook: reply to a conversation → arrives in Messenger
- Instagram: reply → arrives in IG DM (rides the FB-page channel, `instagram_id`)
- Web widget: `/widget?website_token=…` returns 200 (no Rack::Attack 429)
- App boots clean: `docker compose logs rails | grep -i error`
