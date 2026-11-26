# Waiting acknowledgements: skip continuations and symbol-only bursts

Status: implementation spec for proposed release `umi-v4.16.0-45`, base `umi-v4.16.0-44` (`2f420f203`).
Decision: shumkov/shumabit-claude#114. Evidence: shumabit-claude `docs/CRM-ACKNOWLEDGEMENT-CENSUS-20261123.md`
(merged audit PR 115) and the #114 source research. Extends patch 62 (`docs/UMI-CUSTOMER-AUTO-REPLIES-SPEC.md`).

## Problem

`Umi::CustomerAcknowledgement` treats every customer message after a successful human-direction reply as a new
unanswered wait. A thanks, a closing word, an emoji or a story reaction therefore gets "Sorry to keep you waiting"
after five minutes, or the night hours notice at once. In the census of 106 sent acknowledgements, 39 answered no
request; 76 followed an earlier human-direction outgoing in the same conversation (median 37 min earlier). The
deployed rule never reads content (`Umi::CustomerAcknowledgement#acknowledge`, `#eligible?`, `#current_messages`).

## Chosen behaviour

Two send-time checks are added in `acknowledge`, after every existing guard and immediately before the template is
created. Both only return early; neither writes state. Day and night copies, the five-minute daytime delay, the
per-conversation marker and dedup, lifecycle guards, the 24 h window, mode checks, failed-send handling, channel
transports, inbox scope and `started_at` are unchanged.

### 1. Continuation suppression (conversation-local, 12 hours)

- **Anchor F** is the burst's first eligible incoming message: the existing `first` (the `first_message_id` the marker
  records), not the message whose job runs.
- The burst is a **continuation** when the same conversation holds a message that passes the existing
  `successful_human?` predicate and whose `created_at` lies in **[F.created_at − 12 h, F.created_at]** (both ends
  inclusive, as measured by the census). A continuation burst is never acknowledged.
- `successful_human?` is unchanged: public, not failed, not deleted, not `umi_recovered`, native `human_response?`
  (a User sender or an external echo, no automation rule or campaign), not a bot. The census used the same predicate.
  An external echo is a human-*direction* reply, not proof that a person typed it.
- **Equivalence with the census predicate** ("latest preceding qualifying outgoing within L of the anchor") holds by
  definition: the latest qualifying reply at or before F is within 12 h exactly when some qualifying reply lies in the
  window. The burst construction (`#current_messages`) also guarantees that no qualifying reply lies between F and
  execution.
- **History scope:** the lookup reads the whole conversation, ignoring the resolve/snooze boundary and `started_at`
  (as the census did). Those bound the burst, not the history. A reply recorded before activation also counts: it only
  suppresses, it never replays.
- **Resolve and snooze.** A snoozed conversation is reused by the next customer message, so a message within 12 h of
  the last reply is a continuation. The website widget posts into its last conversation even when it is resolved
  (`Api::V1::Widget::BaseController#conversation`), so the same applies there. On Facebook and Instagram a resolved
  conversation is reused only when the inbox has `lock_to_single_conversation` (default false; builders
  `messages/facebook/message_builder.rb`, `messages/instagram/base_message_builder.rb`) or an agent reopens it.
  Otherwise the next message opens a **new conversation with no history**, which is judged as new and can be
  acknowledged. That is the conversation-local scope the census measured. Production inboxes 1 and 2 both have `lock_to_single_conversation`
  false (infra read-only check, 2026-11-26), so after a resolve the next inbound message there opens a new conversation
  that bypasses the previous history by design. That is an accepted residual of the conversation-local scope; it
  affects only the waiting notice, not how staff receive or handle the message.
- **Time alone never unlocks a burst.** F, and so the decision, depends only on the burst's membership, not the clock.
  A late job, the five-minute wait, a 09:00/21:00 mode change or a later message in the same burst all see the same F.
  F moves only when membership changes:
  - F itself is unsent or deleted, so the next eligible message becomes F and is judged against its own window;
  - the reply that started the burst later becomes failed or deleted, so the burst merges back to an earlier F.
  A suppressed burst otherwise ends only when a qualifying reply starts a new burst, or when resolve/snooze closes it.
