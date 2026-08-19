# Review: `docs/UMI-SHARED-NUMBER-SPEC.md` — Chatwoot lifecycle & code correctness

Reviewer lens: Chatwoot call graph, channel callbacks, webhook registration, webhook
job dispatch, status handling, contact/inbox routing, private-note semantics,
first-reply metrics, and the proposed tests. Every code claim in the spec was checked
against this checkout (branch `umi-shared-number-spike`, base `v4.16.0`).

Verdict: the spec's code claims are **mostly accurate**, and unusually careful about
confidence levels. But there are **two claims that are overstated in a load-bearing
way** (they make the runbook look safer than the code is), **one internal
contradiction between §2 and the runbook**, **one cross-reference error**, and
**five real Chatwoot behaviours the spec does not cover at all** — three of which are
production risks specific to a shared number.

---

## Part 1 — Incorrect or overstated claims

### 1.1 OVERSTATED (load-bearing): "`register_callback` … is the safe primitive"

Spec §2, final bullet:

> `WebhookSetupService#register_callback` validates and calls `setup_webhook` directly;
> it does not call either registration check. **This is the safe primitive**, but channel
> creation does not use it automatically.

The first half is correct. The conclusion is not, and it is the most consequential
error in the document.

Evidence — `app/services/whatsapp/webhook_setup_service.rb:20-23`:

```ruby
def register_callback
  validate_parameters!
  setup_webhook
end
```

`setup_webhook` (`app/services/whatsapp/webhook_setup_service.rb:59-68`) calls
`subscribe_phone_number_webhook`, and that method
(`app/services/whatsapp/facebook_api_client.rb:65-72`) **unconditionally performs the
phone-level override POST** — the exact write whose multi-app safety §1 declares
`UNKNOWN` and names as the migration blocker:

```ruby
def subscribe_phone_number_webhook(waba_id, phone_number_id, callback_url, verify_token, subscribed_fields: nil)
  subscribe_app_to_waba(waba_id, subscribed_fields: subscribed_fields || WEBHOOK_DEFAULT_FIELDS)
  override_phone_number_callback(phone_number_id, callback_url, verify_token)   # ← the unknown-safety write
end
```

So `register_callback` is safe **only with respect to `/register`**. It is not safe
with respect to §1. Correction to make in the spec:

> `register_callback` avoids `/{phone-number-id}/register` but still performs the
> phone-level `override_callback_uri` POST. It is the *registration-safe* primitive,
> not *the* safe primitive. A genuinely safe foreign-number mode needs a third
> option — WABA-subscription-only, with `override_phone_number_callback` skipped —
> which does not exist in this checkout and must be added.

