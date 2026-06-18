# UMI Telephony & Messaging — Go-Live Runbook

End-to-end plan to take **Voice calls + WhatsApp (messaging & Business Calling) + LINE** live on the
UMI Chatwoot fork, on **one shared Twilio number** (LINE is separate — it cannot attach to a phone
number). Companion docs: `CALLS_BACKEND_SPEC.md` (voice design + spike results) and
`GROUNDWIRE_AGENT_SETUP.md` (per-agent softphone setup).

> **Status legend:** ✅ built & tested · ⚙️ native Chatwoot config (no code) · 🚧 needs build · ⛔ gated (external approval).
> Facts below are verified against this codebase (v4.14.2 + UMI patches) and current Twilio/Meta docs (Jun 2026).

---

## 0. Scope & status at a glance

| Channel | Mechanism | Status | The catch |
|---|---|---|---|
| **Voice calls** (PSTN in/out) | umi voice backend → Twilio SIP Domain → Groundwire | ✅ built (PR #3) | needs live Twilio number + deploy + per-agent SIP creds |
| **Mobile click-to-call** | "📞 Call contact" macro → `/umi/voice/macro_dial` | ✅ built (PR #3) | macro created post-deploy via rake |
| **WhatsApp messaging** | Meta **Cloud API** (`whatsapp_cloud`) on +66975311301 → Chatwoot | ⚙️ config | ⛔ Meta sender approval (weeks) |
| **WhatsApp Business Calling** | Meta-direct **SIP** → **Jambonz** PBX → Groundwire; logs via `pbx/call_event` → `Umi::Call` | 🚧 later phase | ⛔ Business Verification (weeks); needs a PBX |
| **LINE messenger** | LINE Official Account → `Channel::Line` | ⚙️ config | separate from the number; LINE OA + Messaging API channel |

**One-number model (+66975311301):** **Twilio** carries **PSTN voice** (Plan A); **Meta Cloud API** carries
**WhatsApp messaging now + calling later** — same E.164, two independent rails. LINE is its own LINE Official
Account, unrelated to the number.

---

## 1. What is code vs. configuration

- **Custom-built (this fork):** the **voice backend** (inbound/outbound/recording/macro). Done, tested, in PR #3.
- **Native Chatwoot config (no code):** **WhatsApp messaging** and **LINE** are standard OSS inbox types — you create them in the Chatwoot UI and point the provider's webhook at Chatwoot. No fork work.
- **WhatsApp _calling_ (later phase):** see §6. It works via **Meta-direct SIP** (Meta delivers the call to your SIP server — documented, GA, proven), **not** Twilio (Twilio WA calling only reaches a WebRTC client). Needs a small **PBX (Jambonz)** between Meta and Groundwire; logs in Chatwoot via a `pbx/call_event` → `Umi::Call(provider: whatsapp)` bridge that reuses the existing voice machinery. A defined increment, gated on Meta Business Verification.

---

## 2. Prerequisites & accounts

| Need | Detail | Lead time |
|---|---|---|
| **Twilio number** | Voice-capable; on the existing **US1** account. Used for Voice + WhatsApp. | minutes |
| **Permanent number** | The current number is **temporary** (test only). WhatsApp sender registration is **number-bound** and takes **weeks** — do NOT register WhatsApp on the temp number; wait for the permanent one (see §3, §5). | — |
| **Twilio SIP Domain** | For agents' Groundwire (register on Singapore edge, dial GLOBAL). Per `CALLS_BACKEND_SPEC.md §10`. | minutes |
| **Meta Business** | Business Portfolio + **Business Verification** (gates WhatsApp volume tier, and thus calling). | **several weeks** |
| **LINE Official Account** | + a LINE Developers **Messaging API** channel (id/secret/token). | hours–days |
| **Deployed umi build** | The branch carrying PR #3 (voice backend) — per `FORK.md`. | per deploy |

> **Data residency note:** US1 keeps Twilio-side data in the US; the **Singapore SIP edge** only reduces
> voice latency, it does not move residency. If WhatsApp _content_ must live in Asia, set the **WABA
> data-localization region to Singapore** (Meta-side, via Twilio support) — independent of US1.

---

## 3. Provision the Twilio number

> **The current number is temporary** — fine for **voice testing** (voice webhooks are reconfigured in
> minutes when the permanent number lands). But **do not start WhatsApp** on it: WhatsApp sender
> registration is bound to the specific number and takes **weeks** of Meta verification, which you'd
> have to redo. Sequence: test voice on the temp number now → register WhatsApp only on the **permanent** number.

1. Buy a **Voice-capable** number on the US1 account; record its SID and E.164.
2. Voice setup (SIP Domain, credential lists, edges, per-agent SIP users) → follow **`CALLS_BACKEND_SPEC.md §10` + `§14.7`** (the validated build recipe). Don't re-derive here.
3. Leave WhatsApp registration for §5 — and only on the **permanent** number.

---

## 4. Channel — Voice calls  ✅ (built; deploy + wire)

1. **Deploy** the umi image carrying PR #3 (`FORK.md`: merge → tag `umi-vX.Y.Z-N` → CI builds GHCR image → bump `chatwoot_version` in `umi-vps-infra` → `pg_dump` → deploy).
2. **Env** on the deploy: `UMI_VOICE_SIP_DOMAIN`, `FRONTEND_URL` (public base, used to build webhook + macro URLs), per-agent SIP creds `agent-<user_id>`, optionally `UMI_VOICE_RECORDING=true`.
3. **Twilio webhooks** — point the number's Voice config at (replace `<digits>` with the E.164 without `+`):
   - Voice **Request URL**: `POST {FRONTEND_URL}/umi/voice/<digits>/incoming`
   - Call **status callback**: `POST {FRONTEND_URL}/umi/voice/<digits>/status`
   - (the `<Dial action>` / recording callbacks are emitted by our TwiML automatically)
4. **Create the mobile macro:** `bundle exec rails 'umi:voice:create_call_macro[<account_id>]'` → the "📞 Call contact" macro appears in the agent app (web + mobile).
5. **Agents:** install + configure Groundwire per `GROUNDWIRE_AGENT_SETUP.md` (SIP cred, Transport TCP, Incoming Calls = Push, **Incoming Caller ID = Remote-Party-ID first**).

**Verify:** inbound PSTN → softphone rings with contact name + conversation screen-pops & logs; web Call button rings agent then bridges; mobile macro does the same; (if enabled) recording attaches.

---

## 5. Channel — WhatsApp messaging (same number, via Meta Cloud API)  ⚙️ + ⛔

> **Use Meta Cloud API, not the Twilio WhatsApp sender.** Reason: WhatsApp *calling* later (§6) needs us to own
> the Cloud-API `calling.sip.servers` setting, which a Twilio-managed sender doesn't expose — and a number can
> only live on one WhatsApp account. You already operate a Meta app (`2163627007746338`) + a Cloud-API WhatsApp
> inbox, so this is the natural home. The Twilio number still does PSTN voice; WhatsApp rides Meta's data plane on
> the same E.164.

1. **Register +66975311301 on your WABA via Meta Cloud API** (Meta Business / WhatsApp Manager, under your existing
   app): add the number → verify ownership via **OTP** (SMS or voice — sent to the number; mind interception, prefer
   voice-OTP) → submit **display name** → complete **Meta Business Verification**. *(Wizard minutes; verification **weeks**.)*
   Collect `phone_number_id`, `business_account_id` (WABA ID), and a **permanent access token**.
2. **Create the Chatwoot inbox:** Settings → Inboxes → Add → **WhatsApp** → **WhatsApp Cloud** (manual). Enter
   `name`, `phone_number` (E.164), `phone_number_id`, `business_account_id`, `api_key` (permanent token). Chatwoot
   auto-generates the `webhook_verify_token` and auto-registers the webhook at Meta.
3. **Webhook** (Chatwoot configures this for `whatsapp_cloud`; verify in Meta if needed):
   - `GET/POST https://chat.umi.store/webhooks/whatsapp/66975311301`
4. **Add agents** to the inbox; configure assignment/routing as usual.

**Verify:** a WhatsApp message to the number creates or appends a conversation; agent reply delivers; 24-hour session-window + template rules apply.

---

## 6. Channel — WhatsApp Business Calling  🚧 (later phase — Meta-direct SIP + PBX; the proven path)

**WhatsApp calling on a softphone IS achievable — via Meta's own Cloud API SIP delivery, not Twilio.**
- **Twilio's** WhatsApp Business Calling only terminates to a WebRTC/Voice-SDK `<Client>` (Flex/IVR); it rejects
  WA→PSTN and is silent on `<Dial><Sip>`. → **not our path.**
- **Meta-direct SIP** — documented, GA (Jul 2025), proven by practitioners with real Asterisk/FreeSWITCH/Jambonz
  configs: Meta originates the inbound call straight to *your* SIP server (TLS:5061, Opus + SRTP, tagged
  `X-FB-External-Domain: wa.meta.vc`). → **this is the path**, and it rings Groundwire through a PBX.

**Architecture:**
```
WhatsApp call → Meta Cloud API (calling.sip.servers) → Jambonz PBX (Opus+SRTP) → Groundwire (agent)
                                                        └─ webhook → POST /umi/voice/pbx/call_event
                                                           → Umi::Call(provider: whatsapp) + voice_call
                                                           → Chatwoot screen-pop + call log
```
- **PBX = Jambonz (recommended):** webhook-native like Twilio, so call control + the event→Chatwoot logging map
  ~1:1 onto the existing umi backend, keeping Chatwoot *in the loop* (logging, even click-to-call). Asterisk /
  FreeSWITCH work too but need AMI/ARI/dialplan glue and only let Chatwoot *observe*.
- **Same Groundwire** rings for both PSTN (Twilio SIP Domain) and WhatsApp (the PBX) — Groundwire speaks Opus+SRTP.
- **Logging = identical to PSTN, different event source.** New code: the `pbx/call_event` endpoint (shared-secret)
  + generalize `Umi::Voice::InboundCallBuilder` to accept the WhatsApp Cloud inbox; **reuse** `Umi::Call` (the
  `whatsapp` provider enum already exists), `CallMessageBuilder`, `CallStatus::Manager`, and contact-by-E.164 match.

**Requirements / gates:**
- WhatsApp on **Meta Cloud API** (`whatsapp_cloud`, §5) — NOT a Twilio sender (Cloud API owns the calling settings).
- Enable: `POST /{phone_number_id}/settings` → `calling: { status: ENABLED, sip: { status: ENABLED, servers:[{hostname, port:5061}] }}`;
  retrieve SIP creds with `?fields=calling&include_sip_credentials=true`. SDES- or DTLS-SRTP; **Opus only** (Meta
  does **not** transcode — the PBX must speak Opus+SRTP).
- TLS cert on the PBX SIP host; identify inbound by header `X-FB-External-Domain: wa.meta.vc`; `rewrite_contact=no`
  (a documented practitioner footgun).
- **≥ 2,000-conv tier → Meta Business Verification (weeks)**; business-initiated WA calls excluded in
  US/Canada/Egypt/Nigeria/Türkiye/Vietnam (**Thailand is clear**); `VOICE_CALL_REQUEST` consent for business-initiated.

**Build steps (later phase):**
1. Stand up Jambonz (or Asterisk) with a TLS SIP endpoint + Opus; register agents' Groundwire to it.
2. Enable WhatsApp calling on the number (the `settings` call above) → point `calling.sip.servers` at the PBX.
3. **Spike:** place a WhatsApp call → PBX rings Groundwire (two-way audio?) → PBX posts the event → confirm an
   `Umi::Call` + `voice_call` appears in Chatwoot.
4. Add the `pbx/call_event` endpoint + generalize the inbound builder; fold into PR / `UMI-PATCHES.md`.

> **Meantime (calling not enabled):** there is **no WhatsApp call button** for customers → nothing to handle. Voice
> is covered by **PSTN** on the same number (Plan A) — customers who want to talk call the number normally, or
> message. Sources: developers.facebook.com/docs/whatsapp/cloud-api/calling/sip, nimblea.pe, orencloud.com.

---

## 7. Channel — LINE messenger  ⚙️ (separate from the number)

1. Create a **LINE Official Account**, then in the **LINE Developers console** create a **Messaging API**
   channel. Collect: **Channel ID**, **Channel secret**, and a long-lived **Channel access token**.
2. **Create the Chatwoot inbox:** Settings → Inboxes → Add → **LINE**. Enter `name`, `line_channel_id`,
   `line_channel_secret`, `line_channel_token`.
3. **Set the webhook in the LINE console** → Messaging API → Webhook URL:
   - `POST {FRONTEND_URL}/webhooks/line/<line_channel_id>` (the path segment must equal the Channel ID)
   - Enable **"Use webhook"**; disable LINE's **auto-reply / greeting** messages (so the bot doesn't answer).
4. **Add agents** to the inbox.

**Verify:** a message to the LINE OA creates a conversation in Chatwoot; agent replies deliver; media works.

---

## 8. Test plan (per channel)

- **Voice — inbound:** call the number → softphone rings (locked screen, via push) showing the **contact name** → answer → two-way audio → conversation screen-pops and a `voice_call` entry logs with status/duration.
- **Voice — outbound (web):** open a contact's conversation → **Call** → your softphone rings → bridges to the contact → logged.
- **Voice — mobile:** in the iOS/Android Chatwoot app, run the **"📞 Call contact"** macro on an assigned conversation → your softphone rings → bridges → logged.
- **Voice — recording** (if `UMI_VOICE_RECORDING=true`): after a call, the recording attaches to the call/conversation.
- **WhatsApp messaging:** send a WA message to the number → conversation appears → reply delivers → confirm 24h window / template behavior.
- **WhatsApp calling** (later phase, §6): place a WhatsApp call → Meta SIP → Jambonz PBX rings Groundwire → PBX posts `pbx/call_event` → an `Umi::Call` + `voice_call` logs in Chatwoot.
- **LINE:** message the LINE OA → conversation appears → reply delivers → media renders.

---

## 9. Agent instructions

- **Voice (all agents):** `GROUNDWIRE_AGENT_SETUP.md` — install Groundwire, enter the per-agent SIP credential, Transport TCP, Incoming Calls = Push, **Incoming Caller ID = Remote-Party-ID first** (so the contact name shows).
- **Mobile click-to-call:** tap the **"📞 Call contact"** macro inside a conversation → your phone rings, then connects to the contact. (Inbound just rings — no action needed.)
- **Messaging (WhatsApp / LINE):** no extra setup — these appear as normal inboxes in the Chatwoot web & mobile apps. Standard reply / assignment / routing applies.

---

## 10. Cutover order, rollback, ownership

**Order (don't block fast channels on the slow one):**
1. Deploy the umi voice build → wire Twilio voice webhooks → create the macro → **test voice** (OK on the temp number). ✅ live.
2. Register **WhatsApp on +66975311301 via Meta Cloud API** + Meta Business Verification (the multi-week critical path).
3. Once verified: create the **WhatsApp Cloud** messaging inbox → test → live.
4. Create the **LINE** inbox (independent; can be done anytime) → test → live.
5. **WhatsApp calling last** — stand up the Jambonz PBX, enable Meta SIP calling, run the spike, add the `pbx/call_event` bridge.

**Rollback (per channel):** disable/delete the inbox in Chatwoot and remove the provider-side webhook;
voice rolls back by reverting the number's Voice webhooks + redeploying the prior image tag.

**Ownership:** deploy + Twilio/Meta/LINE config = ops (you); voice backend + the WhatsApp-calling `pbx/call_event` bridge = this fork.

---

## 11. Open decisions & gates (resolve these)

1. **WhatsApp provider — DECIDED: Meta Cloud API** (`whatsapp_cloud`) on +66975311301, not the Twilio sender (§5),
   so the Cloud-API `calling.sip.servers` setting stays under our control for the calling phase.
2. **WhatsApp calling — path DECIDED: Meta-direct SIP + Jambonz PBX** (§6), logged via `pbx/call_event` →
   `Umi::Call`. Open sub-decision: when to schedule the PBX build (defer until messaging is live + verified).
3. **Callee geography.** Business-initiated WA calls are blocked to US/Canada/Egypt/Nigeria/Türkiye/Vietnam.
   If your customers are there, WA *calling* won't reach them outbound.
4. **Data residency.** Accept US1 (US) for Twilio-side data, or request **Singapore WABA localization** for
   WhatsApp content (Meta-side).
5. **Meta Business Verification owner + timeline.** This is the multi-week critical path for everything WhatsApp.

---

## 12. Reference — exact webhook URLs (this codebase)

| Channel | Provider-side webhook to configure |
|---|---|
| Voice (incoming) | `POST {FRONTEND_URL}/umi/voice/<digits>/incoming` |
| Voice (status) | `POST {FRONTEND_URL}/umi/voice/<digits>/status` |
| WhatsApp (Cloud API) inbound | `GET/POST {FRONTEND_URL}/webhooks/whatsapp/66975311301` *(Chatwoot auto-registers)* |
| WhatsApp calling (later) | Meta `calling.sip.servers` → PBX; PBX → `POST {FRONTEND_URL}/umi/voice/pbx/call_event` |
| LINE inbound | `POST {FRONTEND_URL}/webhooks/line/<line_channel_id>` |

`{FRONTEND_URL}` is the public base of the Chatwoot install (same value the voice backend uses to build URLs).
