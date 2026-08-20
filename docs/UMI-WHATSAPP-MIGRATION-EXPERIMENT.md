# UMI WhatsApp number → Klaviyo: can `+66975311301` move, and what proves it

Status: investigation and experiment design. **Nothing was bought, migrated, registered,
deregistered, or reconfigured.** No production Twilio sender, Chatwoot channel, WABA, or
Klaviyo setting was touched. No token appears in this document.

Date: 2026-08-20
Companion: `docs/UMI-SHARED-NUMBER-SPEC.md` — §1.2 (phone-level override is per-app,
confirmed live) and §2.1 (patch 26 guards, `854d58c5a`).

Evidence convention, same as the companion spec: **High** = observed directly or read out
of this checkout. **Medium** = stated by the vendor's own published documentation but not
exercised against UMI's assets. **Unknown** = the documentation does not settle it and only
the experiment can.

---

## 0. The two questions

1. **Klaviyo.** Does their BSP migration re-verify a number that cannot receive an OTP?
   `+66975311301` is VoIP and already failed Meta-direct verification. It works today only
   because Twilio, as the number's owner and a BSP, auto-verifies it.
2. **Twilio.** Does removing a WhatsApp sender affect the number's voice service or the
   account's ownership of the number? Twilio documents migrations *to* Twilio and never
   away.

The desk research below moves question 1 from "unknown" to "known, and the answer is worse
and better than expected at the same time": Klaviyo **does** demand a verification code, and
Klaviyo's own docs also name the workaround. Question 2 remains genuinely undocumented.

---

## 1. Step 0 — which WABA is the number in, and who owns it?

### 1.1 Status: NOT OBSERVED. Blocked on a login I am not permitted to perform.

The answer is only visible in Meta Business Manager (Business Settings → Accounts →
WhatsApp Accounts, or WhatsApp Manager). Twilio's Senders API returns an empty `waba_id`,
and Chatwoot cannot help: `+66975311301`'s inboxes are `Channel::TwilioSms`
(`whatsapp:+66975311301` for messaging, plain `+66975311301` for voice), and that model
stores no WABA or phone-number ID at all — those fields exist only on `Channel::Whatsapp`.

Ivan's Chrome profile is **logged out of both `business.facebook.com` and `klaviyo.com`**
(observed: both redirect to a password form). Entering a password is outside what I may do,
so this section is a specification of what to look at rather than a report of what is there.

**To unblock (about two minutes):** log in to Facebook in that Chrome profile, then say go.
The extension already holds permission for `business.facebook.com`. It does **not** hold
permission for `console.twilio.com` — a screenshot there was refused — so if the Twilio
Console is wanted too, that site needs enabling in the extension.

**What to read off the page, in this order:**

| Field | Where | Why it matters |
|---|---|---|
| WABA name and ID | Business Settings → Accounts → WhatsApp Accounts | Identity; needed for every later Graph call |
| Owning portfolio | The portfolio switcher above the list; a WABA owned elsewhere shows under *Shared with you* / partner access rather than *Owned* | Decides H1 vs H2 below — the whole plan turns on this |
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
This is the ordinary Embedded Signup contract and, on balance, the likelier outcome: Ivan
picked a business in that Facebook dialog, and Embedded Signup creates the WABA under the
selected portfolio. Twilio holds it as a client WABA.

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

What H2 costs: Klaviyo's portfolio prerequisite is unsatisfiable as-is. The WABA (or at
least the number) has to be brought into UMI's portfolio first, which means a Twilio support
request, an asset transfer between business portfolios, or a full cross-business
re-onboarding. **If step 0 returns H2, do not run the experiment yet** — fix ownership first,
because a US test number under UMI's own portfolio would be testing the easy case and
telling you nothing about the hard one you actually have.

---

## 2. What the vendors' own documentation already settles

### 2.1 Klaviyo does demand a verification code (Medium → effectively High)

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
"we are a BSP, we will vouch for it" path in their published flow. This is the condition the
brief feared, and it is documented rather than hypothetical.

### 2.2 …and Klaviyo names the workaround in the same breath

Also verbatim, from the connect article:

> "If using a Google Voice number, choose to verify by a phone call."

Klaviyo already knows VoIP numbers do not receive the SMS, and their answer is the voice
call. That single line reframes the whole problem.

### 2.3 The 2026 failure was a broken voice webhook, not an unverifiable number (High)

