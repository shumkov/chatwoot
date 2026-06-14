# UMI patches

The `umi` branch currently sits on upstream **`v4.14.2`**.
Each patch below is a commit on top of that tag. Keep this list in sync on every rebase.

| # | Patch | Files | Why | Remove when |
|---|---|---|---|---|
| 1 | Facebook Graph API v21 + HUMAN_AGENT tag | `config/initializers/zz_umi_facebook_fix.rb` | Bundled `facebook-messenger` gem pins removed Graph API **v3.2** → outbound FB fails; Chatwoot also sends the deprecated **`ACCOUNT_UPDATE`** tag (Meta subcode 1893061). Repins v21.0 + switches to `HUMAN_AGENT`. | Upstream bumps the gem's Graph version AND replaces the ACCOUNT_UPDATE tag. |

## Patch details

### 1. Facebook send fix (`zz_umi_facebook_fix.rb`)
Idempotent initializer (safe even if upstream fixes it): re-pins
`Facebook::Messenger::{Bot,Profile,Subscriptions}` base_uri to
`graph.facebook.com/v21.0/me` and prepends a module on
`Facebook::SendOnFacebookService` swapping the `ACCOUNT_UPDATE` message tag for
`HUMAN_AGENT`. Mirrors the runtime patch previously mounted by `umi-vps-infra`;
baking it into the image lets us drop that mount.

<!-- Add new patches here as commits, newest last. -->

## Notes / candidates (not yet patched)
- Instagram-via-Instagram-Login long-lived token exchange fails for Facebook-Page-linked
  accounts ("Unsupported request"). UMI uses the **Facebook-page IG path** instead
  (`Channel::FacebookPage.instagram_id`), so no patch needed — documented in
  `umi-vps-infra/docs/INFRA_SPEC.md`.
