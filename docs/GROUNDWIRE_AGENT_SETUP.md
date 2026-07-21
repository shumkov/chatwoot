# Taking Work Calls on Your Phone — Groundwire Setup

This guide sets up **Groundwire** (a "softphone" app) on your phone so you can **make and receive work calls** through our Twilio phone system. Calls ring your phone like a normal call — even when it's locked — and the caller's details show up in Chatwoot. You never expose your personal number.

> **iPhone-focused** (the steps are nearly identical on Android — note the few differences called out below).

---

## What your admin gives you

Each agent has their **own** SIP login. Ask your admin for these three values:

| Field | What it is | Example / current pilot value |
|---|---|---|
| **Domain** (SIP server) | the phone system address | `umi-spike-2c9dbf.sip.singapore.twilio.com` |
| **Username** | your agent SIP user — `agent-<your Chatwoot user id>` (it links answered calls to you in Chatwoot) | `agent-1` |
| **Password** | your SIP password | *(issued to you privately)* |

> ⚠️ Treat these like a password — they are your phone line. Don't share or reuse them.

---

## 1. Install Groundwire

- **iPhone:** App Store → search **"Groundwire"** (by *Acrobits*) → buy & install (one-time ~$9.99/device).
- **Android:** Google Play → **"Groundwire"** (by *Acrobits*).

(Groundwire is a paid app; the free *Acrobits Softphone* also works but Groundwire is the recommended one for reliable background ringing.)

## 2. Add your SIP account

1. Open Groundwire → **Settings** → **Accounts** → **＋** (add) → choose **Generic SIP account** (or "SIP Account").
2. Fill in the **New Account** form:
   - **Title:** `UMI` (any label you like)
   - **Username:** *(your username, e.g. `agent-1`)*
   - **Password:** *(your password — case-sensitive, type it carefully)*
   - **Domain:** *(your domain, e.g. `umi-spike-2c9dbf.sip.singapore.twilio.com`)*
3. **Incoming Calls:** tap it → select **Push Notifications**.
   - This is what lets your phone **ring while locked or with the app closed**, and it's battery-friendly. (It hands registration to Acrobits' push server, which wakes your phone when a call comes in.) **Don't skip this.**
4. **Caller names** — so you see *who's calling* (the contact's name, not just a number): open **Incoming Caller ID** and drag **`Remote-Party-ID`** to the **top** of the list (use the ☰ handle on the right, above *From Username* / *P-Asserted-Identity*). Our system puts the contact's name in that field, so it shows on the call screen.

## 3. Set the transport to TCP

1. Still in the account (or **Advanced** settings) → **Transport Protocol**.
2. Select **`tcp`**. *(Default is `udp` — change it. TCP is the most reliable for staying registered + push. We may move to `tls (sip)` later for encryption.)*
3. Tap **Done** / **Save**.

## 4. Allow permissions

When prompted (or in iOS **Settings → Groundwire**), allow:
- **Microphone** — required for call audio.
- **Notifications** — required for the phone to ring.

(On Android also disable battery optimization for Groundwire so it isn't killed in the background.)

## 5. Confirm it's connected

Back on the Accounts screen, your account should show **Registered / Online** (usually a green dot).
- If it shows offline/failed, see **Troubleshooting** below.

---

## Using it day to day

**Receiving a call:** your phone rings with the normal incoming-call screen showing the caller. Tap to answer. Open **Chatwoot** to see who it is and the conversation history.

**Making a call:** from the contact or conversation in **Chatwoot**, tap **Call** — it launches Groundwire and dials. (You can also dial directly from Groundwire's keypad.)

**Ending / muting:** use the on-screen call controls, same as a normal call.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| **Not "Registered"** | Re-check **Domain**, **Username**, **Password** are exactly as given (password is case-sensitive). Make sure you're on internet (Wi-Fi/cellular). Confirm **Transport = tcp**. |
| **Doesn't ring when locked / app closed** | **Incoming Calls** must be set to **Push Notifications** (Step 2.3). In iOS **Settings → Groundwire → Notifications**, allow notifications. Turn off aggressive Low Power Mode. |
| **No audio after answering** | Allow **Microphone** permission (iOS Settings → Groundwire). If still silent, tell admin (may be a transport/firewall issue). |
| **Rings but I can't be the one who answers** | Calls ring everyone on duty; first to answer gets it — that's expected. |
| **Calls not arriving at all** | Confirm with admin that your account is active/registered on the server side. |

---

## Good to know

- Calls travel over the internet (VoIP). Your normal cellular calls/texts are unaffected.
- Keep Groundwire **installed and signed in** — you don't have to keep it open (push wakes it), but don't delete it.
- If you get a new phone, set it up again with the same details (your admin can reset your password if needed).
- **This is a pilot setup** — report anything flaky (no ring, dropped audio, wrong caller name) to your admin so we can tune it.
