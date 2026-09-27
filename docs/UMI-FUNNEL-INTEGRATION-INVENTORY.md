# Messaging campaign readiness — live inventory

Read-only observations on 2026-09-27, initially approximately 18:52 Asia/Bangkok; follow-up findings below.
Primary goal: launch and measure a useful Meta messaging campaign, then improve
its optimization with supported qualification and paid-sale feedback. The
Shumabit private-note bridge is supporting work, not a campaign launch dependency.
No campaign, budget, label, automation, credential or deployed service was changed.

## Confirmed in Meta

- Account `act_521070490831440`, UMI Ads, account status `1`, currency THB,
  timezone Asia/Bangkok.
- A dedicated `effective_status=[ACTIVE]` campaigns query returned zero campaigns
  and no further page. Campaign activation has not been requested or performed.
- Existing engagement campaigns include conversation campaigns from August and
  February. Examples: `120252533075990415`, `120252494607980415`,
  `120252251147010415`. They are paused.
- Existing ad sets use `CONVERSATIONS` optimization and
  `MESSAGING_INSTAGRAM_DIRECT_MESSENGER`; some older configurations also include
  WhatsApp. Page `516819784857962` is the promoted page.
- These configurations establish an existing messaging-campaign path. They do
  not prove current qualified-lead or purchase optimization availability.
- General campaign/ad-set reads covered the first 100 rows and indicated more
  pages. They are examples, not a complete historical inventory. The separate
  active-campaign query above was complete.

## Confirmed in Chatwoot

Read via scoped Rails model metadata on the deployed Rails container:

- Account 1, inbox 2 (`Facebook`), Channel::FacebookPage, page
  `516819784857962`, connected Instagram ID `17841468119523354`.
  This matches the page on the Meta messaging ad sets.
- No inbox has an active bot. Human conversation ownership is intact.
- Existing sales labels: `lead-new`, `lead-qualified`, `lead-converted`,
  `lead-lost`, `lead-unqualified`. Existing intent, support, source and value
  labels are also present; no taxonomy replacement is required to start.
- The only active automation is “Auto: tag new conversations as New Lead” on
  `conversation_created`, with an `add_label` action. Qualification is not
  currently an active native automation.
- Meta custom attribute definitions exist: `meta_ad_id`, `meta_ad_ref`,
  `meta_ad_title`. No `umi_*` custom attribute definition was returned.
- Shopify integration is enabled.
- Seven conversations were created in inbox 2 during the trailing seven days.
  None of the conversations created in that window had `meta_ad_id`. This is
  a bounded observation, not proof of broken attribution or no historical ads.

## Confirmed in Klaviyo / event-source inventory

- Klaviyo API read access works. All 57 returned metrics fit on one page.
- Native Shopify metrics include Placed Order, Ordered Product, Cancelled Order,
  Refunded Order, Fulfilled Order and Fulfilled Partial Order. A `qualified_form`
  metric exists under the Klaviyo integration; its name does not establish
  conversation qualification. No explicitly named paid-order or conversation-
  qualified metric appeared in the name-filtered inspection.
- Flow inventory returned one flow with no further page: Welcome Series (Email),
  ID `Wk3BCi`, live, triggered by Added to List. No flow was changed.
- The ad account's pixels edge returned one pixel, `1540380063308828`, named
  `cherry.cheap's pixel`, last fired 2026-09-26T23:34:07Z, with no further page.
  A pixel name or firing timestamp does not prove messaging-dataset ownership,
  paid-only Purchase semantics or messaging-optimization eligibility.

## Agent integration — supporting work

- Deployed Polygram 0.39.0 declares Orchestra 0.11.0. Shumabit and its tmux owner
  were active during the read-only check.
- Shumabit configurations use `/home/shumabit/shumabit-claude`, multiple existing
  agent definitions and Claude models. The existing Chatwoot API client exists.
- The current rendered `~/credentials/secrets.json` does not contain the
  `skills.entries.chatwoot` token required by that client. Restore its normal
  durable credential entry before relying on this particular client path;
  do not write a temporary token into the periodically rendered file.
- Meta and Klaviyo credential entries exist; Meta read access was verified.
  Klaviyo read access and flow inventory were subsequently verified above;
  event-to-profile semantics and the welcome flow contents remain unverified.
