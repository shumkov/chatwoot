# What Meta will tell us about Facebook and Instagram customers

Investigation, 2026-08-13. Answers one question: **are we taking everything Meta
offers about the people who message us, or leaving useful things on the table?**

Short answer: **we are leaving a lot on the table, and most of it costs nothing
to pick up.** Two of the three findings need no new Meta permission, no App
Review, and — for the biggest one — not even an extra API call.

---

## The three findings, in one paragraph each

**1. We already collect the four commercially useful Instagram fields, and then
hide them.** Every Instagram customer's follower count, verified badge, and
whether they follow UMI is already fetched and already sitting in the database —
on 563 of 676 Instagram contacts. Nothing displays it, nothing can filter on it,
and no agent can see it. **196 of those contacts have 5,000+ followers. 18 have
over 100,000. 229 of them already follow UMI.** The data has been arriving for
months into a field the product does not read.

**2. A second Meta endpoint rescues most of the "impossible" Instagram
contacts — and it is the influencer half.** The 121 Instagram contacts that the
profile API refuses (error 230) were written off as a permanent floor. A
different endpoint, **Business Discovery**, answers for **77 of those 121**,
using only permissions the token already holds. It returns a real name, a
profile picture, a follower count, a bio, and a personal website. **43 of the 77
have 10,000+ followers; 20 have over 100,000.** The single largest is 613,737.
These are currently displayed to agents as a bare handle with no photo.

**3. Facebook is close to exhausted.** For Messenger contacts we already take
everything the token can reach. The three remaining fields — language, timezone,
gender — are all denied and would each need a new permission through Meta App
Review. Nothing else is available.

**And one thing that will never be solved this way:** Meta does not give out
email addresses or phone numbers, on either platform, under any permission. The
`...@facebook.com` string that shows up in one API response is a fake
placeholder built from the user's ID, not a real address — see *Dead ends*. The
empty-lead-funnel problem cannot be fixed from profile data. What profile data
*can* do is qualify people a different way: by audience size, by whether they
already follow UMI, and — for about 60% of Instagram business accounts — by the
personal website link they publish, which is often a LINE or TikTok address.

---

## How this was measured

Everything below was checked against the live Meta API using UMI's production
page token, against real contacts from inbox 2. Nothing was written.

| Check | Sample |
|---|---|
| Contact census | **all 764** contacts in inbox 2 (676 Instagram, 88 Facebook) |
| Which fields come back | 8 Instagram + 8 Facebook contacts, 2–3 request shapes each |
| Can the "impossible" contacts be reached | **all 113** Instagram contacts missing profile data |
| Do stored values go stale | 60 Instagram contacts, stored vs live |
| Are contacts shown a handle when a real name exists | **all 45** handle-named contacts |
| Business Discovery hit rate | **all 121** Instagram contacts with no photo |
| Does Business Discovery add anything for contacts we already cover | 25 sampled (20 answered) |
| Does the rescued photo actually download | 3, fetched end to end |

Roughly 550 Meta API calls in total.

---

## Table 1 — Instagram

Every field Meta returns for someone who has messaged the business.

| Field | Do we take it? | Worth taking? | Where it would live | Cost |
|---|---|---|---|---|
| `username` (the @handle) | **Yes** | — | Already shown as the Instagram icon in the contact sidebar | free |
| `name` (display name) | **Yes** | — | Already the contact's name | free |
| `profile_pic` | **Yes** | — | Already the contact's photo | free |
| `follower_count` | **Fetched and stored — but invisible** | **Yes, high** | Contact field, type *number* → filterable, e.g. "followers over 10,000" | **free — already in the reply we get** |
| `is_user_follow_business` | **Fetched and stored — but invisible** | **Yes** | Contact field, type *checkbox* | free, same reply |
| `is_verified_user` | **Fetched and stored — but invisible** | Yes, moderate | Contact field, type *checkbox* | free, same reply |
| `is_business_follow_user` | **Fetched and stored — but invisible** | Low — it describes UMI's behaviour, not the customer's | Contact field, *checkbox* | free, same reply |

There is nothing else. Asking Meta for extra fields by name (`biography`,
`website`, `media_count`, `account_type`) returns *"Tried accessing nonexisting
field"* on every one. This endpoint gives seven fields and no more.

Two details worth knowing:

- Meta returns all seven **without being asked** — the request Chatwoot sends
  names no fields at all and still gets the full set. So the commercial fields
  arrive on every single Instagram profile fetch we already make. Confirmed
  identical on 8 contacts, requesting the fields explicitly versus not at all.
- **The nightly profile refresher throws them away.** It receives the full reply
  and writes only the name, handle and photo. So the four fields are frozen at
  whatever they were the day the contact was created, and any contact the
  refresher fixed later never got them at all.

---

## Table 2 — Facebook / Messenger

