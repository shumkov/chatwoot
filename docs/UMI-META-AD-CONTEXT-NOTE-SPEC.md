# UMI — Ad context note

Show the agent what the ad already told the customer, as a private note on the
conversation.

**Status: implemented.** Revision 5, after five independent reviews
(feasibility, failure-modes, scope, security, domain-fit) and a red-before-green
pass over every load-bearing test. Base tag `v4.16.0`, branch
`feat/ad-context-note`.

### Changes in revision 5

**Scope addition (owner, 2026-08-12): the campaign hierarchy.** An external
assessment told the owner that "without custom implementation, Chatwoot cannot
identify which Campaign, Ad Set, or Ad generated each conversation." Patch 20
makes the ad half false; this closes the other half. Meta's webhook carries only
`ad_id` and `ad_title`, but `campaign{id,name}` and `adset{id,name}` **expand
into the request already being made** — verified on the live ad, one round trip,
creative unaffected:

```
campaign: 05082026_Conversation_Messages Engagement
ad set:   Thai_Board
ad:       Video_2
```

Rendered as one line, **last**, below the greeting and the answer: the hierarchy
is context, not what the agent opened the conversation to read. It degrades
independently — if either level is missing the note still posts with everything
else, and if both are missing the line is dropped rather than printing an ad
name the sidebar already shows.

**Two of these specs were vacuous and the red pass caught them.** Both passed
against deliberately broken code:

- *"still allows the real note once Meta recovers"* deleted the failure note
  before re-running, so the two-status guard was never exercised. It was testing
  the rake task's cleanup. Now the failure note is left in place.
- *"reports failures that are not Graph errors"* stubbed Koala to raise
  `NoMethodError` — but the service converts everything it catches into
  `Unavailable`, so the job's catch-all was never reached. The failure now
  arises in the presenter, outside the service.

The first exposed a real design gap: on recovery the thread would have shown the
failure note above the real one. Posting a success note now deletes any failure
note in the same lock.

Everything under "measured" was taken on 2026-08-12 against the live
installation with read-only Graph GETs and DB reads. No production write, and
no modification to any ad, was performed.

---

## 0. The gate — raised, then resolved

**Resolved 2026-08-12. Cleared to implement.** What happened:

1. Patch 20 deployed as `umi-v4.16.0-1`; migration `20260811000000` run by hand,
   rails + sidekiq restarted, both modules and all three builder prepends
   verified loaded in the running process, three `CustomAttributeDefinition`
   rows present.
2. A Messenger ad conversation (870, 20:13 Bangkok) then captured **nothing** —
   code verified loaded, so Meta was the silent party. Confirmed here:
   conversation 870 carries `custom_attributes: {}`.
3. **Root cause: `messaging_referrals` was not subscribed on the Page.** Now
   subscribed (6 fields → 7, read-union-write-verify). So Meta's documented
   requirement *does* bind on Messenger — it simply does not bind on Instagram,
   which is why the earlier reading concluded otherwise.
4. Instagram referral arrival is **proven from captured payloads**: 5 of 120
   Instagram messaging entries over 7 days carried a complete `referral` with
   `ad_id` and `ads_context_data`.
5. Not yet confirmed: a **live Messenger capture**. Zero ad-originated
   conversations have arrived since the subscription change.

**Owner decision: build now, do not wait.** The trigger keys on `meta_ad_id`
being present, which is platform-agnostic; the payload shape is verified from
real captured data rather than docs; the specs prove the code without live
traffic; and if referrals never arrive the job simply never fires — the correct
failure mode, costing nothing. Recorded rather than assumed so a later reader
knows §0 was cleared by decision plus four proven points, not by a live capture.

The original argument for the gate is kept below, because it is still the reason
the subscription fix mattered and the reason a live Messenger capture remains
worth confirming:

| Measured | Value |
|---|---|
| Tap conversations, 90 days | 31 |
| …on Messenger | **22** |
| …on Instagram | 8 (+1 indeterminate) |
| Conversations where Meta's auto-reply is stored in Chatwoot | **8 — exactly the Instagram ones** |
| Page's live `subscribed_fields` | `messages`, `message_deliveries`, `message_echoes`, `message_reads`, `standby`, `messaging_handovers` |
| `messaging_referrals` subscribed | **no** |

The blindness this patch exists to cure is **entirely on Messenger**. The
trigger depends on patch 20, whose registry records Instagram referrals
arriving with complete `ad_id` but Facebook as **unverified** — and the
subscription field Meta documents as required for ad referrals is absent from
the live page.

So the plausible failure is an *inverted* patch: notes on the 8 Instagram
threads, where Meta's answer is already visible in the thread, and nothing on
the 22 Messenger threads that need it. That cannot be settled from the database
— patch 20 is not deployed and zero conversations carry `meta_ad_id`.

That is what happened, and the subscription work (backlog A3) is what fixed it —
`messaging_referrals` added by reading the live field set first and never via
`channel.subscribe`, which rescues `StandardError` and returns `true`, so a
failed re-subscribe looks successful.

**Still worth confirming once traffic resumes:** one Messenger conversation
carrying `meta_ad_id`. Until then the Messenger path is argued, not observed.

---

## 1. The problem, and the limits of what we know

A customer taps a menu option in a Click-to-Messenger ad. Meta answers in 1–5
seconds. On Messenger that answer **never reaches Chatwoot** — measured above,
0 of 22. The agent opens the thread and sees one bare line:

```
3. ขอแนะนำสินค้าขายดีของ UMI
```

**Hypothesis (not established):** agents send a mismatched canned block partly
because they cannot see what the customer was already told.

**The competing explanation, which this repo already measured, is stronger.**
`docs/UMI-META-AUTOMATION-PORT-SPEC.md` records that the Mother's Day tap gets
the best-sellers block because *there is no Mother's Day block* — only two
reply blocks exist in circulation. No amount of visibility conjures a third
block. That spec's deliverable #2 (write the missing block) costs no code and
outranks this patch.

**Falsifier for the hypothesis:** if, after this ships, agents keep sending
mismatched blocks at the same rate, visibility was not the binding constraint.

The Fisher p ≈ 3.3e-6 figure from the backlog establishes that ad taps die more
often than organic conversations. It does **not** select between the two causes,
and this spec does not claim it does.

### A number that needed correcting

