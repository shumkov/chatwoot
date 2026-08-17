# UMI Shopify order → conversation link

**Status:** implementation spec, based on authoritative W4 in
`docs/UMI-CRM-STACK-SPEC.md`, updated for decisions 11 and 12.
**Scope:** Chatwoot fork, storefront snippet instructions, and Shopify app-config
change instructions. The storefront repository and Shopify deployment remain
human rollout steps.

## Goal

When an agent sends a `umi.store` URL from Chatwoot, preserve the originating
conversation through checkout and attach a Shopify order to that conversation
only when the order identity matches the conversation contact.

The flow is:

`outgoing Message → signed URL parameter → cart attribute _cw → orders/create → verified attribution row`

Orders without `_cw` remain unlinked. A forwarded token whose order identity does
not match is recorded as `unverified`, but it never becomes a conversation/order
link and is not eligible for Meta or Klaviyo output.

## Chosen design

### Chatwoot rewrite

An idempotent initializer includes `Umi::Shopify::MessageOrderLinkable` in
`Message`. The concern runs after successful validation and before the Message
insert, so the Redis round-trip is outside the database transaction. It rewrites
every absolute `umi.store` URL in outgoing, non-private text messages before
`Message` commits. Redis or rewrite failures leave the original content and log
the skipped attribution; a runtime kill switch can disable the rewrite. The
concern mints a signed verifier token scoped to the message's conversation and
contact, with a 30-day expiry, and stores the token claim in Redis under a
random nonce. The token itself contains no customer PII.

The existing `Message#after_create_commit` callback enqueues `SendReplyJob`.
The pre-insert callback is therefore required: an after-commit rewrite would make
the stored transcript look tagged while the already-enqueued send carries the old
URL.

The verifier uses the existing Rails `secret_key_base` as the server-side HMAC
secret, matching the existing UMI LINE token service. It uses a dedicated
purpose (`umi:shopify:order-link`), JSON serialization, URL-safe SHA-256
signing, strict version/account/conversation/contact/nonce validation, and a
30-day expiry. The URL parameter is `umi_cw` and one token is minted per
message, reused for every eligible `umi.store` URL in that message.

The claim record is consumed with Redis `GETDEL`; `Rails.cache` is not used
because production cache state is a per-container FileStore. The storefront
removes `umi_cw` from the address bar with `history.replaceState` immediately
after capture, sets `Referrer-Policy: no-referrer`, and never logs the token.
The Rails parameter filter also includes `umi_cw` and `_cw`.

### Durable storage

Create `umi_shopify_order_attributions` rather than using
`conversations.additional_attributes` or contact attributes. JSON attributes are
insufficient because one conversation can produce many orders, cannot provide a
relational order/revenue query surface, cannot enforce one record per Shopify
order, and would mix an unverified forwarded-token observation with a verified
business link. The table is intentionally UMI-owned and namespaced.

The row stores `account_id`, `shop_domain`, `candidate_conversation_id`,
`candidate_contact_id`, nullable verified `conversation_id`/`contact_id`,
`shopify_order_id`/name, gross total and currency, `attribution_state`
(`verified`, `unverified`, or `unavailable`), `match_method`, opaque
`token_nonce`, webhook delivery ID, `redacted_at`, and timestamps. The order ID
is a string because Shopify IDs must not be coerced through numeric types. Unique
indexes on `(account_id, shopify_order_id)` and `(account_id, token_nonce)` make
business and token reuse idempotent. The candidate IDs are retained for an
unverified observation only; reporting uses a shared verified scope requiring
`attribution_state = 'verified'`, a non-null `conversation_id`, the requested
account, and `redacted_at IS NULL`.

Shopify customer redaction nulls both verified and candidate contact and
conversation references, sets
`redacted_at`, and retains only the anonymized order amount/currency needed for
aggregate accounting. The operation is in the existing transactional
`CustomerRedactionService` and is retried with the existing redaction retry job.
Account/shop deletion removes the account's rows. `customers/data_request` is
documented as a manual export path and must include this table before production
rollout.

The migration necessarily updates `db/schema.rb`, which is an accepted rebase
cost for a durable, queryable business fact. On each upstream rebase, re-check
the table definition and the initializer's callback seam before replaying patch
25.

### Shopify webhook

