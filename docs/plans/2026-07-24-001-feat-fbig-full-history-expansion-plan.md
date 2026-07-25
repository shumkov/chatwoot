---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: docs/UMI-FBIG-FULL-HISTORY-EXPANSION-SPEC.md
execution: code
deepened: 2026-07-24
---

# FB/IG full-history expansion and profile repair

## Goal Capsule

Expand the already-applied patch 14 import from its narrow production window
to every Meta-exposed Messenger and Instagram thread through one frozen safe
cutoff. Preserve the existing 22 archives and 48 messages, append eligible
absent messages without creating empty archives, and safely fill supported
contact data—including repairing the exact six generated Instagram
placeholders.

Authority order:

1. the user-settled scope in this session;
2. `docs/UMI-FBIG-FULL-HISTORY-EXPANSION-SPEC.md`;
3. the original patch 14 safety contract in
   `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md`; and
4. existing UMI/repository conventions.

Stop implementation on any design conflict that would require deleting or
rewriting existing imported rows, changing the outbound overlap policy,
creating data-only contacts/empty archives, overwriting agent profile data, or
using live callbacks/jobs for migration writes.

Execution profile: one focused UMI patch, test-first for the production
placeholder/configuration regressions, reviewed before commit, then candidate
clone evidence. Shipping tail includes signed commit, push, PR, CI-to-green,
merge, and image build. The merged image's exact registry digest receives a
fresh full production-clone acceptance before it can be deployed. After
explicit user approval at the production boundary: take a coordinated
database/local-storage backup under writer quiescence, deploy that exact
digest, run the staged apply, and verify invariants/idempotency.

## Product Contract

### Summary

The existing importer already provides exhaustive cursor traversal,
historical timestamp preservation, deterministic inert archives,
callback-free direct persistence, and sequential idempotency. This change adds
a narrowly acknowledged monotonic configuration transition and
preservation-first contact enrichment. It does not replace the importer or
reconstruct history Meta no longer exposes.

### Requirements

- **R1 — Full Meta-exposed scan.** Traverse every bounded Messenger and
  Instagram conversation/message cursor with `SINCE=all` and one exact
  `BEFORE` cutoff at least 15 minutes old.
- **R2 — Preserve production baseline.** Keep every field/association of the
  original 48 Messages and 6 imported Attachments/blobs unchanged. Keep the 22
  archive identities, links, canonical state, and unrelated attributes;
  permit only target-marker normalization and outward historical activity
  bounds. Permit only documented fill-only profile/avatar/contact-activity
  changes.
- **R3 — Append recoverable messages.** Insert every absent message eligible
  under the unchanged `pre_presence` policy with all currently supported
  content, reply, attachment, and import metadata.
- **R4 — No empty/data-only records.** Create no Contact, ContactInbox, or
  Conversation unless a thread has at least one prepared absent message.
  (session-settled: user-directed — chosen over creating every Meta thread:
  empty conversations do not represent useful recovered history.)
- **R5 — Preserve live state.** Do not append to or alter live conversations;
  reject an archive that is no longer canonical/importer-only.
- **R6 — Explicit safe expansion.** Permit only acknowledged, monotonic,
  same-policy predecessor-to-target expansion, scoped to the selected
  platform and resumable after interruption.
- **R7 — Enrich encountered contacts.** Fetch supported profile fields once
  per unique participant and fill safe missing values for existing contacts
  encountered in the scan or new contacts created for prepared history,
  including supported Instagram follower/relationship/verified fields.
- **R8 — Repair exact IG placeholders.** Replace only
  `Instagram user #{source_id.last(4)}` with an available nonblank name and
  preserve agent-edited/near-match names. (session-settled: user-directed —
  chosen over leaving partial-import fallbacks permanent: the user explicitly
  requested repair of placeholders created by this migration.)
- **R9 — Preserve profile ownership.** Never replace an existing avatar,
  username, optional profile value, unrelated social profile, or agent-edited
  name.
- **R10 — Callback-free enrichment.** Do not use ordinary model saves, live
  contact builders, or `AvatarFromUrlJob`; profile and avatar failures never
  block eligible message recovery.
- **R11 — Honest completeness.** Report unavailable/hidden Meta data and
  supported media boundaries explicitly. “All” never claims recovery of data
  Meta omitted.
