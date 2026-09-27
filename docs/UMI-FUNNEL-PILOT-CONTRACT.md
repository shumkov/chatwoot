# First UMI messaging campaign — operating contract

2026-09-27. Based on the user-approved funnel direction and the user's latest
priority: run a useful campaign first; the full Shumabit assistant must not delay it.

Status: preparation in progress; independent simplicity and feasibility/domain
reviews found no must-fixes. These reviews assess the contract and evidence
bounds, not live delivery or campaign performance. No campaign, budget, audience, customer message,
provider test event or production configuration has been changed. Findings are in
[the live inventory](UMI-FUNNEL-INTEGRATION-INVENTORY.md). This document narrows
launch sequencing; the [broader funnel plan](/Users/ivanshumkov/Projects/shumkov/chatwoot.crm/docs/plans/2026-09-27-1325-feat-funnel-messaging-integration-plan.md)
still governs later automated qualification, paid facts, delivery and lifecycle work.

## First usable outcome

A person clicks the approved messaging ad, their inquiry reaches Chatwoot, the
operator can answer and classify it, and the team can distinguish a useful
conversation, a reservation and a confirmed paid sale in the pilot review.

The first campaign can use the existing conversation-optimization setup while
qualification and paid outcomes are recorded manually. It must not be described
as a qualified-lead or purchase-optimized campaign until that goal is verified
and selected in the live account. Automatic Meta feedback is the next outcome,
not a prerequisite for opening the sales inbox.

## Reuse and limits

| Part | Pilot choice / current evidence |
|---|---|
| Ad account | UMI Ads, `act_521070490831440`, THB, Asia/Bangkok |
| Destinations | Existing FB/IG configuration targets Page `516819784857962`; Chatwoot account 1 inbox 2 handles it |
| Campaign | Existing travel/product messaging campaigns are paused. They are candidates to inspect, not approved creative or spend |
| First feedback integration | Messenger is the recommended first technical slice: Page-linked dataset `1540380063308828` and `page_events` are present |
| Instagram | Inbound DMs remain in scope; conversion feedback through the inspected token is unavailable until the app's `instagram_manage_events` grant is resolved |
| Staff workspace | Existing Chatwoot inbox, labels and Shopify sidebar; no bot takeover or new permissions system |
| Classification | Human judgment using Linh's buying-intent definition; Shumabit may assist later |
| Payment | Shopify payment facts; final kept-item order for TBYB; unpaid pickup/reservation is not a sale |
| Customer segments | Keep current Klaviyo flows intact while paid-only buyer segments are prepared separately |
| Reporting | One bounded pilot register and Friday review; no dashboard build required |

Choosing Messenger for the first feedback adapter does not silently change the
ad destination. Marketing must confirm the actual campaign destination and goal.
The missing Instagram permission is a Meta app requirement, not a request to
build an internal permission system.

## Sales handling with the current labels

1. Reply to the inquiry and establish which item or service the person needs.
   Check current Shopify product details and the current FAQ before quoting
   availability, fit, price, shipping, returns or discounts.
2. Keep `lead-new` while the conversation has not been assessed. Mark
   `lead-qualified` when there is a concrete buying step (fitting, pickup,
   reservation, order link) or a substantive product consultation indicating
   purchase consideration. Remove the previous current `lead-*` status when
   choosing another. Keep overlapping `intent-*` and `support-*` topics.
3. A hello, phone number alone, support/refund request or raw message count does
   not qualify a sale. Uncertainty stays unassessed. Do not classify people by
   profile appearance, language difficulty or unanswered-message count.
4. Before supplying a checkout link, collect the actual order email in the
   normal sales conversation and put it on the contact; avoid duplicate contacts.
   Existing attribution verifies identity and must not be weakened. Matching
   names or an inferred social identity is insufficient.
5. For an unpaid fitting/pickup order, record its Shopify order reference and
   reservation state; do not apply `lead-converted` yet. After the final basket
   and payment are confirmed in Shopify, the operator can mark it converted.
6. Record cancellation/no-show/no-keep separately. It does not erase the earlier
   fact that the inquiry was qualified. A refund is a separate adjustment.
7. Record qualification evidence and outcome in the pilot register. Current
   labels help operate the inbox; toggling a label does not dispatch an event
   to Meta or Klaviyo.

The register needs one row per conversation for the pilot and one linked row
per order when there are multiple orders. Keep it in the team's private working
space, not in git. Required fields: conversation reference, first inquiry time,
actual channel, ad ID if evidenced (otherwise unknown), assessed/qualified time
and brief reason, order reference, reservation state, paid time and amount,
currency, refunds, and attribution confidence. Use order references instead of
copying customer email, phone or message text. Count each paid order once.

