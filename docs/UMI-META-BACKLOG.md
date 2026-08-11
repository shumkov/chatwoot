# UMI Meta integration — backlog

Everything surfaced while shipping the FB/IG profile refresher (UMI patches
18/19), 2026-08-06 → 08. Findings come from production Graph probes, four code
review agents, three research agents, and a Business Suite inspection.

**Owner column:** `meta` = configuration in Meta's UI, no code. `code` = a fork
patch. `ops` = a production run.

---

## A. Meta-side configuration

| # | Item | Owner | Why it matters |
|---|---|---|---|
| ~~A1~~ | ~~**Dataset bound to the wrong Facebook Page.**~~ **DONE 2026-08-08.** `410440105481992` turned out not to be a Facebook Page at all — it was the Instagram-backed shadow object (category `Profile`, link `instagram.com/_u/umi.asia`, 0 followers). So the dataset was linked to Instagram *twice* and to Facebook *zero* times, which is exactly why Instagram worked and Messenger did not. Fixed via Events Manager → Connect data → **Messaging** → Facebook Page → UMI clothing, merged into the existing `cherry.cheap's pixel` (irreversible; approved because Instagram + web were already merged there). Verified independently: `GET /516819784857962/dataset` → `[{"id":"1540380063308828"}]`, previously `[]`. | meta | Unblocks D4. Note this makes Facebook **eligible**; it does not start any data flowing — the dataset still carries website events only. |
| A2 | **Dataset named after another brand.** Confirm it is not shared with an unrelated business. | meta | Data hygiene; possible cross-business leakage. |
| A3 | **`messaging_referrals` not subscribed.** Page subscribes to 6 fields; this is not one. | meta + code | No ad attribution reaches Chatwoot. Note `Channel::FacebookPage#subscribe` runs `after_create_commit` only — editing the code list will NOT re-subscribe the live page. |
| A4 | **Catalogue issues — scope corrected 2026-08-08.** The Commerce Manager summary ("17 rejected, 98 issues") overstates it. Actual API breakdown of all 228 items: `PRODUCT_OUT_OF_STOCK` 98, `PRODUCT_NOT_APPROVED` 17, `product_item_not_visible` 1. The 98 are **sold-out sizes** — inventory, not a defect; Meta correctly excludes them from dynamic ads. The 17 rejections are **three lingerie products only**: Invisible Thongs Aura (7 variants), Bralette Pure (6), Thongs Lure (4), all on the adult-content advertising policy. | meta | Much smaller than first assessed. Options for the three: request a second review, reshoot as flat-lay/product-only rather than on-body (usually what clears it), or accept. Only investigate the out-of-stock set if those sizes are believed in stock in Shopify — that would indicate the Flexify sync is misreporting inventory. |
| A5 | **฿4,088 ad spend affected by low data quality**; "send higher-quality price data" flagged high priority. | meta | Direct spend waste; degrades ROAS attribution. |
| A6 | **Duplicate ad-click flow — confirmed customer-visible 2026-08-08.** Not just the Instant Reply: the *entire* sequence duplicates. In thread `…65882840` the greeting fired 6× in 3 seconds; in May Tha Zin Phu's thread both the `replied to an ad` event **and** the welcome message appear twice, rendered as delivered blue bubbles. | meta | Customers receive the same greeting two or more times. Likely retires with D1 if the Meta-side automation is switched off. |
| ~~A7~~ | ~~**Unidentified writer posting "Lead stage set to Qualified".**~~ **ANSWERED 2026-08-08.** It is Meta Business Suite **Leads Centre**, partly automated ("Auto-label added: Lead stage set to intake"), tracking an intake → Qualified → Lost pipeline. Context shows these are **recruitment** ads, not product ads ("we're looking for an E-Commerce Shop Administrator in Phuket"). **Not delivered to customers — CONFIRMED 2026-08-10 in Meta's own words.** The `Lead reminder` automation's action reads: *"Add an admin message to the chat (only visible to you). This will mark the message as unread to highlight it and prompt a response."* Customers never saw "Lead stage set to Lost". (Earlier inference via the identically-shaped `"X replied to an ad."` system line was correct.) | — | Closed. |
| ~~A9~~ | ~~**Meta AI "Business Agent" is replying to customers."**~~ **ANSWERED 2026-08-08 — it is NOT enabled.** The toolbar control leads to `business_ai/ai_onboarding` showing "Preparing your Business Agent…" with a setup progress bar, i.e. a first-run wizard that has never been completed. The "AI responding / AI transferred" popup was Meta advertising the feature, not reporting use. Corroborated by message data: every Meta-side outbound message over 14 days is accounted for (ad system lines, ad welcome message, Instant Reply, Leads Centre notes) — no AI-shaped conversation, and recon would have surfaced one. The onboarding wizard was deliberately **not** completed. | — | **Keep as a standing caution, not a task.** If Business Agent is ever switched on, per B4 Chatwoot will see **none** of it and agents will inherit threads mid-conversation with no history. Decide deliberately; do not enable from a promotional banner. |
| **A10** | **Click-to-Messenger ads include recruitment campaigns**, not only product ads. | meta | Changes D2: captured ad attribution will need to separate hiring conversations from sales, and they likely want different routing/handling in Chatwoot. |
| A8 | **Native checkout cannot be enabled — and should not be.** `payment_setup: NOT_SETUP`, `payment_provider: OFFSITE_LINK`. | — | Thailand was never eligible; Meta retires native checkout globally March 2026. `OFFSITE_LINK` is the intended end state. **Close as won't-do.** |

