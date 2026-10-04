# Stage-one acceptance checkpoint — 4 October 2026

This is a production evidence checkpoint, not a new implementation plan or a
declaration that messaging Purchase optimization is ready. The contract remains
[the stage-one spec](UMI-FUNNEL-STAGE-ONE-SPEC.md). Release 26 is the deployed
application; no application, campaign or financial state was changed by this check.

## Outcome deliveries: prerequisites, not failed sends

Production readback at 09:52–09:54 UTC found two pending Klaviyo deliveries,
both with zero attempts:

- One verified payment has no customer identity. A fresh Shopify read identifies
  an anonymous partner-location sale with no customer, email or phone. It is not
  evidence of a messaging purchase. Keep `identity_unlinked`; do not assign a
  conversation or manufacture a profile to clear the queue.
- One genuinely qualified Instagram conversation has no email, phone, Shopify
  customer or Klaviyo profile. Its complete retained history contains product
  and size discussion, without an exact identity. Keep `profile_unbound` until
  the customer supplies an identifier during normal service.

Existing resolution and delivery jobs resume when their supported prerequisites
become available. Do not reset attempts or replay terminal deliveries.
The 09:19 UTC provider inventory contained no UMI custom metrics and no Recent
conversation intent segment. Its creation still waits for the first genuine
qualified event's provider readback; neither a synthetic event nor native Placed
Order substitutes for that acceptance case.

A separate newly observed partner order has Shopify `financial_status=paid`, but
no transactions and a positive outstanding balance equal to its total. The
financial snapshot correctly records `needs_review/payment_status_mismatch`
and creates no paid event. Resolve the payment evidence at its source; do not
weaken the transaction-based buyer definition or invent a capture.

## Meta

Freshly reloaded App Review on 4 October confirms the submitted
`instagram_manage_events` request is **Approved**. The initial, already-open
browser page was stale and still displayed review in progress before reload.
Permission approval is therefore not the remaining activation blocker.

There are still no verified order-to-conversation attributions. The four pending
Meta paid-event deliveries have zero attempts; three predate the collection
boundary, and the fourth is the anonymous partner sale above. No current record
is an eligible paid-in-chat acceptance candidate. Purchase channels remain empty.

Keep the [release 25 acceptance requirements](UMI-META-RELEASE25-ACCEPTANCE.md):
one genuine eligible payment, verified conversation link and private settlement
confirmation; provider processing/diagnostics for that channel; then controlled
activation and automatic readback. API configuration validation is not launch,
identity matching or advertising-performance evidence.

Native website Purchase remains owned by Shopify. Shopify's current
[data-sharing documentation](https://help.shopify.com/en/manual/promoting-marketing/analyze-marketing/meta-data-sharing)
describes the browser Purchase at checkout completion/thank-you-page viewing and
the server Purchase under Enhanced/Maximum sharing. It does not establish a
paid-only guarantee for UMI's manual-payment/TBYB flow. The earlier unpaid-checkout
correlation remains a risk, not an identified per-order native payload.
Do not duplicate it with a Chatwoot website Purchase or alter active ad tracking
without a reviewed replacement and an observed paid/unpaid acceptance pair.

Fresh Events Manager inspection showed Purchase activity last received five
days ago for the displayed 6 September–3 October range. Its Sampled activities
view covers only the last 24 hours and contained no rows. This UI read supplies
no individual TBYB payload or messaging Purchase receipt; the aggregate website
warning about low CAPI coverage does not identify the payment timing either.

## Public advertising comments

At 09:57–09:58 UTC, Graph v23 enumerated five ACTIVE ads plus all seven ads returned
by the ad-level last-seven-days impressions query: seven distinct ads in total.
Their creatives yielded seven Facebook stories and six Instagram media IDs.
All 13 available comment edges returned complete empty pages. The remaining
paused ad has no returned Instagram media ID; its Instagram coverage is unknown.

This check is broader than the earlier two-ad sample, but is not a historical
account-wide census, a test of real replies, or a recurring comment collector.
No public comment or message was sent. Absence on these edges does not prove
absence across dynamic variants, missing media, deleted comments or other posts.

Mai remains the operator responsible for public comments in Meta Business Suite.
The existing Friday renderer explicitly says ad comments are incomplete; the
Chatwoot operational source reports `ad_comments_not_verified`. Keep both limits.
Do not count DM response measurements as comment SLA. A future collector still
needs the narrow adapter contract required by the stage-one spec.

## What remains before full acceptance

1. Genuine messaging payment and channel-specific Meta processing acceptance.
2. Native website paid/unpaid timing and sender-ownership acceptance.
3. Genuine Klaviyo custom-event readback and Recent conversation intent segment.
4. Operator comment coverage in Business Suite; actual reply timing/API coverage
   remains unverified. The manual fallback is documented, not proof of execution.
5. Observe the next natural Friday quality report on 9 October. The installed
   job and pilot are not a receipt for that future scheduled run.

The latest reminder readback already contains five accepted internal deliveries;
the earlier empty-outbox limitation is superseded for reminder delivery only.
Historical enrichment is already applied; remaining ambiguous identities and
financial cases stay exceptions rather than a reason to rerun the archive.

Private receipts: `Downloads/umi-crm-stage-one-closure-2026-10-04` on the operator
Mac and `/home/shumabit/.local/state/crm-stage-one-closure` on the VPS. Only aggregate
results belong here; customer identities, conversations, order evidence and
credentials must not be copied into this repository.
