# Security / privacy review — UMI shared WhatsApp number spec

Reviewed: `docs/UMI-SHARED-NUMBER-SPEC.md` (2026-08-18)
Reviewer lens: tokens & credentials, callback verification, n8n private-note identity
and idempotency, cross-app trust, destructive rollback actions, data integrity.
Method: read the spec, then verified each code-level claim against this checkout
(branch `umi-shared-number-spike`). No repo files other than this report were changed;
no live Meta, Klaviyo, Twilio, or n8n asset was touched.

Verdict: the spec's Meta-side risk analysis (§1, §2, §6) is sound and the migration
gate is the right shape. The gaps are on the **Chatwoot side of the trust boundary**:
the spec treats Chatwoot as the party that might be harmed by Meta's routing, and
never analyses what Chatwoot itself does *to the shared asset* or what it accepts
*from an unauthenticated caller*. Four blockers below must land in the gate before
any production channel is created.

---

## Blockers

### S1. The inbound webhook is unauthenticated on exactly the channel shape this spec proposes

`app/controllers/webhooks/whatsapp_controller.rb:37-42`:

```ruby
def meta_signature_verification_required?
  return true if whatsapp_channel.blank?
  return false unless whatsapp_channel.provider == 'whatsapp_cloud'
  return true if channel_meta_app_secrets(whatsapp_channel).present?

  whatsapp_channel.provider_config['source'] == 'embedded_signup'
end
```

The spec's channel is `whatsapp_cloud`, manually configured, **not** `embedded_signup`
(§2 — that is the whole point of the foreign-number mode). Unless
`provider_config` carries one of `app_secret`, `app_secret_key`, `client_secret`,
`api_secret` (`MetaTokenVerifyConcern::CHANNEL_APP_SECRET_KEYS`),
`verify_meta_signature!` returns immediately and **`X-Hub-Signature-256` is never
checked**. The global `WHATSAPP_APP_SECRET` in `meta_app_secrets` is unreachable in
that case, because the required? check short-circuits first.

The route is `POST /webhooks/whatsapp/:phone_number` (`config/routes.rb:644`) and the
path segment is the public E.164 number. Anyone who knows `+66975311301` can POST a
forged `whatsapp_business_account` envelope and have
`Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash)` create contacts,
conversations, and inbound messages attributed to any customer phone number — and can
forge `statuses` to flip a real Chatwoot message to `failed`/`read`. Today's Twilio
inbox 6 does not have this exposure; the migration introduces it. Sharing the number
with Klaviyo raises the impact: the endpoint becomes a way to inject fake customer
intent into a support queue that now also drives marketing consequences.

Required before the gate:

* Set the Meta app secret in the Chatwoot channel's `provider_config` (`app_secret`)
  so `meta_signature_verification_required?` returns true, and prove it by replaying a
  captured payload with a bad signature and asserting `401` and zero enqueued jobs.
* Add that assertion as a gate item and a spec — "manual foreign-owned Cloud channel
  rejects unsigned webhooks" — not as a deployment note. The current default is
  fail-open, so a config typo silently reopens the hole with no error anywhere.
* Note in the spec that the verify-token GET path (`valid_token?`, controller line 19)
  compares with `==`, not `ActiveSupport::SecurityUtils.secure_compare`, unlike the
  signature path. Low severity (32-hex token, one-shot verification), worth recording.

### S2. Deleting the Chatwoot inbox mutates Klaviyo's phone number — the spec's rollback does not know this

`Channel::Whatsapp` (`app/models/channel/whatsapp.rb:37`) has
`before_destroy :teardown_webhooks`, and `Inbox` has
`belongs_to :channel, polymorphic: true, dependent: :destroy`
(`app/models/inbox.rb:61`). So the ordinary "Delete inbox" action —
`DeleteObjectJob` → `inbox.destroy!` → channel destroy → `WebhookTeardownService` —
runs, for **any** `whatsapp_cloud` channel with an api_key and a phone_number_id:

```ruby
api_client.clear_phone_number_callback_override(phone_number_id)  # POST override_callback_uri: ''
```

