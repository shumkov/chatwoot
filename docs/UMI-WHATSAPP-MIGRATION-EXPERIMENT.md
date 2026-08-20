# UMI WhatsApp number → Klaviyo: can `+66975311301` verify, and what proves it

Status: investigation. **Nothing was bought, migrated, registered, deregistered, or
reconfigured.** Every Twilio call made for this document was a `GET`, and only the free
Lookup tier was used. No credential value appears here or left the production container.

Date: 2026-08-20
Companion: `docs/UMI-SHARED-NUMBER-SPEC.md` — §1.2 (phone-level override is per-app,
confirmed live) and §2.1 (patch 26 guards, `854d58c5a`).

Evidence convention: **VERIFIED** = observed directly, in this account or this checkout.
**INFERRED** = the best reading of real evidence, but not itself observed. **UNKNOWN** = not
settled, and labelled as such rather than dressed up.

---

## Retraction — read this before reusing any earlier version of this document

An earlier revision of this file marked **"Meta's voice call reaches this number and gets
answered" as VERIFIED**, on the strength of six inbound calls from two US numbers on
2026-07-05. **That label was not earned.** The call log showed calls arriving; it did not
show who was calling. Two US numbers ringing a brand-new Thai number on its setup weekend is
equally consistent with someone testing their own line — which is exactly what Ivan
suggested, and it was a reasonable challenge.

Two things follow, and both are worth writing down:

1. **The claim has since been properly verified — by different evidence.** Twilio holds
   exactly one call recording on this account, and it already carried a completed
   transcription. Its text is quoted in §2.3. It settles the question outright.
2. **Being right by luck is still a process failure.** The conclusion survived; the reasoning
   that produced it did not deserve to. The lesson is the one Ivan named: a caller ID and a
   plausible story are not identification. The fix was to go and find the artefact.

A second over-claim from the same revision is also retracted here: *"inbound SMS to this
number demonstrably works, so Meta's SMS not arriving is not a capability problem."* Three
KBank messages prove **domestic Thai** delivery only. §2.4 replaces that inference with
Twilio's documented rules, which point the other way.

---

## 0. The two questions

1. **Klaviyo.** Does their BSP migration re-verify a number that cannot receive an OTP?
2. **Twilio.** Does removing a WhatsApp sender affect the number's voice service or the
   account's ownership of the number?

Short version. Klaviyo **does** demand a live verification code — settled from their own
runbook. But UMI already owns primary evidence that **Meta's verification voice call reached
`+66975311301`, spoke the code, and was captured on a Twilio recording**; the July attempt
failed because UMI's voice handler errored mid-sentence, not because the code never arrived.
SMS is **structurally impossible** for this number, per Twilio's own documented short-code
rules. And the tooling to capture the code cleanly **already exists and is deployed**. The
recommended path therefore costs **nothing**. Question 2 remains undocumented and
observation-only.

---

## 1. Step 0 — which WABA is the number in, and who owns it?

### 1.1 Status: NOT OBSERVED. Blocked on a login I am not permitted to perform.

Only visible in Meta Business Manager (Business Settings → Accounts → WhatsApp Accounts, or
WhatsApp Manager). Twilio's Senders API returns an empty `waba_id`, and Chatwoot cannot help:
the number's two rows are `Channel::TwilioSms` — id 2 (`+66975311301`, `medium: sms`, inbox 5,
created 2026-07-04) and id 3 (`whatsapp:+66975311301`, `medium: whatsapp`, inbox 6, created
2026-07-05) — and that model stores no WABA or phone-number ID.

Ivan's Chrome profile is **logged out of both `business.facebook.com` and `klaviyo.com`**
(VERIFIED: both redirect to a password form). **To unblock (about two minutes):** log in to
Facebook in that profile, then say go. The extension already holds permission for
`business.facebook.com`.

**What to read off the page, in this order:**

| Field | Where | Why it matters |
|---|---|---|
| WABA name and ID | Business Settings → Accounts → WhatsApp Accounts | Identity; needed for every later Graph call |
| Owning portfolio | The portfolio switcher; a WABA owned elsewhere shows under *Shared with you* rather than *Owned* | Decides H1 vs H2 below |
| Admin / people | WABA → People | Whether UMI can grant its own app access without Twilio |
| Connected/subscribed apps | WABA → Apps (or `GET /{waba-id}/subscribed_apps`) | The seat patch 26 wants |
| Business verification state | Security Centre | Meta gates parts of migration and sending on it |
| Two-step verification PIN | WhatsApp Manager → the number → Two-step verification | Must be **off** to migrate, and cannot be turned off via API |

