# UMI conversation cohort report

Draft for independent review, 27 September 2026. This supplies the bounded
conversation-cohort portion of U7 for Linh's Friday review. The existing
`umi:funnel:report` remains the operational inventory. No dashboard, provider
request, spend import, campaign mutation, new table or scheduled job is added.

## Research and choice

Google's [cohort exploration documentation](https://support.google.com/analytics/answer/9670133?hl=en)
separates the inclusion criterion from later outcomes, distinguishes cumulative
outcomes from period-specific outcomes, and describes retaining the first
breakdown value. Use that pattern for conversations: first recorded live incoming
message establishes membership and channel/ad; subsequent qualified and paid
events are measured over the same fixed duration for each conversation. This is
an internal conversation cohort, not GA users, unique new customers or Meta's
attributed conversions.

The alternative is to extend the current observed-date operational aggregate.
That is smaller but mixes new conversations with older purchases and unequal
follow-up durations, so it cannot compare campaign cohorts fairly. A warehouse
with historical financial snapshots could answer more questions, but the current
pilot does not require that additional storage or integration.

Shopify's [Refund resource](https://shopify.dev/docs/api/admin-rest/2026-01/resources/refund)
distinguishes returned money transactions from refunded line items. Our current
financial state stores aggregate successful refunds and retained cash, not their
dated sequence. Therefore original paid value and latest known cash are separate
outputs; the report cannot reconstruct refunds within a historical horizon.

## Existing sources and limits

- `EventRecorder` freezes `messaging_channel`, `channel_type`, `inbox_id`, optional
  `page_id` and `ad_id` on `message_received`. The builder captures actual Meta
  message referral; the event includes an ad only for `source == ADS`.
  Conversation `meta_ad_id` is a mutable latest-touch sidebar value and is never
  a reporting source. Neither labels nor an absent ad prove organic acquisition.
- `ConversationEvent` preserves qualified and paid occurrence times and identities.
  Paid time means the last successful payment when a fully paid current order was
  observed, as declared by its `time_basis`; it is not a reconstructed historical
  first-paid boundary. Qualification time comes from cited incoming evidence.
- `ShopifyOrderAttribution.verified` supplies the existing verified
  account/shop/order/conversation/contact link. A signed-link candidate or matching
  person alone is not sufficient. No order-total field on that attribution row is
  a paid-money source. Chat-assisted website purchases remain website purchases.
- `ShopifyOrderFinancialState.snapshot.first_paid_snapshot` and the `order_paid`
  event retain original paid facts. The outer snapshot is only the latest known
  cash/refund state. No historical series or late-attachment timestamp exists.
- There are no structured fitting/pickup lifecycle events, qualification reason
  codes, complete business-hours SLA observations or campaign-spend records in
  this core. Those U7 breakdowns remain explicit gaps rather than guessed values.

## Interface and time contract

Add `Umi::Funnel::CohortReport.perform(account_id:, from:, until_time:, as_of:,
horizon_days:)` and `umi:funnel:cohorts`. The command requires `ACCOUNT_ID`,
`FROM`, `UNTIL`, `AS_OF` and `HORIZON_DAYS`; timestamps are explicit UTC ISO8601
with `Z`. Validate an existing positive account, `from < until_time <= as_of <=
generated_at`, acquisition span at most 90 days, and integer horizon 1–90 days.
Require a valid `UMI_FUNNEL_STARTED_AT` and `from >=` that boundary. Reports remain
readable when capture/dispatch switches are off. Invalid input emits no completed
JSON report and performs no external or database mutation.

Capture `generated_at` once at entry. `AS_OF` is the **outcome-time cutoff**, not a
claim to reconstruct what the business knew on that date. Use evidence currently
available when this report is generated, including late captured events and late
verified order links whose occurrence time meets the cutoff. Return
`knowledge_basis: current_records_at_generation` and
`historical_restatement_possible: true`. Privacy erasure also changes later runs.
Do not filter on `observed_at <= as_of` and silently mix that different definition
with current linkage. Exclude records observed after `generated_at` from this run.

For each conversation with start `t`, its outcome interval is
`[t, min(t + horizon_days * 24 hours, as_of)]`, inclusive at both endpoints.
Acquisition is `[from, until_time)`. A conversation is mature exactly when
`t + horizon_days * 24 hours <= as_of`. The `Asia/Bangkok` calendar date of `t`
is a display/grouping dimension; the individual duration is always fixed.

## Cohort assignment

1. Within the selected account, find each conversation's earliest nonredacted
   `message_received` event with `provenance == live`, non-null `occurred_at`,
   occurrence at/after the observation boundary, and observation no later than
   `generated_at`. Select across all recorded history before applying the
   acquisition window, so a later message cannot reacquire an existing thread.
   Break timestamp ties by the numeric source message ID, then event ID.
