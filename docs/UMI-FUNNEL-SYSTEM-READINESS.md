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

The Shumabit bridge and runtime adapter have 20 passing Node tests and independent
reviews. It reuses the existing workspace, memory, skills and proxy route, with
separate conversation sessions and private replies. Runtime files are installed
on the VPS and the new worker is active. Host and Caddy-container health checks,
the secret HTTPS webhook route, wrong-path rejection and persisted Chatwoot
webhook registration all passed. The exact Caddy-container-to-host firewall rule
resolved the first activation's 502 without restarting any service. Existing
bots stayed unchanged. The final private-note/model canary awaits a selected
test conversation; no test messages or model calls have been sent.

Infrastructure source now supplies disabled-by-default funnel settings and the
five Shopify financial webhook topics. No Chatwoot image, migration, capture
boundary, provider export or Shopify app configuration has been deployed yet.

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

- Chatwoot application: [PR 56](https://github.com/shumkov/chatwoot/pull/56).
- Shumabit worker: [draft PR 16](https://github.com/shumkov/shumabit-claude/pull/16).
- Infrastructure: [draft PR 88](https://github.com/shumkov/umi-vps-infra/pull/88),
  with 27 passing contract tests and Ansible syntax verification.

The GitHub Linux build and full repository CI are separate from the local
focused checks above. Release readiness requires their results to be recorded;
opening a PR does not establish that the production funnel is active.
