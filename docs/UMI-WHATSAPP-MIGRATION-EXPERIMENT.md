# UMI WhatsApp number → Klaviyo: can `+66975311301` move, and what proves it

Status: investigation and experiment design. **Nothing was bought, migrated, registered,
deregistered, or reconfigured.** Every Twilio call made for this document was a `GET`. No
production Twilio sender, Chatwoot channel, WABA, or Klaviyo setting was touched, and no
credential value appears here or left the production container.

Date: 2026-08-20
Companion: `docs/UMI-SHARED-NUMBER-SPEC.md` — §1.2 (phone-level override is per-app,
confirmed live) and §2.1 (patch 26 guards, `854d58c5a`).

Evidence convention: **VERIFIED** = observed directly, in this account or this checkout.
**INFERRED** = the best reading of real evidence, but not itself observed. **UNKNOWN** = the
documentation does not settle it and only the experiment can.

---

## 0. The two questions

1. **Klaviyo.** Does their BSP migration re-verify a number that cannot receive an OTP?
2. **Twilio.** Does removing a WhatsApp sender affect the number's voice service or the
   account's ownership of the number? Twilio documents migrations *to* Twilio and never away.

Short version of what follows. Klaviyo **does** demand a live verification code — that is
settled from their own runbook. But UMI's Twilio account holds primary evidence that Meta's
verification **voice call reaches this number and gets answered**, while Meta's SMS never
arrives at all; and the account already holds an approved Thai Mobile regulatory bundle, so
the experiment can be run on a Thai mobile number in the same carrier block as production
rather than on a US proxy. Question 2 remains genuinely undocumented and observation-only.

---

## 1. Step 0 — which WABA is the number in, and who owns it?

### 1.1 Status: NOT OBSERVED. Blocked on a login I am not permitted to perform.

The answer is only visible in Meta Business Manager (Business Settings → Accounts →
WhatsApp Accounts, or WhatsApp Manager). Twilio's Senders API returns an empty `waba_id`,
and Chatwoot cannot help: `+66975311301`'s two rows are `Channel::TwilioSms` — id 2
(`+66975311301`, `medium: sms`, inbox 5, created 2026-07-04) and id 3
(`whatsapp:+66975311301`, `medium: whatsapp`, inbox 6, created 2026-07-05) — and that model
stores no WABA or phone-number ID at all.

Ivan's Chrome profile is **logged out of both `business.facebook.com` and `klaviyo.com`**
(observed: both redirect to a password form). Entering a password is outside what I may do,
so this section specifies what to look at rather than reporting what is there.

**To unblock (about two minutes):** log in to Facebook in that Chrome profile, then say go.
The extension already holds permission for `business.facebook.com`. It does **not** hold
permission for `console.twilio.com` — a screenshot there was refused — though the Twilio API
route used for §2 makes the console unnecessary.

**What to read off the page, in this order:**

| Field | Where | Why it matters |
|---|---|---|
| WABA name and ID | Business Settings → Accounts → WhatsApp Accounts | Identity; needed for every later Graph call |
| Owning portfolio | The portfolio switcher; a WABA owned elsewhere shows under *Shared with you* / partner access rather than *Owned* | Decides H1 vs H2 below — the whole plan turns on this |
| Admin / people | WABA → People | Whether UMI can grant its own app access without Twilio |
| Connected/subscribed apps | WABA → Apps (or `GET /{waba-id}/subscribed_apps`) | Whether Twilio's app is the only subscriber; the seat patch 26 wants |
| Business verification state | Security Centre | Meta gates parts of migration and sending on it |
| Two-step verification PIN | WhatsApp Manager → the number → Two-step verification | Must be **off** during migration, and cannot be turned off via API |

### 1.2 The two hypotheses, and what each one costs

The number was registered through **Twilio Console → Messaging → Senders → WhatsApp senders
→ "Continue with Facebook" → create a new WABA in that flow** (recorded at the time; Twilio
warns against reusing a WABA created outside Twilio). That is Meta Embedded Signup running
under Twilio's tech-provider app, and it can land either way:

**H1 — the WABA sits in the UMI STORE CO., LTD. portfolio, with Twilio's app subscribed.**
The ordinary Embedded Signup contract and, on balance, the likelier outcome: Ivan picked a
business in that Facebook dialog, and Embedded Signup creates the WABA under the selected
portfolio. Twilio holds it as a client WABA.

**H2 — the WABA belongs to a Twilio-owned business portfolio, with UMI granted access.**
Possible if the signup dialog created or defaulted to a portfolio that is not UMI's.

### 1.3 Say it plainly: even H1 is not "just add Klaviyo as a connected app"

This is the outcome the brief hoped for, and it is not available. Klaviyo's own migration
article forecloses it, verbatim:

> "**Create a new WABA for Klaviyo** within that portfolio. Do not reuse your existing WABA."

