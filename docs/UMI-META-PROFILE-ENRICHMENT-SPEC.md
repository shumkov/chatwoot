# Surfacing the Instagram profile data Meta already gives us

Implementation record for patch 22. The research it implements is
`docs/UMI-META-PROFILE-FIELDS-SPEC.md`; this document records only what was
decided, what was measured before building, and what changed against that
investigation.

---

## What this does

1. **Makes the four Instagram fields Chatwoot already collects visible.**
   Follower count, verified badge and both follow relationships arrive on every
   Instagram profile fetch — unrequested — and upstream files them in
   `additional_attributes`, which no sidebar, filter, automation rule or AI
   assistant reads. They are now projected into `custom_attributes` with a
   definition row each, on the live path and on the nightly pass. **569
   production contacts light up with no new API call.**
2. **Adds Business Discovery to the nightly refresher.** A second Meta endpoint
   that answers for the Instagram accounts the messaging profile API refuses
   with error 230, keyed by handle through UMI's own Instagram account. It
   supplies a photo, a real name, a follower count, a website and a bio.
3. **Captures the website and bio** that only Business Discovery returns. The
   website is the single piece of off-Meta identity Meta will hand over, and is
   frequently a LINE link.

## Measured against production before building

Read-only, 2026-08-13, inbox 2 (account 1, `Channel::FacebookPage`,
`instagram_id=17841468119523354`).

| | |
|---|---|
| Meta contacts | 772 (682 Instagram by conversation type) |
| Carry the four fields already | **569** |
| Follower bands | <1k: 212 · 1k–5k: 158 · 5k–10k: 66 · 10k–100k: 115 · **100k+: 18** |
| Verified / follow UMI | 73 / 230 |
| Contacts with any `custom_attributes` | **0** — the visible bucket was entirely empty |
| No avatar | 127, of which **121 Instagram** |
| Business Discovery probe | 3 calls: `@marinaemmb` and `@nasa` answered in full; a bogus handle returned error 110 |

## Two findings that changed the investigation's numbers

**The one-time cost is ~121 calls, not 242.** The investigation assumed each
unreachable contact needs a participants lookup for its handle before Business
Discovery can be asked. It does not: 10 of the 121 already store
`social_instagram_user_name`, and the other 117 carry the handle as
`contacts.name`, written there by patch 19 through the participants endpoint —
which for Instagram returns the handle and nothing else. Where
`name == umi_profile_name` the refresher wrote it and still owns it, so it is a
machine value, not an agent's wording. Every one of the 121 is reachable in a
single call.

**A `number` custom attribute cannot be compared in the UI.** Both filter
implementations map `number` to equality operators only
(`dashboard/helper/automationHelper.js:68`,
`components-next/filter/operators.js`). `is_greater_than` exists in
`FilterService` but no UI offers it for numbers, so the investigation's
expectation that *"followers over 10,000 becomes a saved segment"* does not hold
on this version — an agent cannot author that filter or that automation rule.
This is why the banded `instagram_audience` list attribute exists: it is the
only form of audience size that is actually actionable. The raw count is kept
alongside it for the exact figure.

## The attributes

Contact custom attributes, seeded per Meta-owning account by
`db/migrate/20260813000000` and by
`Umi::Meta::InstagramProfileAttributes.ensure_definitions!`.

| key | type | source |
|---|---|---|
| `instagram_followers` | number | profile API `follower_count`, or Business Discovery `followers_count` |
| `instagram_audience` | list | banded: Under 1K / 1K-5K / 5K-10K / 10K-100K / 100K+ |
| `instagram_verified` | checkbox | profile API only |
| `instagram_follows_us` | checkbox | profile API only |
| `instagram_followed_by_us` | checkbox | profile API only |
| `instagram_website` | link | Business Discovery only |
| `instagram_bio` | text | Business Discovery only |

`media_count` and `follows_count` are deliberately not captured: nothing would
read them, and each costs a sidebar row.

## Rate limit — the binding constraint

Meta's hourly app quota is shared with live message delivery. The
investigation's ~550 calls took the app-usage counter to 94%, so an unpaced
backfill risks customer messages not arriving.

