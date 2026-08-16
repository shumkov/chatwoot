# Independent review — LINE identity binding (`c7d90e8cb`)

Scope: `git diff umi...feat/line-identity-binding` (21 files, +1718). Two lenses: security of a
public endpoint, and fork fit. Every claim relied on below was checked against the file, and the
load-bearing ones were executed.

**Merge verdict: no, not as-is.** One MUST-FIX (the origin gate does not do what the spec and the
report say it does — proven by a run, below) and one fork-rule gap (patch 18 is missing from the
`UMI-PATCHES.md` registry table). Everything else is SHOULD-FIX/CONSIDER and does not block once
those two land.

## What I verified rather than took on trust

| Claim | Source | Result |
| --- | --- | --- |
| No core upstream file is touched | brief / fork rule 1 | **True.** `git diff umi...HEAD -- lib app config enterprise` returns exactly one file: `config/initializers/zz_umi_line_identity_binding.rb`. The reverted `lib/redis/alfred.rb` edit is gone; `Redis::Alfred.set(…, nx:, ex:)` and `.with` already exist upstream (`lib/redis/alfred.rb:10,24`), so the overlay compiles against the stock helper. |
| "14 examples, 0 failures" | `REPORT.md:127` | **True.** Re-ran the five files: `14 examples, 0 failures`. |
| Token contains no email | `SPEC.md:123`, `REPORT.md:73` | **True.** Decoded a real minted token: payload is `{"v":1,"nonce":…}` only. |
| Claim is consumed only after LINE accepts, before Klaviyo | `SPEC.md:169` | **True.** `line_connect_controller.rb:39-42`. |
| Atomic single-use via `GETDEL` on the shared pool | `REPORT.md:62-63` | **Code true** (`token_service.rb:79-85`), **but never executed as written** — see SHOULD-FIX 2. |
| "accepts only … from configured storefront origins" | `SPEC.md:135`, `SPEC.md:219`, `REPORT.md:48` | **False.** See MUST-FIX 1. |
| Route reachable at the root path | `SPEC.md:43-46` | **True.** `routes.append` lands after the whole upstream table and `config/routes.rb` has no catch-all; `GET /line-connect` returns 200 in the request spec. No upstream owner of `/line-connect`. |

Also correct and worth keeping: no Chatwoot DB write anywhere in the flow; SSRF is closed because
`user_id` is validated against `/\AU[0-9a-f]{32}\z/` (`identity_client.rb:73`) *before* it is
interpolated into the profile URL (`:45`); the Klaviyo key and the messaging token never reach the
rendered page; logs carry only stage/outcome/status and a SHA-256 fingerprint.

---

## MUST-FIX

### 1. The origin gate fails open when the `Origin` header is absent — and both the spec and the report claim the opposite

`umi/app/controllers/line_connect_controller.rb:81`

```ruby
return false if origin.blank? || allowed.include?(origin)
```

A blank Origin returns `false` from `reject_origin!`, which the callers read as "not rejected", so
the request proceeds. `ApplicationController` disables CSRF for the whole app
(`app/controllers/application_controller.rb:8`), so this header check is the *only* caller
restriction on the mint endpoint.

Proven, not inferred — a request spec run against this tree with no `Origin` header at all:

```
POST /line-connect/token  {"email":"victim@example.com"}      -> 200
{"url":"https://chatwoot.example/line-connect?token=eyJfcmFpbHM…",
 "email_entry_url":"https://chatwoot.example/line-connect?email_token=djz-ci9iKOCj…"}

POST /line-connect/bind   {"token":"x","id_token":"y","consent":true} -> 409 (invalid claim)
                                                    i.e. it passed the origin gate and reached
                                                    claim validation, it was not rejected at 403
```

The contradicted claims — this is the top finding the brief asked for:

- `docs/…SPEC.md:135` — "The token endpoint accepts only JSON POSTs from configured storefront origins".
- `docs/…SPEC.md:219` — "Invalid input/origin returns `422`/`403`; no claim is created."
- `docs/…REPORT.md:48` — "parameter filtering, **exact-origin CORS**, and Rack Attack token/bind limits."

CORS is browser-enforced and cannot substitute; `curl` never sends `Origin`.