- **No contact-level history and no new dedup.** Only messages of this conversation are read.

### 2. Whole-burst symbol-only veto

- **Inputs** are every public incoming row of the burst, as the census checked, excluding only automatic emails. Rows
  the trigger filter rejects still count as inputs and are judged like any other: a pure story mention, share, post or
  reel blocks the veto through its attachment, and a recovered row through its content. So a shared product post
  followed by "😍" is acknowledged.
- The send is vetoed only when **every** input is symbol-only. One substantive input anywhere in the burst, earlier or
  later, blocks the veto. A **deleted** or **unsupported** incoming row also blocks it, because its content is unknown
  (census: a deleted input is "unknown", not suppressible), and so does a row with blank text and no attachment (for
  example a media download that failed).
- A row is **symbol-only** when all of these hold:
  - it has no attachment other than **story context**: an `ig_story` attachment on a row whose `image_type` is
    `ig_story_reply`. Any other attachment blocks: image, video, audio, file, location, fallback, share, ig_post,
    ig_reel, story_mention, and stickers, which upstream normalizes to image. Stickers cannot be told apart from
    product photos and are never suppressed;
  - its text contains no letter (`\p{L}`), no digit (`\p{N}`) and no question mark of any of these forms:
    `? ？ ﹖ ¿ ؟ ‽ ⁇ ⁈ ⁉ ❓ ❔`;
  - every other character is Unicode punctuation `\p{P}`, a symbol `\p{S}` (emoji, currency, maths, modifiers), an
    extended pictographic `\p{Extended_Pictographic}` (emoji newer than Ruby's Unicode tables), whitespace
    `\p{Space}`, a format character `\p{Cf}` (zero-width joiner, emoji tag characters, invisible marks), a variation
    selector U+FE0E/U+FE0F or the keycap mark U+20E3. Anything else, including a lone combining mark, is substantive.
  - A story reply with the story attachment and **no text** is symbol-only.
- **Question marks are substantive.** A lone "?" or "❓" is usually a nudge on an unanswered question, so it is never
  vetoed. This is narrower than the census predicate, which counted punctuation: it accepts some noise rather than
  silencing a real follow-up. Digits stay substantive ("38", "2", "555"), and keycap digits such as "1️⃣" contain a digit.
- **Mixed bursts:** if the first job sees only an emoji, it is vetoed. If a substantive message follows before a reply,
  that message's own job runs (after 5 min by day, at once by night), sees a non-symbol burst and sends, subject to
  rule 1 with the unchanged anchor F. The marker then records F, the emoji. The veto never picks a new anchor.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Measure the 12 h at execution time | A delay or the five-minute wait would push a thanks past the cutoff and make it eligible. |
| Re-anchor on later "substantive" messages | Needs request detection, the semantic classifier this design avoids. |
| Contact-level history or contact-level once-only | Not measured by the census; needs a shared predicate plus contact serialization. |
| Disable daytime acknowledgements | Removes all 67 daytime sends, useful ones included, and leaves the night noise. |
| Keyword lists or model inference | Multilingual false certainty, latency and a provider dependency. |
| Count "?" as punctuation (census predicate) | Would silence a customer nudging an unanswered question. |
| 24 h window | Census: one more no-request removal and four more meaningful-context removals than 12 h. |

## Expected effect and residual limits

The census's conversation-local estimate of the combined rule (12 h OR symbol-only) removes 66 of 106 observed sends:
36 of 39 no-request ones, but also 27 sends on meaningful-context messages. It is not a customer-only error rate (15
internal-thread and 3 test sends are in the set), not a scheduling replay and not a forecast of the rollout result.
66 is an upper bound on net removal:
when an emoji is vetoed and a real message follows in the same burst, that later message now sends, where before it was
deduplicated, so such sends are not among the 106. Two narrowings also lower suppression slightly: question marks are
substantive here, and unsupported, blank and recovered rows block the veto, where the census set recovery and
unsupported rows aside.

This is timing-based suppression plus an event-shape veto, **not request detection**.
- A worded thanks or social message more than 12 h after a reply, or with no reply in the conversation, still gets an
  acknowledgement. So does a message in a new conversation opened after a resolve.
- A staff reply missing from Chatwoot (no echo) makes a continuation look new.
- Every later message of a continuation burst gets no notice until a reply, resolve or snooze, including a real
  question or a "?" nudge many hours later.
- **Echoed Meta automations.** Any Meta-side automatic message that echoes into Chatwoot counts as a human-direction
  reply and silences the next burst; the census saw echoed greetings, a collection welcome and collaboration replies.
- **Instagram ad menu taps.** Meta's automatic answer to an ad menu tap reaches Chatwoot on Instagram as an external
  echo (8 of 8 Instagram tap conversations in the 90-day measurement recorded for the "Ad context private note" patch in
  `UMI-PATCHES.md`; not re-measured by the census). It counts as a human-direction reply under the unchanged `successful_human?`. So when
  the customer's first typed question follows within 12 h, that burst is a continuation and stays without an
  acknowledgement **for as long as the burst lasts**: there is no delayed acknowledgement once 12 h pass, only a new
  burst after a reply, resolve or snooze. Telling these echoes apart needs provenance metadata Chatwoot does not store.
  This release accepts the loss and keeps the existing automation and campaign checks of `human_response?` unchanged.

What is lost is the automatic waiting notice, never the customer's message or a service obligation: every message
still reaches the conversation, the queue and staff exactly as before. Acknowledgements were never human responses, and the operator queue's waiting computation
skips templates (`umi/app/services/funnel/operator_queue.rb:238,286`). Fewer template rows do reach its message list and
revision digest, so the reminder classifier sees fewer automatic notices; this changes its input, not its duty logic.

## Failure modes

| Case | Result |
|---|---|
| Job runs late (queue delay, under 24 h) | Same decision: F and the window do not move. |
| Human reply lands before the job runs | Burst ends; no send (unchanged). |
| Snooze, or resolve with the **same** conversation reused (single-conversation inbox or manual reopen), then a message within 12 h of the last reply | New burst in the same conversation, continuation, no send. |
| Burst crosses 21:00 | Existing mode checks unchanged; both rules apply in either mode. |
| Two jobs for one burst at once | Existing conversation lock and marker: at most one send. |
| Acknowledgement row marked deleted | Still counts as the burst's marker (unchanged): no second send. |
| Failed, private, bot, template, deleted or recovered outgoing within 12 h | Not a qualifying reply: no suppression. |
| F is unsent or deleted | The next eligible message becomes F and is judged against its own window. |
| The reply that started the burst later fails or is deleted | The burst merges back to an earlier F and is re-judged. |
| Resolve, then a message that opens a new conversation | New conversation, no history: judged as new. |
| Configuration invalid | Raises as today, before either rule. |

The added query reads only public outgoing messages of one conversation inside a 12 h window.

## Rollout

Code-only release: no configuration, no `started_at` change, no replay, no migration. Jobs already queued are evaluated
by the new rules when they run. Rollback is the previous image; suppressed sends are not replayed afterwards.

The night five-minute recent-reply guard stays unchanged; within one conversation the 12 h rule already covers it.

Registry: a new `UMI-PATCHES.md` row for this patch (what, why, remove-when), and the two lines in
`docs/UMI-CUSTOMER-AUTO-REPLIES-SPEC.md` "Behavior" that a later question after a reply "may begin a new" burst and that
night replies resume "after the active-exchange suppression expires" point to this spec.

Outside the repo, owner decision: Mai's published guide (section "Automatic acknowledgements (Facebook and
Instagram)", recorded in `docs/UMI-CUSTOMER-AUTO-REPLIES-SPEC.md` "Mai guide addition published at activation") says
"A new question after a team member answers can start a new wait." That becomes false with this release. Proposed
replacement, for root to publish:

> After a team member answers, the customer's next messages get no automatic confirmation if they arrive within 12
> hours of that answer, or if they contain only emoji or punctuation (for example a story reaction). A missing
> confirmation never means the message is handled: those messages still need your reply.

Editing the published guide is an external write and is not part of this change.

## Tests

Red against `2f420f203` (fails before, passes after). Times are Bangkok; day 09:00–21:00.
1. Production-shaped thanks: User reply, then "ขอบคุณค่ะ 🙏" 3 min later (day) → no send.
2. The same after an external-echo reply (sender cleared explicitly, `external_echo: true`) → no send.
3. Night: reply 22:00, "Thank you!" 22:20 → no night send.
4. Emoji story reaction on first contact (`content "😍"`, `image_type ig_story_reply`, `ig_story` attachment) → no send;
   and the same with no text.
5. Grace cutoff: reply at t0, F at exactly t0 + 12 h → no send (inclusive).
6. Delay: reply 20:00, F 20:30, its day job runs at 09:30 the next day (inside 24 h, same mode) → no send.
7. Snooze, and resolve then a new message in the same conversation (reopened in place), within 12 h of the last reply
   → no send.
8. A reply recorded before activation (`started_at`) still makes the next burst a continuation.
9. Anchor vs trigger: F = thanks within 12 h of the reply, a substantive question in the same burst more than 12 h after
   the reply; run only the question's job → no send.