So the number changes WABAs no matter what step 0 finds. Klaviyo does not attach itself as a
second app to somebody else's WABA — it provisions its own and expects the number to move
into it. The "second app on one WABA" architecture in the companion spec is Chatwoot's role,
not Klaviyo's; Klaviyo is the incumbent in that picture, and patch 26 exists precisely
because Chatwoot must live as the *guest*.

What H1 does buy, and it is worth a lot:

* Klaviyo's hard prerequisite is already satisfied — *"Confirm you have login access to the
  Meta Business Portfolio used with your current BSP. **You must use the same Meta Business
  Portfolio** to set up WhatsApp in Klaviyo."* Klaviyo names using a different portfolio as
  the most common cause of failed migrations.
* Source and destination WABA under one portfolio is Meta's supported intra-business number
  move, not a cross-business handover.
* Patch 26 works as designed: UMI can grant its own Meta app access to a WABA in its own
  portfolio, so `rake 'umi:whatsapp:foreign_owned_setup[<inbox_id>]'` has somewhere to point.

What H2 costs: Klaviyo's portfolio prerequisite is unsatisfiable as-is. The WABA (or at least
the number) has to be brought into UMI's portfolio first — a Twilio support request, an asset
transfer between portfolios, or a full cross-business re-onboarding. **If step 0 returns H2,
do not run the experiment yet**; fix ownership first.

---

## 2. What the Twilio account actually shows (observed 2026-08-20, read-only)

Method: `rails runner` inside the production Chatwoot container, using the credentials stored
on `Channel::TwilioSms` with `Net::HTTP` basic auth. GETs only. No credential value was
printed or left the container.

### 2.1 The number is a Thai **mobile** number — VERIFIED

`PNf160f13eed1ae9ab96a25dc1bd9f6c55` / `+66975311301`, purchased **2026-06-26**, status
`in-use`, `origin: twilio`, `beta: false`, `address_requirements: "any"`. It is the **only**
number on the account.

* Type: it appears in `/IncomingPhoneNumbers/**Mobile**.json` (1 match) and **not** in
  `Local.json` or `TollFree.json` (0 matches each). Its regulatory bundle points at
  regulation `RN0f70c071ddf37e66e352dce6bf4ad9f2` = **"Thailand: Mobile - Business"**.
* Capabilities: `voice: true, sms: true, mms: false, fax: false`.
* Voice URL today: `https://chat.umi.store/umi/voice/66975311301/incoming` (POST).
* SMS URL: still Twilio's demo endpoint `https://demo.twilio.com/welcome/sms/reply`.

**Why the type is decisive.** Twilio's live Thai inventory, queried today:

| TH number type | SMS | Voice | Monthly |
|---|---|---|---|
| local | **✗** | ✓ | $25.00 |
| **mobile** | **✓** | ✓ | **$22.00** |
| toll-free | **✗** | ✓ | $25.00 |

In Thailand, **only the mobile type carries SMS at all**. A Thai local or toll-free number
could never receive an SMS OTP under any circumstance — voice would be its only option. UMI
happens to hold the one Thai type that can do both.

**And this confirms Ivan's suspicion about the US proxy.** A US local number also shows
SMS + voice, so on a capability table it looks equivalent — but it is a different country,
a different regulatory class, and a *fixed-line* class rather than a *mobile* one. Number
class and country are exactly the axes an anti-VoIP OTP heuristic operates on. A US local
number is a poor proxy for a Thai virtual mobile number.

### 2.2 The Thai paperwork is already done, approved, and reusable — VERIFIED

The account holds three regulatory bundles:

| Bundle | Regulation | Status | Created |
|---|---|---|---|
| `BUe5aff5a92082ef66d1896fab122164e6` | Thailand: **Mobile** - Business | **`twilio-approved`** | 2026-06-22 |
| `BUc4db8cd786c2489098fe80ea6f469a0d` ("UMI STORE — TH Local Voice") | Thailand: Local - Business | **`twilio-approved`** | 2026-06-14 |
| `BU4ab355a87fcfd42727a44b95bec39a87` | Thailand: Mobile - Business | `twilio-rejected` | 2026-06-16 |

The approved mobile bundle has `valid_until: null` — no expiry — and the number also carries
address `AD6f0a37531f78fef3c48ece3095694958`. The rejected-then-approved pair shows the
paperwork took roughly six days and one rejection to clear. **That cost is already paid.**

It is not a small thing to have paid. Thailand's Mobile-Business regulation demands the
heaviest document set of any Thai type: proof of business name, proof of corporate
registration number, proof of address, and proof of the authorised legal representative's
identity, identification number and address. (Thai *national* numbers require nothing, but
Twilio does not sell that type in Thailand — `AvailablePhoneNumbers/TH.json` offers only
`local`, `mobile`, `toll_free`.)

