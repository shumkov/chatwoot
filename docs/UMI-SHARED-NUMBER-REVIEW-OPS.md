# Review: UMI shared WhatsApp number spec — failure modes, operations, migration, observability, rollback

Reviewer lens: operational safety. Assumption applied throughout: a wrong answer here
silently takes support dark on UMI's only WhatsApp number, and nobody notices until a
customer complains through another channel.

Scope: `docs/UMI-SHARED-NUMBER-SPEC.md` @ working tree, 2026-08-18, branch
`umi-shared-number-spike`, against this checkout (Chatwoot v4.16.0 base + UMI overlay).
Every "verified" claim below was read out of the files named; no live Meta or production
call was made.

## Verdict

The spec's technical readings of this checkout are **accurate** — I re-derived every code
claim in §1, §2, §3, §4, §5, §6 and found no misstatement. The architecture gate in §1 is
the right blocker and is correctly refused-until-proven.

It is nonetheless **not safe to execute as written**. The spec models the shared number as
a *routing* problem and stops there. It does not model the shared number as a *load*,
*teardown*, *authentication*, or *identity-drift* problem, and those are where a silent
support outage actually comes from. Six issues below are blocking; the gate and runbook
also contain one circular dependency that cannot be satisfied in the order given.

Severity key: **B** = blocking (must be resolved before the gate can be called green),
**H** = high (must be in the gate/runbook but does not by itself stop the design),
**M** = medium.

---

## B1. Channel deletion is a destructive write to the *shared* phone number — and the spec's rollback path walks into it

Not mentioned anywhere in the spec.

Verified in `app/models/channel/whatsapp.rb:` `before_destroy :teardown_webhooks` →
`app/services/whatsapp/webhook_teardown_service.rb`:

* `should_teardown_webhook?` is true for any `whatsapp_cloud` channel with an `api_key` and
  a `phone_number_id` — **it is not gated on `source == 'embedded_signup'`**.
* `clear_phone_number_override` then calls
  `Whatsapp::FacebookApiClient#clear_phone_number_callback_override`, which POSTs
  `/{phone-number-id}` with `webhook_configuration: { override_callback_uri: '' }`
  (`app/services/whatsapp/facebook_api_client.rb`).
* Only the *WABA unsubscribe* is gated on `embedded_signup`. The phone-level clear is not.

Consequence: if §1's Unknown resolves to "the phone-level override is one mutable property
of the phone number" — the exact unsafe case the spec is built to detect — then **deleting
or replacing the Chatwoot inbox erases Klaviyo's callback too**, and Klaviyo's inbound goes
dark. The failure is one `before_destroy` away from any admin who deletes an inbox in the
UI, and the whole teardown is wrapped in `rescue StandardError` + `Rails.logger.error`, so
it fails and succeeds equally silently.

This is a rollback hazard specifically because deleting the new inbox is the intuitive
rollback. Spec Rollback step 3 says "do not delete the channel or inbox until its
data-retention impact is reviewed" — that framing is about Chatwoot rows, and an operator
reading it will conclude the risk is *losing conversations*, not *unhooking Klaviyo*. An
operator who has already exported the conversations will read that sentence as satisfied.

Required:
* Add to Rollback and to the failure table: **inbox/channel deletion is a live destructive
  Meta write on a number UMI does not exclusively own. Never delete the Cloud channel as a
  rollback step.**
* Ship the foreign-number mode in §2 as a `provider_config` marker that *also* suppresses
  teardown (e.g. `source: 'foreign_owned'` short-circuiting `should_teardown_webhook?`),
  with a guard test asserting `clear_phone_number_callback_override` is never called for it.
  §2's recommended patch only covers `register_phone_number`; that is half the surface.
* Runbook step 1's freeze must name inbox deletion explicitly, not just "changes to
  WhatsApp setup".

## B2. Meta signature verification is **off** on exactly the channel shape the spec recommends

Not mentioned anywhere in the spec.

Verified in `app/controllers/webhooks/whatsapp_controller.rb#meta_signature_verification_required?`
and `app/controllers/concerns/meta_token_verify_concern.rb`:

```ruby
return true if whatsapp_channel.blank?
return false unless whatsapp_channel.provider == 'whatsapp_cloud'
return true if channel_meta_app_secrets(whatsapp_channel).present?
whatsapp_channel.provider_config['source'] == 'embedded_signup'
```

A manual `whatsapp_cloud` channel with no `app_secret` / `app_secret_key` / `client_secret` /
`api_secret` key in `provider_config` returns **false** → `verify_meta_signature!` returns
early → `process_payload` accepts the body unauthenticated. The global
`WHATSAPP_APP_SECRET` appears in `meta_app_secrets` (the list of secrets to *check against*)
but **not** in the required-check, so setting it globally does not turn verification on.

The spec's §2 recommendation is precisely "manual, foreign-owned, not `embedded_signup`" —
i.e. it lands on the unverified path by construction. The callback URL is deterministic
(`FRONTEND_URL/webhooks/whatsapp/+66975311301`, built in
`Whatsapp::WebhookSetupService#build_callback_url`) and the number is public marketing
collateral. Anyone can POST forged inbound messages, forged `statuses`, or forged echoes
into the support inbox.

Required gate item: the production `provider_config` must carry `app_secret` for Chatwoot's
Meta app, and the gate must include a **negative test** — POST a well-formed payload with
a bad `X-Hub-Signature-256` and assert `401`, not `200`. Without that assertion the gate
cannot distinguish "verification on" from "verification silently off".

## B3. Marketing status volume and support inbound share one strict-priority Sidekiq queue — the most likely silent outage, and the spec calls it "normal"

The spec's failure table row *"Klaviyo status has no Chatwoot message → Treat as normal"*
is correct about correctness and wrong about operations.

Verified:
* `app/jobs/webhooks/whatsapp_events_job.rb` is `queue_as :low`.
* Inbound support messages use the **same job on the same queue** — there is no separation.
* `config/sidekiq.yml` declares queues without weights, and its own comment states: *"jobs
  in lower ranking queues will only be processed if there are no jobs in higher ranking
  queues."* `low` is 7th of 15. Concurrency defaults to `SIDEKIQ_CONCURRENCY` = 10.

A Klaviyo campaign to N recipients produces on the order of 3N status webhooks
(`sent`/`delivered`/`read`) plus failures, every one of which becomes a `low`-queue job that
does a DB lookup and returns. A 20k-recipient blast is ~60k jobs ahead of the next real
customer message, FIFO, behind six higher-priority queues. Support does not error — it
**arrives late**, which is the failure mode nobody pages on.

Also note the spec's §3 test is written against `IncomingMessageWhatsappCloudService`
directly and therefore proves nothing about enqueue volume; the no-op is cheap *per job*,
which is not the risk.

Required:
* Gate item: obtain Klaviyo's expected peak send rate and compute the resulting webhook
  rate. If it is not small relative to current `low`-queue throughput, this is a blocking
  capacity problem, not a monitoring one.
* Add a **queue-latency alarm on `low`** (Sidekiq queue latency > threshold) as a
  first-class detection signal, wired to the Netdata filecheck heartbeat pattern already
  used on umi-vps — not to Sentry, which is empty by design on this install.
* Preferred mitigation: drop status-only payloads at the controller before enqueue, or
  route them to a distinct lower queue, so marketing telemetry can never sit in front of a
  customer message. Either is a real code change and belongs in the spec, not the runbook.

## B4. Silent inbound blackhole on `phone_number_id` drift — returns HTTP 200, logs a `warn`, and nothing else

The failure table has *"Inbound reaches wrong inbox or contact"* but not *"inbound is
accepted and discarded"*, which is the more dangerous case because there is no wrong-place
artifact to notice.

Verified in `Webhooks::WhatsappEventsJob#get_channel_from_wb_payload`:

```ruby
channel = Channel::Whatsapp.find_by(phone_number: phone_number)
return channel if channel && channel.provider_config['phone_number_id'] == phone_number_id
```

