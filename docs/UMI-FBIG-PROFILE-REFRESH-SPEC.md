# UMI patch: FB/IG contact profile enrichment (names, handles, avatars)

Revision 4. Reviewed across two rounds by seven independent agents
(feasibility ×2, scope ×2, adversarial data-safety ×2, security/compliance).
Material reversals are called out inline under **Revised from rN**.

**Decisions of record.** Handle-as-name (2026-08-05), reversing
`docs/plans/2026-07-24-001-…:549`. `contact_type` visitor→lead promotion
accepted (2026-08-05). **Recurring nightly refresher retained (2026-08-06)**,
after review recommended cutting it to a one-time drain — see §7 for the
evidence against recurrence, recorded so the trade is explicit rather than
forgotten.

## Problem

Meta granted **Business Asset User Profile Access** and
**`instagram_manage_messages` Advanced Access** on 2026-08-04. Neither grant
repairs anything existing, because the profile fetch is **one-shot at contact
creation** on both platforms:

- Facebook — `ContactInboxWithContactBuilder` returns early once a
  `contact_inbox` with that `source_id` exists
  (`app/builders/contact_inbox_with_contact_builder.rb:18`);
  `update_contact_avatar` sits below it (`:23`), gated on
  `unless @contact.avatar.attached?`.
- Instagram — `ensure_contact` runs only `if contacts_first_message?`
  (`app/services/instagram/base_message_text.rb:22`).

There is also an **active leak** (§2), measured at ~2 new contacts/day of which
~14% land with an unusable name.

## Probe results (read-only against prod, 2026-08-05/06)

Single inbox `id=2`, a `Channel::FacebookPage` carrying both platforms via
`instagram_id`.

**Load-bearing finding: the Conversations-API `participants` lookup that patch
#13 uses to beat error 100/33 on Messenger also beats error 230 on
Instagram — 12/12, including 11 ids `get_object` refused.** Verified in the
same probe that `participants[].id` equals the IGSID passed as `user_id`, so
the existing selector is correct.

### Name-shape census (full population)

| Shape | n | No avatar | Handle stored |
|---|---:|---:|---:|
| Real name | 565 | 75 | 493 |
| `Instagram user NNNN` | 147 | 118 | 35 |
| Haikunator (`lingering-sun-586`) | 7 | 0 | 7 |
| `Facebook user` | 2 | 2 | 0 |
| `John Doe` / partial (`Somchai Doe`) | 0 | — | — |

**Revised from r1**, whose "224 affected" figure was derived from a query
sharing its definition with the fix — it could not falsify its own matcher.

### Platform classification

`conversation.additional_attributes['type'] == 'instagram_direct_message'`
(set at `messages/instagram/messenger/message_builder.rb:31`, load-bearing at
`send_reply_job.rb:33`). Classifies **100%** of inbox 2: **77 Facebook**
(75 avatar gaps), **648 Instagram** (154 name gaps). `conversations.contact_inbox_id`
is indexed (`db/schema.rb:777`) and set by both Meta builders, so the marker
attributes to a specific `contact_inbox` as the §4 gate requires.

### Measured facts that constrain the design

- **Handle churn is zero.** 0/60 sampled contacts changed handle, including 6
  older than a year. Instagram handles in this population are static.
- **No contact owns more than one `contact_inbox`** in inbox 2 today.
- **No bad-shape contact has an email or phone**, so `Umi::Shopify::ContactSyncService`
  cannot currently match any of them (§6 conflict is latent, not live).
- `get_object` returns no `name` for most Instagram users even with the grant;
  passing `fields=` explicitly does not help. Probed — do not re-investigate.

## 1. Prerequisite: close the redaction gap BEFORE the cron exists

`Umi::Webhooks::ShopifyCompliance#anonymize_contact` blanks name, email,
phone, identifier, location, country and strips `shopify_*` — but keeps
`social_instagram_user_name`, `social_profiles.instagram`, and **never touches
`contact.avatar`**. It takes that branch whenever conversations exist, which
for a Meta DM contact is always, so the `destroy!` path (which would purge the
blob) never fires for this population.

