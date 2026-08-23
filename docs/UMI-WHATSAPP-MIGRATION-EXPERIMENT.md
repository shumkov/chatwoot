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
recommended path therefore costs **nothing**. Step 0 is now answered (§1): the WABA is
**UMI's own**, in UMI's own portfolio, with Twilio as a partner — which satisfies Klaviyo's
portfolio prerequisite outright. And Klaviyo's migration branch has now been walked (§4.1b):
it never asks how to verify — it collects the number and hands off to **Meta's** embedded
sign-up, which owns that choice. So the last risk is no longer "Klaviyo might force SMS"; it is
"Meta's sign-up must offer the call", and Meta's voice OTP has already been observed reaching
this number. Question 2 remains undocumented and observation-only.

**Where things stand**

| Question | Status |
|---|---|
| Which WABA, whose portfolio (step 0) | **ANSWERED, favourable** — WABA "UMI" `1673373860633578`, owned by UMI STORE CO., LTD.; Twilio is a partner, not the owner (§1) |
| Does Meta's voice OTP reach this number, and can we capture it | **VERIFIED** by the 2026-07-05 Twilio recording and its transcription (§2.3) |
| Can the SMS leg ever work | **NO — ruled out structurally** by Twilio's short-code rules and Thailand's international-long-code block (§2.4) |
| Is the capture tooling built | **YES, already deployed** — `otp_capture` (§2.5) |
| Cost of the recommended path | **$0** (§5) |
| Is Klaviyo's WhatsApp product available to UMI | **YES, and not yet activated** — Settings → WhatsApp offers *"Try WhatsApp for free"*, no paywall or sales gate (§4.1a) |
| Does Klaviyo's migration branch offer voice? | **MOOT.** Klaviyo never offers a method; and Meta's dialog never offers the number (§10.2, §10.4) |
| **Can `+66975311301` enter Klaviyo's flow at all?** | **NO — Meta marks it `Ineligible`, "not eligible to be shared with this app", and offers no migrate option.** Whether that is caused by two-step verification still being on, or by Twilio's binding, is the one open question (§10.4) |

---

## 1. Step 0 — ANSWERED (observed 2026-08-20 in Meta Business Manager, read-only)

**H1 is confirmed.** The WABA is UMI's own, in UMI's own portfolio, with Twilio attached as a
partner rather than as the owner. All VERIFIED, all read from Business Settings and WhatsApp
Manager; nothing was changed and no confirmation was clicked.

| Fact | Value |
|---|---|
| Business portfolio | **UMI STORE CO., LTD.**, `business_id 497970999394825`. Business verification **Verified**; account status **Approved** |
| WABA | **"UMI"**, ID **`1673373860633578`** |
| Owner | *"Owned by: UMI STORE CO., LTD."* — **not** a Twilio-provisioned portfolio |
| Phone number | **+66 97 531 1301**, Thailand. Display name **"UMI"** (visible to customers). Status **Connected** |
| Quality rating | **High** |
| Messaging limit | **2,000** business-initiated conversations per rolling 24 h (updated 20 Aug 14:39 GMT+7) |
| Next tier | 10,000 — requires 1,000 unique customers in a rolling 7 days; currently **14** |
| People | **Ivan Shumkov only**, Full access. Sole admin. |
| Partners | **Twilio, Inc — "Partners with full control"** |
| Payment method | **Credit line — TWILIO INC.** |

Two other WABAs sit in the same portfolio: **"UMI clothing"**, holding **+66 80 005 3593** (the
Cloud-API-direct number behind the "Whatsapp" inbox), and **"Test WhatsApp Business Account"**
(`4445932492313560`).

**Housekeeping note, VERIFIED, unrelated to this migration:** that test WABA is the throwaway
from the companion spec's §1.2 override experiment, whose teardown log records it as removed.
**It is still present in the production portfolio.** Harmless, but the teardown log is wrong —
remove the WABA or correct the spec.

### 1.1 Not obtained, and why — the subscribed-apps list

`GET /{waba-id}/subscribed_apps` needs either a Graph token or Business Settings → Accounts →
**Apps**, and that page is gated behind a **Meta 2FA passkey re-authentication** prompt
("Confirm that it's you with your passkey"). I stopped there rather than work an authentication
challenge. **UNKNOWN.**

What is known instead: the WABA's Partners tab lists exactly one partner — **Twilio, Inc, with
full control** — and the conversation credit line is Twilio's. **INFERRED (high)**: Twilio's app
is the only subscriber today. To settle it, either complete the passkey prompt and open
Business Settings → Apps, or ask a system-user token with `whatsapp_business_management`.

### 1.2 What H1 means — better than expected, but not a shortcut

Genuinely good news:

* **Klaviyo's hard prerequisite is already satisfied.** *"You must use the same Meta Business
  Portfolio"* — the WABA is in UMI's own portfolio, and Klaviyo names a mismatched portfolio as
  the most common cause of failed migrations. Nothing has to be prised out of Twilio first.
* **Ivan is the sole person with full access**, so no third party approves anything Meta-side.
* **The asset is healthy** — verified portfolio, Connected, quality High, 2,000/24h — and Meta
  documents that a migrated number keeps its display name, quality rating, messaging limit and
  approved templates.
* **Patch 26 has somewhere to point:** UMI can grant its own Meta app access to a WABA it owns.

The limit is unchanged, and it is worth restating because H1 is the outcome that tempts people
to assume a shortcut. Klaviyo requires a *new* WABA — *"Create a new WABA for Klaviyo within
that portfolio. Do not reuse your existing WABA."* The number still moves out of WABA "UMI"
into a Klaviyo-provisioned one. What H1 buys is that the move is **intra-portfolio** — Meta's
supported and lighter path — rather than a cross-business BSP handover.

**A new question this observation raises.** Twilio holds **partner full control** over the
source WABA. Whether a number can be migrated out from under a partner with full control
without that partner's cooperation is **UNKNOWN**, and it is the same undocumented territory as
§3.6. It does not change the recommended path, but it belongs on the risk list.

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

## 4. The Klaviyo side — reached 2026-08-20; one question answered, the decisive one not

### 4.1 What Klaviyo actually shows (observed read-only, submitting nothing)

Reached at last, in the `personal@shumabook` Chrome profile after Ivan paired it. Everything
below is read from the UI; no button that connects, confirms or submits was clicked.

**4.1a Is the product available on UMI's plan? — VERIFIED: yes, and it is not yet turned on.**

There is **no "Connect to WhatsApp" on this account today.** Settings → WhatsApp is a marketing
splash — *"Unlock the world's #1 mobile messaging app"* — whose only control is a single
**"Try WhatsApp for free"** button. That is the important nuance: not a paywall, not a "contact
sales" upsell, not a tier gate. The product is offered, free to start, and simply has not been
started.

The supporting entitlement is already there. Billing → Overview, cycle 13 Aug – 13 Sep 2026:

| Plan line | Value |
|---|---|
| Monthly total | **$30.00** |
| Profiles | 1,000 active (**734 used, 73%**) |
| Emails | 10,000 sends (0 used) |
| **Mobile messaging** | **$5.00 SMS spend** (0 used) — the pool WhatsApp shares |
| Reviews | 50 orders processed |
| Composer | 10,000 AI credits, 82 days remaining |

So the earlier inference in this document — that WhatsApp rides the mobile-messaging bundle and
that the gate, if any, is on sending rather than connecting — holds up: the mobile-messaging
line exists, and the WhatsApp tab shows an activation CTA rather than an upsell.