### 1.2 The two hypotheses

The number was registered through **Twilio Console → Senders → WhatsApp senders → "Continue
with Facebook" → create a new WABA in that flow**. That is Meta Embedded Signup running under
Twilio's tech-provider app, and it can land either way:

**H1 — the WABA sits in the UMI STORE CO., LTD. portfolio, with Twilio's app subscribed.**
The ordinary Embedded Signup contract and, on balance, the likelier outcome.

**H2 — the WABA belongs to a Twilio-owned portfolio, with UMI granted access.** Possible if
the signup dialog defaulted to a portfolio that is not UMI's.

### 1.3 Even H1 is not "just add Klaviyo as a connected app"

Klaviyo's own migration article forecloses it, verbatim:

> "**Create a new WABA for Klaviyo** within that portfolio. Do not reuse your existing WABA."

So the number changes WABAs regardless. Klaviyo does not attach itself as a second app to
someone else's WABA — it provisions its own and expects the number to move in. The "second
app on one WABA" architecture in the companion spec is *Chatwoot's* role; Klaviyo is the
incumbent, which is exactly why patch 26 exists.

What H1 buys: Klaviyo's hard prerequisite is already satisfied (*"You must use the same Meta
Business Portfolio"* — Klaviyo names a different portfolio as the most common cause of failed
migrations); source and destination WABA under one portfolio is Meta's supported
intra-business move; and patch 26 has somewhere to point.

What H2 costs: Klaviyo's portfolio prerequisite is unsatisfiable as-is, and the WABA or number
must be brought into UMI's portfolio first. **If step 0 returns H2, stop and fix ownership
before anything else.**

---

## 2. What the Twilio account actually shows (observed 2026-08-20, read-only)

Method: `rails runner` inside the production Chatwoot container, using the credentials on
`Channel::TwilioSms` with `Net::HTTP` basic auth. GETs only.

### 2.1 The number is a Thai **mobile** number — VERIFIED

`PNf160f13eed1ae9ab96a25dc1bd9f6c55` / `+66975311301`, purchased **2026-06-26**, status
`in-use`, `origin: twilio`, `address_requirements: "any"`. It is the **only** number on the
account. It appears in `/IncomingPhoneNumbers/**Mobile**.json` and not in `Local.json` or
`TollFree.json`; its bundle's regulation is **"Thailand: Mobile - Business"**. Capabilities:
`voice: true, sms: true, mms: false`. Voice URL:
`https://chat.umi.store/umi/voice/66975311301/incoming`. SMS URL: still Twilio's demo endpoint.

Twilio's live Thai inventory and pricing, queried today:

| TH number type | SMS | Voice | Monthly |
|---|---|---|---|
| local | **✗** | ✓ | **$25.00** |
| **mobile** | **✓** | ✓ | **$22.00** |
| toll-free | **✗** | ✓ | $25.00 |

Two things fall out. In Thailand **only the mobile type carries SMS at all**. And a Thai
**local** number is *more* expensive than mobile ($25 vs $22) while testing *less* — so the
"cheaper voice-only local number" idea is refuted on Twilio's own price list, not on judgement.

### 2.2 The Thai paperwork is already done and reusable — VERIFIED

| Bundle | Regulation | Status | Created |
|---|---|---|---|
| `BUe5aff5a92082ef66d1896fab122164e6` | Thailand: **Mobile** - Business | **`twilio-approved`** | 2026-06-22 |
| `BUc4db8cd786c2489098fe80ea6f469a0d` ("UMI STORE — TH Local Voice") | Thailand: Local - Business | **`twilio-approved`** | 2026-06-14 |
| `BU4ab355a87fcfd42727a44b95bec39a87` | Thailand: Mobile - Business | `twilio-rejected` | 2026-06-16 |

