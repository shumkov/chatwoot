# UMI funnel events, qualification and paid outcomes

Status: implementation draft for independent review, 27 September 2026. Implements the local U2/U3/U5 core of the agreed funnel plan. The existing paid-order report and recovered-message provenance remain the starting point.

## Purpose and scope

Record incoming conversation evidence, let the operator qualify a conversation with a reason, and automatically reconcile Shopify payment notifications into durable paid outcomes. These records feed the separately specified Klaviyo and Meta adapters. Shumabit can suggest classifications through private notes later; its availability does not block these operations.

Use Rails models, existing Shopify credentials/HMAC handling and Sidekiq. No new permission system, generic event bus, message-copy archive or payment creation. Customer messages and external conversion dispatch remain separate. This unit sends neither.

Enable local capture only for account IDs in `UMI_FUNNEL_ACCOUNT_IDS` (comma-separated positive integers; empty by default), and require `UMI_FUNNEL_STARTED_AT` as a UTC ISO8601 observation boundary when accounts are enabled. Invalid enabled configuration fails loudly. This prevents deployment from silently treating old conversations as new campaign traffic. Provider adapters have their own disabled-by-default dispatch configuration.

## Chosen approach and alternatives

Three small tables are enough: conversation occurrences, independent destination delivery state, and current order financial state. Database uniqueness supplies deduplication. Existing committed messages are the recovery source; Shopify remains the payment authority.

Rejected alternatives: labels alone cannot preserve historical qualification; adding money to the attribution table breaks its token/deduplication contract; synchronous Shopify reads inside webhook handlers delay acknowledgment; queue-only notifications lose work if enqueue fails. A durable pending order row plus periodic reconciliation is sufficient without a separate webhook receipt platform.

Official Shopify documentation states that webhooks can arrive out of order or be missed and recommends API reconciliation: <https://shopify.dev/docs/apps/build/webhooks>. Successful sale/capture transactions move money; authorization does not: <https://shopify.dev/docs/api/admin-rest/2026-01/resources/transaction>. The existing application uses this API version; this work does not migrate clients.

## Fixed model contract

All models live under `umi/app/models`, use `Umi::` and explicit table names. Standard `id`, `created_at`, `updated_at` columns apply. Account foreign keys cascade on account deletion. JSON defaults are non-null objects/arrays as specified. Do not retain webhook bodies, message text, email, phone, transaction receipts or payment credentials.

### Umi::ConversationEvent / umi_conversation_events

| Column | Type / rule |
|---|---|
| account_id | bigint, required |
| conversation_id, contact_id | nullable bigint; identifiers must belong to the account and conversation when present |
| event_type | required string: `message_received`, `classification_changed`, `conversation_qualified`, `order_paid` |
| occurrence_key | required string, unique with account_id |
| occurred_at | nullable datetime; null means unknown source time, never substitute observation time |
| observed_at | required datetime, local observation time |
| provenance | required string: `live`, `recovered`, `historical`, `operator`, `shopify` |
| evidence_message_ids | jsonb array, default `[]`; only IDs from the same conversation |
| payload | jsonb object, default `{}`; event-specific allowlist below |
| redacted_at | nullable datetime; non-null prohibits linking/export |

Additional indexes: account_id + event_type + occurred_at, conversation_id, contact_id. No unique timestamp constraint. Event facts do not change after creation, except explicit identity erasure. A paid event initially lacking verified conversation attribution may be attached once when existing attribution becomes verified; this does not change its occurrence, money or source time.

Occurrence keys: `message:<id>`; `classification:<uuid>`; `conversation:<id>:qualified`; `shopify:<lowercase-shop-domain>:order:<order-id>:paid`. There is at most one qualified milestone per Chatwoot conversation and one paid milestone per Shopify order. Later independent purchase attempts in the same thread do not create more qualified milestones in this release.

Payload schemas (keys are strings):

