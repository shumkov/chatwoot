# UMI × Meta — Purchase event data quality

**Status:** Complete. Events Manager read back 2026-08-12; it holds no further
detail, so the remaining unknown is unprovable from outside Meta and is
resolved by experiment instead.
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

**2. Which Purchase events have bad price data?** The failure *mode* is now
established: **13 of the 39 events send a `value` field that is present but not
a usable positive number.** It is a live problem, not a historical one — Meta's
diagnostic covers 15 Jul – 11 Aug 2026, the identical window measured here. The
*identity* of those 13 is **not obtainable from outside Meta**: Events Manager
exposes no raw counts, no per-event sample and a blank Integration column. Two
candidate subsets of exactly 13 remain, and the way to choose between them is a
cheap change-and-watch experiment, not more Meta access.

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

## The price-data question

Meta's exact wording, from the Diagnostics tab:

> **Send higher-quality price data for more accurate ROAS calculation.**
> 33% of the price data received from **website Purchase events** have
> formatting issues or missing values. This may affect your ROAS calculation.

Detail dialog: Event name `Purchase` · % affected `33` · Issue details
*"Value field is missing / E.g. `""` isn't allowed"* · **Integration column
blank**. Guidance: value *"must be a numeric value that is greater than 0"*.
Dataset date range on screen: **15 Jul 2026 – 11 Aug 2026**. Affected ad spend
**฿2,774**.

### What is now established

**1. It is live, not historical, and it is about the events measured here.**
The diagnostic's window is exactly the window read from the API. That closes a
branch left open in the first draft of this document — "the 33% may predate the
28-day retention horizon" is now ruled out. The affected events are among the
39 counted above.

**2. The failure mode is a present-but-unusable value, not an absent field.**
`aggregation=custom_data_field` reports `value` on 39/39 events — but it also
reports `content_ids` on only **38/39**. That asymmetry proves the aggregation
*does* register genuine absence when it happens. So a field it counts as
present, which Meta simultaneously reports as failing, is present and
unusable: an empty string, a non-numeric string, or a number that is not
greater than 0.