The approved mobile bundle has `valid_until: null`; address `AD6f0a37531f78fef3c48ece3095694958`
is attached to the number. The rejected-then-approved pair shows roughly six days and one
rejection already paid for — for Thailand's heaviest document set (business name, corporate
registration number, address, plus the legal representative's identity, ID number and address).
Twilio documents that an approved bundle is reusable for further numbers of the same country
**and** type. Live TH mobile inventory today: `+66975310955`, `+66975310922`, `+66975311546` —
the same **`+6697531xxxx`** carrier block as production.

So a Thai mobile test number *is* available for ~$22 if wanted. §5 explains why it is no
longer the recommended path.

### 2.3 The 2026-07-05 calls **were** Meta's verification calls — VERIFIED, by recording

**The artefact.** Twilio holds exactly **one** recording on this entire account:
`REe6530e9b50e40c6bfa9669a5a6a62531`, `source: "RecordVerb"`, 11 seconds, created
**2026-07-05 04:52:12 UTC**, on call `CA13f9bb2b4698b74acee2153be52e6c56` — the inbound call
from **+1 949 531 7728**. A completed transcription already existed on it. Its full text:

> "Your verification code is 503, we are sorry, an application error has occurred. Good bye."

That single line settles four things at once:

* **VERIFIED — Meta's WhatsApp verification voice call reaches a Twilio Thai mobile number.**
  The robot is on the recording, reading a code.
* **VERIFIED — the code is audible and capturable.** A plain TwiML `<Record>` verb caught it,
  and Twilio's own transcription rendered it as text at no extra effort.
* **VERIFIED — the July attempt failed because UMI's voice handling errored mid-sentence.**
  "We are sorry, an application error has occurred. Good bye" is Twilio's own apology, and it
  cut the robot off after three digits of a six-digit code. The specific alert (error 11200)
  is **still unrecoverable** — see below — but the audible symptom is now primary evidence,
  which is stronger than the alert would have been.
* **DISPROVEN — the "our own test calls" hypothesis**, for this call. Ivan's challenge was
  methodologically right and factually wrong, and it is the reason the artefact was found.

**Scope of the verification.** The transcript identifies **one** call. The other five from the
same two US numbers that day are **INFERRED (high)** to be the same verification campaign:
same two origins, same morning, all before the Twilio-Senders fallback channel row was created
at 13:51:39 UTC. Note that one of them (03:49:30) was bridged to Ivan's own Thai mobile and
another (08:56:14) to `+66927400421` — so a human may well have heard part of a code live.

**The rest of the call record, for completeness:**

| Time (UTC) | From | Status | Dur | Paired leg |
|---|---|---|---|---|
| 2026-07-04 04:28:02 | +66 97978 3972 | completed | 17 s | dial → `sip:agent1@…` |
| 2026-07-05 03:33:05 | +1 657 999 1951 | no-answer | 0 s | dial → `sip:agent-1@…` no-answer |
| 2026-07-05 03:33:37 | +1 657 999 1951 | no-answer | 0 s | dial → `sip:agent-1@…` no-answer |
| 2026-07-05 03:35:40 | +1 949 531 7728 | completed | 6 s | dial → `sip:agent-1@…` answered |
| 2026-07-05 03:49:30 | +1 657 999 1951 | completed | 8 s | dial → +66 97978 3972 |
| **2026-07-05 04:52:11** | **+1 949 531 7728** | **completed** | **12 s** | **→ `<Record>` (the recording)** |
| 2026-07-05 08:56:14 | +1 657 999 1951 | completed | 5 s | dial → +66 92740 0421 |

Every inbound call has a paired outbound leg, and Chatwoot created conversations 22 and 23 for
the two US numbers — so **the voice webhook was reachable and returning TwiML that day**. The
failure was inside the call flow (dial legs not answered, then an error), not a dead endpoint.

**What is still not recoverable.** Twilio's Monitor Alerts retain ~30 days: the account holds
three alerts, all 2026-08-11, all error 14101 (the demo `sms_url` trying to auto-reply to
KBank). The 2026-06-20…07-10 window returns **zero**. Legacy `/Notifications.json` returns
**404**. Per-call `Notifications` subresources return **0**. The error code itself is gone for
good — but nothing now depends on it.

**Also VERIFIED, and useful:** between the purchase on 2026-06-26 and 2026-07-04 there were
**no inbound calls at all**, and US-origin calls to this line are not unusual — `+15755717399`
called on 2026-08-09 and was handled normally by production. Caller country proves nothing on
its own, which is the whole point of the retraction above.

