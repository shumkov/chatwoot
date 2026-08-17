# Shopify order → originating Chatwoot conversation

Status: implementation complete on `feat/order-conversation-link`, based on
`cab6bb243` (`origin/umi`). No external deployment was performed.

## Authoritative-spec check

After fetching `origin umi` and rebasing onto `cab6bb243`, I deleted the
worktree-created CRM decision record and reread the authoritative
`docs/UMI-CRM-STACK-SPEC.md` §3.4 (W4) and §7. The implementation does not
contradict it. It follows the agreed pre-commit Message rewrite, `_cw` cart
carrier, single-use signed conversation/contact claim, `orders/create` HMAC
branch, identity-gated verification, unverified mismatch outcome, and canary.

Section §7 now records both requested decisions as resolved:

- Decision 11: express checkout buttons are disabled today, so cart coverage is
  complete; if re-enabled, bypass orders remain unlinked and the canary exposes
  the coverage loss.
- Decision 12: option A, automatic Chatwoot rewriting before Message commit;
  the macro alternative is rejected.

## Implementation

- Added `Umi::Shopify::MessageOrderLinkable` through
  `config/initializers/zz_umi_shopify_order_link.rb`. It rewrites ordinary
  outgoing/template text and the derived HTML used by email replies after
  validation but before the Message insert, outside the database transaction.
  Redis/rewrite failures preserve the original reply and are logged; a runtime
  kill switch disables the rewrite. `SendReplyJob` therefore reads the tagged
  content from the committed row.
- Added a URL-safe SHA-256 `MessageVerifier` token with dedicated purpose,
  account/conversation/contact binding, 30-day expiry, Redis-backed claim
  storage, atomic `GETDEL`, and transient restore after a failed durable write.
- Added `Umi::ShopifyOrderAttribution` and migration-backed storage for verified,
  unverified, and unavailable outcomes; unique account/order and account/nonce
  indexes; account-delete foreign-key cascade; redaction detachment; and a
  verified reporting scope that excludes redacted or incomplete rows.
- Added the `orders/create` branch in a separate UMI webhook prepend. It keeps
  compliance's deliberate always-200 path separate from order retry semantics,
  resolves the exact enabled Shopify hook from the shop header, guards webhook
  delivery IDs, rejects ambiguous carriers, and logs safe per-delivery outcomes.
- Added the low-queue scheduled canary and heartbeat, scoped parameter filtering,
  attribution indexes, the
  storefront snippet/handoff, rollout/rollback runbook, and patch registry row
  25. The app-config stanza and theme wiring are documented but intentionally
  remain human deployment steps in their external repositories.

## Why a table instead of conversation `additional_attributes`

The migration/rebase cost is justified because this is a durable business fact,
not a single conversation setting. `additional_attributes` can hold one mutable
JSON blob, but it cannot safely represent an arbitrary number of Shopify
orders, enforce unique `(account_id, shopify_order_id)` or token-claim
idempotency, provide indexed relational order/revenue queries, or cleanly
separate a forwarded-token `unverified` observation from a `verified` link.
JSON also makes row-level compliance detachment and reporting eligibility easy
to get wrong: a future writer could overwrite or accidentally emit the whole
blob. The table is the smallest durable surface that provides those invariants.

`db/schema.rb` is therefore an intentional rebase conflict. On each upstream
rebase, reapply the migration/schema entry, recheck the UMI overlay autoload
paths and initializer seam, and rerun the focused attribution and Message
callback specs. The remove-when is recorded in `UMI-PATCHES.md`: remove this
patch only when Chatwoot or Shopify supplies an identity-verified,
idempotent, durable order/conversation carrier with compliance hooks.

## Independent review follow-up

All four MUST-FIX items from `docs/UMI-ORDER-LINK-REVIEW.md` are addressed:

1. Redis mint/rewrite failures now leave the message untagged, log the failure,
   and do not prevent `SendReplyJob` from being enqueued; the rewrite kill switch
   is checked at the same boundary. The callback runs after validation and before
   the insert, avoiding a Redis round-trip inside the database transaction.
2. The upstream filter initializer is unchanged. UMI adds an exact
   `note_attributes.value` deep-path filter from its own initializer instead of
   globally redacting every key containing `value`.
3. The Message spec captures the content read by `SendReplyJob` at enqueue time,
   rather than only checking the persisted object after the callback chain.