- **R12 — Staged production proof.** Dry-run twice at an identical cutoff,
  preflight contact-avatar uniqueness, and repeat full acceptance on a fresh
  coordinated clone with the merged image's exact registry digest. Apply
  Messenger as canary, verify, apply Instagram, verify, then run exact
  recovery passes until a final zero-write idempotency pass or only explicitly
  accepted permanent enrichment omissions remain.
- **R13 — Same-process database identity.** Require
  `UMI_FBIG_HISTORY_EXPECTED_DATABASE` on every importer invocation and compare
  it with `current_database()` before inbox lookup, lock acquisition, Meta
  access, or writes. Clone and production commands pass distinct expected
  database names.

### Acceptance examples

- Given an existing June-window Messenger archive and a requested
  `SINCE=all` interval with the same policy, acknowledged apply reuses the
  archive, inserts only absent eligible mids, then normalizes its marker after
  Messenger completes.
- Given a crash after new rows commit but before marker normalization, the
  next acknowledged run accepts mixed predecessor/target markers and inserts
  no duplicates.
- Given a locally valid predecessor archive that exhaustive Meta traversal no
  longer returns, the run counts the Meta omission, preserves the archive, and
  normalizes its marker; if Meta returns it later, exact rerun identity-checks
  it before any write.
- Given an Instagram thread whose messages are all already present but whose
  linked contact is named exactly `Instagram user 1234`, the run may update
  that contact from an available profile but creates no new conversation or
  message.
- Given the same contact renamed by an agent to `Instagram user 1234 — VIP`,
  the importer leaves it untouched.
- Given a profile with a picture and a contact with an existing avatar, the
  importer does not fetch or replace the avatar.
- Given a Meta thread with no prepared absent messages and no existing
  ContactInbox, the scan issues no profile write and creates no database row.
- Given a permanently unavailable profile or expired avatar URL, eligible
  historical messages still commit and the summary records enrichment
  degradation.
- Given a missing or mismatched expected database name, the rake task exits
  before loading the inbox or constructing the importer.

### Success criteria

- Focused and regression suites pass without skips.
- Pre-fix tests are demonstrated red and post-fix green.
- Independent code review has no unresolved must-fix finding.
- Production-clone all-history run preserves the baseline snapshot and all
  existing importer invariants on the exact image digest later deployed.
- Production dry-run/apply summaries are complete and audit logs retained.
- Every clone and production importer log comes from a process whose mandatory
  expected database name matched its actual connection.
- Exact recovery runs may fill profile/avatar data that was temporarily
  unavailable; the final production pass imports zero rows and performs zero
  contact/profile/avatar writes, or leaves only explicitly accepted permanent
  enrichment omissions.
- Every remaining placeholder/profile/media omission has a counted,
  explainable Meta or preservation reason.

### Scope boundaries

In scope: patch 14 expansion mechanics, profile reads, exact placeholder
repair, supported IG attributes, safe missing avatar attachment, reports,
tests, docs, rollout.

Out of scope: Graph API version upgrade, scraping, new permissions, bypassing
consent/privacy restrictions, speculative media-shape support, raw profile
payload storage, rebuilding current archives, changing native conversation
behavior, scheduling recurring imports, or enriching contacts not encountered
in the Meta scan.

### Dependencies and sources

- `docs/UMI-FBIG-FULL-HISTORY-EXPANSION-SPEC.md`
- `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md`
- `umi/app/services/fbig/history_import_service.rb`
- `umi/app/services/fbig/history_import_graph_client.rb`
- `umi/app/services/fbig/history_import_attachment_service.rb`
- `app/services/instagram/webhooks_base_service.rb`
- `app/jobs/avatar/avatar_from_url_job.rb`
- Official Meta Conversations and Instagram User Profile API collections
  linked from the expansion spec.

## Planning Contract

### Key technical decisions

- **KTD1 — Monotonic platform-scoped transition.** Add
  `ACK_EXPAND_EXISTING=true`; validate only selected-platform archives and
  accept only the exact target, one unique contained same-policy predecessor,
  or their resume mixture. Normalize all selected-platform markers atomically
  after a structurally and identity-complete scan, locking both Conversations
  and their referenced ContactInboxes for final identity revalidation. This
  fixes the current inbox-wide gate without globally relaxing safety.
  “Identity-complete” means every returned pre-existing archive matched its
  ContactInbox participant. A locally valid archive Meta omitted is counted
  and normalized; permanent participant ambiguity on a thread with no
  existing archive is also counted, creates nothing, and does not block
  normalization.