On mismatch it returns `nil`; `channel_is_inactive?(nil)` returns `true`; `perform` logs
`Rails.logger.warn("Inactive WhatsApp channel: ...")` and returns. The controller has
already returned `head :ok`, so **Meta sees a healthy delivery** and will never retry or
flag the subscription. There is no exception, no Sidekiq failure, no dead set entry — the
message is simply gone. Per the recorded observability posture on this install (no Sentry,
Dead set unwatched), a `warn` line is not a detection mechanism.

The same silent-discard applies to `Channel::Whatsapp.find_by(phone_number:)` missing
because of a `display_phone_number` formatting difference (the job builds
`"+#{display_phone_number}"` with no normalization beyond the `+`).

This is not hypothetical during this migration: see B5 — migrating a number to a different
WABA is exactly the event that changes `phone_number_id`.

Required:
* Gate + runbook step 5 must assert the **positive** signal (message row created, correct
  contact, correct inbox) and treat "webhook returned 200" as no evidence at all.
* Add a synthetic-inbound canary after cutover: a scheduled job or external prober that
  sends one inbound message on a cadence and alarms if no `Message` row appears within N
  minutes. This is the only detector that covers B4, B1, and an override overwrite by
  Klaviyo at the same time.
* Add a monitor on the `warn` string, or better, convert this branch to a counter/heartbeat
  the existing Netdata alarm can see.

## B5. The pre-migration gate and the runbook are circularly ordered — gate item 5 cannot be satisfied before runbook step 2

Gate item 5 requires Chatwoot to have "a tested Cloud channel configuration containing the
final `business_account_id`, `phone_number_id`, API token, phone number, and verify token"
and states "no production save or after-commit setup occurs before the gate is green".

Runbook step 2 is Klaviyo completing the number/WABA migration in the Meta portfolio — and
that step is what *produces* the final WABA ID and, for a cross-WABA move, a new
phone-number ID. Step 3 then says "verify the new WABA/phone IDs", confirming the spec
knows they are new.

So gate item 5 asks for a value that only exists after the runbook has started, while the
runbook is gated on item 5. In practice an operator resolves this by either (a) calling the
gate green with pre-migration IDs, which then silently mismatch at step 4 — landing exactly
in B4 — or (b) creating the Chatwoot channel *after* migration with no gate coverage.