- `message_received`: `message_id`, `inbox_id`, `channel_type`, `messaging_channel`, `scoped_user_id`, `page_id`, `ad_id`. The last three are optional frozen channel/referral identifiers derived from actual message/contact-inbox metadata, never inferred from a name, email or conversation's mutable latest ad attribute. `messaging_channel` is `messenger`, `instagram` or `other`. Missing identifiers remain absent.
- `classification_changed`: `status`, `reason`, `actor_id`, `previous_status`. Evidence IDs are in the dedicated column. Reason is operator-entered, bounded to 1,000 characters; command documentation tells the operator to cite IDs rather than copy personal details.
- `conversation_qualified`: `qualification_reason`, `actor_id`, `inbox_id`, `channel_type`, `messaging_channel`, optional `scoped_user_id`, `page_id`, `ad_id`. Identity/referral comes from the cited eligible incoming evidence; ambiguous or missing referral stays absent. No current conversation label is ad proof.
- `order_paid`: `shop_domain`, `order_id`, `currency`, `value` (decimal string), `time_basis` fixed to `last_successful_payment_at_observed_full_payment`, `order_origin` fixed to `unknown` until a separate supported origin mapper exists. Adapter must not treat this as a messaging purchase merely because conversation_id is present. Financial details remain on the financial state below.

### Umi::ConversionDelivery / umi_conversion_deliveries

| Column | Type / rule |
|---|---|
| conversation_event_id | required bigint FK to ConversationEvent, cascade delete |
| destination | required string: `meta`, `klaviyo` |
| state | required string default `pending`: `pending`, `excluded`, `sending`, `accepted`, `confirmed`, `rejected`, `unknown` |
| payload | jsonb object, default `{}`; frozen allowlisted provider request populated by adapter before dispatch |
| destination_key | nullable string; exact profile/dataset/account target pinned by adapter before dispatch |
| reason | nullable bounded string; machine reason such as `redacted` or `dispatch_disabled` |
| attempt_count | integer, default 0, nonnegative |
| attempted_at, accepted_at, confirmed_at | nullable datetime |
| provider_reference | nullable string, provider event/reference ID only |
| last_error | nullable bounded string, error class/code only; never raw response body |

Unique index on conversation_event_id + destination; index destination + state. Qualified and paid occurrence creation atomically creates one pending row for each destination with empty payload and no destination_key. Before sending, adapters persist the exact destination_key and provider payload so identity changes cannot redirect a retry. Klaviyo binds an existing profile only after operator-selected profile readback and identifier cross-check; core creates no profiles. Its binding lives in contact.additional_attributes['umi_klaviyo_profile_id']. Message/classification records create no deliveries. Disabled dispatch leaves pending rows intact; reports show dispatch configuration separately. Each adapter owns eligibility and delivery transitions, using this shared model; it must not invent a second outbox. `sending` surviving an interrupted attempt becomes `unknown`, not automatically pending. A provider's accepted response is not readback confirmation. Explicit provider rejection is `rejected`; an ambiguous transport failure is `unknown`. Neither is silently reset by the core reconciler.

### Umi::ShopifyOrderFinancialState / umi_shopify_order_financial_states

| Column | Type / rule |
|---|---|
| account_id, shop_domain, shopify_order_id | required, unique together; normalized domain, numeric order ID stored as string |
| reconciliation_requested_at | required datetime, advanced on each notification/operator request |
| reconciled_at | nullable datetime |
| last_error | nullable bounded error class/code |
| snapshot | jsonb object default `{}`, latest sanitized authoritative read |
| paid_event_id | nullable bigint FK to ConversationEvent, unique when present |
| redacted_at | nullable datetime, prohibits reattachment/export |

Snapshot contains the existing report row's classification, review_reasons, currency, original/current_order_value, captured, refunded, net_cash, last_payment_at, order_created_at, order_updated_at; also `observed_at`. Persist money as decimal strings. Extend the authoritative read to retain a sanitized `paid_basket` only when paid: line item/variant IDs and quantities, current subtotal, discounts, tax and shipping values when actually present. Missing component details remain absent; do not synthesize allocations or treat them as conversion eligibility. Store the first paid basket under `first_paid_snapshot` once, alongside its report values, and preserve it when refreshing the current snapshot. Do not store product/customer text or addresses.

## Service interfaces

