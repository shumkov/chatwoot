# UMI LINE dual consumer

## Problem

The LINE Official Account uses one LINE channel (Channel ID `2010611374`) and one
LINE webhook URL. Chatwoot's `Channel::Line` inbox named `LINE` is the customer
conversation system of record and must continue receiving inbound events. Lumo
(`LITTLE HELP CONNECT`) also needs LINE events for marketing identity, consent,
and delivery processing, but its setup normally asks for its own webhook URL.

The LINE webhook must remain pointed at Chatwoot:

```text
POST /webhooks/line/2010611374
  -> Webhooks::LineController#process_payload
  -> Webhooks::LineEventsJob
```

The current controller already captures `request.raw_post` and the original
`X-Line-Signature` header before enqueueing Chatwoot's asynchronous job. The
route is defined in `config/routes.rb`; the controller is
`app/controllers/webhooks/line_controller.rb`.

Research basis: LINE's [signature guidance](https://developers.line.biz/en/docs/messaging-api/verify-webhook-signature/)
requires the unchanged received body and signature for HMAC verification and
LINE's [receiving-messages guidance](https://developers.line.biz/en/docs/messaging-api/receiving-messages/)
recommends asynchronous processing while documenting that webhook redelivery
is disabled by default. Rails' [Active Job retry guidance](https://guides.rubyonrails.org/active_job_basics.html)
supports a job-local `retry_on` policy, which is used below instead of making
the inbound Chatwoot job depend on Lumo.

## Decision

Use candidate A: forward from Chatwoot after its existing LINE signature and
channel lookup checks succeed.

The patch adds a rebase-safe prepend to `Webhooks::LineEventsJob`. The prepend
uses the job's existing `valid_event_payload?` and `valid_post_body?` checks,
then enqueues a separate `Umi::Line::ForwardEventsJob` with the raw body, the
original signature, and the channel ID. The original Chatwoot job then runs
unchanged. The separate job POSTs the exact body to Lumo with the original
`X-Line-Signature` and `Content-Type: application/json`.

This keeps LINE's live endpoint and Chatwoot's 200 response path unchanged. A
Lumo enqueue or HTTP failure is logged and isolated; it cannot make Chatwoot
skip inbound processing. The Lumo job has its own retry policy and emits a
grep-able final failure line because production has no Sentry DSN and the
Sidekiq dead set is not watched.

Candidate A is also the only available design whose new failure domain starts
after Chatwoot has already returned LINE's 200 response. B and C put new work
in front of that response; D is not currently actionable.

Configuration is deliberately off unless both values are present:

```text
UMI_LINE_DUAL_CONSUMER_ENABLED=false   # default; explicit kill switch
UMI_LINE_LUMO_WEBHOOK_URL=             # unset/blank means unconfigured
UMI_LINE_DUAL_CONSUMER_CHANNEL_ID=     # set to 2010611374 for this patch
```

The exact string `true` enables the feature; other values are disabled. Both
the enqueue gate and the forward job read the flag, URL, and target channel ID
from ENV at call time, not at boot and not from serialized job arguments. The
initializer emits one secret-free boot line with only `enabled=<bool>`,
`url_present=<bool>`, and `target_channel_present=<bool>`; the Sidekiq container
is the functionally authoritative process for all three reads.

The forwarder is intentionally scoped to the one production channel:
`UMI_LINE_DUAL_CONSUMER_CHANNEL_ID` must equal `2010611374`. Valid events from
other Chatwoot LINE inboxes continue through Chatwoot but are never sent to
Lumo.

When enabled in production, the URL must be HTTPS and must be present in both
the Rails and Sidekiq container environments. No channel secret, Lumo token,
or endpoint credential is stored in the image or this repository. This patch
does not mint or rotate any LINE token and does not regenerate the channel
secret.

### Implementation seam

