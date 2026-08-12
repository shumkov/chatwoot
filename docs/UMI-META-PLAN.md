# UMI × Meta — the plan, in plain language

Master list of everything discussed. Written to be readable without the
jargon; the detailed engineering specs live in the other `docs/UMI-*` files and
are linked where they exist. Last updated 2026-08-12.

**Status key:** ✅ live · 📦 built, not deployed · 🔨 in progress · ⏸ waiting on
a decision or access · ❌ investigated and rejected · 💤 deliberately deferred

---

## What we are actually trying to achieve

Three separate goals that kept getting tangled together:

1. **Agents can handle ad conversations well.** Today someone taps a button in
   an ad and the agent sees a bare `"3. recommend best sellers"` with no idea
   what the ad promised.
2. **Know which ad produced which sale.** Today there is no link between a
   conversation and a Shopify order.
3. **Meta gets good data back** so its ad delivery improves.

They need different fixes. Goal 1 is mostly Meta-side config. Goal 2 is the
hardest and is blocked on how orders get created. Goal 3 turns out to be
partly broken in a way nobody had noticed.

---

## ✅ Live in production

| What | Detail |
|---|---|
| **Customers no longer get the greeting twice** | The same Thai text was set in both Meta's ad and Chatwoot. Chatwoot's copy switched off 2026-08-12; the text is kept on record so it can be switched back. |
| **All 7 inboxes on Bangkok time** | They were on UTC, so "9–5" actually meant 4pm–midnight. Now 09:00–21:00, seven days a week. Still switched **off** — nothing sends automatically. |
| **Contact names and photos** | 155 contacts renamed, 73 photos attached, no real names overwritten. |

## 📦 Built and tested, NOT yet deployed

| What | Detail |
|---|---|
| **Show which ad a conversation came from** | Captures Meta's ad id, ad name and campaign reference onto the conversation. Reviewed independently, one real bug found and fixed (a path that could have lost a customer's message). |
| **Order history for linked customers** | Chatwoot only matched customers by email or phone and ignored the Shopify ID we already store. Now it uses the ID. |
| **Two small Instagram/Facebook bugs** | An outdated API version in the Instagram send path, and a setting that claimed to do something it never did. |

**Deploying needs two things:** the commits must move to the `umi` branch
(only that branch builds an image), and the database migration must be run **by
hand** — it does not run automatically, and if it is skipped the ad-capture
feature is silently inert.

### Meta-side config changed 2026-08-12 — record, because it is invisible in code

**`messaging_referrals` subscribed on the Page** (app "UMI Store",
`2163627007746338`). Field set went 6 → 7; nothing was lost.

Before: `message_deliveries message_echoes message_reads messages
messaging_handovers standby`
After: the same **plus `messaging_referrals`**

Why: Instagram was delivering ad attribution without it, so an earlier
conclusion recorded here — that Meta's documented requirement "did not hold" —
was generalised from Instagram alone. It **does** hold for Messenger. Proven by
a real ad click: conversation 870, Messenger, 2026-08-12 20:13 Bangkok, opened
by a menu tap, captured nothing while the code was verified loaded and both
builder prepends wired.

**If this ever needs restoring**, the pre-change set was:
`message_deliveries,message_echoes,message_reads,messages,messaging_handovers,standby`

Two traps for whoever touches this next. `POST /{page}/subscribed_apps`
**replaces** the entire field set rather than appending, so a partial list
silently unsubscribes everything omitted and Messenger messages stop arriving.
And never use `Channel::FacebookPage#subscribe`: it rescues `StandardError`,
logs at `debug` and returns `true`, so a failed re-subscribe looks like success.
Read the live set, send the union, read back and diff — as the change above did.

## 🔨 In progress

| What | Detail |
|---|---|
| **Answering the ad menu** | See "The biggest opportunity" below. |

## ⏸ Waiting on a decision or access

| What | Needs |
|---|---|
| **Deploy the three items above** | Confirmation of how commits reach `umi` (rebase, keeping one commit per patch). |
| **Ad question answers** | Your wording, in Thai. ~20 minutes together. |
| **Draft order access in Shopify** | A code change first — see below. |
| **Shumabit stamps a conversation id on orders** | Separate session. This is the real fix for goal 2. |
| **Report a possible Meta bug** | 12 customers typed Thai for "to order" and Meta's automation never reacted. Either it does not understand Thai, or it needs an order created inside Meta. Worth asking Meta which. |

## ❌ Investigated and rejected — do not revisit

| What | Why |
|---|---|
| Backfilling Meta's missing messages into Chatwoot | The menu is button data, not text — it cannot be retrieved. Instagram had no gap at all. And the write would have hidden struggling conversations from the agent's "unattended" list. |
| Matching orders by the invoice link agents paste | 1 of 77 orders carried it, matching none of the 14 links actually sent. |
| "Agents cannot edit a customer's email" | Not a bug. Merging contacts already does this, and merging is the correct action. |
| 4 of Meta's 5 lead automations | Two cannot fire at all (they need an order created inside Meta; you sell through Shopify). One fires backwards — 9.5% on ad conversations versus 46% on everything else. One duplicates a folder Chatwoot already has. |
| "Half the team works in Meta's inbox" | Wrong. About a quarter and falling, one person, mostly emoji replies to Instagram stories. Was 100% in mid-July before Chatwoot adoption. |

## 💤 Deferred by you

Three lingerie products rejected by Meta on adult-content policy · switching
working hours on · an out-of-office message (recommendation: do not send one).

---

## The biggest opportunity: answer what people tap