Twilio's documentation is explicit that an approved bundle is reusable: once approved you can
"purchase a new phone number via Twilio Console or REST API" against it, for numbers of the
same country **and** number type.

**Live Thai mobile inventory right now:** `+66975310955`, `+66975310922`, `+66975311546` —
all `address_requirements: "any"`, non-beta, SMS + voice. Note the block:
**`+6697531xxxx`, the same carrier range as the production number `+66975311301`.**

**Conclusion: buy Thai, not US.** A second Thai mobile number should be purchasable
immediately against the existing approved bundle, in the same carrier block as production,
with the same regulatory class and the same virtual-number character. That removes the
weakest part of the previous plan — the country caveat comes out of the experiment entirely.
It costs $22.00 instead of $1.15, and it is worth it.

Confidence: **VERIFIED** for the bundle status, the regulation, the inventory and the price.
**INFERRED (high)** that the purchase is instant — only issuing the purchase call proves
Twilio accepts the bundle for a second number, and that call is a purchase, so it is not
something to test speculatively. If Twilio does demand a fresh bundle, the fallback is a US
local number and the country caveat comes back.

### 2.3 The 11200 record: the alert is gone; the calls are not

Asked directly, and the honest answer is split.

**Not recoverable — say it plainly.** Twilio's Monitor Alerts retain roughly 30 days. The
account currently holds exactly **three** alerts, all from 2026-08-11, all error 14101. A
query for `StartDate=2026-06-20 … EndDate=2026-07-10` returns **zero**. The legacy
`/Notifications.json?MessageDate=2026-07-05` resource returns **HTTP 404** (retired). The
per-call `Calls/{sid}/Notifications` subresource returns **0** for every call in the window.
**No record of error 11200 survives anywhere in this account.** The timestamp, failing URL
and exact error text asked for cannot be produced.

**Recoverable, and it carries the load anyway.** Call records survive far longer. Inbound
calls to `+66975311301`, 2026-06-20 … 2026-07-10:

| Time (UTC) | From | Status | Duration |
|---|---|---|---|
| 2026-07-04 04:28:02 | +66 97978 3972 | completed | 17 s |
| 2026-07-05 03:33:05 | +1 657 999 1951 | **no-answer** | 0 s |
| 2026-07-05 03:33:37 | +1 657 999 1951 | **no-answer** | 0 s |
| 2026-07-05 03:35:40 | +1 949 531 7728 | **completed** | 6 s |
| 2026-07-05 03:49:30 | +1 657 999 1951 | **completed** | 8 s |
| 2026-07-05 04:52:11 | +1 949 531 7728 | **completed** | 12 s |
| 2026-07-05 08:56:14 | +1 657 999 1951 | **completed** | 5 s |

Six inbound calls from two US numbers, all on 2026-07-05, all **before** the Twilio WhatsApp
channel row was created the same day at 13:51:39 UTC — i.e. during the failed Meta-direct
attempt, before the Twilio-Senders fallback succeeded. The 2026-07-04 call from a Thai number
is 30 minutes after the voice channel row was created and is almost certainly Ivan's own test.

And the message log — all-time, all directions, 15 records — contains **not one inbound SMS
from Meta or WhatsApp, ever**. The only inbound SMS to this number are three from **KBank on
2026-08-11**, which arrived fine. (They are the source of the three 14101 alerts: the demo
`sms_url` tried to auto-reply to an alphanumeric sender.)

Graded:

* **VERIFIED — inbound voice calls reached the number and were answered.** Six of them, four
  with `status=completed` and durations of 5–12 s, in the exact window.
* **VERIFIED — no Meta SMS ever arrived, and the number's SMS path is not the reason.** Zero
  Meta SMS records; three Thai bank SMS delivered to the same number two months later.
* **INFERRED (high) — those six calls were Meta's verification calls.** Two US origins, the
  right day, immediately before the fallback path was used, durations consistent with an
  automated readout. Nothing in the record names the caller, and Meta publishes no list of
  its OTP originating numbers.
* **INFERRED, NOT VERIFIED — that the failure was error 11200 on UMI's voice webhook.** This
  is the part that was load-bearing and it is *not* backed by primary evidence any more. It
  is still the best explanation — 11200 is what Twilio reports when an answered inbound
  call's handler errors, and "an application error has occurred" is Twilio's own apology
  TwiML — but the alert that would prove it has expired.

**What this does to the plan: it strengthens the half that matters.** The claim the plan
rests on is *"Meta's voice call reaches this number and something on UMI's side can answer
it."* That is now **verified**, not assumed. Whether the 2026 answer was an 11200 error page
or a dial timeout changes nothing about what to do next: point the number's voice URL at
something that records, and listen. The plan never depended on the error code — it depended
on the call arriving, and the call arrived.

