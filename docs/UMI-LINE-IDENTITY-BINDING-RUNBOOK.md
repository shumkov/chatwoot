# UMI LINE identity binding runbook

## Stop condition: same provider

Create the LINE Login channel inside the exact LINE Developers provider that owns the Messaging
API channel `2010611374` and UMI's Official Account. Do not create a new provider and do not try to
repair this later by configuration: LINE user IDs match across Login and Messaging API channels
only within one provider. If this step is wrong, stop and recreate the Login channel and LIFF app
before collecting any bindings.

## 1. LINE Developers Console

1. Open the provider that owns Messaging API channel `2010611374`; record the provider identity and
   confirm the linked OA. The same-provider requirement is documented by [LINE's user ID guide](https://developers.line.biz/en/docs/messaging-api/getting-user-ids/).
2. Create a LINE Login channel under that provider. Record its channel ID. Keep the channel secret
   in the deployment secret store; this flow verifies LIFF ID tokens through LINE and does not put
   the secret in the browser.
3. Link the UMI Messaging API channel/OA to the LINE Login channel. The linked OA is what lets the
   LIFF flow offer add-friend behavior; see [Link a bot to a LINE Login channel](https://developers.line.biz/en/docs/line-login/link-a-bot/).
4. Create a LIFF app on the Login channel with:
   - endpoint URL: `https://<chatwoot-host>/line-connect`;
   - size: Full;
   - scopes: `openid` and `profile`;
   - the current pinned LIFF SDK URL from the backend configuration.
5. Keep the LIFF ID and the Login channel ID together in the deployment secret/config store. Compute
   and record the SHA-384 integrity value for the exact pinned SDK file as
   `UMI_LINE_LIFF_SDK_SRI`.
6. Before launch, switch the Login channel from Developing to Published. Developing channels work
   only for channel admins/testers; LINE documents that publishing is irreversible. Standard LIFF
   use does not require a separate app-review submission, but the operator must re-check the current
   console policy before publishing.
7. Verify the OA add-friend URL manually and store it as `UMI_LINE_OA_ADD_FRIEND_URL`.

## 2. Backend configuration

Set these values in the runtime secret/config system. Never commit them or place them in the theme:

```text
UMI_LINE_BINDING_ENABLED=false
UMI_LINE_PUBLIC_BASE_URL=https://<chatwoot-host>
UMI_LINE_LIFF_URL=https://liff.line.me/<liff-id>
UMI_LINE_LOGIN_CHANNEL_ID=<line-login-channel-id>
UMI_LINE_LIFF_ID=<liff-id>
UMI_LINE_MESSAGING_CHANNEL_ACCESS_TOKEN=<channel-2010611374-access-token>
UMI_LINE_OA_ADD_FRIEND_URL=<verified-oa-add-friend-url>
UMI_LINE_ALLOWED_ORIGINS=https://<shopify-storefront-origin>
UMI_LINE_CONSENT_TEXT=<legal-approved-consent-copy>
UMI_LINE_CONSENT_TEXT_VERSION=<approved-version>
UMI_LINE_LIFF_SDK_SRI=<sha384-for-pinned-sdk>
UMI_KLAVIYO_PRIVATE_API_KEY=<profiles-write-private-key>
```

The Klaviyo API revision is pinned in code as `2026-07-15`; it is not an environment override.
The bind token defaults to 15 minutes and the welcome-email entry token to 30 days. Keep the
public base URL and LIFF URL HTTPS, verify `FORCE_SSL`/HSTS at the edge, and configure the reverse
proxy not to retain bearer query strings in access logs. Rails filters `token`, `email_token`,
`id_token`, and `email`, but edge logs need their own query policy.

The endpoint uses Redis, not `Rails.cache`, for claims. Confirm the production Redis service is
reachable and record its version during staging verification; the overlay consumes claims with
atomic Redis `GETDEL` and does not change the shared `Redis::Alfred` helper.

## 3. Klaviyo

1. Confirm the popup's step-1 form emits the documented `klaviyoForms` `stepSubmit` event with
   `detail.metaData.email`; the snippet also accepts the one-step `submit` event. The reference is
   [Track Klaviyo form activity using JavaScript](https://developers.klaviyo.com/en/docs/track_klaviyo_form_activity_using_javascript).
2. Add a step-2 custom HTML block containing one `data-umi-line-button` link and one
   `data-umi-line-qr` image. Copy the provided storefront instructions and snippet into the
   approved theme location; do not send the token to a QR vendor.
3. In the welcome flow, add a button whose URL is the profile property:

   ```liquid
   {{ person|lookup:'umi_line_connect_url' }}
   ```

   Use the documented [Klaviyo profile-property lookup syntax](https://help.klaviyo.com/hc/en-us/articles/4408810654235).
   Disable click tracking for this bearer link if the account's tracking layer would expose its
   query string to a third party. Add a short flow delay or a condition that the property is
   present: the backend queues this profile-property write so a provider outage cannot break the
   popup handoff.
4. Keep the existing email consent/deliverability flow. The LINE checkbox is separate and must be
   unticked by default; legal must provide the Thai/English wording and approve the recorded
   version. Klaviyo's native email suppression does not govern LINE marketing.

## 4. Staging verification

1. With `UMI_LINE_BINDING_ENABLED=false`, verify the routes return the disabled response and no
   provider calls occur. Then enable only in staging.
2. Submit a real staging popup form. Verify the button and QR encode the same personalised URL,
   the URL contains no email, and a repeated `stepSubmit` does not mint repeatedly. Verify QR
   generation stays local.
3. Test iOS LINE app, Android LINE app, desktop QR via the LINE QR scanner, and a normal desktop
   browser. Confirm LIFF login uses the expected channel, the OA follow prompt/link works, the
   consent checkbox is required server-side, and the bind response is `202`.
4. In the LINE webhook payload, compare `source.userId` with the Klaviyo `line_user_id`. The first
   staging bind must match exactly; if it does not, stop because the provider construction is wrong.
5. Open the welcome-email property link in a fresh browser/device. Confirm the long-lived email
   entry token exchanges once for a fresh short token, then the same bind checks run. Confirm a mail
   scanner or repeated click cannot consume the short claim via GET.
6. Stub or observe provider failures in staging: LINE 4xx must not consume the claim or call
   Klaviyo; Klaviyo 429/5xx must be retried by `Umi::Line::KlaviyoBindJob` and emit a final
   `[UMI-LINE] stage=klaviyo_bind_failed` line if exhausted.
7. Check logs for only stage, outcome, provider status, and fingerprints. Alert on
   `[UMI-LINE] stage=line_verify_failed`, `stage=klaviyo_bind_failed`, `stage=redis_failure`,
   and zero `stage=bound` while mint traffic is non-zero. This fork's Sentry DSN and Sidekiq dead
   set are not alert receivers; connect the log pattern to the host's operational log monitor.

## 5. Production rollout

1. Verify the same-provider, Published-channel, LIFF scope, HTTPS, reverse-proxy, secret, Redis,
   and Klaviyo checklist again immediately before launch.
2. Deploy the backend with binding disabled. Copy the snippet/theme configuration only after the
   backend route and health checks are ready.
3. Enable `UMI_LINE_BINDING_ENABLED=true`, then exercise one controlled internal form and both
   entry points. Verify the first production `line_user_id` against its LINE follow webhook.
4. Monitor the alert patterns and the mint-to-bound ratio for the first campaign window. Generic
   marketing is the only approved use for the immediate popup binding. Do not use
   `line_binding_verified=false` profiles for order, payment, account, or other personalised
   sensitive content.

## 6. Rollback and privacy

Set `UMI_LINE_BINDING_ENABLED=false` to stop new mint/bind requests, then remove or disable the
storefront step-2 snippet. Existing Klaviyo properties are not deleted by rollback; decide whether
to retain or remove them under the approved retention policy. Rotating `secret_key_base` invalidates
all outstanding bind tokens and is a valid emergency revocation action, but affects every
MessageVerifier in the application.

The Redis claim contains a normalised email only until its TTL; the URL contains an opaque bearer
token. The Klaviyo profile receives the LINE ID, display name, timestamps, consent source, consent
text version/hash, and `line_binding_verified` (false for the popup path, true for the
mailbox-link path). The privacy notice must name LINE and Klaviyo,
the cross-border transfer/processor role, the retention period, and the fact that LINE marketing
consent is separate from email suppression. A future withdrawal/unfollow workflow must set the
LINE binding to inactive and prevent subsequent LINE sends; this patch does not silently claim that
email suppression or an unfollow webhook already does that for Klaviyo. LINE display names are
user-controlled text; keep them escaped when introducing them into future templates.
