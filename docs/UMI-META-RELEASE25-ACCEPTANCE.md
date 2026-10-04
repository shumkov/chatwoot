# Meta access and release 25 acceptance

Updated 3 October 2026 Bangkok. Release 25 is deployed and verified.
This records release 25's original acceptance state. The 4 October
[activation decision](UMI-INSTAGRAM-OUTCOME-ACTIVATION-SPEC.md) supersedes waiting
for a first purchase before enabling Instagram delivery. The first genuine
purchase remains a processing/attribution check after activation.

## Confirmed

- Advanced `instagram_manage_events` is granted to UMI Store.
- The dedicated funnel Page credential is active in Rails and Sidekiq. Its v23
  Instagram and Messenger dataset reads both return `1540380063308828`.
  Inbox credentials and Purchase channel flags were preserved.
- The nonmonetary Instagram TestEvent at 17:00:46 UTC on 2 October returned
  HTTP 200, `events_received: 1`, `messages: []`. It used Meta's synthetic
  `ig_sid: "0"`; it is not a customer conversion or identity-matching proof.
- Messenger TestEvent sent through the deployed MetaClient with the rotated
  credential was accepted at 18:05:10 UTC and displayed as **Processed**, Server,
  `business_messaging`, at 01:05:10 Bangkok in Events Manager.
- Two later Instagram TestEvents used the owner's retained IG-01 review sender:
  one with the configured Graph account ID, one with the native `ig_id` shown by
  Meta's test example. Both were API-accepted; neither produced an observed
  matching UI record. The cause remains unresolved. Changing ID representation
  alone did not resolve the observation; identity matching is not yet proven.
- The old `instagram_business_account_id` field was rejected with code
  100/subcode 2804079. Changing the field to `ig_account_id` removed that rejection.
  PR [75](https://github.com/shumkov/chatwoot/pull/75) is merged at `0925af255`;
  signed release tag `umi-v4.16.0-25` points to that commit.
- The regression failed on the old field, then all 53 focused examples passed.
  Full CE CI and both linters passed. Two independent reviews were clean.
  The actual preview image matched the source and passed an isolated Instagram
  and Messenger payload smoke with no network or provider calls. Its workflow
  was cancelled during cache export after image publication; this was not a
  compilation or image-push failure.
- The release-tag build completed successfully. Rails and Sidekiq were verified
  on release 25 at 18:17:30 UTC on 2 October (01:17:30 Bangkok on 3 October),
  using image digest `sha256:83a8fe71718e0fece0e84c4fd980c4fa3acd7bb63ee4fdf0ec596041750ad297`.
  Both containers match the source; health returned HTTP 200. The complete
  environment and source vault were unchanged. Inbox credentials, schema, cron,
  13 sibling containers and eight service owners were preserved. Sidekiq was
  quieted and drained before replacement; the database backup was verified.
  The deployment sent no events. Infrastructure PR
  [116](https://github.com/shumkov/umi-vps-infra/pull/116) records the image pin.
- Production inventory at 17:16:03 UTC found zero old-field payloads, four pending
  Meta delivery records for paid events, zero settlement-confirmed orders and
  zero eligible chat Purchase candidates. This inventory sent no events.
  No existing payload needs rewriting or replaying.

## Instagram-only configuration validation

At 17:52:39 UTC on 2 October, Graph v23 accepted an ad-set configuration in UMI's
actual account: `OUTCOME_ENGAGEMENT` + `INSTAGRAM_DIRECT` +
`MESSAGING_PURCHASE_CONVERSION`. The request explicitly used
`execution_options: ["validate_only"]` and returned HTTP 200, `{"success": true}`.
It used the previously verified UMI company identity for Thailand advertiser and
payer. No object ID was returned; the inspected fields of the existing ad set
were unchanged. No campaign, ad set, budget or advertisement was created or changed.

This extends the earlier combined Messenger/Instagram validation to Instagram
alone. It proves configuration validation, not launch acceptance, UI selectability,
event matching, attribution or advertising performance. The Page credential used
for CAPI is separate from the existing system-user credential used for this
Marketing API check.

Official API contract references: [Meta SDK ad-set fields and execution options](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/adset.py),
[validation-only helper](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/mixins.py),
and [regional identity fields](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/regionalregulationidentities.py).

## Remaining activation evidence

1. Obtain a genuine paid order completed in a messaging conversation, linked to
   that customer and conversation, with the operator's private `/paid-in-chat`
   confirmation. No current order satisfies that evidence chain. Website
   checkout remains Shopify's sender responsibility; in-store or unknown origin
   must not be relabelled as a chat purchase.
2. Verify the eligible Purchase's provider receipt and dataset diagnostics before
   enabling that channel's automatic Purchase export. Matching Instagram
   technical TestEvents have not been observed in Events Manager; API acceptance
   alone does not close this check. Messenger has a processed technical receipt,
   which does not establish Instagram processing. No fabricated payment or
   automatic replay is allowed.
3. Confirm native Shopify/TBYB payment timing and sender ownership; historical
   aggregate diagnostics do not identify a complete per-order native payload.

`UMI_FUNNEL_META_PURCHASE_CHANNELS` remains empty. Linh owns campaign launch and
spend. Renew the Page credential's data access before **31 December 2026,
23:34:46 Bangkok**; `expires_at: 0` does not remove that separate expiry.

## Private evidence

Receipts are in `Downloads/umi-crm-historical-audit-2026-10-02`:
`meta-token-rotation/accepted.json`, `meta-ig-fieldcheck-receipt-20261002.json`,
`meta-instagram-only-goal-validation.json`,
`meta-messenger-technical-receipt-20261002.json`,
`meta-instagram-owner-technical-receipt-20261002.json`,
`meta-instagram-native-id-technical-receipt-20261002.json`,
`meta-test-events-ui-observation-20261002.json`, and
`meta-release25-preparation/{application-verification,readonly-payload-inventory,crm-meta-capi-access-image-verified,umi-v4.16.0-25-image-verified,deployment-accepted}.json`.
No credentials or customer records are included in this document.
