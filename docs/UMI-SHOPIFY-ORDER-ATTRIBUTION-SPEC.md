# D16 — Shopify web-order attribution verification report

**Status:** Draft — awaiting approval before implementation  
**Date:** 2026-08-12  
**Scope:** Read-only verification of Shopify web-checkout orders

## Decision

Build a small, repeatable Shopify-side verification report that reads recent
orders, limits the attribution table to `source_name == "web"`, extracts
checkout `note_attributes`, and groups orders with a usable `utm_id` by ad ID
and currency. The report is an audit input for comparing Shopify's checkout
evidence with Meta's reported Purchase numbers.

This is deliberately **not** an attribution-plumbing patch. The real chain is:

`ad → conversation → order → Meta`

Patch 20 covers `ad → conversation`. Shopify's web checkout and the existing
Meta pixel cover the web `order → Meta` edge. D16 does not repair the broken
`conversation → order` edge and must not be presented as completing the chain.

## Why this is worth doing

`utm_id` is checkout evidence of the campaign identifier carried into the
customer's order. It is useful as a ground-truth comparison point for what the
customer actually arrived with, independent of Meta's attribution modelling.
It does not add a signal that Meta lacks and it is not cryptographic proof of
the click: checkout parameters can be altered, omitted, or copied.

The strongest current use is D14's double-count suspicion. The Shopify
Facebook/Instagram app may be sending draft orders as Meta Purchase events. A
Shopify order-by-ad table can establish the web-checkout baseline and expose a
gap against Meta's reported numbers without Events Manager access. It can
identify a discrepancy; by itself it cannot prove that draft orders caused the
discrepancy, because Meta's reporting window, modelling, refunds, and other
event sources may also differ. The draft-order population remains outside this
report.

## Production evidence

Measured read-only against account 1 through the existing Shopify integration
on 2026-08-11. The order query used `status=any`, a 60-day `created_at_min`
(`2026-06-12T17:34:07Z`), and Shopify's maximum REST page size of 250.

| Population | Orders | Gross order value | Share of all value |
|---|---:|---:|---:|
| All orders | 77 | ฿450,687.90 | 100.00% |
| Web checkout (`source_name == "web"`) | 29 | ฿200,988.90 | 44.60% |
| Web orders with a usable `utm_id` | 5 | ฿34,394.00 | 7.63% |

The five usable IDs are all web orders, so they cover 17.11% of web-checkout
value. The original “26 of 77” statement means 26 orders had any
`note_attributes`; it does not mean 26 had usable ad IDs.

Within the 29-order web population, the note-attribute categories are:

| Category | Orders | Meaning |
|---|---:|---|
| Usable `utm_id` | 5 | Exactly one nonblank `utm_id`, preserved as a string; all five observed values are numeric Meta-style IDs and also carry `utm_source=ig`, `utm_medium=paid`. |
| UTM fields without `utm_id` | 4 | UTM-shaped data exists but cannot identify one ad. Examples include `utm_source=ig`/`utm_medium=social` and Shopify email campaigns. |
| `bsure-attribute` only | 16 | Checkout/device metadata with no UTM key; not attribution evidence. |
| No note attributes | 4 | No order-side attribution data. |
| **Total web** | **29** | Categories conserve the full web population. |

Across all 77 orders there is one additional non-web note-attribute order with
affiliate-partner fields; it is excluded from the web report. No observed web
order had a separate note-attribute category beyond those listed above. The
parser must still classify malformed/ambiguous entries rather than silently
choosing one.

### Population the report cannot reach

The largest excluded bucket is 37 of 77 orders with
`source_name == "325329387521"` and matching `app_id == 325329387521`:

- email: 4/37
- phone: 4/37
- customer object: 8/37
- note attributes: 0/37
- landing site: 0/37

