# Does the ad menu auto-reply? — resolving the contradiction

Investigation, 2026-08-12. All numbers measured read-only against production
(Chatwoot DB + Meta Graph via the page token on inbox 2). No production writes,
no ad modified. Companion to `docs/UMI-META-PLAN.md` and
`docs/UMI-META-AUTOMATION-PORT-SPEC.md`; this document **corrects** the
"two places the answer can live" section of the plan.

---

## Verdict, in one paragraph

**Both statements are true, and neither describes what is happening.** Ad
`120252251820030415` does carry three ice-breaker responses, 166 characters
each, byte-identical — the agent read the API correctly. And customers do not
get an answer to the button they tapped — the performance manager is right about
the outcome. The missing link: **the ice-breaker mechanism is not broken and is
not idle. It fires on essentially every tap, on both platforms, in 1–4 seconds.
What it sends is a generic "thanks, we'll get back to you, which model are you
interested in?" — the same text for all three questions.** There is no
autoreply *to the buttons* because the configured response answers no question,
not because nothing fires. The fix is content, not mechanism.

Two claims in the brief are **inverted by the evidence**: the fast replies are
not Messenger-only (Messenger 17/18, Instagram 7/8), and Instagram does not
"get nothing" — Instagram is the *only* platform where Chatwoot can currently
see the automated reply at all.

---

## Method, windows, sample sizes

| | |
|---|---|
| Window (primary) | 2026-08-05 21:45 → 2026-08-12 21:45 Bangkok (rolling 7 days) |
| Taps in window | **29** inbound messages in inbox 2 matching `^[0-9]\.` (21 Messenger, 8 Instagram) |
| Tap conversations | 19 |
| Window (check) | 2026-08-01 00:00 → 2026-08-12 22:00 Bangkok (month-to-date), **33** taps — see *Month-to-date* below |
| Sources | Chatwoot Postgres, and Meta's own copy of each thread via `GET /me/conversations?user_id=…&platform=…` + `/messages` |
| Ad read | `GET /120252251820030415` and its creative `1361403628821199` on Ads API **v23.0** |
| Ad inventory | 50 ads on `act_521070490831440`, `date_preset=last_30d` |

