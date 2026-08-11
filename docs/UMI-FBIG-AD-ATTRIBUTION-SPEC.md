# UMI patch: capture Meta ad attribution on FB/IG messages

Revision 3 — **descoped**. Two review rounds (feasibility, adversarial) found
that r1/r2 promised three user-visible outcomes that each fail for a different
verified reason, all of them silently. What survives is a small data-capture
patch. The parts that were doing the promising are deferred.

## Correction of record

r1/r2 asserted "**D7** — agents unable to read ad conversations — is fixed by
nothing else on the list." That is wrong, and it misquotes this project's own
backlog, which reads: *"Fixed by D2 (ad context card) **+ B3** (backfill the
invisible auto-replies)."* The `+ B3` was dropped.

**B3 is the half that fixes D7.** The artifact agents are missing is not the
ad's *name* — the quick-reply options are self-describing Thai sentences
("interested in the 10% discount", "recommend UMI's bestsellers"). What they
cannot see is what the automated message **promised**: which discount, what
code, what the other options were, whether Meta already answered. That text is
retrievable — recon already reads Meta's own messages via
`GET /{thread_id}/messages`, and `Umi::Fbig::MessageHealService` already
replays them through the builders. Extending healing to `direction=out` puts
the actual conversation in front of the agent.

**So B3 should be built before this patch.** D2 adds a label to a problem B3
solves.

## What survives, and why

Capture the `referral` object onto the inbound message, mirroring the shape
upstream already accepted for Click-to-WhatsApp (chatwoot#13995 / PR #14681;
`whatsapp/incoming_message_base_service.rb:178`). That is cheap, upstream-shaped,
has no user-visible surface to get wrong, and starts accumulating data that
D4 and any future reporting will want.

Everything else is deferred — see "Deferred, with reasons".

### 1. Expose `referral` on the parser

`Integrations::Facebook::MessageParser` has no accessor for it, though
`referral` sits at the top level of `@messaging` and already reaches the
parser intact. Add one via a `Umi::` prepend with a fail-loud guard.

**Key-type split, verified:** the Facebook path yields **String** keys (JSON
parsed in `MessageParser`); the Instagram path yields
`HashWithIndifferentAccess` (`entry.with_indifferent_access`). A shared helper
written for one path returns `nil` on the other — and `nil` is
indistinguishable from "organic". The helper must handle both explicitly and
be tested on both.

### 2. Store on the message

Add to `content_attributes[:referral]` in both builders' `message_params`.
Skip on `outgoing_echo`.

Verified safe: `ContentAttributeValidator` only inspects
`input_select`/`cards`/`form`/`article` types. Prepend targets are
conflict-free — existing prepends on these classes target `#perform`,
`#process_contact_params_result`, `#message_already_exists?` and
`#attach_file`; #10/#18 are on different classes. One prepend covers both IG
paths, since neither subclass overrides `message_params`.

**No side effects in `message_params`.**
`Messages::Instagram::MessageBuilder#get_story_object_from_source_id:16` calls
`conversation.messages.create!(message_params)` a second time, so anything with
a side effect runs twice on the story-fetch-failure path. Storing a value in
the returned hash is fine; writing anything else is not.

### 3. Redaction — in the same commit, before capture is ever enabled

`referral` includes `ad_id`, `ad_title`, `product_id`, `post_id` and a signed
`photo_url`. Combined with the surviving `contact_inbox.source_id` (the
PSID/IGSID, never purged), that is re-identifiable behavioural data: *this
person clicked this ad on this date*.

Nothing currently redacts message `content_attributes`.
`shopify_compliance.rb#anonymize_contact` writes only `Contact` columns — and
it reaches that branch *because* `contact.conversations.exists?`, which for a
Meta DM contact is always true, so the `destroy!` branch that would cascade is
structurally unreachable for this population.