2. Require the current conversation/contact to exist in the same account, match
   the event, and not be redacted. Exclude conversations created before the
   observation boundary: their first acquisition is not observable by this core.
   Recovered/private/outgoing/historical evidence cannot establish membership.
3. Include the conversation only if its selected first occurrence is in the
   acquisition window. Use that event's frozen dimensions, never later touches.
   Group by Bangkok cohort date, inbox ID, channel type, messaging channel,
   page ID and ad ID. Missing values remain null; `ad_evidence` is `recorded_ad`
   only when this snapshot has an ad ID, otherwise `unknown`.

Each conversation belongs to exactly one row. This is first *recorded live*
conversation evidence since activation, not a promise of complete platform
history or first-ever contact acquisition. A later repaired earlier live event
may restate membership; the knowledge-basis flag covers this limitation.

## Outcomes and denominators

Each row has separate `mature` and `immature` metric blocks. Each block contains:

- `conversations`: distinct members of that maturity subset.
- `qualified_conversations`: members with the stable nonredacted qualified
  occurrence inside their individual interval, except invalidated qualification.
  To determine invalidation, take the latest classification at/before `as_of`
  among statuses `qualified`, `not_sales`, `unevaluated` (using occurred time then
  event ID); `not_sales`/`unevaluated` invalidate and a later explicit `qualified`
  restores the same milestone. `inactive`/`engaged` do not erase or restore it.
  Preserve `recorded_qualified_milestones` and `invalidated_qualifications` counts
  beside the effective count. Corrections are facts about classification, not a
  reason to discard a genuine paid sale.
- `paid_conversations`: members with at least one eligible paid order in their
  individual interval. Qualification is not required to count an actual sale.
- `qualified_then_paid_conversations`: effective qualified members with at least
  one counted paid order at/after that member's qualified occurrence time.
- `paid_orders` and `paid_value_by_currency`: distinct paid orders and the sum of
  immutable `order_paid.payload.value`, grouped by ISO currency. Never sum mixed
  currencies. Serialize money with BigDecimal as decimal strings.
- `incomplete_paid_evidence`: distinct candidate paid orders whose recorded event
  points to a member and falls inside its interval, but whose required verified
  link, financial state or first-paid snapshot is missing. Include counts by
  `missing_verified_link`, `missing_financial_state`, `missing_first_paid_snapshot`
  (choose the first applicable reason in that order so the total is distinct).
  Such an order earns no credited sale or money, but never disappears as an
  apparent zero-sale observation. `paid_evidence_complete` is false and
  `paid_totals_basis` is `lower_bound` whenever this count is nonzero; otherwise
  they are true and `complete_for_recorded_verified_evidence`. This completeness
  does not claim that unlinked account sales or missing platform history are known.
- Rates `qualified / conversations`, `paid / conversations` and
  `qualified_then_paid / qualified`, represented as numerator, denominator and
  a decimal ratio rounded to six places. A zero denominator has null ratio.
  All rate ratios in the immature block are null (`incomplete_followup`); keep
  the counts visible. No combined mature+immature conversion rate or ranking.
  Even in a mature block, both paid-related ratios are null
  (`incomplete_paid_evidence`) when its paid evidence is incomplete. Keep the
  known numerators and denominators visible; qualification-only ratios are
  unaffected by missing payment evidence.

Eligible paid orders have a nonredacted `order_paid` event for this account with
valid money/time, matching current same-account/shop/order verified attribution,
and the same conversation/contact. A nonredacted financial state must refer to
that paid event and retain its first-paid snapshot. Money/time come from the
immutable event; current refunded status never rewrites them. A missing state,
first-paid snapshot or verified link is reported as excluded/incomplete evidence,
not coerced into zero. Malformed authoritative money or contradictory paid facts
fail the report visibly. Deduplicate on account + normalized shop + order ID before
counting/summing, including row totals. Multiple orders can increase order count
and money while the paying conversation count remains one. A later ad touch
does not split or move any of that conversation's orders between rows.

## Refunds and attribution coverage

For the distinct paid orders counted in each maturity block, expose a separate
`latest_cash_snapshot` block grouped by currency: known refunded/net-cash totals,
covered order count, unavailable order count, pending reconciliation count,
financial-error count, and oldest/newest snapshot observation times. Use only
nonredacted, parseable snapshots observed no later than `generated_at`, with the
same currency and classifications
other than `test_order`/`needs_review`; malformed/absent snapshots are unavailable.
Valid older snapshots with pending/error reconciliation remain *latest known*,
and their pending/error counts must remain visible. Partial totals are labelled
`complete: false` if any selected order is unavailable or has pending/error work.
Do not imply freshness from the report generation time.

