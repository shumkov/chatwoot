# CRM stages one and two - closure record

5 October 2026, Bangkok. This is the current acceptance record; earlier dated
receipts retain their historical meaning. It does not declare the entire funnel
accepted while the native website Purchase issue below remains open.

## Current production and implementation

Production starts this checkpoint on release27. Instagram qualification and
future eligible paid-in-chat Purchase are enabled. At 18:45 UTC on 4 October,
Events Manager showed the genuine `QualifiedLead` as Active, one processed
Conversions API event. Advertising attribution remains a different observation.

Two remaining implementation gaps are covered by reviewed patches:

- [Recent conversation intent](UMI-RECENT-INTENT-PROVISIONING-SPEC.md): the existing
  periodic segment job creates and reads back the native 30-day audience after a
  genuine confirmed Klaviyo qualification. No manual developer invocation, new
  service, synthetic event or marketing flow is required.
- [Private command feedback](UMI-COMMAND-FEEDBACK-SPEC.md): immediate queued note,
  followed by an edit to the same private note with the existing settlement result.
  Expected rejections remain explicit. Deleted commands cannot be treated as
  applied, and deleted acknowledgements are not resurrected.

Release, CI and live readback receipts are appended after delivery. Local tests
and reviews alone are not a production installation receipt.

## Klaviyo and customer lifecycle

Fresh provider inventory contains 847 profiles: 176 Clients, 42 Repeat, 584
non-buyers and 45 unresolved. Payment and service observations are fresh for all
847. Service context is 823 clear, one hold and 23 unknown; unknown is not clear.

There are no attempted or confirmed custom-event deliveries yet. Two genuine
pending records lack exact identity: an anonymous partner-location payment and
a qualified Instagram conversation without email, phone or existing profile
binding. Those are appropriate holds. Do not fabricate identities or substitute
a native Placed Order event to manufacture acceptance.

Recent conversation intent therefore has not been created at this checkpoint.
The new automation removes the implementation gap; actual provider creation waits
for the first genuine profile-bound confirmed qualification. The sole live flow
is the existing Welcome Series, not new cart recovery. The complete observed
Checkout Started inventory has no draft-order item marker, so that particular
native marker remains unverified. No extra marketing flow has been activated.

## Native website Purchase: a real unresolved decision

The current Shopify Meta browser pixel sends `Purchase` on `checkout_completed`
without checking financial status or the TBYB flag. A genuine recent TBYB order
is entirely unpaid; the same hour contains browser and server Purchase activity.
Individual sampled activity was unavailable, so the server payload and per-order
deduplication are not established by that correlation. The browser source itself
is enough to establish that paid-only semantics are not guaranteed.

Chatwoot correctly excludes website-checkout orders from its messaging sender.
Adding another standard Purchase would not fix the native event and could
duplicate measurement. No current advertising or storefront tracking was changed.

The supported choices are:

1. Preserve native tracking and add a separate verified-payment event/conversion
   target. This is smaller, but the native standard Purchase remains checkout-based
   and Linh must choose the new target for the appropriate future campaign.
2. Replace native website event transport while preserving catalog/channel
   integration. This can make standard Purchase paid-only but needs a controlled
   cutover of consent, matching, event IDs and upper-funnel events.
3. Change the reservation checkout process so unpaid fitting/pickup does not
   complete checkout. This changes the customer workflow, not merely tracking.

No documented native paid-only toggle or per-Purchase filter was found. The first
option is the smallest candidate when the requirement is an accurate paid target;
it does not satisfy a requirement that every standard Purchase mean paid. Ivan
must choose the business contract before a tracking or checkout cutover. A new
sender is not part of the two narrow closure patches.

## Stage two: historical reconciliation and audit

The approved [historical scope](UMI-HISTORICAL-CRM-AUDIT-SPEC.md) has already
processed 1,095 conversations and 12,175 retained messages using full histories.
It applied 899 reviewed classifications, held 187 histories and excluded nine
test threads. Forty-eight customer identities were verified. The approved role
cohort applied 142 contact outcomes, including 30 verified Klaviyo profile writes;
five identity/ownership cases remain explicit exceptions. No guessed order or
customer match, historical advertising replay or historical outreach is allowed.

The audit PDF and detailed CSV were delivered to UMI Orders on 2 October. Archive
execution is not a reason to relabel everything again. Held cases stay held until
new exact evidence or a human correction exists. The deferred command-feedback
item is addressed by the narrow patch above. Sonnet migration, autonomous public
AI replies and Chatwoot-side AI order creation are outside this historical scope.

## Human handoff and future observations

- Linh prepares the actual campaign. The existing paused ad set uses Conversations
  and mixed Messenger/Instagram destinations; its published goal control is locked.
  Earlier validate-only API acceptance for IG messaging Purchase is not a new
  campaign launch. Confirm the goal available in the campaign Linh prepares.
- Mai must receive the [chat guide](UMI-MAI-CHAT-GUIDE.md) and confirm she can see
  public Instagram ad comments in Business Suite. Instructions are ready;
  adoption is not a technical receipt. DM reminders/SLA do not measure comments.
- Observe the first genuine eligible paid-in-chat Purchase and the first genuine
  Klaviyo qualified event. These are data-dependent observations, not reasons to
  generate fake events or disable the working Instagram sender.
- Observe the next natural Friday report on 9 October. The installed schedule,
  successful pilot and reminder receipts are not proof of a future scheduled run.

User-facing handoffs: [Linh campaign guide](UMI-LINH-MESSAGING-CAMPAIGN-GUIDE.md)
and [Mai chat guide](UMI-MAI-CHAT-GUIDE.md). The user will forward them. No message
was sent to Linh or Mai by this work.

Private evidence is under `Downloads/umi-stage-closure-2026-10-05` on the operator
Mac. It contains provider inventories, exact native pixel evidence and tests;
customer-level records and credentials do not belong in this repository.