The backlog states agents answer ad taps in a **1.1 min median**, faster than
organic's 17.9 min. Measured over 90 days on the tap cohort: of 28 replied taps,
9 got a reply within 60s — **but 8 of those 9 are Meta's own ice-breaker echo,
not an agent** (`sender_type` nil, `content_attributes: {external_echo: true}`).
The fastest genuine agent reply is **26 seconds**; the rest are minutes.

The 1.1 min median counts Meta's automation as an agent reply. That figure
should be corrected wherever it is cited. It also means this job has far more
timing headroom than a 1.1 min budget implies (§4).

---

## 2. Measured facts

### 2.1 The Page token can read the ad node — undocumented

`debug_token` on `Inbox.find(2).channel.page_access_token` returns granted
scopes including **`ads_read`** and **`ads_management`**. Meta documents Page
tokens as unable to read Ads API nodes; ours can. **Revocable without notice**,
so the failure path is visible by construction (§6).

### 2.2 Koala sends an unversioned URL; the Ads API rejects it

`Koala.config.api_version` is **`nil`** here — Chatwoot never sets it. Every
existing Koala call in the tree is a Graph *Page* call, which still tolerates
that. This patch is the codebase's **first Ads API caller**:

```
Koala::Facebook::ClientError: (#2635) You are calling a deprecated version of
the Ads API. Please upgrade to the latest version: v25.0.
```

`get_object(id, args = {}, options = {})` takes `api_version` in the **third**
argument; `Koala::HTTPService::Request` reads
`raw_options[:api_version] || Koala.config.api_version` and prefixes the path
(gem source, `http_service/request.rb:37`). Verified: **v21.0 through v25.0 all
return a byte-identical payload.** Pin **v25.0** — newest, longest support
window, and the five-version agreement means a forced bump is a constant change.

### 2.3 The documented field is empty; the payload is nested

`creative.page_welcome_message` returns **nil**. The real payload is at
`creative.object_story_spec.video_data.page_welcome_message`, as a JSON-encoded
**String**.

Same failure class as patch 20's nested `referral`: the documented path returns
`nil`, indistinguishable from "this ad has no welcome message". So the extractor
**scans recursively for the key, bounded to the `creative` subtree** — one rule
covering `video_data`, `link_data`, `photo_data`, `text_data`, `template_data`
and the top-level field.

> Scope review preferred an explicit 6-path list, arguing a blind scan risks an
> accidental match. Keeping the scan: bounding it to `creative` leaves that risk
> nowhere to live, and a fixed list is only future-proof against carriers Meta
> has already documented. Recorded as a live disagreement, not an oversight.

### 2.4 Structure, and three traps

```jsonc
{ "media_type": "text",                        // ← selects the live block
  "text_format": {
    "customer_action_type": "ice_breakers",    // ← selects the item shape
    "message": {
      "text": "สวัสดีค่ะ 👋 {{user_full_name}}    แจ้งให้เราทราบ…",
      "ice_breakers": [ { "title": "1. สนใจรับส่วนลด 10%…", "response": "สวัสดีค่ะ 🤍 …" },
                        { "title": "2. ขอแนะนำสินค้าสำหรับวันแม่", "response": "…identical…" },
                        { "title": "3. ขอแนะนำสินค้าขายดีของ UMI", "response": "…identical…" } ] } },
  "image_format": { … English quick reply "I'd like to learn more" … },
  "video_format": { … same … } }
```

1. **`media_type` selects the live block.** All three `*_format` blocks are
   always present. `image_format`/`video_format` here carry an English quick
   reply **no customer has ever seen**. A naive scrape for
   `ice_breakers`/`quick_replies` renders it as if Meta had sent it.
2. **`customer_action_type` selects the item shape.** `ice_breakers` have
   `title` + `response`; `quick_replies` have `title` only.
3. **The three responses are byte-identical.**

### 2.5 Cross-validation: the API payload matches what Meta actually sent

For the 8 Instagram taps, Chatwoot stored Meta's reply as an outgoing message.
Its `content` is **byte-identical** to the `response` field fetched from the ad
creative. The extraction path is validated against independent evidence, not
only against itself.

### 2.6 Liquid would corrupt the note — and the obvious fix does not work

`Liquidable` runs `before_create` on every outgoing message, private notes
included. The live greeting contains `{{user_full_name}}`, which is not a
registered drop, so Liquid renders it to **empty string** — a quietly falsified
record of what Meta sent.

**Revision 1 proposed wrapping the body in `{% raw %}…{% endraw %}`. That is
broken, two ways, both demonstrated:**

- `liquidable.rb:37` pre-wraps backtick spans in `{% raw %}`. Raw blocks do not
  nest — the outer block closes on the *inner* `{% endraw %}`. Run against this
  repo's bundled Liquid, a body containing backticks raises
  `Liquid::SyntaxError`; `process_liquid_in_content` rescues it and the note
  persists with **literal `{% raw %}` markers visible to the agent**.
- The wrapped text is 100% third-party ad copy. A literal `{% endraw %}` in it
  closes the block early and the remainder is parsed as live Liquid with
  `contact`, `conversation`, `inbox`, `account` drops in scope — so ad copy
  could render `{{contact.email}}` into the note. The trust boundary is whoever
  holds Ads Manager edit access, a routinely phished credential.

**Chosen fix — remove the surface instead of escaping it.** Prepend onto
`Message` an override of `Liquidable#liquid_processable_message?` returning
false when `content_attributes['umi_ad_context']` is present. The note is then
stored exactly as built: no interpolation, no injection, no escaping to get
subtly wrong.

---

## 3. Design

```
inbound FB/IG message
  └─ patch 20 stores referral on the message (in txn), promotes meta_ad_* (post-COMMIT)
     └─ trigger enqueues Umi::Meta::AdContextNoteJob(conversation_id)  ← only if meta_ad_id was written
        └─ Sidekiq :medium
           ├─ skip if a note already exists on this conversation
           ├─ GET the ad creative (inbox's page token, api_version pinned)
           ├─ extract → render (trimmed, §4)
           └─ create a PRIVATE outgoing message, sender: nil, Liquid-exempt
```

**Never on the inbound path.** The Graph call is in a background job. Patch 20
already documents the failure this avoids — a rescued DB error inside the
builder transaction kills the customer's message at COMMIT — and this project
had a near-miss on exactly that.