This block may include a refund after `AS_OF` or after the individual horizon.
Return `cash_time_basis: latest_observed_not_historical` and
`refunds_within_outcome_window: null`, `net_paid_within_outcome_window: null`.
It must never be used as the numerator of fixed-horizon revenue/ROAS. A first-seen
refunded order without a paid occurrence contributes no invented purchase.

Top-level `coverage` separately counts currently known account paid occurrences
with source time in `[from, as_of]`: verified in-cohort, verified outside cohort,
unlinked/unverified, and redacted/unusable. Declare that scope; it is not another
cohort denominator. Count each order once with mutually exclusive categories.
Also report cohort-linked financial states with `paid_history_unknown` and no
paid event as a current-data gap, using verified attribution only. Do not assign
unlinked money to ads or infer a replacement-order relationship.

## Output and missing inputs

Emit one aggregate JSON object with `schema_version`, parameters, observation
boundary, `generated_at`, the time/knowledge-basis declarations, sorted `rows`,
and `coverage`. No conversation/contact/order IDs, message text, scoped social
user IDs, email, phone or freeform classification reasons are printed. Ad/page/
inbox IDs are reporting dimensions; no names are fetched. Zero-member rows are
omitted. Empty data is a successful report with empty rows and zero counts.

Every row returns `spend: {status: unknown, value: null}`, `roas: null`,
`cost_per_paid_conversation: null` and `cost_per_paid_order: null`.
`spend_window` records the acquisition window only as the required future input
alignment, not evidence that spend was loaded. No Meta Ads API is called. Fixed
horizons, account/ad IDs and currency matching are prerequisites to a later
explicit spend join.

Return a short fixed `limitations` list naming absent service-kind/reservation/
attendance/no-show data, reason-code breakdown, historical refunds, historical
linkage snapshots and spend. Raw reason strings cannot safely become campaign
dimensions; that later report needs a reviewed controlled reason field. Business
hours/SLA and ad-comment ownership metrics also need their own verified sources.
These gaps do not prevent the cohort export, but this unit does not finish all U7
service reporting or establish Meta attribution, purchase optimization or uplift.

## Implementation and verification

Own only a new cohort service/spec, its rake task/spec, and reporting usage docs;
reuse current tables and paid semantics. Query account-scoped eligible records
in batches, avoiding provider calls and loading message bodies. Keep the first
cohort selection before window filtering; bound work by conversations relevant
to the requested window rather than loading every account message into Ruby.
Require malformed authoritative money or conflicting duplicate paid facts to fail
visibly before JSON output, rather than emitting a quietly partial financial sum.

Tests must establish:

1. Earliest live event wins across the window boundary and equal timestamp ties;
   later ad touches, labels and sidebar changes cannot reassign a cohort.
2. Recovered/historical/pre-activation conversations and redacted/orphaned identity
   are excluded. Missing ad is unknown. Different channels/inboxes remain distinct.
3. Exact acquisition/end-of-horizon boundaries; a cohort starting three days later
   stays immature while its otherwise identical older cohort is mature. Immature
   and zero-denominator ratios are null, never silently compared as zero sales.
4. Two orders on one conversation count two orders, one payer and money once;
   two currencies remain separate. Unverified or other-account/shop links cannot
   leak money into a cohort. Orders before start/after the horizon are excluded.
   A known in-window member-linked paid event with missing financial state or
   first-paid snapshot increments incomplete evidence, marks paid totals as a
   lower bound, and nulls paid ratios instead of reporting an apparent 0% result.
5. Qualification correction, inactivity and explicit requalification preserve one
   milestone and the specified effective denominator. Paid sales can exist without
   qualification; qualified-then-paid respects ordering.
6. Final kept-item sale 4,000 after reservation 12,000 contributes 4,000; a later
   1,000 refund leaves original cohort paid value 4,000 and latest cash 3,000 with
   the explicit nonhistorical label. Missing/stale/review snapshots stay visible;
   first-seen refunded orders do not invent a paid occurrence.
7. Late observed/linked evidence can restate an older outcome-time cutoff and is
   labelled accordingly. No observed record after generation enters the run.
8. Spend and ROAS remain unknown/null; aggregate JSON has no personal identifiers
   or freeform reason. Invalid input fails without external calls or writes.

Run focused Ruby/rake specs, lint and existing paid/core reports as affected. No
live provider event, Shopify mutation, customer message or ad-budget action is
part of this verification. Independent spec review precedes implementation, and
independent code review precedes claiming the export complete.