| Field | Do we take it? | Worth taking? | Where it would live | Cost |
|---|---|---|---|---|
| `first_name`, `last_name` | **Yes** | — | Already the contact's name | free |
| `profile_pic` | **Yes** | — | Already the contact's photo | free |
| `name` (full name, one string) | No | **No** — it is just first + last, which we already join ourselves | — | free but pointless |
| `locale` (the customer's language) | **No — denied** | Would be genuinely useful (Thai vs English routing) | Contact field, *text* | Needs the `pages_user_locale` permission → **Meta App Review** |
| `timezone` | **No — denied** | Low | Contact field, *number* | Needs `pages_user_timezone` → App Review |
| `gender` | **No — denied** | Low-to-moderate for a clothing brand | Contact field, *text* | Needs `pages_user_gender` → App Review |

All three denials return the same error on all 8 contacts tested:
*"Insufficient permission to access user profile"*. They are a permission
problem, not a data problem — Meta has the values and will not hand them over
without review.

There is **no** Facebook equivalent of the Instagram Business Discovery rescue.
What we have on Messenger is what there is.

---

## Table 3 — Business Discovery (a route we do not use at all today)

This asks Meta, through UMI's own Instagram business account, for the **public**
profile of another Instagram account, by handle. It is how any brand looks up a
creator. It works on **Business and Creator accounts only** — personal accounts
are invisible to it.

Crucially, **it does not care about the error-230 consent wall.** It answered
for contacts the profile API flatly refuses.

| Field | Do we take it? | Worth taking? | Where it would live | Cost |
|---|---|---|---|---|
| `profile_picture_url` | No | **Yes, high** — gives a photo to **77 contacts who have none** | Contact photo | 1 call |
| `name` | No | **Yes, high** — a real name for **74** contacts currently shown as a bare handle | Contact name | same call |
| `followers_count` | No | **Yes, high** — the only way to size these 77 | Contact field, *number* | same call |
| `website` | No | **Yes** — present for **48 of 77**; frequently a LINE (`lin.ee`), Linktree or TikTok address. The only off-Meta identity Meta will give us | Contact field, *link* | same call |
| `biography` | No | Moderate — useful context for an agent opening a cold DM. Present on 20 of 20 sampled | Contact field, *text* | same call |
| `media_count` | No | Low | Contact field, *number* | same call |
| `follows_count` | No | Low | Contact field, *number* | same call |

**Hit rate, measured on all 121 photo-less Instagram contacts:** 77 answered, 44
did not (error 110 — not a business or creator account). Of the 77 rescued:

| Follower range | Contacts |
|---|---|
| 100,000+ | 20 |
| 10,000–100,000 | 23 |
| 5,000–10,000 | 8 |
| 1,000–5,000 | 18 |
| under 1,000 | 8 |

The largest are `@marinaemmb` (613,737), `@lena_helenabusch` (596,088) and
`@tayastarling` (368,217). **All twelve of the largest currently appear in
Chatwoot as a lowercase handle with no photo** — indistinguishable from a
random shopper.

For contacts we *already* cover, Business Discovery still adds the bio (20 of 20
sampled), a website (12 of 20) and a display name (18 of 20). It is worth
running for them too, though it is a second call rather than a free ride.

No new permission is required. The token already holds `instagram_basic` and
`instagram_manage_insights`, which is everything this endpoint needs. **No App
Review, no waiting on Meta.**

---

## Where these things would actually live in Chatwoot

This matters, because the entire first finding is a story about data that had
nowhere to go.

Chatwoot has **two** places to hang extra facts on a contact, and they behave
completely differently:

| | Visible to agents | Filterable / segmentable | Usable in automation rules | Fed to an AI assistant |
|---|---|---|---|---|
| `additional_attributes` — **where all this data sits today** | **No** | **No** | **No** | **No** |
| `custom_attributes` — needs a one-line definition per field | **Yes**, in the contact sidebar | **Yes** | **Yes** | **Yes** |

So the fix for finding 1 is not "collect more data". It is **move the data we
already have from the invisible bucket to the visible one**, which needs a
definition record per field — the same pattern patch 20 already uses for the ad
attribution fields (`Umi::Meta::AdAttributeDefinitionSetup`).

Once they are custom attributes, a number field like follower count supports
real comparisons, so "every Instagram contact with over 10,000 followers"
becomes a saved segment, and an automation rule can label those conversations
the moment they open. That is the difference between having the number and being
able to act on it.

Three fields have no good home and should not be taken: Meta's `name` for
Facebook (duplicate), `media_count` and `follows_count` (nothing would ever read
them).

---

## What it would cost

**Finding 1 — surfacing the four Instagram fields: effectively free.**
No new API calls at all. The values already arrive in a reply we already make
and already sit in the database for 563 contacts. The work is a definition per
field, a one-time copy of existing values, and four lines in the nightly
refresher so future contacts keep them updated.

**Finding 2 — Business Discovery: two calls per contact, one time.**
For a contact the profile API has refused we do not know their handle, so it
takes one call to look it up and a second to fetch the profile. **242 calls to
cover all 121** today, then only a handful a day as new blocked contacts arrive.
Running it for the already-covered contacts too would be about 676 calls more.

**The rate limit is the real constraint, and it is sharper than expected.**
Meta reports app quota usage as a percentage of a rolling hourly allowance. After
this investigation's ~550 calls, that counter read **94** — i.e. within a few
percent of being throttled. One reading, and I cannot cleanly separate my probes
from UMI's normal background traffic, so treat it as a warning rather than a
precise measurement. But the direction is unambiguous: **this quota is shared
with live message delivery**, so an unthrottled backfill risks degrading
messaging for real customers. Any backfill must be paced and run overnight — the
same lesson the Shopify FAQ sync learned the hard way.

**Refreshing follower counts is not worth doing often.** Measured on 60
contacts: the number had moved for 52 of them, but the median change was **6
followers**, and **not one moved by more than 10%**. Nobody crosses a meaningful
threshold in a month. Quarterly is plenty; nightly would burn quota for nothing.
The one field that does change meaningfully is *follows the business* — someone
who follows UMI after their first DM — but that moved for only 1 contact in 60.

---

## Dead ends — being honest about these

**44 Instagram contacts are genuinely unreachable.** They are personal accounts:
the profile API refuses them (error 230) and Business Discovery does not see
them (error 110). No permission fixes this; Meta simply does not expose personal
accounts to businesses. This is the new floor. It is much better than the 121 we
thought we had, but it is real and it will not move.

**The participants endpoint gives nothing extra.** This is the trick that beats
error 230 for names. I asked it for follower counts and verification status: it
**silently ignores the request and returns its fixed shape anyway** — name and ID
for Messenger, handle and ID for Instagram. No error, just the same reply. It
cannot be extended.

**The `@facebook.com` address is not an email.** The Messenger participants reply
contains `28496282546630721@facebook.com`. That is the user's ID with a domain
stuck on it — Meta generates one for every user. It does not receive mail and it
identifies nobody. **It must never be written into a contact's email field**: it
would look like the lead funnel had been solved while making the contact
permanently unmergeable with the real person.

**Meta gives no email and no phone number.** Not on Facebook, not on Instagram,
not under any permission or review. The 758-contacts-with-no-identity problem is
not solvable from profile data, and nothing in this document should be read as
solving it.

**Language, timezone and gender are behind App Review.** Reachable in principle,
but each needs its own permission granted by Meta, with the usual review delay.

---

## Recommendation, ranked

**1. Surface the four Instagram fields we already collect.** *(free, no Meta
dependency, largest immediate return)*
563 contacts light up at once: 196 with 5,000+ followers, 18 above 100,000, 229
already following UMI, 73 verified. Given that influencer barter is an actual
part of this business — 7 gifted orders in 60 days — knowing at a glance that an
incoming DM is from a 100,000-follower account is directly operational. Today
that is invisible even though the number is already in the database.

**2. Add Business Discovery to the nightly profile refresher.** *(no new
permission, ~242 calls one-time, must be throttled)*
Rescues 77 of the 121 written-off contacts: 77 photos, 74 real names, 48
websites. Forty-three of them have 10,000+ followers. This is where the
influencer population has been hiding, and it is the finding most likely to
change how a conversation gets handled.

**3. Take the website field seriously.** *(rides along with item 2)*
It is the only piece of off-Meta identity Meta will hand over, present on about
60% of business accounts, and often a LINE link — a channel UMI already runs.
Not a funnel fix, but the closest thing available.

**4. Refresh quarterly, not nightly.** Follower counts barely move. Spend the
quota on covering *more* contacts rather than re-checking the same ones.

**5. Leave Facebook alone for now.** We take everything reachable. Language
(`locale`) is the only one worth an App Review request, and only if routing by
language is something UMI actually wants.

**Do not build:** anything that treats `<id>@facebook.com` as an email; a
nightly follower-count refresh; `media_count` or `follows_count` capture.

---

## Notes for whoever implements this

Two traps cost time during this investigation and will cost it again.

**Koala modifies the options hash you pass it.** A shared or frozen constant for
the API version raises `FrozenError: can't modify frozen Hash` on the first call
and then on every call after it. Build a fresh hash per request.

**The API version must be a symbol key.** `{ api_version: 'v25.0' }` works;
`{ 'api_version' => 'v25.0' }` is silently ignored and falls back to a default
that nothing sets, which fails later with a deprecation error while the code
looks correct. This is already recorded for the ad attribution work and it bit
again here.

Also worth knowing: the Instagram profile request Chatwoot sends on the
Facebook-page-linked path (`Instagram::Messenger::MessageText`) asks for **no
fields at all** and relies on Meta's defaults. That happens to return all seven
fields today. It is not contractual — if Meta trims its default set, the four
commercial fields disappear with no error and no log line. Naming the fields
explicitly costs nothing and removes that risk.