**No cache.** ~1.4 attributed conversations/day, so fetching fresh costs ~1.4
Graph calls/day against limits three orders of magnitude higher. In exchange the
note is never stale.

> Freshness caveat: backlog D3 records partner-app welcome-message *flows* as
> immutable while an ad is live. Whether that binds the creative's inline
> `page_welcome_message` is **not established**. Meta's model treats ad
> creatives as immutable — an Ads Manager edit spawns a new creative and bumps
> the ad's `updated_time` — which would make freshness real and `updated_time`
> a valid change key. **Inference, not verified**, and it cannot be verified
> without writing to an ad. If volume ever justifies a cache, the key is
> `updated_time`, never a TTL.

**A private note, not frontend work.** `private: true`, `message_type:
:outgoing`, `sender: nil`. Renders inline where the agent is already looking.

### 3.1 What "invisible to the customer" does and does not mean

**Cannot reach the customer via the channel:**
`Base::SendOnChannelService#invalid_message?` returns early on `private?`, and
`Facebook::SendOnFacebookService` and `Instagram::BaseSendService` (parent of
both Instagram send services) inherit it. Pinned by test §8.2.

**Can reach the same surfaces as any other private note.**
`MessageFilterHelpers#webhook_sendable?` is `incoming? || outgoing? ||
template?` — it does **not** check `private?`. So account webhooks
(`WebhookListener`) and AgentBots receive the full body. This is pre-existing
Chatwoot behaviour for every private note, not introduced here.

Measured today: **one** account webhook (n8n Shopify enrich) subscribed to
`conversation_created`, `contact_created`, `contact_updated` — **not
`message_created`** — and **zero** AgentBots. The surface is empty. Recorded so
nobody reads §3 as "cannot leave Chatwoot".

Checked and safe: transcript emails and agent notifications sit behind
`messages.chat` (`where(private: false)`) or check `!private?` explicitly.

### 3.2 Reporting safety

Private notes are outgoing messages, and outgoing messages normally satisfy
`Message#human_response?` — which nulls `waiting_since`, stamps
`first_reply_created_at`, dispatches `REPLY_CREATED`/`FIRST_REPLY_CREATED` and
writes `ReportingEvent` rows. That would corrupt response-time reporting and
drop ad conversations out of Unattended — the exact population this work must
be measured on.

Three guards block it — but **they are not independent, and revision 2 was wrong
to imply they were**:

| Guard | Location | Why it holds |
|---|---|---|
| `update_waiting_since` skips the outgoing branch when `private` | `message.rb:340` | `private` is true |
| `valid_first_reply?` needs `human_response? && !private?` | `message.rb:225` | both fail |
| `human_response?` requires `sender.is_a?(User)` or `external_echo` | `message.rb:362` | sender is `nil` |

**`private: true` alone carries the first two.** `sender: nil` is load-bearing
only for `human_response?` in isolation — flipping the sender to a `User` while
`private` stays true changes nothing observable, because
`update_waiting_since` gates the whole outgoing branch on `!private` before
`human_response?` is ever consulted. This matters for the test design: revision
2's §8.3 red mutations were written as though each guard could be knocked out
alone, and two of the three would have come back green — reporting two guards
inert when the truth is that `private` subsumes them. Corrected in §8.3.

Also verified safe, and previously omitted: `reopen_conversation` returns unless
`incoming?` (`message.rb:405`), and
`mark_pending_conversation_as_open_for_human_response` returns on `private?`
(`message.rb:415`).

Accepted side effects: `set_conversation_activity` bumps `last_activity_at`
(normal for any private note; affects inbox sort only); `MESSAGE_CREATED`
dispatches (see §7); and `should_index?` (`message.rb:251`) is true for outgoing
private notes, so the ad copy enters the search index **if
`ChatwootApp.advanced_search_allowed?` is ever enabled** — upstream behaviour for
every private note, listed here because this section enumerates side effects.

> Note for whoever works on reporting next: the 8 stored Instagram echoes carry
> `external_echo: true`, which **does** satisfy `human_response?`. Meta's
> automation is currently stamping `first_reply_created_at` on those
> conversations. Out of scope here, but it means Instagram ad conversations are
> already being counted as agent-answered.

---

## 4. The note

Owner decision, 2026-08-12: **trim to what is actually new.**

The reviewer's objection is sound. The greeting, the three titles and the three
identical answers are properties of *the ad*, invariant across every
conversation from it. The tap message already shows the tapped title verbatim
(10/10 sampled), and patch 20's sidebar already shows ad name and id. So the
note must carry only the delta:

- **which option was tapped**, marked — the presenter has the conversation, so
  it has the tap message, and the title↔tap match is string equality already
  validated on production data
- **the greeting** Meta sent before the tap (the customer saw this first)
- **the answer** — once, not three times, when they are identical
- **the options not taken**, as bare titles
- **no** ad name/id header — the sidebar has it
- **skipped or trimmed on Instagram**, where the answer is already an outgoing
  message in the thread

```markdown
**From the ad.** Before tapping, the customer was greeted with:
> สวัสดีค่ะ 👋 {{user_full_name}}    แจ้งให้เราทราบได้เลยว่ามีอะไรให้เราช่วยคุณได้บ้าง

They tapped **option 3 of 3** — *ขอแนะนำสินค้าขายดีของ UMI*.
The other options were: *สนใจรับส่วนลด 10%…*, *ขอแนะนำสินค้าสำหรับวันแม่*.

The ad is configured to answer **all three options identically**, with:
> สวัสดีค่ะ 🤍 ขอบคุณสำหรับข้อความของคุณ
> เราได้รับข้อความของคุณเรียบร้อยแล้ว และจะตอบกลับโดยเร็วที่สุด
> ระหว่างนี้ คุณกำลังสนใจสินค้ารุ่นไหนอยู่คะ? เรายินดีช่วยแนะนำค่ะ ✨

_Read from Meta 09:12. Not visible to the customer. Meta's reply is not stored
in Chatwoot on Messenger, so this is the only record of it._
```

**"is configured to answer", never "Meta sent".** Only 23 of 30 taps got a
reply — ~23% did not. On a patch whose principle is "never a silently blank
note", asserting an unobserved send in the agent's face is the same error.

