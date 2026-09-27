# Funnel / Shumabit implementation checkpoint

2026-09-27. Worktree `funnel-shumabit-observer`, based on verified local `umi`
`6fa24dd2887639ef746d1c6af996ca9bbd7ff80c`. The older `crm` checkout and its
uncommitted planning files were preserved. No provider session was resumed.

## Priority: first messaging campaign

The user reconfirmed campaign readiness as the main first goal. Prioritize U1
live campaign/channel inventory, useful qualification, confirmed paid outcomes
and eligible Meta feedback. The Shumabit private-note bridge remains approved
supporting work; it must not become a prerequisite for launching the pilot. Use
existing Shumabit analysis jobs and human qualification where sufficient. Launch
readiness and optimization-feedback readiness must be reported separately.
The [live integration inventory](UMI-FUNNEL-INTEGRATION-INVENTORY.md) records
Meta campaign setup, matching Chatwoot inbox, labels and current automation.

## Complete locally: recovered-message provenance

The first U2 prerequisite from the
[CRM funnel plan](/Users/ivanshumkov/Projects/shumkov/chatwoot.crm/docs/plans/2026-09-27-1325-feat-funnel-messaging-integration-plan.md)
is implemented under the
[source provenance spec](UMI-FUNNEL-SOURCE-PROVENANCE-SPEC.md).

Both FB and IG now store `umi_recovered` and original `external_created_at`
before Message creation listeners run. Recovery-time thread ordering remains
unchanged. A late-arriving live message is not relabeled by the healer.
No schema migration, model call or external activation was needed.

Two independent spec reviews and two independent code reviews found no remaining
must-fixes after incorporating field reuse and precise authority wording.
The final small helper extraction and extra live-ingestion test were re-reviewed.

Verification on isolated local PostgreSQL database
`chatwoot_funnel_observer_test_20260927` and a dedicated ephemeral Redis process:

- Before fix: 8 examples, 2 failures. Both actual creation callbacks lacked the
  marker and original time. Existing tests passed.
- Same tests after fix: 8 examples, no failures.
- Final expanded suite: 97 examples, no failures or skipped examples.
- RuboCop: all 6 touched Ruby files pass. `git diff --check` passes.
- Existing Rails/reline deprecation warnings remain; no dependency changes made.

Expanded test selection:

```text
spec/services/umi/fbig/message_heal_service_spec.rb
spec/builders/umi/fbig_recovery_provenance_spec.rb
spec/services/umi/fbig/conversation_recon_service_spec.rb
spec/builders/umi/fbig_ad_attribution_spec.rb
spec/builders/messages/facebook/message_builder_spec.rb
spec/builders/messages/instagram
```

Local logs and machine-readable execution receipt live in ignored `.codex/`.
The patch is committed as `38f247854` and undeployed. No live-provider behavior was tested.

## Complete locally: paid-order reconciliation

The [paid-report spec](UMI-FUNNEL-PAID-REPORT-SPEC.md) is implemented as
`Umi::Shopify::PaidOrderReport` and `umi:funnel:paid_orders`. It reuses the current
Shopify integration to inspect 1–50 explicitly selected orders and their actual
transactions. It separates reservations, deposits, paid sales and refunds, uses
the current kept basket, and reports existing verified conversation attribution.
It creates no attribution, events, customer messages or database records.

Verification completed on 2026-09-27:

- 91 examples, zero failures, no skipped examples: new service/task plus existing
  Shopify client and order-attribution tests. Four Ruby files pass RuboCop;
  `git diff --check` passes. Existing framework deprecation warnings remain.
- Independent financial and runtime/simplicity code reviews returned CLEAN after
  correcting contradictory refund/cancellation classification. Three regression
  examples failed before that correction and passed afterward.
- A transient Rails runner executed the reviewed service against the two
  previously inspected live orders, using read-only Shopify GETs and a read-only
  database session. The fitting reservation was `no_sale` (฿7,980 original,
  ฿0 captured); pickup was `paid` (฿4,491 captured on 25 August Bangkok time,
  eighteen days after reservation). Neither row required review. Sanitized
  evidence is in ignored `.codex/paid-report-live-smoke.log`.

This is a current reconciliation snapshot, not historical conversion tracking.
The report is committed as `fb57c8887` and undeployed; the transient live check did
not install the rake task or change the running application. The durable paid
event and provider adapters are now implemented locally, as recorded below.

## Next integration boundary

The historical `feat/shumabit` research contains investigation, not a working
Chatwoot integration. Current Polygram/Water ingress is channel-specific and
must not be used as a Chatwoot analysis endpoint. Normal Chatwoot bot credentials
also allow public messages/status changes, so they cannot enforce a private-only
assistant contract.

The [bridge proposal](UMI-SHUMABIT-OBSERVER-SPEC.md) was simplified on the user's
explicit direction: reuse the existing Shumabit workspace, memory, skills,
CLIProxy/model route and Orchestra sessions. A small Chatwoot worker maps each
conversation to its own resumable session and returns private notes. The earlier
stateless, tool-free service design is superseded. The resumable private-note bridge and its runtime configuration are now
implemented and reviewed in the separate Shumabit and infra worktrees. The dedicated worker is installed and active. Its host/container health, HTTPS
route and persisted webhook registration pass; see the current
[readiness record](UMI-FUNNEL-SYSTEM-READINESS.md). The worker does not automatically classify or send public
customer replies; it analyzes and drafts when staff invokes it.

## Campaign readiness follow-up