**4.1b Does the migration branch offer a phone call, or SMS only? — Klaviyo never asks. The
choice is Meta's, and it sits downstream of a phone number.**

With Ivan's authorisation the activation button was pressed and the migration branch walked to
the point where it demands a number. What it contains, VERIFIED:

1. **"Are you currently using WhatsApp for your business?"** — *"Select the best option for your
   business to get instructions for **Meta's embedded sign-up experience**."* Options: *No, I am
   not using WhatsApp for business* / *Yes, I currently use WhatsApp for business*. The second is
   the migration branch and is the one taken.
2. **"Tips for a successful migration"** — two items, both matching this document's expectations:
   * *"Turn off two-step verification for phone in Meta"* — tooltip: *"In the WhatsApp Business
     account you're migrating from, go to WhatsApp Manager, find your phone number settings, and
     turn off 2FA."* This confirms §3.5 from Klaviyo's own UI.
   * *"Disable WhatsApp business app (only for business app users)"* — tooltip: *"This only
     applies for the official WhatsApp Business app for small businesses. It is not the same as
     the WhatsApp Business platform, which is for service providers like Klaviyo."* Not
     applicable to UMI, which is on the platform via Twilio.
3. **"Are you ready to connect?"** — *"Add your phone number. When migrating, using your current
   WhatsApp phone number is strongly recommended."* A checkbox **"Use my current WhatsApp
   number — Recommended"**, ticked by default (tooltip: *"By using your current number, you can
   continue to message customers in the same WhatsApp thread."*), then a country selector
   (defaulting to +1) and an empty number field, then *"What's your current display name?"*.
   Header controls: **Save & close / Back / Next**.

**Stopped there.** Entering a number was not authorised, and it is the gate: **the verification
method is not visible without committing a number** — precisely the outcome named in advance as
a real finding rather than a failure.

**But the walk reframes the question, and favourably.** Klaviyo's wizard never presents a
verification-method choice at all, and now it is clear why its migration article never names
one: **Klaviyo does not own that screen.** By its own words on screen 1 it collects the number
and display name and then hands off to *Meta's embedded sign-up experience*. The SMS-vs-voice
choice belongs to Meta, downstream of the number.

Grading this carefully, because over-claiming is the failure mode this document already had to
retract once:

* **VERIFIED** — Klaviyo's migration branch collects a number and display name and then defers
  to Meta's embedded sign-up; Klaviyo itself never offers or restricts a verification method.
* **VERIFIED** — the method cannot be seen without committing a number.
* **INFERRED (moderate)** — since the choice is Meta's, and Meta's embedded sign-up is the same
  flow that elsewhere offers *"either text message or phone call"*, and Meta's own API exposes
  `code_method: SMS | VOICE` with no documented country or number-type restriction (§3.3), the
  voice option is likely present on this path too. **Likely is not proven.** Nobody has seen
  Meta's verification screen on a migration where the number is already registered to another
  BSP, and that specific case is where a surprise would live.
* **UNKNOWN** — whether that screen offers voice for `+66975311301` in particular.

**What it means.** The one risk that could sink the plan is materially smaller than it looked,
because it is no longer "Klaviyo might have hard-coded SMS" — Klaviyo has hard-coded nothing.
It is now "Meta's embedded sign-up must offer the call", against a vendor whose API documents
both methods and whose voice OTP has already been observed reaching this exact number (§2.3).
The plan proceeds, with the residual risk retired at the moment someone enters the number.

**State the Klaviyo account was left in: unchanged.** Re-opened Settings → WhatsApp after
backing out — identical *"Try WhatsApp for free"* splash, no saved progress, no connection, no
WABA, no phone number. Billing → Overview re-checked: still $30.00/month with the same four
plan lines (Profiles 1,000 / 734 used, Emails 10,000, Mobile messaging $5.00 SMS spend,
Reviews 50) and **no WhatsApp line item added**. **"Save & close" was never clicked** — the
wizard was exited by navigating away, which discarded it. Nothing was created, so **nothing is
added to the teardown checklist in §9**.

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

0. **Prerequisites:** step 0 answered and it is H1 — **done, §1**; Klaviyo's WhatsApp product is
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

1. **Meta's verification screen on the migration path.** Klaviyo is cleared — it never asks
   (§4.1b) — but the screen that does ask belongs to Meta's embedded sign-up and appears only
   after the number is committed. Nobody has seen it for a number already registered to another
   BSP. Still the largest open item, though smaller than it was: SMS cannot reach this number
   by any route, so the call has to be on offer.
2. **Whether Twilio's partner full control blocks the move.** New, raised by §1.2: Twilio holds
   *"full control"* as partner on the source WABA. Whether the number can be migrated out
   without Twilio's cooperation is undocumented, and the same silence as §3.6 covers it.
3. **The subscribed-apps list** (§1.1) — behind a 2FA passkey prompt. Twilio being the sole
   partner makes "Twilio's app only" likely, not certain.
4. **Question 2 — voice surviving deregistration.** Undocumented (§3.6); §5 step 7 observes it,
   but only after the fact, on the production number. There is no risk-free way to learn this
   first, which is an argument for a short window and a rollback plan, not for a rehearsal.
5. **What the number keeps.** Quality **High**, display name "UMI", the 2,000/24h limit and any
   approved templates — all now confirmed present (§1). Meta documents that a migrated number
   retains them; that it does so *for this number* is not verified.
6. **Downtime length.** Klaviyo warns the number cannot send or receive from the start of
   migration until Meta's review completes. Duration unknown and not simulable.
7. **The 11200 error code.** Permanently unrecoverable (§2.3). The audible symptom is verified;
   the code is not, and nobody should later cite it as established.
8. **Chatwoot as the second app under real load.** §1.2 of the companion spec still has no real
   inbound `messages` delivery test on a two-app number.
9. **Whether the other five 2026-07-05 calls were Meta's.** Only the recorded one is verified.

---

## 8. Open decisions for Ivan

1. **Decide whether to commit the number.** §4.1b is walked as far as it goes without one: the
   verification method is Meta's, not Klaviyo's, and it appears only after the number is entered.
   Entering `+66975311301` there starts the real migration — the number goes dark until Meta's
   review completes — so it is a scheduled operation, not a probe. Do it in the §5 window, with
   the Voice URL already pointed at `otp_capture`, so the code is captured on the first attempt.
   Cheapest moment is still now, before any template work exists (§4.2).
2. **Optionally clear the passkey prompt** so the subscribed-apps list (§1.1) can be read, and
   decide what to do about the leftover `Test WhatsApp Business Account` (§1).
3. **Approve the $0 dry-run in §6**, or skip straight to §5. Both are production changes to the
   Voice URL and neither will be made without a yes.
4. **Decide whether the one-number premise is negotiable** (§3.4). A Klaviyo-provisioned
   marketing number removes every risk here; it costs the unified-number story.

---

## 9. Teardown checklist — planned now, to run once the experiments finish

**Do not execute this yet.** Written on request so cleanup is planned rather than improvised.

**Verify, do not trust the log.** The companion spec's §1.2 teardown log records assets as
removed that are demonstrably still present. Two were re-checked today and *both* were still
there. Treat every "already done" claim in this table as unverified until its own verification
step passes.

**Ivan's, because they need a Meta password or 2FA — neither of us enters those:** items 1, 2
and 3. I could not even *read* item 2's page: Business Settings → Accounts → Apps is gated
behind a Meta passkey re-authentication prompt.