4. The false `claim_lost_after_failure` and `[UMI-ORDER-LINK]` claims were removed
   or corrected, and specs now cover replayed delivery, a second delivery for the
   same order ID, and conflicting phone identities producing `unavailable`.

Review follow-up decisions:

- SHOULD 5 fixed: attribution indexes now cover conversation, contact, and
  candidate-contact lookup paths.
- SHOULD 6 declined: the authoritative W4 canary is a storefront-carrier
  coverage check; changing it to a verified-rate floor needs a measured social-
  channel identity baseline and would create false rollout failures.
- SHOULD 7 fixed: `UMI_SHOPIFY_ORDER_LINK_REWRITE_DISABLED` is documented and
  tested.
- SHOULD 8 declined: Chatwoot's asynchronous contact/conversation deletion
  lifecycle needs a separate retention decision; this patch keeps the agreed
  Shopify-redaction and account-cascade hooks.
- SHOULD 9 declined: W4 explicitly chose a signed, scoped token; shortening it
  would change the agreed bearer-token contract for marginal URL-size benefit.
- SHOULD 10 fixed enough for this patch: the Redis namespace bypass now has an
  explanatory comment and the fake honors `SET NX` for the restore seam.
- Review P2 fixed: a minted claim is best-effort discarded when an oversize or
  failed rewrite cannot apply it.
- Review P2 declined: the 10-minute delivery lease remains the agreed W4
  protocol; renewal would add a new lease state without evidence of processing
  beyond that bound.
- CONSIDER 1, 3, 8, 9, 10, and 11 fixed: nil content is preserved, oversize
  rewrites are skipped, shop domains are normalized, dead indirection is removed,
  setup uses `let`, and `_cw` is described as sensitive rather than private.
- CONSIDER 2 declined: parsing fenced code blocks would require a content-format
  parser not used by the existing message path; the URL matcher preserves invalid
  or unparsable URLs.
- CONSIDER 4 declined: the callback runs only on create, so it does not retag an
  existing message; reusing an old claim would add a Redis read to the hot path.
- CONSIDER 5 declined: `unlinked` remains a reserved state for explicit organic
  or cleanup records even though the current service does not create one.
- CONSIDER 6 declined: exact-host matching intentionally leaves bare/domain-wide
  links untagged rather than broadening attribution scope.
- CONSIDER 7 declined: the narrow phone-only recipient ambiguity is bounded by
  W4's strict identity gate and is retained as a known POS/draft-order limit.
- CONSIDER 12 partly fixed: the migration now targets Rails 7.1; no redundant
  state check constraint or comment-only ENV inventory was added.

## Compliance and privacy

The signed value is treated as a bearer secret even though the owner-mandated
carrier name is `_cw`. The storefront removes it from the address bar, uses
localStorage only with a 30-day TTL, and the runbook requires an HTTP
`Referrer-Policy: no-referrer` response header; the injected meta tag is only
defense in depth because it cannot protect the initial document request.

Orders with no carrier are untouched. Identity mismatches are stored only as
unverified candidate observations and are not eligible for Meta or Klaviyo
consumers. Shopify customer redaction nulls verified and candidate contact and
conversation references while retaining only anonymized order amount/currency.
Shop redaction removes the account's attribution rows. `customers/data_request`
remains a deliberate manual export path documented in the runbook because the
existing compliance endpoint has no delivery channel for an automatic export.

## Verification evidence

The original regression test was written first and run against the unfixed
callback path: the outbound-link example failed because the stored content
remained unchanged (`2 examples, 1 failure`). During this follow-up, the new
Redis-availability regression also failed before the fix with
`Redis::CannotConnectError`; it now passes while preserving the reply and its
enqueue. The enqueue-time assertion, email HTML rewriting, and
non-outgoing/private exclusions also pass.

Final focused order-link suite: **37 examples, 0 failures**. It covers the
Message callback and Redis outage behavior, email-derived content, signed token
consume/restore, verified/unverified/unavailable identity outcomes, account
mismatch, duplicate carrier, replay and HMAC endpoint behavior, shop redaction,
customer redaction, reporting scope, and canary heartbeat gating.

Existing compatibility suite: **161 examples, 0 failures**, including the
Message model and existing Shopify UMI services/jobs. RuboCop reported no
offenses on the 16 changed Ruby files. `node --check` passed for the storefront
snippet and `git diff --check` passed.

Not run: Shopify app deployment, Shopify webhook subscription deployment,
storefront theme edits, Netdata configuration, or any external service action.