The Shopify GraphQL Admin API `app(id: "gid://shopify/App/325329387521")`
lookup resolved the app to **Shumabit**, developer **UMI**, using the existing
token. The current report should retain the raw `source_name` and `app_id` in
its coverage summary, but should not hardcode this store-specific title or add
a GraphQL decoration lookup to the minimal recurring web report. The mapping is
recorded here as a verified finding. This population needs an order-creation
workflow change before it can be attributed.

## Requirements

1. Accept an explicit account and date range. Do not use a shifting implicit
   default in the verification artifact.
2. Read Shopify orders through `Umi::Shopify::ClientFactory` and the existing
   `read_orders` permission. Do not request `read_draft_orders`, add OAuth
   scopes, or write to Shopify.
3. Fetch only the fields needed for the report: order ID/name/date, total,
   currency, financial status, `source_name`, `app_id`, source diagnostics,
   and `note_attributes`. Do not fetch or emit email, phone, customer, or raw
   checkout payloads in the report.
4. Restrict ad rows to web checkout orders. Keep excluded-source counts and
   revenue in the coverage summary so the report states its denominator and
   blind spots.
5. Parse `note_attributes` as an array of `{name, value}` pairs. Normalize
   names and values to strings; preserve `utm_id` as a string so 17-digit IDs
   cannot lose precision. Treat nil values as blank.
6. Define a usable ID as one nonblank `utm_id` entry. Multiple nonblank entries
   for the same key are ambiguous and must not be aggregated as usable.
7. Group usable web orders by exact `utm_id` and currency. Sum order totals with
   decimal arithmetic and retain the order count, order names/IDs, and distinct
   UTM metadata values needed to compare the row with Meta.
8. Report diagnostic counts for usable IDs, UTM-without-ID, `bsure`-only, no
   note attributes, malformed/ambiguous attributes, and excluded sources.
9. Follow Shopify cursor pagination. The first request carries the date filter;
   cursor requests carry only the cursor and page limit. Do not emit a partial
   report if a page fails or a page cap is exceeded.
10. Produce a local CSV artifact plus a machine-readable summary suitable for
    comparing a fixed Shopify range with Meta's Purchase report. The command
    itself must have no Chatwoot database writes, label changes, custom
    attribute writes, order mutations, or cached customer data.

## Artifact and implementation shape

Use the smallest UMI-owned surface:

- `umi/app/services/shopify/order_attribution_report_service.rb` — fetch,
  paginate, classify, conserve, and aggregate the order evidence.
- `lib/tasks/umi_shopify_order_attribution.rake` — accept account/date inputs
  and write the local CSV/summary using the service.
- `spec/services/umi/shopify/order_attribution_report_service_spec.rb` — parser,
  conservation, aggregation, pagination, and failure behavior.
- `spec/lib/tasks/umi_shopify_order_attribution_spec.rb` — task output and
  argument validation if the task has behavior beyond direct delegation.

The service should return structured data; the task should own presentation
and local file output. There is no order model, backfill table, migration,
webhook consumer, dashboard endpoint, or recurring job in this patch.

The CSV's ad rows should include at least:

`utm_id`, `currency`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`,
`order_count`, `gross_order_value`, and order names/IDs.

The summary should include the exact date range, fetched count, web count,
web gross value/share, category counts, category value totals, and excluded
source counts. It must label the value as gross Shopify order value, not
recognized Meta revenue or paid accounting revenue; `financial_status` should
be retained in the evidence/summary so later reconciliation can choose a
consistent paid-order policy.

## Alternatives rejected

| Alternative | Rejection reason |
|---|---|
| Conversation custom attributes | Patch 20 already owns the conversation-side Meta keys. Without a conversation→order join, writing order UTM data there would attach evidence to the wrong entity or invent a false join. |
| Contact attributes | Contacts are not orders and identity is incomplete outside web checkout. This would persist mutable customer data without answering the Meta Purchase audit. |
| Labels | Labels can power Chatwoot's conversation reports, but they attach to conversations. They cannot represent order-level revenue without the broken join, and Chatwoot's label reports count conversations, not order value. |
| Persistent order-attribution records | Adds migrations, retention/erasure obligations, and stale-copy risk for a report that can read Shopify directly. It is the wrong investment before the conversation→order design is decided. |
| Dashboard/API surface | Expands the patch into product UI and permissions. A local CSV/summary is sufficient for the verification question. |
| Webhook-side ingestion | The report is an audit read, not an order-processing path. Adding webhook delivery, replay, or a new poller would create plumbing that a future deterministic join could replace. |

## Failure modes and guardrails

- Missing, disabled, or scope-incompatible Shopify integration: fail loudly
  before emitting a partial artifact.
- Shopify 429/5xx or a failed cursor page: stop without writing a successful
  report; preserve the error and retry manually later. The report makes one
  field-limited list request per page and does not fetch one order at a time.
- Nil note-attribute values, duplicate names, blank IDs, and malformed entries:
  classify them in diagnostics; never coerce a blank or ambiguous value into an
  ad row.
- More than one currency: group by currency and never sum across currencies.
- Shopify API pagination beyond the configured safety cap: fail loudly rather
  than silently undercounting.
- Shopify redaction: do not cache customer or order payloads in Chatwoot;
  regenerate the report from Shopify so the source remains authoritative.

## Verification plan

Before implementation, this spec's production baseline is the acceptance
reference, not a fixture to copy into code. After implementation, verify a
read-only run over the same fixed range reports 77 total orders, 29 web orders,
฿200,988.90 web gross value, 44.60% web share, 5 usable IDs, 4 UTM-without-ID,
16 `bsure`-only, and 4 web orders with no note attributes. The five ad IDs must
all be present in the web table and the ad-row totals must conserve the
฿34,394.00 usable-ID subtotal.

The specs must additionally prove:

- a fixture with the real array shape `{ "name" => "utm_id", "value" =>
  "120252251820030415" }` produces one exact string ID and one aggregate row;
- a fixture with a sibling/wrong key path or nil value does not produce an ID;
- `bsure-attribute` alone is diagnostic noise, while UTM fields without an ID
  are not attributed;
- repeated orders with the same ID aggregate once per currency and preserve
  decimal totals;
- duplicate nonblank IDs are classified ambiguous and excluded;
- every fetched order belongs to exactly one category and category totals
  conserve both order count and value;
- cursor pages omit the original date filter and are not double-counted;
- a failed page or page-cap breach produces no successful partial report;
- the service uses only Shopify GETs and does not change hook settings,
  contacts, conversations, labels, custom attributes, or database rows.

## External and local references

- Shopify [REST Order resource](https://shopify.dev/docs/api/admin-rest/2026-01/resources/order)
  documents `note_attributes`, `app_id`, `source_name`, and the `orders` read
  scope. Shopify REST is legacy, but the fork already pins the existing client
  to `2026-01`, supported through 2027-01-16.
- Shopify [REST cursor pagination](https://shopify.dev/docs/api/usage/pagination-rest)
  requires following the response link/cursor and limits pages to 250.
- Shopify [API limits](https://shopify.dev/docs/api/admin-rest) document the
  REST throttle and `Retry-After` behavior.
- Shopify [GraphQL App query](https://shopify.dev/docs/api/admin-graphql/latest/queries/app)
  was used only to identify the current `325329387521` source as Shumabit.
- `umi/app/services/shopify/client_factory.rb` and
  `spec/jobs/umi/shopify/contact_poll_job_spec.rb` are the local client and
  cursor-pagination patterns.
- `UMI-PATCHES.md` section 20 and
  `docs/UMI-FBIG-AD-ATTRIBUTION-SPEC-R4.md` establish the fork's requirement to
  verify payload shape and avoid silent attribution no-ops.

## Patch registry / removal

After approval and implementation, add one focused `UMI-PATCHES.md` row for the
verification report, including the four files above and a remove-when such as:
an upstream/native order-level attribution report can audit raw checkout UTMs
against Meta Purchases, or UMI no longer needs this verification.