This is the most important thing in this document and it comes out of UMI's own history
rather than any vendor's docs.

When the Meta-direct OTP was attempted on `+66975311301`, the voice call **arrived**. What
the caller heard was *"we're sorry, an application error has occurred, goodbye"* — Twilio
error **11200**, which is Twilio's own message when the number's voice webhook returns an
error or bad TwiML. Meta placed the call; Twilio answered it; UMI's then-unconfigured voice
handler dropped it. Meta never failed to deliver the code — nothing on UMI's side was
listening to hear it.

**That is no longer the configuration.** UMI's voice stack has been live in production since
2026-07-22: the number dials through a Twilio SIP domain to agents' Groundwire softphones,
and `dial_status` now returns spoken TwiML instead of erroring. A Meta voice OTP placed at
that number **today** would ring a real phone and read six digits to whoever answers.

The consequence: the blocking objection behind this entire experiment may already be stale.
It should be tested before a single dollar is spent on anything else, and it can be tested
without Klaviyo, without a migration, and without touching the production number. See
Experiment A in §4.

Confidence: **High** that 11200 means the call connected and Twilio's handler failed —
that is what the error code means and it is what was recorded at the time. **Unknown**
whether Meta's OTP vendor will place a *voice* call to a Thai VoIP number today, whether it
will refuse the SMS leg, and whether the recording is intelligible. That is exactly what the
experiment measures.

### 2.4 Why Twilio's auto-verify does not travel with the number (Medium)

Meta's Embedded Signup accepts a `preverified_id`: a provider that owns a number can
pre-register it with Meta and onboard a customer **without any OTP**. That is the mechanism
behind "Twilio auto-verifies." The pre-verification is issued by and bound to the provider
who owns the number — Twilio. Klaviyo cannot present a `preverified_id` for a number Twilio
owns, so leaving Twilio means leaving the auto-verify behind. Nothing suggests Klaviyo
exposes a preverified path to customers at all.

The corollary is worth stating because it is a genuine alternative to the whole migration:
**a number bought through Klaviyo's own flow (Meta's free number, or a number Klaviyo can
pre-verify) has no OTP problem.** Klaviyo's connect article lists "existing number,
purchased from a provider (e.g. Twilio or Infobip), or requested free from Meta during
setup" as the options. Giving marketing a *different* number sidesteps every risk in this
document — at the cost of the one-number premise. That trade belongs to Ivan, not to me,
but it should be on the table before spending on the experiment.

### 2.5 Two-step verification must be off, and Chatwoot must not invent one (Medium / High)

Meta requires two-step verification to be **disabled** on a number being migrated between
WABAs, and it cannot be disabled through the API — only in WhatsApp Manager. Klaviyo's own
step 1 is *"Click **Turn off two-step verification**. This will trigger a confirmation
email."*

This is the same PIN namespace patch 26 was built to protect: Chatwoot's
`register_phone_number` invents a PIN with `SecureRandom` and a **successful** call is the
damaging one, because it silently sets a PIN the number's owner does not know and cannot
guess when they next need to re-register or migrate. Patch 26 makes that call raise on a
foreign-owned channel. Keep it that way, and check the number's 2SV state at step 0 — if
Twilio set a PIN at registration, someone has to clear it in WhatsApp Manager before any
migration begins.

### 2.6 Twilio documents nothing about leaving (High, by absence)

Twilio's *Migrate phone numbers and WhatsApp senders* page covers exactly three journeys:
from the WhatsApp Business app, from another BSP, and between Twilio accounts. It says
nothing about migrating a sender away from Twilio, nothing about deleting a sender, and
nothing about what becomes of the underlying number. The brief's premise is correct: this is
undocumented and can only be settled by observation.

### 2.7 The structural reason to expect voice to survive (Medium — verify, do not assume)

In Twilio's data model the `IncomingPhoneNumber` and the WhatsApp `Sender` are separate
resources. Voice URL, SIP domain routing, credential list, and TwiML app all hang off the
`IncomingPhoneNumber`; the WhatsApp sender is an overlay on the messaging side. Deleting the
sender should therefore leave voice, SMS capability, and account ownership untouched. That
is the expectation — it is not documented anywhere, it is the thing step 6 exists to check,
and it must not be assumed on the production number.

One documented adjacent fact: to re-register the same number as a Twilio sender after
deleting it, two-factor authentication must be turned off for the number in WhatsApp
Manager. So the rollback direction (come back to Twilio) is at least a known path, with a
known prerequisite.

