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

Staff can confirm qualification in Chatwoot's existing **Sales status** dropdown.
The sidebar records the human action with the latest live incoming conversation
message; Shopify alone sets order_placed/purchased. Rejected changes show an error.
The explicit rake form below remains available for a more specific reason and
chosen evidence IDs.

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

## Record settlement in this chat

Use a private note in the conversation that already has the verified Shopify
order link. The exact command is `/paid-in-chat #1234`, using the visible Shopify
order number. The order must already be genuinely paid in Shopify. This command
records where settlement happened; it does not create an order, change payment,
create a customer/link, or send a customer message.

Wait for the private result. The result distinguishes recorded settlement with
Meta Purchase disabled, missing eligible channel evidence, and rejected payment,
checkout or linkage. Acceptance of the command is not a receipt from Meta.
A website checkout remains outside this messaging sender, even after confirmation.
An order settled at the shop must not be confirmed as settled in chat.

To reverse the assertion, post `/paid-in-chat cancel #1234` and wait for its
private result. The note appearing alone does not cancel a queued submission.
Cancellation before claim prevents submission. After a claim, the result explains
that the attempt may already have been sent and cannot be recalled. Payment and
Klaviyo history stay intact. A failed confirmation is final for that note; post a
new command after resolving the reported issue. Duplicate jobs never repeat a
private result or create another sale.

Deleting a confirmation or clearing its native message metadata removes its
future eligibility. Deleting a cancellation does not revive an older confirmation.
Deleting the private result does not reverse the assertion or recreate the result.
Use the explicit cancel command for a confirmed reversal. Wrong paid-order links
still require the existing maintenance procedure: cancel, verify the hold, then
correct the link; do not reset provider attempts or rewrite an immutable paid event.

`UMI_FUNNEL_META_PURCHASE_CHANNELS` defaults to empty, independently of the
existing global Meta switch. Its only accepted comma-separated values are
`messenger` and `instagram`. Both global enablement and the selected channel are
required for Purchase preparation and dispatch. This release does not allowlist
either channel. Instagram additionally uses `UMI_FUNNEL_META_INSTAGRAM_ID` and
requires verified event permission and asset access. Genuine payment timing,
exclusive sender ownership, provider acceptance and optimization eligibility must
be verified before activation. An advertising `validate_only` response is not
that proof. Backend tests do not prove native mobile rendering or Meta attribution.

Each eligible Purchase uses the original immutable Shopify paid time/value and a
selected live incoming message from this exact conversation at or before payment.
Missing, recovered, deleted or post-payment-only evidence holds Meta. Financial
source data is refreshed before preparation and rechecked at claim, including
pending webhook requests. A changed frozen payload or destination holds the same
never-attempted delivery; it is not silently rewritten. A later Shopify edit after
the final read cannot be made atomic with an external POST.

Unresolved Purchase prerequisites now remain visible as pending holds. Previously
excluded `purchase_origin_unresolved` rows are not automatically reopened: a
reviewed rollout may reopen only never-attempted rows inside the original event
window, with the Purchase allowlist still empty. Other terminal reasons and all
attempted rows remain untouched.

## Background operation

The existing five-minute reconciliation job schedules up to 100 eligible sends
and 100 due Klaviyo readbacks per run, only for enabled destinations/accounts.
Klaviyo readback reserves three slots at 5 minutes, 30 minutes and 2 hours after
acceptance. Exhausted or ambiguous outcomes remain visible and are not resent.
`umi:funnel:report` includes preparation holds and exhausted readback counts.

Preparation errors and identity conflicts stop automatic processing. After fixing
the cause, run explicit preview on the never-attempted delivery to clear its hold.
A concurrent automatic worker cannot clear a persisted preparation hold. Pending
missing-contact/profile rows resume when verified linkage becomes available.

Website-only paid orders can attach to one existing contact by the synced Shopify
customer ID while keeping conversation attribution absent. A separate existing
Klaviyo profile binding is still required; this release does not discover/create
profiles automatically. A contradictory current financial identity holds export
even when an earlier paid event has an attached contact. Customer erasure creates
order tombstones before the first financial read as well as clearing linked data.

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

The final integration and existing compliance regression selection passed 312
Ruby examples with zero failures or skips. All 57 changed Ruby/rake files passed
RuboCop; the native sidebar passed 68 frontend tests and its scoped ESLint check. An erasure-during-readback
regression failed before its fix and passed afterward. A real financial-service
test exported the original ฿4,000 paid outcome after a ฿1,000 refund while current
cash became ฿3,000. No provider events were sent by these tests.

Production acceptance still needs a controlled conversation/order-link checkout,
an approved Messenger test event with Events Manager verification, and an
existing-profile Klaviyo event with readback. Campaign budget and creative are
not prerequisites for completing the integration.
