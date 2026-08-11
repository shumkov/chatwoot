# UMI patch: capture Meta ad attribution on FB/IG (r4 — re-scoped upward)

Supersedes `docs/UMI-FBIG-AD-ATTRIBUTION-SPEC.md` r3, which descoped this to
message-level capture only and deferred everything user-visible on the grounds
that **B3 was the half that fixes D7**. B3 is now closed as will-not-build (see
`docs/UMI-FBIG-OUTBOUND-HEAL-SPEC.md` r2), so that deferral no longer holds.
This patch is now the whole answer, not half of one.

**r3's "Correction of record" is itself reversed.** It argued B3 should be built
first and that this patch "adds a label to a problem B3 solves." Measurement
killed that: the quick-reply menu B3 was meant to recover is button metadata
that neither Meta's message edge nor Chatwoot's builders can represent.

## Why now, and the deadline

A **recruitment campaign launches 2026-08-12**. Click-to-Messenger ads already
carry both hiring and product traffic (A10), and today there is **no signal at
all** that separates them — an applicant and a shopper arrive identically. The
`ref` field is the separator, and it must be set on the ads *before* launch;
capture must be live to receive it.

## What Meta gives us — **verified in production, and it corrects r4's draft**

Chatwoot already logs the whole Instagram messaging entry unconditionally
(`app/jobs/webhooks/instagram_events_job.rb:53`), so this did not need shipping
to answer. Grepping 7 days of production logs: **120 Instagram messaging
payloads, 5 carrying a referral.** Real captured payload, trimmed:

```ruby
{"sender" => {"id" => "1509966250899191"},
 "recipient" => {"id" => "17841468119523354"},
 "timestamp" => 1786033599215,
 "message" => {
   "mid" => "aWdfZAG1faXRlbTox…",
   "text" => "1. สนใจรับส่วนลด 10% สำหรับการสั่งซื้อครั้งแรก",
   "referral" => {"source" => "ADS", "type" => "OPEN_THREAD",
                  "ad_id" => "120252251820030415",
                  "ads_context_data" => {"ad_title" => "Video_2",
                                         "video_url" => "https://scontent…"}}}}
```

Four corrections, all of which would have shipped a patch that captured
nothing:

1. **`referral` is nested INSIDE `message`, not a sibling of it.** The draft
   said sibling. The real path is `@messaging[:message][:referral]`. Reading
   `@messaging[:referral]` returns `nil` — indistinguishable from "organic".
2. **`ad_id` is a String** (`"120252251820030415"`), not an Integer. That
   sidesteps `JsonbAttributesLengthValidator`'s `> 9_999_999_999` Integer
   branch (`app/models/jsonb_attributes_length_validator.rb:17-18`), which
   would otherwise raise on every 17-digit ad id. Coerce with `.to_s` anyway —
   the guarantee is Meta's, not ours.
3. **There is no `ref` key at all** on current ads. The keys present are
   `source`, `type`, `ad_id`, `ads_context_data`. So `ref` is genuinely
   operator-set and genuinely absent until someone sets it — the recruitment
   split depends on an action outside this codebase, and the patch must
   degrade gracefully to `ad_id` when it is missing.
4. **`ads_context_data.ad_title`** carries a human-readable name (`"Video_2"`),
   which is the only part of this an agent can actually read.

Note also that the referral arrives **on the quick-reply tap itself** — the same
message whose bare `"1. สนใจรับส่วนลด 10%…"` text is what makes ad threads
unreadable. Ad context and the confusing message are the same webhook.

The Facebook path is *not* verified this way — the FB logs are not in the same
shape — so its nesting must be confirmed before the FB branch is trusted.

## Scope

### 1. Capture on the message (unchanged from r3 — survived two reviews)

Mirror the shape upstream already accepted for Click-to-WhatsApp
(`whatsapp/incoming_message_service_helpers.rb:74-78`): store the object in
`content_attributes[:referral]`, skip on echo.

**Key-type split, verified and load-bearing.** The Facebook path yields
**String** keys (`MessageParser` does `JSON.parse`); the Instagram path yields
`HashWithIndifferentAccess` (`entry.with_indifferent_access`). A helper written
for one path returns `nil` on the other — and `nil` is indistinguishable from
"organic". Handle both explicitly and test both.

`Integrations::Facebook::MessageParser` has no `referral` accessor (confirmed:
it exposes `sender_id`, `recipient_id`, `time_stamp`, `content`, `sequence`,
`attachments`, `identifier`, `delivery`, `read`, `echo?`, `app_id` — no
referral). Add one via a `Umi::` prepend.

**No side effects in `message_params`.**
`Messages::Instagram::MessageBuilder#get_story_object_from_source_id` calls
`conversation.messages.create!(message_params)` a second time, so anything with
a side effect there runs twice. Returning a value in the hash is fine; writing
anything else is not.

### 2. Promote to the conversation — **latest wins, not first**

r3 deferred this and flagged "first referral wins" as wrong. It is, and the fix
is to invert it rather than to defer.

r3's reasoning: with `lock_to_single_conversation` on, the same conversation is
reused *regardless of status, forever*; with it off (the default), a new
conversation is created only if the last is **resolved** — and the target
population is conversations that die *unanswered*, i.e. stay open. So a
first-wins stamp goes stale exactly where it matters.

**Resolution: the two layers answer different questions.**

- **Message-level** is the immutable audit trail — every referral ever seen, in
  order, attached to the message that carried it. This is what attribution and
  any future reporting join on.
