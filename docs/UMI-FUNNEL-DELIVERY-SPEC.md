# Funnel delivery adapters

2026-09-27. Implementation detail for the approved funnel plan U4/U6; consumes
`UMI-FUNNEL-EVENTS-SPEC.md`. The user directed continued implementation. All
external delivery remains disabled until configured and an explicit provider test
is approved. This is normal integration configuration, not a new permission system.

## Outcome

One operator can preview and dispatch a recorded, eligible outcome to Meta or an
existing Klaviyo profile, and see accepted, confirmed, rejected or unknown delivery
state. Customer messages, campaign creation, budget changes, audience membership,
profile creation and subscription changes are outside these adapters.

## Existing contracts and alternatives

Meta business messaging supports QualifiedLead and requires channel-scoped user
identity. Its current official guide says it does not deduplicate events. Therefore
use the local event/destination unique row and commit the sending claim before
network I/O. A response lost after send stays unknown; do not add retries. Reusing
website CAPI mapping or treating a Shopify chat link as a messaging Purchase would
misstate purchase origin. Only Messenger qualification is enabled by this first
adapter. Instagram permission is currently absent; purchase origin/native overlap
is unresolved. Those remain explicit exclusions, not guessed alternatives.

Klaviyo native Shopify Placed Order includes unpaid reservations. Send distinct
UMI Conversation Qualified and UMI Order Paid metrics to an existing, verified
profile. Reuse HTTParty and the existing API-key ENV convention with revision
2025-10-15; never change existing LINE or native Shopify clients. Stable unique_id
and original occurrence time prevent replay from becoming a second event. A 202
is accepted for processing, not confirmed. Do not replace existing reservation
suppression filters or subscribe customers.

Sources read 2026-09-27: [Meta business messaging](https://developers.facebook.com/documentation/ads-commerce/conversions-api/business-messaging),
[Klaviyo create event](https://developers.klaviyo.com/en/v2025-10-15/reference/create_event),
[Klaviyo get events](https://developers.klaviyo.com/en/reference/get_events),
[Klaviyo get profile](https://developers.klaviyo.com/en/reference/get_profile).
The Meta `.md` representation supplies the same guide when HTML fetch is throttled.

## Frozen destination and payload

Use `Umi::ConversionDelivery` fields `payload` (JSON), `destination_key`, `state`,
`reason`, `attempt_count`, `attempted_at`, `accepted_at`, `confirmed_at`,
`provider_reference`, `last_error`. Unique event + destination. Pending rows are
prepared once with an immutable destination and payload. No raw response bodies,
credentials, customer message content or contact email/phone enter delivery rows.
Payloads necessarily contain the provider's scoped identifier; privacy cleanup
must clear them and retain a delivery tombstone.

`prepare(delivery)` locks the row and rechecks source event/contact redaction and
source account. Unsupported events/channels become excluded with a reason.
Missing verified attribution/profile identity stays pending with a reason; later
verified linkage can prepare the same never-attempted row, without a new event. Missing operator configuration raises a visible setup error.
Already prepared rows keep their profile/dataset and unique_id; changes of target
require an explicit new design rather than quietly bypassing deduplication.

`dispatch(delivery)` requires the destination-specific enabled ENV setting,
rechecks current redaction and source validity, commits `sending` + attempt time
under contact-first, then delivery locking (matching redaction), then calls HTTP
exactly once after releasing database locks. Erasure before the claim excludes
the row; erasure after the committed claim leaves a visible in-flight attempt. Only `pending` may claim. Another
worker seeing `sending` must not send. Timeout, connection failure, malformed
success or server uncertainty becomes `unknown`; a restart leaves persisted
`sending` visibly held and never replays it. Definitive HTTP client rejection is
`rejected`; no automatic retries in this release. Log error class/status only.
An explicit reconciliation command changes abandoned sending rows to unknown.

## Messenger mapping

Require `conversation_qualified`, nonhistorical provenance, occurrence time not
in the future and within seven days, and an immutable Messenger channel/page/PSID
snapshot captured from the qualifying conversation's actual inbox/source.
Require configured account, page and dataset IDs to match the snapshot. Do not
use latest conversation sidebar referral to replace occurrence-time evidence.
Require no later human correction that invalidates qualification; removing a
report label alone is not a correction.

POST Graph v23.0 `/{dataset_id}/events` with bearer token from ENV (never URL),
`data: [{event_name: 'QualifiedLead', event_time: epoch,
action_source: 'business_messaging', messaging_channel: 'messenger',
user_data: {page_id, page_scoped_user_id}}]`. Optional test_event_code is explicitly
configured. Do not claim server deduplication from event_id. A 2xx body with
`events_received: 1` is accepted; otherwise hold unknown or rejected according to
an explicit error response. Accepted does not prove ad attribution or available
campaign optimization goal; Events Manager verification is separate.

## Klaviyo identity and mapping

A binding command takes account/contact/profile IDs and an actor/reason, fetches
that existing profile, compares normalized nonempty email or phone to the current
contact, rejects any conflicting shared identifiers or another contact's binding,
and stores a verified binding in contact additional_attributes. No name/social
handle match and no external-ID-only profile creation. Preserve unrelated fields.
Recheck the same provider profile and contact match at preparation and dispatch;
pin the profile ID in destination_key. Redacted contacts cannot bind or export.

The event payload uses profile `{data: {type: 'profile', id: profile_id}}`, metric
name UMI Conversation Qualified or UMI Order Paid, original time, stable unique_id
`umi-funnel-{account_id}-{event_id}`, and allowlisted properties including
`umi_event_id`, qualification reason or shop/order/currency/value. Paid metrics
require an authoritative frozen paid snapshot and verified contact identity;
unknown historical paid events stay local. Never use current refund state to
invent an original paid value/time. Initially unlinked commerce remains visible
locally, with no guessed profile.

Ordinary dispatch requires a non-null, nonfuture occurred_at at or after
UMI_FUNNEL_STARTED_AT, regardless of provenance. An older order paid before
activation but updated afterward remains local with reason pre_boundary.
Historical/backfill events are excluded from ordinary dispatch; implementing a
later backfill requires explicit non-sending flow configuration and `backfill`
semantics. The current adapter does not import history implicitly.

Readback uses GET events filtered by pinned profile and bounded occurrence-time
window, includes metric relationship, and scans bounded pages for matching
`umi_event_id`, exact metric name, profile and occurrence time. A match records
provider event ID and `confirmed_at`. No match remains accepted; incomplete
pagination is reported visibly, never called confirmed. No marketing-consent
changes occur during binding, sending or readback.

## Interface and verification

Services under `umi/app/services/funnel/` with one small HTTP client per provider;
rake commands under `umi:funnel` for preview, profile binding, dispatch and readback.
Use explicit IDs, output only operational status/IDs/reasons. No new web endpoint,
new scheduler, provider retry framework or admin UI is needed.

Specs use WebMock and real event/delivery/contact rows: correct request bodies;
no profile creation; missing/conflicting/changed identities; changed destination;
future/stale/imported/refunded evidence; correct recipient page; disabled exports;
duplicate claims; successful response, client rejection, transport failure,
crash-stuck sending; privacy cleanup; accepted vs readback-confirmed. Inspect
existing redaction/client specs and run them with new tests. No live event is sent
by tests. A final runbook names required configuration and exact test payloads for
operator review; external acceptance remains unverified until the approved test.
