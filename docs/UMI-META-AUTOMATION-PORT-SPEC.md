# Porting Meta Business Suite lead automations into Chatwoot (backlog D6)

Revision 3, 2026-08-12. Builds on `docs/UMI-META-BACKLOG.md` D6 — the Meta-side
inventory is taken as given and not re-derived. Everything else was measured
read-only against production on 2026-08-11/12.

**Revised from r1.** r1 answered the question D6 asked — how to express the two
time-based lead-stage automations — and ranked the work accordingly. A parallel
analysis of the live ad cohort, independently re-measured here, shows that
question was the wrong one to lead with. The five automations D6 inventories
are not equally valuable: the one that mattered is a **sixth** entry on that
list which the backlog recorded as `OFF` and passed over —
**`Questions and responses`**. r1's mechanism analysis is unchanged and
still correct; its *ranking* is reversed.

**Revised from r2.** The two automations r2 dropped as "conditions never
captured" — `Ordered leads` and `Responsive leads` — were read directly from
Business Suite on 2026-08-12 and are now known (§ *The Meta conditions, in
full*). Both are still dropped, but on **merits rather than ignorance**, and
`Responsive leads` needed real work to dismiss: it is a message-count condition,
so it does not hit the time-trigger blocker, and Meta's own funnel shows it
working. § *Why `Responsive leads` is dropped* carries the analysis and states
what porting it would cost. The same reading visually confirmed
`Questions and responses` **OFF** and all five lead automations **ON**.

**Headline decision.** The highest-value item in D6 is **restoring
question-matched auto-replies, in Chatwoot**, as three automation rules with no
code. The lead-stage timers are worth one configuration change each and are
**explicitly sequenced behind it**, because switching on 7-day auto-resolve
today would close the entire cohort under study before the fix can be measured.
Of the five automations D6 names, **one is ported, four are dropped.**

---

## Problem

D6 as posed is about lead hygiene: five Meta automations, two of them purely
time-based, versus one rule in Chatwoot. That framing survives, but it is not
where the money is.

### Problem 1 (dominant) — ad conversations get an answer, but not *the* answer

Measured on production, 2026-08-12. The product ads present a three-option
quick-reply menu; the tap arrives as an ordinary inbound text message. Exact
literals, verbatim, 29 of the 31 taps ever recorded:

| Tap | Meaning | Times tapped |
|---|---|---|
| `1. สนใจรับส่วนลด 10% สำหรับการสั่งซื้อครั้งแรก` | wants the 10 % first-order discount | 10 |
| `2. ขอแนะนำสินค้าสำหรับวันแม่` | asks for **Mother's Day** recommendations | 7 |
| `3. ขอแนะนำสินค้าขายดีของ UMI` | asks for **best-sellers** | 12 |

30 of 31 taps landed in 2026-08. Agents answer these **faster** than anything
else — and the conversation dies anyway:

| | Tap cohort | Other live FB/IG |
|---|---|---|
| Conversations | 21 | 86 |
| Got an agent reply | 20 (95 %) | 55 (64 %) |
| Median time to first reply | **1.1 min** | 17.9 min |
| **Customer replied after the agent's reply** | **4 / 20 = 20 %** | **44 / 55 = 80 %** |

Two-sided Fisher exact **p ≈ 3.3 × 10⁻⁶**. 14 of the 21 tap conversations
contain **exactly one** inbound message ever — the tap, then silence.

Cohort definitions, stated so the numbers can be reproduced: "21" is
conversations containing an exact match on one of the three tap literals, all
time. The reply/follow-up columns are computed on live inbox-2 conversations
(no imported message) whose first inbound message matches `^[0-9]\.`, which is
22 conversations — one more than the literal match, because one thread's tap
carries a different creative's wording. The one-conversation difference does
not move any conclusion.

Broken down by which question was tapped, the mechanism is visible:

| Tap | n | replied | followed up | got WELCOME10 | got best-sellers block |
|---|---|---|---|---|---|
| 1 — 10 % discount | 10 | 9 | **0** | 8 | 0 |
| 2 — Mother's Day | 5 | 5 | 1 | 3 | 2 |
| 3 — best-sellers | 9 | 8 | 3 | 7 | 6 |

- **The 10 % discount tap has never once produced a follow-up.** It gets the
  coupon and the conversation ends. Across all time, `WELCOME10` was sent in
  **21 conversations and 6 got any reply afterwards (29 %)**.
- **The Mother's Day question is never answered.** There is no Mother's Day
  block. Of 5 such taps, 2 got the *best-sellers* block and 3 got the coupon.
  The repeated-outgoing-body census confirms it: the two blocks in circulation
  are best-sellers (7 sends) and the coupon (7 sends). No third block exists.

So reply *rate* and reply *speed* are not the problem. **Answer relevance is.**
This matches the historical comparison supplied by the parallel analysis: the
Feb/Mar 2026 cohort, handled by Meta's `Questions and responses` automation
which answered the specific option tapped in 0–3 s, ran at 43 % follow-up; the
June recruitment cohort, also templated but topic-matched, ran at 37 %. That
automation is **OFF** — confirmed visually in Business Suite on 2026-08-12, on
the same screen that shows all five lead automations ON. The one correlated
with 43 % follow-up is the one switched off; the five still running are lead
bookkeeping. The lesson is not "canned replies are bad" — it is **canned
replies that do not answer the thing the person tapped**.

The Chatwoot greeting, enabled 2026-08-10 under backlog D1, makes it worse
rather than better. Its text ends
`ระหว่างนี้ คุณกำลังสนใจสินค้ารุ่นไหนอยู่คะ?` — *"which product model are you
interested in?"* — asked of someone who clicked a video ad and tapped a menu
precisely because they cannot name a product. It has fired twice so far
(2026-08-10, 2026-08-11), so the damage is not yet done, but it is now the
default first thing every FB/IG customer reads.

### Problem 2 (secondary) — nothing drives the lead labels

27 labels exist; **only two carry any taggings**: `lead-new` 44 (from the single
existing rule) and `spam` 20. `lead-qualified`, `lead-lost` and
`lead-converted` are inert. All 21 tap conversations carry `lead-new` and
nothing else.

The mechanical blocker recorded in D6 is real and is in fact **worse** than
recorded — it is not only the *trigger* that is missing, it is the *condition*:

```ruby
# app/models/automation_rule.rb:37-40
def conditions_attributes
  %w[content email country_code status message_type browser_language assignee_id team_id referer city company_name inbox_id
     mail_subject phone_number priority conversation_language labels private_note]
end
```

`created_at` and `last_activity_at` exist in `lib/filters/filter_keys.yml`
(they work in conversation *search*) but are absent from that list, so
`json_conditions_format` (`app/models/automation_rule.rb:65-72`) rejects any
rule that conditions on elapsed time. Combined with the five events
`AutomationRuleListener` handles (`app/listeners/automation_rule_listener.rb:2-35`),
a stock rule cannot express "quiet for N days" from either end.

---

## Production baseline (read-only, 2026-08-11/12)

Account 1 "UMI", Chatwoot 4.16.0, `enterprise` codebase on the `community`
pricing plan.

### Automation surface