## Draft replies for staff review

These are human-selected drafts. They are not installed as automatic replies
and introduce no new offer or policy.

| Shortcut | Draft |
|---|---|
| `umi-help` | Hi! Which piece caught your eye? Send us its photo or link, and we can help with sizing, colours and styling. |
| `umi-size` | Happy to help with sizing. Which piece are you considering, and what size do you usually wear? If you are comfortable sharing your measurements, we can compare them with the garment's size guide. |
| `umi-next-step` | Would you like help choosing a size, arranging a fitting, or placing an order? |
| `umi-order-email` | Which email address will you use for your order? This helps us connect the order with our conversation and follow up on your request. |
| `umi-reservation` | Your reservation is not a paid purchase. We will confirm the arrangements and the final items before collecting payment. |

Prepare Thai versions and offer-specific replies with the operator before
installation. Do not improvise discount, stock or delivery promises from this
pack. Existing FAQ/product sources remain authoritative.

## Small prelaunch check

Use an agreed staff test identity and the exact proposed ad preview. Record
results against the real destination, not a synthetic webhook alone.

1. Click the ad preview, send a staff test inquiry and confirm it reaches the
   expected Chatwoot inbox. Check the message's referral and correct platform.
   A preview that omits ad referral does not prove production attribution;
   explicitly leave that check pending for the first real campaign conversation.
2. Reply from Chatwoot and confirm receipt in the staff test account. Check
   Meta's applicable reply window in the live UI. Assign responsibility for ad
   comments separately; the DM inbox is not proof of comment coverage.
3. Run one controlled normal-cart checkout from a new Chatwoot order link,
   using the same test identity. Verify the URL has `umi_cw`, the order has
   private `__cw`, and Chatwoot records verified attribution. This step needs a
   specifically arranged test order; no order has been created by this work.
   Express/draft/POS paths may be unlinked; report them separately.
4. Confirm how staff records fitting/pickup payment. Compare reservation-time
   events with the final payment and kept-item value. The native Meta Purchase
   behavior for an unpaid checkout remains unverified; do not add a second
   purchase sender while overlap is unknown.
5. Confirm staffed hours and the campaign schedule. Stored inbox hours are
   09:00–21:00 Bangkok but are disabled, so they do not establish real coverage.
   Linh's target is a first human reply within five business minutes, response
   rate above 95%, and qualification within 24 hours.

Tests that send messages or create orders are prepared here, not executed.
No response SLA or full attribution coverage is claimed from configuration reads.

## Launch and feedback are separate milestones

**Launch readiness:** approved offer/creative, audience, destination, goal,
schedule, daily/total budget, assigned operator/comment coverage, reviewed replies,
verified inbound/outbound test and an agreed way to record outcomes. If automatic
order linking is not yet proven, a staff-confirmed order reference and clearly
marked manual attribution can support the first campaign's internal review.
It cannot generate automatic Meta purchase claims.

**Feedback readiness:** captured evidence with original occurrence time and
channel identity, event ownership/deduplication, reviewed payload, approved provider
test and Events Manager confirmation. Messenger is the first supported candidate;
Instagram permission and purchase-goal availability are separate open checks.
No event is sent just to manufacture goal eligibility. Keep website purchases
with their existing sender; chat-assisted is not automatically messaging-origin.

**Later automation:** reviewed qualification records, confirmed paid-order data,
identified-customer Klaviyo events/segments and eligible Meta feedback. The earlier
U2 provenance patch is locally verified but still undeployed. It must be included
before automatic classifiers treat healed incoming messages as fresh evidence.
The private-note Shumabit bridge is optional for this milestone.

## Pilot review

Record campaign start/end, report as-of time and spend interval. Each Friday,
review conversation volume and cost, assessed/qualified counts, reservations,
paid orders/value, refunds and unknown attribution. Show unassessed conversations
and pending fittings separately. Use the same follow-up horizon when comparing
campaign cohorts; do not rank a three-day-old cohort against a mature one.
Missing spend means unknown cost/ROAS. Shopify sales totals are not
Meta-attributed revenue. No performance benchmark or improvement is promised.

## Inputs still needed for activation

- Offer/creative: user selection requested; existing travel/product campaign
  versus TBYB in Phuket, or a separately supplied offer.
- Staff coverage/comment owner, pilot dates and budget: not yet supplied.
- Actual campaign performance goal and destination: inspect and confirm before
  activation; current paused examples establish a starting point only.

These choices do not block local work on the missing integrations. They do block
claiming the campaign is ready for activation or spending money on an assumed offer.
