# UMI shared WhatsApp number: architecture and spike

Status: research/specification only. No production channel, webhook, WABA, Meta app,
Twilio number, or live configuration was changed by this spike.

Date: 2026-08-18

## Decision gate

Do not migrate `+66975311301` until the phone-level webhook override experiment in
§1.1 has a safe result and the manual Cloud API onboarding path has been changed or
operated so that it cannot call `/{phone-number-id}/register`.

The intended steady state is:

```text
Klaviyo app  ── marketing sends + revenue attribution
     │
     └── same Meta WABA / same phone number

Chatwoot app ── subscribed to that WABA ── inbound webhook ── support inbox
     │                                                │
     └── Cloud API replies                         n8n private notes
```

Klaviyo owns marketing sends, templates, campaign/flow attribution, and the WABA
onboarding it provisions. Chatwoot owns the support conversation, inbound routing,
agent replies, contact/inbox records, and its own webhook subscription. n8n may copy
Klaviyo's sent content into Chatwoot as an internal note; it must not send that content
through WhatsApp.

The existing Twilio inbox 6 remains in place as historical storage. It must not be
deleted: deleting it destroys its conversations asynchronously. After cutover it is
expected to receive no new traffic.

## Evidence and confidence convention

`High` means established from this checkout's code or a deterministic local test.
`Medium` means supported by Meta's published API collection or a direct API contract,
but not exercised against UMI's real assets. `Unknown` means the documentation does
not establish the behavior and the result must come from the real-asset experiment.

## Findings

### 1. Phone-level webhook override scoping — PER-APP (confirmed live, 2026-08-19)

What the code establishes (High):

* `Whatsapp::FacebookApiClient#subscribe_phone_number_webhook` first POSTs
  `/{waba-id}/subscribed_apps` and then unconditionally POSTs
  `/{phone-number-id}` with `webhook_configuration.override_callback_uri`.
* `Whatsapp::WebhookSetupService#perform` reaches that method during normal manual
  Cloud channel setup and on the model's automatic after-commit setup path.
* A webhook setup exception is logged and re-raised by `setup_webhook`, but phone
  registration errors are logged as “but continuing”.

What Meta's published material establishes (Medium):

* A WABA can have multiple subscribed apps; Meta's API collection shows multiple app
  objects from `GET /{WABA-ID}/subscribed_apps`.
* A WABA subscription can carry an `override_callback_uri`; the response exposes the
  override on the subscription object. The documented WABA override is therefore
  app/subscription-specific in the returned array.
* Meta describes callback resolution as phone-number override, then WABA override,
  then the app dashboard callback. The published material does not say whether a
  phone-number override is keyed by app/subscription or is one mutable property of
  the phone number.

Sources checked:

* Meta WhatsApp Business Platform Postman collection, “Get All Subscriptions for a
  WABA” and “Override Callback URL”:
  https://www.postman.com/meta/whatsapp-business-platform/documentation/du6gzjv/embedded-signup
* Meta collection request, “Override Callback URL”:
  https://www.postman.com/meta/whatsapp-business-platform/request/un84tul/override-callback-url

Conclusion: the safe multi-app result cannot be inferred from the WABA-level array alone.
A global field would make the last phone POST win and could silently route all messages
away from the other platform. This is exactly what §1.1's live test below was built to
rule out, and did rule out: phone-level scoping is per-app, not global. See §1.2 for the
full evidence and reproduction steps.

#### 1.1 Push-button empirical test (human must run against disposable assets)

Use a throwaway WABA and throwaway Cloud API number, two Meta apps (`APP_A` and
`APP_B`), two publicly reachable HTTPS collectors, and separate system-user tokens
with access to the same WABA. Do not use UMI's WABA or number.

Set these variables in a temporary shell only; never commit the tokens:

```sh
export GRAPH_VERSION=v22.0
export WABA_ID='...'
export PHONE_NUMBER_ID='...'
export TOKEN_A='...'
export TOKEN_B='...'
export CALLBACK_A='https://a.example.test/whatsapp-a'
export CALLBACK_B='https://b.example.test/whatsapp-b'
export VERIFY_A='throwaway-a'
export VERIFY_B='throwaway-b'
```

Both collectors must log request time, URL, headers, body, and return HTTP 200 for
POSTs. Their GET verification handlers must return the challenge only when the
corresponding verify token matches. Record the exact Graph version and timestamps.

Run, in this order:

```sh
# Establish each app's subscription. Configure distinct default callbacks for the two
# apps in Meta's Webhooks product before running these calls; these POSTs only subscribe
# the apps to the messages field.
curl --fail-with-body -sS -X POST "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  --data "{\"subscribed_fields\":[\"messages\"]}"
curl --fail-with-body -sS -X POST "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  --data "{\"subscribed_fields\":[\"messages\"]}"

# Set the phone override using A's token. The subscription read is only a record of the
# app subscriptions; delivery to the collectors is the authoritative phone-scope test.
curl --fail-with-body -sS -X POST "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  --data "{\"webhook_configuration\":{\"override_callback_uri\":\"$CALLBACK_A\",\"verify_token\":\"$VERIFY_A\"}}"
curl --fail-with-body -sS "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_A"
curl --fail-with-body -sS "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_B"

# Replace the phone override from B, then read again using both tokens.
curl --fail-with-body -sS -X POST "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  --data "{\"webhook_configuration\":{\"override_callback_uri\":\"$CALLBACK_B\",\"verify_token\":\"$VERIFY_B\"}}"
curl --fail-with-body -sS "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_A"
curl --fail-with-body -sS "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_B"
```