---

## 3. Two things to check before recommending any spend

### 3.1 Is Klaviyo's WhatsApp product available on UMI's current plan?

**Not yet observed** — blocked on the same login.

What the public material says (Medium): WhatsApp went generally available in Klaviyo around
October 2025 and rides the **Email + SMS** ("mobile messaging") bundle rather than the
email-only or free tier; it shares the SMS credit pool, which as of 13 July 2026 is moving to
dollar-denominated per-message rates. Klaviyo's own requirements list names **Owner or Admin**
role and a dedicated number that is not already an SMS sending number, and mentions no plan
gate on *connecting*. The gate, if any, is likelier on sending than on connecting — but that
is an inference, not a fact.

**How to settle it in sixty seconds, by observation:** open Klaviyo → Settings → WhatsApp.
If **Connect to WhatsApp** is present and clickable, step 5 of the runbook can reach the
verification screen and the experiment is worth running. If it shows an upsell, a "contact
sales", or nothing at all, step 5 stops at a paywall and the experiment cannot answer its
own decisive question. **Do not buy a plan upgrade to run a test.**

One further constraint worth knowing even though it does not block the experiment: Meta does
not permit WhatsApp *marketing* messages to US phone numbers, and Klaviyo's WhatsApp
marketing is international-only. That affects what a US test number could ever be used to
*send*, not whether it can be verified and migrated.

### 3.2 Does connecting a test number make a mess of the real Klaviyo account?

Yes — bounded, reversible today, and less reversible later. Three specifics:

1. **Klaviyo's WhatsApp connection is account-level and singular.** Settings → WhatsApp holds
   *the* connection. A throwaway WABA connected there occupies the slot the real number will
   eventually need.
2. **Disconnecting is destructive to templates.** Klaviyo's own material: disconnecting the
   WABA *permanently removes the WhatsApp message templates associated with that WABA*, which
   then have to be recreated and resubmitted for Meta approval. For a throwaway WABA with no
   templates that costs nothing. **After UMI starts building real templates it costs real
   work — so if this experiment is going to run at all, run it before that.**
3. **The catch-22 on isolating the test.** Using a separate free Klaviyo account avoids
   touching production, but a free account is the tier least likely to expose WhatsApp at
   all — so the isolated test is the one most likely to die at a paywall, proving nothing.
   Using the real account gets a real answer and pays for it in account state. There is no
   clean third option. Recommendation: settle §3.1 by looking first; if WhatsApp is live on
   UMI's real account, run the test there, before any template work, with `ZZ-TEST-` naming
   throughout — the same convention the §1.2 spike used and tore down cleanly.

A fourth item is Meta-side rather than Klaviyo-side: the test WABA will be created **inside
UMI STORE CO., LTD.'s portfolio** (Klaviyo requires the same portfolio, and the previous
spike established that throwaway assets in that portfolio are manageable). It will sit beside
production assets until torn down. Name it `ZZ-TEST-` so it is unmistakable.

---

## 4. Recommended shape: run the cheap decisive experiment first

The brief's eight-step sequence is written below in full. Before running it, note that it
bundles two independent unknowns into one linear chain, and the cheaper one is decisive:

**Experiment A — can a Meta OTP be captured on a Twilio VoIP number at all?**
No Klaviyo, no migration, no WhatsApp sender, no plan question. Buy one number, point its
voice URL at a TwiML Bin that speaks and records, add the number to a throwaway WABA, and
request the code with `code_method=VOICE`. If the recording carries six intelligible digits
and `verify_code` succeeds, **the objection that started this whole investigation is dead**
and the migration becomes an ordinary, scheduled operation. If Meta refuses to place the call
to a VoIP number, or the code is unusable, everything downstream is moot and you have spent
about a dollar finding out.

**Experiment B — everything else.** Sender registration, the Klaviyo flow itself, voice
survival after deregistration, and the second-app subscription. Worth running only if A
passes or if A is inconclusive in an interesting way.

Running A first inverts the cost curve: the decisive bit costs ~$1.25 and about an hour,
and it does not touch Klaviyo's account state at all. Steps 1–8 below are ordered as briefed;
A is steps 1, 2 and a variant of 5, and can be lifted out and run alone.

---

## 5. The runbook