**No backticks anywhere in the body or the failure note** (§2.6). Belt and
braces alongside the Liquid exemption.

Labels are plain English, not `I18n.t`: the whole `umi/` overlay contains zero
`I18n.t` calls and no locale load path, and adding keys to upstream's `en.yml`
adds rebase conflict surface. Deliberate deviation, flagged not buried.

---

## 5. Files

| File | Role |
|---|---|
| `umi/app/services/meta/ad_welcome_message_service.rb` | `Umi::Meta::AdWelcomeMessageService` — one Graph GET, extract, value object |
| `umi/app/services/meta/ad_context_note_presenter.rb` | `Umi::Meta::AdContextNotePresenter` — value object + conversation → body |
| `umi/app/services/meta/ad_context_note_trigger.rb` | `Umi::Meta::AdContextNoteTrigger` — prepended onto patch 20 |
| `umi/app/models/ad_context_note_liquid_exempt.rb` | `Umi::AdContextNoteLiquidExempt` — prepended onto `Message` |
| `umi/app/jobs/meta/ad_context_note_job.rb` | `Umi::Meta::AdContextNoteJob` |
| `config/initializers/zz_umi_meta_ad_context_note.rb` | wires both prepends |
| `lib/tasks/umi_meta.rake` (extend) | `umi:meta:ad_context_note[conversation_id]` |
| `UMI-PATCHES.md` | **patch 21 row** (§10) |

**Naming.** Revision 1 wrote `module Umi::Meta::AdContextNote::Trigger`, which
NameErrors at boot — `Umi::Meta::AdContextNote` has no constant behind it.
Zeitwerk resolves `umi/app/services/meta/ad_context_note_trigger.rb` →
`Umi::Meta::AdContextNoteTrigger`, matching the existing
`umi/app/services/meta/ad_attribute_definition_setup.rb`. Concern modules go
directly under `umi/app/models/` — an overlay `concerns/` folder is not
auto-collapsed.

### 5.1 The trigger

```ruby
module Umi::Meta::AdContextNoteTrigger
  def promote(message, referral)
    super                                      # OUTSIDE the rescue — see defect 1
    return unless from_ads?(referral)
    return if message.conversation.reload.custom_attributes['meta_ad_id'].blank?

    begin
      Umi::Meta::AdContextNoteJob.perform_later(message.conversation_id)
    rescue StandardError => e
      Rails.logger.warn("[UMI-FBIG] stage=ad_context_enqueue_failed error=#{e.class}")
    end
  end

  def purge_for(contact)                       # §6.1
    super
    ...
  end
end
```

The initializer must mirror patch 20's own
(`config/initializers/zz_umi_fbig_ad_attribution.rb:8`), **not** prepend at
top level:

```ruby
Rails.application.reloader.to_prepare do
  raise 'UMI: patch 20 changed — rebase Umi::Meta::AdContextNoteTrigger' \
    unless Umi::FbigAdAttribution.respond_to?(:promote) &&
           Umi::FbigAdAttribution.respond_to?(:purge_for)

  unless Umi::FbigAdAttribution.singleton_class.include?(Umi::Meta::AdContextNoteTrigger)
    Umi::FbigAdAttribution.singleton_class.prepend(Umi::Meta::AdContextNoteTrigger)
  end
  # …plus the Message prepend for the Liquid exemption (§2.6), same shape.
end
```

Three reasons, all verified rather than assumed:

- **`Umi::*` is a reloadable autoload path.** After the first dev reload Zeitwerk
  hands out a new module object with a clean singleton class, and a top-level
  prepend silently stops firing. Patch 20 uses `to_prepare` for exactly this.
- **The `unless include?` guard** keeps it idempotent across reloads.
- **The explicit `raise` is what actually makes it fail loud.** §5's original
  claim — "the prepend raises `NameError` if patch 20 is deleted" — holds only
  for *total* removal. If a rebase renames or inlines `promote` while the module
  survives, `singleton_class.prepend` cheerfully defines `promote` on a module
  nobody calls, and the feature dies silently — the precise outcome the prepend
  was chosen to prevent. The sibling initializer already solves this
  (`zz_umi_fbig_ad_attribution.rb:12-25`); copy it.

`to_prepare` runs during boot under eager_load, so the fail-loud property is not
weakened by moving inside it.

Three defects from revision 1, all fixed above:

1. **The rescue no longer wraps `super`.** Previously a DB failure inside
   `promote` (`conversation.update!` under `with_lock`) was caught by the
   trigger and mislabelled `ad_context_enqueue_failed`, never reaching patch
   20's `stage=referral_promote_failed` + `ChatwootExceptionTracker`. On an
   installation where the log line is the only signal, that erases the signal.
2. **No longer enqueues on referrals `promote` rejected.** `promote` returns
   early for `source != 'ADS'` (Instagram Shops product taps) and for blank
   pairs; `super` swallows that. Now gated on `meta_ad_id` actually being
   present.
3. **Correct constant name** (above).

**Why a prepend rather than one line inside patch 20.** Patch 20's remove-when
is "upstream captures Meta `referral` for FB/IG". When that lands its file is
deleted, and an inlined enqueue would vanish with it, silently killing this
patch and — worse — the erasure hook in §6.1. The prepend raises `NameError` at
boot instead. Scope review disagreed and preferred inlining; domain review
called the reasoning sound. Kept, and the erasure hook makes it decisive.

**Mechanically verified**, since `promote` is declared under `module_function`:
`Foo.singleton_class.prepend(M)` **does** intercept `Foo.promote(x)`, and does
**not** intercept an unqualified call from a module that `include`s it. Patch 20
calls `Umi::FbigAdAttribution.promote(@message, referral)` with an explicit
receiver, so the prepend binds. Pinned by test §8.9 — if a future rebase changes
that call to the unqualified form, the trigger goes silent.

### 5.2 Service

```ruby
Umi::Meta::AdWelcomeMessageService.new(access_token).fetch(ad_id)
# => Welcome(ad_id:, ad_name:, updated_time:, greeting:, action_type:, items: [{title:, response:}])
# raises Unavailable on any Graph error, missing key, or unparseable payload.
```

`GRAPH_API_VERSION = 'v25.0'`;
`FIELDS = 'id,name,updated_time,creative{id,page_welcome_message,object_story_spec,asset_feed_spec}'`.

