# Automatic recent conversation audience — narrow proposal

Status: reviewed for implementation; no application changes made.
Base: chatwoot crm-stage-closure d3342a8c76b557b7e9283ff6f4eb03708e3653f2.

## Problem and scope

A real qualified conversation automatically becomes a Klaviyo event once an exact existing profile is available. Its provider readback can become confirmed, but nothing automatically creates the agreed UMI - Recent conversation intent audience afterward. The current infra segment helper requires a later manual CLI invocation. Finish that last development/config step now; actual first eligible event remains a natural production observation.

Create one native segment, after genuine confirmed qualification, with the existing rule: at least one UMI Conversation Qualified API metric event in the last 30 days. Buyers and repeat buyers may belong. No profile property, contact label, customer consent, campaign or sending flow changes. No fabricated event, historic replay, alternative identity matching, new service or cron schedule.

## Chosen existing path

Extend `umi/app/jobs/funnel/segment_refresh_job.rb` inside its existing account mutex. The existing five-minute reconciler schedules this job via ProfileSyncJob.enqueue_due. Retain current Chooser/Seeker refresh logic, publication and cadence. After successful normal refresh, run bounded recent-intent provisioning using the same Klaviyo client and already-read metric list. Optional provisioning failures update their own state and do not turn healthy Chooser/Seeker membership stale. Existing mutex lock timeout remains unchanged.

`validate_segments!` will accept or return the metric list rather than issue a second metrics GET. Reuse `activity_condition(metric_id)` for the exact 30-day condition; wrap it in one condition group. No shared framework or general segment reconciler.

Keep provisioning state in one nested `recent_intent` object within existing `account.custom_attributes.umi_segment_refresh`. Store only status, segment_id when known, metric_id, create_attempted_at when claimed, checked_at, next_check_at, and last_error as short error class/HTTP status. Do not store profiles, event bodies or secrets. Current `record_status` merges outer fields, so normal membership success does not erase recent-intent metadata.

### Eligibility

Before any create attempt require:

- The existing job's configured Klaviyo account/customer-context checks, plus funnel account enabled and Klaviyo export enabled.
- At least one account-scoped conversation_qualified delivery with destination=klaviyo, state=confirmed, non-null confirmed_at/provider_reference, and a nonredacted event. Event provenance is operator or classifier and its original occurred_at is within the collection boundary and not in the future. Merely accepted, paid-only, historic/recovered or other-account events do not qualify.
- Exactly one API metric named UMI Conversation Qualified from the complete current metrics read. Missing metric means awaiting_metric; duplicate names are an explicit error.

Before first qualification, status awaiting_qualification makes the unfulfilled business prerequisite visible. Zero provider create calls. Once provisioned, validate the saved segment by GET on later ordinary checks even if the original contact is later erased; the segment is an account-level rule, not stored personal evidence.

### Resolve, create, read back

1. With a saved segment ID, GET it and require exact name and definition. A deleted ID or changed definition is visible error, never automatic recreation/overwrite.
2. Without saved ID, fully paginate GET /segments?filter=equals(name,"UMI - Recent conversation intent") with fields name,definition. Zero matches may proceed; one exact match is adopted and independently GET-verified; duplicate names or drift stop without writes.
3. If no match exists and no prior create attempt is recorded, atomically claim the one create attempt under the existing Account row lock, re-reading nested state. Persist create_attempted_at/status creating BEFORE HTTP; release DB lock before request. The normal Redis mutex serializes jobs; this small durable claim also protects the known crash/timeout seam. No generic outbox/migration.
4. POST once, exact native definition. On HTTP201, persist returned segment_id before the GET readback. GET exact ID/name/definition; only then status ready. Creation is not readiness.
5. A failed GET retries as a GET on later ordinary ticks. A timeout, 5xx or interrupted POST leaves the durable attempted marker; later ticks only perform exact-name discovery and can adopt the eventual exact matching object. They never blindly POST again. If no object becomes discoverable, state explicitly requires operator investigation, not future code.
6. An explicit HTTP429 is known rate-limit rejection: atomically record its Retry-After due time and release the claim for a later scheduled attempt. Recheck that due time under the creation-claim lock so an already-running discovery cannot bypass it. Other explicit 4xx stays visibly rejected/held rather than looping. Correcting external access or malformed state is operational repair, not permission-system work.

A failed attempt marker is deliberately conservative if the process dies between persisting the claim and reaching the network. That very small seam may require inspection; silently duplicating an audience is worse. This is the only new persistent operation guard, because segment creation has no assumed idempotency key and duplicate audience names are allowed by the existing code's defensive contract.