| Thing | Count |
|---|---|
| Automation rules | **1** — `Auto: tag new conversations as New Lead`, `conversation_created`, `status == open` → `add_label lead-new`, created 2026-08-01 |
| Canned responses | **0** |
| Agent bots | **0**; inbox 2 has no `agent_bot` |
| Macros | 1 (`📞 Call contact`, a webhook to the UMI voice dialer) |
| SLA policies / applied SLAs | **0 / 0** |
| Teams | **0** |
| Users | 6 (4 agents, 2 administrators) |
| Private notes, all time, all inboxes | **7** |

### The FB/IG inbox splits into imported history and live traffic

Inbox 2 (`Channel::FacebookPage`, carries both platforms) holds 789
conversations. 681 contain at least one message stamped
`additional_attributes.umi_history_import` — the migration recorded in
`docs/UMI-FBIG-HISTORY-MIGRATION-RECORD.md`. **Every population statistic must
be computed on the 108 that do not**, or the answer describes 2025.

| Live inbox-2 conversations (no imported message) | |
|---|---|
| Total | 108 (98 open, 10 resolved) |
| Platform | 77 Instagram, 31 Messenger |
| Created in the last 30 days | 65 |
| Got a first reply | 75 (69 %) |
| …replied **from Chatwoot** (`sender_type: 'User'`) | **31** |
| …replied **from Meta Business Suite** (`external_echo`) | **56** |
| Open and silent ≥ 7 days | 58 of 98 |
| In the Unattended folder | 43 |

### Open-conversation inactivity, all inboxes

146 open. `<12h` 5 · `12–24h` 3 · `1–3d` 11 · `3–7d` 32 · `7–30d` 60 ·
`30–90d` 35 · `>90d` **0**. **95 open conversations have been silent more than
7 days**, 58 on FB/IG.

The tap cohort sits just under that line: inactivity **min 0.1 d, median 4.3 d,
max 6.9 d**, created 2026-07-24 → 2026-08-10. **Zero would auto-resolve at a
7-day threshold today; all 21 would within the next week.** This is the
sequencing constraint that drives Decision 2.

### Ad attribution: patch 20 is written but **is not running in production**

| Check | Result |
|---|---|
| `config/initializers/zz_umi_fbig_ad_attribution.rb` in the running image | **false** |
| `umi/app/builders/fbig_ad_attribution.rb` | **false** |
| Newest applied migration | `20260806000000` — patch 20 adds `20260811000000` |
| `CustomAttributeDefinition` rows for `conversation_attribute` | **`[]`** |
| Messages carrying `referral`; conversations carrying `meta_ad_id` | **0 / 0** |

Commit `505d3c65c` is in git; the image on the VPS predates it. Migrations do
not run on boot.

### The historical `"replied to an ad."` marker is a dead end

60 conversations carry it. **All resolved, all Messenger, none created in the
last 30 days, none ever answered by an agent.** All are inside the imported
history — the live webhook never produces it, because Meta does not echo its
own system lines (backlog B4). **Do not build any rule on it.** The `referral`
object is the only forward route, and identifying the ad cohort today requires
the tap literals above.

---

## The Meta conditions, in full

Read directly from Business Suite on 2026-08-12. `Lead reminder`,
`Lost leads`, `Booked leads`, `Ordered leads` and `Responsive leads` are all
**ON** (Messenger + Instagram); `Questions and responses` and `Away message`
are **OFF**. The last two were captured on this pass:

**`Leads – Ordered leads`** — *"Automatically move leads to the Converted stage
and add a label when an order has been placed."* Trigger: *"UMI clothing
creates an order, updates the status of an order **or receives messages about
placing an order**. This applies to leads in Intake, Qualified or any of your
custom stages."* Action: set stage **Converted** + add a Converted label.

**`Leads – Responsive leads`** — *"Automatically move leads to the Qualified
stage and add a label when five messages are exchanged."* Trigger: *"UMI
clothing **exchanges 5 messages** with a lead in the Intake stage."* Action:
set stage **Qualified** + add a Qualified label.

### The Leads Centre funnel now explains itself, and the explanation checks out

Intake **30** → Qualified **12** → Converted **0**.

- **Qualified is `Responsive leads` firing.** It is a pure message-count rule,
  so nothing about UMI's setup can break it. Meta's own conversion is
  12 / 30 = **40 %**. Measured independently here: **42 of 108 live FB/IG
  conversations (38.9 %) reach ≥5 non-private messages**, 39 of them with at
  least two each way. Two populations, two methods, 40 % vs 39 %. That is a
  strong corroboration that the rule works exactly as described and that the
  Qualified stage is a restatement of "this thread got to five messages".
- **Converted is `Ordered leads` producing nothing.** Not, as r2 said, because
  it is purely order-driven — the trigger has a **message-content branch**
  ("receives messages about placing an order") that does not need an order
  object at all. It still produced zero. And the raw signal is present in the
  data: **12 live conversations contain an inbound message using สั่ง /
  สั่งซื้อ** (to order / to purchase) and 6 contain "order". So both branches
  failed: the order branch because orders happen in Shopify, and the message
  branch for reasons not visible from here — plausibly no Thai coverage in
  Meta's intent detection, or a requirement that it corroborate against a
  Leads Centre order object. **Either way, measured output is 0.**

This matters for the port: it means "an order was placed" is *not* purely a
Shopify-join problem. There is a detectable in-conversation signal at
~11 % of live conversations. It is out of scope here — a `content contains
สั่งซื้อ` rule would label intent-to-order, not a completed order, and D8/D15
established there is no way to confirm the second — but it is a better starting
point than the backlog's "no signal exists" framing, and it belongs in whatever
picks up `lead-converted`.

---

## Decision 1 — question-matched auto-replies, in Chatwoot (highest value)

**Three `message_created` automation rules, one per tap. No code, no deploy.**

### The mechanism works, end to end

| Requirement | Where it is satisfied |
|---|---|
| Fires on an inbound message | `AutomationRuleListener#message_created` (`app/listeners/automation_rule_listener.rb:18-35`) |
| Can match the tap text | `content` supports `contains` / `equal_to` (`lib/filters/filter_keys.yml`, `messages`); compiled to `LOWER(messages.processed_message_content) LIKE :value` (`app/services/automation_rules/conditions_filter_service.rb:111-131`, `app/services/filter_service.rb:79-83,175-179`) |
| Can restrict to inbound only | `message_type equal_to` (same file); `message_type` is in `conditions_attributes` |
| Applies to the triggering message only | `base_relation` adds `where(messages: { id: @options[:message].id })` (`app/services/automation_rules/conditions_filter_service.rb:203`) |
| Can send the answer | `send_message` action (`app/services/automation_rules/action_service.rb:43-48`) |
| The answer actually reaches Meta | `Base::SendOnChannelService#invalid_message?` blocks only private notes and messages that *came from* the channel (`message.source_id.present?`). An automation message has no `source_id`, so it is delivered. |
| Cannot loop | The generated message carries `content_attributes.automation_rule_id` and dispatches with `performed_by: Current.executed_by`; `ignore_message_created_event?` drops it (`app/listeners/automation_rule_listener.rb:82-85`, `app/services/automation_rules/action_service.rb:6`) |
| Can label at the same time | `add_label` in the same rule's action list |