**Two clocks, and why it matters.** Meta's `created_time` has **1-second**
resolution; Chatwoot's `created_at` is webhook-receipt time and runs **2–6 s
behind** Meta for the same message. Every gap below says which clock it is on.
Sub-second gaps (the brief's 0.4 s / 0.6 s / 0.9 s / 1.7 s) **cannot be produced
by either source** and I could not reproduce them — see *Could not establish*.

**The trap, avoided.** Every reply below is required to be **strictly after**
the tap, anchored on Meta's own copy of that tap. This matters because the ad
sends a *different* message at chat-open, before the tap:
`สวัสดีค่ะ 👋 {{user_full_name}} แจ้งให้เราทราบได้เลยว่ามีอะไรให้เราช่วยคุณได้บ้าง`.
A tolerance window centred on the tap matches that one and returns negative
gaps. It is the welcome text, not an answer.

---

## Finding 1 — what the ad actually contains

`adcreative 1361403628821199` → `object_story_spec.video_data.page_welcome_message`
is a JSON blob with `customer_action_type: "ice_breakers"` and three entries:

| # | `title` (what the customer taps) | `response` (what Meta sends back) |
|---|---|---|
| 1 | `1. สนใจรับส่วนลด 10% สำหรับการสั่งซื้อครั้งแรก` — wants the 10% first-order discount | 166 chars, the generic acknowledgement |
| 2 | `2. ขอแนะนำสินค้าสำหรับวันแม่` — asks for Mother's Day picks | **identical, same 166 chars** |
| 3 | `3. ขอแนะนำสินค้าขายดีของ UMI` — asks for best-sellers | **identical, same 166 chars** |

Verified programmatically: `responses.uniq.length == 1`, `length == 166`. The
text is:

```
สวัสดีค่ะ 🤍 ขอบคุณสำหรับข้อความของคุณ
เราได้รับข้อความของคุณเรียบร้อยแล้ว และจะตอบกลับโดยเร็วที่สุด
ระหว่างนี้ คุณกำลังสนใจสินค้ารุ่นไหนอยู่คะ? เรายินดีช่วยแนะนำค่ะ ✨
```

So the field that is supposed to answer *"show me Mother's Day products"*
answers *"which product are you interested in?"* — it asks the customer the
question they just answered by tapping.

Two operational facts from the same read:

- **Exactly one ad in the account has ice-breakers at all.** Of 50 ads
  (`last_30d`), 49 return `page_welcome_message: nil`. The menu exists on this
  one creative only.
- **That ad is `effective_status: CAMPAIGN_PAUSED`** (campaign
  `120252251147010415` PAUSED, last updated 2026-08-05), yet taps kept arriving
  through 2026-08-12 20:13 — customers still reach the existing post. Pausing
  the campaign does not stop the menu.
- The adset is **`destination_type: MESSAGING_INSTAGRAM_DIRECT_MESSENGER_WHATSAPP`**
  with `optimization_type: DOF_MESSAGING_DESTINATION` and three CTAs in
  `asset_feed_spec` (`MESSAGE_PAGE`, `INSTAGRAM_MESSAGE`, `WHATSAPP_MESSAGE`).
  It is **not** a Messenger-only ad, contrary to the brief's premise. Meta picks
  the destination per user, which is why both platforms see the same menu.

---

## Finding 2 — the mechanism fires, on both platforms, on nearly every tap

Per-tap, anchored on Meta's copy of the tap, gap on **Meta's clock**:

| Platform | Taps | Ice-breaker response fired | Gap min / median / max | Visible in Chatwoot |
|---|---|---|---|---|
| Messenger | 18 matched | **17 (94%)** | 1 s / 2 s / 4 s | **0** |
| Instagram | 8 matched | **6 strictly-after + 1 same-second tie = 7 (88%)** | 1 s / 1 s / 2 s | **7** |
| **Total** | **26 matched** | **24** | all ≤ 4 s | 7 |

26 of 29 taps matched a Meta-side tap message; the 3 unmatched are duplicates
inside conv 834's burst (Meta shows five identical taps stamped the same
second, which second-resolution timestamps cannot tell apart). The Instagram
"tie" is conv 832, where Meta stamps tap and response in the same second;
Chatwoot confirms the response arrived after (+5.86 s on Chatwoot's clock).

Only **two taps got no response at all**: conv 850 (Messenger, 08-09 20:35) and
conv 837 (Instagram, 08-08 11:26). Neither thread carries the ad's
`replied to an ad` marker or welcome text, which suggests the tap did not come
through the ad's welcome flow — but with n=2 I am not asserting a cause.

The answer to *"why only 4 of ~20 Messenger taps?"* is therefore: **it is not
4 of 20, it is 17 of 18.** The count of 4 is an artefact of counting in a place
where Messenger's copies do not exist — see Finding 5.

### Reconciliation against an independent measurement

A parallel measurement reported **4 fast replies, all Messenger, none on
Instagram**, and suspected this document's count of human replies. Holding the
*criterion* constant settles which half is wrong.

**The classification rule used here is not a timing threshold.** A message
counts as the ice-breaker firing only if all three hold:

1. `from.id` is the page (`516819784857962`) or the IG business account
   (`17841468119523354`);
2. the text contains `ขอบคุณสำหรับข้อความของคุณ` — a substring present **only**
   in the 166-char `response` read off the creative, and **absent** from the ad
   greeting (asserted in code: the greeting returns `false` on this test);
3. Meta `created_time` is **strictly greater** than the Meta-side copy of the
   tap.

Rule 2 is what makes the greeting trap structurally impossible rather than
merely avoided: the greeting
`สวัสดีค่ะ 👋 {{user_full_name}} แจ้งให้เราทราบได้เลยว่ามีอะไรให้เราช่วยคุณได้บ้าง`
shares only the opening `สวัสดีค่ะ` with the response. Human replies never
entered the count — they were a separate column throughout.

**Re-run under the other measurement's criterion** — *first page message
strictly after the tap, excluding Leads Centre notes and `replied to an ad`
lines, no text matching at all* — same 7-day window, 25 taps matched:

| Gap | Count | What the message actually is |
|---|---|---|
| 1 s | 8 | ice-breaker |
| 2 s | 8 | ice-breaker |
| 3 s | 5 | ice-breaker |
| 4 s | 1 | ice-breaker |
| 68 s | 1 | human (conv 837, Instagram) |
| 74 s | 1 | human (conv 832, Instagram) |
| 3193 s | 1 | human (conv 850, Messenger) |

**22 of 25 within 10 s — 16 Messenger, 6 Instagram — and all 22 are the
ice-breaker.** Greeting matched as an answer: **0**. Nothing sits between 5 and
67 seconds; the distribution is bimodal with no ambiguous middle, which is why
no timing threshold between 5 s and 60 s changes any conclusion.

The two criteria therefore agree. The disagreement is not definitional, so it
lies in the **data source** — and the Messenger half of it is explained by
Finding 5: any count taken from Chatwoot rows finds **0** Messenger ice-breakers,
because none has been stored since 2026-06-23. The Instagram half is not
explained by anything found here; Instagram is the *better*-evidenced platform,
carrying two independent records.

**Single Instagram data point, both sources, conv 828:**

| Source | Record |
|---|---|
| Meta Graph, `platform=instagram` | `2026-08-07T02:33:11+0000` USER `2573263889745610` → `3. ขอแนะนำสินค้าขายดีของ UMI` |
| " | `2026-08-07T02:33:12+0000` PAGE (IG biz `17841468119523354`) → the 166-char response. **Gap 1 s, strictly after.** |
| Chatwoot | msg `10175` incoming `08-07 09:33:16.955` (tap) |
| " | msg `10177` outgoing `08-07 09:33:20.663`, `external_echo: true`, `source_id` `aWdf…`. **Gap 3.71 s, strictly after.** |

Conv 826 is a second such case (Meta 14:54:47 → 14:54:48, 1 s; Chatwoot 10162 →
10164, 6.47 s). Instagram fires.

### Month-to-date, as a check on the 7-day window

The rolling 7-day window sits entirely inside August 2026 (first tap 08-06
07:37, last 08-12 20:13), so it is not mixing months. Re-run over the full month
to date — **2026-08-01 00:00 → 08-12 22:00 BKK, 33 taps, 30 matched** — the
result holds and strengthens slightly:

| Platform | Taps | Fired | Gap min / median / max | Visible in Chatwoot |
|---|---|---|---|---|
| Messenger | 20 | **19 (95%)** | 1 s / 2 s / 4 s | 0 |
| Instagram | 10 | **8 (80%)** | 1 s / 1 s / 2 s | 8 |
| **Total** | **30 matched** | **27** | all ≤ 4 s | 8 |

The Instagram figure needs one note: 6 of the 8 are strictly-after on Meta's
clock, and the other 2 (convs 832 and 130) are confirmed fired by **Chatwoot's**
copy (+5.9 s and +8.0 s) while Meta's thread listing did not return the message
in a strictly-after position. For conv 832 that is the same-second rounding
described above; for conv 130 the cause is not established. Genuine non-fires
month-to-date are 3 of 30: convs 70, 837 (Instagram) and 850 (Messenger).

---

## Finding 3 — what those replies are: three candidates, two eliminated

The same 166-char Thai text was configured in three places at once. Elimination:

**Candidate A — Chatwoot's own inbox greeting. ELIMINATED.**
Chatwoot's greeting is written with `message_type: template` (3). Across all
time, inbox 2 contains **exactly two** such messages: conv 855 on 2026-08-10
22:37:26 (Messenger) and conv 858 on 2026-08-11 15:23:34 (Instagram). Both
pre-date the disable; `greeting_enabled` now reads `false` and the text is still
stored. The decisive case is the brief's own: the tap at **08-12 11:34:13**
(conv 834), after the greeting was switched off — Meta shows the 166-char reply
at **11:34:16 (+3 s)**, and Chatwoot has **no outgoing row at all**. A message
Chatwoot never created cannot be Chatwoot's greeting.

**Candidate B — Meta's instant-reply / away message. ELIMINATED.**
Those fire on a thread's first message regardless of content. Tested against 10
conversations opened in the same 7-day window that did **not** start with a tap
(convs 843, 846, 848, 849, 858, 864, 865, 866, 867, 869; both platforms): the
166-char text appears **zero** times. The single apparent hit, conv 858, is
Chatwoot's own template greeting echoed outward. Two further disconfirmations:
it fires on the **8th** tap of conv 834, four days into the thread, and it fires
**five times in four seconds** during that conversation's burst. Away messages
do not repeat like that.

**Candidate C — the ad's `ice_breakers[].response`. CONFIRMED.**
It fires if and only if an ice-breaker is tapped, once per tap, on both
platforms, 1–4 s later, and its text is byte-identical to the `response` field
read off the creative. That is the definition of the mechanism.

---

## Finding 4 — Instagram is not the problem; it is the only place that works

Instagram taps (8 in window) got the ice-breaker response 7 times, at 1–2 s —
marginally *faster* than Messenger. The claim "0 of 8 Instagram taps got a fast
reply" is an artefact of the same measurement fault as Finding 2, with the sign
flipped: in **Chatwoot**, Instagram is where the automated replies are visible
(7 of 8, as `external_echo: true`) and Messenger is where they are invisible (0
of 18).

Mechanically this follows from the ad being multi-destination
(`MESSAGING_INSTAGRAM_DIRECT_MESSENGER_WHATSAPP`): Instagram Direct is a
first-class destination of this creative, so IG users see the same three
buttons and get the same configured response. There is no Instagram config gap
in the ice-breaker mechanism.

---

## Finding 5 — the real defect: Chatwoot is blind to Messenger's page-side traffic

This is the finding with the longest tail, and it was not in the brief.

Chatwoot's inbox 2 is a single `Channel::FacebookPage` carrying **both**
Messenger (`page_id 516819784857962`) and Instagram
(`instagram_id 17841468119523354`).

- The page **is** subscribed to `message_echoes` (`subscribed_apps` returns
  `messages, message_deliveries, message_echoes, message_reads, standby,
  messaging_handovers`), so this is not a missing-subscription bug.
- Instagram echoes arrive continuously — most recent 2026-08-12 20:03.
- **No live Messenger echo has been recorded since 2026-06-23.** All 463
  Messenger-format `external_echo` rows are dated on or before that day, and the
  last of them are `Lead stage set to …` notes written in an 11-minute block
  during the history migration. Instagram echo rows run every month from
  2025-03 to now.

Consequence, measured on the tap cohort: Meta's copy of conv 834 holds **34**
messages; Chatwoot holds **12**. Conv 847: 9 versus 4. Conv 824: 7 versus 4.
Everything the page emits on Messenger — `replied to an ad` markers, the ad
welcome text, the ice-breaker response, `Lead stage set to Qualified` — is
absent from Chatwoot. Agents working a Messenger ad conversation see the tap and
nothing else, and cannot tell that the customer was already sent a
"which model are you interested in?" message seconds earlier.

I have **not** established the cause. `Integrations::Facebook::MessageCreator`
would create these rows if the webhook arrived (`echo? && !sent_from_chatwoot_app?`,
and `sent_from_chatwoot_app?` is documented in-tree as probably non-functional),
so the likely explanation is that Meta stopped delivering `message_echoes` for
first-party-generated Messenger messages — but that needs a webhook-payload
capture to confirm, which is a write-adjacent change to logging and out of scope
here.

---

## Corrections to the numbers in the brief

| Brief | Measured | Note |
|---|---|---|
| 28 taps in 7 days | 29 | window-boundary difference only |
| 4 fast replies, all Messenger | 24 of 26 matched taps, both platforms | Messenger 17/18, Instagram 7/8 |
| 0 of 8 Instagram taps got a fast reply | 7 of 8 did | and Instagram is the only platform where Chatwoot sees them |
| gaps 0.4 / 0.6 / 0.9 / 1.7 s | 1–4 s (Meta clock); 3.7–6.9 s (Chatwoot clock) | sub-second gaps not reproducible from either source |
| 24 answered by human, median 118 s | 25 human first-replies, pooled median **725 s** | Messenger median 1386 s, Instagram median 71 s; "human" = first page message after the tap that is not the ice-breaker response, the welcome text, or a Leads-Centre note |
| live ad is MESSAGE_PAGE / Messenger-destination | adset is Messenger + Instagram Direct + WhatsApp | `MESSAGE_PAGE` is one of three CTAs in `asset_feed_spec` |

The brief's *qualitative* core — customers are not getting an answer to the
button, and Chatwoot cannot show agents what happened — survives all of it.

---

## What I could not establish

1. **The origin of the sub-second gaps** (0.4/0.6/0.9/1.7 s) and of the
   "4 of 20, all Messenger" split. Neither clock available to me can produce
   sub-second deltas. I could not reconstruct the earlier pipeline, so I cannot
   say which step introduced the error — only that both authoritative sources
   disagree with it.
2. **Why Messenger echoes stopped on 2026-06-23.** Meta-side delivery change
   versus a Chatwoot-side drop is not separable without capturing raw webhook
   payloads.
3. **Why 2 of 26 taps got no response** (convs 850, 837). Both lack the ad's
   welcome-flow markers; n=2 is too small to call.
4. **Whether Meta's "Questions and responses" automation can be enabled for
   Instagram.** Business Suite automation config is not exposed on any Graph
   node I can read; the OFF/empty/Messenger-only state is carried over from the
   visual reading recorded in `UMI-META-AUTOMATION-PORT-SPEC.md`, not
   re-verified here.
5. **Whether the ice-breaker response counts against Meta's 24-hour messaging
   window** — not observable from message data.

---

## Recommendation — put the answers in the ad's ice-breakers

**Recommended: rewrite the three `response` fields on the creative. Do not build
Chatwoot rules for this, and do not switch on Meta's Questions-and-responses.**

Why, against the decisive constraint (must work on Instagram, ideally visible in
Chatwoot):

- **It already works on Instagram.** 7 of 8 IG taps, 1–2 s. This is measured,
  not assumed — and it is the constraint the plan doc believed ice-breakers
  failed. That belief was wrong.
- **It is the only mechanism that knows exactly which question was tapped.**
  No keyword matching, no language handling. Meta's Questions-and-responses
  matches free text and would have to guess; recall the 12 customers who typed
  Thai for "to order" and got nothing.
- **It is already firing on 24 of 26 taps.** Changing three strings converts a
  measured 92%-delivery channel from useless to useful. Nothing else on this
  page has that leverage-to-effort ratio.
- **Agent blindness is nearly a non-issue here**, which is the point the plan
  doc got wrong. With ice-breakers the reply is a *pure function of the tap*,
  and the tap **is** in Chatwoot on both platforms (21 Messenger + 8 Instagram
  in the window). An agent reading `2. ขอแนะนำสินค้าสำหรับวันแม่` knows exactly
  which of three fixed blocks was sent. That is not true of free-form
  automation, which is what "agents cannot see what the customer was told" was
  originally about.

Why not Chatwoot rules as the primary: they would fire **in addition to** the
ice-breaker response, which is configured per-creative and cannot be suppressed
from Chatwoot — the customer gets two messages, the generic one first. To use
Chatwoot rules cleanly you must first blank the ad's responses, which trades a
1–2 s Meta-native answer for a 5–20 s one and still leaves the per-creative
edit. If you are editing the creative anyway, put the right answer there.

Why not Meta's Questions and responses: keyword-matched rather than
button-matched, currently OFF and empty, and per the existing visual reading
ticked for Messenger only — it is strictly worse than the mechanism already
running.

**Two conditions attach to this recommendation. Both are real and the
recommendation is weaker without them:**

1. **Ice-breakers are per-creative, and UMI does not currently configure them.**
   49 of 50 ads have none. Every new campaign must set all three responses or
   the answer silently reverts to nothing. This belongs on the ad-launch
   checklist, not in anyone's memory. If that cannot be guaranteed, the answer
   flips to Chatwoot rules — they live in one place and survive creative churn —
   and the ad responses must then be blanked to avoid double-sending.
2. **Fix the Messenger echo gap separately** (Finding 5). It is a real defect
   independent of this decision: today an agent on Messenger cannot see the ad
   welcome text, the automated reply, or Meta's own lead-stage notes.

**Also worth acting on now, unrelated to the mechanism:** option 2 is
`ขอแนะนำสินค้าสำหรับวันแม่` — Thai Mother's Day is **12 August**, today. That
menu option is expiring as this is written, and the ad still serves it.

### What the three responses should say — drafts

Drafted by **recombining UMI's own production copy**, not by inventing voice or
product data. Blocks 1 and 3 are the agent copy-paste blocks already in
circulation (7 sends each in 60 days), reproduced verbatim except for the final
line. Every product name, colour, price and URL below is copied from a message
UMI actually sent — none is invented. **A Thai speaker at UMI must still sign
these off before they go into the ad.**

Each response replaces one `ice_breakers[].response` on creative
`1361403628821199`, matched to its own `title`.

---

**Button 1 — `1. สนใจรับส่วนลด 10% สำหรับการสั่งซื้อครั้งแรก`** (247 → 262 chars)

```
สวัสดีค่ะ 🤍 ขอบคุณที่สนใจ UMI นะคะ

นี่คือโค้ดส่วนลด 10% สำหรับการสั่งซื้อครั้งแรกค่ะ

🎁 WELCOME10

ใช้ได้ที่ https://umi.store กรอกโค้ดตอนชำระเงินได้เลยนะคะ

🎁 ซื้อครบ ฿4,000 แถม Thongs Lure 1 ชิ้น (มูลค่า ฿590) ค่ะ

อยากให้ช่วยแนะนำรุ่นขายดี หรือกำลังมองหาชิ้นไหนอยู่คะ บอกได้เลยค่ะ ยินดีเช็คไซส์และสต็อกให้นะคะ 🤍
```

Verbatim from production except the last line. The original closes with an
open *"if you're interested in anything particular, tell me"* — and this tap has
produced **0 follow-ups out of 10** across all time, the worst of the three.
The replacement offers a concrete next step (best-sellers, or name a piece)
rather than an open invitation.

---

**Button 2 — Mother's Day is being switched off at midnight 2026-08-12.**
It is replaced by the gift-with-purchase offer, which needs a new **title** on
the creative as well as a new response:

> new title: `2. ของแถมเมื่อซื้อครบ ฿4,000`

```
ของแถมพิเศษจาก UMI ค่ะ 🤍

🎁 ซื้อครบ ฿4,000 — แถม Thongs Lure 1 ชิ้น (มูลค่า ฿590)
🎁 ซื้อครบ ฿8,000 — แถม Thongs Lure + Bralette Pure (มูลค่า ฿1,690)

ของแถมมีสีดำและสีเบจ ไซส์ S / M / L ค่ะ
https://umi.store/products/thongs-lure
https://umi.store/products/bralette-pure

สนใจรุ่นไหนอยู่คะ เดี๋ยวช่วยจัดให้ครบยอดพอดี แล้วเลือกสีและไซส์ของแถมได้เลยค่ะ 🤍
```

Product facts verified against the live storefront on 2026-08-12:
**Thongs Lure ฿590** and **Bralette Pure ฿1,100**
(`/products/thongs-lure`, `/products/bralette-pure`), both Black + Beige,
S/M/L, and **all six variants of each are in stock** — `available: true`
product-wide on Shopify's `.js` endpoint. Worth recording because the rendered
product page shows *"Variant sold out or unavailable"* against every
combination; that is the theme's pre-selection state, not the stock position.

The ฿4,000 tier is **already being quoted to customers** — `แถมกางเกงใน 1ชิ้น
เมื่อซื้อครบ4,000บาทค่ะ` (2026-08-11 21:38), the only place in production the
offer has ever been written down, and it names no product. These drafts are the
first time the gift has an identity, a value and a size.

**Why the gift belongs on its own button rather than only as a footnote to the
other two:** it has a colour and a size, so it cannot be fulfilled unless the
customer replies. That converts the auto-reply into a question the customer has
a concrete reason to answer — exactly what the 43% February cohort had and what
today's discount block lacks (0 follow-ups in 10). It is the only one of the
three buttons whose answer *requires* a response to complete.

The same tier line is folded into blocks 1 and 3 above, so the offer is not
stranded behind a single button.

**Three business rules I could not establish. Each changes who qualifies:**

1. **Does the ฿4,000 count before or after `WELCOME10`?** It decides real
   cases: a ฿4,690 Tank dress qualifies either way, but ฿4,090 Low-rise
   Trousers become ฿3,681 with the code and stop qualifying.
2. **Can the gift be combined with `WELCOME10` at all?** Nothing in production
   says. The draft deliberately claims nothing.
3. **What is the current free-shipping threshold?** Production contradicts
   itself: `฿6,000` (2025-07-09, 2025-08-19) versus `ซื้อสินค้าครบ฿4,500 ส่งฟรี`
   alongside `฿120` flat shipping (2026-08-06). If ฿4,500 is current, the ladder
   is unusually tidy and worth stating outright — ฿4,000 gift, ฿4,500 free
   shipping, ฿8,000 double gift. I am not putting an unverified number in an ad.

---

**Button 3 — `3. ขอแนะนำสินค้าขายดีของ UMI`** (707 → 771 chars)

```
แนะนำรุ่นขายดีของ UMI ค่ะ 🤍

1. Tank dress Fluent (สีดำ) — ฿4,690
เดรสขายดีอันดับ 1 ค่ะ ทรงสวย ใส่ได้ทุกโอกาส
https://umi.store/products/tank-dress-fluent

2. Long sleeve Haze (สีดำ) — ฿2,490
เสื้อแขนยาวเนื้อนุ่ม ใส่สบาย แมตช์ง่าย
https://umi.store/products/long-sleeve-haze

3. Low-rise Flared Trousers (สีไอวอรี่) — ฿4,090
กางเกงขาบานทรงสวย ยืดหยุ่น ใส่สบายค่ะ
https://umi.store/products/low-rise-flared-trousers

4. Slip Top (สีไอวอรี่) — ฿2,190
เสื้อสายเดี่ยว ใส่เดี่ยวหรือใส่ทับก็สวยค่ะ
https://umi.store/products/strap-top

5. Mini dress Keen (สีดำ) — ฿3,590
เดรสสั้นทรงเรียบหรู ใส่ได้ทั้งกลางวันกลางคืน
https://umi.store/products/mini-dress-keen

อย่าลืมใช้โค้ด WELCOME10 ลด 10% สำหรับออเดอร์แรกนะคะ🤍
🎁 ซื้อครบ ฿4,000 แถม Thongs Lure 1 ชิ้น (มูลค่า ฿590) ค่ะ

สนใจตัวไหนเป็นพิเศษไหมคะ ปกติใส่ไซส์ไหน เดี๋ยวเช็คสต็อกให้ค่ะ
```

Verbatim from production, plus a closing question. This tap already has the best
follow-up rate of the three (3 of 9); the block currently ends on a statement,
so there is nothing for the customer to answer.

### Two things to decide before pasting these in

1. **Button 2 needs a title change, not just a response change.** Mother's Day
   goes off at midnight on 2026-08-12 and the button wording lives in the
   creative, so a response alone cannot fix it — `title` and `response` have to
   be edited together. The replacement is deliberately evergreen: a spend
   threshold does not expire on a calendar date the way a holiday does.
2. **These three go stale in exactly the same way the menu does.** They are
   per-creative. The best-sellers list in particular hardcodes five products and
   five prices; when stock or pricing moves, three separate places need editing.
   Keeping the list to items that are reliably in stock is worth more than
   keeping it long.

---

## The rest of the ad account, and whether the buttons can be edited

Both measured read-only on 2026-08-13 against `act_521070490831440` ("UMI Ads",
THB, Asia/Bangkok). **Ads API calls need `{ api_version: 'v25.0' }` as a
symbol-keyed options hash** — a string key silently falls back to
`Koala.config.api_version`, which nothing sets, and returns error 2635 while the
code looks correct.

### Messaging is a rounding error in this account — except for what it produces

121 campaigns, 207 adsets, 300 ads scanned (the ads list is capped at 300, so
the oldest tail is not covered; campaigns and adsets are complete).

**Only 5 of 207 adsets have ever been messaging-destination:**

| Adset | Started | Destination | Campaign | State |
|---|---|---|---|---|
| Social Media Manager_Phuket | 2026-08-13 | IG Direct + Messenger + WhatsApp | 13082026_Recruitment SMM_Phuket | **ACTIVE** |
| Phuket + Bangkok · 22-40 | 2026-08-13 | Messenger | SMM hiring — Phuket + Bangkok | PAUSED |
| Thai_Board | 2026-08-05 | IG Direct + Messenger + WhatsApp | 05082026_Conversation_Messages Engagement | campaign paused |
| 04062026_Recruitment Admin_Phuket | 2026-06-05 | IG Direct + Messenger | same | campaign paused |
| Bangkok / Instagram/FB / F25-45 | 2026-02-25 | IG Direct + Messenger | 25.02 Conversations / Bangkok only / Thai | campaign paused |

**Two campaigns are ACTIVE account-wide.** Everything else — all 119 others — is
paused:

| Campaign | Objective | Destination | Delivered today |
|---|---|---|---|
| 13082026_Recruitment SMM_Phuket | ENGAGEMENT | **messaging** | ฿26.20, 441 impressions |
| 13082026_Coversion Purchase_Travel 1 | SALES | website conversions | ฿25.10, 182 impressions |

So **the only ad currently sending anyone into the inbox is a recruitment ad**
for a Social Media Manager — ad `120252444629860415` (`SMM_Post`). Inbound ad
traffic right now is job applicants, not shoppers. Its creative
(`1577695497021437`, PHOTO, `MESSAGE_PAGE`, all three messaging destinations)
has **no `page_welcome_message` at all** — no menu, no buttons, and therefore no
automated response of any kind. A second recruitment messaging campaign was
created the same day and left paused.

**Non-messaging campaigns also drive DMs, and it is not negligible.** Messaging
conversations started, last 7 days, by campaign:

| Campaign | Spend 7d | Impressions | Conversations started |
|---|---|---|---|
| 05082026_Conversation_Messages Engagement | ฿1,538 | 9,085 | **21** |
| 07082026_Traffic to Web | ฿1,551 | 22,260 | 3 |
| 07082026_Coversion Purchase_Mothers' Day 10% | ฿3,265 | 13,692 | 1 |
| 07082026_Traffic to IG | ฿1,458 | 23,852 | 1 |
| 11082026_Coversion Purchase_Mothers' Day Gift | ฿1,306 | 5,966 | 1 |

**27 conversations, of which the messaging campaign produced 21 (78%) on 17% of
the spend.** The other 22% arrive from traffic and sales ads, land in the same
inbox, and never see a menu because only messaging creatives carry one. The same
campaign reports `messaging_welcome_message_view = 29`, which corroborates the
29 taps measured independently in Chatwoot over the same 7 days.

### The buttons can be edited. It is an edit, not a rebuild.

Two separate questions, and they have different answers.

**Can the ice-breakers be changed in place on the existing creative? No.** Meta
documents only three updatable fields on an ad creative — `name`, `status`,
`adlabels`. `object_story_spec` is not among them, and the ice-breakers live
inside it at `object_story_spec.video_data.page_welcome_message`. Any change
produces a **new creative**. This part is certain.

**Does that force a duplicate ad? No — and this account proves it.** Scanning
300 ads, **11 carry a creative dated after the ad itself was created**:

| Ad | Ad created | Creative dated | Ad last updated |
|---|---|---|---|
| 120251750514250415 Carousel_Pictures_Manual | 2026-07-14 | 2026-07-16 | 2026-07-17 |
| 120250776044790415 FLOW_catalog | 2026-06-23 | 2026-06-25 | 2026-06-25 |
| 120250368838070415 Video 1 | 2026-06-18 | 2026-06-19 | 2026-06-19 |
| …8 more | | | |

A creative that did not exist when the ad was created, now attached to that ad,
means the ad **kept its ID while its creative was replaced**. `106 of 300` ads
were also edited more than an hour after creation, so this is routine here, not
exotic. The earlier "message flows are immutable while live" finding applies to
the *creative object*, not to the ad — the ad is a pointer, and the pointer can
be moved.

**What an edit actually costs, for this ad specifically:**

| | |
|---|---|
| Ad ID, name, lifetime stats | **kept** — 9,148 impressions, 5,748 reach, ฿1,561.85, 22 conversations |
| Learning phase | **nothing to lose** — the campaign is PAUSED and not delivering |
| Page post social proof | at risk — the post carries **8 likes, 5 shares, 0 comments** |
| Live traffic disruption | none — the ad is not delivering |

The social proof at stake is 13 interactions on a reel eight days old. That is
not a reason to avoid an edit.

**What I could not establish:** whether Ads Manager's UI greys out the
welcome-message editor specifically for an ad that has already been published.
Everything above says the edit is permitted; whether the interface exposes it
without a duplicate is a two-minute check in the UI — open the ad, press Edit,
see whether the welcome-message section accepts changes — and I will not test it
by writing to a live ad. If it is greyed out, the fallback is to build one new
creative and point this ad at it, which preserves everything in the table above.

**Recommendation stands: make it one edit.** The campaign is paused, so there is
no delivery to disrupt and no learning to reset. Remove the stale Mother's Day
button and replace all three generic responses in the same pass, rather than
touching the ad twice. Note separately that fixing this ad does **nothing** for
the traffic arriving right now, which comes from a recruitment ad that has no
menu at all.

## Reproduction

Scripts used, run via
`ssh HOST 'sudo sh -c "cd /opt/umi/chatwoot && docker compose exec -T rails bundle exec rails runner -" < /tmp/s.rb'`:

| Purpose | Key call |
|---|---|
| Taps + Chatwoot replies | `Message.where(inbox_id: 2, message_type: 0).where("content ~ '^[0-9]\\.'")` |
| Platform split | `source_id` prefix — `m_` = Messenger, `aWdf…` (`ig_dm_item:…` base64) = Instagram |
| Ad + creative | `Koala::Facebook::API.new(Inbox.find(2).channel.page_access_token).get_object(id, {fields: …}, {api_version: 'v23.0'})` — the default pinned version returns error 2635 |
| Meta's copy of a thread | `get_connection('me', 'conversations', {user_id: <psid>, platform: 'messenger'\|'instagram'})` then `/messages` |
| Echo history | `Message#content_attributes['external_echo']` in Ruby — **not** SQL, see the gotcha below |

**Gotcha that will bite the next person.** `messages.content_attributes` is a
`json` column whose value is **double-encoded**: the row holds the JSON *string*
`"{\"external_echo\":true}"`, so `json_typeof(content_attributes)` is `string`,
not `object`. Every key lookup through `->>` returns `NULL` and filters return
**0 rows silently** — `WHERE content_attributes->>'external_echo' = 'true'`
counts 0 while `content_attributes::text LIKE '%external_echo%'` counts 5029.
ActiveRecord decodes it correctly, so Ruby-side `select`/`group_by` is the safe
route. Any earlier analysis that filtered echoes in SQL would have concluded no
echoes exist anywhere.