### 2.4 SMS is structurally impossible for this number — VERIFIED, twice over

Settled from Twilio's and Thailand's documented rules rather than from "we never saw one":

* **VERIFIED (Twilio)** — Twilio long-code numbers **cannot receive messages from short codes
  by default**. It can be enabled on a paid account by request, but with a hard constraint: a
  short code can only send to long codes **in the same country as the short code**. Meta's
  verification SMS is sent from a short code. A US/global short code therefore cannot reach a
  Thai long code, enabled or not.
* **VERIFIED (Thailand)** — from 2025-10-06 Thai operators block SMS from unregistered
  alphanumeric sender IDs **and international long codes**. So the long-code fallback is shut
  as well.
* **This explains the KBank observation properly.** KBank is a *Thai domestic* sender to a
  *Thai* number — the one route that is open. Their arrival says nothing about an
  international Meta OTP, and the earlier revision was wrong to treat it as reassurance.
* **INFERRED (third-party only)** — that carriers additionally apply recipient-side filtering
  against VoIP/virtual numbers for OTP traffic. Plausible and consistent, but asserted by
  vendor blogs rather than Twilio or Meta. It does not matter: the two verified rules above
  already close the door.

**Conclusion: do not attempt the SMS leg. Voice is the only path — and voice is proven to
work on this exact number.**

### 2.5 The capture tooling already exists and is deployed — VERIFIED

`umi/app/controllers/voice/webhooks_controller.rb#otp_capture`, routed by
`config/initializers/zz_umi_voice.rb:31` as `POST /umi/voice/:phone/otp_capture`. Its own
comment states the purpose exactly:

> "Number-onboarding helper for a phoneless Twilio number that a provider (e.g. Meta/WhatsApp
> Cloud API) verifies with a voice OTP. Point the number's Voice URL here during onboarding,
> then revert it to `incoming`."

Two modes:

* `?to=+E164` → `<Dial answerOnBridge="true">` to a real phone, so the provider waits for a
  human before reading. The comment calls this "the reliable path", and notes some providers
  error when a machine answers.
* no `to` → `<Record transcribe="true" maxLength="30" timeout="10" playBeep="false">` —
  answer, record, and let Twilio transcribe. This is precisely the mechanism that produced the
  §2.3 evidence.

**Confirmed live in production**: both the route line and the full current implementation
(including the answerOnBridge branch) are present in the deployed image. Nothing needs
building, deploying, or writing.

Related state, VERIFIED: `Channel::TwilioSms` id 2 has `umi_recording_enabled? == false`, so
ordinary answered calls are **not** recorded today — the `otp_capture` endpoint is the
deliberate, scoped way in, not a standing recording of customer calls.

---

## 3. What the vendors' own documentation settles

### 3.1 Klaviyo does demand a verification code — VERIFIED from their docs

> "Confirm you can receive a text or call on the phone number being migrated. You'll need it
> for verification during setup."

> "Enter the phone number you want to migrate. Enter the verification code sent to your number
> to complete the migration."

> "Pick how you want to verify this number (either text message or phone call)." … "Enter the
> 6-digit code to verify your phone number."

So question 1's answer is **yes**. There is no "we are a BSP, we will vouch for it" path.

### 3.2 …and Klaviyo offers exactly the leg that works

> "If using a Google Voice number, choose to verify by a phone call."

Klaviyo already knows VoIP numbers do not get the SMS, and offers the voice call. Read with
§2.3 (voice reached this number and the code was audible) and §2.4 (SMS cannot reach it), the
route is unambiguous: **choose the phone call.**

### 3.3 Meta's country and language restrictions — UNKNOWN, informatively

* **VERIFIED** — `POST /{phone-number-id}/request_code` takes `code_method` ∈ {`SMS`, `VOICE`}
  and a required `language` locale matching `^[a-z]{2}_[A-Z]{2}$`. The **caller chooses the
  language**; it is not derived from the number's country. The July recording was in English,
  consistent with an `en_US`-style default.
* **VERIFIED by absence** — Meta's own pages for `request_code` and for solution-provider
  registration document **no** country restriction on voice verification, **no** carrier or
  number-type restriction, and **no** locale list. The only documented limits are generic Graph
  rate limits, code expiry, and temporary blocking after repeated failures.