### 2.4 A real gap worth fixing separately

The number's `sms_url` is still Twilio's demo endpoint. Anything sent to it by SMS today
lands nowhere UMI can see. If a future Meta SMS OTP *did* arrive it would be invisible in
practice — recoverable only by reading the Messages API afterwards, which is exactly what
this investigation had to do. Pointing it at something that captures is cheap and out of
scope here, but it is a real gap.

---

## 3. What the vendors' own documentation settles

### 3.1 Klaviyo does demand a verification code (VERIFIED from their docs)

From Klaviyo's BSP-migration article, verbatim:

> "Confirm you can receive a text or call on the phone number being migrated. You'll need it
> for verification during setup."

and, in the step list:

> "Enter the phone number you want to migrate. Enter the verification code sent to your
> number to complete the migration."

And from the general connect article:

> "Pick how you want to verify this number (either text message or phone call)." … "Enter the
> 6-digit code to verify your phone number."

So the answer to question 1 is **yes — Klaviyo re-verifies with a live OTP.** There is no
"we are a BSP, we will vouch for it" path in their published flow.

### 3.2 …and Klaviyo names the workaround in the same breath

Also verbatim, from the connect article:

> "If using a Google Voice number, choose to verify by a phone call."

Klaviyo already knows VoIP numbers do not receive the SMS, and their answer is the voice
call. Read alongside §2.3 — voice reaches this number, SMS never did — the two independent
findings point the same way.

### 3.3 Meta's country and language restrictions on voice verification — UNKNOWN, informatively

* **VERIFIED** — Meta's reference documents `POST /{phone-number-id}/request_code` with
  `code_method` accepting exactly `SMS` or `VOICE`, and a required `language` locale matching
  `^[a-z]{2}_[A-Z]{2}$` (e.g. `en_US`). The **caller chooses the language**; it is not derived
  from the number's country. So the code can be requested spoken in English on a Thai number.
* **VERIFIED by absence** — Meta's own pages for `request_code` and for solution-provider
  registration document **no** country restriction on voice verification, **no** carrier
  restriction, **no** number-type restriction, and **no** list of supported locales. The only
  documented limits are generic Graph rate limits, code expiry, and temporary blocking after
  repeated failed attempts.
* **VERIFIED** — Meta does not ban VoIP. Its *Business phone numbers* page's recommended
  action is *"Confirm that the VoIP provider supports international SMS/calls for OTPs"* — a
  compatibility warning pointed squarely at the voice leg, not a prohibition.
* **INFERRED, from non-Meta sources only** — third-party blogs assert that VoIP and virtual
  numbers are blocked outright and that 2026 tightened this further. No Meta page says so, and
  UMI's own call log shows Meta placing the calls. Treat these claims as unsupported.
* **UNKNOWN** — whether Meta's OTP vendor will place a voice call to a Thai virtual mobile
  number *today*; whether `th_TH` is an accepted locale; whether an unsupported locale is
  rejected or silently defaults. Only the experiment answers these.

Practical consequence: request `en_US` explicitly rather than relying on a default.

### 3.4 Why Twilio's auto-verify does not travel with the number (INFERRED from Meta/BSP docs)

Meta's Embedded Signup accepts a `preverified_id`: a provider that owns a number can
pre-register it with Meta and onboard a customer **without any OTP**. That is the mechanism
behind "Twilio auto-verifies." The pre-verification is issued by and bound to the provider
who owns the number — Twilio. Klaviyo cannot present a `preverified_id` for a number Twilio
owns, and nothing suggests Klaviyo exposes a preverified path to customers at all.

The corollary is a genuine alternative to the whole migration: **a number bought through
Klaviyo's own flow has no OTP problem.** Klaviyo's connect article lists "existing number,
purchased from a provider (e.g. Twilio or Infobip), or requested free from Meta during
setup." Giving marketing a *different* number sidesteps every risk in this document, at the
cost of the one-number premise. That trade is Ivan's call and should be explicit.

### 3.5 Two-step verification must be off, and Chatwoot must not invent one

Meta requires two-step verification to be **disabled** on a number being migrated between
WABAs, and it cannot be disabled through the API — only in WhatsApp Manager. Klaviyo's own
step 1 is *"Click **Turn off two-step verification**. This will trigger a confirmation email."*

This is the same PIN namespace patch 26 protects: Chatwoot's `register_phone_number` invents
a PIN with `SecureRandom`, and a **successful** call is the damaging one, because it silently
sets a PIN the number's owner cannot guess when they next need to re-register or migrate.
Patch 26 makes that call raise on a foreign-owned channel. Keep it that way, and check the
number's 2SV state during step 0.

### 3.6 Twilio documents nothing about leaving (VERIFIED by absence)