That is a live gap today. A recurring refresher turns it into a **statutory
erasure being silently reversed on a schedule**: redact → "Redacted customer"
→ within one cycle, renamed back to the handle with the photo re-downloaded,
in an install with `SENTRY_DSN` empty by design.

Two changes, and this commit lands **before** the cron is ever registered:

- `anonymize_contact` also purges `contact.avatar` and drops
  `social_*` + `umi_profile_*` keys.
- The refresher **skips redacted contacts** permanently — a
  `umi_profile_redacted` tombstone set by the redaction path, checked by the
  selection query. Skipping on `name == 'Redacted customer'` alone is not
  enough, because the refresher would rename it and thereby un-skip it.

The same reasoning applies to `ContactsController#avatar` DELETE: under a
recurring refresher, purging an avatar is not durable. The tombstone covers
the redaction case; an agent-purged avatar returning next cycle is an accepted
consequence of recurrence.

## 2. Stop the leak (live path)

**Revised from r1**, which patched patch #10's `fallback_contact_name`. Wrong
hook: with the grant live `get_object` *succeeds* for Instagram but returns no
`name`, so `webhooks_base_service.rb:20-22` passes `nil` into
`create_contact_inbox` and `contact_name` (`:62-65`) falls back to
`Haikunator.haikunate(1000)`. `@contact_inbox` is then present, so patch #10's
`ensure_contact` returns early and `fallback_contact_name` is never called.

Prepend `Instagram::WebhooksBaseService#find_or_create_contact`, using
`user['username']` when `user['name']` is blank. Verified viable: the method
is private on the base class, both live subclasses call it via implicit
receiver, neither overrides it, and patch #10 prepends a *different* method on
a subclass — no ordering conflict. Guard shape per
`zz_umi_fb_contact_name_fallback.rb:18-26`. **Key-type caveat:** the Messenger
path's `user` is a plain Koala Hash (String keys) while the
graph.instagram.com path yields `HashWithIndifferentAccess` — use String keys.

**This path must also write the §3 provenance value**, or every contact it
creates is frozen on its creation-time handle — the exact defect the refresher
exists to retire. Patch #10's `Instagram user NNNN` fallback needs no stamp;
that shape is in the allow-list.

## 3. Provenance: store the value, not the source

**Revised from r3**, which stamped `umi_profile_name_source` and claimed "an
agent's edit becomes permanent the moment they make it." False — nothing
clears the stamp, and **all four rename paths preserve `additional_attributes`
verbatim**: dashboard inline edit and the contact form
(`contacts_controller.rb:94-98,183-193` — `contact_additional_attributes`
returns the existing hash unchanged when the client sends none;
`ContactForm.vue:192-205` spreads it back), CSV re-import
(`data_import/contact_manager.rb`), and `ContactIdentifyAction`. The refresher
would have overwritten agent edits monthly, forever.

Store `umi_profile_name` = **the exact string we wrote**. Refresh a name only
when `contacts.name == umi_profile_name`. An agent edit breaks the equality and
the contact is never touched again — fails **closed**, where the source-stamp
failed open.

This also fixes `ContactMergeAction` stamp-laundering for free: that action
deep-merges `additional_attributes` (mergee keys survive) while the **base's**
name wins, so a source-stamp would have licensed renaming an agent-authored
contact. With value-equality the names differ, so the gate refuses.

First pass, where no stamp exists, still uses the exact-shape allow-list:
`"Instagram user #{that_contact_inbox.source_id.last(4)}"` computed per
`contact_inbox` (never `LIKE`), the Haikunator regex, `Facebook user`,
`John Doe`, and the partial-Doe class.

## 4. `Umi::Fbig::ProfileEnrichmentService`

