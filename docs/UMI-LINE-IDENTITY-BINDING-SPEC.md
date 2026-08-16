# UMI LINE identity binding

Status: reviewed design; implementation authorized by `DECISION.md`.

## Decision and calibrated threat model

This is a marketing opt-in, not account recovery. The production pattern used by LINE marketing
platforms commonly binds a form-captured email to the LINE identity immediately, then offers a
stronger email-link path for people who skip the first opportunity. This patch follows that pattern
and records the limitation honestly: a client-side form event proves that the browser submitted an
email, not that the caller controls the mailbox. An attacker who knows another person's email could
therefore cause their own LINE account to receive generic promotional messages. The flow must not
be used as authentication or for personalised order/payment content. A future confirmation step can
mark bindings as verified before those use cases are enabled.

The design was checked against [LITTLE HELP CONNECT's ID Sync description](https://www.littlehelp.co.jp/en/features),
which documents both dedicated email links and form integrations, and Crescendo Lab's
[MAAC Shopify member-binding flow](https://crescendolab.zendesk.com/hc/en-us/articles/31584415759385-Tutorials-MAAC-x-Shopify-member-data-binding-integration),
which uses email/phone verification for stronger membership binding and a LIFF page for the
remaining registration step. Those products confirm the two entry points and the distinction
between immediate marketing linkage and mailbox/member verification; UMI keeps this patch small
and implements the immediate linkage plus an email-entry link without inventing a second identity
database.

## Problem

The Klaviyo popup collects an email and then invites the visitor to add UMI's LINE Official
Account. A LINE `follow` webhook contains a LINE user ID but no email or popup attribution, so
the two identities cannot be joined. The same join must also work for a link in the Klaviyo
welcome email.

The binding is useful only when the LINE Login/LIFF user ID and the Messaging API webhook user ID
are from the same LINE provider. LINE documents that provider-scoped IDs are equal across LINE
Login and Messaging API channels only when the channels share a provider:
[LINE user IDs](https://developers.line.biz/en/docs/messaging-api/getting-user-ids/).

## Chosen design

The UMI Rails overlay owns the security-sensitive server path. The Shopify theme owns only the
browser integration. n8n is not in this path: it is not the right place for a low-latency browser
token exchange, atomic cross-container token consumption, or the LIFF HTML endpoint.

The overlay exposes three public routes. The root `/line-connect` name is deliberate: it is the
stable public endpoint URL entered in the LIFF console and copied into storefront/email links;
the implementation remains UMI-owned and the route is added by the initializer rather than by a
core Chatwoot route edit.

| Route | Purpose |
| --- | --- |
| `GET /line-connect?token=<token>` | Serve the LIFF page. The token is a short-lived bearer claim, not an email. |
| `POST /line-connect/token` | Accept the email from the Klaviyo form event and mint the personalised URL. It also provisions the email-entry capability used by the welcome email. |
| `POST /line-connect/bind` | Verify the raw LINE ID token at LINE, atomically consume the claim, and update Klaviyo. |

The endpoint and application code are UMI-owned and namespaced under `Umi::`; routes are added by
an idempotent `zz_umi_line_identity_binding.rb` initializer. The LIFF page is intentionally
served by this host because the server must keep the HMAC secret and Klaviyo private API key out
of the storefront. This is an exception to the general “glue does not go in the fork” preference:
the secret-bearing identity join is a backend capability, not storefront glue. The Shopify-side
snippet remains a separately copyable document and does not edit `umi-store-theme`.

### Data flow

1. Klaviyo dispatches its documented `klaviyoForms` browser event. The snippet listens for
   `stepSubmit` and uses `event.detail.metaData.email`; the documented `submit` event is also
   acceptable for a one-step email action. See [Klaviyo form activity using JavaScript](https://developers.klaviyo.com/en/docs/track_klaviyo_form_activity_using_javascript).
2. The snippet POSTs the email to `/line-connect/token` with a configured first-party `Origin`.
   The server normalises the email, generates a random nonce, stores `{email, expiry}` under a
   Redis key with a short TTL, and returns an HMAC-SHA256 token containing only `version` and
   nonce; expiry is enforced by the verifier and Redis TTL. The URL therefore contains neither
   a raw email nor a Klaviyo profile ID. The Redis claim also records `verified_email` so the
   downstream job can distinguish the popup and mailbox-link paths. In the same request it
   creates a separate random email-entry nonce with a longer, bounded TTL and
   queues a Klaviyo profile update that writes a `umi_line_connect_url` custom profile property
   containing `/line-connect?email_token=<nonce>`;
   this property is the only value the welcome email personalises.
3. The snippet replaces both the step-2 LINE button `href` and the QR image source with that
   personalised URL. QR generation is local in the browser; a QR vendor must not receive the
   bearer token.
4. When the page is opened with `email_token=<email-entry-nonce>` from the welcome email, the same page
   POSTs that opaque nonce to `/line-connect/token`. The server consumes it in Redis and returns a
   fresh fifteen-minute HMAC bind URL. The email template uses Klaviyo's documented
   `{{ person|lookup:'umi_line_connect_url' }}` profile-property syntax; it does not interpolate
   `{{ email }}` into a URL. See [Klaviyo personalization](https://help.klaviyo.com/hc/en-us/articles/4408810654235).
5. In the LIFF page, `liff.init()` is followed by `liff.login()` when the page is in an external
   browser. The page requests the linked OA friendship using the add-friend option where LINE
   supports it, then obtains `liff.getIDToken()`. The browser sends the raw ID token, not
   `getProfile()` or decoded profile fields. LINE explicitly documents server-side verification
   of the raw token through `POST /oauth2/v2.1/verify`:
   [Using user data in LIFF apps and servers](https://developers.line.biz/en/docs/liff/using-user-profile/)
   and [Verify ID token](https://developers.line.biz/en/docs/line-login/verify-id-token/).
6. The bind endpoint verifies the signed token, expiry, and Redis claim. It calls the Messaging API
   bot profile endpoint with the verified `sub`, proving that the user follows the configured OA
   through the same provider, then consumes the claim with the overlay's atomic Redis `GETDEL`,
   so two Rails/Sidekiq containers cannot win the same claim without changing the shared
   `Redis::Alfred` contract.
7. The server POSTs the ID token and the configured LINE Login channel ID to LINE's verify
   endpoint, checks the verified audience, issuer, expiry, fresh `iat`, and the `sub` format, and
   uses the returned `sub` and `name` only.
8. The server enqueues `Umi::Line::KlaviyoBindJob`, which updates the Klaviyo profile with
   `POST /api/profile-import` using the private
   server-side key and `profiles:write`. It writes:
   `line_user_id`, `line_display_name`, `line_bound_at`, `line_marketing_consent`,
   `line_consent_at`, `line_consent_source`, `line_consent_text_version`,
   `line_consent_text_sha256`, and `line_binding_verified`. The [Klaviyo profile import reference](https://developers.klaviyo.com/en/reference/create_or_update_profile)
   documents that omitted fields remain unchanged and that `profiles:write` is required. The bind
   response is `202 Accepted` (`{"status":"queued"}`), not a false synchronous success; the job
   has an explicit retry policy for 429/5xx/network failures and emits a final summary line when
   retries exhaust.

### Two entry points

The page accepts the same `token` claim whether its URL came from the popup button/QR or from a link
in the welcome email. The email template uses the per-profile `umi_line_connect_url` generated by
the mint endpoint; it must not put the email directly in the URL. The email-entry nonce is
single-use in Redis, contains no PII, and exchanges for the same fifteen-minute bind claim. A
welcome email link is still a bearer link and must be treated as sensitive. It should be sent
only after the business's normal email consent and deliverability flow.

## Security model

* The bind token uses the repository's existing `ActiveSupport::MessageVerifier` with
  `Rails.application.secret_key_base`, purpose `umi:line:binding`, and `expires_in`; it therefore
  has HMAC signing, constant-time verification, and purpose separation without another secret.
* The bind token carries no PII. Its Redis nonce record carries the normalised email and expires in
  fifteen minutes by default (`UMI_LINE_BINDING_TOKEN_TTL`). The email-entry nonce is also opaque and
  single-use, but has a bounded email-delivery TTL (`UMI_LINE_EMAIL_ENTRY_TTL`, default 30 days).
  Both URLs are bearer credentials:
  HTTPS, redacted Rails parameters, no query-string analytics, and no third-party QR service are
  required.
* Redis is used instead of `Rails.cache`, because this deployment's cache is a per-container
  FileStore. The overlay uses Redis 7.4+'s atomic `GETDEL` directly through its connection pool
  for single-use claims, specifically so the shared upstream `Redis::Alfred` contract remains
  untouched.
* The bind endpoint never trusts a LINE user ID or display name supplied by the browser. It sends
  the raw ID token to LINE and uses only the verified response. This follows LINE's anti-spoofing
  guidance.
* The token endpoint accepts only JSON POSTs from configured storefront origins and rejects a
  missing or unconfigured `Origin` before minting. It is protected by
  Rack Attack limits of 20 requests/hour per IP and 3 requests/day per normalized email. These
  controls reduce token minting abuse but do not prove that the caller controls the submitted mailbox.
  The initializer also adds `email` to Rails' global request-parameter filter; this intentionally
  redacts submitted addresses from application logs beyond this feature, while the token fields
  are already covered by the repository's token filter.
* Authorization limitation: a public client-side form event is not an email-ownership proof. Under
  the immediate-popup design, the brief's primary threat is not fully mitigated: a person who knows
  another person's email could request a claim and bind their own LINE account to that profile. This
  is accepted here as a marketing-opt-in risk, not an authentication guarantee. Unconfirmed bindings
  must not be used for order/payment details or other personalised sensitive content; a future
  mailbox-confirmation patch can promote `line_binding_verified` before those uses.
* LINE consent is not inferred from Klaviyo email consent. The page requires a checked, human-
  supplied PDPA consent statement before binding and records the consent fields above. Legal must
  supply and approve the Thai/English wording; this patch does not invent legal copy. Email
  suppression must be evaluated separately because it does not automatically suppress LINE sends.
* The server logs only stage, outcome, provider status, and a one-way claim fingerprint. It never
  logs email, ID tokens, or complete bearer URLs. Klaviyo/LINE failures produce a summary log line
  and an alertable `[UMI-LINE]` log pattern. Operations must alert on
  `stage=klaviyo_bind_failed`, `stage=line_verify_failed`, `stage=redis_failure`, and sustained
  absence of `stage=bound` while mint traffic is non-zero; Sentry and the Sidekiq dead set are not
  relied upon.

## Failure modes and behavior

| Failure | Behavior |
| --- | --- |
| Missing/invalid/expired/tampered token on bind | 409; no Klaviyo write. The GET page itself does not validate or consume it. |
| Missing/invalid/expired email-entry nonce | 409; no bind claim is minted. |
| Token replay or concurrent second bind | 409; the first claimant owns the claim. |
| Redis unavailable | 503; do not fall back to Rails.cache or process memory. Emit `[UMI-LINE] stage=redis_failure`. |
| LINE ID-token verification fails | 422 for invalid identity data, 503 for transient provider/transport failure; do not consume the claim for a rejected/expired LINE token, log a summary without token/email, and allow the page to retry within the short TTL. |
| Klaviyo returns 4xx | The job records a permanent failure, logs the status and response class, and does not retry. Operations use the alertable fingerprint to recover. |
| Klaviyo returns 429/5xx or network failure | The job retries with its explicit policy and logs a final alertable summary if exhausted. The endpoint has already returned `202`; no token replay path is opened. |
| LIFF login/friend prompt unavailable | Show a recoverable error and the configured OA follow link. Binding still uses the verified ID token when login succeeds. |
| QR generation fails in browser | Keep the personalised button link visible; do not replace it with a generic QR. |

The token is consumed after LINE accepts the raw ID token and before the external Klaviyo write.
This guarantees single-use without burning the claim on an invalid LINE token. The verified tuple
is handed to Sidekiq with an explicit retry policy, so a Klaviyo outage does not permanently lose
a successful LINE follow.

## Configuration

Required in production:

* `UMI_LINE_LOGIN_CHANNEL_ID` (the LINE Login channel that owns the LIFF app)
* `UMI_LINE_LIFF_ID`
* `UMI_LINE_OA_ADD_FRIEND_URL`
* `UMI_LINE_CONSENT_TEXT` (legal-approved wording; not supplied by this patch)
* `UMI_KLAVIYO_PRIVATE_API_KEY`
* `UMI_LINE_MESSAGING_CHANNEL_ACCESS_TOKEN` (the same-provider bot token used for runtime follow verification)
* `UMI_LINE_ALLOWED_ORIGINS` (comma-separated exact HTTPS storefront origins)
* `UMI_LINE_LIFF_SDK_SRI` (integrity hash for the pinned LIFF SDK)
* `UMI_LINE_BINDING_ENABLED=true` only after staging gates pass

Optional values have conservative local defaults only: token TTL fifteen minutes, email-entry TTL 30
days, and provider timeouts below the Rack::Timeout budget. The Klaviyo API revision is a code
constant in the UMI client and changes only with a reviewed patch. Missing configuration fails the
affected request with `503` and a summary log; it does not take down unrelated Chatwoot boot. No
provider ID, API key, or legal copy is committed.

## Alternatives rejected

* **Raw email in the URL:** exposes PII, is easy to retarget, and is replayable. Klaviyo's email
  personalization uses an opaque profile property instead.
* **Unsigned email + LINE user ID:** permits arbitrary profile retargeting and trusts spoofable
  browser data.
* **Rails.cache or a database token table:** Rails.cache is not cross-container here; a table adds
  migrations and cleanup for a short-lived ephemeral claim. Redis already exists and supports the
  required atomic primitive.
* **n8n:** useful for asynchronous workflow automation, but adds latency and a second place to
  protect the claim; it cannot serve the LIFF page or safely hold the browser-facing handoff alone.
* **Storefront-only:** cannot hold the Klaviyo private API key or HMAC secret and cannot verify the
  LINE ID token without exposing credentials.
* **Trusting `liff.getProfile().userId`:** LINE says not to send profile data from the LIFF app to
  the server; the raw ID token must be verified by LINE.
* **Generic OA QR code:** produces a follow webhook with no personalised claim and recreates the
  original attribution problem.

## Wire contracts

* `POST /line-connect/token` accepts JSON `{ "email": "person@example.com" }` with
  `Content-Type: application/json`. A popup request returns `200` and
  `{ "url": "https://host/line-connect?token=...", "email_entry_url": "https://host/line-connect?email_token=..." }`.
  A welcome-email exchange accepts `{ "email_token": "..." }` and returns `200` with only the
  short-lived `url`; that exchange sets `verified_email=true` on the resulting claim because
  possession of the mailbox link is stronger evidence. Invalid input/origin returns `422`/`403`;
  no claim is created.
* `GET /line-connect` never consumes Redis or validates the claim. It only renders the page with
  the opaque query value; `Cache-Control: no-store` and `Referrer-Policy: no-referrer` are set.
  Link scanners therefore cannot burn the claim. The page exchanges `email_token` by POST, then
  replaces the URL with the short-lived `token` form.
* `POST /line-connect/bind` accepts JSON `{ "token": "...", "id_token": "...", "consent": true }`.
  `consent` must be exactly true; client-supplied `line_user_id`/`display_name` fields are
  rejected/ignored. A valid verified LINE token returns `202` with `{ "status": "queued" }`.
  Invalid claim is `409`, invalid consent is `422`, LINE verification failure is `422`, and
  Redis/configuration failure is `503`.
* `POST https://api.line.me/oauth2/v2.1/verify` uses form fields `id_token` and `client_id`; the
  response must be a successful JSON object with issuer `https://access.line.me`, the configured
  audience, an unexpired `exp`, a fresh `iat`, a `sub` matching `U[0-9a-f]{32}`, and optional `name`.
* `POST https://a.klaviyo.com/api/profile-import` uses `Authorization: Klaviyo-API-Key ...`,
  `revision: 2026-07-15`, JSON:API `data.type=profile`, and the email plus the complete LINE
  property set. `200` and `201` are success; 429/5xx are transient job errors; other 4xx are
  permanent.
* The token query key is named `token`, not `t`, so the repository's existing parameter filter
  redacts it. Reverse-proxy access logs must also be configured not to retain query strings.
* The initializer adds a `Rack::Cors` resource for these POST/OPTIONS routes from the same
  `UMI_LINE_ALLOWED_ORIGINS` allowlist used by the controller. A configured-origin preflight is
  handled by Rack::Cors with a successful 200 response and matching allow headers; an
  unconfigured origin receives no allow headers and no mint.
  The origin is browser-supplied; it is a same-site hygiene control, not mailbox authentication.

## Independent review triage

* Findings 1–4 are fixed: the origin gate fails closed, patch 19 is registered, `consume!` has
  no test-only branch, and QR script loading is promise-memoized against observer re-entry.
* Finding 5 is fixed by removing unavailable Tailwind utility classes from the standalone page;
  the project forbids custom CSS, so the consent controls use accessible browser defaults.
* Finding 6 is fixed by using two-second LINE read timeouts, keeping the synchronous verification
  path within the shared request budget.
* Finding 7 is fixed with `no_follow: true` on every outbound request carrying provider credentials.
* Finding 8 is intentionally declined: global `email` parameter redaction is a deliberate privacy
  improvement for application logs and is documented above; narrowing it would expose submitted
  addresses in unrelated request logs.
* Finding 9 is fixed by ignoring the overlay's view directory as an autoload root.
* Finding 10 is intentionally declined: the existing wildcard Rack::Cors resource is active only
  for API-only/development modes, while production does not overlap this exact-origin resource;
  the controller remains the fail-closed security gate and the no-Origin spec protects that claim.
* Finding 11 is fixed by sending attacker-supplied identity fields in the request spec and asserting
  that the verified LINE `sub` still reaches the job.
* Finding 12 is fixed by including the copyable docs fixture in the normal Vitest test glob.
* Finding 13 is fixed in the data-flow, failure-mode, and CORS contract text above.
* Finding 14 is declined for this marketing-only flow: LINE display names are user-controlled and
  remain untrusted text; Klaviyo escapes profile values on render, and the runbook now records the
  constraint for future templates.

## Test and verification plan

RSpec covers:

1. MessageVerifier token expiry, purpose/tamper rejection, and absence of the email from the token.
2. Overlay `GETDEL` single-use behavior and sequential replay rejection; a real Redis integration
   race check is required before production because test doubles cannot prove cross-container
   atomicity.
3. LINE ID-token verification request, audience/issuer/expiry/sub validation, and rejection of a
   client-supplied user ID.
4. Klaviyo profile write payload, including LINE identity and explicit consent properties.
5. Controller responses for mint, bind, replay, bad input, provider failure, and CORS/origin
   rejection.
6. Failure isolation: LINE failures make zero Klaviyo requests; Klaviyo transient failures enqueue
   the explicit retry path and permanent failures do not retry. Tests assert requests and logs,
   not remote persistence after an ambiguous network timeout.
7. The copyable snippet is exercised by a small Vitest/jsdom fixture for event extraction,
   deduplication, exact mint request, button/QR replacement, local QR generation, and no QR-vendor
   request. The LIFF state machine is tested with mocked `window.liff`; device login/friendship
   behavior remains in the manual matrix.

The report records a new request spec written first and run red against the absent route, then green
after implementation, plus the exact targeted `bundle exec rspec` command and output. Manual verification is a
staging end-to-end test on iOS LINE app, Android LINE app, desktop QR, the popup entry point, and
the welcome-email entry point. Production rollout is gated on the runbook's same-provider check.

## Remove-when

Remove this patch when Chatwoot/UMI has a supported first-party Klaviyo↔LINE identity binding, or
when UMI moves this exact secret-bearing flow into a separately maintained identity service with
equivalent Redis single-use, LINE ID-token verification, consent recording, and operational
visibility. Do not remove merely because LINE or Klaviyo changes its UI; update the integration and
runbook at the next provider-version review.