Preconditions for every step: production is untouched. Do not use the existing sender
`XEa587e2c30f03901fec2c383dad8f5f07`, the SIP domain `umi-spike-2c9dbf`, credential list
`CL4eee7ca2…`, or either `+66975311301` Chatwoot channel. Prefix every created asset with
`ZZ-TEST-`. Record timestamps, Graph API version, and raw responses (tokens redacted) as the
§1.2 spike did.

### Step 1 — buy one throwaway Twilio number

Buy a **US local** number in the same Twilio account that owns the production number (same
account matters: WhatsApp senders are per-account, and the point is to reproduce UMI's
condition, a Twilio-owned VoIP number). Give it a `ZZ-TEST-` friendly name.

* **Go:** number provisions instantly with voice + SMS capability.
* **No-go:** none realistically. If the account cannot buy numbers, stop and fix billing.
* **Cost:** ~$1.15/month list for a US local number. Verify at purchase.

### Step 2 — configure voice, place a test call, confirm it works

Point the number's Voice URL at a TwiML Bin that both answers and captures audio — a `<Say>`
followed by `<Record>` is enough; do **not** wire it to the production SIP domain. Call the
number from a mobile and confirm the recording appears in the Twilio console.

This is not a formality: it establishes that the number can *hear* an inbound call before
Meta places one, which is the exact thing that was missing in 2026 when the OTP attempt
produced error 11200.

* **Go:** the call connects, TwiML executes, a recording exists and is audible.
* **No-go:** any 11200 or 12xxx error — fix the TwiML before continuing, or step 5 will
  reproduce the original failure and misattribute it to Meta.
* **Cost:** inbound voice ≈ $0.0085/min plus recording ≈ $0.0025/min. Under $0.10.

> **Experiment A stops here plus one Meta call.** With the number answering and recording,
> create a `ZZ-TEST-` WABA, add the number, and `POST /{phone-number-id}/request_code` with
> `code_method=VOICE`, `language=en_US`. Then read the recording and `POST .../verify_code`.
> **Go:** six intelligible digits and a successful verify → the OTP objection is dead; the
> Klaviyo migration is a scheduling problem, not a feasibility one. **No-go:** Meta declines
> to call a VoIP number, or the audio is unusable → the production number genuinely cannot
> self-verify, and the honest options are a Klaviyo-provisioned number for marketing, or
> Klaviyo support agreeing to a preverified/manual path. Cost: $0 beyond step 1–2.

### Step 3 — register it as a Twilio WhatsApp sender

Console → Messaging → Senders → WhatsApp senders → Create, through the Facebook flow, into a
new `ZZ-TEST-` WABA. This reproduces UMI's exact condition: a VoIP number auto-verified by
Twilio rather than by an OTP.

* **Go:** sender reaches ONLINE without any OTP being demanded — which itself re-confirms the
  `preverified_id` mechanism in §2.4.
* **No-go:** if Twilio *does* demand an OTP for a US number, the test number is not
  reproducing UMI's condition and the rest of the run is not comparable. Stop and reconsider.
* **Cost:** no registration fee; messaging is billed per message and the experiment sends
  none. Confirm in the console before proceeding.

### Step 4 — confirm voice still works with WhatsApp attached

Call the number again. This is the control for step 6: without it, a failure at step 6 cannot
be attributed to the deregistration rather than to the sender registration.

* **Go:** the call connects and records exactly as in step 2.
* **No-go:** voice broke on *registration* — that is a finding in its own right and it would
  mean UMI's production dual-use setup is more fragile than believed. Record it and stop.
* **Cost:** under $0.05.

### Step 5 — attempt the Klaviyo BSP migration. **The decisive observation.**

Klaviyo → Settings → WhatsApp → Connect to WhatsApp, following their migration article: turn
off two-step verification for the test number in WhatsApp Manager, create a **new** WABA for
Klaviyo in the same portfolio, enter the number, and watch what the flow asks for.

Record, in order: whether a verification step appears at all; whether both SMS and voice are
offered; which one Klaviyo pre-selects for a VoIP number; whether the code arrives; whether
the recording/SMS log captures it; and how long Meta's review takes before the number is
usable.

* **Go (best):** no OTP is demanded because the number is already verified in the same
  portfolio — migration is a portfolio-internal move. This would mean UMI's number can move
  with no verification risk at all.
* **Go (workable):** an OTP is demanded, the **voice** option is offered, and the code is
  captured from the TwiML recording. Migration is feasible with a scripted OTP-capture step.
