# Conversation cohort export

Run this read-only export inside the deployed Chatwoot application environment.
It uses stored events, verified order links and Shopify financial snapshots. It
makes no provider requests and sends no messages.

```sh
ACCOUNT_ID=1 \
FROM=2026-09-01T00:00:00Z \
UNTIL=2026-09-08T00:00:00Z \
AS_OF=2026-09-22T00:00:00Z \
HORIZON_DAYS=14 \
bundle exec rake umi:funnel:cohorts
```

Choose actual account and dates. `UMI_FUNNEL_STARTED_AT` must be configured;
`FROM` cannot precede it. All three dates require UTC `Z`, and `AS_OF` cannot be
in the future. Acquisition and horizon are each limited to 90 days. Capture and
provider dispatch do not need to be enabled to read a report. The command prints
one aggregate JSON object only after successful computation; malformed required
paid evidence raises an error instead of silently producing partial revenue.

Each row groups conversations by their first recorded live incoming message's
Bangkok date, inbox, channel, page and ad. The acquisition window includes `FROM`
and excludes `UNTIL`. An absent ad means unknown source. Later messages and
sidebar labels cannot move a conversation into another campaign's cohort.

Read `mature` and `immature` separately. Each conversation gets the same fixed
number of elapsed days to qualify or pay; its observation stops at `AS_OF`.
Immature counts are visible but their rates are null. A qualification later
corrected to not-sales/unevaluated remains a recorded milestone but is excluded
from effective qualification; explicit requalification restores it. A genuine
paid sale counts even without qualification.

`paid_orders` counts distinct verified orders. `paid_conversations` counts each
paying conversation once. `paid_value_by_currency` holds original successful
fully-paid order values, not reservation totals. Missing verified links,
financial rows or original paid snapshots appear in `incomplete_paid_evidence`;
that block's paid totals become a lower bound and its paid ratios are null.
Currencies are never added together.

`latest_cash_snapshot` is separate: it can include refunds observed after
`AS_OF` or the outcome horizon. Its coverage, pending reconciliation, errors and
observation dates show how complete that latest known cash sum is. Historical
refunds and historical net revenue remain null. A first-seen already-refunded
order cannot invent a purchase; verified cohort-linked unknown history is
reported in coverage.

Top-level coverage counts account paid occurrences from `FROM` through `AS_OF`,
including orders outside cohort membership and unverified links. Its
`verified_in_cohort` means the conversation belongs to a reported row; the
payment can still fall outside that conversation's outcome horizon. Coverage is
not a conversion denominator and does not attribute unlinked money to ads.

`AS_OF` is an outcome-time cutoff, not a historical database snapshot. Late
observations, verified links, corrected early messages and privacy erasure may
change a rerun for the same dates. `knowledge_basis`, `generated_at` and
`historical_restatement_possible` state that explicitly.

Spend remains unknown; ROAS and acquisition costs remain null. This export
cannot establish Meta attribution or campaign uplift. Fitting/pickup attendance,
no-show, structured qualification reasons, business-hours SLA and ad-comment
ownership need additional verified sources before they can be reported. The
JSON contains reporting dimensions and counts, with no conversation/contact/
order IDs, message text, customer identity or freeform reasons.
