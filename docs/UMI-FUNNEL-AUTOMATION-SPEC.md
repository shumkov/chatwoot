# Scheduled funnel delivery and website paid-customer links

2026-09-27. Draft for independent review. Completes two operational gaps in
`UMI-FUNNEL-EVENTS-SPEC.md` and `UMI-FUNNEL-DELIVERY-SPEC.md`; it does not change
their financial or provider contracts. Implementation follows review. Linh owns
ads; campaign choices are not prerequisites for this engineering slice.

## Problem and scope

Recorded outcomes currently require one rake dispatch/readback per delivery.
Paid orders also acquire a contact only through verified conversation attribution,
so a website-only buyer cannot receive the dedicated Klaviyo paid metric even
when an existing synced contact and verified profile binding are available.

Use the existing five-minute reconciliation cron, Sidekiq, financial snapshots,
event rows and delivery rows. No new table, scheduler, customer/profile creation,
model classifier, consent change, customer message, Meta Purchase sender or new
permission mechanism. Automatic classification remains a separate shadow-evaluation
slice; these deliveries consume the existing confirmed qualification/paid facts.

## Research and choice

Inspected `Funnel::ReconcileJob`, `DeliveryService`, `ProfileBinding`,
`Shopify::OrderFinancialStateService`, `CustomerContactMapper`,
`ContactSyncService`, `Shopify::PersistCustomerLink`, `CustomerRedactionService`,
`Webhooks::ShopifyCompliance`, and `Line::KlaviyoBindJob`.

The sync/sidebar already store `additional_attributes['shopify_customer_id']`;
the mapper can store an integer, so compare JSON text to a canonical numeric ID.
There is no uniqueness constraint on that key: multiple matches must stay
unresolved. The existing sync refuses to overwrite a different Shopify ID.
The existing delivery service owns destination freezing, source checks and the
committed send claim; the jobs must call it rather than reproduce those rules.

Manual rake-only delivery remains useful for diagnosis but does not finish the
operating loop. A second queue/outbox or n8n workflow would duplicate durable
state. Polling accepted events indefinitely wastes API calls; use a small finite
readback schedule. New email/name matching at payment time would weaken existing
identity rules; exact stored Shopify IDs are the smaller approach. Existing
provider clients and pinned API contracts remain unchanged.

## Scheduled delivery

Extend the existing reconciler with a bounded delivery scan for enabled funnel
accounts. Process at most 100 dispatch candidates and 100 due readbacks per run,
oldest first. Only destinations with their existing `UMI_FUNNEL_*_ENABLED` switch
enabled are scheduled. No new positive outcome arises from the scan.

`Umi::Funnel::DeliveryJob.perform_later(delivery.id)` reloads the row and calls
`DeliveryService#dispatch`. Duplicate enqueues are acceptable: the service's
contact-first lock and persisted `sending` claim prevent duplicate POSTs. No
network call occurs while holding these database locks. `sending`, `unknown`,
`rejected`, `excluded` and completed rows never become dispatch candidates.
The worker rechecks account and destination enablement at execution time.

Pending candidates are restricted to reasons nil, `dispatch_disabled`,
`account_disabled`, `identity_unlinked` and `profile_unbound`. A local prerequisite
check avoids scheduling unresolved contact/profile links repeatedly; their pending
reason remains visible. Once a link/binding appears, the same delivery becomes
eligible. Identity conflicts, setup errors and pre-send provider-read failures
remain pending with a sanitized hold reason (`preparation_failed` for exceptions)
and `last_error` containing only the error class/code. They require an explicit
operator preview after correction; the cron does not repeatedly call an invalid
profile or retry a failing configuration. Automatic preparation and claiming must
recheck holds established by another job; only explicit operator preparation
may clear them. Successful explicit preparation clears
the hold and allows the normal scan to resume. No new retry controller is added.

The job handles pre-send exceptions by recording that hold under the existing
locks, only while still pending. If an exception occurs after a persisted claim,
keep `sending`/`unknown` held; never reset to pending. Prevent ActiveJob/Sidekiq
automatic retries for these delivery jobs using the repository's supported job
exception handling. Queue-enqueue failure remains recoverable by the next scan.
Logs contain row IDs and error classes, not provider bodies or profile identifiers.

## Finite Klaviyo readback

Add one integer column `readback_attempt_count`, non-null default 0, to existing
delivery rows. Keep `attempt_count` as the outbound event POST count. This single
counter survives duplicate jobs/restarts without changing the frozen payload or
overloading error strings as scheduling state.

For accepted Klaviyo deliveries with `accepted_at`, reserve readback attempts at
5 minutes, 30 minutes and 2 hours after acceptance. Under source/contact-first and
delivery locks, recheck accepted/non-redacted state, enablement, due time and count;
increment the counter before HTTP. A duplicate job cannot reserve the same slot.
A crash consumes its slot; the later slots remain available. Never reset counters
on restart. Three attempts is the limit, including failed provider reads.

Call the existing bounded `DeliveryService#confirm` (at most ten pages per attempt).
A matching event becomes confirmed. Missing match, page cap or provider-read
failure stays accepted with a visible sanitized reason. After the third reserved
attempt it is no longer scheduled, regardless of whether the worker crashed;
the report exposes exhausted/unconfirmed count from the counter, not only a
best-effort reason string. No event POST is repeated by readback. Meta acceptance
continues to require separate Events Manager verification.

Every post-read status/reason update rechecks source erasure and state under the
same locks, preserving `erasure_required`. The explicit rake readback remains
available after exhaustion; it is an operator action, not a reset of the automatic
budget. Add aggregate report counts for pending preparation holds and exhausted
accepted readbacks so these cannot disappear behind a generic pending total.

## Website customer identity without invented conversation attribution

