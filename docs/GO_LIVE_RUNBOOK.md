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
| **Voice calls** (PSTN in/out) | umi voice backend → Twilio SIP Domain → Groundwire | ✅ live (inbound + outbound tested) | per-agent SIP creds provisioned |
| **Mobile click-to-call** | "📞 Call contact" macro → `/umi/voice/macro_dial` | ✅ built (PR #3) | macro created post-deploy via rake |
| **WhatsApp messaging** | Twilio **WhatsApp Sender** (`Channel::TwilioSms`, `medium: whatsapp`) on +66975311301 → Chatwoot | ✅ live (inbound tested) | Twilio-managed WABA; auto-verified as BSP |
| **WhatsApp Business Calling** | Twilio **WhatsApp Business Calling** → TwiML App `<Dial><Sip>` → Groundwire (reuses the PSTN voice stack, no PBX) | 🚧 later phase | ⛔ Business Verification + ≥2,000-conv/24h tier |
| **LINE messenger** | LINE OA **@umi.store** → `Channel::Line` | ✅ live | separate from the number; Bot mode + webhooks on, auto-reply off |

**One-number model (+66975311301):** **Twilio** carries **everything on this number** — PSTN voice *and* WhatsApp
(messaging now via a Twilio-managed WABA, calling later via Twilio WhatsApp Business Calling). In Chatwoot this
lands as **two separate inboxes on the one number** — "WhatsApp (+66)" (`Channel::TwilioSms`, `phone_number:
whatsapp:+66975311301`) and "Voice (+66)" (`Channel::TwilioSms`, plain `+66975311301`) — because the differing
`phone_number` strings both satisfy the unique index; they can't be merged. A **separate**, pre-existing number
**+66800053593** runs WhatsApp on **Meta Cloud API direct** (Chatwoot inbox "Whatsapp") — which is why the two
numbers use different WhatsApp stacks. LINE is its own LINE Official Account, unrelated to the number.

---

## 1. What is code vs. configuration

- **Custom-built (this fork):** the **voice backend** (inbound/outbound/recording/macro). Done, tested, in PR #3.
- **Native Chatwoot config (no code):** **WhatsApp messaging** (a Twilio WhatsApp Sender → `Channel::TwilioSms` inbox) and **LINE** are standard OSS inbox types — you register the sender / channel with the provider and point its webhook at Chatwoot. No fork work.
- **WhatsApp _calling_ (later phase):** see §6. Planned via **Twilio WhatsApp Business Calling**: the Twilio sender's Voice Endpoint → a TwiML App that `<Dial><Sip>`s the agent's Groundwire — **reusing the existing PSTN voice `<Dial><Sip>` stack, no PBX**. Gated on Meta Business Verification + the ≥2,000-conv/24h messaging tier.

---

## 2. Prerequisites & accounts

| Need | Detail | Lead time |
|---|---|---|
| **Twilio number** | Voice-capable; on the existing **US1** account. Carries Voice + WhatsApp (+66975311301). | minutes |
| **Twilio SIP Domain** | For agents' Groundwire (register on Singapore edge, dial GLOBAL). Per `CALLS_BACKEND_SPEC.md §10`. | minutes |
| **Meta Business** | Business Portfolio + **Business Verification** — only needed for WhatsApp **calling** (gates the ≥2,000-conv volume tier). WhatsApp **messaging** does NOT need it: the Twilio-managed WABA auto-verifies. | **several weeks** (calling only) |
| **LINE Official Account** | + a LINE Developers **Messaging API** channel (id/secret/token). | hours–days |
| **Deployed umi build** | The branch carrying PR #3 (voice backend) — per `FORK.md`. | per deploy |

> **Data residency note:** US1 keeps Twilio-side data in the US; the **Singapore SIP edge** only reduces
> voice latency, it does not move residency. If WhatsApp _content_ must live in Asia, set the **WABA
> data-localization region to Singapore** (Meta-side, via Twilio support) — independent of US1.

---

## 3. Provision the Twilio number

1. Buy a **Voice-capable** number on the US1 account; record its SID and E.164. (**+66975311301** is the live number.)
2. Voice setup (SIP Domain, credential lists, edges, per-agent SIP users) → follow **`CALLS_BACKEND_SPEC.md §10` + `§14.7`** (the validated build recipe). Don't re-derive here.
3. WhatsApp registration is §5 — on the **same** number via a Twilio WhatsApp Sender (near-instant, auto-verified).

---

## 4. Channel — Voice calls  ✅ (live — inbound + outbound tested)

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

## 5. Channel — WhatsApp messaging (same number, via a Twilio WhatsApp Sender)  ✅ (live — inbound tested)

> **Registered via Twilio WhatsApp Senders, not Meta Cloud API direct.** Because the number lives on Twilio, the
> cleanest path is to let **Twilio** be the BSP: Console → **Messaging → Senders → WhatsApp senders** → add a
> sender → **"Continue with Facebook"** self-sign-up, which creates a **new Twilio-managed WABA** for the number.
> Since Twilio owns +66975311301, the sender **auto-verifies** — Twilio catches the OTP as the BSP and shows the
> code in the Console; **no manual OTP chase**. (The separate number **+66800053593** predates this and runs on
> **Meta Cloud API direct** — Chatwoot inbox "Whatsapp" — which is why the two numbers use different WhatsApp stacks.)

1. **Register the sender** (Twilio Console → Messaging → Senders → WhatsApp senders → "Continue with Facebook").
   Twilio provisions the Twilio-managed WABA and auto-verifies the number. Set the sender's **profile** — name,
   description, email, website — in the Twilio Console sender form. *(about text, profile photo, and vertical are set
   on the Meta side in **WhatsApp Manager**; Twilio doesn't mirror those.)*
2. Set the sender's **"Webhook URL for incoming messages"** → `https://chat.umi.store/twilio/callback`.
3. **Create the Chatwoot inbox:** this is a **`Channel::TwilioSms`** inbox with **`phone_number = whatsapp:+66975311301`**
   (WITH the `whatsapp:` prefix — the incoming lookup `find_by(phone_number: params[:To])` and the send
   `from: phone_number` both use it verbatim) and **`medium: whatsapp`**. Because this string differs from the plain
   `+66975311301` of the Voice channel, the **unique `phone_number` index allows both** → you end up with **two
   separate inboxes on one number** ("WhatsApp (+66)" + "Voice (+66)"); they can't be merged.
4. **Add agents** to the inbox; configure assignment/routing as usual.

**Verify:** ✅ tested — a WhatsApp message to +66975311301 created a conversation in Chatwoot; the 24-hour
session-window + template rules apply as normal for Twilio WhatsApp.

---

## 6. Channel — WhatsApp Business Calling  🚧 (later phase — Twilio WhatsApp Business Calling, no PBX)

**Plan changed** from the earlier "Meta-native SIP → Jambonz PBX" idea to **Twilio WhatsApp Business Calling**,
because the number is a Twilio-managed WhatsApp sender: WhatsApp calls arrive at Twilio and route into
**Programmable Voice**, so we reuse the PSTN voice stack instead of standing up a PBX.

**Architecture:**
```
WhatsApp call → Twilio sender Voice Endpoint → TwiML App → <Dial><Sip> → Groundwire (agent)
              → the same umi voice callbacks log Umi::Call(provider: whatsapp) + voice_call → Chatwoot screen-pop
```
- **No PBX.** The Twilio sender's **Voice Endpoint** → "Connect to a **TwiML Application**" → a TwiML app whose
  webhook returns the same `<Dial><Sip>sip:agent@…</Sip>` used for PSTN voice, ringing the agent's Groundwire.
- **Same Groundwire, same backend.** This reuses the existing PSTN voice `<Dial><Sip>` machinery, contact-by-E.164
  match, `Umi::Call` (the `whatsapp` provider enum already exists), and the call-log/screen-pop path.

**Why not Meta-native SIP → your own PBX:** it remains a theoretical alternative, but it's **mutually exclusive**
with the webhook/Graph (BSP) mode the number is already in, is **undocumented for BSP-registered numbers**, and
needs a **PBX** — so we chose the Twilio path.

**Requirements / gates:**
- **Meta Business Verification + the ≥2,000-conv/24h messaging tier** (not day-one).
- Business-initiated WhatsApp calling is excluded in some countries; **Thailand is NOT on the outbound-exclusion list.**

**Build steps (later phase):**
1. Enable WhatsApp Business Calling on the Twilio sender; point its Voice Endpoint → a TwiML App.
2. Have the TwiML App webhook return the voice `<Dial><Sip>` (reuse the existing `incoming` TwiML).
3. **Spike:** place a WhatsApp call → Twilio → TwiML App `<Dial><Sip>` → Groundwire rings (two-way audio?) → confirm
   an `Umi::Call` + `voice_call` appears in Chatwoot.

> **One honest caveat to verify live:** Twilio docs confirm WhatsApp calls route into Programmable Voice and
> **can't bridge to PSTN**, but they don't *explicitly* enumerate `<Sip>` as an allowed bridge target — so confirm
> the `<Dial><Sip>` bridge with a live test when enabling. **Meantime (calling not enabled):** there is **no
> WhatsApp call button** for customers → nothing to handle. Voice is covered by **PSTN** on the same number —
> customers who want to talk call the number normally, or message.

---

## 7. Channel — LINE messenger  ✅ (live — @umi.store, separate from the number)

> **Being set up now** via `Channel::Line` — a LINE Official Account + a Messaging API channel wired to a Chatwoot LINE inbox.

1. Create a **LINE Official Account**, then in the **LINE Developers console** create a **Messaging API**
   channel. Collect: **Channel ID**, **Channel secret**, and a long-lived **Channel access token**.
2. **Create the Chatwoot inbox:** Settings → Inboxes → Add → **LINE**. Enter `name`, `line_channel_id`,
   `line_channel_secret`, `line_channel_token`.
3. **Set the webhook in the LINE console** → Messaging API → Webhook URL:
   - `POST {FRONTEND_URL}/webhooks/line/<line_channel_id>` (the path segment must equal the Channel ID)
   - Enable **"Use webhook"**; disable LINE's **auto-reply / greeting** messages (so the bot doesn't answer).
4. **Add agents** to the inbox.

**Verify:** a message to the LINE OA creates a conversation in Chatwoot; agent replies deliver; media works.

### Storefront contact links — keep in sync when a number/handle changes

The customer-facing contact details live in **three** places; update all three together:
- **Chatwoot widget** — `app/javascript/widget/components/pageComponents/Home/UmiInboxLinks.vue` (hardcoded WhatsApp / LINE / Messenger / Instagram quick-links; baked into the image → needs a rebuild + deploy).
- **Storefront theme** — `umi-store-theme` → `templates/page.stand.json` (`phone_number`, `whatsapp_url`, `line_url`).
- **Shopify store settings** — Settings → Store details → phone.

Current values: **phone / WhatsApp = `+66975311301`**, **LINE = `@umi.store`** (`line.me/R/ti/p/~@umi.store`), Messenger = `m.me/umi.clothing.store`, Instagram = `ig.me/m/umi.asia`.

---

## 8. Test plan (per channel)

- **Voice — inbound:** call the number → softphone rings (locked screen, via push) showing the **contact name** → answer → two-way audio → conversation screen-pops and a `voice_call` entry logs with status/duration.
- **Voice — outbound (web):** open a contact's conversation → **Call** → your softphone rings → bridges to the contact → logged.
- **Voice — mobile:** in the iOS/Android Chatwoot app, run the **"📞 Call contact"** macro on an assigned conversation → your softphone rings → bridges → logged.
- **Voice — recording** (if `UMI_VOICE_RECORDING=true`): after a call, the recording attaches to the call/conversation.
- **WhatsApp messaging** ✅: send a WA message to +66975311301 → conversation appears → reply delivers → confirm 24h window / template behavior. *(Verified — inbound message received.)*
- **WhatsApp calling** (later phase, §6): place a WhatsApp call → Twilio → TwiML App `<Dial><Sip>` rings Groundwire → an `Umi::Call` + `voice_call` logs in Chatwoot.
- **LINE:** message the LINE OA → conversation appears → reply delivers → media renders.

---

## 9. Agent instructions

- **Voice (all agents):** `GROUNDWIRE_AGENT_SETUP.md` — install Groundwire, enter the per-agent SIP credential, Transport TCP, Incoming Calls = Push, **Incoming Caller ID = Remote-Party-ID first** (so the contact name shows).
- **Mobile click-to-call:** tap the **"📞 Call contact"** macro inside a conversation → your phone rings, then connects to the contact. (Inbound just rings — no action needed.)
- **Messaging (WhatsApp / LINE):** no extra setup — these appear as normal inboxes in the Chatwoot web & mobile apps. Standard reply / assignment / routing applies.

---

## 10. Cutover order, rollback, ownership

**Order (don't block fast channels on the slow one):**
1. Deploy the umi voice build → wire Twilio voice webhooks → create the macro → **test voice**. ✅ live (inbound + outbound tested).
2. Register the **Twilio WhatsApp Sender** on +66975311301 (self-sign-up, auto-verified) → create the `Channel::TwilioSms` WhatsApp inbox → test. ✅ live (inbound tested).
3. Create the **LINE** inbox (independent) → test → **live (@umi.store)**.
4. **WhatsApp calling last** — enable Twilio WhatsApp Business Calling, point the sender's Voice Endpoint at a TwiML App that `<Dial><Sip>`s Groundwire, run the spike. Gated on Meta Business Verification + the ≥2,000-conv tier.

**Rollback (per channel):** disable/delete the inbox in Chatwoot and remove the provider-side webhook;
voice rolls back by reverting the number's Voice webhooks + redeploying the prior image tag.

**Ownership:** deploy + Twilio/Meta/LINE config = ops (you); voice backend (reused for WhatsApp calling) = this fork.

---

## 11. Open decisions & gates (resolve these)

1. **WhatsApp provider — DECIDED: Twilio WhatsApp Sender** (`Channel::TwilioSms`, `medium: whatsapp`) on
   +66975311301 (§5). Twilio owns the number, so the sender auto-verifies as BSP and messaging went live near-instantly.
   (The separate +66800053593 stays on Meta Cloud API direct.)
2. **WhatsApp calling — path DECIDED: Twilio WhatsApp Business Calling** (§6) — sender Voice Endpoint → TwiML App
   `<Dial><Sip>` → Groundwire, reusing the PSTN voice stack (no PBX). Open sub-decision: when to schedule it
   (defer until Business Verification + the ≥2,000-conv tier land). Verify the `<Dial><Sip>` bridge live.
3. **Callee geography.** Business-initiated WA calls are blocked in some countries; **Thailand is clear.**
   If your customers are elsewhere-excluded, WA *calling* won't reach them outbound.
4. **Data residency.** Accept US1 (US) for Twilio-side data, or request **Singapore WABA localization** for
   WhatsApp content (Meta-side, via Twilio support).
5. **Meta Business Verification owner + timeline.** Now only the critical path for WhatsApp **calling** (messaging is already live).

---

## 12. Reference — exact webhook URLs (this codebase)

| Channel | Provider-side webhook to configure |
|---|---|
| Voice (incoming) | `POST {FRONTEND_URL}/umi/voice/<digits>/incoming` |
| Voice (status) | `POST {FRONTEND_URL}/umi/voice/<digits>/status` |
| WhatsApp (Twilio Sender) inbound | `POST https://chat.umi.store/twilio/callback` *(set on the sender's "Webhook URL for incoming messages")* |
| WhatsApp calling (later) | Twilio sender Voice Endpoint → TwiML App → `<Dial><Sip>` (the existing voice TwiML) |
| LINE inbound | `POST {FRONTEND_URL}/webhooks/line/<line_channel_id>` |

`{FRONTEND_URL}` is the public base of the Chatwoot install (same value the voice backend uses to build URLs).