This is the same gap closed days ago for handles and avatars. Extend
`anonymize_contact` to strip `referral` from the contact's messages, **in this
commit**, exactly as the profile-refresh spec landed its tombstone before the
cron existed.

**Drop `meta_ad_ref`.** `ref` is a free-form per-ad string with no bound on
what it may contain and nothing currently consuming it. Storing it is
speculative; add it when something needs it.

## Deferred, with reasons

**Promotion to `conversation.custom_attributes`** — needs
`CustomAttributeDefinition` rows or it is inert *and harmful*: the sidebar maps
over definitions, so undefined keys render nothing; and an automation rule
referencing an undefined key **cannot be saved**, while at runtime it trips
`authorization_error!` and, after two hits, `prompt_reauthorization!`. r2's
citation of `conditions_filter_service.rb:74` as proof rules can filter custom
attributes was exactly backwards — that line's guard is the definition lookup.

**`source-paid-ads` labelling** — depends on the above. Also unresolved: A10
records that click-to-Messenger includes **recruitment** campaigns, so as
specced every job applicant would be labelled `source-paid-ads` and every
per-ad report would blend hiring with sales. That needs answering first.

**"First referral wins"** — wrong under both inbox settings. With
`lock_to_single_conversation` on, the same conversation is reused *regardless
of status, forever*. With it off (the default), a new conversation is created
only if the last is **resolved** — and the target population is conversations
that die *unanswered*, i.e. stay open. So the stamp goes stale precisely for
the conversations this exists for. Needs a rule that survives conversation
reuse before it is worth writing.

**`messaging_referrals` subscription** — delivers nothing through the planned
path. A payload carrying both `message` and `referral` already dispatches as
`Incoming::Message` today with only `messages` subscribed. The *only* thing the
subscription adds is the standalone re-entry event, and that is dropped by the
gem before any Chatwoot code runs: no `Bot.on :referral` is registered, so
`Bot.trigger` raises `KeyError` and emits a bare `Kernel#warn`. (Patch #9
already prevents the batch-dispatch crash the review feared on the IG side —
`event_name` resolves per item and returns `nil` for a referral-only entry.)

If it is ever needed: `POST /{page}/subscribed_apps` **replaces** the field
set, so the call must send the **observed live set** plus the new field, never
the model constant — and there is direct evidence the live list was
hand-edited (`message_echoes` was added 2026-07-22, long after channel
creation), so cardinality matching is not identity. Never use
`channel.subscribe`: it rescues `StandardError`, logs at `debug`, and returns
`true`, so a failed re-subscribe looks successful.

**Instagram is a separate subscription surface entirely** — the field is
`messaging_referral` (singular) on the `instagram` webhook object, configured
in the App Dashboard, invisible in `/{page_id}/subscribed_apps`. 648 of 725
conversations are Instagram, so any subscription work that ignores this is
ineffective where it matters most.

## Is even this worth doing now?

Honest answer: **it is cheap and harmless, but not urgent.** D4 does not need
`ad_id` — CAPI joins on `page_id`+PSID / `ig_business_account_id`+`ig_sid`,
all of which Chatwoot already stores. D4's missing input is the **purchase**
(D8), not the ad. And Chatwoot cannot group reports by a custom attribute
anyway, so the standalone commercial deliverable is "filter conversations by
ad id" — while Meta's Leads Centre already tags Paid/Organic.

Recommended order: **B3 → D8 → this**.

## Verification plan

Specs: FB inbound with referral stores it; both IG paths store it; echo stores
nothing; **String-key and indifferent-access payloads both work**; a malformed
referral still persists the message; a message write that *raises* still
persists the message (the r2 spec tested a malformed payload, not a raising
write — it would have passed green against a broken arrangement); redaction
strips `referral` from a contact's messages.

## Registry

New row in `UMI-PATCHES.md`. Remove-when: upstream captures Meta `referral` for
the FB/IG channels as it already does for WhatsApp.