Extend the authoritative order read to extract only Shopify `customer.id` as a
positive numeric string. Do not retain or print the returned customer object,
email, phone, address or name. Persist this identifier as `shopify_customer_id`
in the sanitized financial snapshot, outside `first_paid_snapshot`; it is linking
metadata, not a payment fact. Missing customer ID stays unknown and does not
invalidate otherwise reconciled money.

For the state's enabled account, require the same sole enabled Shopify hook and
matching shop domain already required by financial reconciliation. Find existing
contacts in that account with exactly the stored Shopify customer ID. Zero or
multiple matches, a redacted contact, or disagreement with existing verified
conversation attribution is an explicit identity hold. Never pick the first
match, create/merge contacts, or use order email, phone, name or totals as fallback.
Absent order customer ID does not invalidate an existing verified conversation
attribution; that established path continues to work.

When there is one exact non-redacted contact, a paid occurrence may attach that
contact while retaining `conversation_id: nil`. This is a website/customer link,
not a chat-assisted claim. Require an existing separately verified Klaviyo profile
binding and the delivery service's current identifier readback before export.
Meta paid export remains excluded as `purchase_origin_unresolved`.

Reuse a small local linking method from financial reconciliation and the existing
reconciler. The latter scans unlinked paid states with stored customer IDs so a
later contact sync/binding can unblock the original pending occurrence without
another Shopify request or conversion. Under contact-first then financial/event
locking, recheck the exact customer key, contact tombstone and duplicate matches.
Never replace an already attached contact or modify occurrence time/value/key.
Serialize later financial identity updates with that immutable contact lock.
An already attached payment with a financial identity hold also remains pending
for delivery as `financial_identity_conflict`, including manual dispatch; an
unlinked payment keeps its resumable `identity_unlinked` reason.
Expose identity holds in the snapshot/report. The model's immutable-event rule
must still allow a one-time verified conversation attachment later to the same
contact; it must not permit moving that contact or replacing a prior conversation.
Only verified conversation attachment projects Chatwoot commerce status/labels.

## Privacy completion for the added identity path

Website contacts can have no conversation, and customer erasure can arrive before
a synced contact exists. Extend the existing authenticated, replay-guarded
`customers/redact` path to redact financial states matching resolved account,
shop and Shopify customer ID, including when normal contact lookup finds nothing
or destroys a conversation-free contact. Reuse the existing compliance account
resolution and transaction/error handling; do not bypass its HMAC/replay checks or
phone-only contact policy. This exact Shopify-ID cleanup requires no email/phone
matching and does not erase an unrelated contact.

Also consume the authenticated payload's `orders_to_redact` positive numeric
order IDs for that resolved account/shop. A queued financial row may still have
an empty snapshot, and an order row may not exist at all: matching only a stored
customer ID cannot cover either case. In the same redaction transaction, upsert
redacted financial tombstones for those exact order keys, with empty snapshots,
no paid-event association and the existing required request timestamp. Redact
any matching existing paid events/deliveries before detaching them. Do not read
Shopify, enqueue reconciliation, or create an ordinary pending financial row.
Validate supplied order IDs before applying the transaction; malformed IDs fail
through the existing visible compliance error handling. Preserve existing
account/shop resolution when the hook has already been removed. A later order
notification or already-queued reconciliation must see the tombstone and stop
before any Shopify read, identity attachment or positive event creation.

For direct contact erasure, capture the stored Shopify customer ID before the
existing service clears its attributes, and redact matching states in that same
contact-locked transaction as well as already attached events. Remove the new
snapshot identity, detach/redact paid events, preserve occurrence/order tombstones
against resurrection, and keep downstream erasure references/markers. A later
sync, order notification or local linking scan cannot reattach a redacted state.
Shop/account erasure continues to remove the scoped records. Cover erasure of an
unpaid website state too, so its later payment cannot restore the identity.

## Verification and acceptance

- Duplicate queued jobs produce one provider POST; pending rows recover from lost
  enqueue. Disabling account/destination after enqueue prevents HTTP. Terminal
  states stay held. Preparation failure is visible and not polled indefinitely;
  explicit corrected preview rearms only never-attempted rows.
- Readback slots survive restart/duplicate jobs, stop after three reservations,
  preserve accepted versus confirmed, and never POST. Test missing match, page
  cap, provider error, crash after reservation and concurrent erasure.
- An ordinary website paid order resolves one existing exact customer contact
  with no conversation, then delivers one frozen Klaviyo paid event. No Meta
  Purchase, new contact/profile, consent write or chat-assisted count appears.
- Missing/duplicate/wrong-account IDs and contradictory attribution stay held.
  Integer/string stored IDs compare consistently. Late contact creation links
  the same paid event; late verified conversation attribution to that same contact
  attaches once. A changed contact binding cannot redirect a prepared delivery.
- Customer erasure before contact sync, after unpaid state creation, after paid
  linkage and during attachment cannot resurrect identity. Exercise the actual
  no-conversation destruction branch and signed customer webhook, not only the
  privacy helper. Deliver a signed `customers/redact` with `orders_to_redact`
  before the first order read/contact sync, both with an empty pending financial
  row and with no financial row. Run the queued reconciliation and a later order
  notification; assert no Shopify read, contact attachment or positive event.
  Wrong-account/shop and malformed order IDs cannot create unrelated tombstones.
  Preserve downstream erasure markers during readback failures.
- Run focused new job/service/request/report specs plus existing financial,
  delivery, profile-binding and Shopify privacy tests on the isolated test DB;
  run targeted RuboCop and migration/autoload checks. No live calls in tests.

Local completion supplies an unattended, disabled-by-default delivery path and
website paid-customer coverage. Production enablement/provider receipts and
Sales approval of automatic classification remain separate acceptance evidence.
