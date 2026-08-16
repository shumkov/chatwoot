# UMI LINE identity binding — completion report

## Result

Implemented the UMI-owned LINE↔Klaviyo marketing opt-in flow. A Klaviyo form submission
mints an opaque, signed, Redis-backed claim; the LIFF page verifies the raw LINE ID token
and same-provider Official Account friendship; and a Sidekiq job writes the verified LINE
identity and explicit LINE consent properties to the Klaviyo profile.

The flow has two entry points:

- The popup path binds immediately as `line_binding_verified=false`, because a browser form
  event is not mailbox proof.
- The welcome-email path exchanges a single-use email-entry nonce and produces a claim with
  `line_binding_verified=true`.

The popup path is deliberately limited to generic marketing. It must not be used for
authentication, order/payment details, personalised sensitive content, or account recovery.

## Research and decision

The design and implementation are recorded in
[`UMI-LINE-IDENTITY-BINDING-SPEC.md`](UMI-LINE-IDENTITY-BINDING-SPEC.md). The research covered:

- Klaviyo’s documented `klaviyoForms` `stepSubmit`/`submit` browser events and
  `detail.metaData.email`: [Track Klaviyo form activity using JavaScript](https://developers.klaviyo.com/en/docs/track_klaviyo_form_activity_using_javascript).
- Klaviyo profile import and `profiles:write`: [Create or update profile](https://developers.klaviyo.com/en/reference/create_or_update_profile).
- Klaviyo profile-property personalization: [Klaviyo lookup syntax](https://help.klaviyo.com/hc/en-us/articles/4408810654235).
- LINE’s provider-scoped user-ID rule, LINE Login/OA linking, LIFF profile handling, and raw
  ID-token verification: [LINE user IDs](https://developers.line.biz/en/docs/messaging-api/getting-user-ids/),
  [link a bot](https://developers.line.biz/en/docs/line-login/link-a-bot/),
  [LIFF user profile](https://developers.line.biz/en/docs/liff/using-user-profile/), and
  [verify ID token](https://developers.line.biz/en/docs/line-login/verify-id-token/).
- Industry patterns: [LITTLE HELP CONNECT](https://www.littlehelp.co.jp/en/features) documents
  dedicated email links and form-to-LINE ID sync; [Crescendo Lab MAAC member binding](https://crescendolab.zendesk.com/hc/en-us/articles/31584415759385-Tutorials-MAAC-x-Shopify-member-data-binding-integration)
  uses stronger email/phone verification for membership binding before the LIFF step.

The chosen pattern follows the common marketing implementation: immediate provisional linkage,
with a stronger mailbox-link entry point available for confirmation. The backend lives in the
`umi/` overlay because it holds the signing secret, Redis claim state, LINE verification calls,
Klaviyo private key, and Sidekiq retry/alert behavior. The storefront receives only a copyable
snippet and configuration instructions; the Shopify theme repository was not edited.

## Delivered implementation

- `config/initializers/zz_umi_line_identity_binding.rb`
  - idempotent routes for `/line-connect`, `/line-connect/token`, and `/line-connect/bind`;
  - parameter filtering, exact-origin CORS, and Rack Attack token/bind limits.
- `umi/app/services/line/`
  - configuration with production-required secrets and conservative TTLs;
  - MessageVerifier token mint/exchange/peek/consume/restore;
  - LINE raw ID-token and same-provider OA friendship verification;
  - Klaviyo JSON:API profile import with transient/permanent error classification.
- `umi/app/controllers/line_connect_controller.rb` and
  `umi/app/views/line_connect/show.html.erb`
  - nonce-bound CSP, no-store headers, explicit consent, LIFF login/friendship handling,
    and retryable browser error states.
- `umi/app/jobs/line/`
  - asynchronous Klaviyo binding and email-entry-property provisioning;
  - explicit retry policies beyond the global Sidekiq retry limit and alertable final logs.
- `umi/app/services/line/token_service.rb`
  - atomic Redis `GETDEL` consumption in the overlay, leaving the shared upstream Redis helper
    unchanged.
- `docs/UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.js`
  and [`UMI-LINE-IDENTITY-BINDING-STOREFRONT-INSTRUCTIONS.md`](UMI-LINE-IDENTITY-BINDING-STOREFRONT-INSTRUCTIONS.md)
  - Klaviyo event listener, deduplicated token mint, personalized button rewrite, and local
    QR generation with a pinned QRCode.js URL and SRI.
- `UMI-PATCHES.md`
  - patch 19 records the UMI-owned surface and remove-when condition; patch 18 is reserved for
    the rebased LINE dual-consumer patch.

## Security and operational boundaries

Claims contain no email in the URL and expire after 15 minutes by default. Email-entry links
are opaque, single-use Redis capabilities with a 30-day default delivery TTL. Atomic Redis
`GETDEL` prevents two containers from consuming the same claim; a real cross-container Redis
race check remains a staging gate. LINE user IDs and display
names come only from LINE’s verified response; browser-supplied identity fields are ignored.

The implementation records LINE consent separately from Klaviyo email consent, including the
approved consent-text version and SHA-256 digest. It does not invent legal wording. The popup
form event remains a residual mailbox-ownership risk: someone who knows another person’s email
could cause their own LINE account to receive generic promotional messages. The welcome-email
path reduces that risk, but its URL remains a bearer credential. Klaviyo profile import can also
create/update a profile and the long-lived email-entry URL is stored as a profile property;
the runbook therefore requires a flow delay/property-present condition, click-tracking review,
HTTPS, query-string redaction, and a retention/privacy decision.

Durable conflict resolution, withdrawal/unfollow deactivation, and a separate confirmation
workflow for sensitive personalization remain follow-up work. Rollback is the documented
`UMI_LINE_BINDING_ENABLED=false` switch plus disabling the storefront snippet; no external
systems were changed during this task.

## Review and verification

The branch was rebased onto `umi` at `065bf6256`; patch 19 is now registered after the existing
LINE dual-consumer patch 18. The required research → spec → multi-agent spec review →
implementation → multi-agent code review sequence was completed. The origin gate was tightened
to fail closed, and the initially staged core Redis edit remains absent: single-use consumption
uses overlay-local Redis `GETDEL`, preserving the upstream contract. Review findings that changed
the implementation included CSP
nonce ordering, same-origin browser requests, Redis WATCH cleanup, token freshness, provider
429/5xx classification, async Klaviyo provisioning, SRI-pinned QR loading, bind throttling,
email-entry verification state, enqueue-failure claim restoration, fail-closed origin checking,
provider redirect blocking, bounded QR loading, and stylesheet-independent functional visibility.
The independent review's declined findings and their reasons are recorded in the spec's triage
section; the remaining manual gate is real cross-container Redis verification.

TDD evidence for the request path:

```text
# Before the route/controller implementation
1 example, 1 failure
expected 200 but got 404

# After implementation and final fixes
Finished in 0.60331 seconds
14 examples, 0 failures
```

Final backend command:

```text
bundle exec rspec \
  spec/requests/umi_line_identity_binding_spec.rb \
  spec/requests/umi_line_identity_binding_bind_spec.rb \
  spec/services/umi/line/token_service_spec.rb \
  spec/services/umi/line/identity_client_spec.rb \
  spec/services/umi/line/klaviyo_client_spec.rb
```

The rework verification added the no-Origin regression and finished with `15 examples, 0 failures`.
RuboCop passed with `13 files inspected, no offenses detected`; `node --check` passed for both
storefront JavaScript files. The Vitest fixture at
`docs/UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.test.js` passes in the normal test glob
(`2 tests`) after the exact docs fixture was added to `vitest.config.ts`.

Before production, the runbook still requires a real Redis cross-container check, same-provider
LINE console construction, published LIFF configuration, iOS/Android/desktop QR tests, a first
exact webhook `source.userId` comparison, Klaviyo flow verification, and provider failure drills.