## B. Fork defects (open)

| # | Item | Owner | Why it matters |
|---|---|---|---|
| B1 | **`HUMAN_AGENT` patch is a silent no-op.** `zz_umi_facebook_fix.rb` sets the ENV, but `InstallationConfig` row 26 (`false`, 2026-06-12) wins in `GlobalConfigService.load`. Sends `messaging_type: RESPONSE`. | code/ops | Patch #1 documents behaviour that is not happening. Harmless today (0 send failures in 30 days). Either delete the row or drop that half of the patch. |
| B2 | **Graph version unpinned on one path.** `instagram/messenger/send_on_instagram_service.rb:17` hardcodes `v11.0`; the fork pins the gem to v21.0. | code | Works only because Meta auto-upgrades retired versions. |
| B3 | ~~**Recon detects outbound misses but never heals them.**~~ **CLOSED — will not build (2026-08-11).** Specced, reviewed and measured against production; the premise failed. See `docs/UMI-FBIG-OUTBOUND-HEAL-SPEC.md` r2. | — | Four disqualifying findings: (1) the **quick-reply menu is not recoverable** — it's button metadata, absent from Meta's message edge *and* unhandled by Chatwoot's builders, so the headline benefit doesn't exist; (2) **Instagram has no outbound gap at all** (71 page-sent human messages present, 0 missing) so the 74% platform gains nothing; (3) a healed outbound echo satisfies `human_response?`, nulling `waiting_since` and setting `first_reply_created_at` — which **removes dying ad threads from the Unattended folder**, the opposite of the intent; (4) the `direction=out` population is **not homogeneous** — it mixes Meta Business Suite internal notes ("Lead stage set to Qualified", "X assigned this conversation to Y") with real agent replies, and 10 of 25 already exist in Chatwoot under a different `source_id`. Also: "34 in 14 days" was **double-counted** (the recon spec forbids summing daily windowed counts; 34 = 2 × 17), and nightly cron latency (~12 h median) is the wrong class for an agent-assist need. Superseded by D2. |
| B4 | **Meta never echoes its own automations.** Established empirically: 17 Meta-generated messages → 0 in Chatwoot; 7 Chatwoot-sent → 7. Not a subscription, standby, or filter issue. | — | Architectural. Fix is B3 (backfill) or D3 (own the greeting), not a webhook change. |

## C. Shipped 2026-08-06/08

- FB/IG profile refresher: 155 contacts renamed, 73 avatars attached, 0 real
  names overwritten. Placeholder shapes 156 → 1.
- Live-path Instagram naming — stops new Haikunator contacts at the source.
- Shopify redact erasure gap: avatar and handle survived erasure, and the live
  path restored the handle on the customer's next message. Both closed.
- Two silent-failure bugs caught in review: `jsonb_set` cannot create
  intermediate objects, and `ApplicationRecord` caps `:string` at 255 while
  Meta CDN URLs run 350–600.

## D. Improvements discussed, not built

