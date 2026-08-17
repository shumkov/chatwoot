# Shopify order-link storefront handoff

The Chatwoot deployment rewrites outbound `umi.store` links with the `umi_cw`
query parameter. Add the contents of
[`snippets/umi-order-link.js`](snippets/umi-order-link.js) to the published
theme's global JavaScript entry point. Do not copy it into Chatwoot's frontend.

The snippet captures and removes the URL parameter, keeps it in `localStorage`
for 30 days, and writes it to the Shopify cart as the `_cw` attribute. It also
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
exists. The current storefront has express checkout disabled.

## Verification

1. Open a real outbound Chatwoot message link in a fresh browser session.
2. Confirm `umi_cw` disappears from the address bar and the browser referrer is
   not sent to the storefront.
3. Add a product, inspect `/cart.js`, and confirm `attributes._cw` is present.
4. Change quantity, remove an item, clear the cart, and add again; confirm the
   attribute is still present after each operation.
5. Complete a normal storefront checkout and inspect the resulting order's
   sensitive `note_attributes` for `_cw`.
6. Confirm a disabled express-checkout path does not produce an attributed order.