* **VERIFIED** — Meta does not ban VoIP. Its recommended action is *"Confirm that the VoIP
  provider supports international SMS/calls for OTPs"* — a compatibility warning aimed at the
  voice leg, not a prohibition. UMI's recording is that confirmation.
* **INFERRED, non-Meta sources only** — blog claims that VoIP/virtual numbers are blocked
  outright. Directly contradicted by §2.3.
* **UNKNOWN** — whether `th_TH` is an accepted locale, and whether an unsupported locale is
  rejected or silently defaulted. Request `en_US` explicitly and the question does not arise.

### 3.4 Why Twilio's auto-verify does not travel with the number — INFERRED

Meta's Embedded Signup accepts a `preverified_id`: a provider that owns a number can
pre-register it and onboard without any OTP. That is how Twilio auto-verifies. The
pre-verification is bound to the owning provider, so Klaviyo cannot present one for a number
Twilio owns.

The corollary is a real alternative: **a number bought through Klaviyo's own flow has no OTP
problem at all.** Klaviyo lists "existing number, purchased from a provider (e.g. Twilio or
Infobip), or requested free from Meta during setup." Giving marketing a *different* number
removes every risk in this document, at the cost of the one-number premise.

### 3.5 Two-step verification must be off, and Chatwoot must not invent one

Meta requires 2SV **disabled** on a number being migrated between WABAs, and it cannot be
disabled through the API — only in WhatsApp Manager. Klaviyo's own first step is *"Click **Turn
off two-step verification**."*

Same PIN namespace patch 26 protects: `register_phone_number` invents a PIN with `SecureRandom`
and a **successful** call is the damaging one. Patch 26 makes it raise on a foreign-owned
channel. Keep it that way, and check the number's 2SV state during step 0.

### 3.6 Twilio documents nothing about leaving — VERIFIED by absence

Twilio's *Migrate phone numbers and WhatsApp senders* page covers three journeys: from the
WhatsApp Business app, from another BSP, and between Twilio accounts. Nothing about migrating
away, deleting a sender, or what becomes of the number. Question 2 is undocumented.

Structurally the `IncomingPhoneNumber` and the WhatsApp `Sender` are separate resources —
voice URL, SIP routing and bundle all hang off the former, which the production record
confirms. Deleting the sender *should* leave voice and ownership untouched. **That remains
UNKNOWN and is the one thing genuinely worth watching during the migration** (§5, step 6).

One documented adjacent fact: to re-register the same number as a Twilio sender after deleting
it, 2FA must be off for the number in WhatsApp Manager. The rollback direction is at least a
known path.

---

## 4. Two things to check before committing to a migration window

### 4.1 Is Klaviyo's WhatsApp product available on UMI's plan? — UNKNOWN

Chrome is logged out of Klaviyo, so this is unobserved. Public material: WhatsApp rides the
**Email + SMS** bundle rather than the free/email-only tier, shares the SMS credit pool, and
requires **Owner or Admin**. No plan gate on *connecting* is documented — the gate, if any, is
likelier on sending. That is an inference.

**Settle it by looking:** Klaviyo → Settings → WhatsApp. If **Connect to WhatsApp** is present
and clickable, the path in §5 is open. If it shows an upsell or "contact sales", stop there.
**Do not buy a plan upgrade to find out.**

### 4.2 Does connecting pollute the real Klaviyo account? — partly

1. Klaviyo's WhatsApp connection is **account-level and singular**.
2. Disconnecting **permanently removes that WABA's message templates**, which must be recreated
   and resubmitted to Meta. Zero cost today (no templates yet); real cost later. **So if
   anything is going to be tried, try it before template work begins.**
3. Under the §5 path this barely applies: the real number is being connected, not a throwaway,
   so the slot is being used for its intended purpose.

---

## 5. Recommended path: **buy nothing** — $0, about 30 minutes

The question was "what is the simplest, cheapest way to settle whether UMI's number can
complete WhatsApp verification, and to capture the code?" For this number, **the delivery half
and the capture half are already settled by primary evidence** (§2.3) — on the production
number itself, which is better evidence than any proxy could produce. The SMS half is settled
by documentation (§2.4). And the capture rig is already written and deployed (§2.5).