Twilio's *Migrate phone numbers and WhatsApp senders* page covers exactly three journeys:
from the WhatsApp Business app, from another BSP, and between Twilio accounts. Nothing about
migrating a sender away from Twilio, nothing about deleting a sender, nothing about what
becomes of the underlying number. Question 2 is undocumented and can only be settled by
observation.

Structurally, the `IncomingPhoneNumber` and the WhatsApp `Sender` are separate Twilio
resources — voice URL, SIP routing, credential list and TwiML app all hang off the former,
and the production number's own record confirms that shape (`voice_url` set, `bundle_sid`
and `address_sid` attached, no `trunk_sid`). Deleting the sender *should* leave voice, SMS
capability and account ownership untouched. That is the expectation step 6 exists to check,
and it must not be assumed on the production number.

One documented adjacent fact: to re-register the same number as a Twilio sender after
deleting it, two-factor authentication must be turned off for the number in WhatsApp Manager.
So the rollback direction is at least a known path with a known prerequisite.

---

## 4. Two things to check before recommending any spend

### 4.1 Is Klaviyo's WhatsApp product available on UMI's current plan?

**Not yet observed** — Chrome is logged out of Klaviyo too.

What the public material says: WhatsApp went generally available in Klaviyo around October
2025 and rides the **Email + SMS** ("mobile messaging") bundle rather than the email-only or
free tier; it shares the SMS credit pool, which as of 13 July 2026 is moving to
dollar-denominated per-message rates. Klaviyo's own requirements list names **Owner or Admin**
role and a dedicated number that is not already an SMS sending number, and mentions no plan
gate on *connecting*. The gate, if any, is likelier on sending than on connecting — an
inference, not a fact.

**How to settle it in sixty seconds:** open Klaviyo → Settings → WhatsApp. If **Connect to
WhatsApp** is present and clickable, the runbook's step 5 can reach the verification screen.
If it shows an upsell or a "contact sales", step 5 stops at a paywall. **Do not buy a plan
upgrade to run a test.**

One further constraint, which does not block the experiment: Meta does not permit WhatsApp
*marketing* messages to US phone numbers, and Klaviyo's WhatsApp marketing is
international-only. That affects what a test number could ever *send*, not whether it can be
verified and migrated — and it is another argument against a US test number.

### 4.2 Does connecting a test number make a mess of the real Klaviyo account?

Yes — bounded, reversible today, less reversible later.

1. **Klaviyo's WhatsApp connection is account-level and singular.** A throwaway WABA
   connected there occupies the slot the real number will eventually need.
2. **Disconnecting is destructive to templates.** Klaviyo's own material: disconnecting the
   WABA *permanently removes the WhatsApp message templates associated with that WABA*, which
   must then be recreated and resubmitted for Meta approval. For a throwaway WABA with no
   templates that costs nothing. **After UMI starts building real templates it costs real
   work — so if this experiment runs at all, run it before that.**
3. **The catch-22 on isolating the test.** A separate free Klaviyo account avoids touching
   production, but a free account is the tier least likely to expose WhatsApp at all, so the
   isolated test is the one most likely to die at a paywall and prove nothing. Using the real
   account gets a real answer and pays for it in account state. There is no clean third
   option. Settle §4.1 by looking first; if WhatsApp is live on the real account, run the test
   there, before any template work, with `ZZ-TEST-` naming throughout — the convention the
   §1.2 spike used and tore down cleanly.
4. **Meta-side:** the test WABA will be created inside UMI STORE CO., LTD.'s portfolio
   (Klaviyo requires the same portfolio) and will sit beside production assets until teardown.
   Name it `ZZ-TEST-`.

---

## 5. Recommended shape: run the cheap decisive experiment first

The eight steps below bundle two independent unknowns into one chain, and the cheaper one is
decisive:

**Experiment A — can a Meta OTP be captured on a Thai virtual mobile number?**
No Klaviyo, no migration, no WhatsApp sender, no plan question. Buy one Thai mobile number
against the existing approved bundle, point its voice URL at a TwiML Bin that speaks and
records, add the number to a throwaway WABA, and request the code — **SMS first** (free to
check in the Messages log, and §2.3 shows this number type does receive SMS from other
senders), then **VOICE**. If the recording carries six intelligible digits and `verify_code`
succeeds, **the objection that started this whole investigation is dead** and the migration
becomes an ordinary scheduled operation. If Meta refuses both legs, everything downstream is
moot and you have spent $22 finding out.

**Experiment B — everything else.** Sender registration, the Klaviyo flow itself, voice
survival after deregistration, and the second-app subscription. Worth running only if A passes
or is inconclusive in an interesting way.

A costs ~$22.20 and about an hour, and touches neither Klaviyo's account state nor any app
configuration. Steps 1–8 below are the full sequence; A is steps 1, 2 and a variant of 5.

---

## 6. The runbook