| # | Item | Owner | Notes |
|---|---|---|---|
| D1 | **Auto-reply owned by Chatwoot.** Enable the inbox greeting; `greeting_enabled` is currently false. | ops | No code. Template messages verified to deliver to Meta (`base/send_on_channel_service.rb:44`). Do this BEFORE switching Meta's off, or customers hit silence. |
| D2 | **Capture ad attribution** into conversation custom attributes + an ad-context card. | code | Mirrors the accepted upstream pattern for WhatsApp (`whatsapp/incoming_message_base_service.rb:178`; chatwoot#13995 / PR #14681). Decided: attribution as **data**, not per-ad reply branching. |
| D3 | **Partner-app welcome message flow.** `POST /PAGE_ID/welcome_message_flows`, then Ads Manager → Message Template → Partner app. | code + meta | The industry answer (ManyChat, ChatBot.com, SendPulse, Chatfuel). Meta requires *a* welcome message — there is no "none" — but it can be **yours**, and you then render it from your own copy. Constraints: Engagement/Sales objectives, flow immutable while an ad is live, first message text + ≥1 quick reply, no personalisation variables. |
| D4 | **Conversions API for business messaging.** `action_source: business_messaging`, joins on `page_id`+PSID / `ig_business_account_id`+`ig_sid` — all already stored by Chatwoot. | code | **Depends on A1.** Also needs `instagram_manage_events` (not currently granted; `page_events` is). |
| D5 | **Working hours misconfigured.** Inbox timezone UTC, 09:00–17:00 Mon–Fri = 16:00–24:00 Bangkok. `working_hours_enabled` false. | ops | Must be fixed before relying on out-of-office replies. |
| **D6** | **Port Meta Business Suite automations into Chatwoot.** Chatwoot side: 27 well-designed labels (`lead-*`, `intent-*`, `support-*`, `value-*`, `source-*`) but only **one** automation rule (tag new conversations `lead-new`), **zero** canned responses, and only 2 of 27 labels in use (`lead-new` 31, `spam` 3). **Meta side inventory captured 2026-08-10** at `/latest/inbox/automated_responses` (note: `automated_responses`, not `automations`): `Leads` (Create activity, **OFF**), `Lead reminder` (**ON**), `Leads – Lost leads` (**ON**), `Leads – Booked leads` (**ON**), `Leads – Ordered leads` (**ON**), `Leads – Responsive leads` (**ON**), `Questions and responses` (Share information, **OFF**), `Away message` (Greet people — **disabled by user 2026-08-10** in favour of the Chatwoot greeting). All the ON ones run on Messenger **and** Instagram. | code + ops | Five lead automations on Meta vs one rule in Chatwoot. `lead-lost`/`lead-converted`/`lead-qualified` labels exist but nothing drives them; **no label exists for Booked or Ordered**. `source-paid-ads` is blocked on D2. Deserves research → spec → review. |
| | **Captured conditions (2026-08-10).** `Lead reminder`: lead → *Qualified*, then **12h** inactive → internal admin note (invisible to customer) + mark unread, optional follow-up flag. `Leads – Lost leads`: lead in *Intake* with **7 days** no messages → set stage **Lost**. `Leads – Booked leads`: booking accepted or order marked "Booked" → set stage **Qualified/Converted** + matching label. **Not yet captured:** `Ordered leads`, `Responsive leads` (Meta's Edit links only respond to the first click after a full page load, then go inert). | | |
| | **BLOCKER for D6 — Chatwoot has no time-based automation trigger.** `AutomationRuleListener` supports only `conversation_created`, `conversation_updated`, `conversation_opened`, `conversation_resolved`, `message_created`. Two of the five Meta automations are purely time-based (7-day inactivity → Lost; 12h inactivity → reminder) and **cannot be expressed with stock rules**. Options: Chatwoot **SLA policies** (time-based breach handling already exists, see `lib/tasks/apply_sla.rake`), or a UMI scheduled job in the same shape as the profile refresher. | code | Decide this before writing the spec — it determines whether D6 is configuration or a patch. |
| | **Second design question:** `Booked` and `Ordered` are driven by order/booking status held in Meta's Leads Centre. Chatwoot has no such source of truth, so porting them means deciding what signals "an order was placed" — realistically Shopify, via the existing `Umi::Shopify::` services. Not a mechanical translation. | code | Also note `lead-converted` exists as a label but there is **no label for Booked or Ordered**. |
| **D7** | **Ad conversations are unreadable to agents — likely the real cause of "ad customers never reply".** Measured 2026-08-10: 38 of 50 Messenger threads originate from an ad, and customers *do* respond. But on **product** ads the response is almost always a **quick-reply button tap** ("1. สนใจรับส่วนลด 10%", "3. ขอแนะนำสินค้าขายดีของ UMI") and then silence. The menu those options belong to is sent by Meta and is **invisible in Chatwoot** (B4), so the agent sees a bare, context-free "3. …" and cannot reply meaningfully. **Recruitment** ads, by contrast, produce long engaged threads (9–19 customer messages). | code | Fixed by D2 (ad context card) + B3 (backfill the invisible auto-replies) — not by anything on the sending side. |

## Verified non-issues

- **Outbound delivery is healthy.** 621 outgoing messages over 60 days:
  510 delivered, 88 sent, 22 read, **1 failed**. Separately, 220/225 Chatwoot
  messages resolved successfully against Meta (the other 5 were deleted by the
  customer). Messages are reaching people.
- **The 24-hour messaging window is not biting.** Only 4 agent replies went out
  later than 24h in 60 days, and 3 of those are the internal test conversation.
  So B1 (`HUMAN_AGENT` no-op) is currently harmless in practice — worth fixing
  for correctness, not urgency.

| **D9** | **Instagram purchase optimisation does not exist — but the exclusion is narrower than r1 stated.** Meta's CAPI-BM docs restrict *optimization*, not ingestion: Instagram **is** a listed CAPI-BM channel (`messaging_channel: "instagram"` + `instagram_business_account_id` + `ig_sid`) and all 14 event types incl. `Purchase` are accepted. Meta's help pages say purchases from IG click-to-chat ads **are reported** in Ads Manager. What's missing is the *bidder*: the click-to-Instagram Marketing API goal list (`OUTCOME_SALES`) offers `CONVERSATIONS`, `OFFSITE_CONVERSIONS`, `LINK_CLICKS`, `IMPRESSIONS`, `REACH` — **no `PURCHASE` goal**. | — | **Revised.** Sending IG Purchase events buys **measurement and ROAS truth**, which is worth having. Two documented levers to check in Ads Manager: (a) placement ≠ destination — a *Messenger*-destination ad can be served on Instagram and keeps full purchase optimisation; (b) eligibility may spill over — a Meta course states that once eligible for purchase optimisation on Messenger you can use *"Messenger and Instagram as destinations"*, gated on ≥10 purchase events / 30 days. **Caveat: that line was read in the Thai locale; the English original is login-walled. Verify before building on it.** |
| **D10** | **Volume is below the learning-phase comfort zone — but clears Meta's documented eligibility bars.** 60-day actuals: 29 web + 10 draft + 40 manual/API orders, ฿450,688. That is ~19.5 purchases/30 days and ~4.5/week. | — | **Revised.** The ~50/ad-set/week figure is a *learning-phase* guideline for website conversion campaigns, not an eligibility gate. Meta's documented messaging thresholds are far lower: **≥10 purchase events / 30 days** for messaging purchase optimisation (UMI clears this) and **>5 lead events / 30 days** for Messenger lead optimisation. But at 4.5 purchases/week a purchase-optimised ad set stays perpetually in learning. ~85 conversations/week sails past 50. **Playbook: optimise on `CONVERSATIONS` or a `QualifiedLead` proxy; send `Purchase` for measurement, not for the bidder.** |
| **D13** | **`referral` on the first inbound message is a deterministic ad→conversation join — for Instagram too.** The IG messaging webhook delivers `{ref, ad_id, source: "ADS", type: "OPEN_THREAD", ads_context_data: {ad_title, photo_url, video_url}}` on the first message of an ad-originated thread. `ref` is an **arbitrary string set per ad**, so campaign/adset/creative can be encoded directly. | code | **Promoted to top priority.** This is Instagram's `ctwa_clid` equivalent and it eliminates the identifier-capture problem for the attribution half: ~100% of ad-originated chats, no cooperation from the customer needed. Strictly better than B3's `"replied to an ad."` text marker (carries the ad id, not just a marker; no historical writes; covers IG). This is `docs/UMI-FBIG-AD-ATTRIBUTION-SPEC.md`, previously descoped and deferred. |
| **D14** | **Possible existing double-count: Shopify draft orders firing as web `Purchase` events.** Meta support confirmed (Feb 2025, Shopify community) that with the official Meta app *"CAPI will share Draft Orders and tracking them as purchases"*; one merchant saw 27 Meta-reported conversions against 7 actual payments. | check | **Audit before adding any CAPI-BM stream.** If UMI's Shopify→Meta app already emits DM revenue as unattributed web Purchases, a second stream double-counts. Dedupe on `event_id` or suppress one source. |
| **D15** | **Deterministic conversation→order join, both directions.** Shopify order attribution flows through **cart permalinks with `attributes[...]`** (`/cart/{variant}:{qty}?attributes[conv]={conversation_id}`) and through **`sourceName` on Admin-API-created orders** — so agent-created orders can carry the conversation id natively. | code | Pairs with D13 to close the loop: D13 gives ad→conversation, this gives conversation→order. Industry confidence ranking puts *unique code redeemed* at ~100% and *phone matches a subscriber profile* at 40–60% — **the 40–60% row is the signal UMI relies on today, which is why the measured match was 0/29.** |
| **D11** | **Agent-side contact linking is broken.** `Api::V1::Accounts::ContactsController#update` does a bare `assign_attributes` + `save!` and never calls `ContactIdentifyAction` (which is wired only to widget/public-inbox controllers). With the `uniq_email_per_account_contact` index, an agent typing a customer's email onto a Meta contact **422s** whenever a synced Shopify contact already owns it. | code | Blocks *every* manual identity-resolution path. Fix before any capture work, or the captured identifier cannot be written. |
| **D12** | **Free deterministic win: draft-order invoice tokens.** Verified: order #1583's `landing_site` contains the exact `/invoices/<token>` an agent pastes into the DM. Scan outbound inbox-2 messages for the token, join to orders. | code | ~100% precision, **no new scopes, no behaviour change**. Covers the draft-order flow only (10/79 orders, 9.6% of revenue). Note `read_all_orders` is needed to match history beyond 60 days. |
| **D8** | **Identity resolution: link Shopify customers to Meta conversations.** **Research complete 2026-08-11.** Merging is a **red herring** — 45 emails typed in DMs matched an existing contact and **45/45 already carried `shopify_customer_id`**; the join is 100% reliable, acquisition is the bottleneck. Decisive negative result: **0 of 29 web orders** matched any email/phone ever typed in a DM, because **55% of revenue never touches web checkout** — DM sales close inside the DM via manual orders and draft-order invoices with PromptPay QR. Baseline identifier capture without prompting: 12.4% all-time, 5.8% last 180d. | Measured 2026-08-11: 795 contacts carry a `shopify_customer_id`, and **0 of them are Meta DM contacts** — the two populations are completely disjoint, because Shopify matches on email/phone and Meta DM contacts have neither. **This is the critical path for D4**: without an order↔conversation link there is no `Purchase` event to send, and purchase optimisation cannot work. | code + product | Needs research on options (contact merge, in-chat email/phone capture, per-conversation discount codes, checkout ref params, agent-side manual linking). Note Chatwoot has `ContactMergeAction`, and `ContactInboxWithContactBuilder#find_contact` already matches on email/phone/identifier — so the mechanism partly exists; the missing piece is *acquiring* an identifier during a Meta conversation. |

## Why the Meta-side loop was already broken

Verified in Leads Centre 2026-08-11: **Intake 30, Qualified 12, Converted 0** —
"Converted leads: --", "Conversion rate: --". Meta has **never** received a
conversion signal from messaging, and this is structural rather than neglect:
the `Booked`/`Ordered` automations trigger on orders created *inside Meta*, but
UMI sells through Shopify with website checkout (`OFFSITE_LINK`, the only model
available in Thailand). Orders never happen in Meta, so those automations can
never fire, so nothing ever reaches Converted.

Consequences for planning:

- Porting to Chatwoot **loses nothing** on the purchase side; there is nothing
  there to lose.
- Feeding real `Purchase` events via D4 would give Meta a signal it has never
  had — an improvement, not a restoration.
- **Intake and Qualified do work** (30 / 12) and are worth replicating;
  Booked/Ordered should be dropped rather than ported.
- Leads Centre tags every lead **Paid** or **Organic** — the ad attribution
  already exists on Meta's side and is exactly what `source-paid-ads` wants.
  It is trapped there until D2.

## E. Accepted limits — not bugs

- **121 Instagram contacts can never receive an avatar.** Profile API denies
  with error 230; participants, message `from`, and `/{id}/picture` all carry
  no picture field (five routes tested). This is the floor.
- **Contact `1960` ("Facebook user")** — Meta refuses the lookup outright.
- **Recurring refresher has no measured benefit in steady state.** Handle churn
  is 0/60; avatar replacement is out of scope. Retained by decision
  2026-08-06; the case against is recorded in
  `docs/UMI-FBIG-PROFILE-REFRESH-SPEC.md` §7.

## Suggested order

1. ~~**A1**~~ — **done 2026-08-08**, verified. Unblocked D4.
2. ~~**A4**~~ — **diagnosed 2026-08-08**, scope far smaller than assumed. Three
   lingerie products on the adult-content policy; the rest is inventory.
   Remaining action is a business decision (appeal / reshoot / accept), not
   engineering.
3. ~~**D1**~~ — **done 2026-08-10.** Chatwoot greeting enabled; Meta's Away
   message switched off by the user. Retires **A6**.
4. ~~**B3**~~ — **closed 2026-08-11, will not build.** Promoted to the top on
   2026-08-10, specced, reviewed, and measured against production — the premise
   did not survive. The menu agents are missing is quick-reply *button
   metadata*, absent from Meta's message edge and unhandled by Chatwoot's
   builders; Instagram has no outbound gap at all; and the write would drop
   dying ad threads out of the Unattended folder. Full post-mortem in
   `docs/UMI-FBIG-OUTBOUND-HEAL-SPEC.md` r2.
5. **D13** — capture `referral` (`ad_id` + per-ad `ref`) on the first inbound
   message. **Now the top code item.** Deterministic, covers Instagram, no
   historical writes, and it is what actually addresses **D7** — the agent gets
   *which ad* with title and creative, at conversation-creation latency rather
   than nightly. This is the previously-descoped
   `docs/UMI-FBIG-AD-ATTRIBUTION-SPEC.md`, which should now be re-scoped
   upward rather than kept minimal.
6. **D8/D15** — identity resolution, now with a documented mechanism:
   `attributes[conv]` on cart permalinks and `sourceName` on Admin-API orders,
   rather than hoping an email or phone gets typed into the DM (measured 0/29).
7. **D3/D4/D6** — the larger pieces, once the above are settled.

## Revised strategy after the D8 research (2026-08-11)

The original goal — send `Purchase` events so Meta optimises ads on revenue —
does not survive contact with the data. Two hard constraints (**D9**, **D10**)
mean purchase optimisation can apply only to the Messenger quarter of the
audience, at a volume an order of magnitude below Meta's learning threshold.

What to do instead, in order:

1. **D11** — fix the agent-side contact update, or no manual linking works at
   all.
2. **D2 (descoped)** — capture referrals, so any event sent can be validated
   against the ad it came from.
3. **D12** — retroactive invoice-token matching: free, deterministic, no new
   scopes.
4. **Close DM sales from Chatwoot** — a sidebar action creating the Shopify
   draft order and sending the invoice link. This is where the money actually
   is (55% of revenue never reaches web checkout, and agents already do this by
   hand). Needs `write_draft_orders` — an OAuth reconnect, same pattern as
   patch #3.
5. **Send a proxy event, not Purchase** — `QualifiedLead`/`InitiateCheckout`
   on the **Messenger** slice. Treat `Purchase` as reporting, not optimisation.

**Strategic option worth a separate decision:** move acquisition ads to
**click-to-WhatsApp**. Meta explicitly supports purchase optimisation there,
`ctwa_clid` is a deterministic click id, and the page token already holds
`whatsapp_business_manage_events`. That converts a probabilistic attribution
problem into a deterministic one — but it is a channel-strategy bet (current
WhatsApp volume is ~14 conversations), not a patch.

**Also found:** `source_name` is never `instagram`/`facebook` on any order —
Meta's Shopify sales channel produces zero orders here, which is the same root
cause as the empty Leads Centre "Converted" stage.

**Correction of record (2026-08-11):** D2 was previously ranked as the fix for
D7. That was wrong — this document's own D7 row says "D2 **+ B3**", and the
`+ B3` was dropped when the spec was drafted. Two review rounds established
that D2's three user-visible outcomes (agent sees the ad; label gets applied;
subscription starts delivering) each fail for a different verified reason, all
silently, in an install with no exception tracker.

## Method note

Two findings so far came from Meta's *summary* UI being misleading, and both
were corrected only by querying the Graph API directly:

- A1 looked like "dataset on the wrong Page"; it was actually "linked to
  Instagram twice, Facebook never" — the second "Page" was an
  Instagram-backed shadow object.
- A4 looked like "98 broken products"; it was 98 sold-out sizes plus three
  lingerie products.

Prefer the API for diagnosis and the UI only for changes that have no API
path.
