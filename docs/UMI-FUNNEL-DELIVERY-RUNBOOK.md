# Funnel outcome delivery

Linh owns campaign creation and spend. This runbook operates the supporting
outcome integration. Run commands in the deployed Chatwoot application through
the owning infrastructure repository after its migration and configuration.

## Configuration

`UMI_FUNNEL_ACCOUNT_IDS=1` enables collection for the known UMI account.
`UMI_FUNNEL_STARTED_AT` is an explicit UTC ISO8601 observation boundary, set when
collection starts. Do not move it backward to export old history.

Messenger configuration uses `UMI_FUNNEL_META_ACCOUNT_ID=1`,
`UMI_FUNNEL_META_PAGE_ID=516819784857962`,
`UMI_FUNNEL_META_DATASET_ID=1540380063308828` and the secret
`UMI_FUNNEL_META_ACCESS_TOKEN`. `UMI_FUNNEL_META_ENABLED` defaults false.
For an approved Events Manager test, set `UMI_FUNNEL_META_TEST_EVENT_CODE` before
preparing its event. That code becomes part of the frozen payload; changing ENV
later does not turn the same recorded test into a production conversion.

Klaviyo uses `UMI_FUNNEL_KLAVIYO_ACCOUNT_ID=1` and the existing secret
`UMI_KLAVIYO_PRIVATE_API_KEY`, with profile-read and event-read/write access.
`UMI_FUNNEL_KLAVIYO_ENABLED` defaults false. Installing these components does not
enable a marketing flow or change consent. Configure flows consuming the new
metrics separately; preserve native Placed Order reservation suppression.

Credentials belong in runtime secret configuration, never shell history or docs.
The provider switches allow dispatch but do not bypass identity or time checks.

## Operator commands

Use actual internal record IDs. A Chatwoot conversation URL uses a display ID;
resolve the account-scoped internal ID before using `CONVERSATION_ID`.

```sh
ACCOUNT_ID=1 CONVERSATION_ID=<internal-id> ACTOR_ID=<staff-id> \
  STATUS=qualified REASON='Asked to arrange a fitting' MESSAGE_IDS=<incoming-id> \
  bundle exec rake umi:funnel:qualify

ACCOUNT_ID=1 CONTACT_ID=<contact-id> PROFILE_ID=<existing-klaviyo-id> \
  ACTOR_ID=<staff-id> REASON='Confirmed customer identity' \
  bundle exec rake umi:funnel:bind_profile

ACCOUNT_ID=1 DELIVERY_ID=<delivery-id> ACTION=preview \
  bundle exec rake umi:funnel:delivery

ACCOUNT_ID=1 DELIVERY_ID=<delivery-id> ACTION=dispatch \
  bundle exec rake umi:funnel:delivery

ACCOUNT_ID=1 DELIVERY_ID=<klaviyo-delivery-id> ACTION=readback \
  bundle exec rake umi:funnel:delivery
```

Preview stores the exact eligible payload but performs no event POST. Klaviyo
preview reads the bound existing profile to verify its identity. Output contains
IDs, destination, state, reason and attempt count, without customer identifiers.
Inspect pending delivery IDs via the account's `Umi::ConversationEvent` records
and their `conversion_deliveries`; the aggregate `umi:funnel:report` exposes
state counts and erasure obligations.

Qualification requires live incoming evidence. `engaged`, `inactive`,
`not_sales` and `unevaluated` are also supported human classifications. Commerce
owns `order_placed` and `purchased`; labels and generic sidebar edits cannot
manufacture a paid event.

## Interpret the result

- `pending`: not sent; the reason explains disabled export, missing binding or
  another unresolved prerequisite. Fix the prerequisite and preview again.
- `excluded`: not eligible for this export. Historical/recovered conversations,
  Instagram without its event permission and purchases with unresolved messaging
  origin are intentionally excluded.
- `sending`: the database claim committed. A process may still be executing it.
  Establish that the original worker has stopped before `ACTION=hold`, which
  changes it to `unknown` without another send.
- `unknown`: the provider may have received it. Do not reset or resend the row.
- `rejected`: the provider rejected the request; retain its recorded status.
- `accepted`: API acceptance only. Meta Events Manager attribution remains a
  separate check; Klaviyo `ACTION=readback` can confirm the exact metric/profile,
  occurrence time and local event ID.
- `confirmed`: matching Klaviyo event was read back; this says nothing about
  downstream customer-message delivery or consent.

`erasure_required` means an attempted external event needs provider cleanup.
Local erasure removes payload and customer identity; it cannot retract a provider
event by itself. Do not clear this reason as part of ordinary readback.

## Verification recorded locally

The integrated core, adapters, existing Shopify attribution/contact matching and
recovered-message regression selection passed 213 examples with zero failures
or skips. All 32 changed Ruby/rake files passed RuboCop. An erasure-during-readback
regression failed before its fix and passed afterward. A real financial-service
test exported the original ฿4,000 paid outcome after a ฿1,000 refund while current
cash became ฿3,000. No provider events were sent by these tests.

Production acceptance still needs a controlled conversation/order-link checkout,
an approved Messenger test event with Events Manager verification, and an
existing-profile Klaviyo event with readback. Campaign budget and creative are
not prerequisites for completing the integration.