- **KTD2 — Append, never rebuild.** Reuse deterministic archive/contact
  identity and scoped source-id anti-joins. (session-settled: user-directed —
  chosen over destructive rebuild: production archives/messages must be
  preserved and extended.)
- **KTD3 — Retain `pre_presence`.** “All messages” means all eligible under the
  existing multipart-overlap guard. Unconditional outbound import was
  rejected because it can create duplicate user-visible bubbles. Eligibility
  is recomputed from current native presence; previously imported rows remain
  append-only even if that current calculation differs.
- **KTD4 — Existing-contact enrichment is independent of message creation.**
  Enrich encountered existing contacts even when a thread has no absent
  message; defer all new-contact work until a prepared message exists. This
  repairs the one placeholder linked only to a native conversation without
  violating R4.
- **KTD5 — Exact and fill-only merge.** Repair only the source-derived exact
  placeholder; deep-merge allowlisted IG fields under a Contact row lock and
  fill only missing values.
- **KTD6 — Importer-owned avatar path.** SafeFetch, stage, lock/recheck, and
  direct-associate a blob only when no avatar exists. Do not enqueue the
  upstream avatar job or log its expiring URL.
- **KTD7 — Profile degradation is nonfatal.** Authentication is fatal, but
  expected per-user profile/URL unavailability does not affect message
  transaction success. Importer-controlled profile identity/contract, avatar
  budget, retry, storage, association, or cleanup failure leaves committed
  messages and history-complete markers intact but makes enrichment
  incomplete/nonzero; exact rerun retries it without expansion
  acknowledgement.
- **KTD8 — Preserve existing API version.** Use the repository’s configured
  Page-linked Graph client and verified production field contract. A Graph
  version upgrade is a separate patch.
- **KTD9 — Retain all supported IG profile fields.** Persist the allowlisted
  follower, relationship, and verified values as fill-only metadata.
  (session-settled: user-directed — chosen over limiting enrichment to
  name/username/avatar: the requested goal is as much supported user data as
  Meta permits.)
- **KTD10 — One reviewed download budget per invocation.** Require
  `UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES` and count both historical message
  attachments and profile avatars within one invocation. Separate platform
  and recovery commands each start a new allowance; the importer does not
  carry a remainder between them. An over-budget attachment thread commits no
  messages; an over-budget avatar is not uploaded. Consuming exactly the
  remainder succeeds. Either failure outcome is incomplete/nonzero and
  resumable, but only the historical attachment outcome blocks history-marker
  normalization. Defer all avatar downloads until every selected platform
  finishes message/attachment recovery and history normalization; skip the
  global avatar phase if any selected platform is history-incomplete so
  platform order cannot let avatars starve history.
- **KTD11 — Enforce one Contact avatar in PostgreSQL.** Add a concurrent
  partial unique index on Active Storage attachment
  `(record_type, record_id, name)` for `Contact/avatar`. A production
  zero-duplicate preflight is mandatory. This is the smallest enforceable
  serialization boundary because ordinary Active Storage writers do not honor
  the importer’s Contact lock.
- **KTD12 — Guard database identity inside the rake process.** Make
  `UMI_FBIG_HISTORY_EXPECTED_DATABASE` mandatory, read
  `current_database()` in that same process, and abort on absence or mismatch
  before `Inbox.find`. External preflight queries remain useful evidence but
  cannot substitute for the write process checking its own connection.

### High-level technical design

```text
mandatory same-process database identity guard
        |
        v
task options + lock
        |
        v
selected-platform archive preflight
  exact target? -------- yes --------+
  contained predecessor + ACK? ------+--> scan every thread/message cursor
  otherwise fail before Meta         |
                                      v
                         existing contact? -- yes --> cached profile evidence
                                      |                + safe fill-only merge
                                      no
                                      |
                         any prepared absent message?
                           no --> create nothing
                           yes --> cached profile evidence
                                    + transaction: create/reuse contact/archive
                                      and append messages/attachments
                                    + after commit: queue optional avatar
                                      |
                         structural + returned-archive identity +
                         historical-write gates complete?
                           no --> keep predecessor markers
                           yes --> normalize selected-platform markers
                                      |
                                      v
                     all selected platforms history-complete?
                           no --> skip global avatar phase
                           yes --> spend remaining run budget on avatars
```