`config/initializers/zz_umi_line_dual_consumer.rb` prepends
`Umi::Line::LineEventsJobForwarding` to `Webhooks::LineEventsJob` in
`Rails.application.reloader.to_prepare`. Its `perform(params:, signature:,
post_body:)` wrapper sets the same `@params` value as the upstream job, calls
the upstream private `valid_event_payload?` and `valid_post_body?` methods, and
enqueues `Umi::Line::ForwardEventsJob` only when both return true. It then calls
`super` regardless of forwarding enqueue success, so Chatwoot's own processing
always follows the existing code path. A forward enqueue exception is rescued,
logged as `stage=enqueue_failed`, and not re-raised.

The initializer fails loudly if the depended-on private methods or the upstream
`perform` keyword parameters disappear during an upstream rebase. This keeps
the patch safe to remove or repair instead of silently disabling the consumer.

The prepend's entire pre-`super` block is inside an exception boundary. Any
forwarding/configuration error is reduced to its class and logged, then
`super` still runs. The forward enqueue intentionally occurs before `super`,
making delivery at-least-once and making Lumo-side `webhookEventId`
deduplication mandatory.

The forward job lives at
`umi/app/jobs/line/forward_events_job.rb`; the forwarding module lives at
`umi/app/services/line/line_events_job_forwarding.rb`. The overlay wiring in
`config/application.rb` maps these to `Umi::Line::ForwardEventsJob` and
`Umi::Line::LineEventsJobForwarding`.

`Umi::Line::ForwardEventsJob` uses the repository's existing `SsrfFilter`
transport (the same SSRF-safe dependency used by `SafeFetch`) with default TLS
verification. It POSTs with a 5-second open timeout and 10-second read timeout,
does not follow redirects, and treats 3xx responses as permanent failures.
The job rejects non-HTTPS URLs in code. Only 2xx is success. Network errors, timeouts, 429, and 5xx
raise a forwarding error and use `retry_on` with five attempts and polynomial
backoff on the `low` queue. Other 4xx responses are logged as permanent
`forward_failed` outcomes without retrying. Retry exhaustion uses the `retry_on`
block to log and discard the job rather than re-raising into the global Sidekiq
retry/dead-set path. The job re-checks the enable flag and URL before executing,
so disabling the flag stops both new and already-queued forwards.

## Why the alternatives were rejected

### B. Relay in front: LINE → n8n → Chatwoot + Lumo

Rejected for this rollout. It puts a new single point of failure in front of
the customer inbox. LINE webhook redelivery is disabled by default, so an n8n
or network outage before Chatwoot would lose inbound messages permanently.
Existing n8n workflows are out of scope and must not be changed for this
patch. A relay may be reconsidered only with durable buffering, explicit
deduplication, and an operational owner.

### C. Caddy edge duplication

Rejected. Standard Caddy reverse proxying selects an upstream for a request; it
does not provide a durable, response-independent request mirror to a second
HTTP upstream. Adding a custom handler/plugin would create another component at
the most failure-sensitive point and would still need buffering, retry, and
signature-preserving semantics. It is not a smaller version of candidate A.

### D. LINE module channel

Recorded as the future native upgrade path, not an action for this patch. LINE
module channels can receive events alongside a primary channel, but Lumo's
documented setup does not establish that it supports attachment as a module
channel. UMI cannot enable or validate that relationship unilaterally.

Lumo's documented no-webhook setup and its form / LINE Login / email-link
identity binding are the supported interim product path while this forwarder
is enabled.

## Data flow

```text
LINE Platform
  │ POST /webhooks/line/2010611374
  │ raw body + X-Line-Signature
  ▼
Chatwoot Webhooks::LineController
  │ enqueue Webhooks::LineEventsJob; return 200
  ▼
Webhooks::LineEventsJob
  │ existing channel lookup + HMAC-SHA256 validation
  ├── invalid/unknown channel ──> no forward; existing Chatwoot behaviour
  └── valid
       ├── enqueue Umi::Line::ForwardEventsJob
       │     └── POST exact raw body + original signature → Lumo
       └── run existing Line::IncomingMessageService
```