Resolve **name and avatar independently** — do not short-circuit the contact.
**Revised from r3**, whose single ladder "stopping at the first hit" meant a
contact resolved locally at rung 1 got no Graph call and therefore no avatar,
even when a missing avatar was its only gap.

Name ladder: local stored handle → `get_object` → `participants`.
Avatar: `get_object` only (participants never returns an avatar field).

Write rules:

- **Rename** only when the value-stamp matches, or (first pass) the exact
  shape matches.
- **Avatars are gap-fill only** — attach when none is present, never replace.
  **Revised from r3**, which listed profile-picture staleness in its premise
  while specifying `re-check avatar.attached?`, which can never replace one.
  Replacement is out of scope: Meta's `profile_pic` is a signed, expiring URL
  that differs on every fetch even for identical bytes, so `avatar_url_hash`
  can never suppress a re-download — replacement would mean purging and
  re-downloading 725 blobs a month, each firing `dispatch_update_event` →
  webhook + ActionCable fan-out, and destroying agent-uploaded avatars.
- **Store** `social_instagram_user_name` + `social_profiles.instagram` in
  upstream's `build_instagram_attributes` shape.
- **Write ordering** (the only sequence satisfying both stated constraints):
  raw `jsonb_set` for every jsonb key → `contact.reload` →
  `contact.update!(name: …)`. Rails partial updates make that a `name`-only
  UPDATE which still fires `before_save :sync_contact_attributes`, so
  `contact_type` promotion happens from the reloaded hash.
  **Revised from r3**, which forbade whole-column writes and simultaneously
  relied on a callback that only fires on a model save — mutually exclusive as
  written. Note the ~75 Facebook avatar-only contacts get no `social_*` key and
  therefore no promotion.
- **Residual, stated honestly:** `jsonb_set` under a row lock stops *us*
  clobbering `AvatarFromUrlJob`'s keys; it does **not** stop the reverse. That
  job reads a job-start snapshot and `update_columns` the whole column from an
  `ensure` (`avatar_from_url_job.rb:93-104`, fires even on the early-out at
  `:17`) without taking our lock. `update_instagram_profile_link`
  (`webhooks_base_service.rb:29-34`) is a second such writer, reachable for an
  existing contact. Losing the stamp makes the contact untouchable — the safe
  direction — so this is accepted, not mitigated. **Revised from r3**, which
  claimed the hazard was handled.

### Avatar attachment (direct, not via `Avatar::AvatarFromUrlJob`)

The shared job's `should_sync_avatar?` reads `last_avatar_sync_at`, written
only in the post-download `ensure`, and never checks `avatar.attached?` — so
concurrent workers both pass and the loser raises `RecordNotUnique` against
patch #17's index, unrescued, into an unwatched Dead set. The retired
importer banned this job for the same reason
(`docs/plans/2026-07-24-001-…:89,328`).

- **Still call `SafeFetch.fetch`** with `Avatarable::ALLOWED_AVATAR_CONTENT_TYPES`
  and the 15 MB cap. Bypassing the job also bypasses the model-level
  `acceptable_avatar` validation (the prior art writes attachment rows without
  saving the Contact), leaving `SafeFetch` as the **only** enforcement point
  for content-type and size.
- **Savepoint, and rescue outside it.** `contact.with_lock` opens a
  transaction and `attach` joins it with no savepoint, so a rescued
  `RecordNotUnique` leaves an aborted transaction and the next write raises
  `PG::InFailedSqlTransaction`. Use `transaction(requires_new: true)` with the
  rescue outside — the in-repo precedent is
  `contact_inbox_with_contact_builder.rb:12,20`.
- `with_lock` raises on a dirty record and `attach` defers on one, so the name
  write and the avatar attach cannot be interleaved arbitrarily.

## 5. Entry points

- **`Umi::Fbig::ProfileRefreshJob`** — nightly cron, `apply:` and `cap:` as
  **job arguments**, not env. **Revised from r3**: an env `APPLY=true` must be
  permanently set for a cron to do anything, at which point it guards nothing.
  Cron passes `apply: true` with the cycle cap; the supervised drain is the
  same job with a raised cap.
