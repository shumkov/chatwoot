# Calls — Design Spec (Chatwoot + Twilio + mobile SIP softphone) · v4

Status: **Draft for sign-off / spike** · Branch: `feat/calls` · Owner: UMI fork

---

## 0. Locked direction (decided by owner; do not relitigate)

- **No EE license**, won't buy → reimplement the backend ourselves in a fork-owned **`umi/`** tree.
- **No native iOS/Android app** (too costly to build/distribute).
- **No desktop calling** — on desktop, Chatwoot shows **information only**.
- **Agents take calls on their phones in an off-the-shelf SIP softphone** (Acrobits **Groundwire**), registered to a **Twilio SIP Domain**. Twilio is the bridge; **Chatwoot is the orchestrator + logger + click-to-call source**.
- **Both PSTN ("mobile") and WhatsApp** calls must reach the softphone.
- In the softphone the agent must **see who's calling (contact name)**; ideally a **link back to Chatwoot**. From Chatwoot, agents **start a call via a link** that rings the softphone.

This spec is the "how." It folds in a 5-agent research sweep + a 5-lens review + a softphone-UX deep-dive. Everything load-bearing that can only be confirmed on a live account/device is collected in the **Spike register (§12)** — run those before/at the start of build.

---

## 1. Architecture

```
   Customer
     │  PSTN dial ───────────►  Twilio Voice number ─┐
     │  WhatsApp call ───────►  Twilio WhatsApp sender ┘
     │                                  │ (signed webhook)
     ▼                                  ▼
  ┌───────────────────────── Chatwoot (umi/) ─────────────────────────┐
  │  Inbound webhook:  match Contact → Conversation → Call → voice_call │
  │    message (realtime "who's calling" screen-pop in Chatwoot)        │
  │    return TwiML: <Dial callerId=contact + Remote-Party-ID=name>     │
  │                    <Sip>agentN@umi.sip.twilio.com?…</Sip> …         │
  │  Outbound (click-to-call): groundwire: deep link  OR  REST bridge   │
  │  Status/recording webhooks → update Call + touch message            │
  └─────────────────────────────────────────────────────────────────────┘
     │  INVITE w/ caller name
     ▼
  Twilio SIP Domain  ──► Acrobits SIPIS (holds registration, sends PushKit)
     │                          │ APNs VoIP push (built from the INVITE)
     ▼                          ▼
  Agents' phones: Groundwire wakes → CallKit shows the CONTACT NAME → answer → RTP audio
```

- **Softphone**: **Acrobits Groundwire** ($9.99 one-time/device; **free hosted SIPIS push**; no app to publish). Each agent registers Groundwire with a **per-agent SIP credential** to our Twilio SIP Domain. SIPIS registers *on behalf of the device* and sends the APNs PushKit push so the phone **rings while locked** — the only reliable no-app way to ring a backgrounded iPhone (plain SIP-on-Twilio does **not** ring backgrounded; Twilio sends no push). Zoiper (paid push add-on) / Bria (CounterPath push) are alternatives.
- **Bridging**: plain **`<Dial>`** with one `<Sip>` per on-duty agent (≤10), first-answer-wins. No conference in P0 (add later for transfer/hold). Recording (P3) via `<Dial record="record-from-answer-dual">`.
- **Chatwoot's role**: receive Twilio webhooks → match contact, create the `Call` + `voice_call` message (so the conversation **screen-pops** in Chatwoot for full context), choose which agents to ring, build the TwiML, inject the caller name, log status/duration, expose click-to-call.

---

## 2. The two "softphone UX" requirements — how each is met

### 2.1 See the contact NAME on the (locked) call screen
**Primary:** inject the Chatwoot-resolved contact name into the **SIP INVITE display-name** at the Twilio layer. On the `<Dial><Sip>` leg, set `callerId` (digits/alphanumeric, **no spaces**) and a **`Remote-Party-ID`** header carrying the display name, e.g.
`<Sip>sip:agent7@umi.sip.twilio.com?Remote-Party-ID=%22Jane%20Doe%22%20%3Csip%3A%2B15551234567%40host%3E</Sip>`.
Groundwire's `remoteContact` config reads headers in order `pai,from,rpid,ppi`, and SIPIS builds the PushKit/CallKit payload **from the INVITE it receives** — so the name reaches the locked CallKit screen, per-call fresh, **no contact sync**. (PSTN `From` is usually a bare E.164 with empty display-name, so we *must* set the name ourselves.)
**Fallback:** Acrobits **Web Service Contacts** — Groundwire polls a Chatwoot HTTP endpoint (default 180s), bulk-downloads contacts (JSON `{contacts:[{displayName, contactEntries:[{type:"tel",uri}]}]}`), and matches incoming numbers locally. Heavier (full-list sync, polling latency, scale concern) and lock-screen rendering of synced names is itself a spike item — use only if INVITE injection fails.
**Always-on context:** regardless, Chatwoot **screen-pops** the conversation (inbound webhook → `voice_call` message → realtime), so the agent has full caller context in Chatwoot even if the softphone shows only a number.