**The load-bearing property: an automation reply does not mark the conversation
attended.** `human_response?` requires `content_attributes['automation_rule_id']`
to be blank (`app/models/message.rb:362-371`), so `valid_first_reply?` is false,
`first_reply_created_at` stays `nil` and `waiting_since` is not cleared
(`app/models/message.rb:224-229,383`). The conversation therefore **stays in
the Unattended folder** (`scope :unattended`, `app/models/conversation.rb:92`).
The auto-answer buys the customer a real answer in seconds without telling the
team the conversation is handled. This is the opposite of the failure that
killed backlog B3, and it is why this belongs in Chatwoot rather than in Meta.

### The three rules

Each: event `message_created`; conditions `message_type equal_to incoming`
**AND** `content contains <distinctive substring of the tap>`; actions
`send_message <answer>` **AND** `add_label <intent label>`.

| # | Match on | Reply | Label |
|---|---|---|---|
| A | `ขอแนะนำสินค้าขายดีของ UMI` | the existing best-sellers block (already in use, 7 sends): `แนะนำรุ่นขายดีของ UMI ค่ะ 🤍 1. Tank dress Fluent (สีดำ) — ฿4,690 …` | `intent-product-details` |
| B | `ขอแนะนำสินค้าสำหรับวันแม่` | **does not exist — must be written.** A Mother's-Day shortlist in the same shape as A: 2–3 named products with prices and links. | `intent-product-details` |
| C | `สนใจรับส่วนลด 10%` | the existing coupon block **plus a question that can be answered without naming a product** — the current block ends at the code and produces 0/9 follow-ups. | `intent-interested` |

Match on the distinctive tail, not the leading `1.` / `2.` / `3.` — the numbers
are menu positions and will change when the creative changes, whereas the Thai
phrase is the question. Match on a substring rather than the whole literal:
`processed_message_content` is a derived column
(`ensure_processed_message_content`, `app/models/message.rb:300`), so exact
equality on the raw text is a needless dependency.

### Why Chatwoot rather than switching Meta's `Questions and responses` back on

Restoring Meta's automation is one toggle and would be live today, and its
historical performance (43 % follow-up) is the best evidence any option has.
Rejected anyway, for one decisive reason and two supporting ones:

1. **Agents cannot see what the customer was told.** Meta never echoes its own
   automations into Chatwoot — established empirically at 17 → 0 (backlog B4).
   That invisibility *is* backlog D7: the agent sees a bare `3. …` with no
   menu and no auto-answer, and cannot reply coherently. Restoring Meta's
   automation restores the engagement and re-creates the blindness at the same
   time.
2. It cannot label, cannot be reported on, and cannot be edited by anyone
   without Business Suite access.
3. Three auto-responders would now be in play — Meta's, the Chatwoot greeting,
   and any Chatwoot rule. Backlog A6 records that duplicate Meta-side
   sequences were already reaching customers 6× in 3 seconds. **Do not run two.**

The Chatwoot version costs an hour of configuration and no deploy, so the
stopgap argument does not carry. If it somehow cannot be done this week,
restoring Meta's is the correct interim — with the D7 blindness accepted
explicitly, and the Chatwoot greeting switched off first.

### Prerequisite: fix or disable the greeting on inbox 2

`MessageTemplates::HookExecutionService` runs synchronously from the message's
callback chain (`app/models/message.rb:440-442`), while the automation listener
runs asynchronously via `EventDispatcherJob`
(`app/dispatchers/async_dispatcher.rb:1-3,13`). So on a tap the customer will
normally receive the greeting first — *"which product model are you interested
in?"* — and the actual answer a few seconds later. That reads as a bot that
asked a question and then ignored the reply.

Worse, the ordering is not guaranteed in either direction:
`should_send_greeting?` gates on
`conversation.messages.outgoing.count.zero? && conversation.messages.template.count.zero?`
(`app/services/message_templates/hook_execution_service.rb:35-45`), so if the
automation message lands first the greeting is suppressed instead. Two
different customer experiences from the same input.