Read-only inventory now confirms Page-linked UMI dataset `1540380063308828`
and granted Messenger `page_events`. The inspected token lacks Instagram
`instagram_manage_events`; the Instagram dataset GET returns that specific 403.
No conversion event has been submitted and optimization-goal availability is
still unverified.

The live buyer segments use Placed Order, and five of the latest 100 event
snapshots were pending payment. Preserve current reservation-suppression filters
while introducing paid-only buyer semantics; do not globally replace them.
No order-attribution rows exist; the live storefront contains the carrier and
recent `orders/create` callbacks are arriving, but end-to-end attribution still
needs a controlled checkout. No current rewrite bug is established by historical
outbound messages.

[The pilot operating contract](UMI-FUNNEL-PILOT-CONTRACT.md) prepares the initial
human-operated campaign: exact existing assets, qualification/payment procedure,
draft replies, prelaunch tests and separate launch/feedback readiness. Independent
simplicity and feasibility/domain reviews both returned CLEAN; they reviewed
the documents and plan, not the live APIs independently. The draft reply pack
has not been installed or sent. No new application code or runtime change was
made in this follow-up; the previously verified provenance patch is preserved.

The user clarified that Linh owns the campaign offer, creative, targeting, budget
and dates. These choices do not block engineering. This task prepares the system;
it does not create ads or spend. Provider tests and a staff-only Shumabit canary
remain distinct production acceptance checks.

The final bounded commerce comparison succeeded: a TBYB order appears in
Klaviyo Placed Order at ฿7,980 but is voided with no successful sale; a pickup
order appears at reservation time but was paid 18 days later. This is direct
cross-system evidence for separating paid outcomes from the native creation
metric. Native Meta Purchase emission for either example remains unverified.


## Durable core and delivery completed locally

- `553cd54c9`: immutable conversation evidence, operator qualification, protected
  status projection, financial webhook reconciliation and current cash/refund
  state. Recovery is bounded, and contact/shop erasure removes retained identity.
- `680a26e6e` and `3c3614023`: Meta/Klaviyo clients, verified existing-profile
  binding, frozen payloads, one-attempt sends, readback and operator rake commands.
  Missing identity stays pending; ambiguous attempts are held, never replayed.
- Parent integration verification: **213 examples, zero failures or skips**,
  covering new features plus existing Shopify attribution/contact matching and
  recovery provenance. **32 Ruby/rake files pass RuboCop**; diff whitespace passes.
  Existing framework deprecation warnings remain. Local Husky launcher is absent;
  Ruby checks ran directly and signed commits preserved normal signing.
- Review regressions were demonstrated failing before fixes: commerce status
  overwrite, unbounded financial recovery, shop erasure after customer redaction,
  and an erasure marker lost during provider readback. Independent reviewers
  cleared the corrected core and delivery code.

Provider receipt tests use HTTP fakes; real Meta/Klaviyo writes remain untested.
Shopify paid snapshots preserve original conversion amount/time while later
refunds update current cash. Website-only paid identities now use exact Shopify-customer linkage independent
of conversation attribution. Scheduled provider processing and cohort reporting
are complete locally, as recorded below.

The Shumabit runtime implementation passed 20 Node and 8 infra tests, Ansible
syntax and a read-only Caddy adaptation check. Two independent code reviews
returned CLEAN. The dedicated worker was subsequently installed and started. A narrow firewall
fix resolved the initial HTTPS failure, and webhook registration now passes.
No inference or test note has been sent.


## Final application integration checkpoint

- `d1c6ad455`: staff confirms qualification through the existing Sales status
  dropdown. Unrelated edits cannot promote stale status; rejected changes show
  the error and preserve the authoritative state.
- `c0bcfb7ba`: bounded conversation-cohort reporting separates mature outcomes,
  original paid revenue, current refunds and missing attribution. Unknown spend
  and ROAS remain explicitly unavailable.
- `26e15f2ae`: scheduled delivery/readback, exact website-order customer linking,
  conflict holds and signed pre-read erasure tombstones. Two independent final
  code reviews returned CLEAN.
- Final parent runs: **312 Ruby examples, zero failures or skips; 68 frontend
  tests passed; 57 Ruby/rake files and the changed frontend files lint clean**.
  The regression suite covers concurrent hold preservation and refusal to send
  paid events while financial identity conflicts remain. Logs are in ignored
  `.codex/funnel-final-*.log` and `.codex/funnel-sidebar-*.log`.

Application source is ready for release review. The production Chatwoot image,
schema, financial webhook subscriptions and provider exports are unchanged.
Live provider receipt/attribution evidence and a controlled checkout remain open.
Shumabit is a separate active deployment with verified host/container health,
HTTPS routing and webhook registration. Its private-note/model canary awaits
an agreed test conversation; the existing six service owners were unchanged.


## Release-check follow-up

The first full GitHub run exposed two unchanged base-branch lint offenses and
two inherited test failures. The lint corrections preserve runtime behavior:
the WhatsApp regression file now matches its described class, and the LINE
job keeps its persisted keyword signature with a narrow lint exemption.

The WhatsApp calling example is Enterprise-only, matching the implementation's
provider overlay. Its corrected scope was checked explicitly: Community went
from 24 examples / one missing-method failure to 23 passing examples, with one
intentional edition exclusion; Enterprise ran all 24 successfully. This does
not replace the focused funnel verification recorded above.

Shumabit application and infrastructure changes are published separately in
[worker PR 16](https://github.com/shumkov/shumabit-claude/pull/16) and
[infra PR 88](https://github.com/shumkov/umi-vps-infra/pull/88). The infrastructure
head passed 27 contract tests, syntax verification and live transport readback.