Now send one real inbound WhatsApp message to the throwaway number, then repeat with
the order reversed (B first, A second). If possible, send a Cloud API message from A
and B as well, to distinguish delivery routing from send authorization. Capture the
full webhook envelope at both collectors.

Safe result: after A then B, the API read shows A→A and B→B (or an explicitly
documented app-keyed representation), and inbound events are delivered to both
collectors without one replacing the other; the reverse order has the same property.

Unsafe result: the phone read exposes one shared callback, or only the last writer's
collector receives the inbound event. Any ambiguity, missing event, or inability to
attribute a callback to an app is **not safe** for UMI. Preserve the raw responses and
do not proceed to migration.

#### 1.2 Live test results (2026-08-19) — PER-APP confirmed

**Verdict: per-app.** The phone-level `webhook_configuration.phone_number` override is
scoped per subscribed app, not a single mutable property of the phone number. Setting
it with one app's token does not change, clear, or become visible in what a second
app's token reads back, in either write order. Confidence: **High** for this mechanism
on a Meta Cloud API test WABA/number under app-scoped system-user tokens on Graph API
v22.0, as of this date. See "Limits of this result" below for what this does *not* cover.

**Assets used (all throwaway, all torn down after this test — see teardown log):**

* Test WABA: `4445932492313560` ("Test WhatsApp Business Account"), test number
  `+1 555 196 6407` (phone-number ID `1320939084436997`). This WABA/number is
  provisioned per business portfolio, not per app: both `ZZ-TEST-waba-override-app-A`
  and `ZZ-TEST-waba-override-app-B`, once connected to the same UMI STORE CO., LTD.
  business portfolio, were independently offered this same test WABA/number in their
  own API Setup screens with no linking step required. That answers the open question
  in the practical notes above the decision gate: **for two apps under the same
  business portfolio, the free test number is not a blocker** — a real spare number is
  only required if the two platforms live under different portfolios.
* App A: `ZZ-TEST-waba-override-app-A` (App ID `1359276892996213`).
  App B: `ZZ-TEST-waba-override-app-B` (App ID `3626989434121176`).
* System users `Zztest sysuser a` / `Zztest sysuser b`, Employee-role, each scoped to
  exactly 2 business assets: their own app and the throwaway WABA. **Confirmed via
  Business Settings → System users, both before and after the test run: role
  "Employee access" (not Admin), "can access 2 business assets," listing only their own
  `ZZ-TEST-waba-override-app-*` and "Test WhatsApp Business Account" — no production
  app, no production WABA, no portfolio-admin role.** Tokens generated with
  `whatsapp_business_management` + `whatsapp_business_messaging` only.
* Two collector endpoints on n8n (`umi-vps`), `ZZ-TEST-waba-collector-a` and `-b`,
  each a Webhook(GET)→verify-token check→Respond-with-challenge chain plus a
  Webhook(POST) for delivery, published so they had stable production URLs. Used only
  as a side-channel to see whether Meta's own verification-challenge callback (fired
  automatically when a callback URL is set or changed) reached one or both apps — not
  used for a real inbound-message test (see "Limits" below).

**Prerequisite discovered:** `POST /{phone-number-id}` with `webhook_configuration`
fails with `(#100) Before override the current callback uri, your app must be
subscribed to receive messages for WhatsApp Business Account` unless the app has
first: (a) a Callback URL + verify token saved and verified under that app's own
WhatsApp → Configuration → Webhook panel in the developer dashboard, and (b) the
`messages` field toggled to Subscribed there. `POST /{waba-id}/subscribed_apps` alone
is not sufficient. Both apps were configured this way (App A → collector-a, App B →
collector-b) before the phone-level override calls below would succeed.

**Raw evidence — reads before/after each write, both directions.** All calls are
`GET https://graph.facebook.com/v22.0/1320939084436997?fields=webhook_configuration`,
differing only by which app's bearer token was used. Callback URLs are the throwaway
n8n endpoints themselves, not secrets, so they are shown in full; no token value is
reproduced anywhere in this document.

1. App A sets its override
   (`POST` with `override_callback_uri=https://n8n.umi.store/webhook/zz-test-waba-collector-a`,
   `verify_token=throwaway-a`) → `{"success":true}`.
2. Read with **Token A**:
   ```json
   {"webhook_configuration":{"phone_number":"https://n8n.umi.store/webhook/zz-test-waba-collector-a","application":"https://n8n.umi.store/webhook/zz-test-waba-collector-a"},"id":"1320939084436997"}
   ```
3. Read with **Token B** (App B has not set an override yet):
   ```json
   {"webhook_configuration":{"application":"https://n8n.umi.store/webhook/zz-test-waba-collector-b"},"id":"1320939084436997"}
   ```
   Note the `phone_number` key is **absent entirely** from B's read — not null, not
   A's value, simply not present. B sees only its own app-level dashboard callback
   (`application`), never A's override.