Expected per-user profile denial and permanent avatar URL unavailability are
counted degradation. Importer-controlled profile/avatar failures make the task
nonzero but retry against exact normalized history markers.

`HistoryImportGraphClient` owns profile request classification and normalized
return data. `HistoryImportService` owns the run-local
`[platform, participant]` cache, including unavailable results, and when
enrichment is allowed. A new `HistoryImportProfileService` owns
name/attribute planning, callback-free merging, SafeFetch avatar
staging/direct association, cleanup, and profile stats. The import service
also owns expansion state, message/archive transaction boundaries, and summary
aggregation.

### Implementation constraints

- UMI-owned app code only; no OSS/Enterprise app edit. The schema-only
  exception is KTD11’s concurrent partial uniqueness index.
- Existing 15-minute cutoff, lock, retry, pagination, detail validation,
  source-id scope, direct inserts, and archive-state validation remain.
- Before Graph, validate selected-platform marker/schema/configuration,
  deterministic-identifier uniqueness, canonical state, and internal
  ContactInbox links. During the scan, require every returned pre-existing
  archive’s Meta participant id to match its ContactInbox source id; count a
  locally valid archive Meta omits without blocking normalization.
- Normalize all selected-platform markers in one transaction: lock/reload all
  archives and referenced ContactInboxes in deterministic order, revalidate
  state/configuration plus current `contact_id`/`source_id` against the
  preflight snapshot and captured Meta participant, replace only nested
  configuration while preserving outer `additional_attributes` (including
  Instagram `type`), assert the affected count, and commit all-or-none.
- Apply must fail before Meta when private-network SafeFetch is enabled and
  require a positive `UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES` single-invocation
  budget shared by historical attachments and avatars.
- New Contact/ContactInbox scalar values commit with their prepared message
  transaction; all optional avatar work waits until platform history is
  complete and markers are normalized.
- Never print profile values, avatar URLs, message text, tokens, or cursor
  URLs.
- Active Storage cleanup must attempt every staged blob even if an earlier
  purge fails.
- Active Storage MirrorJobs are allowed and counted internal persistence
  work; product jobs and `AvatarFromUrlJob` are forbidden.
- Match codebase conventions; avoid speculative helpers or generalized
  contact-sync abstractions.
- TDD red/green evidence must be retained in the commit message.

### Sequencing

1. Pin regressions red.
2. Implement expansion preflight/state transition.
3. Add profile reads and normalization.
4. Add the database-enforced Contact/avatar uniqueness boundary.
5. Implement callback-free profile/avatar merge.
6. Integrate reporting/task/docs.
7. Run focused/full validation and independent code review.
8. Validate against a fresh production clone.
9. After explicit approval, ship and execute the staged production run.

### Risks and mitigations

- **Meta pagination/runtime:** 747 containers and all message pages can be
  long-running. Existing bounded cursors, throttling, lease renewal, per-thread
  commits, and resumability contain the risk.
- **Meta omissions:** final counts can be less than historical reality. The
  run reports cursor exhaustion and explicit omissions without overstating
  completeness.
- **Profile permission asymmetry:** current IG lookups succeed while most
  Messenger lookups return error 100. Participant names remain Messenger’s
  fallback and avatar absence is reported, not synthesized.
- **Profile contract regression:** pin the Page-linked Koala request
  host/version/token source, exact field lists, and returned id; unsupported
  fields or identity mismatch are incomplete/nonzero rather than mass
  per-user omissions.
- **Download/storage usage:** require an explicit total-byte budget in
  addition to per-file/attachment-count limits. Stage-count historical
  attachments before a thread transaction and purge/leave the thread absent
  if it would cross the budget; skip an over-budget avatar. Both are resumable
  and nonzero.
- **Concurrent live/profile writes:** row locks, exact comparisons, fill-only
  merge, avatar recheck, and KTD11’s database uniqueness preserve user data.
- **Marker/config drift:** local preflight rejects malformed, duplicate,
  incompatible, or mutated archives before Meta; scan-time identity validation
  and atomic final revalidation prevent unsafe marker writes.
- **Partial run:** old/target marker mixtures are explicitly accepted only
  under the same monotonic acknowledged transition.
- **Meta hides a predecessor archive:** retain/count/normalize a locally valid
  archive; require identity validation if it reappears on an exact rerun.