Extraction: recursive scan bounded to `creative` for the first non-blank
`page_welcome_message` (String → parse; Hash → use) → select
`"#{media_type}_format"` falling back to `text_format` → `message.text` →
items per `customer_action_type`. `Unavailable` if greeting and items are both
blank.

### 5.3 Job

```ruby
class Umi::Meta::AdContextNoteJob < ApplicationJob
  queue_as :medium
  retry_on Umi::Meta::AdWelcomeMessageService::Unavailable,
           wait: 5.seconds, attempts: 4

  def perform(conversation_id)
    ...
  rescue StandardError => e                    # terminal handler, see below
    post_failure_note(e)
  end
end
```

`:medium` matches `hook_job`/`webhook_job`/`macros_execution_job`. `:low` is
starved by Chatwoot's strict queue ordering. Timing budget is the **26-second**
fastest genuine agent reply (§1), not the contaminated 1.1 min figure.
`attempts: 4` is explicit because the installation's global Sidekiq
`max_retries` is 3 and ActiveJob `retry_on` needs its own count. `retry_on`'s
block runs only once `executions >= attempts`
(`activejob-7.1.5.2/lib/active_job/exceptions.rb:69`).

**`wait: 5.seconds`, not `:polynomially_longer`.** The polynomial schedule is
`executions**4 + 2` → ~3 s, ~18 s, ~83 s, exhausting **~104 s** after the tap —
past the point the agent has replied, which makes both a late success note and
the failure note artefacts. Flat 5 s keeps all four attempts inside ~20 s.

**The failure note is the terminal handler for *all* exceptions, not a
`retry_on` block.** Revision 2 put it in the block, which is wrong three ways:

- **Only `Unavailable` reaches it.** `ApplicationJob` carries only
  `discard_on ActiveJob::DeserializationError`, no `rescue_from`, and there is
  no `sidekiq_options` anywhere in the tree — so everything else
  (`ActiveRecord::RecordNotFound` from a conversation deleted mid-flight,
  `RecordInvalid` from `create!`, a `NoMethodError` from the presenter on an
  unexpected payload) escapes to Sidekiq's 3 retries and then the **unwatched**
  Dead set. Per `umi-observability-netdata-no-sentry` that is fail-silent, which
  is the one thing this patch may not be.
- **Raising inside the block compounds the retry layers.** The block's exception
  propagates out, Sidekiq replays the original payload (`executions` frozen at
  3) three more times, and each replay re-runs `perform` top to bottom: worst
  case **7 Graph calls and 4 failure-note attempts** for one tap.
- **If the failure note's own `create!` raises**, the job lands in the Dead set
  with no note and no signal.

So: `perform` ends in `rescue StandardError => e` → log
`[UMI-FBIG] stage=ad_context_failed error=#{e.class}` → post the failure note
inside its own rescue → return normally. The log line is what a Netdata
filecheck heartbeat can watch; the Dead set is not.

### 5.4 Note record

```ruby
conversation.messages.create!(
  account_id:, inbox_id:, message_type: :outgoing, private: true, sender: nil,
  content: body,
  content_attributes: { umi_ad_context: { ad_id: ad_id, status: 'ok' } }
)
```

Direct `create!` rather than `Messages::MessageBuilder`, which would add email
processing and a second Liquid pass and wants a `User`.

**Idempotency: once per conversation** (owner's original ask; revision 1's
(conversation, ad_id) superset dropped). **Two guards keyed on `status`, not
one** — revision 2 had a single guard and it was a serious bug:

**The guard is evaluated in Ruby, not SQL** — see the encoding trap below:

```ruby
notes = conversation.messages.select { |m| m.content_attributes['umi_ad_context'].present? }
# success path skips only if a GOOD note exists
notes.any? { |m| m.content_attributes.dig('umi_ad_context', 'status') == 'ok' }
# failure path skips if ANY note exists
notes.any?
```

**Why: one transient Graph blip would otherwise poison the conversation
permanently.** Meta rate-limits → 4 attempts exhaust → failure note posted →
Meta recovers 30 s later → nothing re-runs → an operator follows §9 and runs
`umi:meta:ad_context_note[824]` → the single guard finds the error note → silent
return. The documented remediation is a no-op and the thread shows "Could not
read this ad's welcome message" forever, for a perfectly readable ad. Same trap
if an ad later *gains* a welcome message. The rake task additionally deletes any
`status: 'error'` note before running.

### The encoding trap — measured, and it invalidates the obvious SQL

`messages.content_attributes` is a `json` column carrying `store … coder: JSON`,
so Rails serialises the hash **and then the column serialises the string**. The
stored value is a JSON *string*, not an object. Measured in production:

```
jsonb_typeof(content_attributes::jsonb)  →  "string"   (every row)
content_attributes::jsonb -> 'any_key'   →  NULL       (always)
```

| Predicate | via SQL | via Ruby |
|---|---|---|
| `->> 'external_echo' = 'true'` | **0** | **5029** |
| `-> 'referral' IS NOT NULL` | **0** | 0 (none stored yet) |

So `content_attributes::jsonb -> 'umi_ad_context'` — revision 2's guard, and the
shape patch 20 uses — **matches nothing, silently**. The success guard would
never fire and every job run would post another note.

A corrected SQL form exists (`(content_attributes::jsonb #>> '{}')::jsonb -> …`,
double-decoding), but this predicate is safety-critical and its failure mode is
silence. The guard runs inside a lock we already hold, on one conversation's
messages — a bounded set — so it is evaluated in **Ruby**, where the accessor
does the decoding and a mistake cannot be silent.

> **Live defect in deployed patch 20, out of scope for this patch.**
> `purge_for` uses `content_attributes::jsonb -> 'referral' IS NOT NULL` for its
> Shopify-redaction erasure. That predicate matches nothing for the same reason.
> It reads 0 today only because no referrals are stored yet; `messaging_referrals`
> was subscribed on 2026-08-12, so as soon as referrals arrive the erasure path
> will silently strip nothing while reporting success. Needs its own fix and its
> own commit. The `conversations.custom_attributes` half is **fine** — that
> column is real `jsonb` with no `store` coder.

**The guard runs inside `conversation.with_lock`, with the Graph call outside
it:**