Impact, judged at the stated marketing bar rather than a banking bar:

1. `POST /line-connect/token` is a fully unauthenticated **Klaviyo profile-import primitive for
   arbitrary email addresses**. Each mint enqueues `Umi::Line::KlaviyoProvisionEmailEntryJob`
   (`token_service.rb:28-32`), which creates or updates a Klaviyo profile and writes
   `umi_line_connect_url` onto it. That is list pollution, potential flow triggering, and billable
   volume in UMI's Klaviyo account, from anywhere on the internet at 20/h/IP.
2. It also overwrites a *legitimate* customer's `umi_line_connect_url` with an attacker-minted
   bearer link, invalidating the real welcome-email link for that profile.
3. The targeted mis-binding the threat model accepts becomes storefront-independent: the attacker
   no longer needs the popup at all, only the victim's address, bounded by 3/day/email.

Fix (small, and it makes the spec's sentence true):

```ruby
def reject_origin!(allow_public: false)
  origin = request.headers['Origin'].to_s
  allowed = Umi::Line::Config.allowed_origins
  allowed << URI.parse(Umi::Line::Config.public_base).origin if allow_public && Umi::Line::Config.public_base.present?
  return false if allowed.include?(origin)

  render json: { error: 'origin_not_allowed' }, status: :forbidden
  true
end
```

Then pin it: `spec/requests/umi_line_identity_binding_spec.rb:46` only tests
`Origin: https://evil.example`, which is exactly why this survived. Add a no-Origin example
asserting 403 and asserting no job was enqueued. (If some non-browser caller genuinely needs to
mint, that caller needs a shared secret, not a hole in the header check.)

---

## SHOULD-FIX

### 2. `UMI-PATCHES.md` has no registry row for patch 18

`UMI-PATCHES.md:6-23` is the registry table (`| # | Patch | Files | Why | Remove when |`); it ends
at patch 17. Patch 18 exists only as prose under "Patch details" (`UMI-PATCHES.md:370-386`). Golden
rule 3 in `CONTRIBUTING-UMI.md:13` is a row in the registry — every other live patch has one, and
the table is what a future rebase reads. Add the row.

Two smaller defects in the prose block while you are there:

- `UMI-PATCHES.md:385` lists the specs as `spec/{requests,services}/umi/line/`. The request specs
  are actually at `spec/requests/umi_line_identity_binding_spec.rb` and
  `spec/requests/umi_line_identity_binding_bind_spec.rb` — nothing lives at `spec/requests/umi/line/`.
- The remove-when (`:379-380`) is real but circular ("remove when UMI has a first-party binding").
  A checkable trigger would be better: *remove when Klaviyo ships a native LINE identity property,
  or when the LINE Login channel is retired.*

### 3. The `Rails.env.test?` branch in `consume!` is unreachable dead code

`umi/app/services/line/token_service.rb:79-91`

```ruby
return test_consume(conn, key) if Rails.env.test? && !conn.redis.respond_to?(:getdel)
```

Measured in this tree: `CONN=Redis::Namespace INNER=MockRedis GETDEL=true`. `mock_redis 0.36.0`
implements `getdel`, so the guard is always false and `test_consume` (`:87-91`) can never run.
It is both an env-conditional in a production path (`CLAUDE.md`: build for the production path;
remove dead code) and a false comfort — a reader assumes the specs exercise a fallback.

Delete both the guard and `test_consume`. `consume!` should also be private to the module rather
than a public module function.

Related and worth stating plainly: because MockRedis backs `$alfred` in test
(`config/initializers/01_redis.rb:10`), the atomicity guarantee the whole single-use design rests
on is asserted against a single-process in-memory double. `SPEC.md:250-252` promises a "race
simulation"; `spec/services/umi/line/token_service_spec.rb:25-33` is a sequential double-consume.
The runbook's real-Redis check (`RUNBOOK.md:59-61`) is therefore not optional — say so in the
report instead of "Redis compare-and-delete prevents two containers from consuming the same claim"
(`REPORT.md:74-75`), which reads as verified.

### 4. Storefront snippet: the MutationObserver and the QR loader feed each other unbounded `<script>` appends

`docs/UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.js:11-22` and `:44-50`

`observeStepTwo` watches `document.documentElement` with `{childList: true, subtree: true}` and
calls `renderUrl` on every mutation. `renderUrl` calls `loadQr`, which — until `window.QRCode` is
set — does `document.head.appendChild(script)`. That append is itself a childList mutation inside
the observed subtree, so the callback re-fires and appends another copy of the CDN script, in a
microtask loop, for the whole network round-trip of the first load. On a slow connection that is
hundreds of duplicate `<script>` tags on the storefront.

The Vitest fixture never catches it because it pre-assigns `window.QRCode`
(`…SNIPPET.test.js:22-30`), taking the early-return branch.

Fix: memoise one promise at module scope —

```js
let qrPromise = null;
const loadQr = () => (qrPromise ||= new Promise((resolve, reject) => { /* … */ }));
```

and, for good measure, `observer.disconnect()` around the DOM writes or scope the observer to the
Klaviyo form container rather than `documentElement`.

### 5. The consent page ships with no stylesheet

`umi/app/views/line_connect/show.html.erb:11-22` uses Tailwind utility classes, but the template
emits no `<link rel="stylesheet">`, and no layout wraps it (there is no
`app/views/layouts/application.html.erb` in this repo, only `vueapp`/`portal`), so nothing supplies
those classes. `style-src 'self'` (`line_connect_controller.rb:132`) consequently guards nothing.
`REPORT.md:100` calls this "stylesheet-independent functional visibility", which is true about
*function* but means the PDPA consent screen — the one legally-load-bearing page in the flow —
renders as unstyled default HTML on a customer's phone.

Pick one and be explicit: inline a small `<style nonce="<%= nonce %>">` block (and add
`'nonce-…'` to `style-src`), or drop the Tailwind classes so the file does not imply styling that
is not there.

### 6. A LINE brown-out occupies Chatwoot's shared Puma threads

`umi/app/services/line/identity_client.rb:26-27` and `:47-48` — two *sequential* provider calls per
bind, each `open_timeout: 2, read_timeout: 4`, so a worst-case bind holds a request thread for
~12 s against a rack-timeout budget of 15 s (`config/initializers/rack_timeout.rb`, gem default).
The bind throttle is 30/h/IP (`zz_umi_line_identity_binding.rb:34-36`) and unbounded across IPs.
That is the brief's failure-isolation question: yes, a LINE outage can degrade unrelated Chatwoot
traffic, because these routes share the app's Puma pool.

Cheapest fix: drop `read_timeout` to 2 s on both calls. Better: verify the ID token synchronously
(it is what gates consumption) and move `verify_friendship!` into `Umi::Line::KlaviyoBindJob`,
which already has a retry policy.

---

## CONSIDER

### 7. HTTParty follows redirects, and all three outbound calls carry a secret in a header

`identity_client.rb:22,44` (`Authorization: Bearer <messaging channel token>`) and
`klaviyo_client.rb:34-40` (`Authorization: Klaviyo-API-Key …`). HTTParty follows redirects by
default and re-sends headers. The hosts are constants over TLS so this is not currently
exploitable, but `no_follow: true` costs one line per call and removes a whole class of
credential-replay-to-another-host.

### 8. The parameter filter change is fork-wide and only one of its four entries is new

`config/initializers/zz_umi_line_identity_binding.rb:9` adds `%i[email token email_token id_token]`.
`config/initializers/filter_parameter_logging.rb:11` already filters every key matching `/token/i`
(minus `website_token`), so `token`, `email_token` and `id_token` are redundant. The only new
behaviour is `:email`, which redacts the `email` parameter from request logging **everywhere** —
login, signup, contact APIs, not just this feature.

I checked whether this also leaks into `ActiveRecord::Base.filter_attributes` (Rails wires the two
together at `activerecord-7.1.5.2/lib/active_record/railtie.rb:359-363`): it does not — measured
`ActiveRecord::Base.filter_attributes == []`, because AR loads before `config/initializers`. So the
blast radius is logs only. Still, either narrow it to `%i[email_token]` or state the app-wide log
change in the patch row so the next person debugging a login doesn't hunt for it.

### 9. `umi/app/views` is now a Zeitwerk autoload *and* eager-load root

`config/application.rb:55-56` pushes every directory under `umi/app` into the main autoloader. This
patch creates `umi/app/views` for the first time (`git ls-tree -d umi -- umi/app/` on the base
branch lists only builders/controllers/jobs/models/services), and I confirmed
`Rails.autoloaders.main.dirs` now contains it. Eager load succeeds today because there are no `.rb`
files there, but the directory is silently a constant namespace root, and view subdirectories
become implicit `Umi::*` namespaces.

Rebase-safe fix inside the new initializer (it runs before `:setup_main_autoloader`):

```ruby
Rails.autoloaders.main.ignore(Rails.root.join('umi/app/views'))
```

### 10. A second `Rack::Cors` is inserted at position 0

`zz_umi_line_identity_binding.rb:12` stacks another `Rack::Cors` in front of the existing one at
`config/initializers/cors.rb:6`. In the normal deployment the base config does not match
`/line-connect/token`, so there is no overlap — but with `CW_API_ONLY_SERVER=true` (or in
development) the base config matches `resource '*'` with `origins '*'`, and two Cors middlewares
can both emit `Access-Control-Allow-Origin`, which browsers reject outright. Confirm that flag is
never set in production, or fold the resource into the existing block.

### 11. Two spec titles promise more than the specs assert

- `spec/requests/umi_line_identity_binding_bind_spec.rb:38` — "queues a verified binding **and
  ignores browser-supplied identity fields**". The request body (`:34`) sends only
  `token`/`id_token`/`consent`; no `line_user_id` or `display_name` is ever supplied, so this
  example cannot fail if the controller started trusting them. `SPEC.md:253` lists that rejection
  as covered. Send the fields and assert the enqueued job still carries LINE's `sub`.
- `SPEC.md:250-252`'s GETDEL race simulation is not present (see SHOULD-FIX 3).

### 12. The Vitest fixture is committed but outside the test glob

`REPORT.md:130-132` states it plainly: the default Vitest config includes only `app/**`, so
`docs/UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.test.js` ran once under a temporary uncommitted
config and will never run again. A test that CI does not execute rots into decoration — either add
`docs/**` to the include list or move the snippet and its test under `app/javascript`.

### 13. Doc drift in the spec (harmless, but the brief asked)

- `SPEC.md:68` — "stores `{email, expiry}`" and "a token containing only `version`, nonce, and
  expiry". The Redis record is `{email, nonce, verified_email}` (`token_service.rb:20`); expiry is
  the Redis TTL plus the verifier's `expires_in`. `verified_email` — a field that changes what
  downstream may trust — is undocumented in that sentence.
- `SPEC.md:163` — "LINE ID-token verification fails → 422". Transient LINE failures (429/5xx,
  timeouts) return 503, not 422 (`line_connect_controller.rb:104`). The behaviour is right; the
  table is stale.
- `SPEC.md:241` — "A configured-origin preflight is `204`". `Rack::Cors` answers preflight with
  200; only the pass-through `OPTIONS` path in the controller (`:23`) yields 204.

### 14. `line_display_name` is attacker-controlled text stored in Klaviyo

`identity_client.rb:36` takes `claims['name']` verbatim and `klaviyo_bind_job.rb:23` writes it to
the profile. A LINE display name is user-chosen. Klaviyo escapes on render, so this is only a
problem if a template ever puts the property in a raw HTML context. Worth one sentence in the
runbook's privacy section rather than code, given the marketing-only bar.

---

## Severity levels with no entries

None — all three levels have findings. There is **no** additional core-upstream-file edit hiding in
this branch; I checked the whole diff against `lib/`, `app/`, `config/` and `enterprise/`, and the
only file outside `umi/`, `docs/`, `spec/` and `UMI-PATCHES.md` is the sanctioned
`config/initializers/zz_umi_line_identity_binding.rb`.

## If I were merging

Land MUST-FIX 1 with a no-Origin request spec, add the `UMI-PATCHES.md` table row, delete the dead
`test_consume` branch, and fix the snippet's script-append loop. The remaining SHOULD-FIX items
(stylesheet, provider timeouts) can ship in the same commit or a follow-up before
`UMI_LINE_BINDING_ENABLED=true`, since the feature is inert until that flag flips.