What remains is not an experiment. It is a fifteen-minute operational step inside the real
migration window.

**Exact steps.**

0. **Prerequisites:** step 0 answered and it is H1 (§1.2); Klaviyo's *Connect to WhatsApp* is
   available (§4.1); 2SV off on the number in WhatsApp Manager (§3.5); an agreed off-hours
   window, because inbound customer calls will be diverted for its duration.
1. **Record the current Voice URL** so it can be restored verbatim:
   `https://chat.umi.store/umi/voice/66975311301/incoming` (POST).
2. **Point the Voice URL at the OTP capture endpoint** —
   `https://chat.umi.store/umi/voice/66975311301/otp_capture?to=<the mobile that will answer>`.
   Use the `?to=` form: its comment calls it "the reliable path", because the provider waits
   for a human to answer before reading, and some providers error when a machine answers.
   Belt and braces: without `?to=` it records and transcribes instead, which is what produced
   §2.3's evidence — either mode works, and neither needs new code.
3. **Start Klaviyo's flow** (Settings → WhatsApp → Connect to WhatsApp → migration branch) and
   when it asks how to verify, **choose the phone call**, never the text message (§2.4).
4. **Answer the phone and write the code down.** If nobody answers in time, the fallback mode
   records and Twilio transcribes it — read it in the console, exactly as §2.3 was read.
5. **Enter the code in Klaviyo.**
6. **Restore the Voice URL immediately** to the value from step 1, and place one test call to
   confirm normal agent ringing is back.
7. **Then check question 2:** confirm the number is still in the Twilio account with its
   `voice_url`, `bundle_sid` and `address_sid` unchanged, and place one more call. This is the
   only genuinely unknown thing left, and it is observed for free as a by-product.

**Cost: $0** plus a few cents of call time. **Time: ~30 minutes**, most of it Klaviyo's UI.

**What each result proves.**

| Result | Proves |
|---|---|
| Voice option offered, code heard, Klaviyo accepts it | The migration works. Delivery, capture and verification all confirmed end-to-end on the real number. |
| No verification step appears at all | Even better — Meta treated it as an intra-portfolio move (H1). |
| Voice option offered, call arrives, code partially cut | The capture rig needs the other mode; retry with the `<Record>` variant. Recoverable inside the window. |
| Only SMS offered, no voice option | Klaviyo's UI, not Meta, is the blocker. Escalate to Klaviyo support with §2.3 and §2.4 as evidence. |
| Call never arrives | Contradicts §2.3; something changed at Meta or in Thai call routing. Stop and re-investigate before deregistering anything. |

**What it does not prove:** anything about Chatwoot's side (§7), and nothing until step 0 is
answered.

**Where it can still fail.**

* Klaviyo's flow may not expose a voice option on the *migration* branch even though the
  *new-number* branch does. This is the largest residual risk and it is unknowable in advance.
* The number goes dark from the moment migration starts until Meta finishes review — Klaviyo
  says so explicitly. Duration unknown.
* Diverting the Voice URL diverts real inbound calls. Keep the window short and off-hours.
* If the code is cut off again, the retry budget is limited: Meta rate-limits verification
  requests and blocks temporarily after repeated failures (§3.3).
* Everything in §1.3 still applies: this is a WABA change, not an app addition.

---

## 6. Runner-up, and what was rejected

**Runner-up — a $0 dry-run of the capture rig, before the real window.** Point the Voice URL at
`otp_capture?to=<mobile>` for two minutes, call the number from any phone, confirm the bridge
connects and audio is audible (or that a recording and transcription appear in the fallback
mode), then restore. Cost: a few cents. This rehearses the only mechanical step that can go
wrong, on the actual number, without Meta, without a new number, and without a WABA. **If any
insurance is wanted, buy this one rather than a number.** It is listed as runner-up only
because it is a production change and so needs its own approval; if approved, do it.

**Rejected — the $22 Thai mobile rehearsal** (buy `+6697531xxxx`, throwaway WABA,
`request_code` → capture → `verify_code`). This was the previous recommendation and it is now
worse than doing nothing. It would re-prove, on a *fresh* number with no history, what §2.3
already proves on the *production* number with its real history. It cannot rehearse the part
that actually differs — Klaviyo's UI branch on a seasoned number — and it spends $22 plus a
few hours plus Meta asset churn to lower an already-small risk. Keep it in reserve for one
case only: if step 0 returns H2 and a cross-portfolio move has to be practised.

