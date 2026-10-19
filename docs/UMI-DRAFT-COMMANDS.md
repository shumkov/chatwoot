# Staff draft checkout and PromptPay

Mai uses a private command in a supported social conversation:

1. `/draft-order preview 123:2 456:1 market=TH` checks the exact Shopify variants and displays current prices. The numbers before `:` are variant IDs; after `:` are quantities. The market is required.
2. `/draft-order 123:2 456:1 market=TH` creates an ordinary unpaid OPEN draft for that complete agreed basket. Shumabit returns its Shopify Admin and checkout links privately. Mai reviews and sends the checkout link herself. Pickup or try-before-you-buy terms use the existing Shopify workflow instead.
3. For PromptPay, Mai finalizes shipping, tax, discounts and the full payable THB amount in Shopify Admin, then uses `/payment-qr draft:123` or `/payment-qr order:456` for the purchase already linked to this conversation. The bot prepares a private QR image and caption. Mai sends the customer's chosen payment method; checkout and QR are alternatives for the same purchase.
4. Mai verifies received money in the bank and records the manual payment on that same purchase in Shopify. Preparing a QR or receiving a slip never marks it paid. `/paid-in-chat` retains its existing purpose after Shopify confirms payment.

Only explicit staff notes execute commands. Suggestions from Shumabit do not. Commands remain disabled until the bridge's `CHATWOOT_COMMERCE_INBOX_IDS` includes the intended inbox. Model replies stay private.

## Association API

`GET /api/v1/accounts/:account/umi/shopify/conversations/:display_id/draft_commands?source_message_id=N` verifies the original private staff note and returns its current contact, verified Shopify customer (or null), shop domain and source receipt. For QR it returns only the exact already-linked purchase. Missing identity never triggers a name-based customer guess.

`POST` accepts `{source_message_id, draft_order_id, contact_id}`. It rechecks the current staff note, contact, Shopify OPEN state, exact variant quantities, market/source metadata and customer. It then uses the existing manual association service with the staff author as actor. The API credential remains the configured bridge user, which may be the same existing operator. Generated notes are excluded by their `shumabit_bridge` marker. Repeating the same source links the same draft; it cannot replace it with another one.

Shumabit uses the marker `umi-cw-a<account>-c<display_id>-m<source>` in Shopify tags and the `umi_chatwoot_source` attribute, with the selected market in `umi_market`. An uncertain creation is searched by that marker; no automatic second creation occurs. If the result remains uncertain, inspect the original command and Shopify draft before doing anything else. A new note is not a safe retry of an uncertain purchase.

No endpoint here creates a Shopify payment, completes a draft, sends an invoice email or emits a conversion. Existing draft-to-order reconciliation and financial evidence own those transitions.

## Release verification

Local tests cover source admission, customerless drafts, changed identity/basket, repeated requests, QR linkage and private attachment readback. Before enabling use, verify one owner-only unpaid draft, its private checkout result and its Chatwoot association. Verify a private QR attachment without transferring money. Production activation and those canaries are not established by local tests.
