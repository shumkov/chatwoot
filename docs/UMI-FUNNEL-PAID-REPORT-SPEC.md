# Paid-order reconciliation for the messaging pilot

2026-09-27. Independent financial-correctness and simplicity/feasibility reviews
returned CLEAN before implementation. Implementation slice of the approved funnel plan's U5/U7 observation
work. The user explicitly directed implementation. This slice makes the pilot's
manual order register verifiable before automatic conversion delivery exists.

## Problem and scope

Klaviyo Placed Order currently includes unpaid reservations. Live matched examples
show a ฿7,980 TBYB order later voided without a successful sale, and a ฿4,491
pickup order whose payment occurred 18 days after its reservation. We need a
repeatable command that checks the actual Shopify order and transactions.

Implement one read-only report service and rake entrypoint. Reuse the existing
enabled account Shopify integration, `Umi::Shopify::ClientFactory` and its API pin.
No migrations, scheduler, new credential, customer messages or provider writes.
The report is a current snapshot, not an immutable payment ledger or Meta export.
This is deliberately a smaller deliverable than full U5: later event capture is
still required for automatic lifecycle changes and historical conversion cohorts.

## Interface and data flow

`Umi::Shopify::PaidOrderReport.new(account_id:, order_ids:).perform` returns a JSON-
serializable hash. `RAILS_LOG_TO_STDOUT=false ACCOUNT_ID=1 ORDER_IDS=123,456 bundle exec rake
umi:funnel:paid_orders` prints the completed report as JSON. Require an explicit
positive account ID and 1–50 distinct positive numeric order IDs; reject invalid
inputs before API calls. Repeated IDs are deduplicated rather than double counted.

Find the enabled Shopify hook by account (fail if missing or ambiguous). For each
order, use GET order with restricted fields and GET order transactions through
the existing client. Restrict fields to order ID, creation/update timestamps,
financial_status, test, cancelled_at, currency, total_price and current_total_price.
Only transaction ID, kind, status, currency, amount, amount_rounding and
processed_at participate. Do not retain/print customer details, receipt objects,
raw payloads, tokens or gateway authorization codes.

Return account/shop, observation start/end, rows, outcome counts and totals by
currency. Each row includes original/current order value, current financial
status, order creation time, last successful payment time, captured/refunded/net
cash, classification, review reasons, and verified Chatwoot conversation ID if
an existing non-redacted attribution for the same account/shop/order exists.
No attribution row is created or modified. Missing attribution is unknown, never
zero chat-assisted revenue. Existing unverified candidates stay unverified.

## Financial interpretation

- Sum only successful `sale` and `capture` transactions as captured funds.
  Authorizations, pending, failures and voids never count as payment.
- Sum only successful `refund` transactions as returned funds. A pending refund
  does not reduce actual cash, but makes paid/refund reconciliation review-needed.
- Use decimal arithmetic. Missing/malformed/non-finite/negative money is unknown,
  not zero. Unknown currency, different transaction/order currencies, nonzero
  cash rounding, duplicate/conflicting transaction IDs or missing timestamps on
  successful money movement produce a visible `needs_review` row and exclude it
  from totals. Do not invent exchange rates or rounding rules.
- A non-test order with `financial_status=paid`, positive current total, no
  successful refunds and captured amount exactly equal to current total is
  `paid`. Its current total is the final basket amount observed now; original
  reservation value must not replace it.
- Pending/authorized/partially_paid orders are `unpaid` when captures are zero,
  `partial_payment` when captures are positive but below the current total.
  They do not enter paid-sale totals. Inconsistent status/money combinations
  produce `needs_review`.
- A voided/cancelled unpaid reservation is `no_sale`. A test order is
  `test_order` and excluded from all money/count totals except its own status
  count. Positive money on a cancelled order is shown as `needs_review` unless
  the full successful refund reconciles it.
- A `refunded` order requires positive captures equal to successful refunds;
  a `partially_refunded` order requires captures > refunds > 0. Report observed
  money movement and the refund classification without reconstructing a paid
  basket or original conversion time from the current edited order.
- A zero-value order is `no_sale` only when it has no money movement; inconsistent
  money/status is review-needed. Unknown financial statuses are review-needed.
- `last_payment_at` is the latest successful sale/capture transaction's
  `processed_at`, never order creation or observation time. Do not call it the
  first full-payment time or use it to reconstruct historical paid cohorts.

Per-currency totals include resolved non-test rows: observed captures, observed
refunds and net cash. Separately count only `paid` rows and sum their observed
current paid value. Deposits therefore remain visible money without becoming
sales. `needs_review` rows and their reasons are always counted and visible;
unknown money uses null. Do not combine currencies or assert Meta-attributed ROAS.

## Failure modes

HTTP/API failures abort the command before any report is printed; propagate the
failure without a retry layer or partial success output. Shopify's current token
may only access recent orders: an inaccessible older ID is an error, not an unpaid
order. The order and transaction reads are not atomic; mismatches remain visible
review cases and the report records its observation interval. No API error body
or response payload is copied into custom logs. A later rerun reads fresh state;
it never appends a second conversion or triggers marketing.

## Alternatives and research

- Reusing Placed Order or Shopify lifetime-spend summaries is insufficient for
  payment timing and edited fitting baskets, as the live examples demonstrate.
- A durable financial-state table and webhooks are still appropriate for later
  automatic events. They are unnecessary for this initial operator-invoked report.
- GraphQL is Shopify's preferred API for new public apps. This existing private
  integration already uses the pinned REST client successfully; reusing it avoids
  an unrelated client migration. Revisit if the existing endpoint is retired.

Primary contracts: [Shopify transactions](https://shopify.dev/docs/api/admin-rest/2026-01/resources/transaction),
[orders](https://shopify.dev/docs/api/admin-rest/2026-01/resources/order), and
[Klaviyo Shopify metrics](https://help.klaviyo.com/hc/en-us/articles/115005080447).
Repo patterns: `client_factory.rb`, `order_attribution_service.rb`,
`shopify_order_attribution.rb`, `lib/tasks/umi_shopify_contacts.rake`.

## Verification

Test through the report service with stubbed Shopify responses and real local
attribution records. Cover pending→paid, authorization→capture without double
counting, live-shaped voided TBYB and delayed pickup, edited partial-keep basket,
partial deposit, partial/full/pending refunds, test/free orders, currency mismatch,
missing/invalid money/time, duplicate order IDs, API failure, disabled/ambiguous
integration, no/verified/unverified/redacted/cross-shop attribution, and sensitive
field exclusion. Task tests cover required arguments and completed JSON output.

Run the new specs plus existing attribution/client specs and targeted RuboCop.
Use the isolated local test database; no test reaches live Shopify. After local
review, run the command's service read-only against the two already-inspected
special-payment orders without deploying or changing the running application.
Report this bounded smoke separately from unit tests and full campaign readiness.
