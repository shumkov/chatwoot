# UMI — conversation labels: what to use, what to delete

Written 2026-08-12. Everything here was checked against the running production
system and the source code; the line references are in the appendix so any claim
can be re-checked.

---

## 1. The question: can Chatwoot do nested, two-level labels?

**No. Labels are one flat list.** There is no parent, no child, no folder. The
label record holds only a name, a colour, a description and a "show in sidebar"
tick. Nothing more.

The workaround is also more restricted than people assume. A label name accepts
**only letters, numbers, hyphens and underscores**. `source/paid` and
`source: paid` are both rejected by the system — it will refuse to save them. So
`source-paid-ads` is not a style choice, it is the only form available.

**What the hyphen prefix actually buys you:** labels are always listed
alphabetically, so `source-` names sit together in the picker, and typing
"source" filters to them. That is the whole benefit. There is **no roll-up** —
you cannot ask for "all `source-*` labels" as one number in a report. Every
label is its own separate row, forever.

Custom attributes do not help either. They are flat: one key, one value. The
`list` type is a fixed set of allowed answers to pick one from (like a dropdown),
not a tree.

### The important reframe

**You already have two levels. They are just split across two systems, and that
split is better than a nested label tree would be.**

| | Level 1 — the label | Level 2 — the attribute |
|---|---|---|
| Example | `source-paid-ads` | `meta_ad_id`, `meta_ad_title` |
| How many | A handful, hand-made | Unlimited, filled in automatically |
| Can you filter the inbox by it? | Yes | Yes |
| Can you get it in a report? | **Yes** | **No** |
| Upkeep | Someone must maintain it | None |

Level 1 answers *"do ad conversations behave differently from organic ones?"* —
and the Labels report is the **only** place in Chatwoot that can answer it.
Level 2 answers *"which exact ad was this?"* — and needs no maintenance because
Meta writes it for you.

That is your hierarchy. Build the top level as a few labels. Let the bottom
level stay as attributes.

**One correction to what you were told earlier:** reports can group by five
things — agent, team, inbox, label **and channel**. Channel was missed. Custom
attributes are still not among them, so the main point stands.

### The closest thing to nesting that actually exists — and it works

If what you want is an **ordered, closed set of choices** rather than a pile of
free-form names, there is a real mechanism for that today, with no code:
a custom attribute of type **list**.

You define the attribute once (`intent`), and you define the allowed answers
(`size-advice`, `colour-advice`, `ready-to-order`, …). Agents then get a
**dropdown** in the conversation sidebar. They cannot invent a new value, cannot
typo one, and none of it appears in the label picker.

That is genuinely two levels: **the attribute name is level 1, the allowed value
is level 2.** It is the direct answer to "will this turn into a flat pile of
names" — it structurally cannot, because only an admin can add a value.

I tested this against production rather than trusting the code:

| | Result |
|---|---|
| Filter the inbox by a conversation attribute | **Works** — confirmed live |
| Filter by an exact value ("equals hiring") | **Works** — confirmed live |
| Combine it with another condition | **Works** — confirmed live |
| Use it as an automation rule condition | Yes, supported |
| Show up in any report | **No.** Never. |

So your instinct is right: **a list attribute is filterable.** Internally
Chatwoot treats a `list` value as plain text, which is the same path I tested,
so this is proven rather than assumed.

**Two things to know before choosing it.**

1. **It holds exactly one value.** That is a *good* fit for anything genuinely
   mutually exclusive — a conversation has one traffic source, not three. It is a
   *bad* fit for topics, where one conversation can be about sizing *and* a
   refund. Labels are a set; a list attribute is a single choice.
2. **It is invisible to reporting, permanently.** Not awkward — absent. There is
   no way to get "average first response time by source" out of an attribute.

### So why not just make labels nested in our fork?

Because it is a large, permanent fork of a core Chatwoot concept, and it does not
buy you the thing you want.