* **No-go:** an OTP is demanded, only SMS is offered or the voice call never arrives, and no
  code can be captured. The production number cannot migrate to Klaviyo unassisted. Escalate
  to Klaviyo support with this evidence, or take the separate-number option in §2.4.
* **Cost:** $0 in fees if the plan already entitles WhatsApp. Real cost is Klaviyo account
  state per §3.2, and the test WABA's slot.

### Step 6 — call the number again: did voice survive WhatsApp leaving Twilio?

After the migration completes (or after deleting the Twilio sender, if the migration required
it), call the number once more and check that it is still owned by, and billed to, the Twilio
account.

* **Go:** call connects, TwiML executes, number still listed under Phone Numbers with its
  voice configuration intact. Answers question 2 in the affirmative and clears the largest
  unknown for UMI's production voice service.
* **No-go:** voice broken, configuration cleared, or the number released. **This is a
  migration blocker on its own** — UMI's production number carries live agent voice, and
  losing it would be worse than not having WhatsApp on Klaviyo. Do not migrate production.
* **Cost:** under $0.05.

### Step 7 — subscribe a UMI-owned Meta app to the Klaviyo-provisioned WABA

`POST /{waba-id}/subscribed_apps` with a system-user token for a `ZZ-TEST-` UMI app, then the
phone-level override — i.e. exactly what patch 26's
`rake 'umi:whatsapp:foreign_owned_setup[<inbox_id>]'` performs. Remember §1.2's prerequisite:
the app needs its own callback URL saved, verified, and `messages`-subscribed in its own
dashboard first, or Meta answers with error 100 and blames the WABA subscription that just
succeeded.

Then watch for a week (or across a Klaviyo send) whether the subscription and the override
survive, or whether Klaviyo's tooling re-asserts and evicts it.

* **Go:** both apps appear in `GET /{waba-id}/subscribed_apps`, each app reads back only its
  own `phone_number` override (the §1.2 result, reproduced on a Klaviyo-provisioned WABA
  rather than a bare test one), and it persists.
* **No-go:** Klaviyo's platform removes the second subscription, or its onboarding
  periodically rewrites configuration in a way that evicts Chatwoot. The shared-number
  architecture fails and patch 26 has nothing to attach to.
* **Cost:** $0.
* **Note:** this step cannot be run standalone — it needs a Klaviyo-provisioned WABA, so it
  depends on step 5 succeeding.

### Step 8 — tear everything down

In this order, so nothing is orphaned:

1. Disconnect the test WABA in Klaviyo (Settings → WhatsApp).
2. `DELETE /{waba-id}/subscribed_apps` with the UMI test app's token; clear its phone-level
   override.
3. Delete the test number from the WABA in WhatsApp Manager (2SV must be off).
4. Delete the `ZZ-TEST-` WABA, app, and system user in Business Settings — confirm the system
   user's asset list contained only test assets, before and after, as the §1.2 spike did.
5. Delete the Twilio WhatsApp sender if it still exists; release the phone number.
6. Delete the TwiML Bin and any recordings.
7. Re-read `GET /{waba-id}/subscribed_apps` on the **production** WABA and confirm it is
   unchanged from the step 0 baseline.

* **Cost:** releasing the number stops the recurring charge; Twilio bills the month already
  started.

---

## 6. Cost

| Item | Cost |
|---|---|
| US local Twilio number, one month | ~$1.15 |
| Inbound voice + recording across steps 2, 4, 6 | < $0.20 |
| Twilio WhatsApp sender registration | $0 (no message sent) |
| Meta WABA / app / system user | $0 |
| Klaviyo connection | $0 **if** WhatsApp is already on UMI's plan; otherwise blocked — do not upgrade for a test |
| **Hard spend** | **≈ $1.25–$2**, under $5 with any retries |

The money is not the cost. The real costs are: Ivan's time (2–4 hours across steps 1–8, plus
waiting on Meta's migration review at step 5), one occupied Klaviyo WhatsApp connection slot,
and throwaway assets sitting in the production Meta portfolio until teardown. Experiment A
alone costs about $1.25 and an hour, and touches neither Klaviyo nor the portfolio's app
configuration.

---

## 7. What a US test number does not prove

Stated up front because the experiment's conclusions will be tempting to over-read.