`Umi::Funnel::EventRecorder.capture_message(message)` returns the existing/new message event or nil if outside enabled scope. It derives timestamps/provenance before creating records. Capture non-private incoming messages only. Existing `content_attributes['umi_recovered']` and `external_created_at` govern recovered provenance; absent original time stays null. Messages created before the observation boundary are historical and cannot become fresh conversion evidence.

`Umi::Funnel::ConversationTransition.new(conversation:, status:, actor:, reason:, evidence_message_ids:).perform` returns the classification event (or latest identical classification on repeated no-op). Actor is an existing account user, not a new role. Human-settable statuses: `unevaluated`, `engaged`, `qualified`, `inactive`, `not_sales`. `order_placed` and `purchased` are commerce-owned projections. A nonempty reason is required. All supplied IDs must resolve to the same conversation; qualification requires at least one non-private incoming live message after the observation boundary. Classification is the human's judgment under Linh's rule, not a regex or message-count score. `occurred_at` for qualification is the latest cited eligible incoming source time; `observed_at` records when the operator classified it.

Under a contact lock followed by conversation lock, reject redacted contacts, record classification, create the stable qualified milestone if applicable and project `umi_sales_status`. Correcting status never deletes the earlier milestone; a correction records its reason and excludes still-pending qualified deliveries when qualification was entered in error (`not_sales` or `unevaluated`). Moving to `inactive` preserves qualification. Already accepted/sending/unknown deliveries remain visibly unretracted; no false claim of external erasure. Requalifying a corrected conversation uses the same occurrence and cannot create a second positive conversion.

`Umi::Shopify::OrderFinancialStateService.request(account_id:, shop_domain:, order_id:)` durably advances the pending request and enqueues `OrderFinancialReconcileJob.perform_later(state.id)`. If enqueue fails, persisted request remains discoverable by reconciliation. Controller returns a failure only if durable persistence failed. Existing attribution handling must still execute for orders/create.

`Umi::Shopify::OrderFinancialStateService.new(state).perform` reads current Shopify order/transactions using the existing report/client classification, then persists the current snapshot. Serialize reconciliation for the same row so slower old reads cannot overwrite newer ones. Preserve notifications arriving during the read: capture request cutoff before reading and mark completed only through that cutoff; a later request stays pending. Never hold a contact lock during a remote API request. Under the same contact-first lock used by redaction, attach only existing same-account/shop/order verified attribution and recheck contact tombstone. Financial state existence never satisfies attribution deduplication.

When classification is `paid`, create the immutable order_paid event and first paid snapshot once. Use the report's last successful payment timestamp with its explicit time_basis. It is evidence of the current fully paid snapshot, **not proof of the historical first fully-paid boundary**. If first observation is already partially/full refunded, no historical paid event is reconstructed: retain known cash/refund state and report `paid_history_unknown`. Refunds and later edits update current cash only; this unit does not emit a second paid event or a speculative external negative purchase. Test/free/unpaid/no-sale/partial-payment/needs-review states never create paid events.

`Umi::Funnel::ReconcileJob` periodically recaptures committed eligible incoming messages after the fixed observation boundary using batches and unique keys, and requeues financial rows with requests newer than completed reconciliation. A bounded operator command can fetch orders updated since an explicit timestamp to recover entirely missed Shopify webhooks, exhausting pagination before declaring completion. Historical observations do not become fresh exports. No indefinite retry loop: Sidekiq's normal bounded retry handles API failures; error state remains reportable.

## Wiring and operator interface

One idempotent `zz_umi_funnel_events.rb` initializer adds message after-create-commit capture/enqueue, the conversation projection concern, Shopify webhook prepend and one reconciliation cron. Check target methods exist. Message callback failure is logged/tracked without failing customer-message delivery; periodic source reconciliation repairs it. Account activation must be deliberate configuration; neither migrations nor initializers classify existing traffic.

Extend the existing verified Shopify endpoint for orders/create, orders/paid, orders/updated, orders/cancelled and refunds/create. Respect its HMAC before_action and existing attribution/privacy chain. Do not retain raw payloads. Register corresponding app subscriptions separately in infrastructure after application deployment; no provider configuration write is part of local implementation.