Preconditions for every step: production is untouched. Do not use the existing sender
`XEa587e2c30f03901fec2c383dad8f5f07`, the number `+66975311301`, the SIP domain
`umi-spike-2c9dbf`, credential list `CL4eee7ca2…`, or either Chatwoot channel (2 or 3).
Prefix every created asset with `ZZ-TEST-`. Record timestamps, Graph API version and raw
responses (tokens redacted), as the §1.2 spike did.

### Step 1 — buy one throwaway **Thai mobile** number

Purchase one of the numbers currently in inventory (`+66975310955`, `+66975310922`,
`+66975311546` or whatever is available then) in the same Twilio account, attaching the
existing approved bundle `BUe5aff5a92082ef66d1896fab122164e6` and address
`AD6f0a37531f78fef3c48ece3095694958`. Give it a `ZZ-TEST-` friendly name.

* **Go:** purchase returns immediately with the bundle accepted. Same country, same number
  type, same carrier block and same virtual character as production — the country caveat is
  gone.
* **No-go:** Twilio demands a fresh bundle or a new address for a second number. That means
  days of paperwork; fall back to a **US local** number at $1.15 and reinstate the country
  caveat explicitly in the writeup. Do not wait on Thai paperwork for a throwaway.
* **Cost:** **$22.00/month**, billed in advance and not prorated on release.

### Step 2 — configure voice, place a test call, confirm it works

Point the number's Voice URL at a TwiML Bin that answers and captures audio — a `<Say>`
followed by `<Record>` is enough. Do **not** wire it to the production SIP domain. Call it
from a mobile and confirm the recording appears. While here, point the SMS URL at something
that captures too, or plan to read the Messages API — §2.4.

This is not a formality: it establishes that the number can *hear* an inbound call before
Meta places one, which is precisely what was missing on 2026-07-05.

* **Go:** the call connects, TwiML executes, an audible recording exists.
* **No-go:** any 11200 or 12xxx error — fix the TwiML before continuing, or step 5 reproduces
  the original failure and misattributes it to Meta.
* **Cost:** inbound voice + recording, under $0.20 across steps 2, 4 and 6.

> **Experiment A stops here plus two Meta calls.** With the number answering and recording,
> create a `ZZ-TEST-` WABA, add the number, and:
> 1. `POST /{phone-number-id}/request_code` with `code_method=SMS`, `language=en_US`. Wait,
>    then read the Twilio Messages API for an inbound message. This is free and, per §2.3,
>    a genuinely open question for a Thai *mobile* number — inbound SMS demonstrably works.
> 2. If no SMS arrives, repeat with `code_method=VOICE`, `language=en_US`, then read the
>    recording and `POST .../verify_code`.
>
> **Go:** either leg yields six intelligible digits and a successful verify → the OTP
> objection is dead and the Klaviyo migration is a scheduling problem, not a feasibility one.
> **No-go:** Meta declines both legs, or the audio is unusable → the production number
> genuinely cannot self-verify, and the honest options are a Klaviyo-provisioned number for
> marketing (§3.4) or Klaviyo support agreeing to a manual path. **Cost: $0 beyond steps 1–2.**

### Step 3 — register it as a Twilio WhatsApp sender

Console → Messaging → Senders → WhatsApp senders → Create, through the Facebook flow, into a
new `ZZ-TEST-` WABA. This reproduces UMI's exact condition: a Thai virtual mobile number
auto-verified by Twilio rather than by an OTP.

* **Go:** sender reaches ONLINE with no OTP demanded — which re-confirms the `preverified_id`
  mechanism in §3.4.
* **No-go:** if Twilio *does* demand an OTP, the test number is not reproducing UMI's
  condition and the rest of the run is not comparable. Stop and reconsider.
* **Cost:** no registration fee; messaging is billed per message and the experiment sends
  none. Confirm in the console before proceeding.

### Step 4 — confirm voice still works with WhatsApp attached

Call the number again. This is the control for step 6: without it, a failure at step 6 cannot
be attributed to deregistration rather than to registration.

* **Go:** the call connects and records exactly as in step 2.
* **No-go:** voice broke on *registration* — a finding in its own right, and it would mean
  UMI's production dual-use setup is more fragile than believed. Record it and stop.
* **Cost:** included in step 2's under-$0.20.

### Step 5 — attempt the Klaviyo BSP migration. **The decisive observation.**

Klaviyo → Settings → WhatsApp → Connect to WhatsApp, following their migration article: turn
off two-step verification for the test number in WhatsApp Manager, create a **new** WABA for
Klaviyo in the same portfolio, enter the number, and watch what the flow asks for.

Record, in order: whether a verification step appears at all; whether both SMS and voice are
offered; which Klaviyo pre-selects; whether the code arrives on either leg; whether the
recording or Messages log captures it; and how long Meta's review takes before the number is
usable again.

