# Handoff — Meta attribution work, 2026-08-11

Branch `busness-profile`, 5 commits on top of `a1e8bc177`. **Nothing is deployed
to production yet.** Written for a fresh agent picking this up.

## Commits

| SHA | What |
|---|---|
| `56ab38626` | Close B3 (outbound message healing) as will-not-build + post-mortem |
| `e806df47f` | Pin the Instagram send URL v11.0→v21.0; remove the HUMAN_AGENT no-op |
| `a45230465` | Measure the order-attribution premises — three of four failed |
| `a9e53e305` | Verify the ad-referral payload against production before building |
| `505d3c65c` | **Capture Meta ad attribution on inbound FB/IG messages** (patch 20) |

## The one feature that shipped

`umi/app/builders/fbig_ad_attribution.rb` + `config/initializers/zz_umi_fbig_ad_attribution.rb`
+ `db/migrate/20260811000000_create_umi_meta_ad_attribute_definitions.rb`.

Stores Meta's ad `referral` on `message.content_attributes[:referral]` and
promotes `ad_id` / `ref` / `ads_context_data.ad_title` to conversation custom
attributes. Erasure counterpart `purge_for` strips both layers from
`shopify_compliance.rb#anonymize_contact`.

Full rationale in `UMI-PATCHES.md` §20 and
`docs/UMI-FBIG-AD-ATTRIBUTION-SPEC-R4.md`. The four load-bearing details are in
the registry — read them before touching this.

**Verification state:** 9 new examples pass; red-green proven by reverting the
nesting (4 fail). 47 existing FB/IG builder examples and 38 webhook examples
still pass. RuboCop clean.

## Deploy — NOT DONE, and it has a trap

Migrations **do not auto-run on container boot** on this deployment. The app
will boot fine and serve 200s on the old schema, so a deploy that skips the
migration leaves the three `CustomAttributeDefinition` rows absent and the
promotion silently useless.

1. Build/push the image, resolve the new digest (the compose file pins by
   **digest**, so `docker compose pull` alone is a no-op — see the prod-deploy
   notes).
2. `rails db:migrate` manually, then restart rails + sidekiq.
3. Watch for `[UMI-FBIG] stage=referral_promoted` and `stage=referral_absent`.

## The open question this deploy answers

Instagram delivers referrals **without** `messaging_referrals` subscribed —
measured on the live page, which carries six fields and not that one. Meta's
docs claim it is required; for Instagram it is not.

**Facebook is unverified.** After deploy: if Messenger ad conversations log
`referral_absent` while Instagram ones log `referral_promoted`, the missing
subscription is the difference. Adding it is delicate — `POST
/{page}/subscribed_apps` **replaces** the field set, so read the live set first,
and never use `channel.subscribe` (it rescues `StandardError`, logs at `debug`
and returns `true`, so a failure looks like success).

## Three claims that were measured and failed — do not rebuild these

- **B3, outbound message healing.** The quick-reply menu agents can't see is
  button metadata: absent from Meta's message edge *and* unhandled by
  Chatwoot's builders. Instagram has no outbound gap at all (71 page-sent human
  messages present, 0 missing). And a healed outbound echo satisfies
  `human_response?`, which nulls `waiting_since` — dropping dead ad threads out
  of the Unattended folder, the opposite of the intent. Post-mortem:
  `docs/UMI-FBIG-OUTBOUND-HEAL-SPEC.md` r2.
- **D12, draft-order invoice tokens.** Verified on n=1 and did not generalise:
  1 of 77 orders carries a token in `landing_site`, matching 0 of the 14 tokens
  agents actually pasted. The correct key is the DraftOrder's own `invoice_url`,
  but `GET /draft_orders` needs merchant approval for `read_draft_orders`.
- **D11, agent contact-linking 422.** Not a defect. The error is rescued and
  readable, and contact merge is wired end to end — merge is the correct
  operation for linking a Meta contact to a Shopify one.

## What is worth doing next

1. **D16** — cheapest remaining win. 26 of 77 Shopify orders already carry
   `note_attributes` with real Meta UTM data (`utm_source: "ig"`,
   `utm_id: "120252251820030415"`-style campaign ids), and all 29 web orders
   have full identity. That is 44.6% of revenue already attributable with no
   capture work and no new API scopes. Nobody reads it.
2. **D6** — port the five Meta Business Suite lead automations. Needs its own
   spec. Known blocker: Chatwoot has **no time-based automation trigger**, and
   two of the five are purely time-based (7-day inactivity → Lost, 12h →
   reminder). Options are SLA policies or a scheduled job shaped like the
   profile refresher. Drop Booked/Ordered rather than port them — they fire on
   orders created inside Meta, which never happens since UMI sells via Shopify.
3. **D17** — the hard half. 37 of 77 orders (~44% of revenue) come from an
   unidentified app `source_name: "325329387521"` with email 4/37, phone 4/37,
   customer 8/37, no `note_attributes`, no `landing_site`. Nothing to join on;
   needs a workflow change at order-creation time, not code.

## Blocked on the human, not on code

- A `ref` string set on the recruitment ads (separates hiring from product
  traffic deterministically; currently absent from every ad).
- Shopify `read_draft_orders` merchant approval.
- Identifying app `325329387521`.
- Events Manager access for the draft-order double-count audit — the page token
  gets `(#100) Missing Permission`; that read needs `ads_management` on a user
  token.

## House rules that bit during this session

- Commit with `dangerouslyDisableSandbox: true`; never disable GPG signing.
- Production reads are approved and encouraged; verify premises there before
  building on them. Three of four premises this session failed that test.
- `Message` has `default_scope { order(created_at: :asc) }` — it has produced
  wrong conclusions twice. Use `.reorder`.
- `jsonb_set` cannot create intermediate objects; it was a silent production
  no-op once already.
- `ApplicationRecord` caps `:string` at 255 while Meta CDN URLs run 350–600.