The forward job must not parse, re-serialize, normalize, transcode, or log the
body. It may set the content type and a neutral user agent. Lumo is expected to
dedupe by LINE `webhookEventId` if it receives a duplicate caused by retries or
LINE redelivery; the rollout smoke test records whether that expectation holds.

## Failure modes and observability

| Failure | Chatwoot inbound path | Lumo path | Human signal / action |
|---|---|---|---|
| Feature disabled or URL blank | unchanged | no job is enqueued | none; expected state |
| Unknown channel or invalid LINE signature | unchanged | no job is enqueued | existing Chatwoot/LINE validation signals |
| Redis/enqueue error for forward job | continues processing | event is not forwarded | `[umi-line-dual] stage=enqueue_failed`; alert on this log line |
| Lumo timeout, network error, or non-2xx | continues processing | forward job retries with its declared policy | warning/error summary; alert on final `stage=forward_failed` |
| Chatwoot inbound job retries after `IncomingMessageService` raises | continues its existing retry behavior | the same event may be forwarded more than once before Lumo deduplication | treat as at-least-once; assess Lumo `webhookEventId` behavior in the smoke test |
| Lumo accepts event but later processing fails | unchanged | outside Chatwoot control | use Lumo's delivery/processing dashboard |
| Rails or Sidekiq environment differs | unchanged | may silently be disabled in one process | rollout checklist must verify both containers |
| Duplicate delivery | Chatwoot's existing behaviour | Lumo should dedupe by webhook event ID, but this is unverified | record the observed behavior and disable if duplicate state is unsafe |

The forward job declares its own retry policy rather than relying on the global
Sidekiq retry setting (3). Every failed attempt has a compact log line without
body text, signature, channel secret, or token. After retries are exhausted,
the final `[umi-line-dual] stage=forward_failed` line is the human alert signal;
configure the VPS log monitor to alert on that prefix. Because `SENTRY_DSN` is
intentionally empty, no exception tracker is assumed.

The forwarder does not use `Rails.cache` for coordination or delivery state.
There is no cross-container state in this patch; Sidekiq/Redis is the delivery
queue. If durable replay or an outbox is required later, it must use Redis or a
database-backed design rather than the per-container FileStore.

The raw body and signature are necessarily present in the forward job's Redis
arguments while it is queued or retrying. This is an additional copy of data
the existing Chatwoot LINE job already stores in Redis, so Sidekiq/Redis access
is customer-message access. Retry exhaustion discards the forward job instead
of leaving a body-bearing entry in the unwatched dead set.

### Log-stage contract

The `[umi-line-dual]` prefix is an operational interface:

| Stage | Meaning | Alert |
|---|---|---|
| `forward_enqueued` | Valid event was placed on the Lumo queue | no |
| `forward_success` | Lumo returned 2xx | no |
| `forward_retry` | Retryable network/429/5xx failure | no, unless sustained |
| `enqueue_failed` | The Lumo job could not be enqueued | yes |
| `forward_failed` | Permanent 4xx/3xx or retry exhaustion | yes |
| `config_invalid` | Enabled feature has an invalid URL/scheme | yes |

Every line contains only the channel ID, HTTP status when available, and error
class/attempt count; never an exception message, response body, body, signature,
secret, token, or endpoint URL.

## Security

- Chatwoot remains the first signature verifier. The HMAC uses the existing
  `Channel::Line#line_channel_secret`; it is never sent to Lumo or written to
  logs.
- The forwarded `X-Line-Signature` is copied byte-for-byte. The body is copied
  byte-for-byte. LINE's signature rules make parsing or changing either value
  unsafe.