10. Mode change: reply 20:40, thanks 20:55 (its day job is discarded at 21:00), question 21:05 → the night job does not send.
11. Emoji shapes on first contact: "❤️👍🏽🇹🇭👨‍👩‍👧🏴󠁧󠁢󠁥󠁮󠁧󠁿#️⃣", "!!", "…" → no send.
12. Mixed burst: "😍" first, its job → 0 sends; then a real question, its job → 1 send whose marker records the emoji.
13. Concurrency: two workers on a continuation burst → 0 sends (1 before the change).
14. Production-shaped ad-menu tap: the customer's tap, Meta's menu answer as an external echo, then a typed real
    question; its day job → no send; a delayed job for it the next morning and a later question in the same burst
    (more than 12 h after the echo) → still no send, and the burst's anchor is the first typed message throughout.

Behaviour kept, green before and after:
15. F at t0 + 12 h + 1 s → send.
16. Captionless image, image with an emoji caption, Thai question without "?" ("มีไซส์ M ไหมคะ"), "38", "2️⃣", "1️⃣"
    on first contact → send.
17. "?" alone and "❓" alone on first contact → send.
18. Shared post or a bare share attachment (non-eligible rows) followed by "😍" → send. A deleted row with symbol-only
    content, an unsupported row, a blank row without attachment and a recovered question each block the veto → send.
19. A failed or private reply within 12 h does not suppress.
20. A reply in another conversation of the same contact does not suppress (conversation-local).
21. Resolve without single-conversation reuse: the next message in a new conversation → send.
22. F unsent after the reply: the next message becomes F and is judged on its own window.
23. An acknowledgement row marked deleted keeps deduplicating; one send per burst under concurrent jobs.
24. Existing day/night, mode-boundary, lifecycle, channel and concurrency specs stay green.

Existing examples that encode the removed behaviour (a burst minutes after a human reply is acknowledged):
`spec/services/umi/customer_acknowledgement_spec.rb:71` and `:123`, and
`spec/services/umi/customer_acknowledgement_channels_spec.rb:212`. They keep their subject (old jobs not
acknowledging a new burst early; dedup across modes) by starting that new burst more than 12 h after the reply. In the
last two, that moves the final step into daytime, so it becomes a day job. Each adapted example still proves its
original subject, and the removed behaviour itself is pinned by the red cases 1–3 and 10, so the fixture changes cannot
hide it. The commit records each edit.

Regression run: all acknowledgement specs, operator queue, operational report, message window, funnel and Shopify
suites touched by template rows, plus rubocop.