- **Production reversibility:** no row-level destructive rollback; a fresh
  coordinated database/local-storage backup and baseline snapshot are
  mandatory, and rollback restores only the matching pair.

## Implementation Units

### U1. Add failing regression coverage

**Goal:** Prove the two current production defects before changing behavior.

**Requirements:** R2, R6, R8, R9

**Files:**

- `spec/services/umi/fbig/history_import_service_spec.rb`
- `spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`

**Approach:**

- Add a production-shaped existing archive with a contained predecessor
  interval; request `SINCE=all`, a later cutoff, unchanged `pre_presence`, and
  explicit expansion acknowledgement.
- Add an existing contact named by the exact source-derived Instagram
  fallback plus an available profile name.
- Run focused examples against current code and record the expected red:
  configuration expansion is rejected and the placeholder remains unchanged.
- Add preservation cases for agent-edited/near-match names before
  implementation.

**Test scenarios:** compatible expansion, exact placeholder, custom name,
different suffix, missing candidate.

**Verification:**

`eval "$(rbenv init - zsh)" && bundle exec rspec spec/services/umi/fbig/history_import_service_spec.rb spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`

### U2. Implement platform-scoped monotonic expansion

**Goal:** Safely extend existing archives without weakening exact reruns.

**Requirements:** R1–R6, R11

**Files:**

- `umi/app/services/fbig/history_import_service.rb`
- `lib/tasks/umi_fbig_history_import.rake`
- `spec/services/umi/fbig/history_import_service_spec.rb`
- `spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`

**Approach:**

- Parse and carry `ACK_EXPAND_EXISTING`.
- Build the selected-platform preflight scope as the union of marker-owned
  archives and deterministic-prefix matches. Require every marker-owned
  archive’s exact expected identifier; reject prefix impostors and identifier
  mutation.
- Preflight schema, platform, one unique predecessor/target configuration set,
  duplicate deterministic identifiers, local archive/ContactInbox consistency,
  canonical state, and imported-only message state before Graph.
- During scan, require every returned pre-existing archive’s Meta participant
  id to match the linked ContactInbox source id. Count but retain/normalize a
  locally valid predecessor archive Meta does not return.
- Accept exact target, one contained same-policy predecessor, or their
  predecessor/target resume mixture only; define `since=all` ordering
  explicitly.
- Track structural completion, returned-archive identity verification, and
  historical-message/attachment persistence per platform. A
  participant-ambiguous thread with no existing archive stays a counted
  no-record omission. Normalize markers only after history success in one
  transaction that locks archives and referenced ContactInboxes in
  deterministic order, reloads, revalidates current links against the
  preflight snapshot and captured Meta participant, changes only the nested
  configuration, asserts the affected count, and commits all-or-none.
- Preserve every other archive attribute and all original rows.
- Report configuration state and normalization counts.

**Test scenarios:** exact, unique predecessor, predecessor/target resume, no
ACK, second/third predecessor, `all` ordering, narrower since, earlier before,
policy change, malformed marker, duplicate identifier, locally valid archive
absent from Meta, returned participant mismatch, concurrent archive or
ContactInbox identity mutation during final locked revalidation, other
platform ignored/unmodified, interruption and rerun.

**Verification:** focused history-import service and rake specs; inspect SQL
queries to ensure platform scope is escaped and exact.

### U3. Add normalized cached profile reads

**Goal:** Read supported profiles through the importer’s existing Graph safety
boundary.

**Requirements:** R7, R10, R11

**Files:**

- `umi/app/services/fbig/history_import_graph_client.rb`
- `spec/services/umi/fbig/history_import_graph_client_spec.rb`

**Approach:**

- Add allowlisted platform-specific field constants (including `id`) and a
  `profile` method pinned to the existing Koala/Page-token Facebook Graph
  endpoint and configured API version for both platforms.
- Route the request through existing throttle/retry/auth classification.
- Normalize only supported returned keys and require returned `id` to equal
  the requested participant id.
- Return a safe aggregate reason for known permanent per-profile client
  errors; retain fatal token authentication behavior and make
  unsupported-field/identity/contract errors incomplete/nonzero.
- Cache successful and unavailable results once per
  `[platform, participant_id]` in `HistoryImportService`.