- Lumo's handling of `X-Line-Signature` is an empirical rollout question in this
  engagement; no Lumo support confirmation is available. The smoke test must
  record whether Lumo accepts the signature and creates the required state. If
  it does not, disable the forwarder; Chatwoot remains unaffected by design.
- The Lumo URL is deployment configuration and is never included in logs.
  Production rollout must use HTTPS and validate the host before enabling it.
- LINE signatures contain no timestamp or nonce, so replay resistance is not
  provided by the protocol. TLS plus Lumo `webhookEventId` deduplication is the
  required posture; this is inherited from LINE rather than added by UMI.
- The body can contain customer message content and identifiers. Sending it to
  Lumo is the requested product behaviour; access to the Lumo account and
  endpoint must be limited to the people who operate this channel.
- No LINE channel token is reissued. The long-lived Chatwoot token and Lumo's
  separately minted token remain independent. The channel secret must not be
  regenerated.
- The job does not accept an arbitrary destination from the webhook payload;
  its destination comes only from the deployment environment.
- The inherited upstream signature comparison currently uses `==`; the patch
  does not fork that core validation method. If validation is ever reimplemented
  in the overlay, it must use a constant-time comparison.

## Verification plan

Focused automated specs will prove:

1. A full request-to-job chain using Thai text and emoji forwards a body whose
   bytes equal the original request bytes, and whose canonical outbound
   `X-Line-Signature` equals the original header and recomputes correctly from
   the existing channel secret.
2. The Lumo HTTP request has exactly that body and signature, with no redirect
   follow.
3. An exception while enqueueing/forwarding does not prevent
   `Line::IncomingMessageService` from processing the event.
4. The explicit kill switch prevents forwarding even when a URL is configured.
5. Missing URL or disabled configuration enqueues nothing.
6. A valid event for another LINE channel does not forward.
7. Invalid signature and unknown channel do not forward.
8. A queued forward job becomes a no-op after the kill switch is disabled.
9. Failure logs contain no URL, response body, exception message, body, or
   signature.
10. The initializer wires the forwarding module into
   `Webhooks::LineEventsJob`; the existing upstream LINE specs remain green
   with the default disabled configuration.

The existing Chatwoot job can retry after a downstream processing exception.
Because the Lumo enqueue happens before `super`, that can produce duplicate
Lumo deliveries even when LINE itself does not redeliver. Lumo webhook-event-ID
deduplication is therefore an important empirical rollout check, not a vendor
confirmation gate; the duplicate test in step 10 should cover both this case
and a LINE redelivery when a safe replay path exists.

Manual verification must send a real test LINE message after rollout, confirm
the Chatwoot `LINE` inbox receives it, confirm the Lumo delivery/identity event
is visible, and inspect the Rails and Sidekiq logs for the success/failure
summary. Test Lumo's duplicate handling with one controlled redelivery before
depending on webhook redelivery. LINE webhook redelivery is disabled by default;
if it is enabled by a human operator, the runbook must treat duplicates as
expected rather than as a successful exactly-once guarantee.

## Rollout runbook

These steps are written for a human operator with access to `umi-vps` and the
Lumo account. This change does not itself touch the LINE Developers Console,
LINE Official Account Manager, n8n, or the VPS.

### Prepare

1. Confirm the LINE Developers Console still points channel `2010611374` to
   `https://<Chatwoot-host>/webhooks/line/2010611374`. Do not change the URL,
   reissue a channel access token, or regenerate the channel secret.
2. Confirm the Chatwoot inbox named `LINE` is the `Channel::Line` inbox for
   channel `2010611374`.
3. In Lumo, create/complete the channel setup using the existing Channel ID and
   Channel Secret as required by Lumo, but choose its documented no-webhook
   completion path. Do not paste Lumo's URL into the LINE console. Do not
   regenerate the channel secret. Complete identity binding through the Lumo
   form, LINE Login, or email-link path as applicable.
