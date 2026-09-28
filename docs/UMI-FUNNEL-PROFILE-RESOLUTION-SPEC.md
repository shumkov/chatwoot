# Automatic existing-profile resolution for funnel exports

28 September 2026. Implements the existing-profile resolution portion of the
approved funnel plan U4. Independent review precedes code. This does not claim
completion of lifecycle segments or automatic conversation classification.

## Problem and choice

Confirmed qualification/payment events cannot reach Klaviyo until someone runs
a profile-binding command. The operator has already supplied an email/phone or
selected a Shopify customer, and Klaviyo commonly already has that profile.
Resolve that unique existing profile automatically using the same identity
checks as manual binding. Keep the manual command for explicit corrections.

Use the current HTTParty client, API revision 2025-10-15, ProfileBinding,
DeliveryService and five-minute delivery scheduler. No new table, queue,
credential, permission role, profile creation or subscription change.

Klaviyo's [Get Profiles](https://developers.klaviyo.com/en/v2025-10-15/reference/get_profiles)
supports exact email and phone_number filters, sparse fields, and page size.
Use a bounded exact lookup instead of listing all profiles or creating a second
contact directory. An SDK replacement or n8n identity workflow would duplicate
the existing match/freeze/erasure boundary without helping the operator.

## Contract

- Only configured/enabled funnel accounts and Klaviyo exports may automatically
  resolve identity. A selected delivery must still be pending, have a valid
  source/contact, and pass the existing event eligibility and hold checks.
- Use trimmed case-normalized email and the existing E164 normalization. No
  inferred country code, name, Instagram handle or profile-photo matching.
- Query exact email and exact phone separately when present; the live endpoint
  rejects explicit OR filters. Request only id/email/phone_number, with page
  size 2 per query, and combine results by distinct profile ID. Zero results means
  no existing profile; multiple results or any nonempty next link means ambiguous.
  Every shared nonempty identifier must agree using ProfileBinding.matches?.
- A second non-redacted contact in this account sharing a matching normalized
  identifier prevents automatic binding, even when neither contact is bound
  yet. The operator must resolve the duplicate identity instead of the worker
  choosing whichever delivery happens to run first.
- Reuse the profile-scoped advisory lock and contact lock. Re-read the contact
  and its identifiers after HTTP. A changed identifier, redacted/deleted source,
  new conflicting binding or duplicate contact prevents the write. Never hold
  a database lock over provider HTTP.
- Keep an existing binding unchanged; normal delivery still revalidates it.
  A concurrent manual binding wins. Do not redirect a frozen delivery target or
  clear existing terminal delivery states.
- Persist the same umi_klaviyo_profile_id plus binding metadata with explicit
  source `exact_identifier_match` and verification time. Do not attribute the
  automatic match to a human actor. Existing manual actor/reason validation
  stays unchanged.
- Resolution only writes local binding metadata. The existing adapter owns
  event payload preparation, frozen recipient, one-send claim and readback.
  No new positive outcome arises from finding an identity.

## Scheduling and failure behavior

Extend the existing scheduled delivery path, not every contact update. A pending
Klaviyo delivery with no binding and at least one usable identifier can enqueue
the existing DeliveryJob. That job resolves its profile before normal dispatch.
Bounded scheduling remains at 100 candidates each five-minute pass. Select the
oldest updated pending candidates, with ID as a tie-breaker, and touch every
considered candidate even if identity is still missing or enqueue fails. This
rotates unresolved rows behind untouched work instead of letting the first 100
missing profiles starve newer outcomes forever. Existing attempt/acceptance
timestamps retain their meanings; no scheduling column or retry framework is
needed. The readback schedule remains based on accepted_at.

No identifiers or no profile leaves `profile_unbound` and can resume when
identity appears. Skip network work for contacts without usable identifiers.
Ambiguity/conflict is a visible preparation hold requiring the existing manual
preview/correction path; do not repeatedly call a conflicting provider record.
Provider read failure uses the existing preparation_failed hold and sanitized
error class. Profile lookup never retries an event POST. Duplicate jobs may
repeat a GET but can only persist one binding and claim one outbound event.

Manual preview may use the same exact resolver so an operator can recover a
corrected hold. Disabled export must not cause automatic binding merely from a
scheduled job. Preserve the existing manual profile-binding command's behavior.

## Verification

Write meaningful examples before implementing the missing automatic path:
an eligible event plus one exact existing profile must become deliverable
without a manual binding command. Verify the example fails on the existing code.

Cover email-only, canonical phone-only, both matching, conflicting shared phone,
two remote profiles, a next-page response, duplicate local contacts, anonymous
contacts, wrong account, disabled export, concurrent manual binding, identifier
change/erasure during GET, frozen destination and repeated jobs. Assert no
profile/subscription API writes and one event POST. Keep existing manual binding,
delivery, scheduling and privacy examples green. Check actual GET filter/body
against the pinned API contract with WebMock and a read-only live lookup.
Verify that 100 unresolved rows do not prevent the 101st eligible row from being
scheduled on the next pass, including contacts with no usable identifier.

Production acceptance can verify a legitimate existing contact/profile binding
without inventing a sale. The first genuine qualified/paid delivery and provider
readback remain separately recorded evidence. Deployment uses the existing
release/tag/digest and infra-owner process.

## Verification checkpoint

The initial integrated no-manual-binding test and bounded-rotation test failed
against the previous code, then passed with this implementation. A read-only
live probe on revision 2025-10-15 confirmed exact email lookup (one matching
profile), exact phone lookup (multiple profiles with a next page), and HTTP 400
for explicit OR: “The requested endpoint does not permit explicit or() and
not() filters.” A regression reproduced that response before switching to
separate bounded queries. No profile or outcome was created by the probe.