Protect `umi_sales_status` with a small Conversation model concern that rejects generic changes/deletion of that key, with a tightly scoped instance writer used by the transition service. Cover account API, widget set/destroy and public conversation creation. Unrelated attributes remain editable and preserve the derived key. No new authorization roles or user tokens. Provision its list definition idempotently for enabled accounts; fail visibly on an incompatible existing definition. Project existing `lead-qualified` / `lead-converted` labels only through the service, preserving unrelated labels. Editing a label never creates events.

Extend `umi:funnel` rake commands:

- `qualify`: ACCOUNT_ID, CONVERSATION_ID (internal database ID, explicitly documented), ACTOR_ID, STATUS, REASON, MESSAGE_IDS. Calls transition service; prints event ID/status, no message text.
- `reconcile`: bounded optional ORDER_IDS (same 1–50 validation as paid report) or explicit SINCE for missed-order discovery; account-scoped. Prints counts, not raw payloads.
- `report`: account/time-window counts of observed conversations, qualified occurrences, current classification, paid occurrences, current cash/refunds by currency, attribution coverage, paid_history_unknown and delivery states. Distinguish original paid outcomes from current retained cash. No customer identifiers/details in aggregate output.

## Erasure and deletion

Extend `CustomerRedactionService` inside its existing transaction, using the same contact lock order as transitions/attachment. Clear event conversation/contact/evidence and payload identity/referral/reason fields, mark redacted, exclude pending deliveries and detach financial associations. Preserve only nonidentifying monetary totals/occurrence tombstones necessary to prevent resurrection; remove order identifiers where the compliance policy requires deletion. Do not erase downstream references needed by adapter erasure handling before that handling can run. A redacted event/state never regains identity through reconciliation. `shop/redact` removes this shop's financial records/events and their deliveries through the existing compliance chain. Account deletion cascades. Reconciliation must also notice deleted contacts/conversations and prohibit export from orphaned identity.

## Verification and acceptance

1. Duplicate/concurrent source capture gives one event; equal timestamps on different messages give two. Callback failure then source sweep repairs capture. Capture does not copy content.
2. Recovered/private/outgoing/pre-boundary evidence cannot qualify. Live fitting request can qualify once with operator actor/reason. Wrong-account/message IDs and redacted contacts reject without partial projection.
3. Correction/inactive/requalification preserve history and one positive milestone. Generic API/widget/public attribute writes cannot change/remove protected state, while unrelated attribute edits work. Labels remain projections only.
4. Duplicate/reordered Shopify notifications and lost queue enqueue converge. Paid-first then order-create attribution works. Concurrent old fetch cannot overwrite new state; notification during fetch remains pending. Wrong-shop/account attribution never attaches.
5. Reservation 12,000 edited to kept items 4,000 and paid produces one 4,000 occurrence. Deposit/no-keep/no-show/test/free produce none. Later refund 1,000 changes net cash to 3,000 without changing the original paid occurrence. First-seen refunded order reports historical payment unknown. Later paid basket edits cannot overwrite the first snapshot.
6. API failure retains pending/review state and no fabricated zero money. An unknown payment timestamp cannot become current time. Bounded missed-webhook recovery handles all result pages.
7. Contact erasure racing transition/reconciliation cannot resurrect identity or eligible deliveries. Shop erasure removes scoped records without affecting another shop. Interrupted provider states never silently reset to pending.
8. Run focused service/model/controller/job/task specs, existing attribution/redaction/provenance tests, RuboCop on changed Ruby and diff checks. Run migrations against the isolated test database and verify fresh boot/autoload/cron disabled defaults. No live Shopify writes, customer messages or provider event sends in this verification.

## Delivery boundary

One implementation worker owns interdependent migrations/models/services/wiring/tests to avoid competing schema edits. Parent owns registry/status documentation and separate adapter contracts. Two independent reviewers assess actual spec/code for financial correctness and simple reliable integration. Local core completion means deterministic capture, operator qualification, durable payment reconciliation and useful reporting pass their tests. It does not claim model classification accuracy, retrospective payment history, automatic replacement-order attribution, Klaviyo readback, Meta optimization eligibility or campaign activation.