Add `orders/create` to the version-controlled app config in `umi-vps-infra`.
The endpoint remains `POST /webhooks/shopify`. The existing controller's HMAC
before-action validates the raw body. The UMI prepend handles `orders/create`
after HMAC verification and leaves the compliance topics' deliberate `200`
behaviour unchanged.

For an order delivery:

1. Resolve `X-Shopify-Shop-Domain` to an enabled `Integrations::Hook` and its
   account. Unknown or disabled shops are a terminal `unconfigured` outcome;
   never use `Account.first` or a request-body shop value. The signed claim's
   account must equal the hook account, and the conversation/contact must belong
   to that account.
2. Parse the root order JSON. A missing order ID, duplicate nonblank `_cw`
   attributes, or a blank `_cw` value is a terminal `malformed` outcome. No
   attribute is a cheap terminal `unlinked` outcome.
3. Check the durable `(account_id, shopify_order_id)` row before claiming. An
   existing row returns `duplicate` without another write.
4. Verify the signed token and atomically `GETDEL` its Redis claim. Invalid,
   expired, account-mismatched, and already-claimed tokens are terminal 2xx
   outcomes and are never retried. The first presentation owns the single-use
   claim, including a forwarded-token mismatch; consuming it prevents a later
   order from using the same bearer token.
5. Insert the attribution row. On an email match, use the exact lowercased,
   trimmed contact email and the order's `email` (then `customer.email` only if
   the root email is absent); a present mismatching email never falls back to
   phone. If no usable order email exists, compare strict E.164 values from root
   `phone`, then `billing_address.phone`, then `shipping_address.phone`. Local,
   malformed, blank, or conflicting values produce `unavailable`, not a guess.
   A match creates `verified`; a mismatch creates `unverified` with no verified
   `conversation_id`/`contact_id`.
6. If the database write fails after `GETDEL`, restore the original opaque Redis
   claim with `SET NX EX` and re-raise. A process crash in that small window may
   lose attribution but cannot create a wrong link. The unique token nonce
   prevents a restored claim from producing a second durable attribution.
7. Return non-2xx only for transient Redis/database failures so Shopify retries.
   The order branch has its own delivery lease and completed marker and never
   calls the compliance module's `compliance_safely` or always-200 path. The
   marker is written after the database commit; a redelivery after a timeout is
   safe because the durable order index is authoritative.

The handler is synchronous only for the small database operation so the response
reflects success. It declares its own `retry_on` if any follow-up job is used;
the global Sidekiq retry cap is three. Each invocation emits a safe
`[umi-shopify-order-link]` summary with outcome, shop, order ID, and delivery ID,
never the token or customer PII. `SENTRY_DSN` is empty in production, so the
rollout runbook wires the summary heartbeat to the existing Ansible-managed
Netdata filecheck dead-man's switch rather than inventing a second alerting path.

### Storefront artifact

Add the snippet and instructions under `docs/` for the separate
`umi-store-theme` repository. The snippet:

- reads `umi_cw` from the landing URL;
- validates that it is nonblank and stores it in `localStorage` with an explicit
  30-day expiry;
- posts `{ attributes: { _cw: token } }` to `window.Shopify.routes.root + 'cart/update.js'`;
- awaits a successful cart update, serializes clear→reapply, and reapplies the
  token after every current theme add-to-cart path and after a cart clear; and
- uses the mandated underscore-prefixed `_cw` name as a private-ish carrier. The
  token is treated as sensitive even if a Shopify surface exposes the attribute;
  the storefront must configure an HTTP `Referrer-Policy: no-referrer` header,
  and the snippet only provides defense-in-depth cleanup.

The snippet must list the current theme's `product-form.js`, `cart.js`, bulk-add,
and custom direct `/cart/add.js` call sites it hooks. It must not read `_cw` back
from `/cart.js`; localStorage is the source of truth for reapplication. No
storefront source is edited in this repository's sibling checkout.

### Canary