* **Go (best):** no OTP is demanded, because the number is already verified in the same
  portfolio — migration is a portfolio-internal move and carries no verification risk at all.
* **Go (workable):** an OTP is demanded, the **voice** option is offered, and the code is
  captured from the recording. Migration is feasible with a scripted OTP-capture step.
* **No-go:** an OTP is demanded, only SMS is offered or no code can be captured on either
  leg. The production number cannot migrate to Klaviyo unassisted. Escalate to Klaviyo support
  with this evidence, or take the separate-number option in §3.4.
* **Cost:** $0 in fees if the plan already entitles WhatsApp. The real cost is Klaviyo account
  state per §4.2 and the occupied connection slot.

### Step 6 — call the number again: did voice survive WhatsApp leaving Twilio?

After the migration completes (or after deleting the Twilio sender, if the migration required
it), call the number once more and confirm it is still owned by, and billed to, the Twilio
account with its voice configuration intact.

* **Go:** call connects, TwiML executes, number still listed under Phone Numbers with
  `voice_url` unchanged and its bundle still attached. Answers question 2 and clears the
  largest unknown for UMI's production voice service.
* **No-go:** voice broken, configuration cleared, or the number released. **This is a
  migration blocker on its own** — the production number carries live agent voice, and losing
  it would be worse than not having WhatsApp on Klaviyo. Do not migrate production.
* **Cost:** included above.

### Step 7 — subscribe a UMI-owned Meta app to the Klaviyo-provisioned WABA

`POST /{waba-id}/subscribed_apps` with a system-user token for a `ZZ-TEST-` UMI app, then the
phone-level override — i.e. exactly what `rake 'umi:whatsapp:foreign_owned_setup[<inbox_id>]'`
performs. Remember §1.2's prerequisite: the app needs its own callback URL saved, verified and
`messages`-subscribed in its own dashboard first, or Meta answers with error 100 and blames
the WABA subscription that just succeeded.

Then watch across a week, or across a Klaviyo send, whether the subscription and override
survive or whether Klaviyo's tooling re-asserts and evicts them.

* **Go:** both apps appear in `GET /{waba-id}/subscribed_apps`, each app reads back only its
  own `phone_number` override (the §1.2 result reproduced on a Klaviyo-provisioned WABA), and
  it persists.
* **No-go:** Klaviyo's platform removes the second subscription, or its onboarding
  periodically rewrites configuration in a way that evicts Chatwoot. The shared-number
  architecture fails and patch 26 has nothing to attach to.
* **Cost:** $0.
* **Note:** cannot be run standalone — it needs a Klaviyo-provisioned WABA, so it depends on
  step 5 succeeding.

### Step 8 — tear everything down

In this order, so nothing is orphaned:

1. Disconnect the test WABA in Klaviyo (Settings → WhatsApp).
2. `DELETE /{waba-id}/subscribed_apps` with the UMI test app's token; clear its phone-level
   override.
3. Delete the test number from the WABA in WhatsApp Manager (2SV must be off).
4. Delete the `ZZ-TEST-` WABA, app and system user in Business Settings — confirm the system
   user's asset list contained only test assets, before and after, as the §1.2 spike did.
5. Delete the Twilio WhatsApp sender if it still exists; release the phone number. **Do not
   delete or modify the regulatory bundles** — they are shared with production.
6. Delete the TwiML Bin and any recordings.
7. Re-read `GET /{waba-id}/subscribed_apps` on the **production** WABA and confirm it is
   unchanged from the step 0 baseline. Re-read the production `IncomingPhoneNumber` and
   confirm `voice_url`, `bundle_sid` and `address_sid` are unchanged.

* **Cost:** releasing the number stops the recurring charge; the month already started is not
  refunded.

---

## 7. Cost

| Item | Cost |
|---|---|
| **Thai mobile** number, one month (verified list price) | **$22.00** |
| Inbound voice + recording across steps 2, 4, 6 | < $0.20 |
| Twilio WhatsApp sender registration | $0 (no message sent) |
| Meta WABA / app / system user | $0 |
| Regulatory bundle | $0 — already approved, reused |
| Klaviyo connection | $0 **if** WhatsApp is already on UMI's plan; otherwise blocked — do not upgrade for a test |
| **Hard spend** | **≈ $22.20**, under $25 with retries |
| *(fallback: US local number instead)* | *≈ $1.35 — but reinstates the country caveat* |

The money is still not the main cost. The rest is Ivan's time (2–4 hours across steps 1–8,
plus waiting on Meta's migration review at step 5), one occupied Klaviyo WhatsApp connection
slot, and throwaway assets sitting in the production Meta portfolio until teardown.
Experiment A alone is ~$22.20 and an hour, and touches neither Klaviyo nor app configuration.

---