- Registration mirrors `zz_umi_fbig_recon.rb:18-42` exactly — `after_initialize`
  + `next unless Sidekiq.server?`, per-job `Sidekiq::Cron::Job.new(…, source: 'umi').save`,
  **never** `load_from_hash!` (purge filter hardcoded to `source: "schedule"`),
  an explicit `destroy` branch on `UMI_FBIG_PROFILE_REFRESH_DISABLED`, and a
  `job.save` failure report. Slot must not collide with recon's `30 20 * * *`.

**Selection query.** **Revised from r3**, which was a Postgres error as
written:

- `WHERE EXISTS (SELECT 1 FROM contact_inboxes …)`, **not** a join —
  `SELECT DISTINCT … ORDER BY additional_attributes->>'…'` fails with
  *"ORDER BY expressions must appear in select list"*, and without `DISTINCT`
  the join duplicates contacts and silently halves the effective cap.
- Order by `umi_profile_checked_at` **ASC NULLS FIRST, written explicitly** —
  Postgres defaults ASC to NULLS LAST, which would sort the entire backlog to
  the back.
- Rails 7.1 rejects raw order fragments: use
  `Arel::Nodes::SqlLiteral.new(sanitize_sql_for_order(...))`, per
  `Contact.order_on_last_activity_at`.
- Exclude `umi_profile_redacted` tombstones (§1).
- No jsonb index needed — the inbox predicate reduces to ~725 rows before the
  sort, well inside the 14 s `statement_timeout`. Adding one would be
  speculative.

`Channel::Instagram` inboxes are out of scope (the service keys off
`page_id`/`page_access_token`). Log a warning rather than silently skipping,
so adding a native IG inbox later fails loud instead of quietly excluding it.

## 6. Safety

`Contact` is **not** in the audit model list
(`enterprise/app/models/enterprise/audit/`) — no paper_trail, no history
table, and the only recovery is a `pg_dump` restore that rolls back every
message since.

- **Ledger** — `run_id, contact_id, contact_inbox_id, column, old, new,
  evidence_source, graph_response_digest`, appended before each write. It must
  be a **table** (a `Umi::` overlay model + migration): a container file does
  not survive `docker compose up -d` against a moving tag, and `Rails.logger`
  is excluded by the ids-only convention. **Revised from r3**, which specified
  no medium.
- **Retention and cascade** — 90-day purge, plus purge hooks on
  `Contact#destroy` and on the §1 redaction path. Without both, the ledger is
  an unredactable shadow copy of exactly the PII the compliance webhook exists
  to erase, growing ~25 rows/night indefinitely. **New in r4.**
- **Revert** is meaningful only against the *first* pass, where `old` is
  pre-patch truth. For later cycles `old` is merely the previous machine write
  and there is no anchor to "the correct name" — state this rather than
  implying a general undo.
- **Expected-database guard** against `current_database()` before any write.
- **Canary by operation type, not platform** — attach-only first, then
  rename-only. **Revised from r3**: the FB=avatars / IG=names split is a
  census artifact, not a property. The 2 `Facebook user` contacts are renames
  inside the supposedly additive phase, and 118 of the 193 avatar gaps sit on
  Instagram contacts whose avatar and name come from the same `get_object`
  call — so platform ordering separates only 39% of the avatar risk.
- **Logs carry ids and a change classification only**; values go to the ledger.
- **Run-level standdown** — abort the run if the resolution rate falls below a
  floor, the way recon stands down on auth errors. Throttling and "Meta has no
  name" are otherwise byte-identical outcomes (`ParticipantNameService` rescues
  `StandardError` → `nil`), so a throttled night would stamp ~25 contacts as
  checked and sort them to the back for a full cycle. Track
  `umi_profile_last_success_at` separately from `umi_profile_checked_at`.
  **New in r4.**