| # | Item | Owner | State verified 2026-08-20 | Remove by | Verify it is gone |
|---|---|---|---|---|---|
| 1 | WABA **Test WhatsApp Business Account** `4445932492313560` (from the §1.2 override spike) | **Ivan** — Meta 2FA | **STILL PRESENT** in portfolio `497970999394825`; visible in both Business Settings → WhatsApp accounts and WhatsApp Manager, despite the spec's teardown log | Business Settings → WhatsApp accounts → select → Remove | The WhatsApp accounts list shows only **UMI** and **UMI clothing** |
| 2 | Meta apps **ZZ-TEST-waba-override-app-A** `1359276892996213` and **-app-B** `3626989434121176` | **Ivan** — Meta 2FA | **UNVERIFIED** — Business Settings → Accounts → Apps is behind a passkey re-auth prompt I stopped at | Business Settings → Apps → remove; or delete the apps at developers.facebook.com | Apps list no longer shows either; `GET /{app-id}` with a valid token errors |
| 3 | System users **Zztest sysuser a** / **b**, and any tokens they still hold | **Ivan** — Meta 2FA | **UNVERIFIED** — not checked this session | Business Settings → Users → System users → remove (revoke tokens first) | System users list is clear; a previously issued token fails `GET /me` with an `OAuthException` |
| 4 | n8n workflows **ZZ-TEST-waba-collector-a** (`89goLz0JpVLjTfXB`) and **-b** (`MRYMeamf8sxyYnMr`) | Either | **STILL PRESENT, and only DEACTIVATED** — both appear in `n8n list:workflow` but not in `n8n list:workflow --active=true`. Reported archived; they were not deleted | n8n UI → delete; or `docker exec umi-n8n-n8n-1 n8n delete:workflow --id=<id>` | `docker exec umi-n8n-n8n-1 n8n list:workflow \| grep ZZ-TEST` returns nothing |
| 5 | Any Twilio number bought for an experiment | Either | **NONE BOUGHT.** The account holds exactly one `IncomingPhoneNumber`, `+66975311301` (production) | Release it in the Console or via `DELETE /IncomingPhoneNumbers/{sid}` — this is what stops the monthly charge | `GET /IncomingPhoneNumbers.json` returns only the production number. **Do not delete the regulatory bundles** — they are shared with production (§2.2) |
| 6 | Any WABA or connection created in **Klaviyo** during a migration rehearsal | Ivan (needs a Klaviyo login) | **NONE.** The onboarding wizard was opened and walked to the number field on 2026-08-20, then abandoned by navigating away — "Save & close" was never clicked. Re-checked afterwards: Settings → WhatsApp is back to the untouched "Try WhatsApp for free" splash, and Billing shows no WhatsApp line item | Klaviyo → Settings → WhatsApp → disconnect. **⚠ Disconnecting a WABA permanently destroys that WABA's message templates**; they must be recreated and resubmitted to Meta, so do this only on a throwaway WABA or before real template work exists | Settings → WhatsApp shows no connected WABA, and no Klaviyo-provisioned WABA remains in portfolio `497970999394825` |
| 7 | Shopify test order **#1601** | **Ivan's** | **UNVERIFIED** — the Shopify MCP connection needs re-authorization (token expired), so I could not read its current state | Refund or cancel it in Shopify admin | The order shows **Refunded** or **Cancelled** in the admin |
| 8 | This worktree and its branch | Either, **but not from inside it** | herdr session `home`, workspace **`w5X`**, path `/Users/ivanshumkov/Projects/shumkov/chatwoot.migration-test`, branch `umi-waba-migration-experiment`, **4 commits ahead of `origin/umi`, all documentation** | See the procedure below | `herdr workspace list --session home` no longer lists `w5X`, and the path is gone from disk |

**Item 8, in full, because the order matters.**

1. Merge or abandon `umi-waba-migration-experiment` first. All four commits are docs-only, so
   nothing is lost by merging; but the branch is the only copy of this investigation.
2. Quiesce any agent session in the workspace — ask it to stop background work — then sweep for
   processes that outlived it:
   `lsof -d cwd 2>/dev/null | awk '$NF ~ "^/Users/ivanshumkov/Projects/shumkov/chatwoot.migration-test" {print $2, $1, $NF}' | sort -u`
   Report anything found and confirm before killing; a stuck build looks exactly like a runaway.
3. `herdr worktree remove --workspace w5X --force --session home` — **never raw
   `git worktree remove`**, which orphans the herdr workspace and makes it invisible to
   `herdr worktree list`.
4. **Run step 3 from a different session.** `w5X` is the workspace this session lives in;
   removing it terminates this session mid-command.
5. Sibling workspaces **`w43`** (`chatwoot.feat-shumabit`) and **`w4D`** (`chatwoot.crm`) are
   unrelated work — do not touch them. The source repo workspace is `wG`.

**Not on this list, deliberately:** the production WABA "UMI", its number, the Twilio senders,
the regulatory bundles, both Chatwoot channels, and WABA "UMI clothing". Nothing in this
investigation touched them, and nothing in teardown should.

---

## 10. Migration log — phase 1 (2026-08-22)

Ivan authorised the migration and a phase-1 run that goes as far as Klaviyo's verification
screen and stops. Patch 26 is live in production (`umi-v4.16.0-7@sha256:cbf934e5…`), so Chatwoot
can be re-added to a Klaviyo-owned number afterwards. He has also decided **not** to repoint the
public WhatsApp links — inbox 6 has had 13 messages ever, so a short dark window is acceptable.

### 10.1 Restore point — `+66975311301` voice configuration before any change

Read from Twilio at **2026-08-22T10:03:10Z**, `IncomingPhoneNumber`
`PNf160f13eed1ae9ab96a25dc1bd9f6c55`. **This is the byte-for-byte restore target.** Only
`voice_url` is being changed; every other field below must read identically afterwards.

| Field | Value |
|---|---|
| `voice_url` | **`https://chat.umi.store/umi/voice/66975311301/incoming`** ← restore this |
| `voice_method` | `POST` |
| `voice_fallback_url` | `nil` |
| `voice_fallback_method` | `POST` |
| `voice_caller_id_lookup` | `false` |
| `voice_application_sid` | `nil` |
| `voice_receive_mode` | `voice` |
| `trunk_sid` | `nil` |
| `status_callback` | `https://chat.umi.store/umi/voice/66975311301/status` |
| `status_callback_method` | `POST` |
| `sms_url` | `https://demo.twilio.com/welcome/sms/reply` |
| `sms_method` | `POST` |
| `sms_fallback_url` / `_method` | `nil` / `POST` |
| `sms_application_sid` | `""` |
| `emergency_status` | `Inactive` |
| `emergency_address_sid` | `nil` |
| `bundle_sid` | `BUe5aff5a92082ef66d1896fab122164e6` |
| `address_sid` | `AD6f0a37531f78fef3c48ece3095694958` |
| `identity_sid` | `nil` |
| `friendly_name` / `status` | `66975311301` / `in-use` |
| `capabilities` | `voice: true, sms: true, mms: false, fax: false` |

**Restore command** (one field, nothing else):

```
POST /2010-04-01/Accounts/{sid}/IncomingPhoneNumbers/PNf160f13eed1ae9ab96a25dc1bd9f6c55.json
VoiceUrl=https://chat.umi.store/umi/voice/66975311301/incoming
```

**While the Voice URL is diverted, inbound customer calls do not ring agents** — they hit
`otp_capture`, which records and transcribes instead. Keep the window short and restore as soon
as the verification screen has been read.

### 10.2 Phase 1 result (2026-08-22) — the number is inert; the commitment point is one click later