- Business Discovery runs as a **second pass with its own cap** (25/night)
  rather than by enlarging the existing 40/night profile pass. The ~121
  contacts with a gap drain in about five nights; the rest of the Instagram
  population sweeps over about a month.
- **A definitive answer is remembered.** Error 110 — a personal account, which
  no permission will ever make discoverable — stamps
  `umi_business_discovery_at` exactly like a success. Without that the 44
  permanently-unreachable contacts would be re-asked every night forever. A
  transient failure is left unstamped so it retries.
- **The cooldown is 90 days**, and it doubles as the refresh cadence.
- The projection of stored values makes **no Meta call at all**, so the
  one-time sweep of 569 contacts (`umi:meta:project_instagram_profile_attributes`)
  can run at any hour.

## Why follower counts are not refreshed nightly

Measured across 60 contacts over a month: the count had moved for 52 of them,
but the median change was **6 followers** and **not one moved by more than
10%**. Nobody crosses an audience band. The single field that changes
meaningfully — *follows the business* — moved for 1 contact in 60. A nightly
refresh would spend ~570 calls per cycle to change nothing, against a quota
shared with message delivery. The 90-day Business Discovery cooldown gives a
quarterly refresh that paces itself: ~8 calls a night at steady state.

## Ordering: gaps first

The candidate query sorts contacts with **no avatar or no follower count**
ahead of the sweep of contacts already covered. That cohort is the one the
profile API refuses, and it is where the influencer population turned out to be
hiding: 43 above 10,000 followers, 20 above 100,000, the largest 613,737 — all
of them appearing to agents as a lowercase handle with no photo.

## Safety

- **No email is ever written.** Meta returns no real email or phone on either
  platform under any permission. The `<psid>@facebook.com` string in one
  Messenger reply is the user id with a domain attached; writing it would look
  like the lead funnel had been fixed while making the contact permanently
  unmergeable — and merging is the only identity resolution that works here.
  Two specs fail if any code path writes an email or phone.
- **The handle is validated before interpolation.** It lands inside a Graph
  field expression and can originate from a contact name an agent typed, so it
  is checked against Instagram's own handle rule first.
- **Erasure needs no new code**: `Umi::Shopify::CustomerRedactionService`
  already clears `custom_attributes` wholesale, and the projection's SQL
  re-checks the `umi_profile_redacted` tombstone in its `WHERE` clause — the
  nightly pass walks contacts over minutes, so an erasure can land between a
  contact being selected and being written.
- **The rename claim is not duplicated.** Business Discovery resolves, but the
  profile enrichment service writes: same rename gate, same ledger, same avatar
  uniqueness handling, same erasure re-check.

## Koala traps (both cost time in the investigation, both re-verified here)

- Koala **mutates the options hash it is given** — a shared or frozen constant
  raises `FrozenError` on the first call and every call after. Built fresh per
  request; a spec asserts the two hashes are distinct objects.
- The API version **must be a symbol key**. `{ 'api_version' => 'v25.0' }` is
  silently ignored and falls back to a default nothing sets. A spec asserts the
  symbol form and the absence of the string form.

## Verification

Every gate was proven non-vacuous by breaking it: eleven mutations, each
verified as landed on disk before the check ran, each turning a specific spec
red and green again on restore. The projection's Ruby-side redaction guard was
**removed** as a result — the mutation showed it changed no outcome, because
the SQL guard already covers both the plain case and the race.

## Rollout

1. `rails db:migrate` (seeds the definitions; the migration is insert-only and
   safe to re-run).
2. `rails 'umi:meta:project_instagram_profile_attributes[1]'` with
   `DRY_RUN=true` first — no Meta calls, 569 contacts become visible.
3. The nightly cron picks up Business Discovery on its next run. Watch
   `[UMI-FBIG] stage=business_discovery_summary`.

Kill switches: `UMI_FBIG_PROFILE_REFRESH_DISABLED=true` stops both passes;
`discovery_cap: 0` as a job argument stops only Business Discovery.
