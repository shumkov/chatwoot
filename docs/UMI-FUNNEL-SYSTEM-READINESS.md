# System readiness for Linh's messaging campaigns

The user clarified on 27 September 2026 that **Linh owns Meta campaign creation
and operation**. This engineering task prepares the supporting system. Offer,
budget, audience and campaign dates are not inputs required to finish integration
code. Do not create or change an ad campaign as part of this work.

## What the system must supply

- Chatwoot records conversation evidence and an operator-confirmed qualification,
  with single-value sales status and flat reporting/topic labels.
- Shopify remains payment authority. Reservations and deposits do not count as
  paid sales; final kept-item value and later refunds stay distinguishable.
- Klaviyo receives distinct verified qualification/paid outcomes for existing
  identified profiles, preserving its native reservation suppression and consent.
- Meta receives eligible business-messaging outcomes, with visible holds when
  identity, channel permission or delivery receipt is uncertain.
- Shumabit can analyze the conversation and suggest replies through private notes,
  using the existing workspace, business memory, skills and subscription route.
- The operator can inspect counts, money, attribution gaps and delivery failures.

## Implemented and reviewed

The Chatwoot branch includes recovered-message provenance, durable conversation
and paid-order events, the native Sales status confirmation, Meta/Klaviyo
adapters, existing-profile binding, scheduled delivery and finite receipt checks,
exact Shopify customer linking, privacy erasure, and cohort reporting.

Final local integration checks passed **312 Ruby examples and 68 frontend tests**
with zero failures or skips. All 57 changed Ruby/rake files pass RuboCop; changed
frontend files pass ESLint. Independent spec and code reviews cleared each
implementation unit, including financial identity conflicts and concurrent
preparation holds. These checks establish local behavior, not provider acceptance.

The Shumabit bridge and runtime adapter have 22 passing Node tests and independent
reviews. It reuses the existing workspace, memory, skills and proxy route, with
separate conversation sessions and private replies. Runtime files are installed
on the VPS and the new worker is active. Host and Caddy-container health checks,
the secret HTTPS webhook route, wrong-path rejection and persisted Chatwoot
webhook registration all passed. The exact Caddy-container-to-host firewall rule
resolved the first activation's 502 without restarting any service. Existing
bots stayed unchanged. Two authorized first-step canaries produced only private
failure notices. A startup-only diagnostic established that the installed CLI
does not have its Channels feature available. A small amendment using normal
CLI print/resume calls has two clean reviews and awaits user alignment before
implementation. Transport health does not establish a working assistant.

Release `umi-v4.16.0-11` is deployed from application commit
`0b06c1be04398a34662f2fdfb8172454c21e1be7`. Both migrations and all three funnel
tables are present. Collection for account 1 and the five-minute reconciliation
job were verified at `2026-09-27T16:48:21Z`; both provider exports remain disabled.
The fixed source boundary is `2026-09-27T16:33:12Z`, while the first enabled
containers started at `16:46:27Z`. That earlier interval is not proven capture coverage.
Operational and cohort reports execute successfully; their initial empty output
is not evidence of zero sales.

The natural cron tick provisioned the seven-value Sales status field. At
`17:01:19Z`, a final readback verified the disabled Meta/Klaviyo configuration,
correct destinations and equality with the existing authorized credentials in
both application containers. Their preview-configuration restart was at
`16:58:56Z`. Read-only provider checks passed; no event was prepared or posted.

Shopify version `umi-chatwoot-funnel-20260927` is active. A fresh remote
configuration pull verified API `2026-04`, all five financial topics, all three
privacy callbacks, the existing callback destination and unchanged access scopes.
No historical orders were replayed and no conversion event was sent.

## Activation and external evidence

Production rollout must use the owning infrastructure repository and existing
release process. Deployment configuration includes the account and observation
start, disabled-by-default provider delivery, and the bridge's real internal
network/credential/proxy route. No new customer marketing flow is switched on by
installing these components.

Messenger's page/dataset and page_events grant were verified in the integration
inventory. Instagram event permission is missing, so Instagram export remains
excluded until that account setting is supplied. Shopify website purchases remain
owned by their existing integration; a Chatwoot order link is not sufficient to
send another messaging Purchase. This restriction does not block using Chatwoot
or launching a normal messaging campaign.

A provider test receipt, Events Manager readback and live Shumabit follow-up are
separate acceptance evidence. They should be run with explicit test data and
recorded results. API acceptance alone does not establish Meta attribution or
which optimization goals Linh can select.


## Review artifacts

- Chatwoot application: [merged PR 56](https://github.com/shumkov/chatwoot/pull/56).
- Shumabit worker: [draft PR 16](https://github.com/shumkov/shumabit-claude/pull/16).
- Infrastructure: [merged PR 88](https://github.com/shumkov/umi-vps-infra/pull/88),
  with contract tests, Ansible syntax checks and live receipts in its runbooks.

Full Linux CI passed: 6,710 backend examples with zero failures and 66 pending,
plus 3,786 frontend tests. The upstream-only Heroku and MFA jobs were deliberately
skipped. Release build `36332249161` succeeded; isolated image checks matched
44 runtime/schema file hashes and all 238 frontend artifacts. The owning infra
runbook records the database backup and live deployment receipts.