- Use koala 3.4.0's built-in `rate_limit_hook`, which already parses
  `x-business-use-case-usage` / `x-app-usage`, rather than hand-parsing headers.

### Latent conflict: `Umi::Shopify::ContactSyncService`

Its `placeholder_name?` (`:170-177`) treats blank / name==phone /
name==email-local / Haikunator as upgradeable and writes the **real customer
name** from the order. It does not recognise `Instagram user NNNN`, and will
not recognise a bare handle. So writing a handle permanently closes the door on
a strictly better name source, decided purely by which job runs first.

Zero of the 156 bad-shape contacts have an email or phone today, so nothing is
at risk now. Guard anyway: teach `placeholder_name?` that a name equal to
`umi_profile_name` is still a placeholder, so a real name always wins.

## 7. The case against recurrence (recorded, overruled)

Kept deliberately so the trade is not lost. Review recommended a one-time
re-runnable drain; recurrence was retained by decision on 2026-08-06.

- **No measured benefit.** Handle churn is 0/60. Avatar replacement is out of
  scope (§4). So a steady-state cycle re-fetches data that has not changed.
- **The residual risks are recurrence-specific**: GDPR reversal (§1),
  agent-edit overwrite (§3), the ledger's unbounded PII growth (§6), and the
  absence of a revert anchor after cycle 1.
- **It elevates the Meta platform-terms exposure.** The justification for
  using `participants` where the profile API refuses on consent grounds rests
  on it being reply-time display of an active conversation, as Business Suite
  does. Unattended monthly polling of contacts who have not messaged in a year
  is a materially different pattern. Evidence that would settle it: Meta's
  current Platform Terms circumvention clause, the `participants` field's
  documented purpose, or direct confirmation from Meta. Consequence if wrong is
  most likely revocation of the 2026-08-04 grants — which would silently
  revert name resolution across the whole contact base.
- **Mitigation given the decision:** gate refresh on engagement recency rather
  than polling dormant contacts, and set a reassessment date.

## Why not fold into the nightly reconciliation (patch #12)

Rejected. Recon iterates threads with `updated_time` inside a 48-hour window
(`conversation_recon_service.rb:96-110`) — wrong population (a March contact
never appears), different remove-when, and coupled failure modes (recon
re-raises `@fatal` to force a Sidekiq retry).

## Other alternatives rejected

- Explicit `fields=` on `get_object` — probed, identical data.
- Re-fetch on every inbound message — scales Graph calls with volume.
- Backfill from recon's message-listing `from` field — only covers in-window
  contacts.
- Store the handle only, leave `name` alone — 35 contacts already prove it
  does not fix the display.

## Failure modes

| Mode | Handling |
|---|---|
| Graph 401 | Stand down for the run without retries, as recon does |
| Graph rate limiting | koala `rate_limit_hook`, per-run cap, resolution-rate standdown |
| Concurrent avatar insert | Savepoint + rescue `RecordNotUnique` outside it |
| `AvatarFromUrlJob` clobbering our keys | Accepted residual; fails closed (§4) |
| Agent renamed a contact | Value-equality gate refuses (§3) |
| Merged contact | Value-equality gate refuses; platform match per `contact_inbox` |
| Redacted contact | Permanent `umi_profile_redacted` tombstone (§1) |
| Unresolvable contact | `umi_profile_last_success_at` distinguishes from throttling |
| Wrong rename, first pass | Ledger + gated revert (§6) |

## Verification plan

Specs (red→green):

- Instagram participants lookup returns a handle where `get_object` raises 230.
- Live IG path with blank `name` + present `username` yields the handle, not a
  Haikunator name (pins §2; red today).
- Exact-match first-pass gate: `Instagram user 4355` on the `contact_inbox`
  whose source_id ends `4355` is renamed; the same name on one ending `9999` is
  not.