**Rejected — a Thai local number.** Refuted on Twilio's own price list: **$25.00/month, more
than mobile's $22.00**, with `SMS: false` and a different regulation. More expensive and tests
strictly less.

**Rejected — a US local number ($1.15).** Wrong country and wrong number class, on exactly the
axis that matters; a pass would not transfer and a failure would not be attributable. Moot now.

**Rejected — pursuing the SMS leg.** Closed twice over by documented rules (§2.4).

**Rejected — asking Klaviyo or Meta support first.** The brief's premise, and it still holds:
the answers arrive slowly and may be wrong. §2.3 was faster and is authoritative. Support
becomes the right move only in the "only SMS offered" branch of §5.

---

## 7. What this still does not prove

1. **Klaviyo's migration branch.** Whether it offers voice verification at all. The single
   largest remaining unknown, and only §5 answers it.
2. **Step 0.** Ownership is still unobserved; H2 changes the plan (§1.2).
3. **Question 2 — voice surviving deregistration.** Undocumented (§3.6); §5 step 7 observes it,
   but only after the fact, on the production number. There is no risk-free way to learn this
   first, which is an argument for a short window and a rollback plan, not for a rehearsal.
4. **What the number keeps.** HIGH quality rating, approved display name, messaging tier and
   any OBA status. Meta documents that migrated numbers retain these; not verified for this
   number.
5. **Downtime length.** Klaviyo warns the number cannot send or receive from the start of
   migration until Meta's review completes. Duration unknown and not simulable.
6. **The 11200 error code.** Permanently unrecoverable (§2.3). The audible symptom is verified;
   the code is not, and nobody should later cite it as established.
7. **Chatwoot as the second app under real load.** §1.2 of the companion spec still has no real
   inbound `messages` delivery test on a two-app number.
8. **Whether the other five 2026-07-05 calls were Meta's.** Only the recorded one is verified.

---

## 8. Open decisions for Ivan

1. **Log in to Facebook in Chrome** so step 0 can be observed. Everything branches on H1 vs H2.
2. **Look at Klaviyo → Settings → WhatsApp** — is *Connect to WhatsApp* clickable?
3. **Approve the $0 dry-run in §6**, or skip straight to §5. Both are production changes to the
   Voice URL and neither will be made without a yes.
4. **Decide whether the one-number premise is negotiable** (§3.4). A Klaviyo-provisioned
   marketing number removes every risk here; it costs the unified-number story.

## Sources

* [Klaviyo — How to migrate from another WhatsApp Business Solution Provider to Klaviyo](https://help.klaviyo.com/hc/en-us/articles/40116637850651)
* [Klaviyo — How to connect your WhatsApp Business account to Klaviyo](https://help.klaviyo.com/hc/en-us/articles/40111819732635)
* [Twilio — Can Twilio numbers receive SMS from a short code?](https://support.twilio.com/hc/en-us/articles/223181668-Can-Twilio-numbers-receive-SMS-from-a-short-code)
* [Twilio — Thailand: SMS Guidelines](https://www.twilio.com/en-us/guidelines/th/sms)
* [Twilio — Thailand: Regulatory Guidelines](https://www.twilio.com/en-us/guidelines/th/regulatory)
* [Twilio — Migrate phone numbers and WhatsApp senders](https://www.twilio.com/docs/whatsapp/migrate-numbers-and-senders)
* [Twilio — Phone Number Regulatory FAQ](https://www.twilio.com/docs/phone-numbers/regulatory/faq)
* [Twilio — Bundles Resource](https://www.twilio.com/docs/phone-numbers/regulatory/api/bundles)
* [Meta — Phone Number Verification Request Code API](https://developers.facebook.com/documentation/business-messaging/whatsapp/reference/whatsapp-business-phone-number/phone-number-verification-request-code-api)
* [Meta — Registering phone numbers (solution providers)](https://developers.facebook.com/docs/whatsapp/solution-providers/phone-numbers/registering-phone-numbers/)
* [Meta — Business phone numbers](https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/phone-numbers)
* [Meta — Two-step verification](https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/two-step-verification/)