**Test scenarios:** IG complete/partial result, Messenger result, exact
host/version/token/fields, missing/mismatched returned id, permanent
100/230-style per-user denial, unsupported-field contract error, auth 190,
retryable rate limit/server/network failure, one request per repeated
participant including unavailable results.

**Verification:**

`eval "$(rbenv init - zsh)" && bundle exec rspec spec/services/umi/fbig/history_import_graph_client_spec.rb`

### U7. Enforce one Contact avatar at the database boundary

**Goal:** Make the importer’s preserve-existing-avatar rule race-safe against
ordinary Active Storage writers.

**Requirements:** R2, R9, R10, R12

**Files:**

- `db/migrate/*_add_unique_contact_avatar_attachment_index.rb`
- `db/schema.rb`
- `spec/services/umi/fbig/history_import_profile_service_spec.rb`
- `docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md`

**Approach:**

- Add a concurrently built partial unique index on
  `active_storage_attachments(record_type, record_id, name)` where the row is
  `Contact/avatar`; keep the migration outside a transaction as required by
  PostgreSQL concurrent index creation.
- Put the exact zero-duplicate production/clone preflight query in the runbook.
  Stop before deploy if any duplicate key exists; do not choose a winner or
  clean up existing user data in this patch.
- Make U4 treat the index’s `RecordNotUnique` as a concurrent live winner,
  retain the winning attachment, and purge the importer’s unattached blob.

**Test scenarios:** no existing duplicates permits the index; two different
blobs for one Contact/avatar violate it; non-Contact and non-avatar Active
Storage rows remain unaffected; importer losing the race cleans its blob.

**Verification:** migrate a clean test database forward/back/forward, run the
profile-service concurrency specs, and confirm the schema contains only the
intended partial index.

### U4. Implement preservation-first profile and avatar service

**Goal:** Repair importer-owned placeholders and fill supported missing contact
data without callbacks or overwrites.

**Requirements:** R7–R10

**Dependencies:** U3, U7

**Files:**

- `umi/app/services/fbig/history_import_profile_service.rb`
- `spec/services/umi/fbig/history_import_profile_service_spec.rb`

**Approach:**

- Produce dry-run projections and apply results from the same merge planner.
- Normalize evidence as profile name then participant name for display, and
  profile username then observed sender username for Instagram username;
  never derive a display name from a username.
- Under a Contact row lock, compare the exact IG fallback at write time,
  deep-copy attributes, fill only blank username fields/absent optional keys,
  and direct-update changed columns.
- Reject apply before Meta if private-network SafeFetch is enabled. Queue
  avatar work in memory across the invocation and run it only after every
  selected platform’s messages/attachments are complete and history markers
  normalize. Skip the global avatar phase if any selected platform remains
  history-incomplete. Skip avatar fetch when attached. Otherwise enforce the
  15 MB file limit and remaining shared budget, stage/upload a blob, lock and
  recheck, then direct-insert `name: avatar`, `record_type: Contact`, Contact
  id, blob id, and a normal join timestamp without saving the Contact.
- Treat KTD11 `RecordNotUnique` as a concurrent winner, preserve the winner,
  and clean the importer blob.
- Purge every unattached staged blob even if one purge raises. Treat expected
  per-user denials/permanent URL failures as degradation, but make retry,
  budget, upload, association, or cleanup failures incomplete/nonzero and
  URL-free in logs. They retry on exact normalized history markers.

**Test scenarios:** exact repair, race, custom/near-match preservation,
username and nested social-profile merge, false/zero optional values, existing
avatar, successful direct-association shape, unique-index concurrent winner,
avatars run after all message attachments, private-network mode, shared-budget
exhaustion, invalid/unsafe/404/429/5xx, storage/association/cleanup failure
with all-blob cleanup, no
callback/product-job/event side effects, counted MirrorJob only.

**Verification:**

`eval "$(rbenv init - zsh)" && bundle exec rspec spec/services/umi/fbig/history_import_profile_service_spec.rb`

### U5. Integrate enrichment, summaries, and durable docs

**Goal:** Connect profile work to the scan without violating no-empty or
message atomicity boundaries.

**Requirements:** R1–R13

**Files:**

- `umi/app/services/fbig/history_import_service.rb`
- `umi/app/services/fbig/history_import_attachment_service.rb`
- `lib/tasks/umi_fbig_history_import.rake`
- `spec/services/umi/fbig/history_import_service_spec.rb`
- `spec/services/umi/fbig/history_import_attachment_service_spec.rb`
- `spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`
- `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md`
- `docs/UMI-FBIG-FULL-HISTORY-EXPANSION-SPEC.md`
- `docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md`
- `UMI-PATCHES.md`

