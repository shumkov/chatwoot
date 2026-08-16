# Storefront installation

Do not edit the `umi-store-theme` repository from this patch. Copy
`UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.js` into the theme's approved custom JavaScript
location and configure the endpoint before the Klaviyo form listener runs:

```html
<script>
  window.UMILineIdentityBinding = {
    backendBase: 'https://<chatwoot-host>'
  };
</script>
<script src="/path/to/umi-line-identity-binding-snippet.js" defer></script>
```

Add these attributes to the step-2 custom HTML that Klaviyo renders:

```html
<a data-umi-line-button href="https://line.me/">Add UMI on LINE</a>
<img data-umi-line-qr alt="Scan to connect UMI on LINE" width="256" height="256">
```

The listener accepts Klaviyo's `stepSubmit` and one-step `submit` events, ignores events without
`detail.metaData.email`, normalises and de-duplicates the email in memory, then rewrites both
targets to the same personalised URL. It uses a bounded `MutationObserver` because Klaviyo may
render the next step after dispatching the event. QR generation is local through the pinned
QRCode.js browser bundle with a fixed SRI hash; the token is not sent to a QR service. If the
storefront mirrors the bundle locally, preserve the pinned version or update the hash as a reviewed
dependency change.