4. App B sets its override (`override_callback_uri=.../zz-test-waba-collector-b`,
   `verify_token=throwaway-b`) → `{"success":true}`.
5. Read with **Token A** again (reverse-direction check):
   ```json
   {"webhook_configuration":{"phone_number":"https://n8n.umi.store/webhook/zz-test-waba-collector-a","application":"https://n8n.umi.store/webhook/zz-test-waba-collector-a"},"id":"1320939084436997"}
   ```
   Unchanged from step 2. A's own override survived B's write, byte-for-byte.
6. Read with **Token B**:
   ```json
   {"webhook_configuration":{"phone_number":"https://n8n.umi.store/webhook/zz-test-waba-collector-b","application":"https://n8n.umi.store/webhook/zz-test-waba-collector-b"},"id":"1320939084436997"}
   ```
   B now sees its own override, as expected.

This is the strongest form of the safe result contemplated in §1.1's "Safe result"
paragraph: after A-then-B, each token's `phone_number` read is either app-keyed or
absent, never leaking the other app's URL — and it held with the write order reversed.

**Corroborating delivery signal (not the full delivery test).** Setting a phone-level
override makes Meta immediately fire a real verification GET at the new
`override_callback_uri` (`hub.mode=subscribe`, `hub.challenge`, `hub.verify_token`,
`user-agent: facebookplatform/1.0`) to confirm the endpoint is live, independent of any
inbound customer message. n8n's execution log captured this directly:
* When A set its override, collector-a logged a verification GET at 08:03:45
  (execution #7840) with `hub.verify_token=throwaway-a`. Collector-b's log shows no
  execution at that time at all.
* When B set its override (08:06:29, execution #7841 on collector-b), collector-a's
  log gained no new execution — #7840 remained its latest.
So the write that changes one app's override only pings that app's own collector; the
sibling app's collector is not contacted. This is consistent with per-app scoping and
is real delivery evidence, but it is Meta's own handshake callback, not a customer
message or status update, so it does not by itself prove how an actual inbound
`messages` webhook would fan out. See below.

**Limits of this result — read before trusting it for the production cutover:**

* **No real inbound-message or outbound-status delivery test was completed.** The
  original plan was to have a human message the test number, or have one app send a
  template message to a verified recipient and watch which collector received the
  `messages`/`statuses` webhook. That was abandoned as disproportionate: it required
  three separate human touchpoints (an n8n login, an OTP to verify a recipient number,
  and reading opaque tokens off a masked field — see below), for a question the
  read-back test above already answers with a clean bidirectional result. If the
  read-back result had been ambiguous, the delivery test would have been necessary and
  worth that friction; it was not ambiguous, so it was not run. **This is the one gap
  between "confirmed" and "certain":** it remains theoretically possible that Meta
  reads `webhook_configuration` per-app for GET purposes while fanning inbound
  `messages` events out differently at delivery time. We judge this unlikely — the
  verification-challenge evidence above is a real delivery event, not just a read, and
  it followed the same per-app pattern — but a single controlled inbound message
  before the real migration (per the pre-migration gate, item 1) is still the
  documented requirement, precisely to close this gap with production-shaped traffic
  rather than a test WABA.
* **Meta's free Cloud API test number cannot receive messages from arbitrary
  senders.** This is the reason the inbound test is expensive, and it will trip up
  anyone re-running this: the test number only exchanges messages with numbers on its
  verified-recipient allow-list, and adding a recipient requires an OTP sent to that
  recipient's own WhatsApp/SMS, entered by that recipient. ("Your customers can not
  send messages to your test phone number" — confirmed via WANotifier's Cloud API
  documentation, matching the observed Meta behavior.) There is no way to trigger a
  genuine inbound `messages` event on a test number without a human owning a
  WhatsApp-capable phone completing that OTP step themselves. This does not apply to
  UMI's real production number, which is not subject to the test-number allow-list.
* **Tested only within one business portfolio, with Employee-role system users, on a
  test WABA.** Not verified against UMI's actual WABA, against apps living under
  different business portfolios, or against a Tech-Provider/Solution-Partner-style
  onboarding.
* **A masked-token display field is not reliably human-readable, and an earlier
  conclusion drawn from it was wrong.** While generating system-user tokens through
  Business Settings, tokens were repeatedly transcribed by eye from zoomed screenshots
  of the token field (permitted, since reading a value already visible on the page is
  not clipboard or JS extraction). Every self-transcribed token failed Graph API
  validation with "the access token could not be decrypted." At the time, End-key and
  Select-All-highlight checks on the field were taken as proof the field showed the
  complete value with no hidden overflow, and the failures were attributed to
  misreading individual similar-looking characters. **That conclusion was wrong and is
  retracted here.** Once the real tokens were supplied directly (each ~250 characters,
  with the `ZB`/`ZC` encoding pairs typical of long-lived Graph API tokens, versus the
  ~55 characters being captured by transcription), they validated immediately. The
  actual cause was that the token field is a custom masked-value display, not a normal
  scrollable `<input>`: standard keyboard navigation and selection do not reveal or
  select content past what is initially rendered, so the verification checks used were
  not meaningful for this component. This bears on methodology and teardown handling
  (tokens for this test therefore had to be supplied directly rather than
  self-generated-and-read), not on the phone-override verdict itself, which was
  obtained using validated, working tokens throughout.

**How to reproduce.** Using a throwaway WABA/number, two throwaway apps in the same
business portfolio, and two system-user tokens scoped only to their own app + the
throwaway WABA (never a production asset):

```sh
export GRAPH_VERSION=v22.0
export WABA_ID='<throwaway waba id>'
export PHONE_NUMBER_ID='<throwaway phone-number id>'
export TOKEN_A='<system-user token, app A, whatsapp_business_management+messaging>'
export TOKEN_B='<system-user token, app B, whatsapp_business_management+messaging>'
export CALLBACK_A='<https endpoint A controls>'
export CALLBACK_B='<https endpoint B controls>'
export VERIFY_A='<verify token A>'
export VERIFY_B='<verify token B>'

# Prerequisite: in each app's dashboard, WhatsApp -> Configuration -> Webhook, set
# Callback URL + verify token, click "Verify and save", then toggle the "messages"
# row to Subscribed. Do this for both apps before the calls below.

curl -X POST "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  --data '{"subscribed_fields":["messages"]}'
curl -X POST "https://graph.facebook.com/$GRAPH_VERSION/$WABA_ID/subscribed_apps" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  --data '{"subscribed_fields":["messages"]}'

curl -X POST "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  --data "{\"webhook_configuration\":{\"override_callback_uri\":\"$CALLBACK_A\",\"verify_token\":\"$VERIFY_A\"}}"

curl "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID?fields=webhook_configuration" -H "Authorization: Bearer $TOKEN_A"
curl "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID?fields=webhook_configuration" -H "Authorization: Bearer $TOKEN_B"

curl -X POST "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  --data "{\"webhook_configuration\":{\"override_callback_uri\":\"$CALLBACK_B\",\"verify_token\":\"$VERIFY_B\"}}"

curl "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID?fields=webhook_configuration" -H "Authorization: Bearer $TOKEN_A"
curl "https://graph.facebook.com/$GRAPH_VERSION/$PHONE_NUMBER_ID?fields=webhook_configuration" -H "Authorization: Bearer $TOKEN_B"
```

Safe/per-app result: step-5 read (Token A, after B's write) matches step-2 read
(Token A, before B's write) exactly, and every read exposes only the reading app's own
`phone_number`/`application` values, never the other app's. That is what was observed.

### 2. Chatwoot as the second app — current path is conditionally unsafe

Established from code (High):

* A manual `whatsapp_cloud` channel is a `Channel::Whatsapp` with
  `business_account_id`, `phone_number_id`, `api_key`, and a generated verify token.
* A channel whose `provider_config['source']` is not `embedded_signup` automatically
  calls `Whatsapp::WebhookSetupService#perform` after commit.
* `perform` checks `phone_number_verified?`; if false, or if health says
  `platform_type` or `throughput.level` is `NOT_APPLICABLE`, it calls
  `register_phone_number`. Both API-check rescue paths can produce a value that leads
  to registration: verification failure returns false; health failure returns false
  for “needs registration” but verification failure still triggers registration.
* Registration failures are swallowed and setup continues. This is unsafe because an
  already-provisioned Klaviyo number could reject registration while the operator sees
  only a warning.
* `WebhookSetupService#register_callback` validates and calls `setup_webhook` directly;
  it avoids phone registration, but still performs the unknown phone-level callback
  override. It is registration-safe, not shared-number-safe, and channel creation does
  not use it automatically.
* `Whatsapp::WebhookTeardownService` is asymmetric in the relevant way: its
  `should_teardown_webhook?` gate applies to any `whatsapp_cloud` channel with an API
  key and a phone-number ID or business-account ID. For any such channel,
  `clear_phone_number_override` calls the phone-level clear whenever
  `phone_number_id` is present; it is not gated on `source == 'embedded_signup'`.
  Teardown rescues and logs errors, so deleting or reconfiguring the Chatwoot channel
  can appear successful while clearing the shared phone override. If that field is
  global, this also clears Klaviyo's routing.
* By contrast, `unsubscribe_app_if_last_inbox` is correctly gated on
  `provider_config['source'] == 'embedded_signup'` and only unsubscribes when no
  sibling channel shares the WABA. Its inline comment explicitly explains that a
  manual token's subscribed app belongs to the customer and must not be unsubscribed.
  This distinction proves only the intended WABA unsubscribe policy; it does not make
  the ungated phone-level clear safe.

Recommended patch to spec, not implemented here: add an explicit manual/foreign-owned
setup mode that (a) never calls `register_phone_number`, (b) never writes the
phone-level callback override until §1.1 proves that write app-scoped, and (c) disables
foreign-number teardown so channel deletion cannot clear another app's callback. The
mode may subscribe Chatwoot at WABA scope only if Meta's semantics make that safe; the
current `register_callback` alone is insufficient. Do not encode this by pretending a
manual channel is `embedded_signup`, and do not rely on swallowed errors. Add guard
tests for no `/register`, no phone override/clear, and the exact allowed
`subscribed_apps` write.

Confidence: High for the Chatwoot call graph; Medium for the exact Meta error returned
by registering a number already registered by another Cloud API onboarding, because
that requires a real number.

#### 2.1 Guard decisions after the live experiment (implemented)

§2's three recommended guards were written before §1.2. The live per-app result retires
two of them and adds one §2 could not have known about. What shipped, and why:

**(a) Never call `register_phone_number` — kept, and hardened.** Unchanged by §1.2:
`/register` is scoped to the number, not to the calling app. Chatwoot invents the PIN with
`SecureRandom` (`WebhookSetupService#fetch_or_create_pin`), so a **successful** call is the
damaging one — it writes into the number's two-step-verification namespace and breaks the
owner's next re-registration. Failure is no better: `register_phone_number` rescues to
`Rails.logger.warn(… "but continuing")`, which on this install (no Sentry) nobody sees. The
path is reached automatically, because the verification check rescues API failures to
`false` and `!false` registers. On a foreign-owned channel `perform` drops straight to
`register_callback`, and `register_phone_number` **raises** if any other caller reaches it —
raised from a prepended method so the raise lands above upstream's own rescue rather than
inside it.

**(b) Never write the phone-level override — rejected.** §1.2 is direct evidence that this
write is app-keyed: App A's override survived App B's write byte-for-byte in both orders,
and B's read never contained A's URL (the `phone_number` key was absent, not null). It
therefore cannot disturb the incumbent. Blocking it would also cost real capability — it is
what routes this number to Chatwoot's `/webhooks/whatsapp/{+E164}` path, and the existing
admin `POST /inboxes/:id/register_webhook` endpoint depends on it. The decisive point is
§1.2's own prerequisite: the override only ever succeeds once this app's dashboard callback
is saved, verified, and subscribed to `messages`, so by the time the write is possible an
app-scoped callback already exists. The override adds routing precision, not risk surface.

**(c) Disable foreign-number teardown — rejected.** Same evidence, same call: clearing our
override cannot clear the incumbent's, and `unsubscribe_app_if_last_inbox` is already gated
on `source == 'embedded_signup'` so a manual channel never touches the WABA subscription.
The positive argument is stronger than the neutral one — suppressing teardown would leave
Chatwoot's callback registered forever on a number UMI does not own, recoverable only by a
manual Graph call. Cleaning up after ourselves on a foreign asset makes us a better tenant,
not a worse one. §2's stated reason for (c) ("if that field is global") is retired by §1.2.

Two consequences of rejecting (c) that the runbook still owns, because they are policy and
not code: deleting the channel remains forbidden as a *rollback* step (it destroys Chatwoot
conversations asynchronously — use `INACTIVE_WHATSAPP_NUMBERS` or deactivate instead), and a
deleted foreign-owned channel leaves this app's WABA subscription behind by design, so
`DELETE /{waba-id}/subscribed_apps` with Chatwoot's token is a manual decommissioning step.

**(d) Never configure Meta implicitly — added, and the reason is new.** §1.2 established
that `POST /{phone-number-id}` with `webhook_configuration` fails with error 100 unless the
calling app already has a verified callback URL and `messages` subscribed in its **own
dashboard panel**; `POST /{waba-id}/subscribed_apps` alone is not sufficient. That
prerequisite lives outside Chatwoot, and the callback URL and verify token an operator must
paste there only exist once the channel row is saved (`ensure_webhook_verify_token` runs
`before_validation`). Meanwhile the automatic path swallows the result: `setup_webhook`
re-raises, but `Channel::Whatsapp#setup_webhooks` catches it into a log line plus a
reauthorization banner and the channel is created regardless — so a channel that pushed
nothing, or pushed and failed, is indistinguishable in the UI from a working one.

So a foreign-owned channel does not auto-configure Meta at all. The order is:

1. Create the channel with `provider_config['umi_foreign_owned'] = true`. Zero Graph writes.
2. Read `provider_config['webhook_verify_token']` and the callback URL off the saved row.
3. In **this app's** Meta dashboard, WhatsApp → Configuration → Webhook: save that callback
   URL and verify token, click "Verify and save", toggle `messages` to Subscribed.
4. `bundle exec rake 'umi:whatsapp:foreign_owned_setup[<inbox_id>]'` — prints the two values
   from step 2, then subscribes the app to the WABA and sets this app's own override.
   Failures abort with the Meta error; nothing is swallowed. Re-runnable.

Running step 4 before step 3 is the expected way to discover step 3: it fails with Meta's
error 100, whose text blames the WABA subscription the call just made successfully. The
foreign-owned path appends what actually has to change, so the operator is not sent in a
loop re-subscribing the WABA.

**(e) Never enable WhatsApp calling — added on review.** `Channel::Whatsapp#enable_voice_calling!`
→ `update_calling_status('ENABLED')` POSTs `/{phone-number-id}/settings` with
`{calling: {status:}}` (`enterprise/app/services/enterprise/whatsapp/providers/whatsapp_cloud_service.rb:45`).
That is **number-scoped, not app-scoped** — the same class as `/register` — and it is reachable
from the inbox UI and the admin API. This was initially left to the runbook freeze on the
grounds that it is a deliberate operator toggle that raises on failure. That reasoning was
wrong and is retracted: raising on *failure* is no protection at all, because the damaging
outcome here is the call **succeeding** — the number silently gains a capability its owner did
not ask for, and everyone sees success. It is now blocked, raising a message the inbox
controller renders back to the admin who clicked the toggle. The disable path needs no guard:
it never calls `update_calling_status`, only flipping the local flag and re-registering
webhooks, which is app-scoped.

**One further write considered and deliberately left to the runbook.**

* `Whatsapp::CsatTemplateService` POSTs and DELETEs `/{waba-id}/message_templates`
  (`app/services/whatsapp/csat_template_service.rb:23`, `:99`) when CSAT is enabled or
  disabled on the inbox. It writes to the incumbent's template list and consumes their
  template quota, but only under a Chatwoot-generated, inbox-scoped template name
  (`CsatTemplateNameService`), so it cannot touch a Klaviyo template. Deliberate operator
  action, loud result. Freeze CSAT template management on this inbox; treat unfamiliar
  Klaviyo templates appearing in the agent template picker as expected, not as corruption.
  Unlike voice calling, this writes only under a Chatwoot-owned name on a WABA-scoped
  collection, so the worst case is quota and clutter, not a capability change to the number.

Everything else Chatwoot POSTs on a Cloud channel is `/{phone-number-id}/messages` — agent
replies, the intended function — and is not configuration.

Not addressed here, and still owned by the gate: manual Cloud channels do not require an
`X-Hub-Signature-256` unless `provider_config` carries an app secret
(`REVIEW-SECURITY.md` S1 / `REVIEW-OPS.md` B2), the `statuses.first` truncation
(`REVIEW-CHATWOOT.md` §2.1), and the `low`-queue capacity question (`REVIEW-OPS.md` B3).
None of those are writes against the incumbent's configuration.

One marker caveat: `provider_config` is a jsonb column that `PATCH /inboxes/:id` replaces
wholesale, so an API client that sends a partial config drops `umi_foreign_owned` silently.
Every path in this checkout preserves it — the dashboard spreads the serialized config
(`ConfigurationPage.vue:171`) and `Whatsapp::ReauthorizationService` merges into the
existing one — and losing it post-create cannot re-arm `/register`, because the auto-setup
callback is `on: :create` only. Re-check the marker after any channel edit anyway.

Implementation: `config/initializers/zz_umi_foreign_owned_whatsapp.rb`,
`umi/app/models/channel/foreign_owned_whatsapp.rb`,
`umi/app/services/whatsapp/foreign_owned_webhook_setup.rb`, `lib/tasks/umi_whatsapp.rake`,
`spec/umi/whatsapp/foreign_owned_channel_spec.rb`.

### 3. Status webhooks for messages unknown to Chatwoot — ignored cleanly

Established from code (High): `Webhooks::WhatsappEventsJob` dispatches a Cloud API
payload to `Whatsapp::IncomingMessageWhatsappCloudService`, whose base class sees
`statuses` and runs `process_statuses`. It takes the first status and immediately
returns unless `find_message_by_source_id(status[:id])` finds an existing Chatwoot
message. Therefore a single Klaviyo-only message's `sent`, `delivered`, `read`, or
`failed` status is ignored: no row is created, no error is logged by this branch, no
exception is raised, and the job succeeds. It is not retried and cannot enter a dead
set. Important limitation: the current code examines only `statuses.first`; a mixed
batch whose first status is Klaviyo-only can also drop later Chatwoot statuses. This is
a separate pre-cutover patch/measurement decision, not a harmless no-op at campaign
scale.

The local regression spec is `spec/services/whatsapp/shared_number_spike_spec.rb`:

```ruby
it 'ignores a status for a message not created in Chatwoot' do
  counts = { messages: Message.count, conversations: Conversation.count, contacts: Contact.count }
  expect do
    described_class.new(inbox: whatsapp_channel.inbox, params: status_params).perform
  end.not_to raise_error
  expect(Message.count).to eq(counts[:messages])
  expect(Conversation.count).to eq(counts[:conversations])
  expect(Contact.count).to eq(counts[:contacts])
end
```

The spec also asserts no conversation/contact is created and uses a payload with
`statuses: [{ id: 'wamid.klaviyo-only', status: 'delivered', recipient_id: '...' }]`.
This pins the intentional no-op and its operational implication. A future change to
log or meter this case must not turn it into a retrying exception path.

Confidence: High. This is a local behavior spike; it does not require Meta assets and
does not change runtime behavior.

### 4. Inbound routing and the old Twilio inbox

Established from local Cloud API examples/specs (High): Cloud inbound processing uses
the payload's `metadata.display_phone_number` and `metadata.phone_number_id` to find
the matching `Channel::Whatsapp`, then `IncomingMessageWhatsappCloudService` uses the
sender ID to find/create the ContactInbox and conversation. Existing tests cover text,
attachments, BSUID identifiers, and replies whose original message is absent.

Moving from Twilio to Cloud API changes the channel and inbox, not the historical
conversation rows. The existing contact may be reused by phone number, but a new
Cloud inbox necessarily has its own ContactInbox association; that is not a duplicate
within one inbox. Existing Twilio conversations remain attached to inbox 6, and new
Cloud messages form or continue the Cloud inbox's conversation. The cutover must
therefore accept two inbox histories rather than attempt to merge them.

Confidence: High for the local routing behavior; Medium for exact customer identity
matching on every real payload shape because Meta may send phone `wa_id` or BSUID
identifiers depending on account/API behavior. The human cutover test must use a
known customer and verify contact ID, Cloud ContactInbox count, and one new message.

### 5. Mirroring Klaviyo content as a private note — safe if created as a note

Established from code and the existing UMI note pattern (High): `Message`'s
after-create commit callback always invokes `send_reply`, but `SendReplyJob` delegates
to the channel service, and `Base::SendOnChannelService#invalid_message?` returns true
for `message.private?`. Thus a private outgoing note does not call WhatsApp, although
`Message` still enqueues `SendReplyJob`; the channel service rejects the message before
provider delivery. `valid_first_reply?`
requires `!private?`, and the first-reply callback likewise returns for private notes,
so the note does not stamp agent first-reply metrics.

n8n should follow the existing W5 shape: resolve the conversation by a server-side
trusted identifier, create an outgoing message with `private: true`, and include the
marketing text plus metadata identifying the Klaviyo event/message ID. The API path may
assign a sender, so use a dedicated account-scoped AgentBot or least-privilege bot
identity; do not use a human agent token. Enforce `private: true` rather than defaulting
a missing field, and inventory account webhooks, Slack hooks, agent bots, and other
listeners because private notes still fan out to those integrations. It must not create
a template message, use `private: false`, or call a send endpoint.

The event ID is not protected by a unique `messages.source_id` constraint. The workflow
must therefore serialize/deduplicate per conversation or use a durable idempotency
store; a read-then-write race is not idempotent. Record the bot identity, token owner,
rotation plan, idempotency mechanism, and hook inventory in the gate.

Required verification before enabling the workflow: create a local private-note test
that asserts `SendReplyJob` may be enqueued but no outbound provider call occurs, and
that `conversation.first_reply_created_at` and `waiting_since` do not change.

Confidence: High for Chatwoot's current callback and metrics behavior; Medium for the
n8n workflow contract until its exact W5 payload and idempotency key are inspected in
the workflow environment.

### 6. `message_echoes` versus `smb_message_echoes` — UNKNOWN for this use

The checkout subscribes Cloud channels to `messages smb_message_echoes`. The local
job explicitly treats `smb_message_echoes` as WhatsApp Business app/companion-device
coexistence echoes and maps them into outgoing messages with `external_echo: true`.
That is a different field from `message_echoes`.

The Meta material checked here documents `smb_message_echoes` as a coexistence field
and shows the `message_echoes` payload shape in third-party references, but it does
not establish, for the current Graph API version, that `message_echoes` is emitted to
another subscribed Cloud API app when a different Cloud API app sends a message on
the same number. Do not infer that it will mirror Klaviyo sends. Treat this as
Unknown. The two-app throwaway test in §1.1 should record every `changes[].field`
received at both collectors for messages sent by each app. If the result is not
explicitly reproducible and version-pinned, n8n remains the only approved mirror.

Confidence: High that `smb_message_echoes` is not the requested cross-Cloud-app
semantic; Unknown on `message_echoes` for this architecture.

## Failure modes and detection

| Failure | Detection | Response |
|---|---|---|
| Phone override is global and last-writer-wins | Two-app test; continuous collector health checks | Stop migration; no shared-number design until Meta provides a safe app-scoped route |
| Chatwoot attempts foreign phone registration | Setup audit log/HTTP capture; explicit no-register test | Do not create the production channel through current callback; apply reviewed patch |
| Chatwoot webhook subscription missing or overridden | `GET /{WABA-ID}/subscribed_apps` per app plus test inbound | Stop; restore only through the documented app-scoped procedure |
| Chatwoot channel deletion/teardown clears the shared phone override | Teardown code audit and guard test; never delete during rollback | Disable the channel/inbox; never delete it as rollback |
| Voice toggle rewrites the phone override | Freeze voice toggles; audit `enable_voice_calling!`/`disable_voice_calling!` | Keep voice setting frozen until a foreign-number patch covers it |
| Klaviyo status has no Chatwoot message | Job logs/metrics and queue success; no DB row is expected | Treat as normal; add a counter if operational visibility is needed, without raising |
| Mixed status batch drops Chatwoot's later status | Compare Graph status IDs with Chatwoot message statuses; current code processes only `.first` | Patch/measure before cutover; do not call bulk marketing status load harmless |
| Marketing status burst delays support inbound | Queue depth/age by `low` queue and inbound receipt latency | Rate-limit/segregate status processing before large campaigns |
| Inbound reaches wrong inbox or contact | Known-customer cutover test; compare phone_number_id, contact ID, ContactInbox, message source ID | Stop sends, preserve raw payload, investigate before agents resume |
| Private note is accidentally public or sent | Local job/provider spy; inspect `private`, `message_type`, `source_id`, first-reply fields | Disable n8n workflow immediately; delete no data automatically; investigate |
| Forged webhook accepted by manual channel | Bad `X-Hub-Signature-256` test must return 401 | Configure the Cloud channel with Chatwoot app secret and stop if verification is off |
| Meta emits unsupported echo/status shape | Raw webhook capture and field-level alerting | Keep n8n mirroring; do not add broad parsing or retries without a new spec |

## Pre-migration gate

All items must be checked and recorded with timestamps, Graph API version, actor, and
raw response copies (with tokens redacted):

1. The two-app phone-override test is safe in both write orders, including a real
   inbound test message and Cloud API sends from both apps.
2. Klaviyo confirms the final WABA ID, phone-number ID, app ID, permissions, callback,
   and ownership contact. Chatwoot has a system-user token scoped only to the intended
   WABA/phone and a distinct verify token.
3. A staging Chatwoot build has the foreign-number path and tests for no `/register`,
   no phone override/clear, and only the intended WABA-level subscription write. It
   has been tested against a disposable number already provisioned by another app if
   Meta permits such a test.
4. `GET /{waba-id}/subscribed_apps` shows both apps and the expected callback data;
   `GET /{phone-number-id}?fields=...` records phone health and webhook configuration.
5. Chatwoot has a tested Cloud channel configuration containing the final
   `business_account_id`, `phone_number_id`, API token, phone number, and verify token;
   no production save or after-commit setup occurs before the gate is green.
6. A known customer can be used for a controlled inbound test, with agent coverage,
   queue monitoring, webhook request logs, and a halt owner present.
7. Manual Cloud webhook signature verification is enabled with the Chatwoot app secret;
   a malformed-signature POST returns 401.
8. n8n's workflow is disabled until the inbound test succeeds, then enabled with a
   dedicated account-scoped bot identity, an explicit `private: true` assertion, a
   durable idempotency mechanism, and a private-note-only request. A second run of the
   same event proves no duplicate note and no provider call. Existing account hooks
   have been inventoried and their private-note propagation is accepted.
9. The rollback operator has access to the prior Twilio credentials/config and has
   verified that inbox 6 still exists and its conversations are intact.

## Migration runbook (only after the gate)

1. Freeze changes to WhatsApp setup, voice toggles, Klaviyo WABA settings, n8n, and
   channel/inbox deletion. Export current Chatwoot channel/inbox metadata and record
   inbox 6's conversation count. Do not delete inbox 6 or the new Cloud channel.
2. Complete Klaviyo's number/WABA migration in the Meta Business portfolio according
   to Klaviyo's runbook. This document does not authorize or perform that migration.
3. Verify the new WABA/phone IDs and both app subscriptions with read-only Graph API
   calls. Confirm the phone-level result remains the safe test result.
4. Provision the Chatwoot Cloud channel using the reviewed foreign-number path. It
   must not call `/register`, clear or set the phone-level override unless §1.1 proved
   that operation app-scoped, or silently accept failed setup. Subscribe only the
   approved app/WABA-scoped configuration and verify it with Meta. Do not use the
   ordinary `perform` path.
5. Send one controlled inbound message. Confirm it arrives once in the new Cloud
   inbox, resolves to the expected contact, creates only the expected Cloud
   ContactInbox/conversation state, and leaves inbox 6's historical rows unchanged.
6. Send one controlled Chatwoot reply and confirm it reaches the customer. Do not
   enable campaigns yet.
7. Send one Klaviyo test marketing message to a test recipient. Confirm Klaviyo
   attribution, Meta statuses, and the expected Chatwoot no-op for unknown statuses.
8. Enable n8n for the test recipient only; verify one private note, no outbound
   WhatsApp call, unchanged first-reply metrics, and idempotent retry behavior.
9. Expand in stages with monitoring. Keep inbox 6 visible and untouched as the
   historical fallback until the migration is proven stable.

## Rollback

Rollback is a controlled stop, not deletion:

1. Disable Klaviyo campaigns/flows and the n8n mirroring workflow. Stop Chatwoot
   outbound replies if the shared routing is ambiguous.
2. Preserve Graph responses, webhook envelopes, Chatwoot job logs, and timestamps.
3. If Meta's routing remains safe but Chatwoot is faulty, disable the new Cloud inbox
   path and fix or revert the Chatwoot setup patch. Never delete the Cloud channel or
   inbox as rollback: its `before_destroy` teardown can clear the shared phone
   override. Preserve the rows and credentials until Graph state is reconciled.
4. If the phone override is unsafe or support traffic is dark, restore the previously
   validated Twilio/provider configuration only through the provider's documented
   number-reconnection process, with a controlled inbound and outbound test. Do not
   assume the old Twilio connection remains active after migration.
5. Keep inbox 6 and its conversations. Reconcile any messages received by Klaviyo or
   the Cloud inbox during the incident manually; do not bulk-replay without an
   idempotency plan.
6. Record the failure as a new spike/spec input. No production retry is allowed until
   the pre-migration gate is green again.

## Spike inventory

* Code reading spike: `facebook_api_client.rb`, `webhook_setup_service.rb`,
  `channel/whatsapp.rb`, `whatsapp_events_job.rb`, and the incoming-message/status
  service. Proves the local call graph and status no-op; it does not prove Meta's
  phone-override semantics.
* Local regression spike: `spec/services/whatsapp/shared_number_spike_spec.rb` pins the
  unknown-status no-op. It does not prove Meta delivery behavior.
* Live Meta experiment run 2026-08-19 against disposable assets per the §1.1 runbook;
  results in §1.2. Phone-level override scoping is confirmed per-app. A real
  inbound-message delivery test on a production-shaped number was not run (test
  numbers cannot receive messages from arbitrary senders); the pre-migration gate
  item 1 controlled inbound test remains required before cutover.
