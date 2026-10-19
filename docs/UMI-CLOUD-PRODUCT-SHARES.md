# Cloud WhatsApp product shares

The UMI product-share endpoint also accepts the configured WhatsApp Cloud inbox (3) from the authenticated Shumabit bridge. A real staff private `/send-product` note still binds the source, requester, exact Shopify facts and attributed UMI PDP URL to one normal Chatwoot outgoing row. Its provider path sends one Cloud image with that URL in the caption, or one text message with the URL when no verified image exists. It does not send a native catalog card.

`UMI_COMMERCE_CLOUD_INBOX_ID` defaults to `3`. `UMI_PRODUCT_SHARES_CLOUD_ENABLED` is absent/off by default and must be exactly `true` to dispatch Cloud product shares. The sender also requires a live `conversation.can_reply?` WhatsApp session; it never switches a product share to a template. Existing Facebook and Page-linked Instagram flags remain independent. Production enablement waits for an owner-recipient Cloud canary with provider ID and Chatwoot readback.

Cloud product enquiry and catalog-order webhooks become visible incoming conversation messages. They retain the Meta catalog and retailer IDs, quantities, original text and provider source ID where present. These IDs remain unmapped until a real WABA catalog association and Shopify retailer mapping are verified. Neither the webhook nor a product share creates a Shopify draft, order or payment. Native single-product sending and conversion of catalog items into Shopify line items remain disabled without that mapping and a separate canary.

Rollback: turn off `UMI_PRODUCT_SHARES_CLOUD_ENABLED` to stop new Cloud product dispatch; keep the current source state and outgoing rows so uncertain sends remain held rather than replayed. The inbound messages are ordinary Chatwoot history and need no replay.
