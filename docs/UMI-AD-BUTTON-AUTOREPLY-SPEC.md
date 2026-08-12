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
| Window | 2026-08-05 21:45 → 2026-08-12 21:45 Bangkok (rolling 7 days) |
| Taps in window | **29** inbound messages in inbox 2 matching `^[0-9]\.` (21 Messenger, 8 Instagram) |
| Tap conversations | 19 |
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

### What the three responses should say

Out of scope for this document — it needs UMI's wording in Thai (the plan doc
already has this as an open item, "~20 minutes together"). The shape is fixed by
the mechanism: three blocks, each ≤ 1000 characters, each answering its own
button. Two of the three already exist as agent copy-paste blocks in production
(the `WELCOME10` coupon block and the best-sellers block); only the Mother's Day
answer has never existed — which is why 5 taps for it got the best-sellers list
or the coupon instead.

---

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
