# UMI × Meta — Purchase event data quality

**Status:** Investigation complete for what production access can settle; one
Events Manager read still outstanding
**Date:** 2026-08-12
**Scope:** Read-only. No production writes, no code changes.
**Dataset:** `1540380063308828` ("cherry.cheap's pixel"), business
`497970999394825` (UMI STORE CO., LTD.) · Page `516819784857962` ·
Instagram `17841468119523354` · shop `pizeev-ys.myshopify.com` (umi.store)

---

## Headline answers

**1. Does Meta already receive every Shopify order, not just web checkouts?
YES.** Over 15 Jul – 11 Aug 2026 Meta recorded **39 Purchase events** against
**38 Shopify orders of all types** in the same window. Web checkouts alone were
**13**. Adding a second Purchase stream would double-count. The long-held
premise that "55% of revenue never reaches Meta" is **wrong**.

**2. Which subset of Purchase events is missing the value field?** Not
settled. Every Purchase event in the trailing 28 days carries a `value` **key**,
and Meta's own missing-parameter diagnostic currently reports *passed*. But
Meta's warning quotes an empty string (`""`), which is a key that is present and
blank — a state the aggregation I can read cannot distinguish from a real
number. The affected population is narrowed to **two candidate subsets of
exactly 13 orders each**, with a single decisive test defined in
[What to read from Events Manager](#what-to-read-from-events-manager).

---

## Access finding: the dataset is readable from production after all

`UMI-META-PLAN.md` and the backlog record that Events Manager is unreachable
because the page token returns `(#100) Missing Permission` on the dataset. That
is true for the dataset's *detail fields*, which require `ads_read`:

```
GET /v21.0/1540380063308828?fields=id,name,creation_time,last_fired_time
  → (#200) Ad account owner has NOT grant ads_management or ads_read permission
```

But the **`/stats` and `/da_checks` edges are readable** with the Facebook Page
token already stored in production (`Channel::FacebookPage#page_access_token`):

```ruby
tok = Channel::FacebookPage.first.page_access_token
# event counts, hourly buckets
GET /v21.0/1540380063308828/stats
    ?aggregation=event_total_counts&start_time=...&end_time=...
# per-event-name filtering works
GET /v21.0/1540380063308828/stats
    ?aggregation=custom_data_field&event=Purchase&start_time=...&end_time=...
```

Accepted `aggregation` values: `browser_type`, `custom_data_field`,
`device_os`, `device_type`, `event`, `event_detection_method`,
`event_processing_results`, `event_source`, `event_total_counts`, `host`,
`match_keys`, `pixel_fire`, `url`. The `event=` filter is honoured (verified:
unfiltered vs `event=Purchase` return different distributions).

**Retention is a hard trailing 28 days.** Probing day by day, the first bucket
with any data is **2026-07-15** and every earlier day returns zero — including
days on which Shopify definitely had orders. A query spanning Feb–Aug returns
byte-identical totals to the 28-day query. **No history is reachable through
this API**, which is the central limitation on question 2.

**This view agrees with the owner's Events Manager.** It independently
reproduces the 39 Purchase events the owner read off the screen, so the two
surfaces are describing the same data.

---

## What Meta actually received — 15 Jul – 11 Aug 2026 (28 days)

Single API call per row; no daily chunking (chunked daily queries double-count
across hour boundaries and are not used for any figure here).

| Event | Count |
|---|---:|
| PageView | 18,306 |
| ViewContent | 5,315 |
| AddToCart | 403 |
| InitiateCheckout | 151 |
| Search | 75 |
| AddPaymentInfo | 35 |
| **Purchase** | **39** |

Purchase field presence (`aggregation=custom_data_field&event=Purchase`):

| Field | Events carrying it |
|---|---:|
| `value` | 39 / 39 |
| `currency` | 39 / 39 |
| `order_id` | 39 / 39 |
| `content_type` | 38 / 39 |
| `content_ids` | 38 / 39 |
| `num_items` | 38 / 39 |

Purchase by connection method (`aggregation=event_source&event=Purchase`):

| Connection method | Events |
|---|---:|
| BROWSER | 13 |
| SERVER | 26 |
| **Total** | **39** |

---

## What Shopify actually produced — same window

Read through `Umi::Shopify::ClientFactory`, `status=any`, REST page size 250.
Order counts are identical under UTC, Asia/Bangkok (+07) and −07 window
framings (38 in all three), so none of this is a timezone artifact. The
dataset reports in **+0800**; realigning the Shopify window to +0800 also gives
38 orders and the same bucket totals.

| Bucket | Orders | Gross value | Share of orders |
|---|---:|---:|---:|
| Web checkout (`source_name = web`) | 13 | ฿92,250.00 | 34.2% |
| Shumabit app, **no checkout object** | 13 | ฿85,860.00 | 34.2% |
| Shumabit app, with checkout object | 9 | ฿33,822.00 | 23.7% |
| Draft orders | 3 | ฿17,106.00 | 7.9% |
| **Total** | **38** | **฿229,038.00** | 100% |

The Shumabit split is real and concurrent, not a migration — the two shapes
interleave day by day. Orders with no checkout also have no `checkout_token`,
no `cart_token`, and `taxes_included = false`; the correlation is perfect
across all 22 Shumabit orders.

**60-day control** (12 Jun 17:34 UTC – 11 Aug 17:34 UTC), which reproduces the
independently-measured baseline in `UMI-SHOPIFY-ORDER-ATTRIBUTION-SPEC.md`
exactly (77 orders, ฿450,687.90, web 29 / ฿200,988.90 / 44.60%) — confirming the
pull method:

| Bucket | Orders | Gross value | Share of revenue |
|---|---:|---:|---:|
| Web checkout | 29 | ฿200,988.90 | 44.6% |
| Shumabit, no checkout | 27 | ฿151,771.00 | 33.7% |
| Shumabit, with checkout | 10 | ฿47,622.00 | 10.6% |
| Draft orders | 10 | ฿43,406.00 | 9.6% |
| Other (app `341262598145`) | 1 | ฿6,900.00 | 1.5% |
| **Total** | **77** | **฿450,687.90** | 100% |

---

## The mapping — and the answer to the double-count question

| | Meta | Shopify |
|---|---:|---:|
| BROWSER Purchase events | 13 | web checkout orders: **13** |
| SERVER Purchase events | 26 | non-web orders: **25** |
| Total | 39 | 38 |

BROWSER matches web checkouts **exactly**. SERVER matches all non-web orders
to within one event. Corroborating evidence that Shopify is the sole sender:

- **`order_id` is present on 39 of 39 Purchase events.** Every event carries a
  Shopify order identifier.
- The official **Facebook & Instagram app by Meta** (Shopify app `2329312`) is
  installed as a sales channel, alongside Online Store, POS, Inbox, Buy Button,
  Google & YouTube and Shop.
- The storefront carries **exactly one** Meta pixel: the Meta app's own web
  pixel, registered with `{"pixel_id":"1540380063308828","pixel_type":
  "facebook_pixel"}`. Of the 7 web pixels installed, the other 6 belong to
  other vendors (Google, an A/B testing app, Shopify's own). There is **no**
  hardcoded theme pixel — no `connect.facebook.net` reference anywhere in the
  storefront HTML, and the dataset ID appears exactly once.

**This also explains "Integration: Multiple".** It is not two competing pixels.
It is one app delivering Purchase over two connection methods — browser pixel
for web checkouts, server/CAPI for everything else. The two are complementary,
not redundant: no web order produced both, which is why the totals add rather
than dedupe.

The one extra event (39 vs 38) is most likely a single un-deduplicated
browser/server pair. It is not an edge-of-window order: Shopify had **no orders
at all on 12 Aug**, and the four orders on 13–14 Jul fall before the retention
boundary where Meta reports zero Purchase events.

### Answer: YES — Meta already receives every order. Do not add a second stream.

Manual orders and draft orders are **already** reaching Meta as Purchase events
with a value and a Shopify order id. Building a second Purchase stream
(CAPI-BM or otherwise) on top of this would double-count roughly 55% of
revenue. The industry failure mode in backlog item D14 — the Shopify Meta app
firing draft orders as Purchase — is **confirmed present here**, but it is not
inflating anything: the events correspond to real paid orders, one per order.

What Meta lacks is not the revenue. It is the **link from a conversation or ad
to the order** — which is the `conversation → order` edge that remains broken
and is unaffected by anything in this document.

---

## The missing-value question

### What is established

- Over the trailing 28 days, all 39 Purchase events carry a `value` **key** and
  a `currency` key.
- Meta's own diagnostic `pixel_missing_param_in_events` currently reports
  **passed**.
- `event_processing_results` for Purchase returns no error or rejection rows —
  nothing is being dropped before it is counted.

### Why that does not close the question

`aggregation=custom_data_field` counts **whether the key was sent**, not
whether it held a usable number. Meta's warning is explicit that the offending
payload is an empty string:

> Purchase — 33% affected — Value field is missing. E.g. `""` isn't allowed.

An event sending `value: ""` has the key present and would be counted in the
39. So this aggregation can neither confirm nor refute the 33%. I state this
rather than claiming the problem is fixed.

Two further reasons the 33% may sit outside my view: the stats API retains only
28 days, and Events Manager diagnostics persist an issue after it stops
occurring, showing a "last received" date that can be well outside the chart's
range.

### The two candidate subsets

33% of 39 is 12.9. There are exactly two populations of 13 in this window, and
they are **disjoint**:

| Candidate | Orders | Value | If this is the affected set, Meta's total Purchase value for the window is |
|---|---:|---:|---:|
| Web checkout / the 13 BROWSER events | 13 | ฿92,250.00 | **฿136,788.00** |
| Shumabit app orders with no checkout object | 13 | ฿85,860.00 | **฿143,178.00** |
| *(control)* draft orders | 3 | ฿17,106.00 | ฿211,932.00 |
| *(control)* nothing is actually missing | — | — | ฿229,038.00 |

Both stay near a third across windows — over 60 days, web is 37.7% of orders
and Shumabit-no-checkout is 35.1% — so the stability of Meta's "33%" does not
discriminate between them either.

### Which is more likely, and why

**Shumabit orders with no checkout object** is the stronger candidate:

1. **The owner tested the browser path and it worked.** He confirmed via Meta's
   test tool that price and currency come through. That path is precisely the
   13 web checkouts, and it is the one population with a real checkout object
   to read a total from.
2. **Those 13 orders carry no identity or checkout context whatsoever** — 0 of
   13 have a customer record, an email, a phone, a shipping address, a billing
   address, a checkout id, a checkout token or a cart token. They are created
   directly through the Admin API. An integration that derives its Purchase
   payload from a checkout has nothing to read for these, and serialising a
   missing field is exactly how `""` reaches Meta.
3. It is consistent with Meta receiving a *server* event for them regardless —
   the event fires off the order, but the enrichment that fills `value` comes
   from a checkout that does not exist.

Against it: the integration could equally read `total_price` straight off the
order, in which case value would be fine and the 33% is purely historical. I
cannot choose between those two without the reads below.

**A ruled-out hypothesis**, recorded so it is not re-investigated: *custom line
items*. Every line item on all 38 orders carries both a `product_id` and a
`variant_id`, so no order is composed of untracked custom items.

---

## Separately confirmed, and genuinely live

These are current-state findings, not historical, and are independent of the
33% question:

1. **`pixel_has_low_event_source_match_rate` — FAILED.** Meta's own diagnostic:
   *"Some content_ids sent from pixel fires by this pixel do not match any
   catalog associated to the pixel."* This degrades dynamic product ads and
   catalog-based retargeting. It is the only failing check on the dataset.
2. **One Purchase event in 39 carries no `content_ids`, `content_type` or
   `num_items`** while still carrying value, currency and order_id.
3. **Zero-value orders.** 3 orders in the 28-day window and **7 in 60 days**
   have `total_price = 0.00` (#1582, #1587, #1592 from the Shumabit app;
   #1530, #1531, #1532, #1559 draft orders). Each of these produces a Purchase
   event worth ฿0. At 7 of 77 orders this is ~9% of Purchase volume and cannot
   by itself explain 33%, but it is real noise in Meta's optimisation signal
   and is fixable at source rather than at Meta.

---

## What to read from Events Manager

Three reads. The first is decisive on its own; the third is the cleanest
cross-check and takes a minute.

### Read 1 — the diagnostic itself (decisive)

Events Manager → Data sources → **cherry.cheap's pixel** → **Diagnostics** tab
→ the row *"Value field is missing"* on Purchase → **View details**.

Report:
- the **date range** the diagnostic covers, and any **"Last received" /
  "Last detected"** timestamp — this alone tells us whether the issue is
  current or historical;
- the **affected count and total** behind "33%" (e.g. "13 of 39");
- whether it names a **connection method** (Browser / Server) or an
  integration;
- any **sample event** shown — in particular `event_source_url`,
  `action_source`, and the literal `value` field.

### Read 2 — Purchase breakdown by connection method

Events Manager → **Overview**, date range **15 Jul – 11 Aug 2026** → click the
**Purchase** row → the detail panel → breakdown by **Connection method**.

Report the Browser and Server counts. **Prediction: 13 Browser, 26 Server.** If
that matches, my dataset reads and the Events Manager screen are confirmed to
be the same data and everything above holds. Also note the reporting
**timezone** shown on the page (the API returns +0800, the shop runs +0700).

### Read 3 — total Purchase conversion value (the discriminator)

Ads Manager (or the Purchase detail panel, if it shows a value total), date
range **15 Jul – 11 Aug 2026**, column **Purchases conversion value**, total
across all campaigns — including any purchases attributed outside ad campaigns
if the surface allows it.

Compare against the table above:

| If the reported total is ≈ | then |
|---|---|
| **฿229,038** | nothing is missing today; the 33% is historical — close it |
| **฿143,178** | the 13 Shumabit no-checkout orders are the affected set |
| **฿136,788** | the 13 web checkouts are the affected set |
| **฿211,932** | the 3 draft orders are the affected set |

The two live candidates are ~฿6,400 apart, so this needs the actual total
rather than a rounded one. Treat it as corroboration of Read 1, not a
replacement — Meta's attributed conversion value is filtered by attribution
window and ad association, so it can legitimately fall *below* every figure
above. If it does, Read 1 governs.

---

## What I could not establish

- **When the 33% occurred, or whether it is still occurring.** The stats API
  retains exactly 28 days. Everything before 2026-07-15 is unreachable from
  production.
- **Whether a `value` key that is present is also non-empty.** No available
  aggregation exposes field *contents*, only presence.
- **The identity of the 39th event.** Best explanation is one un-deduplicated
  browser/server pair; it is not an edge-of-window order.
- **Why Meta reports more match keys than Shopify holds** — Meta shows `email`
  on 32 of 39 Purchase events and name/address keys on 28, while only 18 of the
  38 Shopify orders carry an email and 20 carry any address. Automatic advanced
  matching in the browser is the likely source. Not pursued; it does not bear
  on either question.
- **The ฿2,774 of affected ad spend.** Not reachable without `ads_read`. For
  scale, it is ~1.2% of the ฿229,038 of order value in the same window.

---

## Recommended action

**Do not build any new Purchase event stream.** This is the single highest-value
decision in this document, and it is fully established by production data
rather than pending any further read. Meta already receives every Shopify
order — manual, draft and web — with a value and a Shopify order id. Any
CAPI-BM or server-side Purchase patch would double-count the ~55% of revenue
that the roadmap currently assumes is invisible.

Then, in order:

1. Take **Read 1** above. It is one screen and it either closes the 33% as
   historical or names the affected subset.
2. If the affected set turns out to be the Shumabit no-checkout orders, the fix
   belongs in **Shumabit's order creation**, not in Chatwoot and not in a new
   Meta integration — those 13 orders carry no identity of any kind, which is
   the same root cause already blocking `conversation → order` attribution
   (backlog D8). One change fixes both.
3. Independently of the 33%, fix the **catalog `content_ids` mismatch** — it is
   the only diagnostic Meta currently reports as failing.
4. Independently, stop emitting **฿0.00 orders** (7 in 60 days) as purchases.

Update `UMI-META-PLAN.md`: the "55% of revenue is invisible to Meta" framing and
the D14 double-count suspicion are both resolved by this document.

---

## Reproduction

All reads are read-only. Shopify goes through the existing `read_orders`
permission; Meta uses the stored Page token.

```ruby
# Shopify — orders in the Meta window, all statuses
hook   = Umi::Shopify::ClientFactory.hook_for(1)
client = Umi::Shopify::ClientFactory.client_for(hook)
client.get(path: 'orders', query: { status: 'any', limit: 250,
  created_at_min: '2026-07-15T00:00:00+07:00',
  created_at_max: '2026-08-11T23:59:59+07:00' })
# bucket on source_name, and within source_name == '325329387521'
# split on checkout_id.nil?

# Meta — Purchase events and field presence
tok = Channel::FacebookPage.first.page_access_token
# https://graph.facebook.com/v21.0/1540380063308828/stats
#   ?aggregation=event_total_counts|event_source|custom_data_field
#   &event=Purchase
#   &start_time=2026-07-15T00:00:00+0800
#   &end_time=2026-08-11T23:59:59+0800
#   &access_token=<tok>

# Meta — dataset diagnostics
# https://graph.facebook.com/v21.0/1540380063308828/da_checks?access_token=<tok>
```

Storefront pixel inventory: fetch `https://umi.store/` and parse the
`webPixelsConfigList` array inlined in the HTML.