**The evidence.** In February and March, Meta answered the specific question a
customer tapped, within three seconds. **43% of those customers kept talking.**
That automation is now switched off and empty. Today someone taps *"Mother's
Day products"* and gets the *best-sellers* list — the wrong answer to the
question asked. **11% keep talking.**

Agents are not slow: median first reply is about 7 minutes, faster than for
normal customers. They are sending the wrong canned block, because the right
one no longer exists.

**Confirmed still live 2026-08-12:** 30 menu taps across 21 conversations in
the last 7 days, most recent at 01:20 today. Three options are in rotation —
10% first-order discount, Mother's Day products, best sellers. Note Thai
Mother's Day is 12 August, so that option expires immediately; the menu changes
per campaign, so whatever answers it will need maintaining.

**Two places the answer can live.**

*Meta answers it* — refill Meta's "Questions and responses" screen. Instant
(0–3s), free, no code. **But Chatwoot never sees Meta's automated messages**, so
the agent still opens the conversation blind and may contradict a discount
already promised. Also currently ticked for Messenger only, not Instagram —
which is 74% of volume.

*Chatwoot answers it* — one rule per menu option. A few seconds instead of
instant, **but the agent sees the whole exchange**, it works on Instagram
without Meta's checkbox, and it can also tag and route.

**Recommendation: Chatwoot.** The core problem all along has been that agents
cannot see what the customer was told. Speed is not the deciding factor — the
February cohort worked because the answer *matched the question*, not because
it was three seconds.

**Caveat:** if Shumabit is going to answer DMs soon, these rules are a stopgap.
They are cheap to delete.

---

## Sending data back to Meta — and what we just found

The original plan was to send purchase events to Meta so it optimises on
revenue. Investigating it turned up three things that change the plan.

**1. Meta already receives your orders — including the ones we thought were
invisible.** Events Manager shows **39 Purchase events in 28 days**. Your total
Shopify orders over a comparable window are roughly 36 of *all* types, versus
only ~14 web checkouts. So the Shopify app appears to be sending **every**
order, not just website ones. If that holds, the "55% of revenue is invisible
to Meta" framing was wrong — Meta sees the revenue, it just cannot tell which
conversation or ad produced it. **Worth confirming before building anything
that sends more events, or we double-count.**

**2. A third of those events have no price on them.** Meta's own warning:
*"Purchase — 33% affected — Value field is missing."* ฿2,774 of ad spend is
flagged as affected. Meta cannot calculate return on ad spend for a purchase
with no value, so it is optimising against a third less revenue than you
actually make. **This is probably the highest-value fix on this page and it is
not about messaging at all.**

**3. Instagram cannot be optimised for purchases, but can be measured.** Meta
accepts purchase events for Instagram conversations and reports them; it just
will not let you bid on them. The practical playbook is to optimise on
conversations or a qualified-lead event, and send purchases for measurement.
Note one ad set is already optimising on "Initiate checkout" (151 events).

**Volume reality:** ~19.5 purchases per 30 days. That clears Meta's documented
minimum (10), but sits far below the level where its optimiser learns
comfortably.

---

## Linking conversations to orders — the hard one

**What we know.** 795 contacts carry a Shopify customer id; **none of them are
Meta DM contacts**, because DM contacts have neither email nor phone. Zero of 29
web orders matched any email or phone ever typed into a DM.

**Where orders actually come from** (77 orders, 60 days):

| Source | Orders | Identity on them |
|---|---|---|
| Shumabit app | 37 (~44% of revenue) | email 4, phone 4 — effectively anonymous |
| Web checkout | 29 (44.6% of revenue) | email 29/29 — complete |
| Draft orders | 10 (9.6%) | partial |

**The fix is not code.** Shumabit already creates the 37. It does not need to
move into Chatwoot — it needs to know which conversation it is acting for and
stamp that on the order. One field. That makes the link exact instead of
guessed.

**Draft order access** needs a code change first: the Shopify permissions are
hardcoded in the app and `read_draft_orders` is not among them, so there is
nothing for you to approve until it is added and deployed.

**A smaller win already available:** 26 of 77 orders carry Meta campaign tags
that nothing reads. Only 5 have a usable campaign id though — about 8% of
revenue, not the 44% first claimed. Specced deliberately narrow as a
verification report, because its real value is checking Meta's numbers against
Shopify's, not adding attribution.

---

## Open questions

1. **Deploy** — confirm the rebase approach and I run it end to end.
2. **Ad answers** — Chatwoot side, as recommended? And what should each of the
   three answers say?
3. **Shumabit stamping order → conversation** — confirm the shape before that
   session.
4. **The missing price data** — this is the biggest measurable loss found today
   and nobody owns it yet.
5. **Confirm whether every order already reaches Meta**, before sending more.
6. **Ask Meta about the Thai bug?**

---

## Engineering detail lives here

- `docs/UMI-FBIG-AD-ATTRIBUTION-SPEC-R4.md` — capturing which ad a conversation came from
- `docs/UMI-META-AUTOMATION-PORT-SPEC.md` — the lead automations, and why 4 of 5 are dropped
- `docs/UMI-SHOPIFY-ORDER-ATTRIBUTION-SPEC.md` — reading campaign tags off orders
- `docs/UMI-FBIG-OUTBOUND-HEAL-SPEC.md` — the rejected message-backfill, with the post-mortem
- `docs/UMI-META-BACKLOG.md` — the full engineering backlog with every finding
- `UMI-PATCHES.md` — what each fork patch does and when to remove it