Walked with the Voice URL diverted to `otp_capture` as insurance. **Nothing was sent and
nothing moved.**

**What entering the number actually does: nothing.** Country set to Thailand, `+66 97 531 1301`
entered, **Next** clicked. No verification code was requested, offered, or sent. VERIFIED
afterwards from Twilio: **zero inbound calls to the number all day** (`Calls?To=+66975311301`
since 2026-08-22 → count 0) and **zero inbound SMS in the preceding two hours**. The boundary is
not where the brief feared — submitting the number is inert on Klaviyo's side, so this screen
can be re-walked at any time at no cost.

**Where the wizard actually ends.** Klaviyo's last screen is **"WhatsApp setup guidance"** — an
outline of what Meta's embedded sign-up will do, not something Klaviyo performs:

1. Get admin access — *"Get admin access to your company's Meta Business account / Log in to
   Facebook and the Meta Business account."*
2. Create or select your business portfolio
3. Create a new WhatsApp Business account (WABA)
4. **Add and verify phone number**
5. Set up your business profile

The only forward control is **"Connect to WhatsApp"** (external-link icon), which launches
Meta's embedded sign-up in a popup.

**So the §4.1b answer is now settled definitively, by walking it end to end: Klaviyo never
offers a verification method at all.** Not "phone call alongside text message", not "SMS only" —
the choice is not Klaviyo's to present. Step 4 above happens inside Meta's embedded sign-up.
Klaviyo collects the number and display name purely to pre-fill Meta's flow.

**Why phase 1 stopped exactly here.** "Connect to WhatsApp" carries an explicit terms
acknowledgement rendered directly beneath it:

> "By clicking "Connect to WhatsApp" you acknowledge and agree that this is subject to the
> existing agreement you have in place with Klaviyo in connection with the services. You also
> acknowledge and agree that all WhatsApp applications, software, features, services, and APIs
> are separately provided by WhatsApp LLC or WhatsApp Ireland Limited … and that you are
> governed by all applicable WhatsApp and/or Meta Platforms, Inc. ("Meta") policies, including
> the WhatsApp Business Terms of Service and, if applicable, the WhatsApp Business Solution
> Terms and/or the Beta Product Testing Terms."

That is a substantive consent on Ivan's behalf, and the brief's hard stop covers it. It is also
the genuine point of no return: the same click both accepts those terms and opens the flow that
creates a WABA.

**State left behind.**

| Asset | State |
|---|---|
| Klaviyo account | **Untouched.** Re-opened Settings → WhatsApp after backing out — identical *"Try WhatsApp for free"* splash. No connection, no WABA, no stored number. "Save & close" never clicked; the wizard was abandoned by navigating away |
| WABA "UMI" / `+66975311301` | **Unchanged.** Still Connected, still on Twilio, quality High |
| Twilio `voice_url` | **STILL DIVERTED** to `.../otp_capture` — restore to `.../incoming` per §10.1 |
| Codes sent | **None** |

**What this means for phase 2.** The remaining unknown has moved from Klaviyo to Meta and
narrowed to one screen: Meta's embedded sign-up, step 4, "Add and verify phone number", for a
number already registered to another BSP. Everything up to that point is now known to be free
and reversible. Phase 2 therefore begins at the "Connect to WhatsApp" click — which needs Ivan's
explicit go, because it accepts the terms above and starts WABA creation — and the divert should
be live again before it happens, since a code becomes reachable from that point on.

### 10.3 Phase 2 attempt (2026-08-22) — paused at Meta's popup, nothing created

Authorised and attempted; **stopped by tooling, not by anything Meta or Klaviyo did.**

**What was done.** The Klaviyo wizard was re-walked (migration branch, `+66 97 531 1301`
pre-filled from the earlier run) to the guidance screen, and **"Connect to WhatsApp" was
clicked** — which accepts the Klaviyo/WhatsApp/Meta terms quoted in §10.2. That was the
authorised step.

**What blocked it.** Meta's embedded sign-up opens via `window.open` as a separate popup
**window**. The Chrome extension can only act on tabs inside its own MCP tab group, so the popup
is invisible to it — not a permissions or login problem, a scoping one. Ivan pressed Continue in
that popup manually, but the flow did not get far enough to create anything.

**Verified state after the attempt — nothing moved:**

* Portfolio `497970999394825` still holds **exactly three WABAs** (Test WhatsApp Business
  Account, UMI, UMI clothing). **No new WABA was created**, so Meta's step 3 was never completed.
* Twilio: **zero inbound calls and zero inbound SMS** to `+66975311301` all day. No code was
  requested or sent.
* Klaviyo: no connection, no stored number on the account.

**The peekaboo fallback is also unavailable, for two independent reasons** — both verified, not
assumed:

1. **No display session.** Every application reports zero capturable windows — Chrome, Safari,
   Finder, and Warp — and a full-screen capture hung until killed. The screen is locked or
   asleep; WindowServer exposes nothing.
2. **TCC grants do not cover the daemon.** `/Applications/Peekaboo.app` signs as
   `boo.peekaboo.mac`; the CLI binary the daemon actually runs
   (`/opt/homebrew/Cellar/peekaboo/4.0.0/bin/peekaboo`) signs as `boo.peekaboo.peekaboo`. TCC
   keys on the signing identifier, so a grant to the app covers nothing the daemon does, even
   though both display as "Peekaboo" in System Settings. Screen Recording read as granted only
   because the running daemon predated the mismatch; **restarting it during this session
   surfaced the gap and lost that borrowed grant.**

**To resume, cheapest first:**

1. **Allow popups for `klaviyo.com`** in the Chrome profile the extension is paired to. Meta's
   sign-up then opens as an ordinary tab, drivable directly — no screen, no TCC, no peekaboo.
2. Or, for the peekaboo route: add `/opt/homebrew/Cellar/peekaboo/4.0.0/bin/peekaboo` by path to
   **both** Screen Recording and Accessibility (expect two "Peekaboo" rows in each list — the
   app and the CLI are different clients), `launchctl kickstart -k
   gui/502/com.ivanshumkov.peekaboo-daemon`, and unlock the screen.

**Voice restored — CLOSED.** At **2026-08-22T15:41:17Z** the Voice URL was set back to
`https://chat.umi.store/umi/voice/66975311301/incoming` and the record re-read: `RESTORE OK`,
and **every field matches the §10.1 restore point exactly** — `voice_method` POST,
`status_callback` `.../status` POST, `voice_fallback_url` nil / `_method` POST,
`voice_caller_id_lookup` false, `voice_application_sid` nil, `trunk_sid` nil, `sms_url` the demo
endpoint with `sms_method` POST, `emergency_status` Inactive, `bundle_sid`
`BUe5aff5a92082ef66d1896fab122164e6`, `address_sid` `AD6f0a37531f78fef3c48ece3095694958`,
`status` in-use. Inbound calls ring agents again. The divert was live roughly 5.5 hours.

**Lesson for the next attempt:** the divert only needs to be live for the few minutes around an
actual verification request. Do not open it until the flow is known to reach Meta's verification
step — this run diverted first and then lost hours to tooling, with the line degraded throughout
and no code ever requested.

### 10.4 Phase 2, manual run (2026-08-23) — **Meta marks the number `Ineligible`. The OTP question is moot.**

Ivan drove Meta's embedded sign-up manually while this session called the steps. The flow got
one screen further than any previous attempt, and stopped at a gate nobody had anticipated.

**VERIFIED — the number cannot be selected at all.** Meta's *"Add your WhatsApp phone number"*
step (Facebook Login for Business dialog, Klaviyo app id `1424473751557007`) presents a picker
whose full contents are:

| Option | State |
|---|---|
| Enter a new phone number | selectable (defaults to **GB +44** — the wrong branch; provisions a *different* number) |
| Use a display name with a virtual number instead | selectable |
| **UMI · `+66 97 531 1301` · UMI STORE CO., LTD.** | **`Ineligible`** |
| UMI clothing · `+66 80 005 3593` · UMI STORE CO., LTD. | **`Ineligible`** |
| Test Number · `+1 555-196-6407` · UMI STORE CO., LTD. | selectable |

Hovering the ineligible row gives: **“This number isn't eligible to be shared with this app.”**

**VERIFIED — there is no "migrate an existing number" option.** The dropdown contains exactly the
five rows above. Klaviyo's wizard asks the migration question and shows migration tips, but the
Meta dialog it hands off to offers only *share an eligible number*, *provision a new one*, or
*take a virtual one*.

**What this does to the whole investigation.** Everything from §2.3 onward chased one question:
would Meta's verification screen offer a voice call, given SMS structurally cannot reach this
number? **That question is moot for this path.** The gate is one step earlier: the number is
never offered for selection, so no verification screen is ever reached. All the OTP evidence
remains true and remains useless here.

Note the third selectable row is `+1 555-196-6407` — the free test number belonging to the
leftover **Test WhatsApp Business Account** from the companion spec's §1.2 spike (§9 item 1). It
is eligible precisely because no BSP owns it.

**Cause identified 2026-08-23 — two-step verification was never turned off.** WhatsApp Manager →
Phone numbers → `+66 97 531 1301` (phone-number ID **`1101374313069948`**) → Two-step
verification reads **`Enabled`**: *"Any attempt to register your phone number on WhatsApp must be
accompanied by the six-digit PIN that you created."* Klaviyo's own tips screen leads with
*"Turn off two-step verification for phone in Meta"*, and neither attempt cleared it.

**Graded honestly: INFERRED, not proven.** 2SV being enabled is a documented migration blocker
and the obvious suspect, but Meta does not say *why* it stamped the number ineligible. The test
is cheap — clear it, wait, re-walk the wizard, and see whether the badge goes. That creates
nothing and costs nothing. Turning it off does not require knowing the current PIN, and is safe
from Chatwoot's side because patch 26 blocks `/register`, the one path that would otherwise
invent a new PIN.

The two candidate causes, in order of likelihood:

1. **Two-step verification, confirmed `Enabled`** — the leading candidate, and untested.
2. **The number is bound to a WABA that Twilio controls.** "Shared with this app" is precise
   language: a number already attached to WABA "UMI", whose only partner is Twilio with full
   control (§1), may simply not be shareable into a second BSP's app while that binding stands.

**If cause 2 holds, the shared-number plan is finished on this route.** Clearing it would mean
deregistering from Twilio *first* — taking the number dark with no guarantee Meta then makes it
eligible, and no tested way back. That is a materially worse bet than the fallback, and this
document recommends against it.

**The fallback is now visible inside the flow itself:** *"Use a display name with a virtual
number instead"* — Klaviyo provisioning its own marketing number, exactly the two-identity option
in §3.4, available immediately and with none of the risk.

**State after this run — nothing created, nothing moved.** No selection was made, no number
entered, no code requested. Voice was diverted at `01:49:14Z` and restored at `01:57:53Z` (~9
minutes, versus 5.5 hours on the previous attempt — the §10.3 sequencing lesson applied and
worked). **Checked and clear:** portfolio `497970999394825` still holds exactly three WABAs (Test
WhatsApp Business Account, UMI, UMI clothing) — **no WABA was created** by either attempt, so
nothing is added to the §9 teardown list. The number remains Connected at quality High.

### 10.5 Two-step verification cleared (2026-08-23) — and the number then *vanished* from the picker

**2SV is off.** Turning it off is not a console-only action: clicking *"Turn off two-step
verification"* in WhatsApp Manager produces a dialog reading *"Follow the instructions in the
email sent to ivanshumkov@gmail.com to turn off two-step verification…"* — Meta sends a
confirmation email and does nothing until it is actioned. Ivan completed it. WhatsApp Manager
now shows the Two-step verification panel in its **"Turn on"** empty state, with no `Enabled`
badge. This is exactly the prerequisite Klaviyo's tips screen leads with, and it had never been
met on any prior attempt.

**Then the re-check produced a third state nobody predicted.** Re-walking the wizard to Meta's
*"Add your WhatsApp phone number"* picker (fresh dialog — the Session ID changed, so it re-fetched):

| Option | 08:53, 2SV **on** | 09:52, 2SV **off** |
|---|---|---|
| Enter a new phone number | selectable | selectable |
| Use a display name with a virtual number instead | selectable | selectable |
| **UMI · `+66 97 531 1301`** | **`Ineligible`** | **absent — not listed at all** |
| UMI clothing · `+66 80 005 3593` | `Ineligible` | `Ineligible` |
| Test Number · `+1 555-196-6407` | selectable | selectable |

So the number moved from *listed-but-ineligible* to *not offered*. The list itself still works —
UMI clothing is still rendered, still ineligible — so this is specific to `+66975311301`, and it
correlates with the 2SV change.

**The production number is unharmed. VERIFIED immediately afterwards:** WhatsApp Manager shows
`+66 97 531 1301`, name UMI, status **Connected**, quality **High** — unchanged. Whatever the
picker is doing, it has not disturbed the live number.

**Interpretation: UNKNOWN, deliberately.** Two readings, and this document is not going to pick
one on a single observation:

1. **Meta is re-evaluating eligibility** after the 2SV change and the number is transiently
   between buckets. Favoured on timing, and cheap to test — wait, re-open the flow fresh, look
   again.
2. **It has entered some other state** that removes it from sharing candidates entirely.

**Next checks, in order:** type `531` into the dropdown's search box to rule out a truncated
list; then close the dialog, wait ~10 minutes, and re-open the flow from scratch. If it is still
absent, stop guessing from the picker and read the number's state from the Graph API directly.

**No clock is running:** voice is on its normal `incoming` handler, nothing is diverted, and no
code has been requested. This can wait as long as it needs to.

### 10.6 Correction — the picker was never the migration path

**Retracting a steer given in this session.** Twice I told Ivan not to select *"Enter a new phone
number"* on Meta's dialog, on the reasoning that it would provision a *different* number. **That
was wrong, and it is why two runs dead-ended.** Ivan recalled the actual flow — you type the
number, Meta recognises it as already registered elsewhere, and offers to migrate — and the
documentation backs him.

**The two branches do different things:**

* **The dropdown list** offers numbers eligible to be **shared** with the calling app. A number
  already bound to a WABA another BSP controls is not shareable, which is precisely what
  `Ineligible` meant, and why the wording was *"not eligible to be **shared** with this app."*
  Sharing was never the operation we wanted.
* **"Enter a new phone number"** means *a number not in that list* — including one registered
  elsewhere. This is the migration path. Per Birdeye's BSP-migration documentation: *"The phone
  number entered is already linked to a WhatsApp Business Account with another provider… If the
  user continues, the number will be moved to the new WABA connected to your platform… Once
  moved, the number will no longer work with the previous provider."*

So `Ineligible`, and then the number vanishing from the list entirely, were both **red herrings**
— states of a mechanism we were never supposed to be using.

**Prerequisites for the real path, checked against what we know:**