- The existing CLIProxy container is running. Its actual model route into the
  future Chatwoot worker has not been verified; container presence alone is not
  a working integration claim.

## Next work on the campaign path

1. Verify the first ad-to-inbox path and existing referral capture using an
   agreed preview/test, plus the welcome/FAQ response workflow. Keep human
   handling and current labels; do not wait for the private-note assistant.
2. Make qualification and paid outcomes usable for measurement. Qualification
   follows Linh's buying-intent rule. A TBYB or pickup reservation is not paid;
   final kept-item payment is the conversion. Verify existing Shopify/Klaviyo/
   Meta events before adding a second purchase sender.
3. Establish the supported Meta outcome event and available campaign goal for
   this account/channel. Then implement only the missing feedback integration,
   verify it and prepare the campaign for its owner's activation decision.

Unverified: dataset/event-source ownership, current Meta messaging CAPI sender,
qualification/purchase goal availability, Shopify payment-event coverage,
unpaid-reservation Purchase behavior, pilot
creative/offer/budget and activation owner. A conversation-optimized campaign
and an outcome-optimized campaign are separate readiness claims.

## Follow-up inventory — 2026-09-27, 19:48–20:00 Bangkok

### Shopify and attribution

- Using the deployed Chatwoot integration's existing Shopify REST client
  (`2026-01`), the trailing-60-day query (limit 100) returned 46 orders: 45
  currently paid and one voided; none marked test. Source values were `web`
  (11), `shopify_draft_order` (1), and an app source ID (34). Source alone does
  not establish where a purchase happened.
- The sample includes `Pay after your fitting` and `Cash At Store`; one order's
  original/current totals differ. None carries the `__cw` conversation cart
  attribute. Account 1 has zero persisted Shopify order-attribution records.
  These are missing measurement coverage, not proof of zero chat-assisted sales.
- The current shop-scoped webhook API returned no subscriptions. This does
  **not** establish missing app-config subscriptions: the infra repository's
  `shopify/umi-chatwoot/shopify.app.toml` declares `orders/create`. Shopify
  documents app-scoped subscriptions separately from API-listed shop-scoped
  subscriptions. Recent Chatwoot Rails logs contain three `orders/create`
  attribution outcomes, all `unlinked`, within 48 hours: the receiver is being
  called. No paid/refund receiver exists in the inspected UMI code.
- A public GET of `https://umi.store` includes the order-link capture asset,
  `umi_cw` handling and pixel ID `1540380063308828`. This proves the live HTML
  contains the carrier, not that the browser/cart/order path works end to end.
- The initial detailed special-payment comparison failed; a follow-up restricted
  to the current 60-day Shopify order window succeeded for the two matching
  special-payment orders. The first failure's cause was not established.
- The September 12 TBYB order has native Klaviyo Placed Order value ฿7,980 and
  pending financial status. Its current Shopify state is voided with current
  total ฿0; transactions show a pending sale and successful void, no successful
  sale/capture. Thus a placed-order event remains despite no confirmed sale.
- The August 7 Cash At Store order has Klaviyo Placed Order value ฿4,491 and
  pending status. Shopify records a successful ฿4,491 sale on August 25, after
  the reservation. The initial metric's occurrence time is not the paid time.
  These matched examples establish the need for distinct paid-order facts;
  they do not establish what Meta received.

### Klaviyo buyer semantics and active flows

- All 16 segment definitions were read across two pages. Repeat Buyers
  (`Rd9GSk`) uses native Shopify Placed Order count >1; VIP (`SxP4sY`) uses >5.
  Win-Back, Potential Purchasers and Churn Risks also use that metric. These
  rules do not enforce the agreed paid-order criterion.
- Among the latest 100 Placed Order event snapshots, `financial_status` was
  paid in 94, pending in 5 and refunded in 1. There are more historical pages;
  this is a bounded sample, not all-time counts. It directly demonstrates that
  this metric includes orders without confirmed payment at event creation.
- Welcome flow `Wk3BCi` has four live email actions, two delays and a source
  split. Its form-signup branch's three emails require zero Placed Orders;
  keep this useful reservation suppression while introducing paid-only buyer
  segmentation. Do not globally replace every Placed Order filter with Paid.
  The Shopify-source branch has a separate live no-code welcome email. The
  split's descriptive name is stale; the actual branch has a send action.