After an attempt has been claimed, read-only discovery/adoption continues even
if the original qualifying customer is erased. The account-level definition
contains no customer data, and the durable claim still prevents another POST.

### Klaviyo client additions

In existing `umi/app/services/funnel/klaviyo_client.rb`:

- `segments(name:)`: use current collection/pagination helper, exact filter with JSON.generate(name), fields[segment]=name,definition. Do not request unsupported page sizes (max10).
- `create_segment(name:, definition:)`: one HTTParty POST to /api/segments, headers revision PROFILE_REVISION=2026-07-15, JSON {data:{type:'segment',attributes:{name,definition}}}, existing bounded timeouts/no_follow. Require HTTP201 with data.id; parse 429 using existing RateLimited. No transport retries. Keep create_event's HTTP202 and API_REVISION=2025-10-15 unchanged; do not globally redefine success as201.
- Reuse existing `segment(id)` GET for independent readback. Errors log only class/status, never response bodies/tokens.

Official contracts checked 5 October Bangkok: https://developers.klaviyo.com/en/reference/create_segment (segments:write,201,revision2026-07-15); https://developers.klaviyo.com/en/reference/get_segments (name equals filter,cursor pagination,max10/page). Current read-only credentials prove segments:read, not a write capability receipt; do not create a dummy audience to probe scope.

## Minimal alternative considered

Call existing Node `prepareSegments` after each hourly lifecycle sync. Advantages: reuse existing create/readback code. Rejected for this narrow contract: it checks metric existence, not Chatwoot's genuine confirmed delivery; proving that gate would add cross-service DB/API plumbing. It also couples audience creation failures to financial profile sync and reconciles five unrelated definitions. Calling only from DeliveryService.confirm is smaller in lines but strands provisioning after a transient failure once the event delivery is terminal. Existing SegmentRefreshJob has the necessary owner, periodic retry cadence and mutex already.

## Exact files

Runtime (2 existing files):
1. umi/app/jobs/funnel/segment_refresh_job.rb.
2. umi/app/services/funnel/klaviyo_client.rb.

Tests (2 existing files):
3. spec/jobs/umi/funnel/segment_refresh_job_spec.rb.
4. spec/services/umi/funnel/klaviyo_client_spec.rb.

Documentation: update stage-one spec U9 and delivery runbook to remove the future manual requirement; update matching UMI-PATCHES.md row. Retire the future manual Recent-intent step in infra readiness documentation when delivering, while preserving Node helper for explicitly requested baseline preparation. Do not schedule a second writer.

## Regression intent and delivery

First add a concrete failing job spec: confirmed genuine qualification + provider metric + no segment; ordinary job run should POST once and GET-verify native audience. It fails on current code because no creation happens. Then implement and demonstrate same test green.

Necessary focused cases:

- No qualification / accepted-only / paid-only / recovered or other-account / redacted source: no creation.
- One confirmed qualification creates the exact 30-day audience without buyer-stage filter, records returned ID, then ready only after exact readback.
- Repeat jobs, including claimed in-progress state, do not duplicate POST; existing exact audience is adopted; exact-name pagination is complete.
- Missing/duplicate metric, duplicate audience name, changed definition and deleted recorded ID hold visibly, never overwrite/recreate.
- POST succeeded but GET failed: saved ID survives; next tick performs GET only.
- POST timeout/crash marker: no second POST; eventual list discovery can finish.
- Explicit429: due time honored, no immediate retry. Non429 rejection visible.
- Provisioning error leaves current Chooser/Seeker observation and next refresh healthy.
- Client pins revision, exact request shape and201, bounded one-call behavior; existing event202/revision behavior unchanged.

Run both focused suites plus existing funnel automation/client tests. Multi-agent review actual diff, normal full CI, signed UMI release via canonical infra. Fresh production readback should show awaiting_qualification and zero create calls now, because no qualifying Klaviyo delivery exists. The first real profile-bound confirmed qualification will complete provisioning automatically; no later implementation is required. Do not call a synthetic test or pending waiting-state receipt proof of provider segment creation.

## Review receipt

Two independent source and API-contract reviews completed on 5 October, both
without must-fixes. Reviewers checked scheduler ownership, account-state merge,
the exact 30-day definition, non-idempotent POST handling, and the separate
HTTP201 creation versus HTTP202 event contracts. Actual provider write scope
and the first genuine qualification remain live acceptance observations.
