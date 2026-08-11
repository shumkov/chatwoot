# UMI patch: heal outbound FB/IG messages Meta never delivered (B3)

Revision 2 — **do not build as specced.** Draft 1 was reviewed and measured
against production. Its headline benefit does not exist, its target platform
has no gap, and the write it proposes is actively harmful to the conversations
it was meant to help. What survives is a much smaller idea; the better answer
is a different patch entirely.

## Verdict first

| Draft-1 claim | Status |
|---|---|
| Agents will see the ad's automated message **and its menu** | **False.** The menu is quick-reply *buttons*, not message text. Meta doesn't return it on the message edge, and Chatwoot's builders have no `quick_replies` handling — `process_attachment` returns early for `:template`, and no attachment type maps to a button set. Refuted on both sides independently. |
| Instagram matters most (74% of volume) | **Irrelevant here.** Instagram has *no outbound gap*: 71 page-sent human messages present, **0 missing**. The only IG misses are 5 empty-text rows. B3 is Messenger-only. |
| Healing restores context to dying conversations | **Backwards.** A healed outbound echo satisfies `Message#human_response?`, which nulls `waiting_since` and can set `first_reply_created_at` — dropping the conversation out of the **Unattended** folder. It hides the exact threads it was meant to rescue. |
| `missing_suspect=0` proves the dedup heuristic works | **No.** Measured: exactly 1 of 77 misses would duplicate an existing message, and the ±90 s heuristic catches **0 of that 1** while flagging innocent messages. It is both a false-positive generator and blind to the real case. |
| `direction=out` is a homogeneous population of Meta automations | **False**, and this is the disqualifying finding. See below. |

### What the outbound misses actually are (production, 241 page-sent messages)

| Type | Platform | Present | Missing |
|---|---|---|---|
| Ad greeting ("let us know how we can help") | messenger | 0 | 14 |
| `"X replied to an ad."` marker | messenger | 5 | 15 |
| Away message ("thanks, we'll reply soon") | messenger | 1 | 18 |
| Away message | instagram | 7 | 0 |
| other / human | messenger | 63 | **25** |
| other / human | instagram | 71 | **0** |
| (empty text) | instagram | 15 | 5 |

The 25-message "other" bucket is **not** Meta automations. It is two things
that must never be replayed together:

- **Agents replying from the Meta app / Business Suite** — *"Yeah, no problem.
  See you at 12"*, *"I'll be in a sec"*. Real messages, genuinely missing.
- **Meta Business Suite's own internal notes**, returned by the API as
  page-authored messages — *"Ivan Shumkov assigned this conversation to Ivan
  Shumkov."*, *"Auto-label added: Lead stage set to intake."*, *"Lead stage set
  to Qualified"*, *"Lead stage set to Lost"*. Replaying these would inject
  Meta's CRM bookkeeping into customer conversations as outgoing messages.

And **10 of those 25 already exist in Chatwoot under a different `source_id`**,
so healing them duplicates a message the agent already sees.

There is no field on the message edge that separates these categories. Any
outbound heal is therefore a text-matching exercise against an open-ended set,
which is exactly the kind of heuristic this project has been burned by before.

### Why the timestamp fix cannot rescue it

Draft 1 argued backdating `created_at` was required for readability. Review
established it does not work and makes things worse:

- Every timestamp side effect runs in `after_create_commit`, **before** the
  update. `conversation.last_activity_at`, `first_reply_created_at`, and the
  `ReportingEvent` rows for `first_response`/`reply_time` are all written with
  heal-time values and are *not* corrected by a later `message.update`. So
  inflated first-response times get persisted and rolled up, attributed to
  `user_id: nil`.
- Backdating **poisons the gate that authorises healing**: a healed, backdated
  message sits inside the ±90 s window of its own sibling in the same ad flow,
  so mid #2 is permanently labelled `suspect=multipart` and skipped.
- `MessageFinder` orders by `created_at` but paginates by `id`. A backdated row
  has a high id and a low timestamp, so once 20 newer messages exist it falls
  off page 1 and every scroll-up page filters `id < before_id` — the message
  becomes **invisible in the agent UI**. It breaks precisely on the long
  engaged threads.
- A conversation resolved since the message was sent gets a **brand-new
  conversation containing only the healed greeting**, detached from the reply
  it was meant to explain.

Draft 1 also mis-stated the failure table: `fetch_detail` returns `nil` only
when the Graph call *raises*. A successful fetch of an empty template message
proceeds to create an **empty outgoing bubble** stamped `umi_recovered` and
reports `:healed` — the likely outcome for exactly the ad-flow messages this
targeted, and the explanation for the 5 empty Instagram rows above.

One genuinely reassuring finding: **healed messages are never re-sent to the
customer.** `Base::SendOnChannelService#invalid_message?` short-circuits on
`source_id.present?`. That risk was real and is closed.

### Two further corrections of record