1. **Thai OTP delivery.** Meta routes verification SMS and voice through per-country vendors.
   A US number receiving (or not receiving) a code says little about `+66`. This cuts hardest
   on the SMS leg: a US Twilio number receives SMS normally, so a successful SMS OTP in the
   test would be **falsely reassuring** — Thai Twilio numbers are regulated differently and
   may not have usable inbound SMS at all. Treat only the **voice** result as transferable,
   and treat even that as indicative.
2. **A number with history.** `+66975311301` carries a HIGH quality rating, an approved
   display name, an established messaging tier, and possibly OBA status. A fresh test number
   has none of it. The test cannot show whether those survive migration, whether Meta reviews
   a seasoned number differently, or how long a real number stays dark during review.
3. **Production entanglement.** The production number is bound to a SIP domain, a credential
   list, a TwiML application, two Chatwoot channels, and live agent registrations. "Voice
   survived" on a bare test number with a TwiML Bin is materially weaker evidence than the
   same result on that wiring. Step 6 reduces the risk; it does not eliminate it.
4. **Downtime.** Klaviyo warns the number *"cannot send or receive messages from the moment
   you begin migration until Meta completes its review."* A test number's outage length is not
   predictive of a seasoned commercial number's, and the business impact is not simulated at
   all.
5. **Portfolio and verification state.** If the test runs under a different portfolio, or one
   with different business-verification status, Meta may behave differently. Run it in UMI's
   real portfolio or discount the result.
6. **Klaviyo's branch selection.** Klaviyo's *new number* flow and its *migration* flow are
   different code paths. A test number that was a live Twilio sender does reproduce the
   migration branch — but not the specific case of migrating out of a WABA that Twilio
   provisioned inside UMI's own portfolio with an already-approved display name.
7. **Nothing about Klaviyo's steady-state behaviour.** Step 7 observed over days is not the
   same as a WABA under real campaign load with Klaviyo's tooling re-running onboarding
   checks. §1.2's caveat still stands too: no real inbound `messages` delivery test has ever
   been completed on a two-app number.

---

## 8. Open decisions for Ivan

1. **Log in to Facebook in Chrome** so step 0 can be observed. Everything above branches on
   H1 vs H2, and H2 means "do not run the experiment yet."
2. **Look at Klaviyo → Settings → WhatsApp** and say whether *Connect to WhatsApp* is
   available. If it is paywalled, step 5 cannot run and the experiment is worth only its
   Experiment A part.
3. **Approve or decline the spend** — ~$1.25 for Experiment A, ~$2 for the full run, plus the
   Klaviyo account-state cost in §3.2. Nothing is bought until this is a yes.
4. **Decide whether the one-number premise is negotiable.** §2.4's alternative — let Klaviyo
   provision its own marketing number, keep `+66975311301` on Twilio for support and voice —
   removes every risk in this document. It costs the unified-number story and Klaviyo's
   revenue attribution stays intact either way. Worth an explicit decision rather than an
   implicit one.

## Sources

* [Klaviyo — How to migrate from another WhatsApp Business Solution Provider to Klaviyo](https://help.klaviyo.com/hc/en-us/articles/40116637850651)
* [Klaviyo — How to connect your WhatsApp Business account to Klaviyo](https://help.klaviyo.com/hc/en-us/articles/40111819732635)
* [Klaviyo Academy — Enable WhatsApp in Klaviyo](https://academy.klaviyo.com/en-us/learning-paths/getting-started-with-sms/courses/getting-started-with-whatsapp/lessons/enable-whatsapp-in-klaviyo)
* [Twilio — Migrate phone numbers and WhatsApp senders](https://www.twilio.com/docs/whatsapp/migrate-numbers-and-senders)
* [Twilio — Register WhatsApp senders using Self Sign-up](https://www.twilio.com/docs/whatsapp/self-sign-up)
* [Twilio Help — Twilio number already registered with a WhatsApp account](https://help.twilio.com/articles/10665149551515)
* [Meta — Business phone numbers](https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/phone-numbers)
* [Meta — Two-step verification](https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/two-step-verification/)
* [Bird — Setting up the WhatsApp Embedded flow (`preverified_id`)](https://docs.bird.com/api/channels-api/supported-channels/programmable-whatsapp/whatsapp-isv-integration/whatsapp-channel-onboarding/setting-up-the-whatsapp-embedded-flow)
* [respond.io — Phone Number Migration to WhatsApp Cloud API](https://respond.io/help/whatsapp/phone-number-migration-to-whatsapp-cloud-api)