This propagates into the runbook. **Runbook step 4** ("Subscribe Chatwoot, set only
Chatwoot's approved callback") *is* the unknown-safety write, and the "Decision gate"
only gates on `/register`, not on the override. As written the runbook authorizes the
operation the spec's own §1 says must not be inferred safe. The gate wording needs a
second condition: no phone-level override write against the shared number until §1.1
returns the safe result.

### 1.2 OVERSTATED: §1's "logged and re-raised" understates how quietly setup fails

Spec §1: "A webhook setup exception is logged and re-raised by `setup_webhook`, but
phone registration errors are logged as 'but continuing'."

Both halves are literally true (`webhook_setup_service.rb:65-68` re-raises;
`:40-42` swallows). But the re-raise does **not** reach the operator. The model's
after-commit path catches it — `app/models/channel/whatsapp.rb:123-128`:

```ruby
def setup_webhooks
  perform_webhook_setup
rescue StandardError => e
  Rails.logger.error "[WHATSAPP] Webhook setup failed: #{e.message}"
  prompt_reauthorization!
end
```

So on the automatic path the channel/inbox is still created successfully, with only a
log line and a reauthorization banner. The practical statement the spec should make is
the opposite of the current emphasis: **on the auto-setup path, nothing in the Chatwoot
lifecycle fails loudly** — not registration, not webhook setup. An operator watching the
UI cannot distinguish "subscribed correctly" from "wrote the wrong thing to Meta and
gave up". The gate must require reading `[WHATSAPP]` logs and a Graph read-back, not the
UI's success state.

### 1.3 INCOMPLETE: the subscribed-fields claim omits `calls`

Spec §6: "The checkout subscribes Cloud channels to `messages smb_message_echoes`."

`WEBHOOK_DEFAULT_FIELDS` is indeed those two
(`app/services/whatsapp/facebook_api_client.rb:4`), but the setup service overrides it
(`app/services/whatsapp/webhook_setup_service.rb:71-89`):

```ruby
def subscribed_fields
  fields = %w[messages smb_message_echoes]
  fields << 'calls' if calls_enabled_on_waba?
  fields
end
```

`calls_enabled_on_waba?` returns true if **this channel or any sibling on the same
WABA** has `calling_enabled`. UMI runs WhatsApp voice on this number, so the real
subscription will be `messages smb_message_echoes calls`. The `calls` field lands in
`Enterprise::Webhooks::WhatsappEventsJob#handle_call_events`
(`enterprise/app/jobs/enterprise/webhooks/whatsapp_events_job.rb:18-49`). This matters
for the §1.1 experiment design: the collectors must expect a third `changes[].field`,
and the gate's "expected callback data" check should assert the full field list.

### 1.4 IMPRECISE: "does not enqueue a customer-facing send"

Spec §5 says a private note "does not call WhatsApp and does not enqueue a
customer-facing send through the channel service."

`send_reply` is unconditional (`app/models/message.rb:330`, `:397-401`) — `SendReplyJob`
**is always enqueued**, for private notes too. It runs, instantiates
`Whatsapp::SendOnWhatsappService`, and the guard fires inside
`Base::SendOnChannelService#invalid_message?` (`app/services/base/send_on_channel_service.rb:46-51`):

```ruby
def invalid_message?
  message.private? || outgoing_message_originated_from_channel? || message.content_type == 'voice_call'
end
```

Net effect is what the spec claims (no Graph call), so this is a wording fix, not a
correctness failure — but the §5 verification plan says to assert "no `SendReplyJob`-driven
network call", and a naive `expect(SendReplyJob).not_to have_been_enqueued` assertion
would fail. State the assertion as: the job is enqueued, and `perform_reply` is never
reached.

### 1.5 CROSS-REFERENCE ERROR: "§4.1" does not exist

The Decision gate and §6 both point at "the phone-level webhook override experiment in
§4.1" / "the two-app throwaway test in §4.1". The experiment is **§1.1**. §4 is inbound
routing. Fix both references; this one is likely to send a human operator to the wrong
procedure.

### 1.6 Claims verified as CORRECT (no change needed)

| Spec claim | Evidence |
|---|---|
| `subscribe_phone_number_webhook` POSTs WABA then unconditionally POSTs phone override | `facebook_api_client.rb:65-72` |
| `perform` registers if `!verified?` **or** health `NOT_APPLICABLE` | `webhook_setup_service.rb:15`, `:125-140` |
| Verification-check rescue returns `false` → still triggers registration | `webhook_setup_service.rb:107-111` (`false` → `!false` → register) |
| Health-check rescue returns `false` → does **not** trigger registration | `webhook_setup_service.rb:119-123`, `:136-140` |
| Registration errors swallowed as "but continuing" | `webhook_setup_service.rb:40-42` |
| Non-`embedded_signup` cloud channel auto-runs `perform` after commit | `channel/whatsapp.rb:38`, `:162-166` |
| Manual cloud channel = `Channel::Whatsapp` + business_account_id/phone_number_id/api_key/generated verify token | `channel/whatsapp.rb:20-38`, `:132-134` |
| Status for an unknown message is a clean no-op | `incoming_message_base_service.rb:49-57` (`return unless find_message_by_source_id`) |
| No row created, no exception, job succeeds, no dead set | ditto + `whatsapp_events_job.rb:92-97` returns nil sender for status payloads → no mutex, no `LockAcquisitionError` retry |
| Inbound routing keys on `metadata.display_phone_number` **and** `metadata.phone_number_id` | `whatsapp_events_job.rb:155-161` |
| A new Cloud inbox gets its own ContactInbox; Twilio history stays on inbox 6 | `Channel::TwilioSms` is a different channel class with its own inbox; ContactInbox is per (contact, inbox, source_id) |
| Deleting an inbox destroys conversations **asynchronously** | `app/models/inbox.rb:69-70` `dependent: :destroy_async` |
| `invalid_message?` blocks private notes from the channel service | `base/send_on_channel_service.rb:46-51` |
| `valid_first_reply?` requires `!private?` | `message.rb:224-225` |
| A private note does not stamp `first_reply_created_at` **or** `waiting_since` | `message.rb:381-386` → `update_waiting_since` (`:340-343`) is guarded by `&& !private`, and `set_waiting_since_on_incoming_message` needs `incoming?` |
| `smb_message_echoes` is coexistence-only, mapped with `external_echo: true` | `whatsapp_events_job.rb:37-77`, `incoming_message_base_service.rb:175-181` |

---

## Part 2 — Material gaps (real Chatwoot behaviour the spec does not cover)

### 2.1 BLOCKER-CLASS: only the **first** status in a batch is processed

`app/services/whatsapp/incoming_message_base_service.rb:49-51`:

```ruby
def process_statuses
  status = @processed_params[:statuses].first
  return unless find_message_by_source_id(status[:id])
```

Meta batches multiple `statuses` entries per webhook. Today, with a Chatwoot-only
number, a dropped second status is a cosmetic delivery-tick miss. **On a shared number
it becomes systematic**: a batch that happens to lead with a Klaviyo wamid causes
Chatwoot's own status in position 2+ to be silently discarded, so agent-sent messages
stall at `sent` and never show delivered/read/failed — including `failed`, which is how
agents learn a message did not land.

§3's framing ("ignored cleanly") is correct for the single-status case but misses that
the shared-number design *creates* the mixed-batch case. This belongs in the failure-mode
table with its own detection (compare Chatwoot `messages.status` against Graph) and
probably needs a patch (`each` over `statuses` instead of `.first`) before cutover.

### 2.2 `before_destroy` teardown clears the phone-level override — for manual channels too

`app/models/channel/whatsapp.rb:37` → `Whatsapp::WebhookTeardownService`
(`app/services/whatsapp/webhook_teardown_service.rb:24-38`):

```ruby
def should_teardown_webhook?
  @channel.provider == 'whatsapp_cloud' && provider_config['api_key'].present? &&
    (provider_config['phone_number_id'].present? || provider_config['business_account_id'].present?)
end
...
api_client.clear_phone_number_callback_override(phone_number_id)
```

The WABA unsubscribe is correctly gated on `source == 'embedded_signup'` (`:43`), but the
**override clear is not**. So deleting the Chatwoot Cloud inbox POSTs
`override_callback_uri: ''` to the shared phone number. If §1.1 returns the unsafe
result (one shared, mutable override), that single delete takes **Klaviyo's** inbound
routing down too, from inside a `before_destroy` that logs and swallows every error
(`:13-16`).

The Rollback section says "do not delete the channel or inbox until its data-retention
impact is reviewed" — framing the risk as data retention only. Add: deleting the Cloud
channel is a **Graph-mutating** operation against a number Chatwoot does not own. Rollback
should disable, never delete.

### 2.3 Voice toggles silently re-write the phone override

`app/models/channel/whatsapp.rb:79-87` and `:92-102` both call
`webhook_setup_service.register_callback` — i.e. both the enable and disable voice paths
re-issue the phone-level override POST, and the disable path swallows failures (`:99-101`).
An admin flipping the voice toggle in the UI after cutover performs the §1 unknown-safety
write with no gate, no review, and no operator-visible failure. The spec's freeze
(runbook step 1) covers "WhatsApp setup, Klaviyo WABA settings, and n8n" but not the
inbox voice toggle. Add it, and add a failure-mode row.

### 2.4 Private notes still fan out to automation rules, agent bots, and account webhooks

§5's "safe if created as a note" holds for Chatwoot's *own* send path, but the
`MESSAGE_CREATED` dispatch is unconditional (`app/models/message.rb:381`), and the
downstream listeners do **not** filter private:

* `AutomationRuleListener#message_created` — `app/listeners/automation_rule_listener.rb:18-34`;
  its skip guard (`:82-85`) is `performed_by_automation? || activity? || auto_reply_email?`
  — **private is not excluded**. A `message_created` rule whose action is `send_message`
  (`app/services/automation_rules/action_service.rb:43-47`, which builds
  `private: false`) would turn a mirrored Klaviyo note into a real outbound WhatsApp
  message. That is precisely the outcome §5 exists to prevent.
* `AgentBotListener#message_created` — `app/listeners/agent_bot_listener.rb:36-42`,
  gated on `webhook_sendable?`, which is `incoming? || outgoing? || template?`
  (`app/models/concerns/message_filter_helpers.rb:8-10`) — private notes pass.
* `WebhookListener#message_created` — `app/listeners/webhook_listener.rb:25-33`, same
  gate. Every account/inbox webhook receives the Klaviyo marketing copy.

Correctly filtered: `notifiable?` **does** exclude private
(`message_filter_helpers.rb:16-18`), so no agent notifications fire.

Gate addition: before enabling n8n, audit the account's `message_created` automation
rules and any agent bot on the Cloud inbox, and assert in the §5 test that no
automation rule fires and no outbound message is created.

### 2.5 A mirrored note bumps `last_activity_at`

`app/models/message.rb:448-451` (`set_conversation_activity`) runs for every message
including private notes, `update_columns(last_activity_at:, updated_at:)`. Mirroring
every Klaviyo campaign send therefore re-sorts the agent inbox and resets any
activity-based auto-resolve/stale timers on conversations that had no real customer
activity. Not a safety bug, but it is an agent-experience regression the spec should
name, and it is worth one assertion in the §5 test.

---

## Part 3 — The proposed tests

### 3.1 The §3 test as written can pass vacuously (false green)

```ruby
described_class.new(inbox: whatsapp_channel.inbox, params: status_params_for('wamid.klaviyo-only')).perform
```

`Whatsapp::IncomingMessageWhatsappCloudService#processed_params`
(`app/services/whatsapp/incoming_message_whatsapp_cloud_service.rb:7-9`):

```ruby
@processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
```

Note the **mixed key types**: `[:entry]` symbol, then `['changes']` / `['value']` strings.
A plain symbol-keyed hash returns `nil`, `perform` does nothing at all, and the test
passes — while asserting nothing. Every existing spec avoids this by ending the payload
with `.with_indifferent_access`
(`spec/services/whatsapp/incoming_message_whatsapp_cloud_service_spec.rb:31`). The spec
must say so explicitly.

### 3.2 The §3 test violates Rule 8 — it cannot fail when the logic changes

Both assertions (`not_to change(Message, :count)`, `not_to raise_error`) also hold when
the payload never parses, when the service is a no-op, and when `process_statuses` is
deleted entirely. Minimum fix — add a **positive control in the same example group**:

* create a message in the inbox with `source_id: 'wamid.chatwoot-owned'`;
* feed a status for `wamid.chatwoot-owned` → assert `message.reload.status` changes
  (proves the payload parses and `process_statuses` runs);
* feed a status for `wamid.klaviyo-only` → assert no Message/Conversation/Contact
  created **and** the known message's status is unchanged.

Only the pair pins the intent. The spec's own follow-up note ("should also assert no
conversation/contact is created") is right but insufficient without the control.

Also: `find_message_by_source_id` is `Message.find_by(source_id: source_id)` with **no
account or inbox scope** (`app/services/whatsapp/incoming_message_service_helpers.rb:80-84`).
Worth one assertion that a same-`source_id` message in a *different* inbox is not
mutated by a status arriving on this one — a cross-tenant status-write path that the
shared-number design makes more reachable.

### 3.3 The §2 guard test is correctly specified but insufficient

"Add a guard test that asserts the foreign-number path never calls `register_phone_number`"
is right. Given §1.1 above, add a second assertion to the same test: the foreign-number
path never calls `override_phone_number_callback` either. Otherwise the guard certifies
a path that still performs the §1-blocked write.

### 3.4 The §5 test needs three more assertions

Beyond "no outbound provider call / no first-reply change": assert (a) `SendReplyJob` is
enqueued but `perform_reply` is not reached, (b) `AutomationRules::ActionService` is not
invoked, (c) `conversation.waiting_since` is unchanged (this one currently holds — see
§1.6 — so it is a genuine regression pin, not a snapshot).

---

## Part 4 — Smaller notes

* **Gate item 5** ("no production save … before the gate is green") is right and worth
  strengthening: a `Channel::Whatsapp` save is not inert. `validate_provider_config`
  (`channel/whatsapp.rb:136-138`) makes two Graph GETs on every save, and
  `after_create :sync_templates` (`:35`) pulls the whole template list. Creating the
  record "just to check the config" already touches Klaviyo's WABA.
* **Uniqueness**: `channel_whatsapp.phone_number` has a UNIQUE index
  (`channel/whatsapp.rb:17`, `:32`). Add a pre-flight check that no `Channel::Whatsapp`
  row already holds `+66975311301`; the Twilio row lives in a separate table so it does
  not conflict, but a stale/abandoned cloud row would block creation at the last moment.
* **Channel lookup is exact-match on `"+#{display_phone_number}"`**
  (`whatsapp_events_job.rb:156-160`). If Meta ever emits a formatted
  `display_phone_number`, the channel is not found and the job returns with only a
  `Rails.logger.warn` (`:11-14`) — inbound goes dark silently. Add "inbound arrives and
  resolves to the channel" as an explicit positive check in runbook step 5 rather than
  relying on absence of errors.
* **§4's confidence framing is right.** `IncomingMessageIdentifierHelper` handles BSUID
  and `wa_id` shapes; the spec correctly declines to claim exact identity matching
  without a real payload.
* **§6 is correctly reasoned.** `message_echo_event?` keys strictly on
  `field == 'smb_message_echoes'` (`whatsapp_events_job.rb:71-73`); nothing in this
  checkout consumes `message_echoes` as a top-level field, so "do not infer it will
  mirror Klaviyo sends" is the right call.

---

## Summary of required spec edits

1. Rewrite §2's "safe primitive" claim — `register_callback` still performs the §1-blocked
   phone-override write. Add the missing third mode (WABA-subscribe only).
2. Add the phone-override write to the Decision gate and to runbook step 4's
   preconditions; today the runbook performs the operation §1 blocks.
3. Fix "§4.1" → "§1.1" in the Decision gate and §6.
4. Add §1.2: the auto-setup path swallows *everything* — gate on logs + Graph read-back,
   not UI success.
5. Add the multi-status batch truncation (§2.1) as a failure mode with detection.
6. Add channel-delete teardown (§2.2) and voice toggles (§2.3) as Graph-mutating paths
   to freeze/forbid.
7. Add automation-rule / agent-bot / webhook fan-out of private notes (§2.4) to §5 and
   to the pre-migration gate.
8. Correct §6's subscribed-fields list to include `calls`.
9. Rewrite the §3 test with `.with_indifferent_access` and a positive control.