**The "34 missing in 14 days" figure is double-counted.** `docs/UMI-FBIG-RECON-SPEC.md`
explicitly forbids that arithmetic: the 48 h window at daily cadence re-reports
a still-missing mid about twice, so `missing>0` is the signal and counts must
**not** be accumulated across days. 34 = 2 × the 17 Meta-generated messages
from the original experiment. The real rate is closer to ~1.2 distinct mids per
day. Same class of error as the circular population count in the profile-refresh
work — a number reused across two contexts where only one definition holds.

**The latency class is wrong for the stated purpose.** Recon runs `30 20 * * *`.
A customer taps an ad at 10:00 local and the context would arrive at 03:30 the
next night — median ~12 h, and typically after Meta's 24-hour standard messaging
window has closed. "The agent sees the ad's message when she replies" is a
real-time agent-assist requirement; reconciliation is a nightly audit mechanism.
The existing machinery drove the design instead of the problem doing so. Any
solution to D7 has to attach at **conversation-creation time**, which is another
reason `referral` capture on the live path is the right shape.

Also worth recording: the premise *"Meta never echoes its own automations"* is
not cleanly established, because `message_echoes` was only subscribed on
2026-07-22 and the original 17→0 experiment has no stated date range. The
production census above partly contradicts it anyway — Instagram away messages
are echoed 7/7, and the `"replied to an ad."` marker is echoed 5 of 20.

## What to do instead

**Capture `referral` on the live path, and render ad context — don't replay
messages.** Independent research confirmed the Instagram messaging webhook
delivers, on the first message of an ad-originated thread:

```
"referral": { "ref": "<arbitrary string you set per ad>",
              "ad_id": <ad id>, "source": "ADS", "type": "OPEN_THREAD",
              "ads_context_data": { "ad_title", "photo_url", "video_url" } }
```

This is strictly better than healing a `"X replied to an ad."` string: it is
deterministic, carries the **ad id and title** rather than a marker, needs no
write into conversation history, has no reporting or ordering side effects, and
covers Instagram — where B3 has nothing to offer. It is the same
`docs/UMI-FBIG-AD-ATTRIBUTION-SPEC.md` patch that was descoped to
data-capture-only, which should now be **promoted ahead of B3**.

That spec's own "Correction of record" — asserting *"B3 is the half that fixes
D7"* — is hereby reversed. B3 does not fix D7. `referral` capture plus an ad
context card does.

## The one piece worth keeping

Agents answering from the Meta app produce genuinely missing inbound-adjacent
history (the ~25-message bucket, minus the Business Suite notes and the 10
duplicates). That is a real gap, but it is a **workflow problem** — the team
should answer in Chatwoot — and healing it is the expensive fix for a habit.
Revisit only if the Meta-app habit persists and someone asks for it.

## Original draft below (retained for the record)

The analysis that follows is draft 1 and is superseded by the verdict above.

---

## Problem

Meta never echoes messages its own systems generate — established empirically
(17 Meta-generated messages → 0 in Chatwoot; 7 Chatwoot-sent → 7). So the ad
welcome message, its quick-reply menu, and Business Suite automation replies
are invisible to agents.

The operational cost is measured, not theoretical. On product ads the customer
taps a quick-reply button and the agent sees only:

> **"3. ขอแนะนำสินค้าขายดีของ UMI"**

— a bare numbered option answering a question she cannot see. She does not know
which discount was promised, what the other options were, or whether Meta
already answered. 38 of 50 Messenger threads originate from an ad, and these
conversations die. Recruitment ads, where people type real questions, produce
long engaged threads. **The difference is context, not intent.**

Recon detects these today: 34 missing messages in 14 days, all
`direction=out`, `missing_suspect=0`.

## What already exists

`Umi::Fbig::ConversationReconService` finds them and logs
`stage=reconcile_missing … direction=out`. `Umi::Fbig::MessageHealService`
already fetches a message by mid and replays it through the live builders, with
a Redis owner lock, a global `source_id` dedup, a per-platform heal budget, and
an `umi_recovered` stamp.

Healing is gated to inbound at one line —
`conversation_recon_service.rb:172`:

```ruby
heal(platform, entry) if direction == 'in' && heal_enabled?
```

`docs/UMI-FBIG-RECON-SPEC.md` records the reason: outbound healing was
"deliberately excluded until real reports show the multipart-suspect labeling
is reliable." **Those reports now exist and are clean** — `missing_suspect=0`
across the observed window.

## The problem that decides whether this is worth building

**Healed messages carry heal-time `created_at`, not send time.** The service's
own header says so: *"its created_at is the heal time (the builders don't take
historical timestamps)"*.

For inbound healing that is tolerable — a recovered customer message appears
late but is still recognisably theirs.

For B3 it is **fatal to the stated purpose**. The welcome message belongs at the
*top* of the conversation, before the customer's reply. Healed at heal time it
lands at the *bottom*, newest-first, so the agent sees:

```
[customer]  3. ขอแนะนำสินค้าขายดีของ UMI
[us]        สวัสดีค่ะ 👋 … how can we help?      ← the greeting, arriving last
```