| Requirement | State |
|---|---|
| Two-step verification disabled on the number | ✅ done 2026-08-23 (§10.5) |
| Meta Business Account verified | ✅ UMI STORE CO., LTD. shows Verified (§1) |
| Display name approved | ✅ "UMI", visible to customers (§1) |
| No pending display-name change | ✅ none observed |
| Losing and destination WABA in the same portfolio | ✅ both under `497970999394825` |
| Valid payment method on the destination WABA | ⚠️ unverified — Klaviyo's new WABA will need one |
| Ability to receive the OTP | ⚠️ **this is where §2.3–§2.5 finally matter** |

**The OTP question is un-mooted.** §10.4 recorded it as moot because the number was never
offered. On the correct branch it is live again, and everything this document established about
it applies: SMS cannot reach the number (§2.4), Meta's voice call demonstrably can (§2.3), and
`otp_capture` is deployed and ready to record and transcribe it (§2.5).

**This is the real migration, not a probe.** Continuing past Meta's warning moves the number and
**it stops working on Twilio** — WhatsApp on `+66975311301` leaves Twilio inbox 6, which is the
intended end state (Chatwoot re-attaches as the second app via patch 26), but it is irreversible
in the same motion. It needs an explicit go, with the divert live first.

### 10.7 Migration executed (2026-08-23) — code captured, number moved, ownership check outstanding

**The correct branch worked.** Taking *"Enter a new phone number"*, setting the country to
Thailand and typing `97 531 1301` produced exactly the prompt §10.6 predicted:

> "This phone number is already registered to a WhatsApp Business account with another partner.
> If you continue, your number will be moved to your new account… Once moved, you won't be able
> to send or receive messages on your old account."

Portfolio was locked to **UMI STORE CO., LTD.** and the WABA field to **Create a WhatsApp
Business account** — no choice needed, and no risk of reusing the old WABA.

**The verification screen offers BOTH methods. VERIFIED — this is the question the whole
document chased.**

> "Choose how you would like to verify your number:  ◉ Text message   ○ Phone call"