**3. "Website Purchase events" does not narrow this to the browser.** Agreed
with the reading on the read-back. In Meta's taxonomy "website events" means
`action_source: website`, which spans pixel *and* Conversions API. The API
corroborates it directly: `aggregation=url&event=Purchase` returns
`https://umi.store/` for 28 of 39 events — more than the 13 BROWSER events — so
server-side events are carrying a website source URL too and sit in the same
bucket. Diagnostics action 2 ("you saw 11.8% more conversions by using the
Conversions API alongside the Meta pixel") sits under the same heading, which
would make no sense if the heading excluded CAPI.

**4. The blank Integration column is itself consistent with the architecture
finding.** Meta has no single integration to name because both connection
methods originate from the *same* Shopify app (`2329312`). It is not evidence
of a mystery third source.

### The third candidate, costed: zero and malformed values

Meta's rule is that value must be numeric **and greater than 0**, which makes a
฿0.00 order a violation by definition. This was worth costing properly, and it
had not been measured before. Result, for the exact diagnostic window:

| Population | Orders | % of 39 events |
|---|---:|---:|
| `total_price == 0.00` | 3 (#1582, #1587, #1592 — all Shumabit-with-checkout) | 7.7% |
| plus cancelled/refunded to zero | +1 (#1574 — Shumabit-no-checkout, refunded to ฿0.00) | — |
| **all values ≤ 0** | **4** | **10.3%** |

Everything else is a clean positive decimal. No test orders, no multi-currency,
one `pending` order, no other refunds.

**So zero-value orders cannot explain 33% on their own — 10.3% is a third of
the way there.** They are certainly *a* violation by Meta's stated rule, and
fixing them is unambiguously correct, but they are at most a subset of the
affected 13.

### The tension this creates — and why it is useful

If Meta *is* counting the ฿0 orders as violations, then neither clean 13-set
can be the whole answer, because the zeros do not sit inside either of them
cleanly:

| Hypothesis | Affected count | % of 39 |
|---|---:|---:|
| Web checkouts (13) **+** the 4 zero/refunded orders (all non-web) | 17 | 43.6% |
| Shumabit-no-checkout (13, already contains #1574) **+** the 3 other zeros | 16 | 41.0% |
| Web checkouts alone | 13 | **33.3%** |
| Shumabit-no-checkout alone | 13 | **33.3%** |

Only the clean 13-sets land on 33%. The most economical reading is therefore
that **Meta is not counting the ฿0.00 orders** — either it does not receive a
Purchase event for them, or it does not flag a zero as a formatting issue
despite the guidance text — and that the affected population is one of the two
13-order subsets.

That is an inference from arithmetic, not a proof. Its value is that it makes
the experiment below *diagnostic either way*.

### The two candidate subsets

33% of 39 is 12.9. There are exactly two populations of 13, and they are
**disjoint**:

| Candidate | Orders | Value | Under UMI's control? |
|---|---:|---:|---|
| Web checkout / the 13 BROWSER events | 13 | ฿92,250.00 | **No** — Meta's app on Shopify's checkout |
| Shumabit app orders with no checkout object | 13 | ฿85,860.00 | **Yes** — UMI writes these orders |

Both stay near a third across windows — over 60 days web is 37.7% of orders and
Shumabit-no-checkout is 35.1% — so the stability of the "33%" does not
discriminate either.

**Shumabit-no-checkout remains the stronger candidate.** The owner tested the
browser path and saw price and currency arrive correctly, and web checkouts are
the one population with a real checkout object to read a total from. Those 13
Shumabit orders, by contrast, carry no identity or checkout context whatsoever
— 0 of 13 have a customer record, email, phone, shipping address, billing
address, checkout id, checkout token or cart token. An integration deriving its
payload from a checkout has nothing to read, and serialising a missing field is
exactly how `""` reaches Meta.

It also happens to be the candidate UMI can actually fix. If the answer is the
web path instead, there is no hand-fix available anyway — the remedy would be
reconfiguring or reinstalling Meta's Shopify app.

**A ruled-out hypothesis**, recorded so it is not re-investigated: *custom line
items*. Every line item on all 38 orders carries both a `product_id` and a
`variant_id`, so no order is composed of untracked custom items.

---

## Separately confirmed, and genuinely live

Current-state findings. The first two are independent of the 33% question; the
third is a strict subset of it.

1. **`pixel_has_low_event_source_match_rate` — FAILED.** Meta's own diagnostic:
   *"Some content_ids sent from pixel fires by this pixel do not match any
   catalog associated to the pixel."* This degrades dynamic product ads and
   catalog-based retargeting. It is the only failing check on the dataset.
2. **One Purchase event in 39 carries no `content_ids`, `content_type` or
   `num_items`** while still carrying value, currency and order_id.
3. **Zero-value orders.** 3 orders in the 28-day window and **7 in 60 days**
   have `total_price = 0.00` (#1582, #1587, #1592 from the Shumabit app;
   #1530, #1531, #1532, #1559 draft orders), plus #1574 which was cancelled and
   refunded to ฿0.00 — 4 in the window once refunds are counted. Each produces
   a Purchase event worth ฿0, which Meta's own rule ("greater than 0") makes a
   violation by definition. See
   [the third candidate](#the-third-candidate-costed-zero-and-malformed-values):
   at 10.3% of events it cannot by itself explain 33%, but it is real noise in
   Meta's optimisation signal and is fixable at source rather than at Meta.

---

## Why no further Meta read will settle this

Events Manager was checked on 2026-08-12 across the Overview action dialog and
the Actions/Diagnostics tab. It exposes **no raw counts, no date range beyond
the dataset-level one, no sample event, and a blank Integration column**. The
guidance text is generic. There is no screen that names the affected subset.

Nor can the API supply it: no `aggregation` exposes field *contents*, only
presence, and the dataset's detail fields need `ads_read`, which the stored
Page token does not carry. The `da_checks` edge is actively misleading here —
it reports `pixel_missing_param_in_events` as **passed** while the UI reports
the 33% price-data issue. The two surfaces are running different checks, so the
API's "passed" is not evidence the problem is absent, and `da_checks` cannot be
used to track whether the experiment below worked. Read the percentage off the
Diagnostics tab instead. A conversion-value cross-check via Ads Manager was
considered and rejected — attributed conversion value is filtered by
attribution window and ad association, so it can legitimately fall below every
candidate figure and would not discriminate.

**The identity of the affected 13 is therefore unprovable from outside Meta.**
The decision below does not depend on obtaining it.

---

## The experiment: change what we control, watch the number

The diagnostic recomputes over a rolling 28-day window, so the percentage moves
on its own within about four weeks of a change. That makes the number on screen
a free instrument. Two changes, both correct on their own merits, both entirely
within UMI's control:

**Change A — stop emitting ฿0.00 purchases.** 4 of 39 events in the window
(10.3%); 7 of 77 orders over 60 days. A ฿0.00 purchase is a violation of Meta's
stated rule whatever else is true, and it is noise in the optimiser regardless
of the 33%.

**Change B — put an explicit numeric total on Shumabit's Admin-API orders**, and
give them the customer/address identity they currently lack entirely. This is
the leading candidate for the remaining ~9–13 events.

Then read the one number off the Diagnostics tab four weeks later. Every
outcome is informative:

| After the change, % affected | Reading |
|---|---|
| 33% → **~23%** | The ฿0.00 orders were being counted. The remaining ~9 events are a separate subset; re-open with that much smaller target. |
| 33% → **~0%** | Change B hit it. The Shumabit no-checkout payload was the cause. Done. |
| 33% → **unchanged at 33%** | Neither zeros nor the Shumabit payload are counted. By elimination the affected set is the **web-checkout / browser path** — which is Meta's own app on Shopify's checkout, so the remedy is to reconnect or reconfigure the Facebook & Instagram sales channel, not to write code. |

The third row is the reason this is worth doing even though Change B is a
guess: a null result *is* the answer, because only two candidates exist and
they are disjoint. Ruling one out selects the other.

Cost of being wrong: both changes are correct independently of the diagnostic,
so neither is wasted work if it fails to move the number.

---

## Established vs unprovable — plainly

**Established from production data:**

1. Meta receives a Purchase event for **every** Shopify order, not just web
   checkouts (39 events vs 38 orders; web alone was 13).
2. The BROWSER/SERVER split is 13/26 and maps exactly onto web / non-web
   orders. `order_id` is on 39/39 events.
3. "Integration: Multiple" is one Shopify app on two connection methods, not
   two pixels. Confirmed by storefront inspection: exactly one Meta pixel, no
   hardcoded theme pixel. Meta's own diagnostics action 2 describes pixel and
   CAPI as complementary here.
4. The price-data issue is **live and inside the measured window** (15 Jul –
   11 Aug 2026), not historical.
5. The failure mode is a **present-but-unusable** `value`, not an omitted
   field, inferred from `value` 39/39 against `content_ids` 38/39.
6. **4 of 39 events (10.3%) carry a value of ≤ 0** and violate Meta's rule by
   definition. This is a real defect and a strict subset of the problem.
7. Zero-value orders **cannot** account for 33% on their own.
8. Only two disjoint 13-order subsets land on 33.3%, and one of them — the web
   checkout path — is not under UMI's control.

**Unprovable from outside Meta:**

1. **Which 13 events are affected.** No UI surface and no API aggregation
   exposes it.
2. **The literal payload Meta received.** No sample event is obtainable.
3. **Whether Meta counts a ฿0.00 order as a violation.** The guidance text says
   it should; the arithmetic suggests it does not. Change A settles it.
4. **Anything before 2026-07-15.** Hard 28-day retention.
5. **The ฿2,774 of affected ad spend** as a share of anything. Not reachable
   without `ads_read`; for scale it is ~1.2% of the ฿229,038 of order value in
   the same window.
6. **The identity of the 39th event.** Best explanation is one un-deduplicated
   browser/server pair; it is not an edge-of-window order — Shopify had no
   orders at all on 12 Aug.
7. **Why Meta reports more match keys than Shopify holds** (`email` on 32 of 39
   events vs 18 of 38 orders). Automatic advanced matching is the likely
   source. Not pursued; it bears on neither question.

---

## Recommended action

**Do not build any new Purchase event stream.** This is the single highest-value
decision in this document, it is fully established by production data, and it
does not wait on anything. Meta already receives every Shopify order — manual,
draft and web — with a value and a Shopify order id. Any CAPI-BM or server-side
Purchase patch would double-count the ~55% of revenue the roadmap currently
assumes is invisible.

Then, in order:

1. **Run the experiment above.** Fix the ฿0.00 orders and the Shumabit payload,
   wait four weeks, read the percentage. Do not seek more Meta access first —
   there is none to be had.
2. If it turns out to be the Shumabit orders, the fix belongs in **Shumabit's
   order creation**, not in Chatwoot and not in a new Meta integration. Those
   13 orders carry no identity of any kind, which is the same root cause
   already blocking `conversation → order` attribution (backlog D8) — one
   change fixes both, which is the strongest argument for doing it regardless
   of the diagnostic.
3. Independently, fix the **catalog `content_ids` mismatch**. It is the only
   check Meta currently reports as *failing*, and it is unrelated to price
   data.

Update `UMI-META-PLAN.md`: the "55% of revenue is invisible to Meta" framing and
the D14 double-count suspicion are both resolved by this document. The
open-question "the missing price data — nobody owns it" should be rewritten as
a bounded experiment rather than a blocked investigation.

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