Required: split the gate into **pre-migration** (items 1, 2, 3, 6, 7, 8 — provable against
disposable assets) and **post-migration pre-activation** (items 4, 5 plus B2's signature
test and B6's uniqueness check), and make runbook step 3 an explicit gate boundary with its
own halt owner. As written the document has one gate; it needs two.

## B6. Channel creation itself is the risky, irreversible-ish act — and it commits before anything is verified

Verified in `app/models/channel/whatsapp.rb`:

* `after_commit :setup_webhooks, on: :create, if: :should_auto_setup_webhooks?` — the row
  is **committed first**, then webhooks are attempted.
* `setup_webhooks` wraps `perform` in `rescue StandardError => e` → `Rails.logger.error` +
  `prompt_reauthorization!`. **The create still succeeds.** The admin UI shows an inbox
  that exists but may have pushed a partial or wrong configuration to Meta.
* `validates :phone_number, uniqueness: true` plus a unique DB index
  `index_channel_whatsapp_on_phone_number` — global across the whole install, not per
  account. Any pre-existing `Channel::Whatsapp` row for `+66975311301` (a spike leftover, a
  test inbox) blocks creation at the worst possible moment. The Twilio inbox 6 is a
  `Channel::TwilioSms` row in a different table (`channel_twilio_sms`, its own unique index)
  so it does **not** collide — verified — but the gate should still assert
  `Channel::Whatsapp.where(phone_number: '+66975311301')` is empty beforehand.
* `validate_provider_config` runs `Whatsapp::Providers::WhatsappCloudService#validate_provider_config?`,
  which makes **live Graph GETs** (`/{waba}/message_templates`, and when
  `provider_config_changed?` also `/{waba}/phone_numbers`) on *every save*. A token that
  cannot read the shared WABA's templates makes the channel uncreatable.
* `after_create :sync_templates` immediately pulls the shared WABA's templates, and
  `Channels::Whatsapp::TemplatesSyncSchedulerJob` re-syncs every 3 hours — so **Klaviyo's
  marketing templates become selectable by support agents in Chatwoot**. Not dangerous, but
  it is an unstated product consequence of sharing a WABA and should be acknowledged (and
  the operator told not to treat unfamiliar templates as corruption).

Required additions to the gate: the pre-existing-row check; a token-scope check proving
`/{waba}/message_templates` and `/{waba}/phone_numbers` are readable; and an explicit
acknowledgement that **"inbox created successfully" in the UI is not evidence that webhook
setup succeeded** — the operator must check for the reauthorization banner / the
`whatsapp_disconnect` administrator email (`Reauthorizable#prompt_reauthorization!` →
`send_channel_reauthorization_email(:whatsapp_disconnect)`) and read back
`GET /{phone-number-id}?fields=webhook_configuration` before declaring step 4 done.

## H1. §2's patch recommendation is under-scoped: `register_callback` is not the only re-write path

§2 correctly identifies that `perform` can call `/register` and that `register_callback` is
the safe primitive. Two paths it misses:

* `Channel::Whatsapp#enable_voice_calling!` and `#disable_voice_calling!` both call
  `webhook_setup_service.register_callback` → `setup_webhook` →
  `subscribe_phone_number_webhook` → **an unconditional phone-level override POST**. Toggling
  WhatsApp voice on the shared inbox therefore rewrites the shared override. Given voice is
  already live on this number via Twilio, an operator toggling voice is a realistic action.
* `Whatsapp::WebhookSetupService#subscribed_fields` / `calls_enabled_on_waba?` scans sibling
  channels on the same `business_account_id` and rewrites the **WABA-level app subscription
  fields**. That POST is app-scoped by bearer token (verified: `subscribe_app_to_waba` uses
  `request_headers` only), so it cannot clobber Klaviyo's subscription — good — but it does
  mean Chatwoot re-declares `messages smb_message_echoes [calls]` on a WABA it shares.

Also worth stating plainly, because §2 is optimistic about it: the spec frames the
`/register` risk as "an already-provisioned Klaviyo number could reject registration".
Rejection is the *good* outcome. `POST /{phone-number-id}/register` with a
`SecureRandom`-generated PIN (`WebhookSetupService#fetch_or_create_pin`) **succeeding** is
the bad outcome — it can reset the number's two-step PIN out from under Klaviyo, breaking
their future re-registration, and Chatwoot then swallows the whole thing
(`rescue StandardError → Rails.logger.warn("...but continuing")`). The spec should invert
its framing here: assume success is possible and treat any `/register` call on this number
as a production incident, not a warning.

Required: the guard test §2 asks for must assert **zero** calls to
`register_phone_number` *and* `clear_phone_number_callback_override`, and the foreign-number
mode must additionally block the voice-toggle re-write path (or the runbook must forbid
touching voice settings on this inbox and say why).

## H2. §6's Unknown has an unhandled *safe-result* downside: echoes corrupt agent SLA metrics

§6 asks the two-app test to record `message_echoes`, and concludes "if not reproducible,
n8n remains the only approved mirror". It does not say what happens if echoes *do* arrive.

Verified: `Webhooks::WhatsappEventsJob#message_echo_event?` matches `field ==
'smb_message_echoes'` and calls the incoming service with `outgoing_echo: true`, which
creates a message with `message_type: :outgoing`, `sender: nil`, `status: :delivered`,
`content_attributes: { external_echo: true }`
(`incoming_message_base_service.rb:166-176`). In `app/models/message.rb:370`,
`human_response?` is true when `sender.is_a?(User) || content_attributes['external_echo']`,
and `valid_first_reply?` requires only `human_response? && !private?`. So an echo-created
message **stamps `conversation.first_reply_created_at` and clears `waiting_since`**.

Consequence: if any echo shape reaches Chatwoot for a Klaviyo send, every marketing message
to an open conversation counts as the agent's first reply. First-response-time reporting
becomes silently wrong in the *flattering* direction — which is worse than obviously wrong,
because nobody investigates a good number.

The spec is careful to verify exactly this property for the n8n private note (§5, correctly
— `Base::SendOnChannelService#invalid_message?` returns true for `private?`, and
`valid_first_reply?` requires `!private?`; both verified) and then does not apply the same
check to the echo path it leaves Unknown.

Also: if echoes *and* n8n both fire, each Klaviyo send appears twice — once as a visible
outgoing bubble, once as a private note. The echo bubble will not be re-sent to the customer
(`outgoing_message_originated_from_channel?` is true because `source_id` is present —
verified), so there is no double-send, but there is double-display and metric corruption.

Required: add "echo received for a Klaviyo send" as its own failure-table row with detection
(any `Message` with `content_attributes.external_echo` whose `source_id` was not produced by
Chatwoot) and response (disable n8n mirroring *or* stop the echo subscription — decide which
mirror wins before cutover, not during).

## H3. Detection is entirely point-in-time; there is no continuous monitor for the one thing most likely to change

Every detector in the failure table is an act performed by a human during cutover ("two-app
test", "known-customer cutover test", "raw webhook capture"). The failure the design is
actually exposed to is *Klaviyo re-running their own onboarding six weeks later and
overwriting the phone-level override*. Nothing in the spec would notice.

`Whatsapp::HealthService#health_fields` already requests `webhook_configuration` from
`GET /{phone-number-id}` — the read primitive exists in this checkout.

Required: a scheduled check that reads `webhook_configuration.override_callback_uri` and
compares it to Chatwoot's expected `FRONTEND_URL/webhooks/whatsapp/+66975311301`, alarming
on drift; plus the synthetic-inbound canary from B4. Per this install's observability
posture, both must terminate in the Netdata filecheck heartbeat, not in a log line and not
in Sentry.

## M1. `INACTIVE_WHATSAPP_NUMBERS` is the missing non-destructive kill switch, and Rollback never mentions it

`Webhooks::WhatsappController#inactive_whatsapp_number?` reads the
`INACTIVE_WHATSAPP_NUMBERS` installation config (declared in
`config/installation_config.yml:304`) and rejects matching payloads with `422` before
enqueueing. This is the correct "stop Chatwoot ingesting without touching Meta and without
deleting anything" lever — it makes B1 avoidable.

Rollback should name it as step 1 for the Chatwoot side. Two caveats to record with it:
it matches on the **URL** `:phone_number` param, and it returns a non-2xx to Meta, so
sustained use will accumulate delivery failures against Chatwoot's subscription — it is a
minutes-to-hours brake, not a parking spot.

## M2. Rollback step 4 correctly doubts the Twilio path but gives no pre-verified recovery time

"Do not assume the old Twilio connection remains active after migration" is the right
instinct. But a WhatsApp number migrated away from Twilio to a Meta-hosted WABA is not
re-attachable on a support-incident timescale, and the spec's rollback reads as though it
might be. Recorded UMI context: this number's WhatsApp sender was provisioned through
Twilio Senders precisely because Meta-direct verification fails on a VoIP number
(error 11200) — so the reverse trip is not a formality either.

Required: state the honest worst case in the Rollback section — **once the number is
migrated, there is no fast rollback to Twilio; the rollback for a Meta-side failure is
"support is down on WhatsApp until Meta/Klaviyo fix it"**. Then decide in advance what the
substitute channel is (LINE inbox, the Twilio voice line, a website widget banner) and put
*that* in the runbook. A rollback plan whose fastest branch is measured in days needs a
stated fallback, otherwise the gate is being called green against an outage with no floor.

## M3. §3's proposed regression test is weaker than the property it claims to pin

The example asserts `not_to change(Message, :count)` and `not_to raise_error`, calling
`described_class.new(...).perform` twice. It does not pin the operationally important half —
that this stays a **non-retrying, non-erroring** path. A future change that logs the unknown
status via a call that can raise would still pass this test if the raise happened outside the
service. The spec's own prose ("A future change to log or meter this case must not turn it
into a retrying exception path") is the real requirement; the test should therefore exercise
`Webhooks::WhatsappEventsJob` and assert the job completes, not just the service.

Minor: the two `expect` blocks re-run `perform` on the same payload, so the second block's
`not_to raise_error` is also incidentally an idempotency assertion — fine, but say so, and
add the `Conversation`/`Contact` count assertions the surrounding prose already calls for.

---

## What the spec gets right (do not weaken these)

* Refusing to migrate before §1's Unknown is resolved, and defining "any ambiguity is not
  safe". This is the correct default and survives review.
* Requiring the two-app test on **disposable** assets, in **both write orders**, with real
  inbound. Both-orders is the detail most such plans omit.
* §3, §4, §5 code readings — all re-derived and correct. In particular §5's chain
  (`Base::SendOnChannelService#invalid_message?` → `message.private?`; `valid_first_reply?`
  → `!private?`) is exactly right, and the n8n contract (private note, `sender: nil`,
  idempotent on the Klaviyo event ID, never a send endpoint) is the right shape.
* Refusing to fake `source: 'embedded_signup'` to dodge registration. That shortcut would
  have silently turned on signature verification requirements and changed teardown and
  reauth behavior at the same time — the spec is right to forbid it for reasons beyond the
  one it gives.
* Keeping inbox 6 and accepting two inbox histories rather than attempting a merge.

## Consolidated additions required before the gate can be called green

Gate (pre-migration):
1. B2 negative signature test (bad signature ⇒ 401).
2. B3 capacity number from Klaviyo + `low`-queue latency alarm live.
3. B6 pre-existing `Channel::Whatsapp` row check for `+66975311301` returns empty.
4. B6 token-scope check: `/{waba}/message_templates` and `/{waba}/phone_numbers` readable.
5. H1 guard test asserts zero `register_phone_number` **and** zero
   `clear_phone_number_callback_override` on the foreign-number path.
6. M2 substitute support channel named, and the "no fast Twilio rollback" fact acknowledged
   in writing by the halt owner.

Gate (post-migration, pre-activation — new boundary per B5):
7. Final `business_account_id` / `phone_number_id` re-read from Graph and written into
   Chatwoot config; `display_phone_number` string round-trips to the stored `phone_number`.
8. `GET /{phone-number-id}?fields=webhook_configuration` read back after channel creation.
9. Reauthorization banner absent / no `whatsapp_disconnect` email received.

Standing (post-cutover):
10. H3 override-drift monitor + B4 synthetic-inbound canary, both terminating in the Netdata
    heartbeat.
11. H2 echo-detection rule and a decision on which mirror wins.

Rollback edits:
12. `INACTIVE_WHATSAPP_NUMBERS` as the first, non-destructive stop (M1).
13. Explicit prohibition on deleting the Cloud channel/inbox as a rollback step, with the
    `before_destroy` reason stated (B1).
14. Honest statement of the no-fast-rollback worst case and the substitute channel (M2).

## Verification note

All code claims above were read from this checkout: `app/models/channel/whatsapp.rb`,
`app/services/whatsapp/webhook_setup_service.rb`,
`app/services/whatsapp/webhook_teardown_service.rb`,
`app/services/whatsapp/facebook_api_client.rb`,
`app/services/whatsapp/health_service.rb`,
`app/services/whatsapp/providers/whatsapp_cloud_service.rb`,
`app/services/whatsapp/incoming_message_base_service.rb`,
`app/jobs/webhooks/whatsapp_events_job.rb`,
`app/jobs/channels/whatsapp/templates_sync_scheduler_job.rb`,
`app/controllers/webhooks/whatsapp_controller.rb`,
`app/controllers/concerns/meta_token_verify_concern.rb`,
`app/models/concerns/reauthorizable.rb`, `app/models/message.rb`,
`app/models/channel/twilio_sms.rb`, `config/sidekiq.yml`,
`config/installation_config.yml`, `config/routes.rb`.

No Meta API call, no production query, and no repo file outside this document were made or
modified. Claims about Meta's own semantics (registration side effects in H1, number
migration changing `phone_number_id` in B5, Twilio re-attachment in M2) are **not** verified
against the live platform and inherit the spec's own Unknown — they are stated as risks the
gate must retire, not as facts.