- No flow or segment was changed, and no individual profile identifiers were
  output or persisted by the inventory.

### n8n and sales handling

- Read the live SQLite database with `mode=ro`; seven workflows were returned.
  Five active: respond.io capture, respond.io Shopify enrichment, Shopify →
  Chatwoot enrichment, Klaviyo → Chatwoot attributes, Chatwoot → Klaviyo events.
  Two inactive WhatsApp collector test workflows remain untouched.
- The inspected workflows have no Meta Graph HTTP destination, qualification
  event or paid-order receiver. The current event pipeline concerns
  WhatsApp/LINE activity; it is not a Messenger/Instagram CAPI bridge.
- Last-seven-day n8n execution status counts: 666 enrichment successes and
  133 Chatwoot → Klaviyo successes. A workflow success can be a deliberate skip;
  these counts do **not** prove any event reached Klaviyo.
- Both Chatwoot account webhooks use public `n8n.umi.store` URLs. They subscribe
  to contact/conversation enrichment and message-created/updated respectively.
  The infra README's later internal-URL examples contradict its correct public
  URL warning and the live configuration; do not copy the internal examples.
- FB/IG inbox 2 has stored 09:00–21:00 Bangkok hours for every day, but
  `working_hours_enabled=false`, no enabled greeting and no out-of-office
  message. Staffing hours must be confirmed; stored hours are not coverage.
- Account 1 has zero canned responses and one macro. A small reviewed response
  pack and explicit comment-monitoring responsibility are launch work, not
  reasons to wait for a general AI assistant.

Primary references refreshed during this follow-up:

- [Klaviyo Shopify data reference](https://help.klaviyo.com/hc/en-us/articles/115005080447)
- [Shopify webhook subscription types](https://shopify.dev/docs/apps/build/webhooks/subscribe)
- [Shopify Meta data sharing](https://help.shopify.com/en/manual/promoting-marketing/analyze-marketing/meta-data-sharing)
- [Meta business-messaging contract, official Markdown](https://developers.facebook.com/documentation/ads-commerce/conversions-api/business-messaging.md)

Meta's standard HTML pages returned 429 during this follow-up; its public official
Markdown documentation was readable. No event POST or dataset creation was made.

### Meta outcome route verified

- Graph `v23.0` GET `/516819784857962/dataset` returned existing dataset
  `1540380063308828`. Its owner is business `497970999394825`, UMI STORE CO., LTD.
  Thus the old pixel name is not evidence of a foreign owner; this is the
  Page-linked UMI dataset, also present in live storefront HTML.
- The existing system-user token's complete permission response includes
  granted `page_events`, `pages_messaging`, `business_management` and
  `whatsapp_business_manage_events`. It does not include
  `instagram_manage_events`.
- GET `/17841468119523354/dataset` returned HTTP 403, Graph code 200, explicitly
  saying the app lacks `instagram_manage_events` on that Instagram account.
  This is a confirmed blocker for that credential's Instagram conversion-event
  route, not for receiving Instagram DMs in Chatwoot.
- Messenger dataset linkage and permission are verified. No test event was
  submitted; accepted delivery, selectable optimization goal and attributable
  outcomes remain unverified. Do not create another dataset to work around this.

### Bounded qualification and link coverage

- Of 187 FB/IG conversations created in the trailing 60 days, current label
  assignments were `lead-new` 177 and `spam` 6. No qualified/converted label was
  present in that cohort. These are current labels, not immutable event counts.
- Among 674 public outgoing/template messages in that period, 25 contain
  `umi.store`, 15 match the existing rewrite URL pattern, and none contain
  `umi_cw=`. Those 25 date from July 30 through August 28; none is from the last
  14 days, and seven are external echoes. The rewrite concern is loaded now.
  This does not establish a current rewriter bug; deployment timing and a fresh
  controlled checkout must be checked before assigning a cause.
- The first exploratory label query used a nonexistent `tags` association and
  failed; the corrected read used the existing `label_list` interface and
  returned the counts above. No application behavior was changed.