4. Confirm the new Chatwoot image is available. Roll it out with the feature
   disabled (`UMI_LINE_DUAL_CONSUMER_ENABLED=false`), no Lumo URL, and
   `UMI_LINE_DUAL_CONSUMER_CHANNEL_ID=2010611374` first.
   Restart/recreate both `umi-chatwoot-rails-1` and `umi-chatwoot-sidekiq-1`
   using the existing `umi-vps-infra` Chatwoot deployment procedure.
5. Check the Sidekiq container has the disabled configuration (the Sidekiq
   environment is functionally load-bearing; Rails parity is still recommended
   for deployment consistency), then send one test LINE message. Verify
   Chatwoot receives it and no
   `[umi-line-dual] stage=forward_enqueued` line appears.

### Enable

6. Add the Lumo endpoint URL and
   `UMI_LINE_DUAL_CONSUMER_CHANNEL_ID=2010611374` to the Chatwoot Rails and
   Sidekiq environment but keep `UMI_LINE_DUAL_CONSUMER_ENABLED=false` for
   staging verification. Use the endpoint supplied by Lumo; do not put a
   secret in this repository. Keep the URL HTTPS.
7. Restart/recreate both Chatwoot containers so the environment is identical in
   Rails web processes and Sidekiq workers. Verify the Sidekiq values without
   printing the URL or any secret (for example, check only that the enabled flag
   is false and the URL is present).
8. Send a test message from a LINE account. PASS requires: Chatwoot creates the
   inbound message in the `LINE` inbox; no Lumo request is made while disabled;
   and the boot line reports only the enabled/url-present/target-channel
   booleans.
9. Perform the empirical Lumo smoke test with the kill switch enabled: send one
   real message to the LINE Official Account, then inspect Lumo. Success means
   the event is visible in Lumo's delivery view and the expected LINE identity,
   consent, and delivery state is populated. Record the result; this test is
   intentionally safe because Chatwoot processing is already independent.
   - No Lumo event / rejected request: conclude the endpoint, signature, or
     payload contract is unsupported; disable the forwarder and continue using
     Lumo's form/LINE Login/email-link identity paths.
   - Event exists but identity/consent is missing: conclude the payload is
     accepted but Lumo mapping is incomplete; disable the forwarder unless the
     product owner explicitly accepts delivery-only behavior.
   - Event and required state exist: record the observed success and continue
     monitoring. Do not infer exactly-once delivery.
10. Exercise a controlled duplicate in staging if Lumo exposes a safe replay
    path, and exercise the Chatwoot-job-retry path. Record whether Lumo
    deduplicates; if it does not, disable the forwarder because duplicate
    identity/consent state is unsafe. Do not enable LINE webhook redelivery
    until this behavior is understood.
11. Configure the VPS log monitor to alert on
   `\[umi-line-dual\] stage=(enqueue_failed|forward_failed|config_invalid)` and
   force one test line before enabling production forwarding. If this alert
   cannot be configured, stop rollout; the feature has no human-visible loss
   signal in the current no-Sentry environment.
12. Set `UMI_LINE_DUAL_CONSUMER_ENABLED=true` in the shared environment and
   restart/recreate both Chatwoot containers. Verify the Sidekiq boot line shows
   `enabled=true url_present=true target_channel_present=true` without printing
   the URL.
13. Send a test message from a LINE account. PASS requires: Chatwoot creates the
   inbound message in the `LINE` inbox; the Lumo delivery/marketing view shows
   the corresponding event; and logs show `forward_enqueued` followed by
   `forward_success`, with no body or signature. Monitor `[umi-line-dual]` and
   Lumo delivery errors for the first production traffic window. Do not treat
   the absence of an error line as proof that Lumo's downstream processing
   succeeded.

### Roll back in under one minute