It **defaults to Text message and sends one immediately** ("We've sent a code via text message
to +66975311301"). That SMS can never arrive (§2.4) — so on this path the default is the wrong
one, and switching to *Phone call* then *Resend Code* is mandatory, not optional.

**The capture rig worked end-to-end, against the exact failure from July.**

* Inbound call `CA772e0e575de6b2a9d01bf078d62925df` at **03:25:10Z from `+1 949 531 7728`** —
  the *same Meta originating number* as the 2026-07-05 attempt (§2.3).
* Duration 35 s, answered by `otp_capture`, two recordings (29 s + 5 s), auto-transcribed.
* Transcription `TRa762c3bf9b505e97a294dfbe710412a6`:
  **"Your verification code is 431040. Your verification code is 431040. Your verification code
  is 431040. Your verification code is."**

Set that beside July's transcript on the same account — *"Your verification code is 503, we are
sorry, an application error has occurred. Good bye."* — and the difference is entirely UMI's
own voice handler. Same Meta, same number, same voice path; a working handler is all that was
ever missing. No human answered a phone at any point.

**Result — partially complete.**

| Asset | State after migration |
|---|---|
| New WABA | **"UMI STORE CO., LTD."**, ID **`914496898392950`**, owned by UMI STORE CO., LTD., payment method **Credit line — Klaviyo, Inc.** |
| Klaviyo → Settings → WhatsApp | WhatsApp Account **Active**, message limit **2K / 24hrs** — the 2,000/24 h tier **carried over** |
| `+66 97 531 1301` in the new WABA | **`Unverified`**, quality rating blank |
| `+66 97 531 1301` in old WABA `1673373860633578` | still listed **`Connected`, quality High** |
| Klaviyo banner | *"Your phone number ownership could not be verified. Please verify ownership in Meta and try again."* + **Resubmit** |

So the WABA connected and the messaging tier transferred, but **the ownership hand-off did not
complete**: the number is listed in *both* WABAs. The captured code got through Meta's
verification step; something after it did not finish. Not yet diagnosed — candidates are Meta
not having released the number from the old WABA yet, or registration on the new WABA failing.

**§3.6 is answered, and favourably. VERIFIED: the Twilio number survived.** Read straight after
the migration — `phone_number` `+66975311301`, `status` **in-use**, `capabilities` voice+SMS
intact, `status_callback`, `bundle_sid` `BUe5aff5…` and `address_sid` `AD6f0a37…` all unchanged.
The only altered field was our own `voice_url` divert. Removing WhatsApp from Twilio did **not**
disturb the number, its voice service, its regulatory bundle, or account ownership — the
question Twilio documents nowhere.

**Voice window:** diverted `03:19:38Z`, restored `03:49:58Z` — about 30 minutes, and the code
was captured inside it.

**Next:** press **Resubmit** on Klaviyo's banner. If it asks for a code again, choose **Phone
call**, and re-divert voice *first* — the divert is currently restored, so a fresh OTP call
would ring agents instead of being recorded.

### 10.8 Resubmit fails — migration is stuck half-done

**Klaviyo's Resubmit does not work.** Pressed at 04:01Z with the divert live: a toast reading
**"Failed to resubmit WhatsApp account. Please try again."**, the red banner unchanged, no Meta
dialog opened. VERIFIED from Twilio that **no verification call or SMS was triggered** — the
only inbound call all day remains the 03:25:10Z one. So the resubmit dies before it reaches the
code-sending stage; retrying the button changes nothing.

**Current split state, and it is stable rather than in motion:**

| | |
|---|---|
| New WABA `914496898392950` | **Active** in Klaviyo, message limit **2K / 24hrs** carried over |
| `+66975311301` in the new WABA | **`Unverified`** |
| `+66975311301` in old WABA `1673373860633578` | still **`Connected`, quality High`** |
| Twilio number `PNf160f13eed…` | untouched — `in-use`, voice+SMS, bundle and address intact |
| Twilio WhatsApp sender | **still registered** (not deleted) |

**INFERRED, not verified — why it is stuck.** Meta cannot confirm ownership for Klaviyo while
the number is still attached to the old WABA, and the old WABA's claim is plausibly held open by
`+66975311301` still being a **registered WhatsApp sender on Twilio**. Releasing it from the
losing BSP is the standard missing step in BSP-to-BSP migrations. This is a hypothesis; nothing
observed states the cause.

**Options, in the order this document recommends:**

1. **Wait 30–60 minutes, press Resubmit again.** Meta's migrations propagate asynchronously and
   the destination WABA is already Active. Zero cost, zero risk, and it may simply resolve.
2. **If still stuck: delete the WhatsApp sender in Twilio**, then Resubmit. This is the
   deliberate, one-way step — do it with the divert live, because it may trigger a fresh
   verification call. **Not done, and not to be done on inference alone** — if the hypothesis is
   wrong it costs the sender for nothing.

**Nothing is broken meanwhile.** The Twilio number is intact and voice is restored
(`04:04:30Z`, all §10.1 fields matching). WhatsApp on the number is expected to be dark from
here — that was always the cost of the migration, and inbox 6 has had 13 messages ever.

**Voice window this round:** diverted `04:01:31Z`, restored `04:04:30Z` — 3 minutes.

### 10.9 Waiting did not help — and the sender restore point before deregistering

**Re-checked 2026-08-23 08:38Z, ~4.5 h after the migration. Option 1 (§10.8) is exhausted:**

* Twilio sender `XEa587e2c30f03901fec2c383dad8f5f07` — **still `ONLINE`, quality `HIGH`**. Twilio
  has not been told anything, and WhatsApp on the number is very likely still serving through it.
* `+66975311301` in the new WABA — **still `Unverified`**, quality blank.
* **But the display name went through:** WhatsApp Manager shows *"Congratulations! Your display
  name UMI was approved"* on the new WABA.

That last point matters: Meta **is** processing this WABA, so the delay is not a generic backlog.
It is the **number's ownership transfer specifically** that is stuck. Meta will not finish it
unaided.

**Working conclusion (INFERRED, and now the last lever):** the old WABA still holds the number
because Twilio still has it registered as a live sender, and Meta will not hand ownership to
Klaviyo while that is true. Deregistering at Twilio is the remaining action.

**Be clear what deregistering costs.** This is not tidying up something already dead. The sender
is `ONLINE`; deleting it is **what actually takes WhatsApp down** on `+66975311301`, and
returning to Twilio afterwards means re-registering from scratch. If Meta then still refuses,
the number has no working WhatsApp until it is resolved.

**Restore point — WhatsApp sender `XEa587e2c30f03901fec2c383dad8f5f07`, captured before deletion:**

| Field | Value |
|---|---|
| `sender_id` | `whatsapp:+66975311301` |
| `status` | `ONLINE` |
| `properties.quality_rating` | `HIGH` |
| `properties.messaging_limit` | `Unavailable` |
| `webhook.callback_url` | **`https://chat.umi.store/twilio/callback`** |
| `webhook.status_callback_method` | `POST` |
| `profile.name` | `UMI` |
| `profile.emails` | `info@umi.store` (label "Email") |
| `profile.websites` | `https://umi.store/` (label "Website") |
| `profile.description` | *"UMI is a clothing brand born in the tropics, inspired by the sea. Dedicated to modern minimalism and sensual elegance, uniting lightness and comfort with refined cuts and natural fabrics - a gentle touch on the body."* |
| `profile.about` / `address` / `vertical` / `logo_url` | empty |

To rebuild the sender on Twilio, that profile block and the callback URL are what must be
re-entered. Note `messaging_limit` already reads `Unavailable` — a hint the migration has
partially detached it.

**Order of operations for the deregistration** (each step verified before the next):

1. Divert voice to `otp_capture` — deregistering may trigger a fresh verification.
2. `DELETE /v2/Channels/Senders/XEa587e2c30f03901fec2c383dad8f5f07`, with a pre-flight assertion
   that `sender_id == whatsapp:+66975311301` so the wrong sender cannot be deleted.
3. Re-read the sender, and re-read the **IncomingPhoneNumber** to confirm the number itself,
   its `voice_url`, `bundle_sid` and `address_sid` are untouched.
4. Press **Resubmit** in Klaviyo.
5. Restore the voice URL.

### 10.10 Deregistered from Twilio — it did NOT unblock the migration

**The hypothesis in §10.8/§10.9 was wrong, and acting on it cost the Twilio sender.**

Executed 2026-08-23 14:54Z with the divert live:

* `DELETE /v2/Channels/Senders/XEa587e2c30f03901fec2c383dad8f5f07` → **204**, sender now **404**.
  Pre-flight asserted `sender_id == whatsapp:+66975311301` before deleting.
* **Twilio number untouched**, as designed: `in-use`, voice+SMS capabilities, `status_callback`,
  `bundle_sid`, `address_sid` all unchanged.
* Meta registered the change — in the **old** WABA the number flipped `Connected` → **`Offline`**
  (quality still High). So Twilio's claim genuinely was released.

**And Klaviyo's Resubmit still fails, identically.** Same error, no Meta dialog, and VERIFIED
from Twilio that **no verification call or SMS was triggered** — still only the 03:25:10Z call
from this morning.

**Net effect: the number is now dark on both sides.** Old WABA `Offline`, new WABA `Unverified`,
no Twilio sender. Before the deletion, WhatsApp was still serving through Twilio. That capability
was spent for no gain.

**What was misjudged.** The reasoning was that Meta would not transfer ownership while the
losing BSP held a live registration. Releasing it changed the old WABA's status but moved the
destination not at all — so the block is not, or not only, the Twilio registration. Klaviyo's
banner said *"Please verify ownership **in Meta** and try again"*, which reads as an instruction
to complete something Meta-side **before** pressing Resubmit; that wording deserved more weight
than the Twilio hypothesis, and did not get it.

**Current state:**

| Asset | State |
|---|---|
| Old WABA `1673373860633578` | number present, **`Offline`**, quality High |
| New WABA `914496898392950` | number present, **`Unverified`**, quality blank, **new phone-number ID `1242276345642600`** (old was `1101374313069948`) |
| New WABA display name | **UMI — approved** |
| Klaviyo | WABA **Active**, 2K/24hrs; banner *"phone number ownership could not be verified"*; Resubmit fails |
| Twilio sender | **deleted** — restore point in §10.9 |
| Twilio number | intact, `in-use`, voice restored to `.../incoming` |

**Recommended next steps, in order:**

1. **Look for a verify action on the number inside WhatsApp Manager** (new WABA → the number →
   Settings/More). Klaviyo's error points at Meta-side verification, and the number carries a
   fresh phone-number ID, so Meta may offer its own verification independent of Klaviyo's button.
   This session could not read those menus reliably — the browser viewport was 500 px wide.
2. **If there is no such action, open a Klaviyo support ticket.** The case is clean and fully
   evidenced: WABA created and Active, tier carried over, display name approved, number present
   but `Unverified`, ownership verification failing, Resubmit erroring, losing BSP released.
3. **Do not delete or re-add anything further on inference.** Two irreversible steps have now
   been taken; the second one did not help.

**Rollback option if WhatsApp is needed before this resolves:** re-register the number as a
Twilio WhatsApp sender using the §10.9 restore point. Twilio's documentation notes that
re-registering a previously deleted sender requires two-step verification to be off for the
number — it currently is (§10.5), so that path is open. Untested.

### 10.11 There is no Meta-side verify action — checked exhaustively

Klaviyo's banner instructs *"verify ownership in Meta"*. **VERIFIED: no such control exists.**
Read from the accessibility tree of the number's detail panel in WhatsApp Manager (new WABA
`914496898392950`, phone-number ID `1242276345642600`):

* Tabs on the number: **Insights, Profile, Automations, Message links, Two-step verification,
  Call settings, Call logs**. No verification tab.
* Row controls: **Delete** and **Settings** only. No verify action.

So ownership verification is not something an admin can perform in Meta's UI — it has to be
driven by the BSP, which is exactly the call that is failing inside Klaviyo. Klaviyo's error text
points at an action the user cannot take.

**Remaining route that is not a support ticket:** Klaviyo's WhatsApp settings page has an
**"Add number"** button under *WhatsApp Phone Number*, distinct from the Resubmit banner.
Resubmit appears to retry a stored, broken job; *Add number* may open a fresh verification for
`+66975311301` on a different code path. Untried, and free.

