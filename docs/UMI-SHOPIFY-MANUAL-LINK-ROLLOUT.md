# Manual Shopify links: rollout and operator check

The implementation follows the reviewed manual-link spec. The operator accepted the paid-link correction limitation on 28 September 2026. This document records rollout requirements; the design document preserves its reviewed snapshot.

## Release requirements

Deploy through the `umi-vps-infra` owner, following that repo's deploy skill. This worktree does not deploy Chatwoot.

- Back up the database and run migration `20260928000000_add_manual_shopify_links` with the new image. Restart Rails and Sidekiq together.
- Add `read_draft_orders` to the managed Shopify application's scopes (`shopify/umi-chatwoot/shopify.app.toml` in the infra repository), publish that configuration, and complete the store's scope approval. The Chatwoot OAuth scope list also requests it. Read back `currentAppInstallation.accessScopes`; do not infer access from configuration alone.
- Ensure the existing funnel reconciliation cron is running. It checks at most 50 pending draft links per pass, oldest checked first. Its normal interval is five minutes; operator Refresh queues an immediate check.
- Keep Meta and Klaviyo export settings unchanged. This feature neither activates exports nor resolves the separate Meta Purchase eligibility requirement.

## Operator flow

In a conversation's Shopify sidebar, search for the existing Shopify customer by name, email, phone or customer Admin URL and choose the matching customer. Unique exact email/phone matches can link automatically, preserving existing sidebar behavior. Choosing a customer only displays purchase history; it does not attribute that history to the chat.

Select a draft/order from that history, or paste its Shopify **Admin** URL. Check the preview and confirm. Invoice checkout links and display numbers are not accepted as Admin references. A draft followed by checkout or manual completion resolves to its resulting order. PromptPay payments must be recorded in Shopify; Chatwoot never infers payment from a message or label.

Refresh requests a reconciliation; Reload displays its result. Unavailable drafts and customer/conflicting-link errors remain visible for the operator. Saved links remain visible during Shopify read failures. A linked unpaid order can be removed after confirmation. A recorded paid conversion cannot be moved or removed through this first version; correction requires maintenance. Changing a customer is blocked while active purchase links or paid events use the existing customer.

## Acceptance after deployment

Use designated test conversations and test Shopify records with the operator's approval:

1. Link an existing customer to a contact without email/phone. Verify customer history is visible but no conversion is attributed.
2. Preview and link an unpaid order. Reload after reconciliation: the chat is `order_placed`, never purchased from link confirmation alone.
3. Link a draft, complete it in Shopify, and Refresh. Verify one resulting order association, including when payment is recorded manually rather than through an invoice.
4. Reconcile a paid order and then another unpaid order in the same chat. Verify the chat stays purchased and only one paid occurrence exists per Shopify order.
5. Try an already-linked purchase from another chat; verify a visible conflict. Try changing the linked customer while purchases use it; verify it is blocked.
6. In test data, unlink an unpaid purchase; verify neither a resolved draft nor a pending draft that later discovers the order can reattach it. Verify paid links display the maintenance limitation.
7. Verify scoped access: an agent without access to the conversation cannot read or change its commerce links.

Watch Sidekiq errors for `Umi::Shopify::DraftLinkReconcileJob` and `Umi::Shopify::OrderFinancialStateService`, and draft link `status`, `last_error`, and `last_checked_at`. A scope/access error needs the Shopify installation fixed, not repeated customer reassignment. Storefront attribution must still appear as automatic; operator attribution must appear as manual in the sidebar and `attribution_source` in the paid-order report.

## Rollback

Retain the new nullable columns/table and roll back the image if necessary; do not roll back the migration after manual links exist. The previous image cannot provide the manual-link UI or draft polling. Do not alter paid events to undo this feature. The infra owner should stop pending draft reconciliation before diagnosing live attribution mistakes.

## Concurrency and operational tradeoff

Customer confirmation, automatic customer matching and manual purchase linking serialize with customer erasure using the existing account row. The lock covers the fresh Shopify read through the local save, so an in-flight first association cannot survive an erasure delivery unnoticed. It uses `FOR NO KEY UPDATE`, permitting payment-event foreign-key checks while still serializing these operations. Slow Shopify reads can delay another linking request or erasure processing for that account. This simple account-wide serialization suits the current single-operator workflow; monitor request latency before considering finer-grained coordination.

## Verification boundary

Automated request, service, job and component tests use stubbed Shopify responses and an isolated local PostgreSQL database. Local visual checks use synthetic records. These checks do not demonstrate granted production scopes, a deployed image, real Shopify draft completion or Meta attribution. Those remain explicit post-deployment acceptance steps above.

Verified locally on 28 September 2026: 683 backend examples (UMI requests/services/jobs/models plus Shopify compliance and integration controllers), 7 sidebar component tests, 26 changed Ruby files through RuboCop and changed JavaScript/Vue files through ESLint all passed. No examples were skipped in these runs; the full upstream suite was not run locally. Browser checks covered the real component with synthetic API responses, including edited-reference invalidation, with no console messages.

Review regression tests were observed failing before their fixes and passing afterward. These cover stale draft ownership, background reattachment after unlink, duplicate-contact erasure and partial failure, first confirmation concurrent with erasure, account-lock compatibility with payment-event insertion, and sidebar request ordering/errors. The complete code review and bounded fix readback closed every actionable finding. Full payment-versus-unlink execution with separate database connections remains unverified.
