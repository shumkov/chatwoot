# UMI Chatwoot fork — maintenance & build strategy

Fork of [chatwoot/chatwoot](https://github.com/chatwoot/chatwoot) carrying UMI's
patches on top of a pinned upstream **stable release tag**, built into our own
Docker image and deployed via the `umi-vps-infra` Ansible repo.

## Branch model (rebase-on-release)

- Upstream dev branch is `develop`; **stable = release tags** (e.g. `v4.14.2`).
  We pin to tags, never `develop`.
- **`umi`** — our long-lived branch. It is the latest upstream stable tag **plus
  a clean stack of UMI patch commits** (see `UMI-PATCHES.md`) and these specs.
- Remotes:
  - `origin`   → `git@github.com:shumkov/chatwoot.git` (this fork)
  - `upstream` → `https://github.com/chatwoot/chatwoot.git`

## Upstream update flow (rebase our patches onto the new release)

```bash
git fetch upstream --tags
NEW=v4.15.0           # next upstream stable tag
OLD=v4.14.2           # tag the umi branch currently sits on (see UMI-PATCHES.md)
git checkout umi
git rebase --onto "$NEW" "$OLD" umi   # replay UMI patch commits onto $NEW
# resolve conflicts — they only ever touch UMI patch files
git tag "umi-$NEW"
git push origin umi --force-with-lease
git push origin "umi-$NEW"
```

Update the "sits on" tag in `UMI-PATCHES.md` after each rebase. Tagging
`umi-vX.Y.Z` triggers the image build (below).

## Build pipeline

`.github/workflows/umi-build.yml` builds Chatwoot's `docker/Dockerfile` and
pushes to **GHCR** on push to `umi` or a `umi-v*` tag:

- `ghcr.io/shumkov/chatwoot:umi-v4.14.2` (immutable, per release)
- `ghcr.io/shumkov/chatwoot:umi-latest`  (moving)

First time: make the GHCR package **public** (or add a pull secret on the VPS).

## Deploy

In `umi-vps-infra` set the Chatwoot image to our build:

```yaml
# group_vars/all/main.yml
chatwoot_image: "ghcr.io/shumkov/chatwoot"
chatwoot_version: "umi-v4.14.2"
```

Then `ansible-playbook site.yml --tags chatwoot`. Because patches are baked into
the image, the runtime initializer **mount can be removed** from the compose
template once we cut over.

## Upgrade checklist

1. `git fetch upstream --tags`, pick the new stable tag.
2. Rebase `umi` onto it (above). Review each UMI patch still applies / is still needed.
3. Push tag → CI builds `ghcr.io/shumkov/chatwoot:umi-vNEW`.
4. Bump `chatwoot_version` in `umi-vps-infra`, **pg_dump first**, deploy.
5. Smoke-test channels (FB send, IG send, widget) before closing the upgrade.
