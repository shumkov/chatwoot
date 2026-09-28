# Manual Shopify links in Chatwoot

Date: 2026-09-28. Status: reviewed design, awaiting user alignment on the limitations below; no application code changed.
Base: `origin/umi` at `0b06c1be04398a34662f2fdfb8172454c21e1be7`.

## Outcome and scope

An operator can associate a Chatwoot contact with an existing Shopify customer and explicitly associate a conversation with an existing draft/order. This covers both invoice checkout and orders paid by PromptPay without a checkout link. Orders remain created and paid in Shopify, manually or through Shumabit in Telegram. Shumabit integration is not a dependency.

Customer identity and conversation attribution are separate: selecting a customer makes their purchase history visible; it does not credit all their orders to the current chat. Only an explicit order/draft selection does that. Shopify remains the source of payment/refund truth. Neither a draft, a QR image, nor a staff assertion that payment arrived creates a paid conversion.

No order creation, Shopify mutations, customer messaging, new agent runtime, permission system, or Meta campaign setup in this change. Existing Meta/Klaviyo export switches stay unchanged. In particular, manual order attribution does not resolve the existing Meta Purchase origin hold.

## Current implementation and research

- `ShopifyOrdersList.vue` reads customer order history. `PreferLinkedCustomer` already uses `contact.additional_attributes.shopify_customer_id`; both the frontend and the upstream controller still require email/phone, which must be relaxed for a valid stored customer ID.
- `OrderAttributionService` verifies the storefront `__cw` carrier and writes `Umi::ShopifyOrderAttribution`. It cannot associate a draft or an order paid without that storefront path. The invoice checkout path is not proven to execute our theme cart script and must not be represented as already covered.
- `OrderFinancialStateService` reads actual payments/refunds; `PaidCustomerLink` attaches missing identity to a canonical paid event. `CohortReport` requires a matching verified attribution row. Reuse these paths rather than creating another paid-event stream.
- All Admin API reads use `ClientFactory`, pinned to **2026-01**. The webhook payload version is separately configured and is not the Admin API version.
- Shopify provides a draft's `order` reference and `invoiceUrl`; draft reads require `read_draft_orders`. The current managed app configuration lacks this scope. [DraftOrder API](https://shopify.dev/docs/api/admin-graphql/2026-01/objects/DraftOrder)
- A completed draft can produce an unpaid order; manual payment is marked paid in Shopify after money is received. [Manual payments](https://help.shopify.com/en/manual/payments/manual-payments)
- Default order access is the most recent 60 days. This iteration does not request historical `read_all_orders` access. [Order API](https://shopify.dev/docs/api/admin-graphql/2026-01/objects/Order)

Alternatives considered:

| Approach | Decision |
| --- | --- |
| Match every order by email/customer and infer its conversation | Reject: a returning customer can have several chats and unrelated purchases. |
| Write conversation attributes into Shopify drafts | Defer: requires write scope and Shopify mutations; an explicit local association is enough. |
| Add draft webhooks and a store-wide draft replica | Defer: polling only explicitly linked drafts on the existing five-minute schedule is sufficient for this small operation. |
| Build Shopify order creation into Shumabit first | Reject as a dependency: manual and Telegram creation must both work now. |
| Existing sidebar + explicit selection + draft-to-order reconciliation | Choose: small operator workflow, existing financial pipeline, no new service. |

## Operator workflow

1. Open the existing Shopify section on a conversation. It shows the linked customer and distinguishes **Customer orders** from **Linked to this conversation**.
2. **Link customer** searches by email, phone or name; alternatively paste the customer's Shopify Admin URL. Show candidates with name/email/phone and require an explicit selection. Never silently choose the first fuzzy result. Preserve Chatwoot's name/email/phone; save only the existing Shopify customer ID field.
3. List that customer's recent orders and drafts, 20 at a time with Load more. Each has number, date, amount/currency, Shopify status, Admin link and **Link to conversation**. Server-check returned customer IDs rather than trusting the search filter alone.
4. **Link order or draft** also accepts a pasted Shopify Admin URL and recognizes its type. Resolve the object through the connected shop, show its customer and order details, then confirm. If the contact has no customer link, confirmation explicitly links both customer and order/draft. A different existing customer is a conflict, not an implicit reassignment. A customerless Shopify order can still be explicitly linked to this contact after preview; it does not invent a customer ID. Raw internal IDs, display numbers and customer invoice URLs are not accepted as Admin URLs.
5. For a linked draft, the operator continues using Shopify/Telegram to create and share its customer checkout URL. An Admin URL is never inserted into the customer composer. No automatic message scanning or checkout-link lookup is required.
6. When Shopify returns the draft's resulting order, retain the draft reference and attach the order to the same conversation. Fetch financial state using the existing reconciliation service. An unpaid order becomes `order_placed`; a paid order becomes `purchased` through the existing financial rules. A draft by itself does not change sales status.
7. For PromptPay, select the existing order and mark it paid in Shopify after receiving payment. The ordinary paid webhook and financial reader supply the conversion; no checkout URL is needed.

The interface works on a Facebook/Instagram contact with no email or phone. Existing native customer matching remains available, but manual selections are never replaced by later fuzzy matching. Customer linking includes Change customer, not a standalone unlink button: clearing the ID alone would immediately allow the existing sidebar/sync to recreate it. Changing customer clears the old `CustomerContactMapper::SHOPIFY_KEYS` enrichment before saving the new ID; it does not retain another customer's spend, tags or marketing metadata.

## Persistence and integration

Extend the existing attribution table, rather than creating competing order attribution:

- Add `source` (`storefront` default for existing rows, `operator` for manual links), `linked_by_id`, `linked_at`, and optional `shopify_customer_id` for the confirmed association.
- Make `token_nonce` nullable, required only for `source=storefront`. Keep its unique index for real tokens; never fabricate a token for operator actions. Existing automatic token verification is unchanged.
- Keep the existing unique order constraint. A confirmed manual order uses `attribution_state=verified`, `match_method=operator`; the UI/report must distinguish operator confirmation from automatic identity verification.
- Existing verified attribution to the same contact/conversation is an idempotent success. A different verified owner is a conflict. An unverified candidate may be explicitly confirmed after showing its previous candidate conversation; a redacted row may never be revived.

Add one small `umi_shopify_draft_links` table for draft associations: account, shop domain, draft ID, contact/conversation IDs, confirmed Shopify customer ID (nullable), resulting order ID (nullable), linked-by/at timestamps, last-checked timestamp, last-error/status and `redacted_at`. Status distinguishes pending, resolved, unavailable, conflict and unlinked; redaction is separately terminal. Unique account/shop/draft. Do not persist full Shopify customer/address payloads or invoice URLs.

Use a UMI controller/service under `umi/app/` and an initializer routing seam. Conversation routes resolve the display ID within `Current.account`, use existing conversation policy, and derive contact from that conversation. Contact-only customer linking uses the existing contact policy. Existing staff access is sufficient; no custom roles. IDs, prices, customer identity and shop are read from Shopify, not accepted as trusted client facts.

Proposed actions under the account's UMI Shopify namespace:

| Action | Meaning |
| --- | --- |
| GET customer search | Bounded query and cursor; previews only. |
| PUT contact customer link | Explicitly set/change the existing contact field. |
| GET conversation commerce | Linked objects, customer history, pagination and refresh errors. |
| POST conversation link preview | Resolve a Shopify Admin URL; no writes. |
| POST conversation links | Re-read the selected object; confirm association transactionally. |
| DELETE conversation link | Remove a correctable association under the rules below. |
| POST conversation refresh | Refresh linked drafts/orders; GET rendering does not enqueue work. |

Backend errors are stable codes rendered through English i18n: customer mismatch, already linked elsewhere, missing draft scope, unavailable object, paid-link correction required, Shopify temporarily unavailable. Use existing alert components. Do not expose raw API payloads/tokens.

Minimal frontend seams: conversation context into `ShopifyOrdersList`, UMI-owned linking component/API wrapper, English strings; avoid a second Shopify panel. Check OSS/Enterprise compatibility. Register the patch in `UMI-PATCHES.md` with removal when upstream provides equivalent explicit links and draft resolution.

## Draft resolution and failure handling

- Existing five-minute reconciliation enqueues a bounded batch of at most 50 unresolved draft reads ordered by oldest check time; manual Refresh is also available. Use normal low-queue jobs and retry policy, not a new worker framework. Rate-limit failures remain visible and do not clear a saved link.
- Re-read the draft through the connected account's shop. If `order` is present, fetch that order, verify its customer against the saved association, create/reuse the order attribution through the same service, and request financial reconciliation after commit. Repeated runs and racing order webhooks produce one order attribution and one canonical paid event.
- A customer change, conflicting order attribution or deleted/moved Chatwoot contact becomes a visible hold. Do not guess from amount, name or timing. A null/deleted/inaccessible draft is shown as unavailable and stops automatic polling; manual Refresh can try again. Authentication/scope failures are errors, not deletion.
- Shopify documents that editing a draft after its checkout starts can break the draft-to-order reference while allowing checkout to finish. If the draft remains open, the operator can link the resulting order directly; we cannot promise automatic recovery. [Draft update caveat](https://shopify.dev/docs/api/admin-graphql/2026-01/objects/DraftOrder#mutations)
- A link to an already paid order requests the same financial read and fills missing event identity, never emits another paid event. Keep actual payment time and existing export source/time rules. Linking old purchase history must not turn it into a new sale today.
- Where a confirmed order points to the same exact Shopify customer ID as its selected contact, that explicit association resolves multiple Chatwoot contacts sharing that customer ID for this order only. Unattributed website orders retain the existing ambiguity hold. Conflicting existing paid-event identity is never silently replaced.

Use the documented `customer_id` draft search filter; Shopify's example currently shows `customerId`, so verify filtering against the pinned live API before acceptance. Always verify each returned draft's customer ID. This is a list convenience; selecting an object always re-reads its exact ID.

### Conversation status across multiple orders

Financial refresh and link/unlink must use one conversation-level projection rule, replacing the current last-refreshed-order behavior: a valid linked canonical paid event wins (`purchased`); otherwise any verified linked order whose financial snapshot is unpaid/partially paid means `order_placed`; otherwise restore the latest non-redacted operator classification, defaulting to `unevaluated`. Missing/error financial state cannot downgrade a previous known commerce outcome. A later refund does not erase the historical paid event.

Recompute under the existing contact/conversation locks after relevant financial writes and association corrections. Use `project_umi_sales_status!` so labels stay consistent, without recording another classification, qualification or payment event. Recompute both old and new conversations when an unpaid association moves. Regression tests must first fail against current behavior for an unpaid order downgrading a paid conversation and an unlinked order leaving a stale stage.

## Corrections and erasure

Allow replacing a customer-only link if no active draft/order association or canonical paid-event contact identity depends on it. Otherwise explain which association prevents the change. Allow unlinking/relinking a draft or unpaid order, with confirmation. One order has at most one attributed conversation; a conversation may have several orders.

A resolved draft and its resulting order are one purchase in the UI. Its draft reference cannot be independently moved: unlinking an unpaid purchase unlinks both associations together and stops its draft resolver; a paid purchase protects both. For the rare broken draft/checkout reference, manually linking the resulting order leaves the draft unresolved until the operator explicitly removes that stale draft link; do not infer the pair.

For this first iteration, once a paid event has acquired contact/conversation identity through a link, do not reassign or erase that association through the sidebar. Show that a paid attribution correction is needed. This is a deliberate limitation: an editable history or provider correction workflow is outside the small linking feature. It must be explained to the user before code; a mistaken paid link needs an explicit maintenance correction, not silent event rewriting. Linking a paid event with no prior conversation remains supported. Before confirming an already-paid order, say: “This links a recorded payment to this conversation. Changing it later requires maintenance.” The restriction is on changing recorded attribution, not on linking a paid order for the first time.

Correction checks and financial attachment must share row/identity locking so payment racing with unlink cannot leave a paid event pointing to a removed attribution. Review the existing financial advisory-lock/contact-lock order before implementing; do not add an independent lock order. Return a conflict and refresh if the underlying object changed since preview. Customer metadata changes alone never move old attribution.

Extend existing contact/shop redaction and orphan cleanup to detach draft links and prevent jobs restoring them. Removed/deleted contact or conversation means no future attribution/export. Redaction is distinct from operator unlink: keep redaction tombstones; ordinary unlink must not create an erasure tombstone. An unlinked manual order row is retained with cleared owner and `unlinked` state to prevent a late storefront delivery unexpectedly reattaching it. Re-linking requires explicit confirmation.

Shopify customer erasure must also find the new associations by account/shop/confirmed Shopify customer ID, including every duplicate Chatwoot contact; the current first-matching-contact callback alone is insufficient. Clear customer/actor metadata on erased links and retain only minimal object tombstones needed to prevent revival. Resolver and confirmation recheck redaction and the current conversation owner under the same identity locks before commit.

## Verification and rollout

Before implementation, independent reviews must cover feasibility/lifecycle, simplicity/operator experience, and identity/financial correctness. Resolve must-fixes, then explain the plan and caveats to the user for alignment.

Tests must cover:

- Contact without email/phone; ambiguous search requires selection; wrong account/shop/conversation denied by existing policy; stale frontend response cannot relink a different chat.
- Manual order, draft invoice conversion, PromptPay paid order and customerless order. Draft complete-but-unpaid and try-before-you-buy/pickup remain non-conversions until paid.
- Paid-before-link and link-before-paid give one event, unchanged payment time/value; two contacts sharing one customer are resolved only by the explicit order selection.
- Storefront automatic links and unverified candidate confirmation; different verified owner conflicts; idempotent submit/webhook/job races.
- Unlink versus paid reconciliation, customer mismatch after draft edit, missing draft/order, transient error, pagination, missing scope and stale preview.
- Paid order A plus unpaid B cannot downgrade purchased; removing the last unpaid link restores classification; removing one of several keeps order_placed. Resolved draft and order correction is atomic. Customer replacement clears stale Shopify enrichment and is rejected if dependent identity remains.
- Contact/shop erasure and conversation deletion before or during resolution; no recreated identity. Reports include manual attribution without treating it as automatic storefront evidence. Meta Purchase origin hold remains enforced.
- Vue interaction checks for preview/confirm/cancel, separate customer history and conversation links, empty/error/loading states. Run focused Ruby/Vitest/lint checks and independent code review; no claims of live verification from mocks.

Deployment prerequisite: the infra owner adds `read_draft_orders` to the managed Shopify app configuration and verifies the installed token actually has it; reconnect alone cannot widen a managed app's declared scopes. No `write_draft_orders` or new webhook subscription is needed. Customer/order linking must keep working if draft access is missing, with the draft controls clearly unavailable.

Live acceptance after deployment: one controlled draft-to-order flow and one manual PromptPay-style payment flow, plus a contact lacking email/phone. Read back persisted links and the single canonical paid event, and verify the sales-status transition. Test purchases/payment state changes require an explicitly selected test order; do not alter an arbitrary customer's order. Exports remain disabled during acceptance. Deploy runs through the infra owner, not this repository.

## Review record

Two independent reviews completed on 2026-09-28: Shopify lifecycle/API feasibility and simplicity/operator domain fit. Both found the stale status on unpaid unlink; the domain review also found the multiple-order downgrade and ambiguous resolved-draft correction. The feasibility review found that customer unlink would undo itself through existing matching. All are addressed above, with customer unlink omitted instead of adding another preference flag. Root inspection additionally identified duplicate-contact customer erasure coverage. Paid-link correction remains an explicit user-alignment caveat because current paid-event identity is immutable once set.

Both reviewers read back the revised design and returned CLEAN. This is design validation, not implementation or live acceptance.