## 8. What this still does not prove

The country caveat is gone — that was the weakest item and §2.2 removes it. What remains:

1. **A number with history.** `+66975311301` carries a HIGH quality rating, an approved
   display name, an established messaging tier and possibly OBA status. A fresh test number
   has none of it. The test cannot show whether those survive migration, whether Meta reviews
   a seasoned number differently, or how long a real number stays dark during review.
2. **Production entanglement.** The production number is bound to a SIP domain, a credential
   list, live agent registrations and two Chatwoot channels. "Voice survived" on a bare test
   number with a TwiML Bin is materially weaker evidence than the same result on that wiring.
   Step 6 reduces the risk; it does not eliminate it.
3. **Downtime.** Klaviyo warns the number *"cannot send or receive messages from the moment
   you begin migration until Meta completes its review."* A test number's outage length is not
   predictive of a seasoned commercial number's, and the business impact is not simulated.
4. **Reputation of the number, not the block.** The test number will be a fresh Thai mobile in
   the same carrier block. Whether Meta's OTP heuristics treat a fresh number in that block the
   same as a two-month-old one already registered as a WhatsApp sender is unknowable in advance
   — it could cut either way.
5. **Portfolio and verification state.** If the test runs under a different portfolio, or one
   with different business-verification status, Meta may behave differently. Run it in UMI's
   real portfolio or discount the result.
6. **Klaviyo's branch selection.** Klaviyo's *new number* and *migration* flows are different
   code paths. A test number that was a live Twilio sender does reproduce the migration branch
   — but not migrating out of a WABA that Twilio provisioned inside UMI's own portfolio with
   an already-approved display name.
7. **Steady state.** Step 7 observed over days is not the same as a WABA under real campaign
   load with Klaviyo re-running onboarding checks. §1.2's caveat also still stands: no real
   inbound `messages` delivery test has ever been completed on a two-app number.
8. **The 11200 error text.** Permanently unverifiable — §2.3. The plan does not depend on it,
   but nobody should later cite it as established fact.

---

## 9. Open decisions for Ivan

1. **Log in to Facebook in Chrome** so step 0 can be observed. Everything branches on H1 vs
   H2, and H2 means "do not run the experiment yet."
2. **Look at Klaviyo → Settings → WhatsApp** and say whether *Connect to WhatsApp* is
   available. If it is paywalled, only Experiment A is worth running.
3. **Approve or decline the spend** — ~$22.20 for a Thai mobile test number (recommended), or
   ~$1.35 for a US local one that reinstates the country caveat. Nothing is bought until this
   is a yes.
4. **Decide whether the one-number premise is negotiable.** §3.4's alternative — let Klaviyo
   provision its own marketing number, keep `+66975311301` on Twilio for support and voice —
   removes every risk in this document. Worth an explicit decision rather than an implicit one.

## Sources

* [Klaviyo — How to migrate from another WhatsApp Business Solution Provider to Klaviyo](https://help.klaviyo.com/hc/en-us/articles/40116637850651)
* [Klaviyo — How to connect your WhatsApp Business account to Klaviyo](https://help.klaviyo.com/hc/en-us/articles/40111819732635)
* [Klaviyo Academy — Enable WhatsApp in Klaviyo](https://academy.klaviyo.com/en-us/learning-paths/getting-started-with-sms/courses/getting-started-with-whatsapp/lessons/enable-whatsapp-in-klaviyo)
* [Twilio — Migrate phone numbers and WhatsApp senders](https://www.twilio.com/docs/whatsapp/migrate-numbers-and-senders)
* [Twilio — Register WhatsApp senders using Self Sign-up](https://www.twilio.com/docs/whatsapp/self-sign-up)
* [Twilio — Phone Number Regulatory FAQ](https://www.twilio.com/docs/phone-numbers/regulatory/faq)
* [Twilio — Bundles Resource](https://www.twilio.com/docs/phone-numbers/regulatory/api/bundles)
* [Twilio Help — Twilio number already registered with a WhatsApp account](https://help.twilio.com/articles/10665149551515)
* [Meta — Business phone numbers](https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/phone-numbers)
* [Meta — Phone Number Verification Request Code API](https://developers.facebook.com/documentation/business-messaging/whatsapp/reference/whatsapp-business-phone-number/phone-number-verification-request-code-api)
* [Meta — Registering phone numbers (solution providers)](https://developers.facebook.com/docs/whatsapp/solution-providers/phone-numbers/registering-phone-numbers/)
* [Meta — Two-step verification](https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/two-step-verification/)
* [Bird — Setting up the WhatsApp Embedded flow (`preverified_id`)](https://docs.bird.com/api/channels-api/supported-channels/programmable-whatsapp/whatsapp-isv-integration/whatsapp-channel-onboarding/setting-up-the-whatsapp-embedded-flow)