`Whatsapp::WebhookTeardownService#clear_phone_number_override` is *not* gated on
`source == 'embedded_signup'`; only the WABA-level `unsubscribe_app_from_waba` is.
The teardown comment even states the reasoning for the WABA gate ("a manual token's
subscribed app is the customer's, not ours to unsubscribe") — the phone-level call was
never given the same guard.

This is the mirror image of the §1 Unknown. §1 asks "can the other app's write blow
away ours?" The unasked question is "does *our* delete blow away theirs?" If the
phone-level override is a single global property — the unsafe branch the spec is
testing for — then deleting the Chatwoot inbox clears the override for the number and
can dark-route Klaviyo's inbound as well. Every error in that path is swallowed into
`Rails.logger.error` (`webhook_teardown_service.rb:12`), and per this install's
observability posture there is no Sentry and nothing watches those lines, so the
operator sees a successful inbox delete and no signal at all.

The spec's rollback §3 says "do not delete the channel or inbox until its
data-retention impact is reviewed" — framed purely as Chatwoot-side data loss. It must
be restated as: **deleting the Chatwoot channel/inbox performs a write against the
shared Meta phone number and can break the other tenant.** Add to rollback and to the
runbook freeze list: never delete the Cloud channel/inbox as a rollback step; disable
it instead (deactivate, or add the number to `INACTIVE_WHATSAPP_NUMBERS`, which the
controller honours at `whatsapp_controller.rb:7-11`). If a delete is ever genuinely
needed, clear `provider_config['phone_number_id']` first so the teardown no-ops, and
confirm with Klaviyo before and after.

### S3. Runtime paths beyond channel creation rewrite the shared phone override

The spec's §2 patch targets exactly one entry point — the after-create
`should_auto_setup_webhooks?` → `WebhookSetupService#perform`. Three other paths reach
Meta on the shared asset and are not covered:

* `Channel::Whatsapp#enable_voice_calling!` (line 82) and `#disable_voice_calling!`
  (line 93) both call `webhook_setup_service.register_callback`, which re-POSTs
  `override_callback_uri` on the shared `phone_number_id` and re-POSTs
  `/{waba-id}/subscribed_apps` with a recomputed `subscribed_fields`. An admin
  toggling voice on the inbox is a last-writer-wins event against Klaviyo's routing.
  The voice toggles are reachable from the UI (`config/routes.rb:285-286`).
* `WebhookSetupService#calls_enabled_on_waba?` (setup service line 78) queries
  *sibling channels on the same WABA* and rewrites the shared app subscription
  accordingly — cross-inbox coupling that now spans a WABA UMI does not own.
* `Channel::Whatsapp` `validate_provider_config` and `after_create :sync_templates`
  make Graph calls against Klaviyo's WABA on every save/create. Not destructive, but it
  is UMI's token pulling Klaviyo's template inventory, and it contributes to a shared
  rate-limit budget (this install has already had a Shopify 429 storm from an N+1 —
  same failure shape).

Gate items 3 and 5 should be widened from "no `/register` call" to "no unrequested
write to `/{phone-number-id}` or `/{waba-id}/subscribed_apps` from any path", with the
guard test asserting on the API client methods, not just `register_phone_number`.

### S4. The n8n private-note contract is not implementable as written, and its identity is unspecified

§5 specifies the note as `private: true`, `sender: nil`. Via the documented API path
that is impossible: `Api::V1::Accounts::Conversations::MessagesController#create` sets
`user = Current.user || @resource` and `Messages::MessageBuilder#sender` resolves
outgoing messages to `message_sender || @user`
(`app/builders/messages/message_builder.rb:135-141`). The note is therefore always
attributed to whatever principal n8n's credential represents. Consequences:

* If n8n uses a human agent's access token, every Klaviyo marketing message appears in
  the timeline authored by that person, and n8n holds that human's full account
  privileges — a token that can read every conversation and send customer-facing
  messages, held by an automation whose only need is "append one note".
* The spec never says which credential n8n uses, where it is stored, or how it is
  rotated. That is the single highest-privilege secret in this design and it is absent
  from the gate.

Fix the contract to: a dedicated `AgentBot` (pass `sender_type: 'AgentBot'` +
`sender_id`, the only branch `message_sender` honours) or a dedicated bot user with
the narrowest workable role, its token stored in n8n's credential store, rotated on
staff change, and recorded in gate item 7. Also note that
`AgentBot.where(account_id: [nil, account.id])` accepts global bots — pin the bot to
UMI's account.

Idempotency is likewise under-specified. There is **no unique index on
`messages.source_id`** — `db/schema.rb:1172` is a plain index; the unique
`(inbox_id, source_id)` index at line 715 is on `contact_inboxes`, not messages. So
"idempotent on the Klaviyo event ID" can only be a read-then-write in n8n, which is
racy exactly when it matters (n8n's own timeout-retry firing while the first request is
still in flight → two notes). Either accept and document at-least-once with a
dedup pass, or make the workflow serialize per conversation. Do not describe it as
idempotent without a mechanism.

---

## Significant, non-blocking

### S5. Private notes are not private to Chatwoot — they fan out to webhooks, Slack, and bots

§5 concludes the note is safe because it never reaches the WhatsApp channel. That is
correct (`Base::SendOnChannelService#invalid_message?` returns true for
`message.private?`, verified) but it is not the whole data-flow. A private note is
still `outgoing`, and:

* `Message#webhook_sendable?` is `incoming? || outgoing? || template?`
  (`app/models/concerns/message_filter_helpers.rb:8`) — so `WebhookListener#message_created`
  delivers the full note content to every account/inbox webhook, flagged `is_private: true`
  but with `content` intact.
* `slack_hook_sendable?` is the same predicate; `HookListener` → `HookJob` →
  `SendOnSlackJob` → `Integrations::Slack::SendOnSlackService` posts it to the Slack
  channel with a literal `private: ` prefix (`lib/integrations/slack/send_on_slack_service.rb:50`).
* `AgentBotListener#message_created` uses `webhook_sendable?` too, so any agent bot URL
  receives it. `HookJob` also fans out to Dialogflow / Google Translate / Linear /
  LeadSquared if those integrations are enabled.

So enabling the mirror copies Klaviyo's marketing content — and, per campaign, the
implicit fact that a given customer was targeted — into every third-party endpoint
already wired to this account. Add an inventory of enabled hooks/webhooks to the gate
and a decision on whether that propagation is acceptable, per integration.

### S6. Fail-open default on `private`

`Messages::MessageBuilder` does `@private = params[:private] || false`. If n8n's
payload omits the field (template edit, JSON path change, partial expression failure),
the note becomes a **public outgoing message** and `SendOnWhatsappService` sends it: as
free-form text inside the 24h window, or as a template attempt (and a `failed` message)
outside it. The blast radius of one missing key is "marketing copy delivered twice to
the customer, from the support inbox." The spec's mitigation is a table row
("Private note is accidentally public or sent → disable n8n immediately"), i.e.
detection after the fact. Prefer prevention: assert `private == true` in the n8n
request and, if this is worth engineering at all, a guard that rejects
non-private outgoing messages carrying the Klaviyo metadata marker.

### S7. Only the first status in a batch is processed — a real data-integrity loss once Klaviyo shares the number

§3 concludes the unknown-status case is a clean no-op. Verified — but the code is
narrower than the spec's description implies:

```ruby
def process_statuses
  status = @processed_params[:statuses].first
  return unless find_message_by_source_id(status[:id])
```

Meta batches `statuses` as an array. Chatwoot reads only `[0]` and discards the rest,
so a batch whose first entry is a Klaviyo-only message ID causes **every other status
in that batch to be dropped**, including delivery/read/failed for genuine Chatwoot
agent replies. Today, with a Chatwoot-only number, misses are rare; adding a
high-volume marketing sender to the same number makes mixed batches routine and turns
a latent upstream bug into a systematic reporting gap. The proposed regression test in
§3 should be extended to a batch payload `[klaviyo_status, chatwoot_status]` asserting
the Chatwoot message *is* updated — it will fail against current code, which is the
useful outcome.

### S8. Token scoping and handling

Gate item 2 says Chatwoot gets "a system-user token scoped only to the intended
WABA/phone." Two additions:

* Record the token's expiry/rotation owner. `provider_config['api_key']` is stored in
  plaintext JSONB and is used by `WebhookTeardownService` at delete time (S2) and by
  every send — a stale or over-scoped token on a WABA UMI does not own is a
  cross-tenant liability, not just an outage.
* `WebhookSetupService#store_pin` writes a 6-digit `verification_pin` into
  `provider_config` and `@channel.save!`. On the foreign-number path that PIN must
  never be generated at all (it is Klaviyo's two-step-verification PIN namespace);
  the no-registration mode should assert `provider_config['verification_pin']` stays
  absent.
* The §1.1 experiment exports `TOKEN_A`/`TOKEN_B` into a shell. Add: use a shell that
  does not persist history for that session, and confirm the throwaway system users are
  deleted after the test — otherwise two long-lived WABA-scoped tokens survive on
  disposable assets nobody owns.

### S9. Spec-internal inconsistencies

* Three references to "§4.1" (lines 11, 267, 365) point at a section that does not
  exist; the two-app experiment is §1.1. A gate that cites a missing section is a gate
  people skip.
* §2 says registration is reached when "verification failure returns false; health
  failure returns false for 'needs registration'". Verified accurate against
  `webhook_setup_service.rb:15` and both rescue blocks — worth keeping the exact line
  reference in the spec so a rebase onto a new upstream tag can re-check it.
* §6's claim that the checkout subscribes `messages smb_message_echoes` is accurate
  (`Whatsapp::FacebookApiClient::WEBHOOK_DEFAULT_FIELDS`), but `WebhookSetupService`
  recomputes the list and may add `calls`. Worth stating, because it is a third value
  that gets written to the shared subscription (see S3).

---

## Suggested additions to the pre-migration gate

9. The production Cloud channel's `provider_config` contains a Meta `app_secret`, and a
   replayed webhook with an invalid `X-Hub-Signature-256` is rejected with 401 and
   enqueues no job. (S1)
10. Written, tested confirmation that no rollback or cleanup step deletes the Cloud
    channel or inbox; deactivation is used instead. A staging test proves that
    destroying such a channel would POST `override_callback_uri: ''` — so the team has
    seen the behaviour before production. (S2)
11. Voice calling toggles are locked out on the shared-number inbox for the duration of
    the migration, and the no-write guard test covers `override_phone_number_callback`,
    `subscribe_app_to_waba`, and `clear_phone_number_callback_override` — not only
    `register_phone_number`. (S3)
12. n8n's identity is a dedicated AgentBot/bot user pinned to UMI's account, with its
    credential stored in n8n and an owner named for rotation; the note contract is
    updated so `sender: nil` is replaced by that bot. (S4)
13. An inventory of enabled account/inbox webhooks, Slack, and bot integrations, with
    an explicit accept/deny decision on Klaviyo content reaching each. (S5)
14. The §3 regression test is extended to a multi-status batch asserting the Chatwoot
    message's status is still applied. (S7)

## Verification notes

Claims checked against the checkout and found accurate as written: §1's description of
`subscribe_phone_number_webhook`, §2's Chatwoot call graph and swallowed registration
error, §3's status no-op, §4's `display_phone_number` + `phone_number_id` channel
lookup, §5's `invalid_message?` / `valid_first_reply?` / `update_waiting_since`
behaviour for private notes, §6's `smb_message_echoes` handling. Nothing in the spec
was found to be factually wrong about the code it cites; the findings above are things
the spec does not cover.

Not verified here (unchanged from the spec's own confidence statement): Meta's
phone-override scoping, `message_echoes` emission semantics, and the actual n8n
workflow definition — the last of which should be read before gate item 7 is signed.