`Umi::Shopify::OrderAttributionCanaryJob` runs daily in the `low` queue through
the same per-job `Sidekiq::Cron::Job` registration pattern as patch 7. It reads
the last `UMI_SHOPIFY_ORDER_LINK_CANARY_DAYS` days of orders through the existing
`Umi::Shopify::ClientFactory`, follows cursor pagination, counts total orders,
orders with `_cw`, and the ratio, and never writes Chatwoot or Shopify data. A
successful run requires at least one tagged order and emits a safe summary line;
zero orders or zero tagged orders is a failed canary and emits an exception
tracker event. The configured `UMI_SHOPIFY_ORDER_LINK_CANARY_HEARTBEAT` path is touched
only after a successful positive check, using the existing Netdata app-check /
dead-man's-switch mechanism documented in `umi-vps-infra/docs/APP-CHECKS-NETDATA_SPEC.md`.
The runbook must add that explicit marker path to the existing Netdata check;
this patch does not edit `umi-vps-infra`.

### Coverage

The current storefront has accelerated checkout buttons disabled, so cart checkout
is complete for the deployed theme. If those buttons are re-enabled, bypassed
orders are intentionally unlinked rather than guessed. The canary makes the drop
visible. Meta Business Suite/native-app replies, Shop-app/POS/draft orders, and
any other path that bypasses the storefront cart remain outside attribution.

## Alternatives rejected

- Conversation or contact JSON: cannot model multiple order rows or enforce
  order-level idempotency.
- Shopify order metafield as the carrier: a metafield is a destination and is not
  automatically carried from a storefront cart; `note_attributes` is the carrier.
- Email/phone-only attribution: it is circular because the missing conversation
  identity is what this patch supplies.
- Macro-only tagged links: lower blast radius but misses the agent-forgot case;
  the owner chose automatic rewrite for coverage.
- `orders/paid`: not needed to establish the conversation/order edge; order
  creation is the stable first event and later payment-state work can consume the
  verified row.

## Permanent outcome matrix

| Outcome | HTTP | Redis claim | Attribution row |
|---|---:|---|---|
| no `_cw` | 200 | none | none |
| blank/duplicate/malformed `_cw` or order ID | 200 | none | none |
| invalid/expired/account-mismatched/replayed token | 200 | already absent | none |
| missing usable order identity | 200 | consumed | `unavailable` |
| identity mismatch / forwarded token | 200 | consumed | `unverified` |
| verified email/phone match | 200 | consumed | `verified` |
| Redis/DB failure | non-2xx | restored when possible | transaction rolls back |
| same account/order already present | 200 | unchanged | no second row |

## Verification plan

Focused specs must prove:

- URL rewriting occurs before `Message` creation and before the send job can read
  the row;
- messages without a `umi.store` URL are unchanged;
- invalid/expired/replayed claims do not link an order;
- a forwarded token with mismatched email/phone creates `unverified` with no
  verified conversation link;
- a replayed `orders/create` cannot create a second attribution row;
- an account/shop mismatch cannot resolve a conversation in another account;
- email mismatch does not fall back to phone, and strict E.164 phone matching
  handles root/billing/shipping precedence;
- organic orders without `_cw` are acknowledged and untouched; and
- customer redaction detaches attribution PII while preserving only the
  anonymized aggregate fact; and
- the canary reports a positive tagged-order outcome and touches its heartbeat
  only after that check; failures are exception-tracked without mutating orders
  or contacts.

The regression spec is written and run against the unfixed callback path before
the implementation is added, then rerun after the fix for the required red→green
evidence.

## Rollout and rollback

Rollout order, with no deploy performed by this change:

1. Apply the Chatwoot migration and release the fork patch.
2. Human operator updates the version-controlled Shopify app config and runs
   `shopify app deploy` from `umi-vps-infra/shopify/umi-chatwoot`.
3. Human operator installs the snippet in the published `umi-store-theme`,
   verifies the theme asset is present, and keeps accelerated checkout disabled.
4. Place one tagged cart order and one organic order; verify one `verified` row,
   one unlinked order, and the summary heartbeat. Verify the accelerated checkout
   buttons are still disabled.
5. Add the explicit canary marker to the existing Netdata app-check configuration
   and monitor it for the configured
   window (default seven days).

Rollback sets `UMI_SHOPIFY_ORDER_LINK_REWRITE_DISABLED=true`, removes the
storefront snippet first, then removes the `orders/create` subscription through
the app-config redeploy. Existing verified attribution rows are retained; do not
 delete business history during rollback. If a bad identity match is observed,
 disable downstream Meta/Klaviyo consumers of verified rows, preserve the
 `unverified` records, and investigate before re-enabling.