- **Conversation-level** is "what is this conversation about *now*", so it
  takes the **most recent** referral. If a customer clicks a second ad, the
  live context is the second ad; showing the agent the first would be wrong.

This makes conversation reuse a non-issue instead of a trap.

### 3. Create the `CustomAttributeDefinition` rows — in the same commit

r3 established that promotion without definitions is **inert and harmful**: the
sidebar maps over definitions so undefined keys render nothing; an automation
rule referencing an undefined key **cannot be saved**; and at runtime it trips
`authorization_error!` and, after two hits, `prompt_reauthorization!`.

So the definitions are not optional polish — they are what makes the write mean
anything. Seed them idempotently for `conversation_attribute`:

| key | type | purpose |
|---|---|---|
| `meta_ad_id` | text | joins to Ads Manager |
| `meta_ad_ref` | text | the operator-set string — **this is the recruitment separator** |
| `meta_ad_title` | text | human-readable, what agents actually read |

r3 said to **drop `meta_ad_ref`** as speculative with nothing consuming it.
That is now reversed: A10 consumes it, and it is the whole reason the
recruitment split is cheap. Recorded as a deliberate reversal, not an
oversight.

### 4. Redaction — same commit, before capture is ever enabled

`referral` carries `ad_id`, `ad_title`, `photo_url` and a per-ad `ref`.
Combined with the surviving `contact_inbox.source_id` (the PSID/IGSID, never
purged) that is re-identifiable behavioural data: *this person clicked this ad
on this date*.

Nothing currently redacts message `content_attributes`.
`shopify_compliance.rb#anonymize_contact` writes only `Contact` columns — and
it reaches that branch *because* `contact.conversations.exists?`, which for a
Meta DM contact is always true, so the `destroy!` branch that would cascade is
structurally unreachable for this population.

Extend `anonymize_contact` to strip `referral` from the contact's messages and
the three attributes from its conversations, **in this commit** — the same
discipline the profile-refresh patch used when it landed its tombstone before
the cron existed.

## Explicitly out of scope

**`source-paid-ads` auto-labelling.** A10 is the reason: click-to-Messenger
carries recruitment *and* sales, so a blanket label would tag every job
applicant as a sales lead and blend the two in every report. Once `ref` is
flowing and the hiring ads carry a known value, labelling becomes a
one-line automation rule — but it needs real `ref` values observed first, not
guessed. Ship capture, watch a day of traffic, then label.

**`messaging_referrals` subscription.** Verified in r3 to deliver nothing
through the planned path: a payload carrying both `message` and `referral`
already dispatches as `Incoming::Message` today with only `messages`
subscribed. The only thing the subscription adds is the standalone re-entry
event, which the gem drops before any Chatwoot code runs (no `Bot.on :referral`
is registered, so `Bot.trigger` raises `KeyError` and emits a bare
`Kernel#warn`).

If it is ever needed: `POST /{page}/subscribed_apps` **replaces** the field set,
so the call must send the **observed live set** plus the new field, never the
model constant — there is direct evidence the live list was hand-edited
(`message_echoes` added 2026-07-22). Never use `channel.subscribe`: it rescues
`StandardError`, logs at `debug`, and returns `true`, so a failed re-subscribe
looks successful. **Instagram is a separate surface entirely** — field
`messaging_referral` (singular) on the `instagram` webhook object, configured in
the App Dashboard, invisible in `/{page_id}/subscribed_apps`.

## The unverified assumption, and how it gets settled

**Does a `referral` object actually arrive on this deployment's Instagram
webhooks?** Everything above is documented behaviour, and 74% of volume is
Instagram, so this matters more than any other open question. Chatwoot stores
no raw webhook payloads, so it cannot be answered from history.

It is settled by shipping: capture logs
`[UMI-FBIG] stage=referral_seen platform=… ad_id=… ref=…` on every hit and
`stage=referral_absent` on the first message of a conversation that has none.
One day of the hiring campaign answers it definitively.

This is deliberately a **read-and-log-first** design: the patch is inert if no
referral ever arrives, and it cannot corrupt anything if the shape differs from
the docs.

## Failure modes

| Mode | Handling |
|---|---|
| No referral (organic conversation) | Nothing written; `stage=referral_absent` logged once |
| Malformed / partial referral | Message still persists — the write must never be able to lose a customer message |
| A referral write *raises* | Same: rescue and log, never propagate into message creation |
| String vs indifferent-access keys | Both handled explicitly and both tested |
| Second ad click in a live conversation | Conversation attributes overwrite (latest wins); message history keeps both |
| Contact erasure | Referral stripped from messages *and* conversations |

## Verification plan

Specs, red→green: FB inbound with referral stores it; **both** IG paths store
it; echo stores nothing; **String-key and indifferent-access payloads both
work**; a malformed referral still persists the message; **a referral write
that raises still persists the message** (r2's spec tested a malformed payload,
not a raising write — it would have passed green against a broken arrangement);
conversation attributes take the latest referral, not the first; redaction
strips referral from messages and conversations.

Production: deploy, then read the `referral_seen` / `referral_absent` counts
over the hiring campaign's first day. That is also the A10 deliverable.

## Registry

New row in `UMI-PATCHES.md`. Remove-when: upstream captures Meta `referral` for
the FB/IG channels as it already does for WhatsApp and Twilio
(`app/services/twilio/referral_params_helper.rb` shows the pattern is already
established in two channels).
