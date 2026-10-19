---
title: Social Commerce in Chatwoot - Plan
type: feat
date: 2026-10-19
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Social Commerce in Chatwoot - Plan

## Delivery checkpoint — 2026-10-19

Current owner-directed release scope is **Instagram only**. WhatsApp is blocked and deferred until 2026-10-20; do not activate the Cloud image/PDP fallback, retry catalogue connection, or move catalogue ownership as a workaround. Messenger product sharing also stays off in this release. Enable Instagram independently only after the owner-recipient canary; existing ordinary messaging is unchanged. Instagram cards are product presentations, not an editable native cart: a multi-item basket remains an unpaid Shopify draft with a checkout link.

Source delivery is published in [Chatwoot #100](https://github.com/shumkov/chatwoot/pull/100), [Shumabit #45](https://github.com/shumkov/shumabit-claude/pull/45), and [infrastructure #134](https://github.com/shumkov/umi-vps-infra/pull/134). All are open; none is production activation. U6 package/config source and operator docs are implemented. The installer retains existing draft/restock settings and leaves commerce off.

Verification: Bridge 150/150, zero skipped; broad Rails integration 147/147 followed by final shared-operator regression 11/11; changed Ruby files lint clean; infrastructure 3 commerce + 19 existing contract tests passed. Independent source reviews have no unresolved findings. Actual production identity is the shared operator User1; generated-note markers prevent recursive command handling, without claiming a separate bot permission boundary.

Full PR CI subsequently found an invalid-message Retry regression (409 instead of the existing 422) and four Cloud incoming test failures caused by committed operator-queue fixtures leaving contacts behind. Both were reproduced before correction: Retry 1 failing example; queue-plus-Cloud 68 examples with the same four failures. The corrected combined suite passed 96 examples, zero failures, with zero persisted contacts afterward; two independent delta reviews found no actionable issues. Full CI on the corrected revision remains a release gate. The fixture fix changes no WhatsApp runtime behavior.

Release continuation: merge reviewed sources, produce/verify a Chatwoot release image through the canonical infrastructure owner, install the exact signed Shumabit revision, and complete owner-only product rendering plus private unpaid-draft/QR canaries before channel activation. The owner has been asked for a personal test conversation URL; no real customer recipient was selected. No payment, invoice email, customer message or production change occurred during source implementation.

U1 staff admission, U2 product facts, U3 Facebook/Page-linked Instagram transport, and U5 unpaid drafts/private PromptPay are implemented locally. U4 provides Cloud image/text product sharing and visible inbound catalog enquiries/orders. Native WhatsApp single-product sending is not implemented or enabled: the inspected WABA returned no linked catalog, so there is no verified retailer mapping to use. U6 live canaries and per-channel activation remain outstanding. Local tests are not production delivery evidence. See `UMI-PRODUCT-CARDS.md`, `UMI-CLOUD-PRODUCT-SHARES.md`, `UMI-DRAFT-COMMANDS.md` and the PromptPay addendum for operator and endpoint details.

### Catalogue connection attempt — 2026-10-19

Live phone commerce settings return `is_cart_enabled: true` and `is_catalog_visible: true` (HTTP 200). These switches are already enabled, but do not establish a catalogue association or prove customer-visible functionality.

After the owner reconfirmed the target number and requested connection again, one direct, documented `POST /1900779887500226/product_catalogs` with the existing catalogue ID also failed definitively: HTTP 400, code 100, subcode 2388099, `is_transient: false`, trace `AB32iZv1VYJ_NWtz768SpoV`. Subsequent GET returned HTTP 200 with `data: []`. This reproduces the browser rejection through the existing production credential; do not keep retrying the unchanged request. Further Business Settings inspection currently requires the owner's Meta passkey confirmation.

The owner authorized connecting the existing catalogue in Meta and using product cards as the main product presentation. Browser login completed. Production inbox 3 confirms Cloud WABA `1900779887500226` (UMI clothing), phone-number ID `1123368177532417`, public number +66 80 005 3593. The existing `Shopify Product Catalog` is `1200409158757107`, owned by business `497970999394825`; its Commerce account is `1286633862440382`. Its actual UMI products come from Shopify and the supplementary Flexify feed. Facebook Page `516819784857962` and Instagram @umi.asia are already connected to that shop.

The authorized **Connect Catalogue** attempt failed with Meta's explicit message: **“Product catalogue already linked to WhatsApp business account”**; the dialog says a catalogue can only be linked to one WABA. No successful association, detach, replacement catalogue or provider migration occurred. Both the browser and independent Graph v23.0 reads show empty `product_catalogs` for all three owned WABAs: target `1900779887500226`, UMI (Klaviyo) `1102576082727242`, and UMI `1673373860633578`. The business reports no client WABAs. The conflicting association remains unidentified; do not infer that Klaviyo owns it or disconnect another channel speculatively.

Catalogue eligibility is variant-specific: Sway Beige/M content ID `43654748504111` and Black/S `43654748569647` are shown **Eligible**, while out-of-stock variants explain the product group's **Not eligible** status. Separately, the Actions screen reports policy rejections for underwear variants (Aura, Lure, Pure). Those are not evidence that the whole catalogue is unusable; no products were hidden, deleted or appealed during this connection task. UI content IDs alone do not complete the API retailer-to-Shopify mapping contract.

Continuation: establish whether a legacy WhatsApp Business mobile-app connection holds this catalogue; otherwise escalate the contradictory association to Meta support with the catalogue/business/WABA IDs and empty read results. Only after the owner association is identified should a transfer or other remedy be proposed. Native-card implementation and owner-only rendering/cart verification remain outstanding; the rejected connection does not activate any Chatwoot feature.

## Goal Capsule

- **Objective:** Mai can identify and share an exact UMI product in an existing Messenger, Instagram, or WhatsApp conversation and, when a customer agrees to buy, prepare an unpaid Shopify checkout link without losing the conversation or mistaking a cart, draft, or link click for payment.
- **Means:** Proposed staff-authorized commands in the existing Shumabit–Chatwoot bridge; channel-specific cards sent and recorded through normal Chatwoot messages; Shopify-owned drafts and payment state (KTD1–KTD4).
- **Authority:** Shopify owns product, draft, order, stock, and payment facts; Chatwoot owns conversations and outbound message status; Shumabit suggests privately and executes only explicit staff commands. No new daemon, permission framework, vendor adoption, provider migration, or dashboard redesign.
- **Stop conditions:** A product/variant, channel window, or provider send cannot be verified; a send or draft creation has an ambiguous result; WhatsApp catalog mapping or inbound cart visibility is absent. Hold the affected action for operator review rather than retrying or claiming success.
- **Execution profile:** Separate UMI fork and Shumabit patches, each following its repo's review and release process. Operator-only canaries precede customer activation by channel. Implementation and production activation are separate acts.

---

## Product Contract

### Summary

Mai gets a private, source-grounded product suggestion and may explicitly request one public product card. For a customer-agreed exact basket, Mai may explicitly create one unpaid Shopify draft and receive its invoice URL in a private note. Existing Shopify association and paid-order reconciliation remain the only path from draft to recorded purchase.

### Problem Frame

Current private drafts can discuss products, but there is no exact-SKU public card command or Chatwoot-linked draft creation. The live Meta routes support ordinary text/media, not these commerce payloads. Rich cards, carts, checkout, and payment are separate events; collapsing them would mislead Mai and corrupt attribution. Current production has combined Messenger/Instagram in FacebookPage inbox 2 and recently active WhatsApp Cloud inbox 3. Twilio WhatsApp inbox 6 is configured but had no 30-day traffic (see capability table).

### Requirements

**Product identification and sending**

- R1. `@shumabit` in its currently supported FB/IG inbox 2 may recommend one Shopify product, and a variant only when color/size evidence supports it, plus a canonical URL and ready-to-copy staff command. Conflicting ad creative/greeting, unviewable image, or ambiguous option yields a clear question instead of a guessed SKU or price. In WhatsApp inbox 3 Mai can use a canonical UMI product URL from the storefront/Shopify without relying on in-conversation `@shumabit`.
- R2. Proposed syntax: a real staff-authored private `/send-product <exact variant ID | canonical UMI product URL>` in the same conversation authorizes at most one public product share. A product URL without `variant=` can produce an FB/IG product-level generic card without claiming a size; a native WhatsApp single-product card or variant-specific share requires an exact variant ID or URL with `variant=ID`. Quoted suggestions, AI-generated notes, duplicates, wrong account/inbox, stale/deleted commands, and unavailable products do not authorize a send. Mai sees a concise private result and the normal public Chatwoot message with provider accepted/failed status; no false “sent” receipt.
- R3. Messenger and Page-linked Instagram in inbox 2 receive one channel-appropriate rich generic card with verified image, product title, confirmed variant when known, and canonical Shopify URL when the actual transport accepts it. A price/currency appears only for a verified buyer market or explicit staff-selected market; otherwise omit the price and let checkout quote it. The CTA retains existing conversation attribution or the card does not send. Each channel is activated only after its own owner-recipient canary.
- R4. In active WhatsApp Cloud inbox 3, `/send-product` provides a staff-reviewed canonical PDP link in one normal Chatwoot image message with URL caption, or one text-link message if no usable image exists, even while native catalog sharing is off. A native single-product card activates only after the WABA has a verified existing commerce catalog, exact retailer-ID↔Shopify-variant mapping, and Chatwoot can show the ensuing product enquiry/cart. A cart submission remains an actionable customer message for Mai, never an automatic Shopify order.

**Draft checkout and accounting**

- R5. Proposed syntax: staff first enters private `/draft-order preview <variantID:quantity> [<variantID:quantity> ...] [market=TH]` for a fresh Shopify-read basket summary (product, option, quantity, market/currency and price snapshot, unpaid status) and a ready-to-copy command. A separate real staff private `/draft-order <variantID:quantity> [<variantID:quantity> ...] [market=TH]` contains the whole customer-agreed basket in its own source note and authorizes creation; the bridge rechecks it, so no model or stale thread state chooses line items and no extra confirmation framework is required. Creation requires a verified destination market or Mai's explicit market choice; language/social profile never determines it. Any try-before-you-buy or pickup terms unsupported by the ordinary draft workflow are held for Mai's existing process, not represented as a generic OPEN draft. Shopify then creates one **OPEN/unpaid** draft. Shipping details may be collected at checkout; a known Shopify customer is linked only when verified, and an unknown social profile is never converted into a guessed customer. The draft is associated through the existing Chatwoot commerce link; the Admin reference and `invoiceUrl` return privately for Mai to review. No invoice email, draft completion, payment capture, or automatic public send occurs.
- R6. Product/card/draft prices and inventory are labeled as snapshots; Shopify checkout determines final shipping, tax, discounts and payable total. A draft does not reserve stock by default or prove payment. Existing Shopify webhook, financial reconciliation, `/paid-in-chat` and Meta/Klaviyo delivery owners remain unchanged.

**Operational boundaries**

- R7. All public sends persist a normal Chatwoot outgoing row and use its channel sender; channel rejection and uncertain provider outcome remain visible. The command's durable source ID binds the operation and a verified `requested_by` staff identity without impersonating that user as the bridge credential. Uncertain sends/draft POSTs are reconciled before any retry; Chatwoot's existing manual Retry must not bypass that hold or strip the card payload.
- R8. No Manychat/respond.io/Klaviyo messaging adoption, automated public replies, full Meta catalog migration, in-chat payment, automatic receipt, speculative follow-up, new worker, or new composer UI is part of the first release.

### Actors and flows

- A1. Customer asks about a product or agrees to a basket in an existing conversation.
- A2. Mai checks the private suggestion and issues a private command; she may edit/send an invoice link separately.
- A3. Shumabit bridge validates command/source and reads Shopify; Chatwoot persists/delivers the public message; Shopify owns draft/order/payment.

- F1. Customer/ad/media evidence → optional private suggestion in inbox 2 or Mai's own exact UMI URL in inbox 3 → Mai's `/send-product` → exact Shopify read → Chatwoot public card or Cloud PDP image/link → provider ID or failed/held status → private command result. Covers R1–R4, R7.
- F2. Customer-agreed basket → Mai's private `preview` note listing every `variantID:quantity` → fresh private resolved basket and ready command → Mai's separate full-basket create command → Shopify OPEN draft → Chatwoot verified draft association → private invoice URL → optional human link send → eventual Shopify order/payment webhooks. Covers R5–R7.
- F3. WhatsApp Cloud single-product share → product enquiry or cart webhook → visible inbound conversation with exact catalog/product/quantity fields → Mai follows up. Covers R4; this flow has no automatic order creation.

### Acceptance examples

- AE1. An ad says “Tank Dress” while the creative suggests top/pants and the customer says “black outfit”; the private suggestion asks which item, with no `/send-product` variant or invented price. Covers R1.
- AE2. Mai types `/send-product https://umi.store/products/example?variant=123` as a private note after verifying a specific variant. One public card, or on Cloud one image/link share, appears in the same conversation with matching color/size and a tracked UMI CTA; price is omitted if buyer market is unknown. Its provider ID or failure is visible. Replayed webhook, quoted AI suggestion and manual Retry after an uncertain send make no second send. Covers R2–R4, R7.
- AE3. A WhatsApp cart contains two retailer IDs and quantities. Mai sees the exact submitted items and any unmapped item is marked unresolved; no draft/order/payment appears. Covers R4.
- AE4. Mai privately enters `/draft-order preview 123:1 456:2 market=TH` after the customer agrees to those items and confirms Thailand, sees both exact options and quantities, then enters the returned `/draft-order 123:1 456:2 market=TH` as a separate private note. Shopify returns an OPEN draft and invoice URL, which appear privately with the linked draft; no email/public message is sent. A network timeout after POST holds the create command until readback, and a repeat does not create a second draft. Covers R5–R7.
- AE5. The customer pays the draft invoice. Only Shopify order/financial reconciliation marks paid; the card, cart, draft, and invoice click never mark paid or fire a second Meta Purchase. Covers R6.

### Capability boundary

| Surface | Current evidence | New work / release gate |
| --- | --- | --- |
| Messenger, inbox 2 | FacebookPage route; text/media/quick replies, 217 combined FB/IG public incoming and 439 outgoing with provider IDs in 30 days | Generic-template serializer and self-recipient provider/Chatwoot readback; no catalog required |
| Instagram, inbox 2 | Same FacebookPage channel with `instagram_direct_message` dispatch to Page-token Instagram sender | Test **that** endpoint, template rendering and window independently; native IG-login generic examples are not proof |
| WhatsApp Cloud, inbox 3 | Active provider with 6 incoming/5 outgoing with provider IDs in 30 days; session text/media/interactive text | WABA `/product_catalogs` read returned HTTP 200 `data=[]` with current token despite visible/cart settings true; establish existing Shopify-fed catalog association, retailer mapping, Cloud send and inbound enquiry/cart first |
| Twilio WhatsApp, inbox 6 | Zero 30-day public traffic | No first-release implementation or migration |
| Shopify | Shumabit app's live `currentAppInstallation` read confirms `read_products`, `read_draft_orders`, `write_draft_orders`; Chatwoot has manual draft/order link and paid reconciliation | Staff-command draft creation/association; no extra Chatwoot draft-write grant assumed |

---

## Planning Contract

### Key technical decisions

- KTD1. **Human command is the proposed send boundary.** Reuse `tools/chatwoot-bridge/bridge.js` source refetch, staff/private/marker checks, queue and durable source state, while AI remains private. This is an operator-control recommendation for review, not a user-settled command interface. Governs R1, R2, R5, R7.
- KTD2. **Normal Chatwoot outgoing row owns delivery.** A narrow UMI-owned structured product payload is interpreted in existing FB/IG/Cloud channel services and stores one provider message ID or failure. Avoid a direct Shumabit→Meta send, which would bypass conversation history and sender status. Keep OSS/Enterprise-compatible overlay/initializer hooks and fail loudly if an upstream hook changes. Governs R2–R4, R7.
- KTD3. **Card and draft are separate operations.** One exact Shopify variant read can supply both, but no card creates an order. Shumabit's granted Shopify draft scope performs the proposed staff-requested `draftOrderCreate`; existing Chatwoot `ManualLinkService`/`DraftLinkReconcileJob` owns association and later conversion. Shopify payment remains authoritative. Governs R5, R6.
- KTD4. **Channel-specific release gates.** FB generic can advance independently; Page-linked IG needs its own canary; Cloud product card waits for catalog mapping and inbound parse. Cloud inbox 3, not inactive Twilio 6, is the WhatsApp target. A PDP link/image shares a product but is not called a native commerce card. Governs R3, R4.
- KTD5. **One operation per staff source; uncertain outcomes stop.** Persist command ID, conversation, variant/basket, resulting Chatwoot message or draft ID, and status. Before POST, re-read source and relevant state; after uncertain POST, read back by stable marker/provider object rather than blind retry. Chatwoot `MessagesController#retry` currently clears `content_attributes` and re-enqueues delivery: structured-card rows with an uncertain outcome must reject that route, while a definite failure may retry only with the immutable card payload and source identity intact. Use existing bridge state and narrow Shopify draft marker, not a general orchestration subsystem. Governs R2, R5, R7.
- KTD6. **Preserve staff-requester audit without service impersonation.** The bridge credential executes API calls, while Chatwoot verifies the source private note's user/account/conversation and stores that user as `requested_by`. Do not accept an arbitrary caller-supplied user ID; retain the service principal in delivery logs and bind the verified requester to the public row and draft link. Governs R2, R5, R7.

### Existing ownership trace

Today a public message is built by `app/controllers/api/v1/accounts/conversations/messages_controller.rb` and `app/builders/messages/message_builder.rb`; `app/models/message.rb` enqueues `SendReplyJob`. The job selects Facebook vs Page-linked IG by `conversation.additional_attributes['type']`, or Cloud WhatsApp by channel. `Base::SendOnChannelService` skips private/source-ID messages. Facebook and Instagram currently send text/media separately and can overwrite the single Chatwoot `source_id`; the new card must be **one provider call for one public row**. Cloud chooses session vs template using `conversation.can_reply?`; the structured card cannot bypass that decision.

For an ordinary public `umi.store` URL, `umi/app/services/shopify/message_order_linkable.rb` mints `umi_cw` in message text at validation. The storefront puts it into cart `__cw`; `orders/create` → `ShopifyOrderLink` → `OrderAttributionService` verifies the conversation/contact against Shopify identity. A rich-card button URL is not currently scanned by that concern, whose current rescue also allows an untracked ordinary URL when minting fails. Structured cards must instead fail closed before send unless the saved CTA has one valid token; U2 owns this narrow exception without changing ordinary URL behavior. Draft invoice checkout may not carry this storefront token: `CommerceController#create` → `ManualLinkService.link_draft!` → `DraftLinkReconcileJob` → Shopify `draft.order.id` → `ManualLinkService.link(order,draft:)` is the separate explicit association path. Shopify financial webhooks → `OrderFinancialStateService`/`PaidOrderReport` produce `order_paid` only for paid classification; `SettlementCommand` and `PurchaseSource` then decide whether chat-origin Meta Purchase is eligible. A sent card or draft cannot replace any of those checks.

### Alternatives and constraints

- Sending a plain Shopify URL through today's composer is the lowest-risk immediate manual workflow but does not satisfy the requested rich card. Keep it available as a fallback, not as the finished feature.
- Native Meta catalog product cards across all channels would demand catalog linkage and variant map, which are not verified; use non-catalog generic cards for FB/IG first. Meta documents [Messenger generic templates and its standard response window](https://www.postman.com/meta/messenger-platform-api/folder/vilwbh4/send-api) and [Instagram generic templates](https://www.postman.com/meta/instagram/folder/rl2amj3/templates), but the Instagram example follows native IG login, not necessarily UMI's Page route.
- WhatsApp Cloud, rather than Twilio Content templates, matches actual customer traffic. Meta's [single-product request](https://www.postman.com/meta/whatsapp-business-platform/request/syvmul4/send-single-product-message) and [inbound messages object](https://www.postman.com/meta/whatsapp-business-platform/folder/1dtuocp/messages-object) shape the contract. WABA catalog emptiness is an account prerequisite, not a reason to block FB/IG.
- Shopify [draftOrderCreate](https://shopify.dev/docs/api/admin-graphql/latest/mutations/draftordercreate) and [DraftOrder.invoiceUrl/status](https://shopify.dev/docs/api/admin-graphql/latest/objects/DraftOrder) support an unpaid direct checkout link. `draftOrderInvoiceSend` and `draftOrderComplete` are distinct operations and excluded.
- Preserve the current UMI fork's overlay/patch registry and Enterprise Cloud prepend. Avoid frontend changes: the command and normal Chatwoot message carry the operator workflow. Recheck any title/image/price/tax field against actual Shopify API and market before treating it as customer-ready.

---

## Implementation Units

### U1. Exact product proposal and staff command admission

- **Goal:** Private suggestion stays grounded; `/send-product` and `/draft-order` accept only real staff private sources with exact Shopify IDs and durable one-source claims.
- **Requirements:** R1, R2, R5, R7.
- **Files:** `tools/chatwoot-bridge/bridge.js`, `chatwoot.js`, `server.js`, `bridge.test.js`, `.claude/agents/shumabit-chatwoot.md`, shared Shopify skill as needed. Avoid duplicating agent instructions.
- **Approach:** Reuse current `/back-in-stock` command shape and source re-fetch across account 1 conversations (existing `@shumabit` suggestions remain inbox-2-only). Bind account/conversation/inbox/source and verified staff requester, exclude `shumabit_bridge` and any generated/quoted command, parse variant ID or canonical UMI product URL and explicit draft `variantID:quantity` list, and return a private status. `preview` is a read-only Shopify resolution with a copyable full-basket command; only that separate command may create. Mai can copy a product URL herself in Cloud inbox 3. No model-driven routing or direct public write from the model. Keep a default-off, per-channel activation boundary using existing bridge configuration style.
- **Dependencies:** None; U2 and U5 use this admission contract.
- **Test scenarios:** AI note quoting a command, deleted/edited source, duplicate event, wrong conversation, conflicting ad, ambiguous image, exact variant and wrong handle, product-only URL, Cloud manual URL, explicit multi-item basket, staff command after later customer change.
- **Verification:** `cd tools/chatwoot-bridge && npm test`; current bridge suite plus new command cases.

### U2. Product facts and attributed card contract

- **Goal:** Freeze a verified exact variant/product/market snapshot and one safe card payload before any public send.
- **Requirements:** R1–R3, R6, R7.
- **Files:** Shumabit `tools/chatwoot-bridge` narrow Shopify reader and `bridge.test.js`; Chatwoot `umi/app/services/shopify/message_order_linkable.rb`, new UMI service/initializer only where core sender cannot be extended safely, `spec/models/umi/shopify_order_linkable_spec.rb`, `spec/services/umi/shopify/order_link_token_service_spec.rb`.
- **Approach:** Read exact variant ID when specified, otherwise product-level facts only. Validate the URL's handle and any variant against Shopify; do not infer a SKU from media/ad words. Determine buyer market from a verified destination or explicit staff choice; if unknown, omit card price/currency. Construct a canonical PDP CTA whose `umi_cw` token is minted/embedded under Chatwoot's existing attribution contract; require the saved structured-card CTA to contain one valid token before it is deliverable and fail privately on mint/validation error. Keep ordinary link behavior unchanged. Store structured card facts with the public message so provider serializers cannot substitute current unrelated product data.
- **Dependencies:** U1.
- **Test scenarios:** Wrong handle/variant, product-level URL with no claimed option, inaccessible image, unknown market omits price, verified different market currency, stale price, ad conflict, card CTA token present exactly once, token mint fault blocks card before delivery, ordinary URL behavior unchanged.
- **Verification:** Bridge tests and focused `bundle exec rspec spec/models/umi/shopify_order_linkable_spec.rb spec/services/umi/shopify/order_link_token_service_spec.rb` with `rbenv` initialized.

### U3. Messenger and Page-linked Instagram generic cards

- **Goal:** One Chatwoot public card row becomes one provider generic-template send on each actual inbox-2 branch.
- **Requirements:** R2, R3, R7.
- **Files:** `app/jobs/send_reply_job.rb`, `app/services/facebook/send_on_facebook_service.rb`, `app/services/instagram/messenger/send_on_instagram_service.rb`, `app/services/instagram/base_send_service.rb`, `app/controllers/api/v1/accounts/conversations/messages_controller.rb` only where required; prefer `config/initializers/zz_umi_*.rb` plus `umi/app/services/*` extension. Mirror any Enterprise override. Tests in `spec/services/facebook/send_on_facebook_service_spec.rb`, `spec/services/instagram/messenger/send_on_instagram_service_spec.rb`, `spec/controllers/api/v1/accounts/conversations/messages_controller_spec.rb`.
- **Approach:** Branch only for the structured card; preserve text/media and private-note behavior. Use one provider request, save its ID/failure on the normal row, attach verified `requested_by` separately from the executing API user, and prohibit replay of an ambiguous accepted send. The existing `MessagesController#retry` must reject uncertain structured-card rows and retain immutable card/source fields on any allowed definite-failure retry. Enforce actual response window and do not use `HUMAN_AGENT` to send promotional product cards. Enable FB and Page-linked IG separately after owner-only recipient canary confirms API shape, rendered card/CTA, and Chatwoot/provider readback; native IG adapter is not live scope.
- **Dependencies:** U1–U2.
- **Test scenarios:** FB vs Page-linked IG dispatch, exact image/variant/optional price/URL, normal text unaffected, private source never serialized, provider reject/timeout, duplicate job, existing manual Retry after timeout vs definite failure, verified requester audit, window closed, readback/echo dedup.
- **Verification:** `bundle exec rspec spec/services/facebook/send_on_facebook_service_spec.rb spec/services/instagram/messenger/send_on_instagram_service_spec.rb spec/controllers/api/v1/accounts/conversations/messages_controller_spec.rb spec/models/umi/shopify_order_linkable_spec.rb`; owner canary before customer enable.

### U4. Active Cloud WhatsApp single product and inbound cart

- **Goal:** Native single-product share in inbox 3 is enabled only when exact catalog mapping and inbound order/enquiry visibility work.
- **Requirements:** R4, R6, R7.
- **Files:** `app/services/whatsapp/send_on_whatsapp_service.rb`, `app/services/whatsapp/providers/whatsapp_cloud_service.rb`, `app/services/whatsapp/incoming_message_service_helpers.rb`, `app/services/whatsapp/incoming_message_base_service.rb`, corresponding `enterprise/app/services/enterprise/whatsapp/providers/whatsapp_cloud_service.rb`; tests in `spec/services/whatsapp/providers/whatsapp_cloud_service_spec.rb`, `spec/services/whatsapp/incoming_message_whatsapp_cloud_service_spec.rb`, Enterprise counterpart. Use UMI initializer/overlay when practical.
- **Approach:** Independently of catalog, make `/send-product` create one normal Cloud image message with an attributed UMI PDP URL in its caption, or one text URL message if the image is unavailable, and truthful provider status; this is a product share, not a native card. For native card, first identify the existing Shopify-fed Meta catalog and verify its WABA association and exact retailer IDs from a real API read, never derive retailer IDs by string format. Parse Cloud product enquiries and `order` payloads into a visible incoming message with structured catalog ID, retailer IDs, quantities and provider source ID; unresolved mapping stays visible, not transformed into a Shopify line item. Only then add Cloud outbound single-product payload within an eligible session; gate activation until self-recipient send, enquiry/cart and Chatwoot readback pass. If WABA still returns no linked catalog, native card remains off while FB/IG and Cloud PDP share can proceed.
- **Dependencies:** U1–U2 for Cloud PDP share; verified WABA catalog association and inbound parser before native-card activation. U3 is independent.
- **Test scenarios:** One product, multi-item cart, unmapped item, malformed/duplicate order webhook, 24-hour session expiry, source ID, no Shopify draft/order or payment on cart, Cloud3 vs Twilio6.
- **Verification:** `bundle exec rspec spec/services/whatsapp/providers/whatsapp_cloud_service_spec.rb spec/services/whatsapp/incoming_message_whatsapp_cloud_service_spec.rb spec/enterprise/services/enterprise/whatsapp/providers/whatsapp_cloud_service_spec.rb`; owner-only Cloud canary after catalog association.

### U5. Staff-requested unpaid draft and existing association

- **Goal:** One explicit command creates one OPEN Shopify draft and links it to the conversation, with invoice URL private to Mai.
- **Requirements:** R5–R7.
- **Files:** Shumabit `tools/chatwoot-bridge/bridge.js`, narrow draft module/tests, `chatwoot.js`; Chatwoot existing `umi/app/controllers/shopify/commerce_controller.rb`, `umi/app/services/shopify/manual_link_service.rb`, `umi/app/jobs/shopify/draft_link_reconcile_job.rb` if a minimal authenticated association endpoint is needed. Preserve `umi/app/services/shopify/order_financial_state_service.rb`, `umi/app/services/funnel/purchase_source.rb` ownership.
- **Approach:** Read-only `preview` resolves every exact variant and quantity against a verified destination market or explicit `market=XX`, then returns one private basket/unpaid summary with a copyable ready command. The separate create command rechecks the full list/market and any TBYB or pickup terms; unsupported terms hold for the existing human workflow instead of silently creating an ordinary draft. Then use Shumabit app's current `write_draft_orders` grant and `draftOrderCreate` with a stable source marker; read back ID, OPEN state, line items and invoiceUrl. Link through the current stale-preview/identity-checked commerce path or a narrow equivalent that verifies the real source-note requester and records that `requested_by` without impersonating them; existing draft linkage accepts a customerless draft when both sides have no Shopify customer. If POST outcome is uncertain, hold and search marker/readback before retry. Private result says requested/unpaid, plus Admin/invoice links and a subtotal-versus-final-shipping/tax distinction; no automatic invoice email, completion, payment or public message. Request missing information only if Shopify requires it for this draft or the requested terms require it.
- **Dependencies:** U1–U2. Independent of U3–U4 transport activation.
- **Test scenarios:** Explicit one/multi-variant quantities, preview never writes a draft, basket summary and ready command before create, changed variant between preview and create, unknown market holds, explicit market rechecked, customer mismatch, verified requester vs bridge execution identity, shipping/tax/discount snapshot vs checkout final total, duplicate command, timeout after accepted create, missing invoiceUrl, link conflict, draft converts to order, no paid event until verified Shopify payment, unsupported TBYB terms hold.
- **Verification:** Bridge draft tests; focused `spec/services/umi/shopify/manual_link_service_spec.rb`, `spec/jobs/umi/shopify/draft_link_reconcile_job_spec.rb`, `spec/services/umi/shopify/order_financial_state_service_spec.rb`, `spec/services/umi/funnel/settlement_command_spec.rb`; owner-only draft canary without invoice email/customer notification.

### U6. Release checks and operator guide

- **Goal:** Mai can distinguish a suggestion, a sent/failed card, a cart request, an unpaid draft, and a paid Shopify order, with separate activation controls per channel.
- **Requirements:** R1–R8.
- **Files:** Shumabit bridge `README.md`, shared skill/agent instructions as applicable; UMI fork patch registry `UMI-PATCHES.md`, operational docs under `docs/`; canonical infra gate owned by deployment operator.
- **Approach:** Document proposed command syntax, exact-ID and customer-agreement preconditions, product-only vs variant-specific cards, Cloud PDP fallback and recovery for unknown send/draft outcome. Stage FB first, Page-linked IG after its canary, Cloud PDP share independently, Cloud native card after catalog + inbound cart, and draft command after association canary. Read back installed source/image/config and each channel's Chatwoot row/provider ID or failure. Customer-facing activation remains a separate reviewed step.
- **Dependencies:** U1–U5, with per-channel partial release allowed when its own gate passes.
- **Test scenarios:** Default-off flags, wrong inbox, no public note recursion, staff guide wording, no invoice email or CAPI event from draft/cart; an unresolvable provider timeout stays held for operator inspection rather than claiming dedup readback succeeded.
- **Verification:** Relevant full bridge suite, focused Chatwoot and Enterprise specs, lint, source/image readback, and owner-only canary receipts. Do not call an untested channel live.

---

## Verification Contract

| Evidence | Exit signal |
| --- | --- |
| Bridge | `cd tools/chatwoot-bridge && npm test` passes all tests with zero skips; explicit RED→GREEN on any regression fix. Duplicate/ambiguous send and draft cases prove no second external POST. |
| Chatwoot sender/inbound | Initialize `rbenv`; `bundle exec rspec` on the focused Facebook, Page-linked IG, Cloud and UMI Shopify/funnel specs named in U3–U5. OSS and Enterprise Cloud variants pass; existing text/media and manual link contracts remain. |
| Fork quality | UMI-owned code in overlay/guarded initializer wherever possible; `UMI-PATCHES.md` row with remove-when; relevant RuboCop passes; independent code review of sender, auth, attribution and payment boundaries. |
| Account preflight | Read-only verification of Page-linked IG generic endpoint, Meta window/permission, WABA catalog association and variant mapping, Shopify current grant. An unmet preflight blocks only its channel. |
| Owner canary | Staff test account/conversation: source command → public Chatwoot row → provider ID or failed state → rendered image/variant/CTA. Native WhatsApp catalog card additionally requires inbound enquiry/cart readback before activation; the single-message PDP-link fallback does not. Draft canary reads OPEN draft/link/invoiceUrl and verifies no email/public send/paid event. |
| Production | Separate approved channel activation, exact source/image/config readback, and observation of one genuine customer path; no success claim based only on mocked API or provider HTTP 200. |

## Definition of Done

- U1–U6 acceptance examples pass and their implementation-only experimental/dead paths are removed.
- Public product shares remain staff-authorized, Shopify-verified product-level or exact-variant as specified, attributed, normal Chatwoot messages with truthful provider state. Shumabit's unsolicited suggestions remain private.
- Native WhatsApp card stays disabled until its catalog association, retailer mapping and cart/enquiry inbound evidence pass; Messenger and Instagram gates are independent.
- Draft creation yields one linked OPEN/unpaid Shopify draft and private invoice URL, with no automatic invoice email, public send, completion, payment, or duplicate CAPI Purchase.
- Required source review, code review, canary, and production readback receipts are complete for each channel actually activated. An unactivated channel is reported as such.

---

## Appendix

### Platform capability versus UMI implementation

| Capability | Platform evidence | Current UMI limit / decision |
| --- | --- | --- |
| Messenger generic/button/receipt | Meta's [Send API collection](https://www.postman.com/meta/messenger-platform-api/folder/vilwbh4/send-api) documents these templates and the standard 24-hour response basis. | Inbox-2 sender supports text/media/quick replies, not generic cards. A receipt would display an existing order, not create or pay one; no receipt in first release. |
| Instagram generic | Meta's [Instagram generic-template collection](https://www.postman.com/meta/instagram/folder/rl2amj3/templates) supports image/text/buttons, but its example uses native Instagram Login. | Live IG is Page-linked FacebookPage, so its token, endpoint, window and rendering need a separate owner canary. Native IG product-template/catalog entitlement is unverified and not needed for generic-card first slice. |
| WhatsApp Cloud single/multi/catalog/cart | Meta's [single-product request](https://www.postman.com/meta/whatsapp-business-platform/request/syvmul4/send-single-product-message) and [messages-object reference](https://www.postman.com/meta/whatsapp-business-platform/folder/1dtuocp/messages-object) include catalog product and inbound-order shapes. | Live Cloud inbox 3 has no catalog returned by its WABA `/product_catalogs` GET; inbound Chatwoot parser currently lacks order/product mapping. Build one-product path and inbound cart before activation; no multi-product/catalog rollout. |
| WhatsApp payment in chat | Meta's [order-details Payments API example](https://www.postman.com/meta/whatsapp-business-platform/request/fhq321e/send-order-details-message) is for India; no Thailand eligibility was established. | Shopify invoice checkout remains the payment path; no in-chat payment claim. |
| Outside-window sends | Messenger [Send API](https://www.postman.com/meta/messenger-platform-api/folder/vilwbh4/send-api) and Meta/Twilio [WhatsApp session guidance](https://www.twilio.com/docs/whatsapp/key-concepts) distinguish ordinary 24-hour replies from approved outside-window messages/templates. | Staff command does not override a channel window. Do not use the `HUMAN_AGENT` support tag for promotional product cards; its account approval/eligibility was not verified. |
| Shopify draft checkout | Shopify [draftOrderCreate](https://shopify.dev/docs/api/admin-graphql/latest/mutations/draftordercreate), [DraftOrder.invoiceUrl](https://shopify.dev/docs/api/admin-graphql/latest/objects/DraftOrder), and [OPEN status](https://shopify.dev/docs/api/admin-graphql/latest/enums/DraftOrderStatus). | Shumabit app has current read-product/read-draft/write-draft scopes; Chatwoot links/reconciles but cannot create a draft. Invoice email and completion are separate excluded operations. |

Source inspection: `app/jobs/send_reply_job.rb`, `app/services/{facebook,instagram,whatsapp}/`, `app/controllers/api/v1/accounts/conversations/messages_controller.rb`, `umi/app/services/shopify/`, `umi/app/services/funnel/`, `tools/chatwoot-bridge/{bridge,chatwoot,restock}.js`, and `skills/umi-shopify/SKILL.md`. At plan creation the inspected refs were Chatwoot `origin/umi` `5640ea4fae6721422f03828b90fc139dc2f52120` and Shumabit `origin/main` `ac39636d4916504757a8ce4fed04769fdfe42d26`. Live channel counts/catalog/scope observations are from a bounded 2026-10-19 read-only preflight; provider delivery and template eligibility remain unproven until canary. Direct Meta Developers pages returned HTTP 429 during research, so Meta-owned Postman collections establish general capability but do not validate UMI's Page-linked Instagram route or current account entitlement.
