# Shopify order-link storefront handoff

The Chatwoot deployment rewrites outbound `umi.store` links with the `umi_cw`
query parameter. Add the contents of
[`snippets/umi-order-link.js`](snippets/umi-order-link.js) to the published
theme's global JavaScript entry point. Do not copy it into Chatwoot's frontend.

The snippet captures and removes the URL parameter, keeps it in `localStorage`
for 30 days, and writes it to the Shopify cart as the private `__cw` attribute.
The double underscore is Shopify's privacy marker: the attribute still reaches the
order, but it cannot be read back from Liquid or the Ajax API, so no other app on
the shop origin can lift the token out of `/cart.js`. It also
reapplies the value on page load and before add-to-cart submits. It intentionally
does not make a checkout API call: the Shopify cart carries the attribute into
`orders/create` as `note_attributes`.

Configure the storefront response with `Referrer-Policy: no-referrer` as well.
The snippet's meta tag is defense in depth, but it cannot change the referrer on
the initial HTML request that carried the token.

After installing the global snippet, wire the exposed
`window.UmiOrderLink.reapply()` into every cart mutation that replaces or clears
cart state:

- `assets/product-form.js` add-to-cart success;
- `assets/cart.js` quantity, remove-item, clear-cart, and cart-update success;
- `assets/quick-add-bulk.js` bulk-add success;
- `assets/quick-order-list.js` quick-order-list success; and
- the direct `/cart/add.js` call in
  `blocks/ai_gen_block_31f9fa1.liquid`, after its successful response.

Each hook must await its add/update/clear response before calling `reapply()`;
the order is `cart/clear` → successful response → attribute reapply. This is
deliberate: a submit-time call alone races the theme's asynchronous cart write.

Use the theme's locale-aware `window.Shopify.routes.root` when calling Shopify
endpoints. Do not use a hard-coded `/cart/update.js` path. Express checkout,
Shop Pay, Apple Pay, Google Pay, PayPal, Shop app, draft, and POS flows bypass
this cart carrier by design; they must remain unlinked until a supported carrier
exists. **The storefront does not have express checkout disabled** — contrary to what this doc and
the runbook said until now. `show_dynamic_checkout: true` is set in five product/landing templates in
`umi-store-theme`, so "Buy it now" and the wallet buttons are live on product pages and bypass the
cart entirely. That is the largest coverage gap in this design, and it must be sized from the Shopify
Analytics split between accelerated-PDP and cart checkouts before anyone reads `__cw` coverage as a
conversion rate.

## Verification

1. Open a real outbound Chatwoot message link in a fresh browser session.
2. Confirm `umi_cw` disappears from the address bar and the browser referrer is
   not sent to the storefront.
3. Add a product and inspect `/cart.js`. `attributes.__cw` must be **absent** —
   a private attribute is unreadable there by design, so seeing it would mean the
   name lost its double underscore and the token is exposed to every app on the
   origin.
4. Change quantity, remove an item, clear the cart, and add again.
5. Complete a normal storefront checkout and confirm `__cw` is in the resulting
   order's `note_attributes`, both on the order page and in the `orders/create`
   webhook payload. This is the only place the carrier can be observed, and it is
   the step that proves a private attribute survives to the order at all.
6. Place one order through a "Buy it now" button and confirm it arrives **unattributed** —
   that path skips the cart, so no carrier exists to copy. It is an expected miss, not a bug.