```ruby
welcome = service.fetch(ad_id)                 # network, no lock held
conversation.with_lock do
  return if guard_hit?
  conversation.reload.custom_attributes['meta_ad_id'].present? or return  # erasure race
  conversation.messages.create!(...)
end
```

A bare SELECT-then-INSERT is not enough, and "worst case is a duplicate note" was
wrong. Two verified concurrent-enqueue paths exist: **two taps in one
conversation** (production conversation 824, seconds apart, Sidekiq
`:concurrency: 10`), and **Meta webhook redelivery** — `messages.source_id`
carries a *non-unique* index (`db/schema.rb:1172`) and `Message` has no
uniqueness validation, so a redelivered webhook builds a second message and
promotes again.

The real worst case: worker A succeeds, worker B's Graph call rate-limits
(likelier precisely when two fire together), and ~20 s later the thread shows a
correct ad-context note **followed by** "Could not read this ad's welcome
message — check the ad in Ads Manager before replying." The agent gets a direct
contradiction with the failure note last. That is worse than no note at all, and
it is exactly what the "never a silently blank note" rule exists to prevent.

`with_lock` is the same primitive patch 20 already uses
(`fbig_ad_attribution.rb:64`) — no new infrastructure, no functional index. A
`Redis::Alfred` NX/EX lock would also work; `Rails.cache` would **not**, being a
per-container FileStore in production.

The job re-reads `meta_ad_id` from the conversation rather than trusting a job
argument, so it is safe to invoke by hand and produces nothing for a
conversation whose attribution was erased.

---

## 6. Failure modes

Rule: **never a silently blank note.** Page-token ads access is undocumented and
revocable; when it stops working the agent must see that.

| # | Failure | Behaviour |
|---|---|---|
| 1 | Conversation gone, `meta_ad_id` absent or erased | silent return |
| 2 | Note already exists | silent return |
| 3 | `page_access_token` blank | see below |
| 4 | Graph 5xx / timeout / rate limit | `Unavailable` → 4 retries at 5 s → failure note |
| 5 | Graph 400/403 — access revoked, ad deleted, version deprecated | → failure note |
| 6 | `page_welcome_message` absent, unparseable, or behind an indirection | → failure note. Also the correct outcome for an ad with genuinely no welcome message. |
| 7 | Liquid corruption | prevented by the exemption (§2.6), pinned by §8.1 |
| 8 | Anything else — `RecordNotFound`, `RecordInvalid`, presenter `NoMethodError` | caught by the terminal handler (§5.3) → failure note + `stage=ad_context_failed` |

Revision 1's separate row for indirection carriers is **folded into 6**: it
specced bespoke detection for a branch nothing in production exercises. The
generic reason string surfaces it if it ever appears.

Revision 2's row for `prevent_message_flooding` is **deleted** — it overstated
the risk and misstated the mechanism. `Limits.conversation_message_per_minute_limit`
defaults to **200/min** (`lib/limits.rb`) against ~2.5 conversations/day, so it
is unreachable here; and `create!` raises `ActiveRecord::RecordInvalid`, which
`retry_on Unavailable` never catches, so "retries on backoff" was wrong. It now
falls under row 8.

**Failure mode 3 — the "fail loud" contradiction.** Revision 1 said raise. But
`retry_on` covers only `Unavailable`, so it would land in the Sidekiq Dead set —
which per `umi-observability-netdata-no-sentry` is **unwatched**, with
`SENTRY_DSN` empty by design. "Fail loud" would have been fail silent. A Meta
inbox with no token is a deployment bug, so: log at `error` on the `[UMI-FBIG]`
prefix **and** post the failure note. The note is the signal; the log is for the
heartbeat check.

**The failure note** carries no ad copy and no backticks:

```markdown
**Ad context unavailable.** Could not read this ad's welcome message from Meta
after 4 attempts (error 100, OAuthException).

The customer may already have been answered by the ad. Check it in Ads Manager
before replying.
```

Marked `umi_ad_context: { ad_id:, status: 'error' }` so it satisfies the same
idempotency guard — no retry storm of failure notes — and is greppable.

**Never `e.message`.** Every other Graph caller in `umi/` logs `e.class.name`
only. A non-Koala exception (`Faraday::ConnectionFailed`, timeout, DNS) can
carry the full request URI **including the `access_token` query parameter** in
its message; putting that in an agent-visible note or a log line leaks the Page
token. Use `Koala::Facebook::APIError`'s structured `fb_error_code` /
`fb_error_type` — parsed from the JSON body, structurally incapable of carrying
the URL (verified: Koala's own `#message` does not contain the token, but the
non-Koala branch is the risk) — and bare `e.class.name` otherwise.

### 6.1 Erasure