**If that fails, escalate to Klaviyo support.** The evidence package is complete: WABA
`914496898392950` created and Active with the 2K/24 h tier carried over, display name UMI
approved, number present but `Unverified` with a new phone-number ID, losing WABA released to
`Offline`, Twilio sender deregistered, Resubmit failing without triggering any verification
attempt (confirmed from Twilio's call and message logs).

### 10.12 Clean retry also fails — "already verified ownership" is persistent Meta state

**Second inference also wrong.** §10.11 reasoned that Meta's *"You have already verified
ownership of this phone number"* was a leftover from the first half-finished run, held in the
destination WABA's `Unverified` stub, and that deleting the stub would clear it.

Done and verified:

* New WABA `914496898392950` → **empty** (*"hasn't added any phone numbers yet"*).
* Old WABA `1673373860633578` → still holds `+66 97 531 1301`, `Offline`, quality **High**.
* Twilio number → untouched (`in-use`, voice+SMS, `status_callback`, bundle, address).

Then Klaviyo was disconnected and the whole embedded signup re-run from the splash, with 2SV
off, no Twilio sender, and no stub. **Identical error**, new session
`01a02f5f-17d8-7818-a228-15c791b2ab41`: *"You have already verified ownership of this phone
number."* `Next` stays disabled; entering the still-valid code `431040` does not enable it.

**So the state is persistent in Meta and not reachable from any UI we have.** It survives:
deleting the destination WABA's copy of the number, disconnecting and reconnecting Klaviyo,
deregistering the losing BSP, and a completely fresh signup session.

**Score on this session's hypotheses: two proposed, both wrong, both irreversible.**

1. §10.8 — "Twilio's live sender holds the old WABA's claim." Deleting it changed the old WABA
   to `Offline` and did not unblock Klaviyo. Cost: WhatsApp service on the number.
2. §10.11 — "the stub in the destination WABA holds the stale verification." Deleting it changed
   nothing. Cost: the half-migrated record (which was worthless, so low).

Both were plausible and both were wrong. **No further destructive steps should be taken on
inference.** The remaining unknown is inside Meta's verification state, which neither WhatsApp
Manager nor Klaviyo exposes.

**This is now a vendor case, and the evidence is complete.** The decisive framing for it: **Meta
says ownership is already verified; Klaviyo says it cannot be verified.** Both cannot be true,
and everything on UMI's side is demonstrably correct — business verified, display name UMI
approved, 2SV off, losing BSP released, number present in a UMI-owned WABA with quality High.

Report through **both** channels:
* The **"Report error to Klaviyo - WA Integration!"** link in Meta's own error panel, which
  attaches Meta's error text and reference automatically.
* A Klaviyo support ticket quoting error refs `#N/A:01a02f52-9dd6-7b57-86ad-0eb41377691b` and
  `#N/A:01a02f5f-17d8-7818-a228-15c791b2ab41`, and the fact that **Resubmit triggers no
  verification attempt at all** (confirmed from Twilio's call/message logs) — evidence of a
  broken job on Klaviyo's side rather than a problem with the assets.

**Service consideration:** WhatsApp on `+66975311301` is down and will stay down until this
resolves. If that becomes painful before the vendors respond, re-register the Twilio sender from
the §10.9 restore point — 2SV is off, which is Twilio's stated precondition. Untested, and it
would need redoing before any future migration attempt.

---

## 11. Handover — state as of 2026-08-23 16:10Z

Written so this does not live in one person's head while the vendors are chased.

### 11.1 What is true right now

| Asset | State | Notes |
|---|---|---|
| **Twilio number `+66975311301`** | **Healthy.** `in-use`, voice+SMS capabilities, `bundle_sid BUe5aff5…`, `address_sid AD6f0a37…` | Never disturbed by anything in this migration |
| **Voice service** | **Working.** `voice_url` = `https://chat.umi.store/umi/voice/66975311301/incoming`, restored 16:10:42Z | Agents ring normally; Groundwire path intact |
| **WhatsApp on that number** | **DOWN.** No Twilio sender; not live in any WABA | This is the outage; it persists until a vendor unblocks the migration |
| **Twilio WhatsApp sender** | **Deleted** (`XEa587e2c30f03901fec2c383dad8f5f07`) | Restore point in §10.9 |
| **Old WABA `1673373860633578` ("UMI")** | Holds the number, **`Offline`**, quality **High** | Reputation and display name intact |
| **New WABA `914496898392950`** | **Empty** — no phone numbers | Created by Klaviyo; tainted by the failed run, do not reuse |
| **Klaviyo** | **Disconnected.** Settings → WhatsApp is back at the "Try WhatsApp for free" splash | No WABA, no number, no templates lost (there were none) |
| **Two-step verification** | **Off** on the number | Turned off 2026-08-23; required an email confirmation |
| **Chatwoot inbox 6** | Receives nothing | 13 messages in its lifetime; deliberately not deleted |
| **Meta portfolio `497970999394825`** | Business verified; WABAs: UMI, UMI clothing, new empty one, plus the `Test WhatsApp Business Account` leftover (§9 item 1) | |

### 11.2 The blocker, stated for a vendor

Meta's embedded signup refuses to verify `+66975311301` with **"You have already verified
ownership of this phone number"**, while Klaviyo reports **"Your phone number ownership could not
be verified."** Both cannot be true.

Error references: `#N/A:01a02f52-9dd6-7b57-86ad-0eb41377691b` (22:53) and
`#N/A:01a02f5f-17d8-7818-a228-15c791b2ab41` (23:06).

Supporting facts, all verified:

* Klaviyo's **Resubmit triggers no verification attempt at all** — no call, no SMS, across every
  attempt, confirmed against Twilio's call and message logs. It fails before reaching Meta.
* The error survives: deleting the destination WABA's copy of the number, disconnecting and
  reconnecting Klaviyo, deregistering the losing BSP, and a fresh signup session.
* Everything on UMI's side is correct: business verified, display name **UMI approved** on the
  destination WABA, 2SV off, losing BSP released, number present in a UMI-owned WABA at quality
  High.

### 11.2a Vendor ticket

**Klaviyo ticket #4139654** — opened 2026-08-24, category **WhatsApp**, priority **Urgent**,
status **Open**: *"Customer support WhatsApp number migration stuck 'already verified'"*.

Anything further goes **into that thread**, not a new ticket. The three facts that make it
actionable, if they are not already in it: both Meta error refs (§11.2), that Resubmit triggers
**no** verification call or SMS at all (verified in Twilio's logs), and that WhatsApp is **down
in production** on the number.

### 11.3 Options while waiting

1. **Do nothing.** Voice is fine; only WhatsApp is dark. Lowest risk.
2. **Restore WhatsApp service via Twilio** — re-register the sender from the §10.9 restore point
   (profile, description, email, website, callback `https://chat.umi.store/twilio/callback`).
   2SV is off, which Twilio requires for re-registration. **Untested**, and it would have to be
   undone again before any future migration attempt.
3. **Wait for Klaviyo/Meta**, then retry the §10.6 path — which is now known-good up to the
   verification step.

### 11.4 What this exercise did establish

Worth keeping even though the migration is unfinished:

* **Meta's voice OTP reaches a Twilio Thai mobile number and can be captured automatically.**
  `otp_capture` recorded and transcribed `431040` from a 35 s call, unattended (§10.7). The July
  failure was UMI's own broken voice handler, not Meta (§2.3).
* **SMS can never work for this number** — Twilio's short-code rules plus Thailand's
  international-long-code block (§2.4).
* **Removing WhatsApp from Twilio does not disturb the phone number**, its voice service, its
  regulatory bundle or account ownership (§10.10) — the question Twilio documents nowhere.
* **The migration path is "Enter a new phone number", not the picker** (§10.6).
* **A migrated number keeps its messaging tier** — 2K/24h carried to the new WABA (§10.7).

### 11.5 Process notes

* **The divert should be opened last and closed immediately.** First run left it open 5.5 hours
  for a code that was never requested; later runs were 3–30 minutes (§10.3, §10.8).
* **Two hypotheses were acted on and both were wrong** (§10.12). The Twilio deregistration was
  the expensive one and caused the current outage. Neither was verified before acting; both were
  plausible. The lesson is not "do not hypothesise" but "do not spend irreversible actions on
  one."

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
