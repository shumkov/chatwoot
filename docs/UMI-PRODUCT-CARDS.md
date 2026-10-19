# Staff product share delivery

The bridge resolves Shopify product facts before calling the authenticated Chatwoot endpoint. Chatwoot verifies the current private staff command, account membership, conversation and exact product selection. The authenticated service user remains the outgoing row sender; the source note author is stored separately as `requested_by`.

`POST /api/v1/accounts/:account_id/umi/shopify/conversations/:display_id/product_shares` accepts `{source_message_id, facts}`. `GET` on the same route with `source_message_id` reads the existing operation. Responses contain `status`, `message_id` and a short `text`: `not_found`, `queued`, `held`, `accepted`, `rejected` or `ambiguous`. Accepted means Meta returned a message ID, not that the customer received or read the message. A persisted in-progress dispatch without an ID is ambiguous. POST serializes on the source note and reuses its outgoing row.

Configuration: `UMI_COMMERCE_BRIDGE_USER_ID` is required. `UMI_COMMERCE_ACCOUNT_ID` defaults to 1 and `UMI_COMMERCE_META_INBOX_ID` to 2. Public delivery is independently disabled until `UMI_PRODUCT_CARDS_FACEBOOK_ENABLED=true` or `UMI_PRODUCT_CARDS_INSTAGRAM_ENABLED=true`. Each flag requires its own owner-recipient canary before production activation.

Normal `SendReplyJob` selects the existing Facebook or Page-linked Instagram sender. Its product-card overlay makes exactly one generic-template provider call with standard RESPONSE messaging inside 24 hours of the latest customer message, without HUMAN_AGENT tags. The current source and attribution token are checked again before dispatch. It persists dispatch intent before calling Meta. Timeouts, unparseable results and missing IDs become ambiguous; duplicate jobs do not resend them. Native Instagram Login is outside this transport.

The existing Retry endpoint rejects queued, held, accepted and uncertain cards. Only definite Meta rejection can be retried, preserving product facts, attribution URL and requester; current source, activation and messaging-window checks still apply. Existing text and attachment send paths continue through their upstream implementation.

The same endpoint now accepts the configured Cloud WhatsApp inbox for a separately gated PDP image/text share; see [Cloud product shares](UMI-CLOUD-PRODUCT-SHARES.md). Native catalog cards still require verified WABA catalog association and exact retailer mapping. Draft creation remains a separate unit. No production sends or activation are part of local verification.

The production bridge reuses the existing administrator operator token. `UMI_COMMERCE_BRIDGE_USER_ID` restricts API callers; it does not prohibit that operator from issuing commands. Generated bridge notes carry `shumabit_bridge` and cannot trigger commerce commands. An unmarked note deliberately written with this shared operator credential is trusted as an operator action; this integration does not establish a separate bot permission boundary.