**Approach:**

- Enrich encountered existing ContactInboxes even when all messages are
  present.
- Fetch/plan profile data for a new contact only after a prepared message
  exists; insert scalar contact data with the successful thread transaction,
  then defer optional avatar work until every selected platform’s history and
  marker normalization complete.
- Preserve the ContactInbox late-winner retry: roll back the speculative
  Contact, reuse the winner, and apply only exact/fill-only enrichment.
- Enforce the shared download budget after staging each thread’s historical
  attachments and before its transaction. If the thread would cross the
  budget, purge every staged blob, insert no message from that thread, mark
  incomplete/nonzero, and block marker normalization.
- Keep enrichment outside message success/failure semantics and aggregate
  profile stats in the final result.
- Print the exact cutoff, expansion status, projected/applied profile changes,
  safe aggregate reason buckets, shared attachment/avatar byte-budget usage,
  and dry-run downloadability boundary.
- Require and verify `UMI_FBIG_HISTORY_EXPECTED_DATABASE` before inbox lookup;
  document and pass the distinct clone/production names in every importer
  command.
- Add the focused operator runbook with exact commands, field-level immutable
  baseline snapshot queries, invariant queries, comparison procedure, and
  audit paths. Document the new task flags, limitations, and remove-when
  without changing patch numbering.

**Test scenarios:** existing contact/no absent message, no existing contact/no
candidate, new contact with profile, failed new-contact message transaction,
ContactInbox late-winner with profile evidence, expected profile failure with
successful message, attachment budget exhaustion purges/commits no thread,
avatar budget exhaustion uploads nothing after history normalization,
historical-write failure blocks normalization while profile/avatar failure
does not, dry-run zero writes/downloads, exact rerun zero profile changes, full
side-effect sentinel, missing/mismatched expected database exits before inbox
lookup.

**Verification:** all focused importer/Graph/profile/attachment/lock/rake
specs and RuboCop on changed Ruby files.

### U6. Review, clone acceptance, and shipping tail

**Goal:** Establish independent evidence before production and execute only
the approved staged rollout.

**Requirements:** R1–R13

**Files:** no planned product-code additions; review fixes remain surgical in
the files above and the focused runbook.

**Approach:**

- Run independent correctness/data-preservation, failure/security, and
  testing/operations reviews of the actual diff; fold every must-fix.
- On a fresh production clone, use the runbook to snapshot the known 22/48
  baseline—including archive metadata plus imported Attachment/blob/join
  associations—dry-run twice with the same cutoff, then apply Messenger and
  Instagram separately with invariant checks after each. Treat an exact rerun
  that fills previously unavailable profile/avatar data as recovery, then
  repeat exact reruns until a final pass writes nothing or only explicitly
  accepted permanent enrichment omissions remain. Every importer process
  receives and verifies the clone's expected database name.
- Run the production read-only Contact/avatar duplicate preflight before
  merge/deploy; stop if it is nonzero.
- Capture red/green and candidate-clone evidence, then create one signed
  `UMI:` commit.
- Push, open PR, monitor CI/review to green, merge, and wait for the exact
  image build.
- Resolve the merged image to an immutable registry digest, restore a new
  coordinated production database/storage clone, and repeat complete clone
  acceptance with every Rails one-off pinned to that digest. Only this second
  acceptance approves production deployment. The database and nonempty local
  storage restore must come from one writer-quiesced backup ID/checksum set;
  compare source/restored storage manifests and verify the isolated bind mount
  before apply.
- Ask for explicit production approval if it has not already been provided
  for the exact reviewed commands and cutoff.
- Take a fresh coordinated database/local-storage production backup under
  writer quiescence and verify its `pg_restore` list, tar manifest, and
  checksums. Deploy the clone-accepted digest through Ansible as
  `tag@sha256:digest` only after committing that exact pin to the persistent
  infrastructure inventory. Pass and verify the production expected database
  name on every staged importer command, retain audit logs, and report totals
  plus irrecoverable omissions. Use ID-bound PII-free hashes for the original
  22/48/6 rows/files and stable linkage of pre-existing live conversations;
  avoid racy whole-production fingerprints while live writers continue.

