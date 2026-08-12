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

---

## 2. What the taxonomy should be: three labels

Today there are 27 labels. **Only two have ever been applied to a single
conversation.** The other 25 have never been used once, by anyone. So this is
effectively a blank page.

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

## 3. What to delete — all 25 unused labels

Every one of these has been applied to **zero** conversations since the account
began. Deleting them is clean and safe: Chatwoot removes the label from any
conversation still carrying it and tidies up behind itself.

**Delete these 7 (`intent-`):** `intent-color-advice`, `intent-interested`,
`intent-product-details`, `intent-ready-to-order`, `intent-size-advice`,
`intent-waiting-payment`, `intent-waiting-reply`

**Delete these 6 (`support-`):** `support-after-sales`, `support-complaint`,
`support-exchange`, `support-order-tracking`, `support-refund`,
`support-special-request`

> Both groups describe what a conversation is *about*. Only a human can apply
> them, and there is nothing in place that would prompt anyone to — no canned
> responses (0 exist) and one macro. If a habit ever forms, recreating a label
> takes ten seconds. Deleting is reversible; clutter never fixes itself.

**Delete these 6 (`value-`):** `value-first-time`, `value-high-value`,
`value-influencer`, `value-returning`, `value-vip`, `value-wholesale`

> These duplicate information you already hold and never have to maintain. The
> customer sidebar already carries `shopify_orders`, `shopify_lifetime_spent` and
> `shopify_tags` from Shopify. A hand-applied "VIP" label would go stale the
> moment someone's next order lands; the Shopify figure never does.

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

> This is the recommendation to think hardest about, so here is the measurement.
> The rule tags `lead-new` onto every new conversation. 52 carry it. **49 are
> still sitting on `lead-new` right now**, and not one conversation has ever been
> moved on to `lead-qualified`, `lead-converted` or `lead-lost`. So `lead-new`
> does not mean "new lead" — it means "a conversation exists", which the Open
> folder already tells you for free.
>
> It also solves the applicant problem better than any label could: if there is
> no sales funnel in the labels, an applicant cannot be sitting in it.
>
> **Build a funnel later if you want one — but only once a person has committed
> to moving conversations along it.** Until then it is decoration that makes
> every conversation look identical. Chatwoot's own priority and status fields
> already do a light version of this, natively, and appear in reports.

**Net result: 27 labels → 3.**

---

## 4. The two automation rules to create

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

## 5. Before these rules can work — one thing must be confirmed

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

## 6. How to identify recruitment traffic: use a ref, not a list of ad ids

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

## 7. Per-ad labels: your reasoning holds — don't do it

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

## 8. Four traps worth knowing about

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
section 4. Use "Conversation Updated".

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

---

## 9. Corrections to earlier figures

| Was said | Actually measured today |
|---|---|
| `lead-new` on 31 conversations, `spam` on 3 | **52** and **21** |
| Every ad conversation now carries `meta_ad_id` | **Zero** conversations carry it. The code is deployed and ready; nothing has come through yet. |
| Reports group by agent, team, inbox, label | Also by **channel** — five, not four |
| `add_label` needs the label to exist first | It does not. See trap 1. |
| The `lead-new` rule has been running a while | It started **9 days ago**, on 3 August |

---

## 10. Do this, in order

1. Delete the rule "Auto: tag new conversations as New Lead".
2. Delete the 25 labels listed in section 3.
3. Create the label `recruitment`.
4. Create rules 1 and 2 from section 4.
5. Ask the ads person to set `ref=hiring` on the hiring ads before launch.
6. After the next ad click, open the conversation and check an ad id appears in
   the sidebar. Until you have seen that once, treat both rules as unproven.

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

**Production, measured 2026-08-12 (read-only)**
- 27 labels; only `lead-new` (52) and `spam` (21) have ever been applied.
- `lead-new`: 49 open, 3 resolved. First applied 3 August.
- Zero conversations hold any custom attributes; zero invented labels; only two
  tag records exist in total.
- Zero canned responses, one macro, no teams.
- The ad-capture code is loaded and the three ad attributes are defined.