The blocker is deeper than adding a "parent" column. Labels are stored on a
conversation as **plain text tags** — the conversation holds the string
`source-paid-ads`, and knows nothing about any hierarchy. A parent column would
live only in the label settings table as decoration. To make it mean anything,
every place that *reads* labels would have to learn the hierarchy: the picker,
the sidebar, the inbox filter, the saved filters, the automation rule builder,
the CSV import, contact labels, the AI label tool — and the Labels report, which
today emits exactly one row per label with no notion of grouping.

That is the part you actually want (roll-up: "all paid sources as one number"),
and it is also the largest and most fragile piece. Our fork's rule is that a
patch should be a small, removable thing that survives upgrading Chatwoot. This
would be neither — it would conflict on every future Chatwoot release, forever,
with no version where we could drop it.

**And it is not needed.** Nesting solves two problems: a cluttered picker, and
report roll-up. The clutter goes away by having three labels instead of
twenty-seven. The roll-up is only worth building if you have more source
categories than you can read at a glance — and you have one.

If nested labels ever genuinely become the blocker, the right move is to ask
Chatwoot for it upstream, not to carry it here.

### The rule for choosing, from now on

**Two questions: who sets it, and do you need to measure it?**

The first question is a hard constraint, and I had this wrong earlier today.
**An automation rule cannot write a custom attribute.** The complete list of
things a rule can do is: add or remove a label, assign an agent or team, change
status or priority, mute, snooze, resolve, send a message, add a private note,
send an email, or call a webhook. That is all of it. There is no "set attribute"
action.

So:

| Who sets it | What you must use |
|---|---|
| An automation rule | **A label.** No other option exists. |
| A person, in the sidebar | Either — and a list attribute is tidier |
| One of our scheduled jobs | Either — a job is plain code and can write both |

Then the second question:

| | Use a **label** | Use a **list attribute** |
|---|---|---|
| Want it in reports | ✅ only option | ❌ impossible |
| Want a tidy closed set of choices | ❌ anyone can add one | ✅ admin-only |
| One conversation needs several at once | ✅ | ❌ single value |
| Upkeep as it grows | Gets worse — every label is in every picker | Stays flat — values live in one dropdown |

**Put together: anything a rule applies is a label, full stop. Anything a person
picks by hand, and that you never need to measure, is better as a list
attribute.**

This is why `source-paid-ads` must stay a label on both counts — a rule applies
it, and comparing ad traffic against organic on response and resolution time is
the entire point.

---

## 2. What we have today, and the design it was built for

The 27 labels are not a random pile. They are stage 0 of a five-stage customer
funnel designed in an earlier session, where only stage 0 ever got built. That
matters, and it corrects the framing of my first draft: **"25 labels unused" is a
measurement of unfinished work, not of bad design.**

### The inherited design, as written

> One path per customer. Each stage flips one `lead-*` label (mutually
> exclusive), plus optional `intent-` / `support-` / `value-` tags (stackable).
>
> 0. Message arrives → `lead-new`
> 1. Triage & qualify — asks about size/fit/price/colour, shares phone or
>    address, or returns 2–3 times → `lead-qualified` + an `intent-*` tag
> 2. Serve — `intent-*` is what they need, `support-*` is a service issue
> 3. Convert — order placed/paid → `lead-converted`, and `value-*` from real spend
> 4. Go quiet — no reply for 30 days → `lead-lost` → the retargeting pool
> 5. Not a customer → `lead-unqualified` + auto-resolve