**Test scenarios:** clone field-level baseline preservation, no empty archives,
no live-conversation changes, no product-side-effect jobs/events, marker
normalization/resume, exact zero-write rerun, placeholder/profile results.

**Verification:** repository test commands below plus the runbook’s
production-clone snapshot and invariant queries.

## Verification Contract

Initialize the repository Ruby before every Ruby command:

`eval "$(rbenv init - zsh)"`

Focused correctness:

`bundle exec rspec spec/services/umi/fbig/history_import_service_spec.rb spec/services/umi/fbig/history_import_graph_client_spec.rb spec/services/umi/fbig/history_import_profile_service_spec.rb spec/services/umi/fbig/history_import_attachment_service_spec.rb spec/services/umi/fbig/history_import_lock_spec.rb spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`

Style:

`bundle exec rubocop umi/app/services/fbig/history_import_service.rb umi/app/services/fbig/history_import_graph_client.rb umi/app/services/fbig/history_import_profile_service.rb lib/tasks/umi_fbig_history_import.rake spec/services/umi/fbig/history_import_service_spec.rb spec/services/umi/fbig/history_import_graph_client_spec.rb spec/services/umi/fbig/history_import_profile_service_spec.rb spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`

Broader regression:

- run every UMI FB/IG service/job/task spec touched by patches 8–14;
- run the repository backend CI shard(s) selected by the PR; and
- report any skip or unrelated known failure explicitly.

Behavioral quality gates:

- demonstrate U1 red against the unmodified implementation and green after;
- assert zero product events/jobs/webhooks/bots/outbound sends in successful
  message and profile paths; counted Active Storage MirrorJobs remain allowed;
- validate no ordinary Contact/Conversation/Message/Attachment callbacks are
  used;
- independently review the diff after implementation; and
- run production-clone acceptance with a snapshot of ids and mutable fields,
  not counts alone.

Production gate:

- fresh coordinated database/local-storage backup completed, checksummed, and
  restorable as one pair;
- deployed image digest equals the merged build accepted on the fresh clone;
- persistent infrastructure inventory pins the same exact
  `tag@sha256:digest`, never `umi-latest`;
- every importer process requires the distinct expected clone/production
  database name and verifies it before inbox lookup;
- exact dry-run cutoff and policy reviewed;
- private-network SafeFetch disabled and explicit shared download budget
  reviewed;
- zero duplicate production `Contact/avatar` Active Storage keys before the
  partial unique-index migration;
- smaller Messenger platform passes before Instagram;
- original 48 messages and 6 imported attachment/blob associations unchanged;
- original 22 archive identities/state/unrelated attributes unchanged, with
  only documented marker/activity-bound deltas;
- every comparison uses the originally captured IDs, and pre-existing live
  conversation identity/linkage hashes remain unchanged;
- zero empty archives and zero importer mutations to live conversations;
- exact recovery reruns converge to a final pass that imports zero rows and
  performs zero contact/profile/avatar writes, or leaves only explicitly
  accepted permanent enrichment omissions; and
- audit logs retained outside the container.

## Definition of Done

- **U1:** both production regressions demonstrably fail on old code.
- **U2:** only explicit monotonic selected-platform expansion is accepted,
  interruption resumes, and original rows remain stable.
- **U3:** profile reads are allowlisted, cached, throttled, retry-classified,
  and auth-safe.
- **U7:** the concurrent partial index enforces one Contact/avatar, passes the
  production/clone duplicate preflight, and leaves other attachment shapes
  unaffected.
- **U4:** exact placeholders and missing supported data are filled without
  overwriting user data or invoking product callbacks/jobs;
  importer-controlled avatar failures cannot be reported as success and retry
  without reopening history expansion.
- **U5:** end-to-end import retains no-empty, append-only, inert semantics and
  reports the real API boundary.
- **U6:** independent reviewers are satisfied; focused/CI/clone checks pass;
  commit/PR/deploy/apply artifacts are auditable.
- No abandoned experiment, duplicate implementation, debug output, raw
  profile data, signed avatar URL, or unrelated refactor remains in the diff.
- `UMI-PATCHES.md` and both history-import specs accurately describe the
  shipped behavior and remove-when condition.
- Production completion is reported as all Meta-exposed history scanned, with
  per-platform archive/message/contact/profile/avatar totals and every known
  omission surfaced.