**Revision 1 omitted this entirely.** Patch 20's `purge_for` states in its own
comment that ad attribution is behavioural data — "which ad this person clicked,
and when" — and strips it on Shopify redaction. This note stores exactly that
category (`umi_ad_context.ad_id`, plus the ad's copy in `content`), and
`purge_for` matches on the `referral` key, so it would leave the note sitting in
the conversation after erasure — contradicting the intent patch 20 states.

The trigger's `purge_for` override extends the same transaction — **selecting in
Ruby, deleting by id**, because the SQL key predicate is a silent no-op here
(§5.4):

```ruby
ids = Message.where(conversation_id: conversation_ids)
             .select { |m| m.content_attributes['umi_ad_context'].present? }
             .map(&:id)
Message.where(id: ids).delete_all if ids.any?
```

**Delete, not strip:** unlike `referral`, which lived only in
`content_attributes`, the sensitive text is in `content` — the whole message is
the artifact. `delete_all` matches the set-based rationale `purge_for` already
documents (avoiding `MESSAGE_UPDATED` webhook echo and
`prevent_message_flooding`). The same predicate catches failure notes, which
also carry `ad_id`. **Open question 1.**

**Residual race:** a job already in flight that read `ad_id` before the purge
committed could re-post afterwards. Closed by re-reading `meta_ad_id` inside the
lock immediately before `create!` (§5.4) — if erasure has run, it is gone and the
job returns. Pinned by §8.10.

---

## 7. Interaction with the planned automation rules

`AutomationRuleListener#message_created` ignores only `activity?` and
`auto_reply_email?` — **private notes are evaluated** — and
`ConditionsFilterService#base_relation` scopes to the *triggering* message.

The trimmed note still quotes menu titles. A `message_created` rule keyed on
`content contains "3. ขอแนะนำ…"` per `UMI-META-AUTOMATION-PORT-SPEC.md` would
match the note and fire a second time, **sending the customer the canned reply
twice**.

Latent today: production has one automation rule (`conversation_created` → add
label) and **zero** `message_created` rules, and this patch ships first.

**Requirement carried into the automation-port spec:** every `message_created`
rule must include `message_type is incoming` or `private_note is false`. Both
exist as filter keys (`lib/filters/filter_keys.yml`). Verification in §9.

---

## 8. Test plan — every one red before green

This project has shipped tests that passed against broken code. Revision 1's
§8.1 was itself an example: it asserted the content *contains*
`{{user_full_name}}`, which stays true when the Liquid render is skipped by an
exception — so it passed against the broken `{% raw %}` implementation. Each
test below is run against a deliberately broken version first and the red output
pasted into the commit message.

**8.1 Liquid cannot touch the note.** Fixture: the real `page_welcome_message`
captured from ad 120252251820030415, `{{user_full_name}}` included, checked in
verbatim. Assert the persisted `content` is **byte-identical to the string
built** — not merely that it contains a substring. Also assert no literal
`{% raw %}` / `{% endraw %}` survives. *Red:* remove the `Message` prepend →
Liquid renders `{{user_full_name}}` away → byte comparison fails. *Red 2:* apply
revision 1's `{% raw %}` wrap with a backtick in the body → `Liquid::SyntaxError`
is rescued and raw markers persist → both assertions fail.

**8.2 Cannot reach the customer.** `Facebook::SendOnFacebookService` and
`Instagram::Messenger::SendOnInstagramService` perform no HTTP and no
`perform_reply`. *Red:* flip `private` to false.

**8.3 Reporting untouched.** After the note: `waiting_since` unchanged,
`first_reply_created_at` nil, `ReportingEvent.count` unchanged, no
`REPLY_CREATED`/`FIRST_REPLY_CREATED`, conversation still matches Unattended.

*Red — three mutations, each run individually.* **Revision 2's mutations were
broken**: two of the three left `private: true`, and `update_waiting_since`
gates the entire outgoing branch on `!private` before `human_response?` is
consulted, so they would have come back green and the suite would have reported
two guards inert. Every mutation must flip `private: false` and vary the second
axis:

- (a) `private: false` + `User` sender, no `first_reply_created_at` → first-reply
  path stamps it and writes a `first_response` event
- (b) `private: false` + `User` sender with `first_reply_created_at` pre-set →
  `REPLY_CREATED` + a `reply_time` event, `waiting_since` nulled
- (c) `private: false` + `external_echo` in `content_attributes` → the echo
  branch of `human_response?`

**A mutation that leaves the assertions green means the test is not pinning
what it claims** — which is the finding revision 2 nearly shipped, not a
formality.

**8.4 Extraction.** Picks `text_format` on `media_type: 'text'`; **does not**
emit `"I'd like to learn more"` from the other blocks (*red:* scan recursively
for `quick_replies`); finds the key under `object_story_spec.video_data`
(*red:* read `creative['page_welcome_message']` → nil → `Unavailable`); returns
titles and responses in order; a `quick_replies` payload yields nil responses
and renders without an empty quote; absent/unparseable → `Unavailable`, not
`JSON::ParserError`.

**8.5 Graph call shape.** `get_object` receives `api_version: 'v25.0'` in the
third argument, **as a symbol key**. *Red 1:* omit it. *Red 2:* pass
`'api_version' => 'v25.0'` as a string — `Request` reads `raw_options[:api_version]`
and silently falls back to `Koala.config.api_version`, which nothing in this tree
sets, reproducing the (#2635) rejection at runtime while the test still looks
plausible. The stub is asserted to have been **invoked** (`have_received`), not
merely configured — the exact way a previous spec here passed vacuously.

The note in this spec must live on a `Channel::FacebookPage` inbox:
`validate_target_channel` raises on a class mismatch *before* the private check,
so a wrong-inbox fixture would pass for the wrong reason.

**8.6 Presenter trim.** Marks the tapped option by matching the tap message
against `title` (*red:* remove the match → note says nothing about which was
tapped); collapses identical responses to one (*red:* disable → three copies);
carries no ad name/id header; contains no backtick.

**8.7 Idempotency and the race.** Two runs → one note; a second tap → still one
note; the `::jsonb` cast query matches a persisted note (*red:* drop the cast →
`PG::UndefinedFunction`).

**Recovery after a failure note** — the bug revision 2 shipped: post a failure
note, then run the success path, and assert a real note is created. *Red:* use
revision 2's single `ad_id`-only guard → the success path returns silently and
the conversation is permanently stuck on the error note.

**The guard actually matches a persisted note.** Create a note, run the job
again, assert exactly one note exists. *Red:* evaluate the guard with
`content_attributes::jsonb -> 'umi_ad_context' IS NOT NULL` in SQL → matches
nothing (the column is double-encoded, §5.4) → a second note is created. This
must be a real persisted round-trip, not an in-memory object: the encoding only
bites after the column serialises.

**The race** cannot be pinned by two sequential runs — that passes by
construction and is a behaviour snapshot, not a regression test. Assert instead
that the guard-and-insert happen **inside `conversation.with_lock`** and that the
Graph call happens outside it (`have_received` ordering, or by asserting the
lock is held at insert time). *Red:* move the `create!` outside the lock.

**8.8 Job resilience.** `Unavailable` retries then posts one failure note;
a second failure posts no second note; blank token → error log + failure note,
not a Dead-set entry; no `meta_ad_id` → nothing. **Non-`Unavailable` exceptions
also produce a failure note** — raise `ActiveRecord::RecordNotFound` and a
presenter `NoMethodError` and assert both are caught by the terminal handler
(*red:* revert to the `retry_on`-block form → both escape to Sidekiq and the
conversation gets nothing). **The enqueue cannot break message handling:** stub
`perform_later` to raise, run patch 20's builder against a real referral
payload, assert the customer's message still persists.

**8.9 The prepend binds, and does not swallow patch 20.** Two assertions:

- `Umi::FbigAdAttribution.promote` routes through
  `Umi::Meta::AdContextNoteTrigger`. *Red:* change patch 20's call site to the
  unqualified `promote(...)` form → the private instance-method copy is called,
  the singleton prepend is bypassed, the trigger goes silent. This pins the
  `module_function` semantics a rebase could break invisibly.
- **A failure inside `super` still reaches patch 20's own reporting.** Make
  `conversation.update!` raise; assert `stage=referral_promote_failed` is logged
  and `ChatwootExceptionTracker` is called — *not* `stage=ad_context_enqueue_failed`.
  *Red:* move `super` inside the trigger's rescue (revision 2's form) → the
  attribution failure is mislabelled as a Redis problem and the tracker call is
  lost. §8.8's "customer's message survives" assertion cannot see this, because
  the message survives either way.

**8.10 Erasure.** `purge_for` deletes both the ok-note and the failure-note.
*Red:* remove the override → notes survive redaction. Also assert the in-flight
race: a job that read `ad_id` before the purge must not re-post after it — the
`create!` re-reads `meta_ad_id` inside the lock and finds it gone.

**8.11** `bundle exec rubocop` clean (lint gate, not a behaviour test).

---

## 9. Production verification

Gated on §0. Patch 20 must be deployed **including its migration** — per
`chatwoot-prod-deploy`, migrations do not run on boot; skipping it leaves the
whole chain silently inert.

1. **Settle the gate:** confirm at least one **Messenger** conversation captures
   `meta_ad_id`. Check the **database**, not the log — patch 20's
   `stage=referral_absent` line was gated on `conversation.previously_new_record?`,
   which is never true by the time promotion runs, so the patch emitted no line
   either way. Fixed in code on 2026-08-12, **not yet deployed**. Until that
   ships, treat `[UMI-FBIG]` grep as unreliable and inspect
   `Conversation.where("custom_attributes ? 'meta_ad_id'")` directly.
2. `umi:meta:ad_context_note[<id>]` on a test conversation. Confirm Thai, emoji
   and `{{user_full_name}}` intact, tapped option marked, one answer not three.
3. Confirm `waiting_since` unchanged, `first_reply_created_at` nil,
   `ReportingEvent` count unchanged, still in Unattended.
4. Confirm nothing delivered: no outbound message in Meta's inbox for the thread.
5. **Timing, n≥5, not n=1.** Record note-created-at minus tap-at across at least
   five real taps; compare against the 26s floor. A single sample cannot decide
   a timing property at ~1.4 conversations/day.
6. `AutomationRule.where(event_name: 'message_created')` still empty; when the
   automation port ships, every rule carries `message_type is incoming`.
7. `grep '\[UMI-FBIG\] stage=ad_context'` — one `ad_context_posted` per
   attributed conversation, no `ad_context_failed`.

---

## 10. UMI-PATCHES.md row

Revision 1 omitted this, violating fork golden rule 3.

**Remove-when — and it is an uncomfortable one.** Every upstream-shaped
candidate is weak: upstream will never render Meta ad context (it needs Ads API
access from a Page token, which Meta documents as impossible), and Meta echoing
its own automations is outside anyone's control (backlog B4, architectural).

The honest remove-when is: **"when the ad's `ice_breakers[].response` values are
made per-option and relevant, and Meta's replies are visible in Chatwoot."**
That is a configuration change UMI controls, not an upstream event.

Golden rule 3's test — "no remove-when → belongs upstream" — returns the wrong
verdict here. The correct reading is the inverse: this has no upstream-shaped
remove-when because **it is a code workaround for a Meta-side configuration
decision that has not been made**. Recorded plainly so the patch is re-examined
when that decision is taken, rather than accreting.

---

## 11. Alternatives rejected

| Option | Why not |
|---|---|
| Fetch inline in the builder | Slow Meta call delays the customer's message; a rescued DB error inside the transaction kills it at COMMIT. Patch 20 documents this; near-miss today. |
| Cache the creative | ~1.4 calls/day. Costs freshness, buys nothing. Arithmetic in §3 so it stays re-checkable. |
| Sidebar panel / custom attribute | Frontend work, new API surface, sits outside the thread the agent is reading. |
| Backfill Meta's real messages as outgoing | Rejected in `UMI-FBIG-OUTBOUND-HEAL-SPEC.md`: menu taps are button data, and writing outgoing messages hides struggling conversations from Unattended. This patch writes a *private* message for that reason. |
| A Business Manager / system-user token | A second credential to store, rotate and leak. The Page token already in the DB carries `ads_read`; the undocumented-access risk is handled by the visible failure path. |
| Fixed path to `page_welcome_message` | The documented path returns nil (§2.3). |
| `{% raw %}` wrapping | Broken two ways, both demonstrated (§2.6). |
| Follow indirection carriers now | No current ad uses one; unexercised code. Failure mode 6 surfaces it. |
| Inline the enqueue into patch 20 | Couples lifetimes; patch 20's removal would silently kill this patch *and* the erasure hook (§6.1). |
| A team briefing / pinned canned response instead | Genuinely considered — the content is a constant. Rejected because it requires the agent to remember and go look; the note is zero-effort at the point of need. **But if the trimmed note proves to add little, this is the cheaper answer and should win.** |

---

## 12. Open questions

1. **Erasure: delete the notes, or strip `content_attributes` and leave the
   text?** Spec deletes, because the ad copy is in `content`. Your call.
2. **Instagram: skip entirely, or post a trimmed note?** Meta's answer is
   already an outgoing message there (8/8), but the greeting and untapped
   options are not. Recommendation: post, minus the answer block.
3. **English labels vs `I18n.t`** (§4). Recommendation: keep plain strings,
   matching the rest of `umi/`.
4. **Failure-note wording** (§6) — occasionally the only sign Meta revoked ads
   access.
5. **The bigger one, parked by your decision but not closed:** the ad's
   `ice_breakers[].response` is a per-option answer field delivered in 1–5
   seconds, currently three identical generic strings — the same mechanism as
   the Feb/Mar cohort that ran 43% follow-up. Neither this spec nor the
   automation-port spec evaluated it. It is a config change with no code, and it
   would beat three Chatwoot `message_created` rules on latency and on the
   greeting-race failure mode. Whether a live ad's welcome message is editable
   cannot be tested from here without writing to an ad; Ads Manager answers it
   in a minute.