Three mechanisms were identified to drive it: **A** native automation rules,
**B** scheduled jobs, **C** Captain (Chatwoot's paid AI). Suggested build order
was Shopify sync first, then the 30-day sweep, then auto-qualify, then keyword
rules.

### Everything currently live

| What | State |
|---|---|
| Labels defined | 27 |
| Labels ever applied to anything | **2** — `lead-new` (52), `spam` (21) |
| Automation rules | **1** — "Auto: tag new conversations as New Lead": on conversation created, if status is open, add `lead-new`. Live since 3 August. |
| Canned responses | 0 |
| Macros | 1 |
| Teams | 0 |
| Conversation attributes | `meta_ad_id`, `meta_ad_ref`, `meta_ad_title` — defined, **all empty** |
| Contact attributes | 10 Shopify fields |
| Scheduled job infrastructure | **Real and proven** — 13 cron jobs run, 3 of them ours (`umi_shopify_contact_poll` every 30 min, plus the FB/IG profile refresh and recon) |
| Captain (AI) | **Off** — `captain_integration: false` |

So mechanism B is genuinely available: we already run our own scheduled jobs in
production. The plan was right about that.

### Where the design meets the data

I measured what each stage would actually label. This is the part that changes
the answer.

| Stage | Would label | Verdict |
|---|---|---|
| 0 · `lead-new` | Everything | Works, but says nothing |
| 1 · `lead-qualified` | **318 of 868** conversations have 3+ inbound messages (309 in FB/IG) | **The only stage with real coverage** |
| 3 · `lead-converted`, `value-*` | **6 of 868** | Blocked — see below |
| 4 · `lead-lost` | 710 idle >30 days, but 0 reachable | Purpose does not work |
| 5 · `lead-unqualified` | Duplicates `spam` | Redundant |

**The blocker for stage 3 is identity, not effort.** 796 contacts are linked to
Shopify. Only **6** of them have ever had a conversation. And of the 758 people
who have messaged the Facebook/Instagram inbox — which is **92% of all
conversations** — exactly **zero** have a Shopify link, an email address, or a
phone number.

They are two separate populations that barely touch. So the plan's "highest value
win — the data's already on your contacts, and it backfills your whole existing
customer base on first run" would in fact label about six conversations, four of
which are email, one is Ivan testing, and none are in the inbox that carries the
volume. **The suggested build order is exactly inverted: the recommended first
job is the lowest-yield one available.**

**Stage 4 has a different problem.** 710 FB/IG conversations have been idle over
30 days, so the sweep would work mechanically. But the stated purpose — "that's
your retargeting pool" — cannot happen: none of those 690 contacts has an email
or phone, so they cannot be uploaded to a Meta Custom Audience. And you do not
need them to be: Meta already lets you retarget "people who messaged your Page"
natively in Ads Manager, without any export. The label would add nothing to a
capability you already have.

### One factual correction to the inherited plan

The plan states: *"Native rules can only add labels, they can't clean up the old
one. So the jobs must remove the previous `lead-*` when they set a new one.
That's the main reason the funnel logic belongs in scheduled jobs rather than
rules."*

**That is not correct — `remove_label` exists as a standard rule action.** A
single rule can add `lead-qualified` and remove `lead-new` in one go, so native
rules *can* keep `lead-*` single-valued.

This does not rescue the whole plan — counting messages and reading Shopify
genuinely do need jobs — but the stated *main reason* for the architecture is
wrong, and it is worth knowing before building anything.

### What this means

The design is coherent. It was drawn for a business where a customer is one
identifiable person across chat and Shopify. **UMI is not that business today** —
92% of conversations are anonymous Meta DMs with no email, no phone, and no order
link. Three of the five stages depend on exactly the link that does not exist.

So the funnel is not wrong, it is **premature**. The thing that unblocks it is
already on the master plan: Shumabit stamping a conversation id onto orders. Once
that lands, stages 3 and 4 become real. Until then, building them produces labels
on six conversations.

---

## 3. What the taxonomy should be: three labels

Today there are 27 labels. **Only two have ever been applied to a single
conversation.** So this is effectively a blank page.

| Label | Applied by | Why it earns its place |
|---|---|---|
| `spam` | A person, by hand | The only label anyone actually uses — 21 conversations, 20 of them closed afterwards. A real habit that already exists. |
| `source-paid-ads` | Automatic rule | Ad traffic vs organic is the one comparison you cannot get any other way, because reports cannot read the ad attributes. Already exists; leave it. |
| `recruitment` | Automatic rule, and by hand | Keeps job applicants out of the sales conversations. New — create it. |

That is it. Three.

The test each one passes: **something reliably applies it, and it answers a
question someone actually asks.** A label that fails either test makes every
label picker longer and teaches agents to ignore label chips altogether. That is
a real cost, not a tidiness preference.

### Where this differs from your original idea

You proposed `source-recruitment`. **I recommend naming it just `recruitment`,**
for one concrete reason: a click on a hiring ad *is* a click on a paid ad, so it
will carry an ad id and pick up `source-paid-ads` automatically. A conversation
tagged both `source-paid-ads` and `source-recruitment` reads as a contradiction —
two answers to "where did this come from". Naming it `recruitment` makes the pair
read correctly: source is paid ads, subject is recruitment. It also stays honest
when someone asks about a job in a normal DM, with no ad involved.

---

## 4. What to delete — all 25 unused labels

Every one of these has been applied to **zero** conversations since the account
began. Deleting them is clean and safe: Chatwoot removes the label from any
conversation still carrying it and tidies up behind itself.

**Deleting is not the same as abandoning the funnel.** Three of these families
have a clear condition that would bring them back, named below. A label costs
nothing to recreate and costs something every day it sits unused in the picker,
so the right place to keep an unbuilt plan is a document — this one — not the
label settings screen.

**Delete these 7 (`intent-`):** `intent-color-advice`, `intent-interested`,
`intent-product-details`, `intent-ready-to-order`, `intent-size-advice`,
`intent-waiting-payment`, `intent-waiting-reply`

**Delete these 6 (`support-`):** `support-after-sales`, `support-complaint`,
`support-exchange`, `support-order-tracking`, `support-refund`,
`support-special-request`

> **Bring back when:** someone wants topic reporting badly enough to keep it up.
>
> These are the *most* buildable part of the inherited plan — keyword rules on
> message content genuinely work, so they could be automated tomorrow. The reason
> to hold off is not feasibility, it is that Thai keyword matching is noisy and
> nobody has asked a question these would answer. There is also nothing in place
> that would prompt an agent to apply them by hand: 0 canned responses, 1 macro.
>
> **If they come back, decide first whether a rule or a person applies them.** A
> rule means labels (a rule cannot write an attribute). A person means one
> `intent` dropdown with seven answers and one `support_topic` dropdown with six —
> two sidebar fields instead of thirteen labels in everyone's picker.

**Delete these 6 (`value-`):** `value-first-time`, `value-high-value`,
`value-influencer`, `value-returning`, `value-vip`, `value-wholesale`

> **Bring back when:** orders can be linked to conversations.
>
> The plan sets these from real Shopify spend, which is the right idea. It cannot
> work yet: of the 758 people in the Facebook/Instagram inbox, zero have a Shopify
> link. A job would label six conversations.
>
> There is also a design problem to solve before reviving them. Spend changes, so
> a spend-derived label goes stale the moment the next order lands — meaning a job
> has to keep re-writing them, and labels would flip on people daily. The Shopify
> figures already sit in the contact sidebar and never go stale. If you want to
> *measure* by customer value, a label is the only way; if you just want to *see*
> it, it is already there.

**Delete `source-organic`**

> Organic is simply "no ad id". Labelling it automatically is not just
> unnecessary, it is **impossible to do correctly** — the ad details are written
> a moment *after* the conversation appears, so at the moment a conversation is
> created every conversation looks organic, including the ad ones. A rule would
> mislabel all of them. Label the exception, not the default. To see organic
> traffic in the inbox, use a saved filter for "labels does not include
> source-paid-ads" — that works correctly in the inbox (see trap 3).

**Delete these 5 (`lead-`), including the one in use:** `lead-new`,
`lead-qualified`, `lead-converted`, `lead-lost`, `lead-unqualified`

> This is the one to think hardest about, because it is the funnel itself. Taken
> stage by stage:
>
> **`lead-new` — delete outright, no revival.** The rule tags it onto every new
> conversation. 52 carry it, **49 are still sitting on it**, and not one
> conversation has ever moved on to a later stage. It does not mean "new lead", it
> means "a conversation exists" — which the Open folder already tells you free.
> A funnel whose first stage is universal and permanent is not a funnel.
>
> **`lead-qualified` — delete for now; bring back when someone will act on it.**
> This is the only stage that would work today: 318 conversations have 3+ inbound
> messages, and a scheduled job could set it. But that is more than a third of
> everything, and "sent three messages" is a weak proxy for "will buy". Before
> building it, answer one question: **what would you do differently for a
> conversation once it is labelled?** If there is no different action, the label
> is a statistic, and the report you would build it for does not exist yet.
>
> **`lead-converted` — delete; bring back when orders link to conversations.**
> Right idea, blocked on identity. Six conversations today. The unblocking event
> is already on the master plan: Shumabit stamping a conversation id onto orders.
> **When that ships, this is the first label to recreate** — it is the one that
> would finally answer "which conversations make money".
>
> **`lead-lost` — delete, and do not revive it in this form.** The 30-day sweep
> works, but the purpose does not: its 690 contacts have no email and no phone, so
> they cannot be retargeted from here, and Meta already offers "people who
> messaged your Page" natively. If you want the *operational* version — "stop
> looking at conversations nobody will reply to" — Chatwoot already has it:
> auto-resolve is enabled on this account.
>
> **`lead-unqualified` — delete permanently.** It is `spam` with a longer name,
> and `spam` is the one label anyone actually uses. Two names for one idea is how
> a taxonomy starts rotting.

**Net result: 27 labels → 3**, with the funnel written down here and a named
trigger for each piece rather than sitting half-built in the settings screen.

---

## 5. The two automation rules to create

First **delete the existing rule** ("Auto: tag new conversations as New Lead"),
since `lead-new` is going away.

Then, in Settings → Automation → Add rule:

### Rule 1 — mark ad traffic

| Field | Value |
|---|---|
| Name | `Tag conversations that came from an ad` |
| Event | **Conversation Updated** |
| Condition | `meta_ad_id` (under Conversation Custom Attributes) → **Is present** |
| Action | Add label → `source-paid-ads` |

### Rule 2 — split off job applicants

| Field | Value |
|---|---|
| Name | `Tag hiring-ad conversations as recruitment` |
| Event | **Conversation Updated** |
| Condition | `meta_ad_ref` (under Conversation Custom Attributes) → **Equal to** → `hiring` |
| Action | Add label → `recruitment` |

Create the `recruitment` label first, in Settings → Labels — otherwise see
trap 1.

**Both rules must be "Conversation Updated", not "Conversation Created".** The ad
details are written onto the conversation a fraction of a second *after* it is
created. A "Created" rule runs too early, finds nothing, and silently labels
nothing. This is by design in our ad-capture patch, not a workaround.

**These rules will not loop.** Chatwoot ignores events caused by an automation
rule, so a rule adding a label cannot re-trigger itself. Verified in the code.

---

## 6. Before these rules can work — one thing must be confirmed

**No conversation in production carries an ad id today. Not one.** In fact no
conversation has any custom attributes at all yet.

The plumbing is genuinely in place: the ad-capture code is loaded in the running
system and the three attributes (`meta_ad_id`, `meta_ad_ref`, `meta_ad_title`)
are defined and ready. But nothing has arrived through it yet, because the Meta
setting that delivers ad details on Messenger (`messaging_referrals`) was only
switched on **today, 12 August**.

This matters: **a rule built on an attribute that never arrives is silently
inert.** It does not error, it does not warn, it simply never fires — and job
applicants would land in the shop queue anyway, which is the exact thing you are
trying to prevent.

**So: create the rules, then confirm with one real ad click.** After the next
click-to-Messenger ad click, check that the conversation shows an ad id in its
sidebar. If it does, both rules are live. If it does not, the Meta subscription
needs another look before trusting either rule.

---

## 7. How to identify recruitment traffic: use a ref, not a list of ad ids

**Recommendation: have the ads person set `ref=hiring` on every hiring ad.** Do
not maintain a list of ad ids.

Our ad-capture code already reads Meta's `ref` field straight into
`meta_ad_ref`, so nothing needs building — it works the moment the ads are set
up that way.

| | `ref=hiring` | A list of ad ids |
|---|---|---|
| Upkeep | None. New hiring ads inherit it when duplicated. | Someone must add every new ad id to the rule, forever. |
| When someone forgets | The new ad is missing a ref — visible on the ad itself. | The rule quietly stops matching. Nothing tells you. |
| Readable? | Yes — `hiring` says what it is. | No — `120249289177590415` says nothing. |

The deciding point: **the two known recruitment ad ids are both paused.** The
campaign hasn't launched. Whatever ads actually run will have new ids, so a list
built from those two would be out of date on day one. And the hiring campaign
being unlaunched is exactly why the ref approach is available — it can be set
before anything goes live, which is the only time it is easy.

**Ask the ads person for two things:**
1. Set the ref to exactly `hiring` — lower case, no spaces. The rule matches the
   text exactly.
2. Put the word "hiring" in the ad's name too. That is not used by any rule, but
   it shows up in the conversation sidebar, so an agent can see it at a glance
   even if the ref was missed.

---

## 8. Per-ad labels: your reasoning holds — don't do it

Confirmed against the code. A label per ad would be wrong for three reasons:

1. **482 ads, one shared alphabetical list.** Every label appears in every
   picker for every agent on every conversation. It would be unusable, and the
   Labels report would become 500 rows of almost entirely zeros.
2. **Ads are disposable, labels are permanent.** A paused ad's label stays in the
   picker forever unless someone remembers to delete it.
3. **It adds nothing you cannot already do.** The ad id is on the conversation
   and is filterable — you can pull up every conversation from one specific ad
   today, without any label.

**The one honest gap:** per-ad labels *would* give you per-ad response and
resolution times in the Labels report, which the attributes cannot. If that ever
becomes a real question, the answer is a handful of **campaign-theme** labels
(not per-ad ones) — and not now, when zero ad conversations have been captured
yet. Per-ad *performance* — spend, reach, cost per result — is Ads Manager's job,
and Chatwoot will never have those numbers.

---

## 9. Six traps worth knowing about

**Trap 1 — an automation rule can invent a label that never appears in
Settings.** This corrects something you were told. An `add_label` action does
**not** require the label to exist first. If the name doesn't match a real label,
Chatwoot tags the conversation anyway: the chip shows on the conversation,
filters find it, and it looks completely normal. But it never appears in
Settings → Labels, and — the real damage — **the Labels report only ever lists
labels that exist as proper records, so that tag is invisible in reporting,
permanently and silently.**

You are safe when clicking through the UI, because the rule builder makes you
pick from existing labels. The trap is reachable through the API, a CSV import,
or Chatwoot's AI label-suggestion feature, which passes a name the model made up.
**So: always create the label in Settings first.** Right now there are no
invented labels in production — verified, it is clean.

**Trap 2 — "Conversation Created" rules miss the ad details.** Covered in
section 5. Use "Conversation Updated".

**Trap 3 — "labels does not include X" is broken in automation rules, but works
in the inbox.** In an automation rule it means "has some other label", not
"doesn't have this one" — a conversation labelled `source-paid-ads` would pass a
"does not include `recruitment`" test. **Never use it in a rule.** In the inbox
filter and saved views it is implemented differently and is correct, so
"conversations without `source-paid-ads`" is a perfectly good saved filter.

**Trap 4 — rules do not chain.** Chatwoot ignores anything an automation rule
did, which is what stops loops (good) but also means one rule cannot trigger
another. Both rules above are independent, so this is fine — just don't design
a rule that expects a label another rule applied.

**Trap 5 — a "does not equal" filter on a custom attribute crashes unless it is
the last condition.** Found while testing this document, and reproduced against
production. Filtering for *"meta_ad_ref does not equal hiring"* on its own works
and returns the right answer. Add a second condition after it and the search
fails outright with a database error, because Chatwoot builds the query as
`AND OR`. If you hit an error building a filter, move the "does not equal" row to
the bottom of the list. This is an upstream Chatwoot bug, not something we
introduced, and it applies to any custom attribute — not just ours.

**Trap 6 — currency and percent attributes cannot be filtered at all.** Chatwoot
knows how to filter text, number, link, date, list and checkbox attributes, but
its filter code has no entry for `currency` or `percent`, so filtering one
produces a broken query. Avoid those two types; use `number` instead.

---

## 10. Corrections to earlier figures

| Was said | Actually measured today |
|---|---|
| `lead-new` on 31 conversations, `spam` on 3 | **52** and **21** |
| Every ad conversation now carries `meta_ad_id` | **Zero** conversations carry it. The code is deployed and ready; nothing has come through yet. |
| Reports group by agent, team, inbox, label | Also by **channel** — five, not four |
| `add_label` needs the label to exist first | It does not. See trap 1. |
| The `lead-new` rule has been running a while | It started **9 days ago**, on 3 August |
| Native rules can add labels but cannot remove the old one | **They can.** `remove_label` is a standard rule action. |
| A rule could set a custom attribute | **It cannot.** There is no such action. Anything a rule applies must be a label. |
| Shopify sync is the highest-value first job — it backfills the whole customer base | It would label **6 conversations of 868**, and **0** in the Facebook/Instagram inbox. 796 contacts are Shopify-linked; only 6 have ever had a conversation. |
| `lead-lost` gives you a retargeting pool | The 690 contacts have no email and no phone, so they cannot be exported to Meta. Meta already offers this natively. |
| Captain is a paid feature and is off | Correct — `captain_integration: false`, confirmed |
| Scheduled jobs are an available mechanism | Correct — 13 cron jobs run in production, 3 of them ours |

---

## 11. Do this, in order

1. Delete the rule "Auto: tag new conversations as New Lead".
2. Delete the 25 labels listed in section 4.
3. Create the label `recruitment`.
4. Create rules 1 and 2 from section 5.
5. Ask the ads person to set `ref=hiring` on the hiring ads before launch.
6. After the next ad click, open the conversation and check an ad id appears in
   the sidebar. Until you have seen that once, treat both rules as unproven.

### And when to revisit the funnel

Do not build it in the order the earlier plan suggested — that order starts with
the lowest-yield job available. The triggers to watch for instead:

| Bring back | When |
|---|---|
| `lead-converted` | Shumabit stamps a conversation id onto orders. That single change turns stage 3 from 6 conversations into all of them, and is already on the master plan. |
| `value-*` | Same trigger, plus a decision on how to stop spend-derived labels going stale. |
| `lead-qualified` | Someone can name what they would *do* differently for a qualified conversation. |
| `intent-*` / `support-*` | Someone asks a topic question a report would answer. Then pick: rule-applied means labels, hand-applied means two dropdowns. |
| `lead-lost` | Never in this form. Use auto-resolve, which is already switched on, and Meta's native "people who messaged your Page" audience. |

**The single highest-value thing on this page is not a label.** It is the
order-to-conversation link. Until it exists, the funnel cannot be measured, and
most of the 27 labels have nothing to attach to.

No production changes have been made. This document is a recommendation only.

---

## Appendix — where each claim was checked

**Labels are flat, and the name is restricted**
- `db/schema.rb` labels table, `app/models/label.rb` — name, description, colour,
  sidebar flag, account. No parent field.
- `lib/regex_helper.rb:7` — names allow only letters, numbers, `_`, `-`.
- `app/models/label.rb` — names are forced to lower case; list is always sorted
  by name.

**Reports cannot group by custom attributes**
- `app/builders/v2/reports/drilldown_builder.rb:10` — dimensions are account,
  inbox, agent, label, team.
- `config/routes.rb:500-506` — summary reports expose agent, team, inbox, label,
  channel.
- No reference to custom attributes exists anywhere in `app/builders/v2/` or
  `app/helpers/api/v2/`.

**Custom attributes are flat; `list` is a fixed set of answers**
- `app/models/custom_attribute_definition.rb` — the eight types, exactly as
  described; allowed values are stored as a plain list.
- `app/javascript/.../automationHelper.js:64-69` — a text attribute supports
  equal to / not equal to / is present / is not present.

**`add_label` does not require the label to exist**
- `app/services/action_service.rb` → `app/models/concerns/labelable.rb` — writes
  a tag; nothing creates a label record.
- `app/builders/v2/reports/label_summary_builder.rb:16` — the Labels report
  starts from label records only, so an invented tag can never appear in it.
- `app/javascript/.../automation/constants.js:734-737` — the rule builder offers
  a pick-list, which is why the UI is safe.
- `enterprise/lib/captain/tools/add_label_to_conversation_tool.rb:29` — the AI
  tool passes a name straight through.

**"Does not include" behaves differently in rules and in the inbox**
- `app/services/automation_rules/conditions_filter_service.rb:170-175` and
  `:187-195` — rules compare names across a join. Broken for absence.
- `app/services/filter_service.rb:118-137` — the inbox filter uses a
  "no such tag exists" test. Correct.

**Rules cannot loop, and cannot chain**
- `app/listeners/automation_rule_listener.rb:40, 73-75` — events caused by an
  automation rule are ignored.

**Ad details are written after the conversation is created**
- `umi/app/builders/fbig_ad_attribution.rb:53-72` — the update happens on the
  incoming message and deliberately relies on the "conversation updated" event.
- `umi/app/builders/fbig_ad_attribution.rb:48` — `meta_ad_ref` is Meta's `ref`
  field, set per ad by whoever builds the campaign.
- `app/models/conversation.rb:313-327` — a change to custom attributes or labels
  is what raises that event.

**Deleting a label is clean**
- `app/controllers/api/v1/accounts/labels_controller.rb` →
  `app/services/labels/destroy_service.rb` — removes the label from every
  conversation and contact holding it.

**Custom attribute and label filters, run live against production (read-only)**
- `app/services/filters/custom_attribute_filter_helper.rb` targets the
  `conversations` table for conversation attributes, so they are genuinely
  filterable; `app/services/filter_service.rb:9-11` maps `list` to `text`, which
  is why testing the text path proves the list path.
- Confirmed working: attribute `is present` → ran clean; attribute `equals` →
  ran clean; attribute `equals` plus a second condition → ran clean.
- Confirmed broken: attribute `does not equal` followed by another condition →
  `PG::SyntaxError: syntax error at or near "OR"`. Alone it is correct and
  correctly includes conversations that have no value at all.
- Confirmed correct: `labels equal to lead-new` → 52; `labels does not equal
  lead-new` → 816, which is exactly 868 − 52; combined with `status open` → 105.
  So label absence in the inbox filter is right, unlike in automation rules.
- `currency` and `percent` are absent from the filter type map, so they cannot be
  filtered.

**What a rule can and cannot do**
- `app/services/action_service.rb` plus `app/services/automation_rules/action_service.rb`
  hold the complete action list: add/remove label, assign/unassign agent or team,
  change status or priority, mute, snooze, resolve, open, pending, send message,
  private note, attachment, email transcript, email to team, webhook — and
  `add_sla` in the enterprise overlay. **No action writes a custom attribute**,
  and `remove_label` does exist.
- `lib/filters/filter_keys.yml:216-237` — message `content` supports `contains`
  and `does not contain`, so keyword rules are genuinely feasible.

**Whether the inherited funnel can be fed (measured 2026-08-12, read-only)**
- 5,344 contacts; **796** carry a Shopify link (`shopify_customer_id`,
  `shopify_orders_count`, `shopify_total_spent` in `additional_attributes`).
- Only **6** Shopify-linked contacts have ever had a conversation — 4 email,
  1 web, 1 voice. Two of the six are Ivan's own test contacts and one has 0
  orders.
- Facebook/Instagram inbox: 795 conversations, 758 distinct contacts, of which
  **0** have a Shopify link, **0** have an email, **0** have a phone number.
- 710 FB/IG conversations idle over 30 days, across 690 contacts — again 0 with
  email or phone, so not exportable to a Meta Custom Audience.
- **318** of 868 conversations have 3 or more inbound messages (309 in FB/IG).
- `captain_integration` is **false**. `auto_resolve_conversations` is enabled.
- 13 sidekiq-cron jobs run, including our own `umi_shopify_contact_poll` (every
  30 min), `umi_fbig_profile_refresh` and `umi_fbig_recon`.

**Production, measured 2026-08-12 (read-only)**
- 27 labels; only `lead-new` (52) and `spam` (21) have ever been applied.
- `lead-new`: 49 open, 3 resolved. First applied 3 August.
- Zero conversations hold any custom attributes; zero invented labels; only two
  tag records exist in total.
- Zero canned responses, one macro, no teams.
- The ad-capture code is loaded and the three ad attributes are defined.
