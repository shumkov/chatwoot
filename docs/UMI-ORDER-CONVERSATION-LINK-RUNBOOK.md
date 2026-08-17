# Order-to-conversation link rollout

This patch is intentionally split across the Chatwoot fork, the Shopify app
configuration, and the published storefront theme. Only the Chatwoot fork is
changed by this commit. The Shopify app and theme changes below are human-run
deployment steps; this agent does not deploy them.

## Preflight

- Confirm the Shopify integration hook is enabled and its token can read orders.
- Confirm express checkout buttons are disabled for the canary storefront.
- Confirm the app's webhook configuration can add `orders/create` for the
  production shop and that the Chatwoot webhook URL is reachable.
- Set `UMI_SHOPIFY_ORDER_LINK_CANARY_HEARTBEAT` to the path watched by the
  existing Netdata app-check dead-man's switch. The default path is only a
  development fallback.
- Keep `UMI_SHOPIFY_ORDER_LINK_REWRITE_DISABLED=true` in the Chatwoot env while
  the storefront `_cw` capture snippet and the `orders/create` subscription are
  absent. Remove this opt-out only after both are live; removing it is the
  enablement step. Verify a new outgoing `umi.store` link carries `umi_cw` only
  after that coordinated rollout.

## Deploy sequence

1. Deploy the signed Chatwoot commit and run the migration. Verify the
   `umi_shopify_order_attributions` table and the low-queue canary cron.
2. In the Shopify app's version-controlled config, add an `orders/create`
   subscription pointing at the existing Chatwoot Shopify webhook endpoint:

   ```toml
   [[webhooks.subscriptions]]
   topics = ["orders/create"]
   uri = "https://<chatwoot-host>/webhooks/shopify"
   ```

   Use the production callback URL already used by the app rather than the
   placeholder above. Verify the active Shopify app version lists this topic
   after deployment.
   Keep the existing privacy subscriptions unchanged. Run `shopify app deploy`
   from the infra checkout after review; do not run that command as part of a
   Chatwoot code deploy.
3. Publish the storefront artifact in
   [`UMI-SHOPIFY-ORDER-LINK-STOREFRONT.md`](UMI-SHOPIFY-ORDER-LINK-STOREFRONT.md)
   and wire its explicit cart-mutation hooks.
4. Send one real storefront checkout from a Chatwoot outbound link. Confirm
   the order contains `_cw`, the webhook creates one `verified` row, and the
   canary heartbeat is touched.
5. Monitor the canary, application logs, exception tracker, and the ratio of
   `verified` to `unverified` rows for the first seven days.

## Rollback

- Stop new attribution at the storefront by removing the snippet or disabling
  its cart-mutation calls. Existing signed tokens expire after 30 days.
- Set `UMI_SHOPIFY_ORDER_LINK_REWRITE_DISABLED=true` and confirm new outgoing
  messages remain untagged while the service is investigated.
- Disable the canary with `UMI_SHOPIFY_ORDER_LINK_CANARY_DISABLED=true` and
  confirm the persisted cron is removed.
- Remove the `orders/create` subscription in the Shopify app config only after
  the Chatwoot webhook branch is no longer receiving deliveries.
- Keep existing attribution rows for reporting and compliance. Do not delete
  them as part of a code rollback; use the Shopify redaction path to detach
  customer links.

## Failure interpretation

`unlinked` orders are expected for unsupported checkout paths or orders made
without the cart carrier. `unverified` means the token was valid but the order
identity did not match the originating contact; it must never be forwarded to
Meta or Klaviyo. Transient database or Shopify failures return non-2xx so
Shopify/Sidekiq can retry; malformed, expired, replayed, account-mismatched,
and already-processed deliveries are terminal and acknowledged.

Shopify `customers/data_request` remains an explicitly manual export path. The
on-call operator must identify the Chatwoot contact from the Shopify customer
id, export both verified and candidate rows, attach the JSON export to the
compliance incident, and record the operator/deadline. The export query is:

```ruby
customer_id = ENV.fetch('SHOPIFY_CUSTOMER_ID')
contact = Contact.where("additional_attributes->>'shopify_customer_id' = ?", customer_id).first!
rows = Umi::ShopifyOrderAttribution.where(contact_id: contact.id)
  .or(Umi::ShopifyOrderAttribution.where(candidate_contact_id: contact.id))
puts JSON.pretty_generate(rows.as_json(except: %w[id account_id token_nonce webhook_id]))
```

Run it as `SHOPIFY_CUSTOMER_ID=123 bundle exec rails runner /path/to/export.rb`
from a controlled Chatwoot host, or paste the same body into `rails runner`.

Do not paste the output into application logs or external issue trackers.