14. If Chatwoot inbound delivery breaks or Lumo causes operational trouble, set
    `UMI_LINE_DUAL_CONSUMER_ENABLED=false` in the shared Chatwoot environment
    and immediately recreate/restart the Sidekiq container (and Rails for env
    parity) with the existing production Compose command. Sidekiq is the
    effective control point because both gates read ENV at job call time. The
    endpoint remains unchanged, so no LINE console action is needed. A fresh
    Sidekiq process will stop enqueueing and executing forward jobs while
    Chatwoot continues to consume LINE events.
15. Send one test LINE message and verify it appears in Chatwoot. Leave the Lumo
    URL in place but disabled until the cause is understood; remove it later if
    desired. If restarting both containers cannot complete within the local
    one-minute operational target, use the existing VPS emergency rollback
    procedure to restore the previous Chatwoot image/env as a single operation.

### What this worktree cannot verify

- The real Lumo endpoint, credentials, response contract, delivery dashboard,
  and duplicate semantics cannot be verified without Lumo credentials.
- Production container env parity, deployment time, log shipping, and alert
  latency cannot be verified without access to `umi-vps` and `umi-vps-infra`.
- The LINE console URL, token state, channel secret state, and real webhook
  delivery cannot be checked here because console changes and production access
  are explicitly out of scope.
- Whether Lumo supports LINE module-channel attachment is not established by
  its documented setup; its owner must confirm that separately.

## `umi-vps-infra` documentation block

The following block is suitable for the infrastructure repository's Chatwoot
service documentation; it is intentionally included here only and is not an
edit to that repository:

```markdown
### LINE dual consumer (Chatwoot + Lumo)

LINE continues to deliver to Chatwoot at
`/webhooks/line/2010611374`. After Chatwoot validates the LINE signature, its
Sidekiq job forwards the unchanged body and `X-Line-Signature` to Lumo. Lumo is
configured through its no-webhook setup path; its webhook URL must not replace
the LINE console URL.

Set these variables identically for the Rails and Sidekiq Chatwoot containers:

- `UMI_LINE_DUAL_CONSUMER_ENABLED` — `false`/unset by default; set `true` only
  after Lumo setup and endpoint verification.
- `UMI_LINE_LUMO_WEBHOOK_URL` — the HTTPS endpoint supplied by Lumo; unset when
  the feature is not in use.
- `UMI_LINE_DUAL_CONSUMER_CHANNEL_ID` — set to `2010611374`; other valid LINE
  channels are never forwarded by this patch.

Alert on `[umi-line-dual] stage=enqueue_failed` and final
`[umi-line-dual] stage=forward_failed` lines. The feature can be rolled back by
setting the enable flag to `false` and restarting/recreating the Rails and
Sidekiq containers; the LINE console URL is unchanged.
```

## Files and patch registry

The implementation is intentionally limited to the UMI overlay, one
rebase-guarded initializer, focused specs, this document, and one row in
`UMI-PATCHES.md`:

- `config/initializers/zz_umi_line_dual_consumer.rb`
- `umi/app/jobs/line/forward_events_job.rb`
- `umi/app/services/line/dual_consumer.rb`
- `umi/app/services/line/line_events_job_forwarding.rb`
- `spec/controllers/webhooks/line_controller_spec.rb` (extended)
- `spec/jobs/webhooks/line_events_job_spec.rb` (extended)
- `spec/jobs/umi/line/forward_events_job_spec.rb`
- `docs/UMI-LINE-DUAL-CONSUMER-SPEC.md`
- `UMI-PATCHES.md` (new patch row)

No OSS controller/job, Enterprise overlay, routes, migrations, n8n workflow,
VPS configuration, or LINE console setting is changed.

## Remove-when

Remove this patch when Lumo supports LINE module-channel attachment for this
channel, or when Lumo/UMI provides a supported native dual-consumer mechanism
that makes forwarding from Chatwoot unnecessary. Re-check whether upstream
Chatwoot or LINE adds a supported fan-out mechanism during each upstream rebase.