- **Agent edit survives a refresh cycle** (pins §3 — red against r3's design).
- **A merged contact carrying a transplanted stamp is not renamed.**
- **A redacted contact is never re-enriched** (pins §1).
- Concurrent attach: loser rescues, exactly one attachment row remains, and the
  subsequent write succeeds (proves the savepoint).
- `ParticipantNameService` keeps its Messenger behaviour under the new keyword.

Production: redaction commit first → expected-database guard → attach-only
canary → verify → rename phase → re-run the name-shape census.

**Success criterion.** Placeholders and Haikunator → ~0. The avatar gap
collapses to **~75 recovered, ~112 structurally unreachable** — those
Instagram contacts are denied by error 230 and `participants` returns no
avatar field, so they can never receive one. **Revised from r3**, whose
"collapse to the genuinely-dead ids" was unachievable by its own numbers and
would have made a healthy system indistinguishable from a broken one.

## Implementation notes (what code review changed)

Four review agents scrutinised the diff. Findings that changed the design, kept
here so the doc matches the code:

- **`jsonb_set` cannot create intermediate objects.** Pathing into
  `{social_profiles,instagram}` with `create_if_missing` was a silent no-op for
  every contact without a `social_profiles` object — the whole target cohort.
  Built with `jsonb_build_object` instead.
- **Ledger values must be `text`.** `ApplicationRecord` caps `:string` at 255
  and Meta's signed `profile_pic` URLs run 350–600 characters, so every avatar
  attach would have raised `RecordInvalid`.
- **The local rung is an avatar/handle shortcut, never a name source on a later
  cycle.** Reading it after a name had been resolved renamed a real display
  name back down to the handle — one-way and silent.
- **Ambiguous contacts are skipped, not guessed.** A merged contact owns
  several `contact_inbox` rows and `find_by` has no ordering, so the source_id
  chosen was arbitrary and could write another customer's handle.
- **The rename gate also accepts a name equal to the stored handle**, so a
  contact stays repairable if the provenance value is lost to
  `AvatarFromUrlJob`'s whole-column write.
- **The throttle standdown tracks Graph denials**, not resolution rate: every
  Graph error was previously rescued into `:unchanged`, so `:failed` was never
  produced and the standdown was dead code. A refused batch is now left
  unstamped so it stays at the head of the queue.
- **Erasure ordering inverted** — the tombstone is set first, because it is
  what keeps the erasure honoured; purging the avatar and ledger before it
  meant a failed `update!` destroyed the audit trail while leaving the contact
  un-erased and still enrichable.
- **The live Instagram path honours the tombstone**, which it previously did
  not: it rewrote the handle from the surviving source_id on the customer's
  very next message, so erasure lasted only until they spoke again.
- **The ledger sweep no longer rides the kill switch.** Disabling enrichment
  had also frozen retention and erasure propagation.
- **`placeholder_name?` in the Shopify sync** now treats a name we wrote as a
  placeholder, so a real customer name from an order still wins (§6's guard).

Not implemented, and deliberately so: the expected-database guard (the drain is
run by hand against a known host) and the canary as a code path (it is a
runbook ordering — attach-only contacts are drained before renames).

## Commits

Per `CONTRIBUTING-UMI.md` golden rule 2:

1. **Redaction gap** (§1) — prerequisite; lands before the cron exists.
2. Generalize `ParticipantNameService` with a platform keyword.
3. Live-path Instagram naming fix (§2) — stops the leak; writes the stamp.
4. Profile refresher (§3–§6) — ledger, service, job, cron registration.

Registry: new rows for 1, 3 and 4, plus amendments to **#10** (its remove-when
says the patch can go once Advanced Access is "approved + verified"; access is
approved and verified *insufficient* — error 230 still denies ~75% of the
placeholder cohort) and **#13** (profile API now resolves for Messenger; its
service is shared with Instagram, which is what keeps it alive). Remove-when
for the refresher: upstream re-fetches contact profile data after contact
creation.