Either **disable `greeting_enabled` on inbox 2**, or **rewrite the greeting so
it does not ask a question** (an acknowledgement is fine; "which model are you
interested in?" is the exact bounce-back this whole decision is about). Do this
**before** the rules go live.

### Coverage limit, stated plainly

These rules match tap literals, so they cover the ad menu and nothing else. 30
of 31 taps are one of three strings, so coverage of *this* creative is
effectively total — but **a new ad with new menu options silently matches
nothing**, and the failure is invisible. That is an operational commitment:
whoever changes the ad creative must add the matching rule. Once patch 20 is
deployed, `meta_ad_id` gives a way to detect the gap (ad-originated
conversations with no `intent-*` label), which is a further reason to ship it.

---

## Decision 2 — the time-based trigger mechanism

**Chosen: stock `Account#auto_resolve_after` + `auto_resolve_label`, driven by
the existing every-5-minutes cron. Zero code. Sequenced *after* Decision 1 and
gated on its measurement window.**

D6 posed this as SLA-policies vs a UMI scheduled job. Both lose to a third
option already running in the deployed code:

```ruby
# app/jobs/conversations/resolution_job.rb:5-13
resolvable_conversations = conversation_scope(account).limit(Limits::BULK_ACTIONS_LIMIT)
resolvable_conversations.each do |conversation|
  ::MessageTemplates::Template::AutoResolve.new(conversation: conversation).perform if account.auto_resolve_message.present?
  conversation.add_labels(account.auto_resolve_label) if account.auto_resolve_label.present?
  conversation.toggle_status
end
```

- The scope is exactly the Meta condition:
  `open.where('last_activity_at < ?', Time.now.utc - auto_resolve_after.minutes)`
  (`app/models/conversation.rb:98-102`), with an `auto_resolve_ignore_waiting`
  variant that skips conversations where the customer is still waiting (`:93-97`).
- Enqueued from `Account::ConversationsResolutionSchedulerJob`, called by
  `TriggerScheduledItemsJob` (`app/jobs/trigger_scheduled_items_job.rb:18`),
  which runs `*/5 * * * *` (`config/schedule.yml`). Confirmed live in Redis.
- Gated on `Account.with_auto_resolve` (`app/models/account.rb:109`).
  Production has `settings == {}`, so it currently does nothing.
- Configurable from the dashboard, no deploy
  (`.../settings/account/components/AutoResolve.vue:52-62,105`; permitted at
  `app/controllers/api/v1/accounts_controller.rb:128`; schema bounds
  10 – 1,439,856 minutes at `app/models/concerns/account_settings_schema.rb:11-15`).
- Resolving dispatches `CONVERSATION_RESOLVED` (`notify_status_change`,
  `app/models/conversation.rb:353-362`) with `performed_by: Current.executed_by`,
  which is `nil` here — so the listener does not short-circuit on
  `performed_by_automation?` (`app/listeners/automation_rule_listener.rb:40,73-75`)
  and a `conversation_resolved` rule gets its turn.

### Why it must not go first

At a 7-day threshold this would resolve **all 21 tap conversations within the
next week** (their inactivity today is 0.1 – 6.9 days). That closes the exact
population whose engagement Decision 1 is trying to fix, before there is a
baseline to compare against. Ship Decision 1, hold a measurement window, then
turn this on.

### Alternative rejected: SLA policies

Disqualified on **three independent grounds**, any one fatal.

1. **Not licensed, not enabled.** `sla` is premium
   (`config/features.yml:130-134`, `enterprise/config/premium_features.yml:4`).
   Production reports `INSTALLATION_PRICING_PLAN == "community"`, quantity 0,
   `account.feature_enabled?('sla') == false`.
2. **It cannot express the requirement even if enabled.** `SlaPolicy` has three
   knobs — `first_response_time_threshold`, `next_response_time_threshold`,
   `resolution_time_threshold` (`enterprise/app/models/sla_policy.rb`). None
   means "N days of silence". The nearest, `nrt`, is computed from
   `conversation.waiting_since` (`enterprise/app/models/applied_sla.rb:88-96`),
   and `waiting_since` is nulled the instant anyone replies
   (`app/models/message.rb:349,383`) — it measures *agent lateness*, not *lead
   death*. A lead that went cold after the agent's last message has
   `waiting_since IS NULL` and is invisible to `nrt`.
3. **SLA performs no actions.** `Sla::EvaluateAppliedSlaService` writes
   `SlaEvent` rows and flips `applied_sla.sla_status`
   (`enterprise/app/services/sla/evaluate_applied_sla_service.rb:56-73,83-92`).
   No label, no note, no status change. The `lead-lost` label would still need
   a second mechanism — so SLA is not an alternative to anything, it is an
   extra dependency in front of one.

Its only downstream effect is an agent notification
(`app/models/notification.rb:44-46`). At a 1.1-minute median first reply on the
cohort that matters, that notification would fire on nothing.

### Alternative rejected: a UMI scheduled job shaped like the profile refresher

The pattern works and is in production —
`umi/app/jobs/fbig/profile_refresh_job.rb` plus the per-job
`Sidekiq::Cron::Job.new/destroy` registration in
`config/initializers/zz_umi_fbig_profile_refresh.rb:26-50` (never
`load_from_hash!`, whose purge filter is hardcoded to source `"schedule"` and
would wipe the core schedule). Registered live as
`umi_fbig_profile_refresh(15 21 * * *)`.

Rejected: it would reimplement `Conversations::ResolutionJob` with a worse
operational profile — a new patch row, kill switch, cron entry and failure
surface, on an install where `SENTRY_DSN` is empty and an exception is a bare
log line. **Reserve it** for the one thing stock cannot do: acting on
conversations *without* resolving them (see "What would change these decisions").

### Alternative rejected: snooze-as-a-timer

`snooze_conversation` is an available action and
`Conversations::ReopenSnoozedConversationsJob` reopens snoozed conversations
every 5 minutes, which would give a delayed `conversation_opened`. It does not
work: the action is `def snooze_conversation(_params) = @conversation.snoozed!`
(`app/services/action_service.rb:13-15`) — it takes no wake time and never sets
`snoozed_until`, and the reopen job selects only
`where(snoozed_until: 3.days.ago..Time.current)`
(`app/jobs/conversations/reopen_snoozed_conversations_job.rb:5`). An
automation-snoozed conversation never wakes, and a 7-day delay is outside the
window regardless.

---

## Decision 3 — what is worth porting

**Port 1 of the 5 inventoried. Drop 4. Add the one that was passed over.**

| Meta automation | Verdict | Reason |
|---|---|---|
| **`Questions and responses`** (recorded **OFF**, not in D6's five) | **PORT — first** | The 60-point engagement gap. Decision 1. |
| `Leads – Lost leads` (7 d silent → *Lost*) | **PORT — second, gated** | Real signal, 58 live FB/IG conversations qualify, zero code. But it closes the Decision 1 cohort, so it waits. |
| `Lead reminder` (12 h silent → note + mark unread) | **DROP** | See below. |
| `Leads – Booked leads` | **DROP** | Can never fire. |
| `Leads – Ordered leads` | **DROP** | Both trigger branches measured at zero output. |
| `Leads – Responsive leads` | **DROP** | Works on Meta, but Chatwoot cannot express it without a patch, and what it produces restates a visible fact. |

### Why `Lead reminder` is dropped

1. **The problem it solves does not exist here, and on the cohort that matters
   it is inverted.** Median time to first reply is **1.1 minutes** on the tap
   cohort and 17.9 minutes elsewhere; 6 of 75 live conversations ever crossed
   12 h. The customers are not waiting on agents — the agents are waiting on
   customers who never come back.
2. **Chatwoot already ships the surface, live and better.** The Unattended
   folder (`app/models/conversation.rb:92`, sidebar item at
   `app/javascript/dashboard/components-next/sidebar/Sidebar.vue:401-407`,
   `app/finders/conversation_finder.rb:146-147`) shows exactly "customer is
   waiting and nobody has answered" — 43 live FB/IG conversations right now,
   with no latency. A private note written 12 h later is worse information,
   later. Decision 1 is specifically built to keep conversations *in* that
   folder.
3. **It would be pure noise.** 87 open conversations are ≥12 h silent with an
   agent reply already on file. Writing 87 private notes into an account with
   **7 private notes in its entire history** trains agents to ignore them.

The "mark unread" half has no Chatwoot action at all
(`app/models/automation_rule.rb:42-47`), so a faithful port was never possible.

### Why `Booked` / `Ordered` are dropped

`Booked leads` triggers on a booking or an order marked Booked inside Meta.
UMI sells through Shopify with `OFFSITE_LINK` website checkout, so that object
never exists. Not re-litigated.

`Ordered leads` needs the correction r2 got wrong. Its trigger is *"creates an
order, updates the status of an order **or receives messages about placing an
order**"* — so it is **not purely order-driven**; there is a message-content
branch that needs no order object. It nevertheless produced **Converted 0**,
and the inputs for the message branch are demonstrably present: 12 live
conversations carry an inbound สั่ง / สั่งซื้อ and 6 carry "order". So the
honest statement is not "it cannot fire" but **"both of its branches were live
and both produced nothing"** — the order branch because orders happen in
Shopify, the message branch for a reason not visible from here.

Porting it means deciding what "an order was placed" means in Chatwoot terms,
and the only definition that is actually true requires the order↔conversation
join D8/D15 measured at **0 of 29 web orders** matched, with **795
Shopify-linked contacts entirely disjoint** from Meta DM contacts. A
`content contains สั่งซื้อ` rule is cheap and would fire on ~11 % of live
conversations, but it labels *intent to order*, not a completed one — and
labelling that `lead-converted` would put a false number in the one place the
business is trying to get an honest number. Out of scope; noted above for
whoever picks up `lead-converted`.

### Why `Responsive leads` is dropped

This is the one that needed real work to dismiss. It is **not** blocked by the
time-trigger problem — "5 messages exchanged" is a count, and it could ride
`message_created`. And it demonstrably works: it is what produces Meta's
Qualified 12, and my independent count puts the same threshold at 39 % of live
FB/IG conversations against Meta's 40 %.

Dropped on four grounds:

1. **Chatwoot cannot express a message count at all.** It is absent from
   `conditions_attributes` (`app/models/automation_rule.rb:37-40`), absent from
   every model in `lib/filters/filter_keys.yml` (conversations, contacts and
   messages all lack it), and there is **no counter-cache column** — the
   `conversations` table in `db/schema.rb` has no `messages_count`. There is
   nothing to condition on.
2. **The label-as-counter workaround does not work**, and the way it fails is
   worth recording because it is invisible. Chaining rules ("has `msg-4`, not
   `msg-5` → add `msg-5`") needs "does not have label X", and `labels
   not_equal_to` compiles to `tags.name != :value`
   (`app/services/automation_rules/conditions_filter_service.rb:170-176`) over
   the LEFT OUTER JOIN in `base_relation` (`:187-201`), which yields **one row
   per label**. A conversation labelled `[lead-new, msg-5]` still produces a
   `lead-new` row, and `'lead-new' != 'msg-5'` is true — so the condition
   passes whether or not `msg-5` is present. The operator means "has at least
   one label that isn't X", never "does not have X". And a conversation with no
   labels yields a single row with `tags.name` NULL, where `NULL != 'X'` is
   NULL, so it fails too. **`labels not_equal_to` is unusable for absence
   checks** — here and in any other rule.
3. **What it produces restates a visible fact.** `lead-qualified` would mean
   "this thread reached five messages" — which an agent can see from the
   thread, the conversation list, and the sort order. Meta needed the label
   because Leads Centre has a stage model; Chatwoot does not. It adds a filter,
   not a judgement, and Decision 4 already declines to automate *Qualified* for
   exactly this reason.
4. **It fires on the wrong cohort.** Only **2 of 21 tap conversations (9.5 %)**
   reach five messages, against **40 of 87 (46 %)** of everything else. It
   would silently skip the ad traffic Decision 1 exists to fix and busily label
   the organic conversations that were already healthy.

**What porting it would take, if the judgement is later reversed.** The cheapest
expressible route is *not* extending the automation condition set — it is a UMI
`message_created` hook that increments a numeric conversation custom attribute
(`message_count`), plus a stock `conversation_updated` rule
`message_count equal_to 5` → `add_label lead-qualified`. Conversation custom
attributes are valid automation conditions (Decision 5 establishes this), and
`equal_to` is the right operator anyway: the automation UI offers only
`equal_to` / `not_equal_to` for a `number` attribute
(`getOperatorTypes` maps `number → OPERATOR_TYPES_1`,
`app/javascript/dashboard/helper/automationHelper.js:62-73`,
`.../automation/operators.js:1-10`), and on a monotonic counter equality at 5
fires exactly once. The backend does support `is_greater_than`
(`app/services/filter_service.rb:85-98`), reachable via the API but not the
dashboard. Cost: a service, a migration seeding the definition, a patch row and
a remove-when. **Not worth it for a label that restates the message count.**

---

## Decision 4 — what drives the labels

| Label | Driver | Status |
|---|---|---|
| `lead-new` | Existing rule 1 | Live, 44 taggings |
| `intent-product-details`, `intent-interested` | Decision 1's three rules, alongside the reply | **New. Config only.** |
| `lead-lost` | `auto_resolve_label: 'auto-resolved'` + one `conversation_resolved` rule ANDing `labels == auto-resolved` and `inbox_id == 2` | **New. Config only, gated behind Decision 1.** |
| `source-paid-ads` | `conversation_updated` rule, `meta_ad_id is_present` | **New. Blocked on deploying patch 20.** |
| `source-recruitment` (new label) | `conversation_updated` rule, `meta_ad_ref equal_to hiring` | **New. Blocked on Meta-side `ref` config.** |
| `lead-qualified` | **Nothing. Macro / manual.** | Deliberately not automated |
| `lead-converted` | **Nothing.** | Deliberately not automated |

### `lead-lost` — the two-step, and why not the one-step

The obvious one-step is `auto_resolve_label: 'lead-lost'`. Rejected:
`auto_resolve_after` is **account-wide**, one threshold and one label for every
inbox. At 7 days it would stamp `lead-lost` on 95 conversations, of which only
58 are FB/IG — the other 37 are website, email, WhatsApp, LINE and voice
threads where "lost lead" is simply false.

The two-step keeps both halves honest:

1. **Account setting** applies a *provenance* label. `auto_resolve_label` is
   only ever applied by `Conversations::ResolutionJob`; an agent resolving by
   hand never gets it. So `auto-resolved` means exactly "closed by the machine
   for silence", truthfully, account-wide.
2. **One `conversation_resolved` rule** turns provenance into meaning:
   `labels equal_to auto-resolved` AND `inbox_id equal_to 2` →
   `add_label lead-lost`.

Both keys are supported (`app/models/automation_rule.rb:37-40`,
`lib/filters/filter_keys.yml`; label branch at
`app/services/automation_rules/conditions_filter_service.rb:162-183`). Ordering
is safe — `add_labels` runs **before** `toggle_status`, so the label is
committed before `CONVERSATION_RESOLVED` dispatches. No loop:
`AutomationRules::ActionService` sets `Current.executed_by = rule`
(`app/services/automation_rules/action_service.rb:6`), which arrives as
`performed_by` on the follow-on `conversation_updated` and short-circuits the
listener. Caveat: `labels equal_to` reads only `values.first` — one label per
condition. Fine here.

### `lead-qualified` and `lead-converted` — deliberately manual

*Qualified* is a human judgement about intent to buy. Meta does have a proxy for
it — `Responsive leads`' five-message threshold — and it is worth being explicit
that this spec **declines that proxy on purpose**, not for want of one. A label
meaning "this thread reached five messages" is a restatement of something an
agent can already see, it fires on 9.5 % of the ad cohort against 46 % of
everything else, and Chatwoot cannot express it without a patch anyway
(Decision 3). Inventing a proxy produces a label nobody trusts — the failure the
other 25 unused labels already demonstrate. Use a **macro**; the account already
has one working macro, so the surface is proven.

*Converted* needs the order↔conversation join, which does not exist. Note that
Meta's `Ordered leads` also has an in-conversation branch and it produced
nothing; a Thai keyword rule would capture *intent* to order, which is not the
same label.

---

## Decision 5 — `source-paid-ads`

**Yes, but gated on a deploy, and there is a design trap in it.**

### The trap: `conversation_created` will not work

`Umi::FbigAdAttribution::Builder#perform` promotes the three conversation
custom attributes **after** `super` returns — after the transaction that
created the conversation committed. The reason is sound and documented in the
patch: a rescued DB error inside that transaction would leave it aborted and
kill the customer's message at COMMIT.

But `CONVERSATION_CREATED` dispatches from the create-commit
(`after_create_commit :notify_conversation_creation`,
`app/models/conversation.rb:133,303-305`) and `AutomationRuleListener` is on
the **async** dispatcher (`app/dispatchers/async_dispatcher.rb:13`) — an
`EventDispatcherJob` in Sidekiq. A `conversation_created` rule keyed on
`meta_ad_id` races the write and will intermittently see nothing. It would pass
every manual test and silently under-label in production.

**The reliable hook is `conversation_updated`.** `promote` performs
`conversation.update!(custom_attributes: …)`, and `custom_attributes` is in
`Conversation#list_of_keys` (`app/models/conversation.rb:319-322`), so
`notify_conversation_updation` (`:313-317`) dispatches `CONVERSATION_UPDATED`.

### Conversation custom attributes are usable as conditions — with a prerequisite

- `json_conditions_format` accepts any key in
  `account.custom_attribute_definitions`, regardless of model
  (`app/models/automation_rule.rb:70`).
- `build_custom_attr_query` picks the right table:
  `table_name = attribute_model == 'conversation_attribute' ? 'conversations' : 'contacts'`
  (`app/services/filters/custom_attribute_filter_helper.rb:25`).
- The UI groups them under `conversation_custom_attribute`
  (`app/javascript/dashboard/helper/automationHelper.js:225-233`) and stamps
  `custom_attribute_type` on save
  (`.../settings/automation/AutomationRuleForm.vue:207-217`).

The prerequisite is the `CustomAttributeDefinition` rows. Production has
**none**, so today the rule is unsavable. Patch 20's migration creates them.

### Recruitment vs product traffic

The backlog's caveat is right that click-to-Messenger carries both, and a
hiring campaign launches around now. But the conclusion drawn from it was
wrong: `source-paid-ads` describes the *source*, and a recruitment
click-to-Messenger ad **is** paid ads. What is untruthful on job applicants is
`lead-new`, which the *existing* rule already applies to everything.

So split it:

- **`source-paid-ads`** — blanket, `meta_ad_id is_present`. Correct as stated.
- **`source-recruitment`** — `meta_ad_ref equal_to hiring`, with a second
  action `remove_label lead-new` (`app/services/action_service.rb:55-60`).

`ref` is an arbitrary per-ad string set in Ads Manager, promoted to
`meta_ad_ref` by patch 20. **This makes the recruitment split a Meta-side
configuration deliverable with a hard deadline**: `referral` arrives only on the
*first* message of a thread, so any hiring conversation that starts before
`ref=hiring` is set is unrecoverable. Nothing in Chatwoot can fix it afterwards.

Note the recruitment population does not have the Decision 1 problem — the June
recruitment cohort ran 37 % follow-up on templated replies, and its templates
(4 distinct application-form blocks, 12–21 sends each) already answer the
question being asked.

### Unverified: does Facebook deliver `referral` at all?

Patch 20's registry row records Instagram verified, **Facebook unverified**;
backlog A3 records that the page subscribes to 6 fields and
`messaging_referrals` is not one of them, and that
`Channel::FacebookPage#subscribe` runs `after_create_commit` only. Live traffic
is 77 Instagram / 31 Messenger, so if Facebook is silent these rules cover
~71 % of conversations. **Not answerable from the database** — must be
confirmed from the first live `stage=referral_promoted` log line after deploy.

---

## Data flow

```
Customer taps "3. ขอแนะนำสินค้าขายดีของ UMI"
        │
        ▼  inbound message persisted
        ├─ [sync, message callback] MessageTemplates::HookExecutionService
        │      └─ greeting — MUST be disabled or rewritten first, it asks
        │         "which model are you interested in?"
        │
        ▼  MESSAGE_CREATED → async EventDispatcherJob
AutomationRuleListener#message_created
        │   message_type == incoming AND content contains "ขอแนะนำสินค้าขายดีของ UMI"
        ▼
ActionService
        ├─ send_message(<best-sellers block>)   → Messages::MessageBuilder
        │        └─ no source_id ⇒ Base::SendOnChannelService delivers to Meta
        │        └─ content_attributes.automation_rule_id set
        │             ⇒ human_response? false
        │             ⇒ first_reply_created_at stays nil, waiting_since kept
        │             ⇒ conversation REMAINS in Unattended
        └─ add_label('intent-product-details')
```

```
Customer stops replying
        ▼   last_activity_at ages past auto_resolve_after
every 5 min: TriggerScheduledItemsJob → Account::ConversationsResolutionSchedulerJob
        ▼
Conversations::ResolutionJob   (≤100 per tick)
        ├─ add_labels('auto-resolved')     ← provenance, account-wide
        └─ toggle_status → resolved
                 ▼  CONVERSATION_RESOLVED (async, performed_by: nil)
        AutomationRuleListener#conversation_resolved
                 ▼  labels == auto-resolved AND inbox_id == 2
        add_label('lead-lost')
```

```
Customer taps a Meta ad, sends first message
        ├─ [in transaction] message.content_attributes[:referral] = {…}
        └─ COMMIT ─────────► CONVERSATION_CREATED   ← TOO EARLY, do not use
        ▼ [after transaction] Umi::FbigAdAttribution.promote
conversation.update!(custom_attributes: {meta_ad_id, meta_ad_ref, meta_ad_title})
        ▼  CONVERSATION_UPDATED (custom_attributes ∈ list_of_keys)
        ├─ meta_ad_id is_present         → add_label('source-paid-ads')
        └─ meta_ad_ref equal_to 'hiring' → add_label('source-recruitment'),
                                           remove_label('lead-new')
```

---

## Failure modes

| # | Failure | Likelihood | Blast radius | Mitigation |
|---|---|---|---|---|
| 1 | **Greeting and auto-answer both fire**, so the customer is asked "which model are you interested in?" and then told the answer anyway — or, if the automation wins the race, gets no greeting. Nondeterministic (`hook_execution_service.rb:35-45` gates on `messages.outgoing.count.zero?`). | Certain | Every FB/IG conversation | Disable `greeting_enabled` on inbox 2, or rewrite the greeting to an acknowledgement with no question, **before** the rules go live. |
| 2 | **A new ad creative changes the menu wording** and the rules match nothing, silently. | High over time | All new ad traffic | Operational commitment: creative changes require a rule update. Once patch 20 ships, detect it as ad-originated conversations with no `intent-*` label. |
| 3 | **`ConditionsFilterService` swallows its own errors** — `rescue StandardError` → log + `return false` (`app/services/automation_rules/conditions_filter_service.rb:40-43`). A malformed condition makes a rule silently never fire. | Medium | One rule, silently | Verify each rule fired on a real conversation before considering it shipped. |
| 4 | **`ActionService#perform` swallows per-action errors** into `ChatwootExceptionTracker`, a bare log line here (`app/services/automation_rules/action_service.rb:15-18`). A rule can half-execute — label applied, reply not sent. | Low | One action | Verify by outcome: message count, not just label count. |
| 5 | **Turning on auto-resolve resolves the Decision 1 cohort.** All 21 tap conversations cross 7 days within a week. | Certain if unsequenced | The entire population under study | Gate Decision 2 behind Decision 1's measurement window. This is the reason for the ordering, not a nicety. |
| 6 | **Turning on auto-resolve resolves the whole backlog at once.** 95 open conversations are already past 7 days; `Limits::BULK_ACTIONS_LIMIT` is 100 (`lib/limits.rb:2`), so it lands in one or two ticks: 95 status changes, labels, activity messages and websocket pushes. | Certain | Whole account | Stage the threshold 90 d → 30 d → 7 d and tell the agents first. |
| 7 | **Account-wide threshold hits non-lead inboxes** — email 17 open, website 8, WhatsApp 9, LINE 4, voice 4. | Certain | 48 open conversations | Accepted by design: they get `auto-resolved`, not `lead-lost`. If closing support threads is unacceptable, Decision 2 must be revisited. |
| 8 | **`auto_resolve_message` accidentally set** → `MessageTemplates::Template::AutoResolve` sends a message *to the customer* announcing the resolution (`resolution_job.rb:10`). Meta's Lost automation was invisible to customers; this would not be. | Low | Every auto-resolved conversation, customer-visible | Leave it empty and **verify it is `nil`**, not merely that nobody typed it. |
| 9 | **`source-paid-ads` labels nothing** because patch 20 is undeployed, the migration was not run, or Facebook does not deliver `referral`. Three independent silent failures, no exception tracker. | High | Nothing labelled; looks like "no ad traffic" | Verify by content: grep for `stage=referral_promoted` and count `Conversation.where("custom_attributes ? 'meta_ad_id'")` before trusting the rule. |
| 10 | **Ad rule keyed on `conversation_created`** instead of `conversation_updated`. Passes every manual test, under-labels in production. | High if unspecified | Silent partial labelling | Specified above; encoded in the verification plan. |
| 11 | **`toggle_status` uses `save`, not `save!`** (`app/models/conversation.rb:162-167`). A validation failure is dropped silently — but `add_labels` already ran, so the conversation keeps `auto-resolved` while staying open. | Low | Individual conversations | Compare `auto-resolved` tagging count against the resolved count after the first tick. |

---

## Verification plan

Everything is read-only except the configuration changes, which are made
through the dashboard.

**Baseline — record before touching anything.**

```ruby
TAPS = ['1. สนใจรับส่วนลด 10% สำหรับการสั่งซื้อครั้งแรก',
        '2. ขอแนะนำสินค้าสำหรับวันแม่',
        '3. ขอแนะนำสินค้าขายดีของ UMI']
tap_ids = Message.unscoped.where(message_type: :incoming, content: TAPS).reorder(nil).distinct.pluck(:conversation_id)
tap_ids.size                                       # 21 on 2026-08-12
Conversation.where(status: :open).count            # 146
Account.first.settings                             # {}
AutomationRule.count                               # 1
ActsAsTaggableOn::Tagging.where(taggable_type: 'Conversation').group(:tag_id).count
```

### Step 0 — greeting

Disable `greeting_enabled` on inbox 2, or replace the text with a question-free
acknowledgement. Confirm `Inbox.find(2).greeting_enabled` and the stored
message.

### Step 1 — the three reply rules (Decision 1)

Create rules A, B and C. Immediately confirm the stored shape, because the UI
can save a condition the backend will not match:

```ruby
AutomationRule.where(event_name: 'message_created').pluck(:name, :conditions, :actions)
# each must carry a message_type == incoming condition and a `content`/`contains` condition
```

Then wait for real taps (~1/day at current volume) and verify **by outcome**:

```ruby
recent = Message.unscoped.where(message_type: :incoming, content: TAPS).where('created_at > ?', <cutover>).reorder(nil)
recent.count                                          # taps since cutover
Message.unscoped.where(conversation_id: recent.distinct.pluck(:conversation_id))
       .where("content_attributes::text LIKE '%automation_rule_id%'").reorder(nil).count
# must equal the tap count — one auto-reply per tap
```

Then confirm the load-bearing property actually holds in production:

```ruby
Conversation.where(id: recent.distinct.pluck(:conversation_id)).pluck(:first_reply_created_at)
# must all still be nil until a HUMAN replies — if the automation reply is
# setting first_reply_created_at, the conversations have silently left the
# Unattended folder and the rule must be reverted
```

**Success criterion.** The metric is customer follow-up after the automated
answer, against the measured baseline of **4 / 20 = 20 %**. The historical
`Questions and responses` cohort ran 43 %. Anything at or above ~35 % over a
30-tap window is the fix working; anything still near 20 % means the *answers*
are wrong, not the mechanism, and the reply texts — not the rules — need
another pass. Hold this window open **before** Step 3.

Also watch the coupon separately: `WELCOME10` currently sits at **6 replies
across 21 conversations (29 %)**, and rule C changes its text. If that does not
move, the discount tap needs a different reply entirely, not a better-worded
one.

### Step 2 — ad attribution (Decision 5)

Deploy patch 20, run migration `20260811000000`, restart rails and sidekiq.

```ruby
CustomAttributeDefinition.where(attribute_model: 'conversation_attribute').pluck(:attribute_key)
# ["meta_ad_id", "meta_ad_ref", "meta_ad_title"]
```

Then wait for live traffic and check **before creating any rule**:

```ruby
Conversation.where("custom_attributes ? 'meta_ad_id'").count
Conversation.where("custom_attributes ? 'meta_ad_id'").group("additional_attributes->>'type'").count
# the second query answers the open Facebook question: if the Messenger bucket
# stays 0 while the Instagram bucket grows, Facebook is not delivering referrals
```

A rule created against an attribute that never arrives is indistinguishable
from a working rule. Only then create the `conversation_updated` rules, and
verify the two counts converge.

### Step 3 — `lead-lost` (Decision 2), only after Step 1's window closes

**Create the rule first, then turn on auto-resolve.** The rule fires on the
*event*, not the state, so anything resolved while it does not exist is never
labelled and no later sweep will pick it up. It is inert until auto-resolve is
on, so creating it early costs nothing.

Rule: `conversation_resolved`, conditions `labels equal_to auto-resolved` AND
`inbox_id equal_to 2`, action `add_label lead-lost`.

Then stage the threshold. Current buckets make it predictable —
`>90d` **0**, `30–90d` **35**, `7–30d` **60**:

| Stage | `auto_resolve_after` (minutes) | Expected resolutions |
|---|---|---|
| 3a — smoke test | `129600` (90 d) | **0.** Proves the job runs and the label is wired, resolving nothing. |
| 3b | `43200` (30 d) | ~35 |
| 3c — target | `10080` (7 d) | ~60 more |

Set `auto_resolve_label: 'auto-resolved'`, leave `auto_resolve_message` empty.
After each stage, wait one tick (5 min):

```ruby
Account.first.settings                                    # auto_resolve_message must be absent/nil
ActsAsTaggableOn::Tag.find_by(name: 'auto-resolved')&.taggings&.count.to_i
ActsAsTaggableOn::Tag.find_by(name: 'lead-lost')&.taggings&.count.to_i
Conversation.where(status: :open).count                   # 146 → 146 → ~111 → ~51
```

`lead-lost` must equal the FB/IG share of `auto-resolved`; if it lags, the rule
is not firing. Stage 3a resolving anything, or 3b resolving far more than 35,
means the units were misread — stop.

### Regression check

`lead-new` must keep growing at roughly the conversation-creation rate — the
new `message_created`, `conversation_updated` and `conversation_resolved` rules
must not have broken rule 1.

---

## What is explicitly NOT being ported, and why

1. **`Lead reminder` (12 h → note + mark unread).** Median first reply is
   **1.1 min** on the ad cohort and 17.9 min elsewhere; 6 of 75 live
   conversations ever crossed 12 h. The Unattended folder already shows the
   same population live and better, and Decision 1 is built to keep
   conversations in it. 87 would qualify today, in an account with 7 private
   notes total. "Mark unread" has no Chatwoot action.
2. **`Leads – Booked leads`.** Triggers on a booking or order object inside
   Meta, which cannot exist (`OFFSITE_LINK`, Thailand).
3. **`Leads – Ordered leads`.** Both branches measured at zero output — the
   order branch because orders happen in Shopify, the message branch
   ("receives messages about placing an order") for a reason not visible from
   here, despite 12 live conversations carrying an inbound สั่ง / สั่งซื้อ. A
   keyword rule would label *intent to order*, not a completed one, and
   `lead-converted` is the one label that must not carry a false number.
4. **`Leads – Responsive leads`.** Expressible in principle — it is a count,
   not a timer — but Chatwoot has no message-count condition and no counter
   column, the label-chaining workaround is broken by `labels not_equal_to`
   semantics, and the output restates the message count. Fires on 9.5 % of the
   ad cohort and 46 % of everything else, i.e. exactly backwards. The patch it
   would take is specified above in case this is reversed.
5. **Restoring Meta's `Questions and responses`.** The behaviour is ported; the
   *location* is not. Meta never echoes its own automations (B4), so agents
   would remain blind to what the customer was told — which is backlog D7.
6. **`lead-converted` automation.** Requires an order↔conversation join
   measured at 0 %.
7. **`lead-qualified` automation.** No observable means "qualified". Macro, not
   rule.
8. **A UMI scheduled job.** Stock covers the one time-based case worth covering.
9. **SLA policies.** Not licensed, cannot express the condition, perform no
   actions.
10. **Anything keyed on the `"replied to an ad."` text marker.** History only —
    60 conversations, all resolved, none in the last 30 days, none live.
11. **A per-ad rule set (`meta_ad_id equal_to <id>`).** Unmaintainable;
    `meta_ad_ref` is the intended axis.

---

## What would change these decisions

- **If Step 1's follow-up rate does not move**, the diagnosis is wrong: the
  problem is the offer or the product fit, not the answer, and no automation
  fixes it. Stop and re-diagnose rather than adding rules.
- **If closing non-FB/IG conversations is unacceptable**, `auto_resolve_after`
  has no inbox scope and stock is out. The UMI-scheduled-job option returns —
  shaped like `Umi::Fbig::ProfileRefreshJob`, scoped to inbox 2, applying
  `lead-lost` **without** resolving. That is a real patch and needs its own
  spec, not a bolt-on here.
- **If agents move fully into Chatwoot**, the whole calculus changes; see below.
- **If a Shopify order↔conversation join lands** (D15's `attributes[conv]` cart
  permalinks or `sourceName` on Admin-API orders), `lead-converted` becomes
  expressible and `Booked`/`Ordered` are worth revisiting.

---

## The single biggest risk

**Half the agents are not in Chatwoot.** Of the 108 live FB/IG conversations,
**56 were replied to from Meta Business Suite** (arriving back as
`external_echo` messages, `sender_type: nil` — 288 such messages since
2026-06) against **31 replied from Chatwoot**. Every label, note and status
this port writes is invisible to an agent working in Business Suite, and every
stage change made in Business Suite is invisible to Chatwoot.

This bites Decision 1 hardest and in a specific way: the auto-reply is a real
Chatwoot message and **will** be delivered to the customer, but an agent
working in Business Suite will see the customer's tap and the auto-reply as two
messages with no indication that one of them was automatic — and may send the
same block again. Backlog A6 records that duplicate sequences have already
reached customers. **Whoever is answering FB/IG needs to be told these rules
exist and where to see them**, or the fix ships a new duplicate-message
problem.

More broadly: porting the funnel into a tool half the team does not look at
reproduces exactly the failure Meta's funnel already demonstrates — diligently
maintained, Converted 0. **The prerequisite for the rest of D6 is not
technical.** It is getting FB/IG replies to happen in Chatwoot. Until that
holds, keep the footprint to what this spec proposes and re-open the question
when the echo count is near zero.

---

## Summary of deliverables, in order

| # | Deliverable | Owner | Code? |
|---|---|---|---|
| 1 | Disable or rewrite the inbox-2 greeting so it does not ask "which model are you interested in?" | ops | no |
| 2 | Write the **Mother's Day** reply block — it does not exist and 7 taps have gone unanswered | product | no |
| 3 | Rewrite the **10 % discount** reply so it ends in something answerable (current text: 9 replies, **0** follow-ups) | product | no |
| 4 | Three `message_created` rules — tap → matched answer + `intent-*` label | ops | no |
| 5 | **Hold a measurement window.** Success = follow-up moves from 20 % toward the historical 43 % | ops | no |
| 6 | Tell whoever answers in Business Suite that the auto-replies exist | ops | no |
| 7 | Set `ref` on hiring ads in Ads Manager (`ref=hiring`) — deadline is the campaign launch, unrecoverable afterwards | meta | no |
| 8 | Deploy patch 20 + run migration `20260811000000` + restart | ops | already written |
| 9 | Confirm `stage=referral_promoted` live; confirm whether Facebook delivers | ops | no |
| 10 | Labels `auto-resolved`, `source-recruitment`; `conversation_updated` rules for `source-paid-ads` / `source-recruitment` | ops | no |
| 11 | `conversation_resolved` rule → `lead-lost` (**create before 12**) | ops | no |
| 12 | `auto_resolve_after` staged 90 d → 30 d → 7 d, `auto_resolve_label: auto-resolved`, `auto_resolve_message` empty | ops | no |
| 13 | Macro for `lead-qualified` (optional) | ops | no |

**No `UMI-PATCHES.md` row is required by this spec** — nothing here is a fork
patch. The only code involved is patch 20, which already has row 20 and its own
remove-when. If Decision 2 is later reversed in favour of a scoped UMI job,
that job gets its own row and remove-when ("upstream adds a per-inbox
auto-resolve threshold").

---

## Flagged: what could not be established

- **Whether Facebook (as opposed to Instagram) delivers `referral` at all.**
  Patch 20's row records Instagram verified / Facebook unverified; A3 records
  `messaging_referrals` absent from the page's 6 subscribed fields. Not
  answerable from the database — zero referral rows exist because the patch is
  undeployed. Confirm from live logs after Step 2.
- **Whether `ref` can be set on an already-running hiring ad.** Backlog D3
  records that welcome-message *flows* are immutable while an ad is live; I did
  not establish whether the same holds for the `ref` field. If it does not, the
  recruitment split is impossible for the campaign launching now.
- **Why the message branch of `Ordered leads` never fired.** The trigger
  includes "receives messages about placing an order", the raw signal is
  present (12 live conversations carry an inbound สั่ง / สั่งซื้อ), and the
  automation has been ON — yet Converted is 0. Two plausible explanations,
  neither testable from here: Meta's intent detection may not cover Thai, or
  the message branch may still require corroboration from a Leads Centre order
  object. It changes nothing about the recommendation, but it is the difference
  between "the feature does not apply to us" and "the feature is silently
  broken for Thai", and only the second is worth reporting to Meta.
- **Whether `Responsive leads` counts the same messages I did.** My 39 % uses
  non-private incoming + outgoing messages. Meta says "exchanges 5 messages"
  without defining whether system lines, its own automated replies or the ad
  welcome message count. The 39 % / 40 % agreement is close enough to be
  persuasive but it is not proof the definitions match, and the recommendation
  does not depend on it.
- **The Feb/Mar 43 % and June 37 % comparison cohorts were not re-measured
  here.** They come from the parallel analysis and rest on the marker-verified
  history population; my own measurements cover the current cohort only. The
  *direction* is corroborated by my independent numbers (20 % vs 80 %,
  p ≈ 3.3 × 10⁻⁶), but the 43 % target in Step 1's success criterion inherits
  whatever uncertainty that cohort carries.
- **My cohort figures differ from the parallel analysis's** — 21 conversations
  vs 20, 20 % follow-up vs 11 %, `WELCOME10` 6/21 vs 0/8 — because the cohorts
  are defined differently (I matched the three tap literals across all time;
  they took product-ad conversations created 2026-08-05/10). Both point the
  same way and the conclusion does not depend on which is used, but **the two
  sets of numbers are not interchangeable** and should not be mixed in one
  sentence.
- **Why 10 conversations carry "marked resolved by system due to 0 minutes of
  inactivity" activity messages (all 2026-06) when `auto_resolve_after` has
  never been set** (`Account.first.settings == {}`, account last updated
  2026-06-13). Probably an artefact of the history migration or a
  since-reverted setting; not proven. Worth asking before Step 3 in case
  someone turned auto-resolve off for a reason.