That is more confusing than the gap it replaces. **B3 is only worth building if
recovered messages can be placed at their original position.**

### Options

1. **Set `created_at` after creation.** `Message` ordering is
   `default_scope { order(created_at: :asc) }`, so an update places the row
   correctly. Needs care: `created_at` feeds reporting, `conversation
   .last_activity_at`, SLA, and `first_reply_created_at`. An outbound message
   backdated before the customer's first inbound could alter first-response
   metrics.
2. **Store the original time in `content_attributes` and render it in the UI.**
   No timestamp mutation, but the message still sorts wrongly — solves
   provenance, not readability.
3. **Do not heal; surface the ad's menu another way** — e.g. capture the flow
   content once per ad (the Partner-App welcome flow route the earlier research
   identified) and render it as conversation context rather than as messages.

Recommendation: **option 1, with the reporting fields explicitly considered** —
it is the only one that produces a readable transcript. The spec must state
exactly which timestamp columns are set and which are deliberately left alone.

## Approach

### 1. Identify the customer, which outbound replay needs and inbound did not

`MessageHealService#fetch_detail` requests
`id,created_time,from,message,attachments`. For an inbound message `from` is
the customer. For an outbound one `from` is the page — so the customer must
come from elsewhere. Add `to` to the field list; Meta returns the recipient
list on the message edge. Fall back to the thread's `participants` (the same
call `Umi::Fbig::ParticipantNameService` already makes) if `to` is absent.

### 2. Replay as an echo, not as a new message

Both builders already support this and it is the correct path:

- **Facebook** — `Messages::Facebook::MessageBuilder.new(parsed, inbox,
  outgoing_echo: true)`. With the echo flag, `@sender_id = recipient_id`, so
  the contact resolves to the customer, and `message_type` becomes `:outgoing`.
  The synthesized payload therefore needs `sender: {id: page_id}`,
  `recipient: {id: customer_psid}`.
- **Instagram** — `Instagram::Messenger::MessageText` derives echo from
  `@messaging[:message][:is_echo]`, and `instagram_and_contact_ids` then
  returns `[sender, recipient]` so the contact is the recipient. Set
  `is_echo: true` and swap the ids the same way.

This reuses the live path exactly, as inbound healing does — contact
resolution, conversation selection and dedup all behave identically.

### 3. Keep every existing safety property

Unchanged: the Redis per-mid owner lock, the **global** `source_id` dedup
(deliberately stricter than detection's account scope), the per-platform heal
budget, `umi_recovered` stamping, and the best-effort posture where any single
mid can fail without affecting the scan.

### 4. Respect the multipart suspect heuristic

`multipart_suspect?` flags an outbound mid that has a Chatwoot outgoing message
within ±90 s — the signature of Meta splitting one Chatwoot send into several
mids, where healing would create duplicates of our own message. **Skip
suspects**; heal only clean outbound misses. This is the exact reliability
question the original exclusion was waiting on, and the answer so far is
`missing_suspect=0`.

## What this does and does not fix

**Fixes:** the agent sees the automated message and its menu, so a quick-reply
tap becomes readable. That is D7.

**Does not fix:** the `"X replied to an ad."` system line (an annotation, not a
message), and anything Meta declines to return on the message edge. Nor does it
retroactively attribute the ad — that is D2, and note `MessageHealService`'s
fetch has no `referral` field available, so a healed first message can never
carry attribution.

## Failure modes

| Mode | Handling |
|---|---|
| `to` absent on the message edge | Fall back to thread participants; skip if still unknown |
| Message is a Chatwoot multi-part fragment | Skipped by the suspect heuristic |
| Already healed / late webhook | Existing global `source_id` dedup |
| Backdating alters first-response metrics | Must be measured before enabling; see below |
| Meta returns no content | Existing `:content_unavailable` skip |
| Heal storm after an outage | Existing per-platform budget |

## Verification plan

Specs (red→green): an outbound miss replays as an **outgoing** message attached
to the **customer's** contact, not the page's; the Instagram path does the same
via `is_echo`; a multipart suspect is skipped; a second heal of the same mid is
a no-op; `created_at` is set to Meta's `created_time` and the message sorts
before the customer's reply.

Production: enable on a **single thread first** (the ad-click threads are
identified), read the transcript as an agent would, and confirm it is more
readable rather than less. Only then widen. Measure
`first_reply_created_at`/SLA before and after on a sample, because backdating
outbound messages is exactly the kind of change that quietly moves reporting.

## Rollout note

This writes historical messages into live conversations. Agents will open
threads and find messages that were not there yesterday. That is the intended
outcome, but it is visible to people mid-shift and should be announced rather
than discovered.

## Registry

Amends patch #12's row (`UMI_FBIG_RECON_HEAL` gains outbound coverage) rather
than adding a new patch. Remove-when: unchanged — upstream ships
webhook-delivery reconciliation for Meta channels, or Meta begins echoing its
own automated messages.