### 2.2 A link to Chatwoot, and click-to-call from Chatwoot
- **Click-to-call FROM Chatwoot — web (primary):** the conversation **Call** button → `POST contacts/:id/call` → Twilio REST `calls.create(to: 'sip:agentN@…sip.twilio.com', url: <umi outbound_twiml that <Dial>s the contact>)` → the agent's Groundwire rings first, then bridges to the customer. Fully logged, business caller-ID, vendor-agnostic.
- **Click-to-call FROM the native mobile app (no app fork) — via a MACRO.** **LIVE FINDING (2026-06-23):** the iOS app **copies** a `link`-type custom attribute instead of opening it, so a tappable `groundwire:`/https link in an attribute does **not** auto-dial. The working trigger is a Chatwoot **macro**: a global "📞 Call contact" macro runs `send_webhook_event` → `POST umi/voice/macro_dial` (shared-secret) → the same server-bridge (ring the conversation **assignee's** softphone → bridge to the contact). Verified live that the app runs macros **server-side**. A signed-link trigger (`/umi/voice/dial/:token`, confirm page → POST) remains for surfaces that *open* links (e.g. a link inside a message).
- **Link to Chatwoot FROM the softphone (best-effort):** Groundwire's `openUrl` dial action (`customActionUrl` templated with `%uri%`) can open `https://<chatwoot>/…?number=%uri%` — but it's documented for the keypad, not confirmed on the in-call screen (**spike**). The white-label Cloud Softphone "Custom Functions Framework" supports true in-call CRM buttons but costs ~$549/mo — not worth it. **Realistic stance: rely on Chatwoot screen-pop for context; treat an in-call Chatwoot link as a nice-to-have pending the spike.**

---

## 3. Chatwoot surface (HTTP + realtime)

Account-scoped under `/api/v1/accounts/:account_id`. Owned (in `umi/`).

| Method & path | Purpose | Notes |
|---|---|---|
| `POST contacts/:contact_id/call` | Click-to-call (server-bridge variant) | `{inbox_id, conversation_id?}` → `{call_sid, conversation_id}` |
| `GET contacts/:contact_id/call_link` | Return the `groundwire:` deep link (deep-link variant) | optional convenience |
| `POST umi/voice/:phone/incoming` | Twilio inbound voice webhook → TwiML `<Dial><Sip>` | signed |
| `POST umi/voice/:phone/outbound_twiml` | TwiML for the outbound bridge leg | signed |
| `POST umi/voice/:phone/dial_status` | `<Dial action>` result (attribution, no-answer) | signed |
| `POST umi/voice/:phone/status` | Call status callback | signed |
| `POST umi/voice/:phone/recording` | Recording callback (P3) | signed |
| `GET umi/voice/contacts_directory` | Web Service Contacts feed (fallback for §2.1) | token-auth; optional |

**Realtime / logging:** calls surface as a `voice_call` message (`content_type` already in OSS `Message`). Every state change `call.message.touch` → `ActionCableListener#message_updated` → broadcasts `message.push_event_data`; our **`Umi::Message#push_event_data`** decorator embeds the `call` (snake_case, hyphenated `display_status`: `ringing|in-progress|completed|no-answer|failed|missed`, with `provider`, `medium`, `direction`, `duration_seconds`, `accepted_by_agent_id/name`). This is what screen-pops the conversation and updates the bubble.

---

## 4. Data model & placement (unchanged from v2/v3 decisions)

- Reuse the migrated `calls` table + `channel_twilio_sms` voice columns (no new migrations P0–P2). Top-level **`Call`** model in `umi/app/models/call.rb`.
- `umi/` extension tree wired via `lib/chatwoot_app.rb` (`umi?` + `extensions`), `config/application.rb` (eager-load `umi/app/**`), `config/routes.rb` (our routes, EE voice routes removed). Decorators `Umi::Message`, `Umi::Channel::TwilioSms` auto-prepended via the existing `prepend_mod_with` calls. **Remove the EE voice + EE WhatsApp-Cloud-calling subtrees** (license).
- **Per-agent SIP credentials** (not shared) — needed for attribution (which agent answered) and per-agent ring sets. Stored/managed per agent (a `umi` model or on the user/inbox); SIP password encrypted.
- Channel mapping: PSTN Voice = `Channel::TwilioSms` medium `sms`, `phone_number: +66975311301`; WhatsApp = `Channel::TwilioSms` medium `whatsapp`, `phone_number: whatsapp:+66975311301` (the `whatsapp:` prefix is stored verbatim — incoming `find_by(phone_number: params[:To])` and outbound `from: phone_number` both rely on it). The two distinct `phone_number` strings both satisfy the unique index → **two separate inboxes on one number**; the contact-leg address also gets the `whatsapp:` prefix for WA.

---

## 5. Flows

### 5.1 Inbound (PSTN or WhatsApp)
1. Customer dials the number / WhatsApp-calls the sender → Twilio POSTs `…/incoming` (signature validated first).
2. `Umi::Voice::InboundCallBuilder`: resolve channel by `:phone`; idempotently find/create ContactInbox→Contact→Conversation→`Call`(incoming, ringing)→`voice_call` Message; broadcast `message.created` (Chatwoot screen-pop).
3. `Umi::Voice::AgentRing::Resolver` picks the on-duty agents (≤10). Build TwiML: `<Dial callerId="<contact-e164>" timeout="20" action="…/dial_status"><Sip>` per agent, **each with `Remote-Party-ID` = the contact display-name** and a self-identifying `?agentId=N` (or per-`<Sip>` `statusCallback`) for attribution.
4. SIPIS pushes each agent's Groundwire → rings (locked screen shows the contact name) → first answers; others cancel.
5. `…/dial_status` records which agent answered (→ `accepted_by_agent_id`, assign conversation, `in_progress`); `no-answer` within timeout → `missed`/`no_answer` (+ optional voicemail `<Record>` fallback). `…/status` drives terminal state + duration. `touch` on every transition.

### 5.2 Outbound click-to-call
- **Deep-link:** Chatwoot shows `groundwire:<contact-e164>?dialAction=autoCall`; tap → Groundwire dials (the contact sees the agent's SIP/registered identity; for a business caller-ID, prefer the bridge variant).
- **Server-bridge:** `POST contacts/:id/call` → create `Call`(outgoing) + message → (outside the DB txn) `calls.create(to: 'sip:agentN@domain', url: …/outbound_twiml)` → agent's Groundwire rings → on answer, TwiML `<Dial callerId="<business#>"><Number>+E164</Number></Dial>` (PSTN) or `<WhatsApp>+E164</WhatsApp>` (WA) bridges to the contact. Logged + status-tracked.

### 5.3 WhatsApp specifics — messaging live on a Twilio Sender; calling via Twilio WhatsApp Business Calling (corrected 2026-07-04)
**WhatsApp messaging is LIVE** on +66975311301 via a **Twilio WhatsApp Sender** (Console → Messaging → Senders →
WhatsApp senders → "Continue with Facebook" self-sign-up → a new **Twilio-managed WABA**). Because Twilio owns the
number it **auto-verifies** as the BSP (Twilio catches the OTP and shows it in the Console — no manual OTP chase).
In Chatwoot this is a **`Channel::TwilioSms`** inbox, `phone_number: whatsapp:+66975311301`, `medium: whatsapp` — a
*separate* inbox from the plain-`+66975311301` Voice channel (both `phone_number` strings satisfy the unique index).

**Rejected path — hand-adding the number to your own Meta WABA (Cloud API direct).** We tried
`POST /{waba}/phone_numbers` + `request_code` on our own WABA first; it **does not work on a VoIP/Twilio number** —
the SMS OTP never arrives and the voice OTP fails. The spoken *"we're sorry, an application error has occurred"* is
**Twilio error 11200** (the number's own voice webhook/TwiML erroring), **not** a Meta bug; Meta also rates VoIP
numbers SMS-"Not Recommended". (Hours burned here before switching to the Twilio-Sender path.) Cleanup note: a
pending number added this way can't be `DELETE`d via Graph API — remove it in **Meta Business Settings → WhatsApp
Accounts**. The separate **+66800053593** predates all this and stays on **Meta Cloud API direct** (Chatwoot inbox
"Whatsapp") — that's why the two numbers use different WhatsApp stacks.

**WhatsApp calling (later phase) — Twilio WhatsApp Business Calling, no PBX.** Since the number is a Twilio-managed
sender, WhatsApp calls arrive at Twilio and route into **Programmable Voice**. Plan: the sender's **Voice Endpoint** →
"Connect to a **TwiML Application**" → a TwiML app that returns the **same `<Dial><Sip>`** used for PSTN voice,
ringing the agent's **Groundwire**. This **reuses the existing PSTN voice stack** — `Umi::Call(provider: :whatsapp)`
(the enum already exists), `CallMessageBuilder`, `CallStatus::Manager`, contact-by-E.164 match — so the same
screen-pop + call log apply. **No PBX.**

**Why not Meta-native SIP → your own PBX:** it stays a theoretical alternative, but it's **mutually exclusive** with
the webhook/Graph (BSP) mode the number is already in, is **undocumented for BSP-registered numbers**, and needs a
**PBX** — so we chose the Twilio path.

**External gates:** ≥2,000-conv/24h tier → Meta **Business Verification** (weeks); business-initiated WA calls are
excluded in some countries (**Thailand is clear**). **Honest caveat to verify live:** Twilio docs confirm WhatsApp
calls route into Programmable Voice and **can't bridge to PSTN**, but they don't *explicitly* enumerate `<Sip>` as an
allowed bridge target — so confirm the `<Dial><Sip>` bridge with a live test when enabling (this is Spike S3).
**Meantime (calling not enabled): no WhatsApp call button exists → nothing to handle**; voice is covered by PSTN on
the same number. Full plan: `GO_LIVE_RUNBOOK.md §6`.

---

## 6. Security & correctness

1. **Twilio webhook signature** (`X-Twilio-Signature`, channel `auth_token`) validated **before side effects**, with the signed URL **reconstructed from the public base URL** (not `request.url`) so it doesn't 403 behind the proxy. Skip CSRF; no session auth. Log+metric on 403. **P0-blocking test** with `X-Forwarded-Proto`.
2. **SIP credentials**: per-agent, password **encrypted**; SIP Domain locked to the credential list (no anonymous calling); rotate-able. `ACTIVE_RECORD_ENCRYPTION` keys are a deploy prerequisite for enabling voice.
3. **Authz** on `contacts/:id/call`: account membership + Pundit + voice-enabled inbox + `channel_voice` flag.
4. **Toll-fraud**: `rack_attack` throttle on click-to-call (per-account + per-agent) + per-account daily cap.
5. **No secrets in logs** (auth_token, SIP password, credentialed recording URLs); recording job gets `call.id` + `recording_sid` only.
6. **`call_sid` identity**: `push_event_data.provider_call_id` is always the canonical `calls.provider_call_id`.

---

## 7. Failure modes (incl. ones the EE original mishandles)

- **No agent answers / timeout** → `<Dial timeout>` + `dial_status` `no-answer` → `missed` + optional `<Record>` voicemail (a single shared number must never hit dead air).
- **Which agent answered** → per-agent `<Sip>` + `DialSipHeader_*` / per-`<Sip>` `statusCallback?agentId=N`.
- **REST outside the DB transaction** (create row → commit → call Twilio → patch SID); webhooks for an unpersisted call respond with a benign `<Pause>` and rely on retry.
- **Idempotent webhooks** via unique `(provider, provider_call_id)` + terminal-state guard; out-of-order `completed`-before-`in_progress` sets `started_at = Timestamp − CallDuration`.
- **Softphone unregistered / SIPIS down** → no-answer → voicemail; surface clearly.
- **WhatsApp**: permission/geography errors (§5.3).

---

## 8. Components (under `umi/`)

`Umi::Voice::WebhooksController` (`incoming`, `outbound_twiml`, `dial_status`, `status`, `recording`); `Umi::Voice::ContactCallsController` (`create`, `call_link`); `Umi::Voice::ContactsDirectoryController` (WS-contacts fallback). Services: `Umi::Voice::{InboundCallBuilder, OutboundCallBuilder, CallMessageBuilder, StatusUpdateService}`, `Umi::Voice::CallStatus::Manager`, `Umi::Voice::Dial::{Builder, ResultHandler}`, `Umi::Voice::AgentRing::Resolver`, `Umi::Voice::Sip::CredentialService`, `Umi::Voice::Provisioning::{Setup,Teardown}Service`; P3: recording service+job. Model/decorators per §4. Frontend (MIT, minimal): a contact/convo **Call** button (deep link + server-bridge), the `voice_call` bubble, and screen-pop; **no desktop softphone**.

---

## 9. Cost model (US ballpark; verify live)

- Number: ~$1.15/mo. **A bridged inbound call = TWO legs, each rounded up to the whole minute:** inbound PSTN local $0.0085/min + SIP leg $0.0040/min ≈ **$0.0125/min** (toll-free inbound $0.022). Outbound PSTN $0.014/min. WhatsApp ≈ $0.017/min out, ≈ $0.005/min in. Recording $0.0025/min + $0.0005/min-mo storage. SIP Domain registration free. **Groundwire $9.99 one-time per device; SIPIS push free.**
- Trial: SIP Domain + registration work; **inbound only from verified numbers + a trial watermark**; **WhatsApp calling NOT available on trial** (needs an approved sender).

---

## 10. Account & infra setup (you have none yet)

**Region / data residency (team is in Asia; account Region fixed at US1):**
- **Account Region = US1 (already created, immutable)** → call data/recordings/logs are **stored in the US**. Region and Edge are **independent** ("any Edge with any Region"), so US1 does NOT block the Singapore edge.
- **Edge = `singapore`** for SIP latency. **Registration** uses the edge URI `…sip.singapore.twilio.com` (softphone ingress). **CONFIRMED LIVE:** when **dialing** a registered endpoint you must use the **GLOBAL** URI `…sip.twilio.com` (no edge) — Twilio forks to the registered devices; putting an edge in the *dial* URI fails with **error 32220** ("Specifying an edge is not allowed when dialing SIP registered endpoints"). So: register on `…sip.singapore.twilio.com`, dial `sip:agent@…sip.twilio.com`.
- **Residency caveat:** APAC data residency (AU1) is not available on this US1 account and can't be retrofitted. Only matters if a regulation requires call data to stay in-region → then a **separate AU1 project** for production. The US1 account is fine for the spikes and (absent such a rule) for production too. **Confirm US-stored call data is acceptable.**

1. **Twilio**: account (in the chosen Region) → voice-capable number (shared business number).
2. **Twilio SIP Domain** (`umi.sip.singapore.twilio.com`, Singapore edge): Credential List with **one SIP username/password per agent**; enable SIP Registration; lock to the credential list; point the domain/number Voice URL → `…/umi/voice/<number>/incoming`.
3. **Groundwire** on each agent's iPhone/Android: install ($9.99), register with that agent's SIP creds + domain, **enable Push** (SIPIS, free/hosted).
4. **WhatsApp messaging (LIVE)**: register a **Twilio WhatsApp Sender** on +66975311301 (Console → Messaging → Senders → WhatsApp senders → "Continue with Facebook" → Twilio-managed WABA, auto-verified); set its incoming webhook → `https://chat.umi.store/twilio/callback`; create the `Channel::TwilioSms` inbox (`phone_number: whatsapp:+66975311301`, `medium: whatsapp`). **WhatsApp calling (later)**: enable Business Calling on the sender → Voice Endpoint → a TwiML App returning the voice `<Dial><Sip>`; needs Meta Business Verification + ≥2,000-conv tier. **Thailand is not outbound-excluded.**
5. **Chatwoot**: Twilio SID/auth-token + per-agent SIP creds on the voice inbox; `ACTIVE_RECORD_ENCRYPTION` keys; enable `channel_voice`.

---

## 11. Phasing

- **P0 — inbound PSTN → Groundwire, with name + logging:** `umi/` wiring; `Call` + `Umi::Message`; provisioning (SIP domain/per-agent creds + number Voice URL); `incoming` webhook (proxy-verified signature) building `<Dial><Sip>` with **Remote-Party-ID name injection**; `dial_status`/`status` (attribution, no-answer, duration); `voice_call` message + realtime screen-pop. **Exit:** a real PSTN call rings the on-duty agents' locked iPhones **showing the contact name**, first answers, two-way audio, and the conversation + live bubble appear in Chatwoot. (Gated on Spikes S1, S2, S6.)
- **P1 — outbound click-to-call:** `groundwire:` deep link + server-bridge variant + throttle.
- **P2 — WhatsApp via Twilio:** messaging **LIVE** (Twilio WhatsApp Sender → `Channel::TwilioSms` inbox, `whatsapp:` addressing). Calling later via **Twilio WhatsApp Business Calling** (sender Voice Endpoint → TwiML App `<Dial><Sip>`), gated on Spike S3 + Business Verification + ≥2,000-conv tier + geography pre-check.
- **P3 — recording + voicemail:** `<Dial record>` + recording webhook/job/attach + authenticated access + consent; `<Record>` voicemail on no-answer.

---

## 12. Spike register — confirm before/at build start ("100% sure on each part")

| # | Spike (live Twilio account + real iPhone) | Why it's the risk | Confidence today | Blocks |
|---|---|---|---|---|
| **S1** | **Groundwire + SIPIS, registered to a Twilio SIP Domain, rings a LOCKED iPhone** after the registration window lapses (>10 min idle). | The make-or-break. SIPIS push-on-behalf is provider-agnostic *in design* but unverified end-to-end with Twilio (credential-list vs IP-ACL; Twilio max-Expires 3600s). | Med-High (architecturally sound) | P0 (whole mobile model) |
| **S2** | **Contact NAME shows on the locked CallKit screen** when we set `From`/`Remote-Party-ID` display-name on the `<Dial><Sip>` INVITE (SIPIS forwards it into the push). | "See who's calling" depends on it; Twilio default puts bare E.164 with empty display-name. | Med | P0 (name display; falls back to number / WS-contacts) |
| **S3** | **WhatsApp ↔ SIP**: inbound WhatsApp call via **Twilio WhatsApp Business Calling** → TwiML App `<Dial><Sip>` rings Groundwire (two-way audio). | Twilio confirms WA calls route into Programmable Voice and can't bridge to PSTN, but doesn't *explicitly* enumerate `<Sip>` as an allowed bridge target. If it fails, WhatsApp-to-softphone via Twilio is impossible. | Med (likely OK) | P2 (WhatsApp calling only; messaging is live) |
| **S4** | **Click-to-call**: `groundwire:<e164>?dialAction=autoCall` auto-dials on iOS from a Chatwoot link; AND server-bridge `calls.create(to: sip:AOR)` rings a registered Groundwire then bridges (incl. caller-ID + unregistered-AOR error 32009). | Both click-to-call paths. | Med-High | P1 |
| **S5** | **Attribution**: identify the answering agent via `DialSipHeader_X-AgentId` echo and/or per-`<Sip>` `statusCallback?agentId=N`. | "Handled by X" + auto-assign. | Med (endpoint-dependent) | P0/P1 polish |
| **S6** | **Webhook signature behind the proxy**: validation passes with reconstructed public URL (`X-Forwarded-Proto`). | All-or-nothing 403 freezes every call. | High (known fix) | P0 |
| **S7** | **In-call Chatwoot link**: whether Groundwire `openUrl`/custom button fires on the incoming/in-call screen (not just keypad). | The "link in softphone" nice-to-have. | Low | none (screen-pop covers context) |

**Run order:** S1 + S6 first (cheapest, P0-blocking; ~½ day with a $10 Groundwire install + trial Twilio + an iPhone). Then S2, S4, S5. **S3 only when a WhatsApp sender exists** (gated behind weeks of Meta verification anyway — run during that wait). S7 last/optional.

---

## 13. Decisions captured

1. **Chatwoot + Twilio + Acrobits Groundwire (SIPIS push) on a Twilio SIP Domain.** No EE code, no native app, no desktop calling.
2. **Per-agent SIP credentials**; `<Dial><Sip>` group ring (≤10), first-answer-wins; attribution via per-agent leg id.
3. **Contact name on the call screen via SIP display-name injection** (RPID/From); WS-contacts sync fallback; Chatwoot screen-pop always.
4. **Click-to-call** via `groundwire:` deep link (primary) + Twilio server-bridge (robust).
5. **Both PSTN and WhatsApp** to the softphone. WhatsApp **messaging is live** (Twilio WhatsApp Sender → `Channel::TwilioSms`); WhatsApp **calling** later via Twilio WhatsApp Business Calling, gated on Spike S3 + Meta verification + geography check.
6. `umi/` tree + `prepend_mod_with`; reuse `calls` schema + `voice_call` message + realtime; remove EE voice + EE WhatsApp-Cloud paths; add webhook signature validation + toll-fraud throttle.
7. **Phasing:** P0 inbound PSTN (name+logging) → P1 outbound click-to-call → P2 WhatsApp → P3 recording + voicemail.
8. **Spike register §12 is the gate** — S1 (locked-iPhone ring) and S3 (WhatsApp↔SIP) are the two that can force a rethink; both confirmable cheaply.

---

## 14. Spike results — desk verification (2026-06-18) + live runbook

### 14.0 LIVE RESULTS (2026-06-18, on a real Trial account + iPhone + Groundwire)
- **Provisioned via API:** SIP Domain `umi-spike-2c9dbf.sip.twilio.com` (Singapore-edge registration host `…sip.singapore.twilio.com`), credential list + `agent1`, mapped for registration + calls. Auth via Account SID + **Auth Token** (the API-Key SID/secret pairing kept failing — use Auth Token for the spike).
- **Edge gotcha (confirmed):** register on `…sip.singapore.twilio.com`, but **dial the GLOBAL URI `…sip.twilio.com`** — dialing an edge URI fails with **error 32220**.
- **S1 (foreground): PASS** — a Twilio API-originated call to `sip:agent1@…sip.twilio.com` reached the registered Groundwire and connected (status `in-progress`); the iPhone rang. Core path (Twilio → SIP Domain → Groundwire) works live.
- **S1 (locked/background): PASS** ✅ — after **5 min** locked + Groundwire backgrounded, a Twilio call still **rang the iPhone's lock screen** (SIPIS push woke it cold; the live socket would have been suspended). **Make-or-break proven: the no-app / SIP-softphone approach works on real hardware.**
- **S2 (caller name on the softphone): PASS** ✅ — the injected name now shows on the call screen. **Method:** (1) backend injects the contact name into the SIP **`Remote-Party-ID`** header on the dial-to-agent leg (Twilio forwards RPID; it does NOT forward `P-Asserted-Identity`); (2) in Groundwire, **Incoming Caller ID** priority must list **Remote-Party-ID at the top** — by default `From Username` sits above it, so it shows the *number* (that was the earlier "no contact" result). With RPID first, "Test Contact" displayed. **No contact-sync needed.** This is a one-time per-device Groundwire setting (documented in the agent setup guide) + a backend header. (Contact-sync remains an alternative if RPID-reorder isn't acceptable.)
- **S4 (click-to-call): PASS** (desk + unit) — server-bridge `POST contacts/:id/call` rings the agent SIP then `<Dial>`s the contact; covered by umi specs.
- **Mobile trigger (2026-06-23, live): PASS via MACRO** — a `link`-type custom attribute is **copied, not opened** by the iOS app, but a macro's `send_webhook_event` runs **server-side from the app** (verified: tapping a test macro on the phone added a private note). So **`📞 Call contact` macro → `umi/voice/macro_dial` → server-bridge** is the no-fork mobile path.
- **S3 (WhatsApp): messaging LIVE** (2026-07 — Twilio WhatsApp Sender on +66975311301, auto-verified; inbound message received). **Calling-over-SIP still PENDING** — the `<Dial><Sip>` bridge for Twilio WhatsApp Business Calling is unverified (see §5.3).
- Trial notes: no owned number (used a placeholder `From`, accepted for SIP); a trial whisper may precede audio.

---

(Desk verification below predates the live run; live results above supersede where they overlap.)

### 14.1 Desk-verified results

| Spike | Desk finding | New confidence | Still needs live? |
|---|---|---|---|
| **S1** Twilio side | Twilio SIP Domains auth by **Credential List alone (no IP ACL)**, deliver INVITE to the current registration binding **regardless of source IP**, Expires 600–3600s — so SIPIS registering on the device's behalf is supported. Acrobits SIPIS documents the register-on-behalf → APNs-wake model and requires the SIP server be **publicly reachable** (Twilio is). | **High (mechanism)** | **Yes** — the actual locked-iPhone ring is unverified end-to-end with Twilio (no published receipt found). |
| **S2** name | Mechanism confirmed: set `Remote-Party-ID`/`From` display-name on the `<Dial><Sip>` INVITE; Groundwire `remoteContact` reads `pai,from,rpid,ppi`; SIPIS builds the CallKit payload from the INVITE. | **Med-High** | **Yes** — does the name actually render on the locked CallKit banner. |
| **S3** WA↔SIP | Only inference: Twilio forbids WhatsApp↔**PSTN**; SIP is VoIP and `<Dial><Sip>` is the documented way to reach softphones; no explicit "WhatsApp→SIP" statement or counter-evidence found. | **Med** | **Yes** — requires an approved WhatsApp sender. |
| **S4** click-to-call | `groundwire:<e164>?dialAction=autoCall` URL scheme documented; TwiML `<Dial>` to a registered AOR confirmed; REST `to=sip:user@domain` to an AOR is "same as any SIP call" (minor residual). | **Med-High** | Light — confirm auto-dial + AOR ring. |
| **S5** attribution | `DialSipHeader_X-*` + per-`<Sip>` `statusCallback?agentId=N` are documented mechanisms. | **Med** | Light — endpoint-dependent header echo. |
| **S6** signature | Known fix: reconstruct signed URL from the public base URL (`FRONTEND_URL`/forwarded headers). | **High** | Code-level test only (no account needed). |
| **S7** in-call link | Groundwire `openUrl`/custom button is keypad-documented; in-call binding unconfirmed; white-label only for true CRM buttons. | **Low** | Optional — screen-pop covers context. |

### 14.2 Live runbook — S1 + S2 + S5 (inbound: locked ring + name + attribution)
Prereqs: Twilio account (trial works for a first pass — caveats below); a **verified** phone to call from; an iPhone; Groundwire (~$9.99).
1. Buy/keep a **voice number**. Create a **SIP Domain** `umi-test.sip.twilio.com`; create a **Credential List** (`agent1` + password), map it to the domain; enable **SIP Registration**.
2. Create a **TwiML Bin** and set the **number's "A call comes in" → this Bin**:
   ```xml
   <Response>
     <Dial timeout="20" callerId="{{From}}" action="https://example.test/dial_status">
       <Sip>sip:agent1@umi-test.sip.twilio.com?Remote-Party-ID=%22Test%20Contact%22%20%3Csip%3A{{From}}%40umi-test.sip.twilio.com%3E&amp;x-AgentId=1</Sip>
     </Dial>
   </Response>
   ```
   (Hardcoded display-name `Test Contact` proves S2; `x-AgentId` probes S5.)
3. Install Groundwire on the iPhone → add SIP account (server `umi-test.sip.twilio.com`, user `agent1`, password) → **enable Push Notifications**. Confirm "registered."
4. **Background the app, lock the phone, wait >10 min** (past the registration window — proves SIPIS is holding the binding).
5. Call the Twilio number from the verified phone.
6. **PASS:** (S1) locked iPhone rings via CallKit within ~10s; (S2) the screen shows **"Test Contact"** not just a number; (S5) the `action` callback / Twilio Debugger shows `DialSipHeader_X-AgentId`; answer → two-way audio.
   *Trial caveats:* inbound only from a verified caller-ID; a trial whisper plays first; WhatsApp not available on trial.

   **No-number variant (run S1/S2/S5 BEFORE the number arrives — recommended):** a SIP Domain + Credential List needs **no phone number**. Register **two** endpoints to `umi-test.sip.twilio.com`: Groundwire (`agent1`, on the iPhone) and any free softphone (`caller`, on a laptop — Zoiper/Linphone). Set the **SIP Domain's Voice Configuration "A call comes in" URL** to a TwiML Bin returning the same `<Dial><Sip>sip:agent1@umi-test.sip.twilio.com?Remote-Party-ID=…</Sip>` as 14.2. Lock the iPhone (>10 min idle), then from the laptop softphone **dial anything** → the domain webhook fires → Groundwire rings. PASS criteria identical to 14.2 (locked ring + injected name + attribution header). This exercises SIPIS push, name injection, and attribution end-to-end with **zero PSTN numbers**. (SIP-to-SIP uses a SIP From identity, not a PSTN caller-ID, so the trial verified-number rule shouldn't apply; if anything blocks, a ~$20 paid balance removes trial limits.) The PSTN number is then only needed for the final real-PSTN end-to-end check.

### 14.3 Live runbook — S4 (click-to-call)
- **Deep link:** open `groundwire:+1<verified>?dialAction=autoCall` on the iPhone → PASS if Groundwire auto-dials.
- **Server bridge:** `twilio api:core:calls:create --from <twilio#> --to sip:agent1@umi-test.sip.twilio.com --url <Bin that <Dial>s the verified #>` → PASS if Groundwire rings, then bridges on answer. (Also note error 32009 if the AOR is unregistered.)

### 14.4 Live runbook — S6 (signature) — no account needed
Implement validation reconstructing the URL from the public base; unit/request-test a valid signature (incl. `X-Forwarded-Proto: https`) passes and a forged one 403s.

### 14.5 Live runbook — S3 (WhatsApp↔SIP) — gated on an approved sender (weeks)
When a WhatsApp sender with Business Calling exists: point its Voice config at a Bin returning `<Dial><Sip>sip:agent1@umi-test.sip.twilio.com</Sip></Dial>`; WhatsApp-call the sender from a test account → PASS if Groundwire rings + two-way audio (i.e. Twilio did **not** reject WhatsApp→SIP). Run during the verification wait; doesn't block PSTN.

### 14.7 P0 build recipe (validated by the live spike)
Implement P0 to reproduce exactly what worked by hand:
- **Provision** (per voice channel): create a Twilio **SIP Domain** + **Credential List** (one SIP user per agent) via API; agents register Groundwire to **`<domain>.sip.singapore.twilio.com`** with **Incoming Caller ID = Remote-Party-ID first**.
- **Inbound webhook** (`POST umi/voice/:phone/incoming`, signature-validated): match/create Contact→Conversation→`Call`→`voice_call` message (screen-pop), then return:
  ```xml
  <Response>
    <Dial timeout="25" callerId="{customer_e164}" action="{…/dial_status}" answerOnBridge="true">
      <Sip>sip:{agent}@{domain}.sip.twilio.com?Remote-Party-ID={"Contact Name" &lt;sip:{customer_e164}@{domain}.sip.twilio.com&gt;}</Sip>
      <!-- one <Sip> per on-duty agent, ≤10 -->
    </Dial>
  </Response>
  ```
  **Dial the GLOBAL domain `…sip.twilio.com`** (never the edge — error 32220). RPID carries the contact name (Twilio forwards RPID, not P-Asserted-Identity).
- **Callbacks:** `dial_status` (DialCallStatus → in_progress / no_answer + which agent answered) and `status` (terminal + duration) update the `Call` and `touch` the message (realtime).
- **Auth/creds:** store the channel's Twilio Account SID + Auth Token (the Auth Token authenticated reliably in the spike; an API Key also works in production — the console pairing was just fiddly). Encrypt secrets.

### 14.6 If S1 fails
Fallbacks, in order: (a) try Zoiper/Bria push proxies; (b) accept PSTN **forward-to-cell** for PSTN-only reliability (loses WhatsApp + in-app context); (c) reconsider the (ruled-out) native Twilio Voice SDK app — the only path with first-party, guaranteed locked-screen ring. S1 is the decision point.
