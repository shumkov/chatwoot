# UMI FB/IG Full-History Expansion and Contact Enrichment

Status: implementation revision under multi-agent review
Date: 2026-07-24
Extends: `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md` (patch 14)

## Problem

Patch 14 was applied to a narrow June 12–13 window. Production now has 22
deterministic history archives and 48 imported messages:

- Messenger: 16 archives, 20 messages;
- Instagram: 6 archives, 28 messages; and
- 6 imported attachments.

The requested outcome is broader: scan every Messenger and Instagram
conversation and message that Meta still exposes, preserve every existing
imported row, append every recoverable absent message, and retain as much
supported contact data as the API currently returns.

The current importer cannot apply that broader scope. Every existing archive
pins the original `since`, `before`, and `outbound_policy`, and apply mode
rejects any different configuration before it calls Meta. Existing contacts
also return from the importer without profile enrichment. When Instagram
profile lookup failed during the partial import, the importer used the same
fallback as the live channel, `Instagram user <last four source-id digits>`.
Six production contacts currently have that exact generated placeholder.

## Production evidence

Read-only checks on 2026-07-24 established:

- Meta exposes 747 thread containers for the target inbox: 73 Messenger and
  674 Instagram. A thread container is not evidence that it has an importable
  absent message.
- All 6 sampled Instagram archive participants currently return `name`,
  `username`, `profile_pic`, follower count, relationship flags, and verified
  state through the Page-linked Graph token.
- Only 1 of 16 sampled Messenger archive participants returns
  `first_name`, `last_name`, and `profile_pic`; the other 15 return Meta error
  100. Conversation participants remain the reliable Messenger name source.
- The six exact Instagram placeholders are all in the target inbox. Five are
  linked to history archives; one is linked only to a native conversation.

These are aggregate capability checks. The importer must not log profile
payloads, names, usernames, avatar URLs, tokens, or message content.

## Goals

1. Scan all Meta-exposed Messenger and Instagram conversation and message
   cursors from the beginning through one frozen cutoff at least 15 minutes
   old.
2. Append every absent message recoverable under the retained
   `pre_presence` outbound policy, with original timestamps, direction, text,
   supported reply metadata, and supported attachments.
3. Preserve the existing 48 message rows and 6 attachment/blob associations
   unchanged. Preserve the 22 archive identities, links, and canonical state;
   only their import configuration and outward historical activity bounds may
   change.
4. Create a Contact, ContactInbox, and archive only when at least one absent
   message for that thread is ready to persist.
5. Enrich existing or newly imported contacts with supported profile fields,
   including replacing only the exact generated Instagram placeholder.
6. Preserve agent-edited names, existing avatars, existing usernames, and
   unrelated contact attributes.
7. Keep the import callback-free and operationally inert: no customer
   notifications, automations, bots, outbound replies, webhooks, or live
   conversation mutation.
8. Make interruption and rerun safe, including an interruption after some
   threads have committed but before a platform finishes.

### Recovery boundary for this one-time rollout

This implementation supports repeated attempts with the same accepted
release, settings, history scope, and initial profile approval. It does not
authorize changing the image/settings after a production profile attempt has
sealed prestate. Although the manifest reserves two predecessor digest fields,
this rollout requires both to be exactly `none`; production rejects a
non-`none` predecessor chain before lock acquisition or Meta access.

If a different release/settings becomes necessary after prestate, keep all
writers stopped and restore that attempt's checksum-verified coordinated
database and storage backup as one pair. Then repeat fresh clone acceptance
and create a new initial approval. This deliberately smaller recovery contract
is fail-closed and sufficient for the one-time migration; automated
profile-only approval supersession is out of scope.

## Meaning of “all”

“All” means every conversation page, message page, and recoverable detail Meta
returns for the Page token at execution time. It cannot include:

- old Requests-folder conversations Meta no longer returns;
- deleted, expired, hidden, blocked, consent-restricted, or otherwise
  unavailable profiles or messages;
- attachment binaries whose signed URLs have expired; or
- media/metadata shapes the documented importer does not safely map.

The final report must say “all Meta-exposed history scanned,” not “all
historical events recovered.”

`pre_presence` remains the outbound policy. It deliberately excludes absent
outbound Meta mids at or after the earliest native Chatwoot presence for that
participant, less the existing multipart guard. Importing those mids
unconditionally could duplicate a native multipart Chatwoot bubble whose
other Meta mids were not retained. “Recoverable absent messages” in this spec
means messages eligible under that policy.

Eligibility is recomputed from native presence at expansion time. Previously
imported rows are never re-evaluated or removed if today’s native-presence
calculation would classify them differently. The result is an append-only
expansion, not a clean-room replay of the target interval.

### Production-clone finding: contentless details

The first exhaustive clone dry run on 2026-07-25 used dry-run `report_all`,
scanned 750 threads and 11,635 Meta message ids, and fetched 11,220 detail
payloads. Of those, 2,152 returned neither nonblank `message` text nor any
attachment shape the importer could represent or mark as unsupported. The run
correctly wrote nothing and exited nonzero under the predecessor completion
contract. It also observed one independent profile request error and one
safely omitted new thread with ambiguous participants.

A fresh exhaustive clone probe on 2026-07-26 reproduced that one omitted
Instagram thread. A read-only, PII-free inspection hashed its thread and
participant ids and then checked the message detail: Meta exposed only the
Instagram business account in `participants`, one outbound listing from that
same business account, no external recipient in `to`, no message body, and no
attachment. The envelope therefore contains neither a recoverable contact
identity nor a representable message. Creating a synthetic contact or empty
archive would misattribute the event and violate the no-empty-conversation
contract. It is an unrecoverable Meta envelope, not a migratable chat.

The one-time runbook seals both the expected Instagram ambiguity count and a
domain-separated, pseudonymous fingerprint. Raw Meta ids remain in-process
and are never emitted. The digest is
`Umi::Fbig::TypedValueDigest.hexdigest(record)`, which supplies SHA-256 plus
typed, nested, length-framed values and UTF-8 validation. `record` is a hash
with domain `umi-fbig-unrecoverable-envelope-v1`, platform, and a sorted
`threads` array. Each thread record contains its id; a sorted participant
array preserving multiplicity; and messages sorted by unique mid. Each
message binds the mid, canonical listing time, listing sender, detail sender,
sorted unique detail recipients, `detail["message"].blank?`, attachment
descriptor count, and the sorted omission counts returned by the same
`HistoryImportAttachmentService#plan` used by the importer. Missing ids,
duplicate thread/mid/recipient ids, invalid UTF-8, a missing detail, a detail
mid/time mismatch, malformed shapes, or any incomplete conversation/message
page aborts without emitting a digest.

Before an ambiguous thread enters the digest, the inspector also requires the
reviewed unrecoverable predicate itself: exactly one participant equal to the
Instagram business identity, exactly one pre-cutoff message, listing and detail
senders equal to that business identity, no recipients, a blank body, and zero
supported or omitted attachments. A stable ambiguity count cannot therefore
hide a group thread or newly recoverable identity/content when the first
sidecar is created; any semantic change aborts before a digest is emitted.

The sealed values live in strict
`fbig-unrecoverable-envelope-v1.tsv`/`.sha256` sidecars. The sidecar binds its
schema, repository commit, image digest, account, inbox, Instagram business
id, frozen `before` cutoff, platform, expected count, fingerprint, and
inspector-script SHA-256. The accepted probe log records the sidecar checksum
before it is locked; `HistoryApprovalManifest#source_dry_log_sha256` therefore
chains the sidecar into the existing checksummed 25-field approval without
changing its runtime schema. Clone and production derive the expected value
only from that validated sidecar and inspect only listings/details before the
frozen cutoff.

The same read-only inspection runs immediately before and after every
Instagram-inclusive probe/dry/apply/recovery stage. Both observations must
match the sealed fingerprint, which closes the gap between a separate
pre-stage observation and the envelope the importer actually omits. Each
stage also requires `ambiguous_participants == failed_threads == 1` and zero
ambiguous senders; Messenger-only scans require zero ambiguity. The accepted
unaccepted probe and two accepted dry runs must have byte-identical normalized
summaries. Any identity/content/count drift or any other failed thread aborts
and requires a new investigation. The final production check repeats the
fingerprint after all history/profile work and reports this single envelope
separately from recoverable conversations and messages.

Meta's documented examples include legitimate empty-text messages whose
content is carried by a structured attachment. Those are not this case: the
attachment planner already retains supported media or emits a visible
unsupported-attachment marker. The 2,152 observed details had no supported or
unsupported attachment evidence at all. Meta does not document that such
successfully returned, structurally contentless details will later regain
content. Because `report_all` includes outbound mids that the approved
`pre_presence` apply policy can skip, 2,152 is evidence of the issue only; it
is not an accepted migration count or set.

The predecessor importer spec intentionally makes every permanently
unavailable detail incomplete/nonzero. That remains the default. The full
history expansion adds an explicit, exact operator acceptance path so known
contentless details cannot block marker normalization forever, while a changed
omission set or a different Graph failure still fails closed.

### Production-clone finding: concentrated profile reads

The exhaustive clone dry run interleaved profile reads with message pagination
and detail requests. It observed 523 profile successes, 183 classified
unavailable responses, and one profile error across 707 unique participants.
A later read-only aggregate diagnostic used the same reviewed image and clone
but issued profile reads back-to-back at the existing 250 ms Graph delay. It
returned 151 Instagram successes, 117 classified Instagram unavailability
responses, 407 exhausted Instagram rate-limit errors, one Messenger success,
69 classified Messenger unavailability responses, and four unclassified
Messenger client errors currently mapped to `contract_error`.

Those second-run values are not profile availability totals: the first
exhaustive scan had already consumed shared Meta quota, and the concentrated
diagnostic then amplified that state. They do prove that treating profile reads
as an inline side effect of every history verification pass is unsafe. It can
exhaust shared business-use-case quota, make two otherwise identical dry runs
nonrepeatable, and prevent message acceptance from reaching a stable result.
The four Messenger errors also cannot be reclassified as expected unavailability
without first observing their aggregate code/subcode/type and matching a
documented per-user condition.

## Chosen design

### 1. Explicit monotonic expansion

Every invocation requires
`UMI_FBIG_HISTORY_EXPECTED_DATABASE=<expected-database-name>`. The rake process
compares it with `current_database()` in the same process and exits nonzero on
a missing or mismatched value before inbox lookup, writer-lock acquisition,
Meta access, or any importer write. Clone and production commands must pass
their distinct expected names explicitly.

Add `ACK_EXPAND_EXISTING=true` as an apply-only acknowledgement. The
acknowledgement does not weaken validation. It permits an existing archive
configuration only when:

- the stored marker has the known history-import schema;
- its platform and identifier match the selected platform;
- `outbound_policy` is exactly unchanged;
- every non-target marker has one identical predecessor configuration; a
  third distinct configuration is rejected;
- the requested interval contains that unique predecessor interval:
  - requested `since=all`, or requested `since` is no later than stored
    `since`; and
  - requested `before` is no earlier than stored `before`; and
- a stored `since=all` is contained only by requested `since=all`; and
- local archive state is canonical, resolved, unassigned, importer-only, and
  internally linked to a ContactInbox in the target inbox.

An exact requested configuration remains valid without the acknowledgement.
A narrower interval, a different outbound policy, malformed/unknown metadata,
a second predecessor, a duplicate deterministic identifier, or a mutated/live
archive fails before any Meta request or marker write.

Participant identity cannot be known before Meta is queried. During the scan,
every returned pre-existing selected-platform archive must have a Meta
participant source id exactly equal to the linked ContactInbox source id
before any write to that thread. A returned identity mismatch makes the
platform incomplete and prevents marker normalization.

A locally valid pre-existing archive that is absent after exhaustive Meta
cursor traversal is retained and counted as
`predecessor_archive_not_returned`. It does not permanently block
normalization: the local marker/link passed preflight, Meta’s omission is
outside the importer’s control, and an exact future rerun will validate the
participant if the thread becomes visible again.

Configuration validation becomes selected-platform-scoped. Archive
identifiers already contain the platform:

`umi-fbig-history:<inbox-id>:<platform>:<thread-id>`

The current inbox-wide check is unsafe for a staged rollout because a
Messenger-only run should neither validate nor advance Instagram archives.

Preflight scopes the union of:

- conversations whose history-import marker declares the selected platform;
  and
- conversations whose identifier matches the selected deterministic platform
  prefix.

Every marker-owned archive must have its exact expected deterministic
identifier. Prefix impostors, marker-owned identifier mutation, duplicates,
malformed markers, and incompatible state all fail before Meta. A prefix-only
scope would miss an importer archive whose identifier was manually changed and
could let the scan create a second archive for the same thread.

The importer accepts the unique compatible predecessor, the exact target, or
their crash-resume mixture. New archives created during expansion use the
target configuration. Existing predecessor markers remain unchanged while the
platform is scanning.

Only after the selected platform exhausts its conversation cursor without
authentication, pagination, request, lock, returned-archive identity, or
historical-message persistence failure does one database transaction normalize
all that platform’s compatible markers. The transaction locks and
reloads every selected-platform archive and referenced ContactInbox in
deterministic order. It revalidates canonical/importer-only state,
deterministic-identifier uniqueness, allowed configuration, and each current
ContactInbox `contact_id`/`source_id` against the preflight snapshot plus the
captured Meta participant when Meta returned that archive. It then deep-copies
the current `additional_attributes`, replaces only the nested configuration,
asserts the affected count, and commits all-or-none. Ordinary live/agent
writes cannot race between this identity validation and update.

If the process stops before normalization, committed rows remain valid,
predecessor and target markers may coexist, and the same acknowledged
expansion safely resumes. Exact reruns no longer need the acknowledgement once
all selected-platform markers are normalized.

The marker is an invocation-envelope guard, not a claim that Meta made every
item available. Explicitly accepted structurally contentless details and
counted attachment, participant, or profile omissions may remain after
normalization and are retried or reported according to the contracts below.
A `detail=nil` Graph client result is not an accepted omission and keeps the
platform incomplete.

For this history gate, identity verification means every returned pre-existing
archive matched its ContactInbox participant. A locally valid archive Meta did
not return, permanent participant ambiguity on a thread with no existing
archive, and profile returned-id/field-contract failure are counted separately;
they create no wrong record and do not block history-marker normalization.

### 2. Preserve append-only and no-empty behavior

The existing boundaries remain load-bearing:

- one renewable per-channel writer lock;
- exhaustive bounded conversation and per-thread message pagination;
- deterministic archive identifier;
- account-and-inbox-scoped source-id anti-join;
- a second scoped source-id check immediately before insert;
- one transaction per thread; and
- no contact or archive creation until at least one detail is ready to
  persist.

An empty Meta thread, a thread containing only already-present messages, a
policy-skipped thread, or a thread whose absent details are all unavailable
creates no new Contact, ContactInbox, or Conversation.

Existing archives and messages are reused, never deleted, rebuilt, or moved.
New messages append to the same deterministic archive.

The field-level preservation contract is:

- the original 48 Messages and 6 imported Attachments, Active Storage joins,
  and blobs keep every persisted field and association unchanged;
- the 22 Conversations keep ids, identifiers, contact/inbox links, status,
  assignment/read/first-reply state, and all unrelated attributes; only the
  nested import configuration and outward `created_at`, `updated_at`,
  `last_activity_at`, and `agent_last_seen_at` historical bounds may change;
- Contacts keep identity and user-owned data; only documented fill-only
  profile/avatar fields and monotonic incoming `last_activity_at` may change;
  and
- native/live conversations and their messages remain unchanged.

### 3. Exact acceptance for structurally contentless details

Successfully fetched details that pass id/time/sender/recipient validation but
contain blank `message` text and no supported or unsupported attachment
evidence remain absent. Do not invent a Chatwoot message, contact, or archive
from such a detail. Continue to count the existing aggregate
`content_unavailable` counter and add per-platform `contentless_details`
counts.

The strict default is unchanged: without an accepted set, any contentless
detail makes that platform incomplete/nonzero and prevents its marker
normalization.

Every fingerprint-producing dry run, apply, and recovery invocation uses
`OUTBOUND_POLICY=pre_presence`; fingerprint membership is limited to candidates
selected by that policy. After a full dry scan, the importer prints for each
selected platform:

- the exact contentless-detail count; and
- a lowercase SHA-256 fingerprint of a byte-exact, platform-separated
  serialization of the exact Meta mids in that set.

The fingerprint is an audit value, not an identity or recovery mechanism. Do
not print the underlying mids in the aggregate summary or acceptance input.
Build it as follows:

1. Treat every validated mid as a UTF-8 string and reject invalid encoding.
2. A second sighting of one contentless mid anywhere in the same platform is a
   structural duplicate-mid failure; do not silently deduplicate it.
3. Sort mids by their UTF-8 bytes in ascending lexicographic order.
4. Initialize SHA-256 and feed the platform followed by every sorted mid.
   Encode each value as an unsigned 64-bit big-endian byte length followed by
   the exact UTF-8 bytes. There is no delimiter.
5. The count is the number of mids after duplicate validation. The empty-set
   fingerprint hashes only the length-prefixed platform.

Tests pin known digest vectors for empty and nonempty sets, input-order
invariance, platform separation, length framing, and duplicate rejection.

The internal accepted-set parser requires exactly one unique entry for every
selected platform and no entry for an unselected platform. Platform is exactly
`messenger` or `instagram`; whitespace, empty/trailing entries, extra
fields/colons, and duplicate entries are invalid. Count grammar is exactly
`0|[1-9][0-9]*`, with a maximum of 2,147,483,647. Fingerprints are exactly 64
lowercase hexadecimal characters. Input entry order is arbitrary; normalized
startup output uses selected-platform order. A missing input means the
canonical zero count and empty-set fingerprint for every selected platform.
The normalized accepted count/fingerprint map is printed at startup and stored
in the audit log, but it is operational acknowledgement rather than archive
identity configuration.

Parse and validate the acceptance syntax, count/digest grammar,
selected-platform coverage, and canonical missing-input expansion during task
option construction, before writer-lock acquisition, any Meta request, or any
write. Only comparison with the observed count/fingerprint waits for cursor
exhaustion.

The rake interface has exactly two explicit all-history approval modes.
Both require `UMI_FBIG_HISTORY_EXPECTED_DATABASE`, `INBOX_ID`, `DRY_RUN`, and
`UMI_FBIG_HISTORY_APPROVAL_MODE`:

- `unaccepted_probe` requires `DRY_RUN=true`, canonical
  `PLATFORMS=messenger,instagram`, `SINCE=all`,
  `OUTBOUND_POLICY=pre_presence`, and `PROFILE_MODE=defer`. It rejects
  approval-manifest/checksum paths, `ACK_EXPAND_EXISTING`, and any direct
  accepted-set input. Omitted `BEFORE` generates the safe frozen cutoff; an
  explicitly supplied cutoff must meet the same grammar/age rule. The task
  supplies the canonical zero accepted set internally and is expected to exit
  nonzero only for observed exact contentless-set mismatches.
- `approved` requires absolute
  `UMI_FBIG_APPROVAL_MANIFEST_PATH=.../fbig-approval-v1.tsv` and
  `UMI_FBIG_APPROVAL_CHECKSUM_PATH=.../fbig-approval-v1.tsv.sha256`.
  `PLATFORMS` is the only manifest projection control and must be
  `messenger`, `instagram`, or canonical `messenger,instagram`.
  The task derives commit/image, account/inbox/Page/Instagram identities,
  `SINCE`, `BEFORE`, outbound policy, deferred profile mode, and the selected
  accepted count/fingerprint projection only from the validated manifest.
  It rejects manually supplied manifest-bound scope, profile-mode, or
  accepted-set values; apply additionally requires the explicit
  `ACK_EXPAND_EXISTING=true`.

The durable approval artifact stores one combined two-platform manifest.
Approved task construction projects it in memory to exactly the selected
platform entries. Messenger-only commands receive only `messenger`;
Instagram-only commands receive only `instagram`; combined dry runs receive
both in selected-platform order. The rake task never exposes
`UMI_FBIG_HISTORY_ACCEPTED_CONTENTLESS` as an accepted-run override. Any
mode/path/checksum/ownership/parser/projection error fails before
writer-lock acquisition, Meta access, or writes.

During a platform scan, collect the structurally contentless mids in memory.
Compare its exact count and fingerprint with the accepted value only after
cursor exhaustion and before marker normalization:

- exact match: count the omissions, set `degraded=true`, keep those mids absent
  for future exact reruns, and allow otherwise complete history to normalize;
- missing or mismatched acceptance: increment one explicit
  contentless-acceptance-mismatch history exit counter and leave that platform
  incomplete. Apply additionally sets `write_complete=false` and does not
  normalize; dry run retains `write_complete=not_applicable`.

The comparison happens after per-thread commits because buffering an entire
platform would make the importer unsafe and unbounded. A late mismatch retains
already committed messages, contacts, and archives, blocks that platform's
marker normalization, and in apply mode aborts scanning any later selected
platform. Dry run continues across selected platforms so the first no-write
probe can report every exact set. Recovery is
append-only with the same frozen cutoff. A recovery clone taken after a partial
production attempt does not reassert the original total row counts. It must
instead preserve and verify the original 22 archive IDs and 48 message IDs
against their ID-bound hashes, snapshot every importer-created resumable row
from the failed attempt by stable source identity and ID-bound hash, and allow
only the documented predecessor/target marker mixture. The recovery gate proves
that the original rows are unchanged, every additional in-scope row belongs to
the recorded failed attempt, and no duplicate source identity exists; it then
pins that expanded baseline for the resumed clone and production checks. If a
previously accepted mid regains content, its message may commit before the old
fingerprint fails; a new dry scan produces the reduced accepted set, and the
revised-map rerun observes the message through the scoped anti-join, creates no
duplicate, and normalizes.

The accepted path applies only to a successfully returned and fully validated
detail whose text and attachment evidence are empty. It never accepts:

- `detail=nil` from a Graph client error;
- authentication, permission, field-contract, transport, retry, pagination,
  or rate-limit failure;
- id, time, participant, sender, recipient, direction, or platform mismatch;
- attachment download/staging/storage/budget failure.

Exact reruns still request every accepted-but-absent mid. If Meta later returns
recoverable text or attachment evidence, the changed omission fingerprint
makes the old acceptance fail closed; the operator reviews a new dry scan,
imports the recovered message once, and accepts the reduced set. Thus marker
normalization never permanently suppresses recovery.

The runbook first captures an unaccepted `pre_presence` dry result. Because
nonzero is expected, it temporarily disables `errexit` only around the
`rake | tee` pipeline, immediately snapshots the complete `PIPESTATUS` array,
restores strict mode immediately, requires exactly two statuses with producer
status exactly `1` and `tee` status exactly `0`, and requires exactly one
complete terminal summary. It verifies
that the only history exit failures are the reported contentless-set mismatches
and obtains both per-platform fingerprints. Unaccepted-probe mode requires
explicit `PROFILE_MODE=defer`, and every profile/avatar request, outcome, byte,
or change counter must remain zero. Any Graph, pagination, identity,
attachment, or other history exit failure rejects the probe.

The operator then creates the immutable fixed basename
`fbig-approval-v1.tsv` with noclobber. It is a strict UTF-8, LF-terminated,
tab-separated v1 data record—not a shell file—with exactly 25 lines in this
fixed `name<TAB>value` order:

1. `schema_version` (`1`);
2. `repository_commit` (40 lowercase hexadecimal characters);
3. `image_digest` (the exact
   `ghcr.io/shumkov/chatwoot@sha256:<64 lowercase hexadecimal characters>`
   reference);
4. `clone_backup_id` (`YYYYMMDDTHHMMSSZ-<16 lowercase hex>`);
5. `clone_database_name`;
6. `database_dump_sha256`;
7. `source_storage_manifest_sha256`;
8. `restored_storage_manifest_sha256`;
9. `account_id`;
10. `inbox_id`;
11. `facebook_page_id`;
12. `instagram_business_id`;
13. `since` (`all`);
14. `before` (canonical ISO-8601 UTC);
15. `outbound_policy` (`pre_presence`);
16. `profile_mode` (`defer`);
17. `messenger_count`;
18. `messenger_fingerprint`;
19. `instagram_count`;
20. `instagram_fingerprint`;
21. `placeholder_targets_sha256`;
22. `source_dry_log_sha256`;
23. `source_dry_summary_sha256`;
24. `approved_by`; and
25. `approved_at` (canonical ISO-8601 UTC).

The parser requires the exact line count, order, names, one tab per line, final
LF, and valid UTF-8. It rejects missing, duplicate, reordered, or unknown
fields; CR, NUL, embedded LF/tab, invalid encoding, or trailing bytes; and
never sources, evaluates, interpolates, or executes the file. Counts and
fingerprints use the acceptance grammar above; identity fields are positive
canonical decimal integers; the six checksum fields are 64 lowercase
hexadecimal characters; `clone_database_name` matches
`[a-z_][a-z0-9_]*`; and `approved_by` is nonblank and at most 255 UTF-8 bytes.

A fixed `fbig-approval-v1.tsv.sha256` checksum file contains exactly one GNU
`sha256sum`-style line:
`<64 lowercase hex><two spaces><manifest basename><LF>`. The audit directory is
root-owned mode `0700`; manifest and checksum are regular root-owned files mode
`0400`, with neither symlinks nor hard links accepted. Every consumer first
verifies ownership, modes, file type/link count, checksum-file grammar,
basename match, and manifest checksum, then parses the manifest through a
dedicated Ruby data parser.

The `placeholder_targets_sha256` covers the fixed basename
`fbig-profile-targets-v1.tsv`, a second root-owned mode `0400` regular file in
the same `0700` audit directory. It is strict UTF-8 TSV with
exactly six LF-terminated rows, sorted by numeric ContactInbox id, each
`contact_inbox_id<TAB>contact_id<TAB>instagram_source_id`. Every value is a
positive canonical decimal integer; each ContactInbox id and source id is
unique; there are exactly two tabs per row; and the parser applies the same
encoding, control-character, file-type, ownership, mode, link-count, and
non-execution rules as the approval manifest. The baseline query creates this
file with noclobber from the six exact target-inbox contacts whose persisted
name equals `Instagram user #{source_id.last(4)}`. Clone and production
Instagram profile consumers verify its checksum and require every row still to
map the recorded ContactInbox, source id, account, inbox, and Instagram
platform before any Meta request or write. The recorded `contact_id` is
provenance, not a live equality requirement: a legitimate ContactInbox relink
resolves and enriches the current Contact under the write-time locks below.
The write-time exact-name comparison still preserves a concurrent agent edit.

The commit/image, account/inbox/Page/Instagram identities, all-history cutoff,
policy, deferred-profile mode, and accepted-set fields are live history
execution invariants. Every history command
validates them against its selected platform and runtime envelope before
writer-lock acquisition, any Meta request, or any write. The backup id,
database dump checksum, storage-manifest checksums, and source-dry checksums
are clone-provenance evidence: clone acceptance verifies them against the
restored clone, while production verifies their syntax and the enclosing
manifest checksum but does not compare them to live production
database/storage state. Per-command accepted-set values always come from the
validated manifest projection rather than hand-copying values.

The placeholder-target checksum is release-bound metadata in the manifest, but
history commands do not open the sidecar or validate its live Contact mappings.
Only an Instagram-selected profile task requires, opens, and live-validates the
sidecar. Thus missing or changed profile-target state cannot block message
acceptance, apply, marker normalization, or history recovery.

Two fresh clone dry scans with the frozen cutoff and accepted projections must
then exit zero, match aggregate counters and fingerprints, and prove database
and storage immutability; all profile/avatar counters remain zero. Clone
apply/recovery and production
dry/apply/recovery use projections from that same approved manifest. Failed
attempts and their post-attempt scoped snapshots remain in the audit bundle.

Production runs two accepted dry scans; it never creates or modifies approval.
Any production count/fingerprint drift invalidates clone acceptance and sends
the rollout back to a fresh coordinated production clone, unaccepted probe,
review, and new manifest. It is never reapproved ad hoc against production.

### 4. Deferred, rate-aware profile phase

History acceptance, history apply, and history recovery operate only in
deferred profile mode. Unaccepted-probe mode requires explicit
`PROFILE_MODE=defer`; approved mode derives `defer` from the manifest and
rejects a manual profile-mode value. Task-option parsing rejects every other
combination before lock acquisition, Meta access, or writes. In deferred mode
the history importer makes no profile Graph request and downloads no avatar.
It still applies safe evidence already present in the conversation and message
payloads:

- display name: nonblank conversation participant name;
- Instagram username: a nonblank observed incoming listing/detail sender
  username; and
- never derive a display name from a username.

For a new contact, that evidence is applied only inside a successful thread
transaction containing at least one prepared message. For an existing
ContactInbox, the same exact-placeholder/fill-only merge can run when its
Meta-returned thread is encountered even if the thread has no absent message.
Thus deferred profile access does not create data-only contacts and does not
discard participant names already returned by the exhaustive history scan.

After message/attachment recovery is complete, a separate
`umi:fbig:history_profiles` task performs profile enrichment. It shares the
same expected-database guard, inbox/platform validation, writer lock,
callback-free profile merge, safe avatar attach, and aggregate-only logging,
but scans only conversation pages and their participant payloads. It never
requests message pages or details and never creates a Contact, ContactInbox,
Conversation, Message, or historical Attachment. A Meta participant is
eligible only when an exact target-inbox ContactInbox already exists; missing
contacts are counted and skipped. Participants are deduplicated by exact
`[platform, participant_id]`, and a duplicate participant mapping to a
different ContactInbox is a structural failure.

Before Graph access, the task also discovers stable local targets from every
exact UMI history archive for the selected inbox/platforms whose marker is at
the approved target configuration and whose ContactInbox/source/platform
mapping passes the same importer identity validation. This includes both the
22 predecessor archives and every archive created by the full-history apply.
Stable local targets receive a direct profile GET by their persisted source id
even if Meta no longer returns their thread in the later conversation scan.
Duplicate archive/participant/seed sightings deduplicate to one logical lookup
by exact `[platform, participant_id]`; one pair mapping to different
ContactInboxes is a structural failure.

For each platform, the canonical stable-target audit set contains unique
`[platform, source_id]` pairs from those exact importer-owned history
ContactInboxes; the Instagram set additionally includes all six legacy
placeholder seeds. Sort each set by canonical decimal source-id bytes. Feed
SHA-256 the length-prefixed platform followed by every length-prefixed source
id, using unsigned 64-bit big-endian lengths and no delimiter. Report each
platform's positive count and lowercase fingerprint without logging the pairs.
Clone profile approval binds all four values; after production history reaches
idempotency, every production profile command recomputes and requires an exact
match for its selected-platform projection before lock acquisition, Meta
access, or writes.

The complete lookup target set is the union of current Meta-returned
participants with exact existing ContactInbox mappings and the stable local
targets. When `instagram` is selected, the stable set includes all six rows in
the immutable placeholder-target file. Seeded rows remain eligible even when
Meta no longer lists their conversation and never create a local row. Every
conversation with no single external participant is counted as ambiguous and
skipped independently; it does not prevent later current or stable targets
from being enriched. Pagination, authentication, target-identity, or mapping
ambiguity remains blocking for the complete scan. Every
stable target gets one terminal aggregate outcome: profile-based enrichment,
already-filled/agent-edited preservation, successful profile with no fillable
data, classified unavailable, or blocking error. Every legacy placeholder seed
additionally reports whether the exact placeholder was repaired, preserved
after an agent edit/already repaired, returned a blank name, was classified
unavailable, or blocked. Completion is invalid unless every stable target and
all six seed-specific outcomes are present. Blank profile data and classified
unavailability remain explicit degradation rather than silently declaring
enrichment complete. A Messenger-only run neither requires/opens the target
file nor issues any Instagram seed request.

Its task options are deliberately separate. Every invocation requires
`UMI_FBIG_HISTORY_EXPECTED_DATABASE`, `INBOX_ID`, `DRY_RUN`,
`UMI_FBIG_APPROVAL_MANIFEST_PATH`, and
`UMI_FBIG_APPROVAL_CHECKSUM_PATH`. The two history-approval paths must be
absolute and have the exact basenames above.

Clone-evidence mode is explicit with
`UMI_FBIG_PROFILE_APPROVAL_MODE=clone_evidence`. It requires the current
database to equal `UMI_FBIG_HISTORY_EXPECTED_DATABASE`, differ from the
clone-evidence-only canonical
`UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME`, and requires canonical
`PLATFORMS=messenger,instagram` plus positive
`UMI_FBIG_PROFILE_GRAPH_DELAY_MS`,
`UMI_FBIG_PROFILE_MAX_CONVERSATION_PAGES`,
`UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS`, and
`UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES`. Clone evidence additionally requires
the current database to equal the history manifest's `clone_database_name`.
Every predecessor-profile path is rejected. A different release/settings
after a production attempt requires coordinated restore and a new fresh clone,
not a production override or predecessor chain.
Each clone evidence run also requires absolute
`UMI_FBIG_PROFILE_STATE_PATH=.../fbig-profile-state-v1.tsv` and
`UMI_FBIG_PROFILE_STATE_CHECKSUM_PATH=.../fbig-profile-state-v1.tsv.sha256`
for the strict source profile-state artifact described below. The exact
mode-specific inputs and settings are reused for every clone command.
`UMI_FBIG_PROFILE_CLONE_PHASE` is exactly `dry`, `apply`, or `idempotency`;
`dry` requires `DRY_RUN=true`, while the other two require `DRY_RUN=false`.
Dry and apply require their sealed clone prestate to equal the source-state
artifact exactly. Idempotency additionally loads the apply attempt's immutable
`fbig-profile-clone-poststate-v1.tsv` plus checksum, requires the current
prestate to equal it exactly, and verifies that the source-to-predecessor
transition contains only eligible enrichment. Clone prestate and poststate are
sealed in every attempt directory. Every normalized clone startup and
terminal summary prints the phase, source/predecessor hashes, history hash,
both expected clone and production database names, commit, and image digest;
profile approval creation takes them only from those verified summaries.

Every state/attempt path is absolute and has its documented fixed basename;
its checksum path appends `.sha256`. Production evidence uses fixed
`fbig-profile-production-run.log` and
`fbig-profile-production-run-summary.tsv` basenames.

Production mode is explicit with
`UMI_FBIG_PROFILE_APPROVAL_MODE=production` and additionally requires absolute
`UMI_FBIG_PROFILE_APPROVAL_MANIFEST_PATH` and
`UMI_FBIG_PROFILE_APPROVAL_CHECKSUM_PATH` paths with the fixed basenames
`fbig-profile-approval-v1.tsv` and
`fbig-profile-approval-v1.tsv.sha256`. `PLATFORMS` is the only profile-manifest
projection control and must be `messenger`, `instagram`, or canonical
`messenger,instagram`; it cannot name a platform outside the manifest's
approved set. A one-platform projection is dry-only; apply and recovery require
the manifest's complete canonical platform set so the clone-reviewed avatar
budget remains one invocation budget. The task derives the allowed platforms,
delay, page ceiling, rate-wait budget, avatar budget, release, and scope only
from that validated profile approval. Supplying any other manual value for
those settings, including `UMI_FBIG_PROFILE_PRODUCTION_DATABASE_NAME`, is a
configuration error. Both predecessor digest fields must be `none`; any
non-`none` value or predecessor path is rejected.

Any Instagram-selected invocation additionally requires the absolute
`UMI_FBIG_PROFILE_TARGETS_PATH=.../fbig-profile-targets-v1.tsv`; a
Messenger-only invocation rejects that variable if supplied. The task has no
history interval, outbound policy, expansion acknowledgement, or contentless
acceptance. Supplying those history-only settings is a configuration error.
The operator wrapper bind-mounts root-owned files read-only at the declared
paths and verifies the exact container digest before invocation. Parse and
validate the complete mode-specific configuration, manifest/checksum and
selected target artifact, account/inbox/channel identity, safe-fetch mode, and
avatar-index preflight before lock acquisition, Meta access, or writes.

Before the first clone profile command, the operator creates strict
`fbig-profile-state-v1.tsv` plus checksum in the attempt directory. It is an
ID-bound, PII-free canonical snapshot of every target-inbox ContactInbox /
current Contact linkage, hashes of the scalar fields in the preservation
matrix, avatar attachment/blob associations, and checksum/size of every
relevant local avatar object. Snapshotting the whole target inbox locally does
not make non-target contacts eligible for a profile request; it ensures that
dynamic Meta-returned targets are also covered by preservation comparison. It
applies the same root-owned `0700` directory, `0400`
regular-file, link-count, checksum, UTF-8/control-character, and non-execution
rules as the manifests. Clone dry proves it unchanged; clone apply and
idempotency compare every original entry and allow only the spec's
fill-only/exact-placeholder/missing-avatar deltas. A cleanup failure or
unexplained target/blob drift blocks approval.

The profile-state file has one exact v1 serialization. Its first four lines are
`schema_version<TAB>1`, `account_id<TAB>N`, `inbox_id<TAB>N`, and
`row_count<TAB>N`. They are followed by exactly `row_count` rows sorted by
numeric ContactInbox id, with no duplicate ContactInbox id, each containing
exactly these 27 tab-separated fields:

1. literal `contact_inbox`;
2. ContactInbox id;
3. SHA-256 of the source id's typed encoding;
4. current Contact id;
5. SHA-256 of the typed ContactInbox fields `created_at`, `updated_at`,
   `hmac_verified`, and `pubsub_token`;
6. SHA-256 of all persisted Contact fields except `id`, `name`, and
   `additional_attributes`;
7. name state (`exact_instagram_placeholder` or `other`);
8. name value SHA-256;
9–20. state and value SHA-256 pairs, in the documented field order, for
   `social_profiles.instagram`, `social_instagram_user_name`,
   `social_instagram_follower_count`,
   `social_instagram_is_user_follow_business`,
   `social_instagram_is_business_follow_user`, and
   `social_instagram_is_verified_user`;
21. SHA-256 of `additional_attributes` after removing only those six paths;
22. avatar state (`absent` or `present`);
23. Active Storage attachment id or `0`;
24. blob id or `0`;
25. SHA-256 of every persisted attachment/blob metadata field;
26. SHA-256 of the local storage object bytes or `-`; and
27. storage object byte size or `0`.

Composite hashes use the typed string-keyed hash encoder below with these exact
preimages:

- field 5 has exactly `created_at`, `hmac_verified`, `pubsub_token`, and
  `updated_at`;
- field 6 has exactly `account_id`, `blocked`, `company_id`, `contact_type`,
  `country_code`, `created_at`, `custom_attributes`, `email`, `identifier`,
  `last_activity_at`, `last_name`, `location`, `middle_name`, `phone_number`,
  and `updated_at`; and
- field 25 has exactly two outer keys. `attachment` contains `id`, `name`,
  `record_type`, `record_id`, `blob_id`, and `created_at`; `blob` contains
  `id`, `key`, `filename`, `content_type`, `metadata`, `byte_size`, `checksum`,
  `created_at`, and `service_name`.

There are no implicit columns, exclusions, aliases, or concatenation. Fields
8–20 hash the single typed value; field 21 hashes the exact projected
`additional_attributes` hash; field 3 hashes the typed source-id string.

All ids/counts/sizes are canonical nonnegative decimals. Hashes are lowercase
64-hex, except the explicit absent-avatar `-`. Username field state is exactly
`absent`, `blank`, or `present`; optional-field state is exactly `absent` or
`present`, so `nil`, `false`, and zero remain present values. An absent value
uses hash `-`; every non-absent value uses its typed hash. Snapshot creation
fails on invalid UTF-8, unsupported Ruby values, duplicate Contact/avatar
associations, or missing blobs/objects. Target construction separately fails
when one selected pair resolves to multiple ContactInboxes or multiple
selected participant identities resolve to one current Contact.

Projecting `additional_attributes` removes the five allowed top-level keys and
only the `instagram` leaf from `social_profiles`; it preserves every sibling
key and prunes `social_profiles` only when that parent is empty after
projection. This makes a newly created Instagram-only parent map invisible to
the unrelated-attributes hash without pruning any other empty map.

Avatar tuples are state-dependent. `absent` requires attachment id `0`, blob id
`0`, metadata hash `-`, object hash `-`, and size `0`. `present` requires
positive attachment/blob ids, two lowercase 64-hex hashes, and a canonical
nonnegative size exactly equal to both blob metadata and bytes read. No other
combination parses.

The file is limited to 512 MiB, one million data rows, and 4,096 bytes per
line; its declared row count must equal both parsed data rows and the live
target-inbox ContactInbox count at snapshot creation. It requires one final LF,
rejects CR/NUL/embedded controls/trailing bytes, and uses the same exact
single-line GNU-style checksum grammar and verify-before-parse ordering as the
approval manifest. Snapshot creation rederives the rows from one guarded
database/storage view before sealing the file; later consumers verify its
checksum and complete grammar before using it as approval or same-lineage
recovery evidence.

Typed hashing is byte-exact and shared by snapshot generation/comparison:
the one-byte tags are exactly nil `0x00`, false `0x01`, true `0x02`, integer
`0x03`, finite IEEE-754 double `0x04`, UTF-8 string `0x05`, UTC timestamp
`0x06`, array `0x07`, and string-keyed hash `0x08`. Variable-length values and
collection counts use unsigned 64-bit big-endian framing; integers use
canonical decimal bytes, doubles use big-endian binary64, timestamps use UTC
ISO-8601 with six fractional digits, arrays retain order, and hash keys sort by
UTF-8 bytes before framed key/value encoding. There are no delimiters,
implicit type coercions, or locale-dependent conversions.

The comparator matches snapshots from the same production lineage by
`[contact_inbox_id, source_id_hash]`. IDs are never compared between the
acceptance clone and production. A checksum-verified fresh restore of a
production database remains the same production lineage, so its IDs must
match that attempt's production prestate. It
deterministically buckets each difference as:

- importer-eligible: exact Instagram placeholder to nonblank name; absent or
  blank username to present; absent optional field to present; or absent avatar
  to one valid association/object;
- protected/unattributed: Contact id, immutable Contact/ContactInbox hash,
  user-owned name/profile field, unrelated-attributes hash, existing-avatar
  metadata, reverse/overwrite transition, or any row-set change; and
- blocking: malformed/missing artifact data, selected stable identity/set
  drift, duplicate identity/contact/avatar, missing/orphan storage, a
  production importer change counter greater than the corresponding eligible
  transition count, a clone counter/delta disagreement, or any
  protected/unattributed bucket.

The comparator counts candidate eligible transitions by type. In isolated
clone evidence and writer-quiesced production, applied counters must equal
those counts and every protected/unattributed bucket must be zero. Dry runs
require zero deltas. Without a terminal summary, every nonzero delta is
unattributed and blocks. Aggregate review alone never authorizes a protected
change. Supersession proceeds only after this exact comparison succeeds;
otherwise it stops for investigation/restoration. This spec does not invent
attribution or carry the change forward.

Production profile work does not run beside live writers. Before every
production profile dry/apply/recovery attempt, the operator places ingress in
maintenance, stops Rails web/ActionCable and every Sidekiq/worker process that
can write Chatwoot data, preserves rather than purges queued jobs, and verifies
from the orchestrator plus `pg_stat_activity` that only the digest-pinned
one-off and administrative database sessions remain. This full Chatwoot writer
quiescence stays in place from the fresh pre-attempt backup through prestate,
sealed poststate, comparison, attempt evidence, and any failed-attempt
coordinated backup. Meta
webhook ingress during the window must be buffered or use a clone-verified
retry-safe maintenance response, and delivery recovery must be audited after
service resumes; if the infrastructure cannot prove that boundary, production
profile execution is blocked. No app writer restarts on a task crash, missing
artifact, failed comparison, or unsealed backup.

After writer quiescence is verified and immediately before each production
profile dry/apply/recovery attempt, the root wrapper takes a fresh coordinated
database dump and local-storage archive under one unique backup id. It verifies
the dump restore list, nonempty storage manifest, archive extraction manifest,
and checksums before the profile task may acquire its writer lock or seal
prestate. The operator-level deployment lock and orchestrator check forbid any
other importer one-off between backup completion and task-lock acquisition.
No earlier history-phase or prior-profile-attempt backup may be substituted.

The wrapper builds the backup in a new root-owned `0700` private temporary
directory. Every component is noclobber-created, file-fsynced, made read-only,
and followed by a directory fsync. Only after the semantic restore/extraction
verification below succeeds does the wrapper create and fsync
`fbig-profile-pre-attempt-backup-v1.tsv` plus checksum with
exactly nine ordered fields: `schema_version`, `backup_id`,
`production_database_name`, `image_digest`, `database_dump_sha256`,
`database_restore_list_sha256`, `storage_archive_sha256`,
`storage_manifest_sha256`, and `created_at`. The component files use fixed
sibling basenames `database.dump`, `database.restore.list`, `storage.tar`, and
`storage.manifest`; every digest is lowercase 64-hex. Backup id is
`YYYYMMDDTHHMMSSZ-<16-lowercase-hex>`, the timestamp/image/database grammars
match the approval manifest, and the common ownership, mode, regular-file,
link-count, checksum, UTF-8/control-character, and non-execution rules apply.
The manifest is the only backup digest bound into the production attempt, but
validation recursively verifies every named sibling against its field before
task start or restoration. The wrapper fsyncs the completed directory, renames
the whole directory atomically to its fixed final basename, and fsyncs the
parent directory. The profile task cannot start until that final-directory
seal exists and revalidates.

The backup manifest and components reside in one root-owned `0700`, non-link
directory whose basename is exactly
`fbig-profile-pre-attempt-<backup_id>`; the declared id must byte-match that
basename suffix, and that resolved directory may not equal, contain, or be
contained by production storage. Before task start, the wrapper requires the
backup manifest's production database to equal both `current_database()` and
the validated profile approval, and its image digest to equal both the
approval and the digest-pinned one-off that will execute the task. The later
15-field attempt must repeat those same database/image values and bind this
exact backup-manifest hash. Restoration and supersession re-resolve the
directory, recheck id/path isolation, recursively verify every component, and
require the same database/image equality through the complete approval/attempt
chain. A valid backup from another database, release, or directory is rejected.
The build directory is its sibling with exact basename
`.fbig-profile-pre-attempt-<backup_id>.building`; both final and build paths
must be absent before creation, and the atomic seal is a same-filesystem rename
from that exact build path to the exact final path.

“Recursively verify” is semantic, not checksum-only. Using the exact
digest-pinned PostgreSQL tools, the wrapper regenerates `pg_restore --list`
from `database.dump` and requires byte equality with the bound
`database.restore.list`, then restores the dump into a new empty,
attempt-unique verification database. It verifies the Chatwoot schema-migration
set and the approved account/inbox/channel/Page/Instagram identity envelope
there before dropping that verification target. A list-only check is
insufficient.

Before creating `storage.tar`, the wrapper rejects any source-storage symlink
or non-regular/non-directory entry and builds a canonical manifest from
normalized relative UTF-8 paths, file sizes, and content hashes. Tar validation
rejects absolute paths, `..`, duplicate normalized paths, control characters,
symlinks, hardlinks, devices, FIFOs, sockets, and entries outside documented
size/count/path bounds. The wrapper extracts only into a new empty,
attempt-unique directory whose resolved path is isolated from production,
regenerates the canonical manifest, and requires byte equality with the bound
`storage.manifest` before deleting the verification extraction. No direct
validation extraction into production storage is permitted.

A crash/failure before the atomic final-directory seal leaves no accepted
backup. The wrapper must prove task/prestate/Meta/write counters never began,
then quarantine or remove only the exact incomplete temporary backup directory
after validating its expected parent/basename and isolation. In that branch the
attempt records `pre_attempt_backup_sha256=none`; once the final backup is
sealed, the attempt must use its 64-hex manifest digest even if the task never
starts.

If failed-comparison rollback is required, the root recovery wrapper validates
the immutable profile approval, the attempt's durable pre-task binding, any
sealed failed-attempt manifest, and the recursively checksummed backup. It
restores the bound dump and storage archive into new empty replacement targets
and repeats all semantic checks before cutover. While writers remain stopped,
the regenerated profile-state snapshot must equal the sealed attempt prestate
when present and the application identity/schema checks must pass. Only the
coordinated verified database-and-storage replacement is activated. Sealed
monotonic recovery stages make a crash between storage activation, database
activation, final state verification, and writer resume safely resumable with
the same inputs. The replaced database and storage are retained for audit;
writers do not resume after a partial restore, checksum-only check, identity
mismatch, state mismatch, missing Rails readiness, or missing Sidekiq process.

Every production profile attempt requires a new root-owned attempt directory.
After acquiring the profile writer lock and before Meta or product writes, the
task creates
`fbig-profile-production-prestate-v1.tsv` and checksum with the exact schema
above using a temporary noclobber file, fsyncs it, renews the lease, atomically
seals the fixed basename/checksum, and makes both read-only. Snapshot generation
calls `renew_if_due!` before and after every bounded database batch and storage
object hash, before fsync/rename, and once more before Meta or product writes.
Lock loss deletes only unsealed attempt temp files, creates no final snapshot,
and aborts before Meta/product writes with owner-token-only release.

Every profile invocation also receives a new private avatar
staging-intent directory. Before creating an Active Storage blob row or
uploading an object, the task generates a collision-checked 48-lowercase-hex
blob key and atomically seals and directory-fsyncs one fixed-grammar intent
file containing the sequence, blob key, ContactInbox id, and source-id hash.
The file is named `intent-<canonical-sequence>.tsv` and has exactly five
ordered lines: `schema_version<TAB>1`, `sequence<TAB>N`,
`blob_key<TAB><48-hex>`, `contact_inbox_id<TAB>N`, and
`source_id_sha256<TAB><64-hex>`, with one final LF and the common strict file
rules. Sequence is positive canonical decimal from 1 through 1,000,000 and its
exact unpadded bytes must match the filename component.
Before sealing, both the Active Storage blob-key lookup and exact storage-key
existence check must be empty; collision regenerates the key without creating
an intent. Recovery rejects unexpected final files and removes only incomplete
temporary intent files after proving the task could not have proceeded from
them.
The task must not call blob creation unless that exact final intent is durable;
an intent may therefore exist without a blob after a crash, but a task-created
blob/object cannot exist without an intent. Tests pin this ordering at every
fault boundary. The blob is then created with that exact key.

Before poststate capture on normal return, cleanup enumerates every sealed
intent. An
unattached blob row and/or exact-key storage object is purged and verified
absent. An attachment is retained only when it is the one valid current
target-contact avatar under a live identity-locked DB/storage validation; it
must later match the sealed poststate. An attachment to any other record, a
duplicate, an unparseable intent, an exact-key collision present before intent
creation, or a failed purge blocks. Cleanup never scans or deletes an unlisted
key.

After cleanup, the task seals
`fbig-profile-avatar-staging-v1.tsv` plus checksum. Its three header lines are
`schema_version<TAB>1`, `source_state_sha256<TAB><64-hex>`, and
`entry_count<TAB>N`, followed by exactly `N` rows sorted by canonical sequence.
The source-state digest is the clone source profile-state checksum in clone
evidence and the same attempt's production prestate checksum in production.
Each row has exactly nine tab-separated fields: literal `intent`, sequence,
48-hex blob key, ContactInbox id, source-id hash, terminal outcome
(`attached` or `absent`), blob id or `0`, attachment id or `0`, and object
SHA-256 or `-`. `attached` requires positive ids and an object hash that
matches the live validated avatar tuple; `absent` requires zero ids, `-`, and
verified absence of both DB row and storage object.
The manifest applies the profile-state file bounds, ownership, regular-file,
checksum, UTF-8/control-character, and non-execution rules. Its aggregate
intent/attached/absent outcomes must match the terminal summary when one exists;
purge attempts/failures remain separate diagnostic counters.

On every normal return, before lock release, the task completes staging
cleanup, seals the staging manifest, then captures and seals
`fbig-profile-production-poststate-v1.tsv` plus checksum through the same
snapshot/renewal path. It then cross-validates every staging-manifest
`attached` tuple against the sealed poststate and every `absent` tuple against
the still-absent exact DB/storage key before running the canonical pre/post
comparator against its in-memory counters. It refuses success on any mismatch.
If the task crashes after prestate, the wrapper keeps all writers quiesced and
seals every complete artifact it can observe without inventing missing
evidence. The operator then either accepts a fully sealed, clean normal result
or invokes the coordinated recovery wrapper above. Partial evidence never
authorizes resume or a changed release.

After normal return or crash handling, while writers remain quiesced, the root
wrapper creates immutable `fbig-profile-production-attempt-v1.tsv` plus
checksum with exactly 15 ordered
fields: `schema_version`, `profile_approval_sha256`, `image_digest`,
`production_database_name`, `platforms`, `dry_run`,
`pre_attempt_backup_sha256`, `prestate_sha256`, `poststate_sha256`,
`avatar_staging_sha256`, `run_log_sha256`,
`run_summary_sha256` (`none` if no terminal summary), `exit_status`,
`started_at`, and `finished_at`. It applies the same strict file/parser rules;
`dry_run` is canonical `true`/`false`, platforms match the validated
projection, status is canonical `0..255`, and timestamps are canonical UTC.
The pre-attempt backup hash is 64-hex once backup sealing succeeds and may be
`none` only when the wrapper stopped before the atomic final backup seal and
proved the task/prestate/Meta/write phases never began. On nonzero failure,
each prestate, poststate, staging, and terminal-summary hash independently
records a complete sealed artifact or `none`; honest partial evidence is
retained for recovery and never treated as success. Exit zero requires the
backup hash, all three state/staging hashes, and the one terminal-summary hash
to be present 64-hex values. This artifact binds the immediate
recovery point, same-production pre/post states, and complete staged-key
disposition to the exact immutable run log and extracted single
terminal-summary file (or explicit absence). Recovery verifies those files
against the attempt hashes before using counters.

An exit-zero attempt may resume writers only after staging cleanup and the
pre/post comparison are clean. A failed comparison never resumes writers
until the recovery wrapper restores and verifies that attempt's exact
checksum-verified pre-attempt backup. Ordinary logs expose no names, ids, URLs,
or profile payloads.

After clone profile dry, apply, and zero-write idempotency passes are clean, the
operator creates immutable `fbig-profile-approval-v1.tsv` plus its checksum
with the same strict UTF-8 TSV, fixed-order, exact-field, ownership/mode/link,
checksum, and non-execution rules as the history manifest. It has exactly 31
lines:

1. `schema_version` (`1`);
2. `history_manifest_sha256`;
3. `repository_commit`;
4. `image_digest`;
5. `clone_database_name`;
6. `production_database_name`;
7. `account_id`;
8. `inbox_id`;
9. `facebook_page_id`;
10. `instagram_business_id`;
11. `platforms` (`messenger,instagram`);
12. `graph_delay_ms`;
13. `max_conversation_pages`;
14. `max_rate_limit_wait_seconds`;
15. `max_avatar_download_bytes`;
16. `placeholder_targets_sha256`;
17. `predecessor_profile_approval_sha256` (reserved; `none`);
18. `predecessor_production_attempt_sha256` (reserved; `none`);
19. `source_profile_state_sha256`;
20. `messenger_stable_target_count`;
21. `messenger_stable_target_fingerprint`;
22. `instagram_stable_target_count`;
23. `instagram_stable_target_fingerprint`;
24. `clone_profile_dry_log_sha256`;
25. `clone_profile_dry_summary_sha256`;
26. `clone_profile_apply_log_sha256`;
27. `clone_profile_apply_summary_sha256`;
28. `clone_profile_idempotency_log_sha256`;
29. `clone_profile_idempotency_summary_sha256`;
30. `approved_by`; and
31. `approved_at`.

The history/target/state/stable-set/evidence digests are exactly 64 lowercase
hexadecimal characters. The two predecessor fields are both exactly `none`.
Repository/image/identity/database/timestamp/integer grammars match the history
manifest; all positive settings and both stable target counts use canonical
decimal integers; and both database names match
`[a-z_][a-z0-9_]*` and differ. Profile approval creation verifies the rooted
history checksum, duplicated account/inbox/Page/Instagram scope, target
checksum, source profile-state checksum, recomputed per-platform stable target
counts/fingerprints, and all six clone evidence hashes.
It parses exactly one terminal summary per log and verifies its normalized
configuration/counters before noclobber creation. The profile repository
commit/image identify the clone-reviewed runtime used by this rollout.

Every production profile command verifies the profile checksum, profile
manifest, referenced history manifest/checksum, target checksum, both reserved
predecessor fields are `none`, recomputed stable target set,
exact production database, release/scope, and mode before lock acquisition,
Meta access, or writes. The source profile-state digest is clone provenance and
preservation evidence, not a live scalar-equality precondition that could
overwrite or block a later agent edit.

The profile task creates at most one cached logical lookup per unique
`[platform, participant_id]` in one run. A logical lookup can make multiple
HTTP attempts under the bounded retry contract below; the cache stores only
its terminal success, classified-unavailable, or error result:

- Instagram fields: `id`, `name`, `username`, `profile_pic`, `follower_count`,
  `is_user_follow_business`, `is_business_follow_user`, and
  `is_verified_user`.
- Messenger fields: `id`, `first_name`, `last_name`, and `profile_pic`.

Both platforms use Koala against the repository-configured Facebook Graph API
version and existing Facebook Page access token:

`GET /<participant-id>?fields=<platform allowlist>`

This is the Facebook-linked Instagram Messaging contract already used by the
target `Channel::FacebookPage`, not Chatwoot's separate
`Channel::Instagram`/Instagram Login client. The exact host/version/token
source and fields are pinned in Graph-client specs. The operator must not
substitute the current `graph.instagram.com` Instagram Login endpoint because
this inbox does not hold that client/token contract.

Every Graph HTTP attempt made by the profile task feeds one run-local rate
controller. A narrow `Umi::Fbig::SanitizedKoalaApi` subclass retains Koala's
version/token handling, GraphCollection pagination, and error classes, but
overrides the 3.4.0 `api` method at the per-client raw HTTP response boundary.
That lower boundary is required because Koala's `api` raises
`Koala::Facebook::ServerError` for a 5xx before inherited `graph_call` can see
the response. The override mirrors Koala 3.4.0's request copying, access-token
and app-secret proof insertion, parameter sanitization, path normalization, and
`Koala.make_request` call, then sanitizes the returned response before any
Koala error construction. It is instantiated with the third `rate_limit_hook`
argument explicitly `nil`, so inherited global hook configuration cannot
observe these responses.

At that boundary, the subclass parses `x-business-use-case-usage`,
`x-app-usage`, and any present `x-ad-account-usage` through the UMI aggregate
parser. It validates any present JSON/nested shape and nonnegative integer
percentage/`estimated_time_to_regain_access` values, retains only supported
aggregate maxima, and discards ad-account usage after validation. It removes
every Koala `GraphErrorChecker::DEBUG_HEADERS` entry from copied response
headers and the parsed error object before Koala receives either. The task
classifies errors only from allowlisted type/code/subcode/status fields and
never logs the remaining raw body or exception message.

Malformed present metadata raises a fixed-message UMI error before Koala can
parse/log it; absent metadata remains distinct and allowed. For a sanitized
5xx the override explicitly raises the same
`Koala::Facebook::ServerError(status, sanitized_body)` that Koala 3.4.0 would
raise. For lower statuses it returns the sanitized response to inherited
`graph_call`, preserving `GraphErrorChecker`, response-component selection,
and `GraphCollection` behavior. Runtime asserts exact Koala version 3.4.0;
tests pin the superclass method signature and request/signing behavior plus
success, 4xx/429, and 5xx valid/malformed header and error-body paths so a gem
upgrade fails loudly rather than bypassing redaction.

When any reported call-count/CPU/time percentage reaches 80, the controller
waits 60 seconds before its next request and probes again. Each wait is split
into at most 60-second slices. Immediately before every slice, including the
first, the service synchronously renews the writer lease and requires a
positive renewal result. A false result or exception is lock loss: the task
does not start that slice and immediately stops all further sleeping, Graph
calls, scalar writes, avatar downloads/staging, and associations. It still
purges importer-owned unattached staged blobs before exit, retains completed
fill-only writes, reports one lock-loss failure, exits nonzero, and releases
only through the existing owner-token compare-and-delete path. Importer logs
never include raw headers, business object ids, trace ids, or payloads.

On a rate-limit response, use a positive server-provided
`estimated_time_to_regain_access` as minutes, plus bounded jitter. If the value
is absent or zero, retry with 1-, 5-, then 15-minute waits. Every slice uses
the same strict pre-slice lease renewal above. The explicit positive
`UMI_FBIG_PROFILE_MAX_RATE_LIMIT_WAIT_SECONDS` bounds cumulative throttle waits
for the invocation, including preventive pauses, server-directed waits,
fallback waits, and jitter. Jitter is an injected-random 0–5 seconds. The task
never sleeps past the remaining budget: a longer next wait immediately
produces one retryable profile-rate-limit exit failure and stops further
profile requests without undoing completed fill-only writes. No permanent
profile/contract response is retried.

A profile logical lookup permits at most four HTTP attempts total: the initial
attempt plus at most three rate-limit retries. Rate-limit fallback waits before
attempts two through four are 1, 5, and 15 minutes unless a positive
server-estimated regain time replaces that attempt's fallback. Retryable
network/5xx errors retain the existing two-retry bound and also consume the
same four-attempt ceiling; mixed failure classes can never exceed four total
attempts. Conversation-page attempts are bounded and reported separately.
Counters distinguish unique profile logical lookups, profile HTTP attempts,
conversation HTTP attempts, rate-limit retries, and terminal participant
outcomes. A participant success/unavailability/error counter increments once,
only for the terminal logical result.

Rate waits are not the only lease boundary. The profile orchestrator invokes
strict `renew_if_due!` immediately before and after every conversation-page
request and profile HTTP attempt, before every scalar merge transaction, and
before and after every avatar download/stage, association, and cleanup
iteration. Inside scalar and avatar association transactions it renews before
the final write. Ordinary Graph-delay and avatar-retry sleeps use one shared
sleep helper, split into at-most-60-second slices, with `renew_if_due!` before
every slice. A due renewal that returns false or raises has the same lock-loss
behavior above: no later Graph request or product write, mandatory cleanup of
already staged unattached importer blobs, one nonzero lock-loss result, and
owner-token-only release. The last-renewed clock advances only after a positive
renewal.

Every successful profile must return `id` exactly equal to the requested
participant id. A missing/mismatched id is an identity failure and performs no
contact merge. Token authentication is fatal. A permanent profile-specific
permission, consent, privacy, blocked-user, deleted-object, or documented
not-found response returns a narrowly classified `profile_unavailable` result.
An invalid/unsupported-field response remains a contract regression. Any
unclassified client response remains nonzero until an aggregate
error-type/code/subcode diagnostic—never ids or messages—matches a documented
per-user condition and the allowlist change is reviewed. The four observed
Messenger errors therefore remain blocked pending that diagnostic.

Normalize profile evidence once per participant:

- display name: nonblank profile name, then nonblank conversation participant
  name;
- Instagram username: nonblank profile username, while preserving any
  username already filled from history evidence; and
- never derive a display name from a username.

The task parses only allowlisted returned fields and does not persist opaque
profile responses. Dry run performs the same profile reads and reports
projected scalar/avatar changes but does not download avatar binaries or write
contact data. History dry runs do neither: their repeatability and
contentless-set approval are independent from Meta profile quota.

### 5. Callback-free, preservation-first contact merge

Contact enrichment is independent from message recovery and runs through a
dedicated UMI service shared by the deferred history-evidence path and the
profile-only task. It must not call ordinary `Contact#update!`, the live
Instagram webhook builder, `ContactInboxBuilder`, or
`Avatar::AvatarFromUrlJob`.

Name precedence for a new contact is the normalized display-name evidence,
then the existing deterministic platform fallback.

For an existing Instagram contact, replace the name only when the value in the
database exactly equals:

`Instagram user #{contact_inbox.source_id.last(4)}`

The replacement candidate must be nonblank. The update uses a row lock and an
exact compare at write time, so an agent edit wins. Do not prefix-match
`Instagram user`, replace near-matches, or rewrite any other existing name.
Messenger’s existing `Facebook user` is not repaired generically because it
is not source-specific enough to prove importer ownership; participant names
continue to prevent that fallback for new imports.

Instagram username and optional supported fields are fill-only. These fields
are deliberately in scope because the requested goal is as much supported
profile data as Meta permits, not only names and avatars:

- `additional_attributes.social_profiles.instagram`;
- `additional_attributes.social_instagram_user_name`;
- `additional_attributes.social_instagram_follower_count`;
- `additional_attributes.social_instagram_is_user_follow_business`;
- `additional_attributes.social_instagram_is_business_follow_user`; and
- `additional_attributes.social_instagram_is_verified_user`.

Every merge carries stable
`[contact_inbox_id, account_id, inbox_id, platform, source_id]` identity, never
only a cached Contact object. Immediately before a scalar write, start a
transaction, lock/reload the ContactInbox, revalidate that complete identity,
resolve its current `contact_id`, then lock/reload that Contact. A valid
concurrent contact merge/relink therefore moves enrichment to the current
Contact; source/inbox/platform drift is a structural failure and writes
nothing. Under those locks, deep-copy `additional_attributes`, fill only blank
username slots and absent optional keys, and preserve all unrelated social
profiles and attributes. Booleans and zero are present values, not blanks.
Direct column updates avoid callbacks and events.

New-contact sequencing is explicit:

1. normalize participant/listing/detail evidence only after at least one
   message detail is prepared;
2. insert the new Contact/ContactInbox scalar values and archive/messages
   inside the successful thread transaction;
3. commit that transaction; and
4. leave optional profile/avatar enrichment to the separate profile task.

No contact or blob may survive a failed new-contact message transaction.
Existing-contact scalar enrichment is independent and nonfatal to message
recovery. If the ContactInbox unique constraint is won concurrently, roll
back the speculative Contact, reuse the winner, and apply only the same
exact/fill-only enrichment rules.

Never replace an attached avatar. If the contact has no avatar and the
profile supplies `profile_pic`, profile-task apply mode retains the expiring
URL only in its run-local avatar queue. Before any apply-mode Meta request or
write, fail configuration validation if `SafeFetch.allow_private_network?` is
true.

History apply requires the existing explicit positive
`UMI_FBIG_HISTORY_MAX_DOWNLOAD_BYTES` budget for message attachments only.
Profile apply separately requires an explicit positive
`UMI_FBIG_PROFILE_MAX_DOWNLOAD_BYTES` budget for avatars only. Separate
platform and recovery commands each start a new allowance; neither task carries
a remainder between invocations. Dry run reports attachment or avatar URL
counts but cannot project byte size. Each apply tracks staged/downloaded bytes
before its own persistence step.

If a thread’s staged historical attachments would cross the remaining history
budget,
purge every staged blob, commit no messages for that thread, mark the platform
incomplete/nonzero, and block marker normalization. If an avatar would cross
the profile budget, do not upload/attach it and mark enrichment
incomplete/nonzero.
A download that consumes exactly the remaining budget succeeds; “cross” means
strictly greater than the remainder.
A larger profile or history budget requires coordinated restore where
applicable, a fresh clone acceptance run, and a new immutable initial approval.

Do not download avatars while scanning profiles. Queue only the stable
ContactInbox identity tuple above plus the expiring URL, never a Contact
reference. Only after every selected platform finishes its profile scan without
authentication, contract, identity, pagination, or retry failure may apply
spend the profile budget on avatars. Before each download, lock/reload and
revalidate the ContactInbox identity and resolve the current Contact; if it
already has an avatar, preserve it without fetching. After staging and before
association, repeat the ContactInbox lock/revalidation, resolve and lock the
then-current Contact, and recheck its avatar. A valid relink attaches to the
current Contact; identity drift purges the staged blob and fails structurally
without attaching to the stale Contact. Classified per-user unavailability is
allowed. If any selected platform is incomplete, skip the global avatar phase
so a later profile rerun gets fresh expiring URLs and the full reviewed budget.
If interruption loses the queue, rerun the idempotent profile task; it
refetches profiles and retries only fields/avatars still absent.

Use `SafeFetch` with the existing avatar MIME allowlist, 15 MB per-file limit,
public-network enforcement, redirect protection, and bounded timeouts. Stage
a normal Active Storage blob only after its collision-checked key is durable in
the attempt's staging-intent directory, then use the identity-locked
re-resolution above and recheck that no `Contact/avatar` attachment exists. A
concurrent partial unique index on
`active_storage_attachments(record_type, record_id, name)` for
`record_type = 'Contact' AND name = 'avatar'` enforces the `has_one_attached`
contract across importer and live writers. Pre-deploy production verification
must prove the index predicate currently has zero duplicate keys; otherwise
stop without cleanup or migration.

Direct-insert exactly one Active Storage association with
`record_type: Contact`, the Contact id, `name: avatar`, and a normal current
join timestamp. Do not save the Contact. Treat `RecordNotUnique` as a
concurrent winner, retain the existing avatar, and purge the importer blob.
Purge the staged blob if any association step fails. Cleanup must attempt every
staged blob even if one purge raises, then seal the canonical staging manifest
and prove every intent is attached to the intended current avatar or fully
absent from both Active Storage and the storage service. Do not retain or log
the URL.

Profile denial and expected permanent avatar-fetch failures are counted
degradation only and cannot roll back, omit, or change any imported message.
Retry-exhausted profile/avatar transport, upload, association,
download-budget, or orphan-cleanup failures leave history markers untouched but
make profile enrichment incomplete/nonzero. Idempotent profile reruns revisit
existing contacts and retry fields or avatars that remain absent. Cleanup
failure is never reported as success.

Active Storage `MirrorJob` remains the original importer’s one allowed,
counted internal persistence job when mirror storage is configured. Product
jobs and `AvatarFromUrlJob` remain forbidden.

### 6. Result and operator reporting

Keep the existing history scan/write/degraded result and add:

- exact/expandable/incompatible archive configuration counts by platform;
- projected/applied participant-name placeholder repairs and observed-username
  fills;
- attachment bytes used, download-budget exhaustion, storage failures, and
  cleanup failures;
- contact merge races/no-ops; and
- marker normalizations.

The profile task has its own result and prints:

- conversation pages, unique participants, per-platform stable target
  counts/fingerprints/outcomes, existing/missing/ambiguous contact mappings,
  and duplicate-identity failures;
- logical profile lookups, profile HTTP attempts, conversation HTTP attempts,
  successes, classified unavailability, rate-limit pauses/retries, cumulative
  wait seconds, retry exhaustion, lock loss, authentication, identity,
  contract, and error type/code/subcode buckets;
- maximum observed app/business-use-case call-count, CPU, and total-time
  percentages plus maximum estimated regain minutes;
- projected/applied exact-placeholder, username, and optional-field fills;
- avatars offered, preserved, downloaded, attached, raced, and unavailable;
- avatar bytes, staging intents/final attached/final absent, purge attempts,
  budget exhaustion, storage/association/cleanup failures; and
- contact merge races/no-ops.

Unavailable profile/avatar counters use aggregate reason buckets such as
permission/consent, deleted/not-found, identity mismatch, invalid field
contract, unsafe/invalid URL, permanent HTTP, retry exhaustion, storage,
association, budget, and cleanup. They never include ids, names, usernames,
payloads, or URLs.

History dry run must print the generated frozen `BEFORE` value for verbatim
reuse, the three outbound-policy projections, and projected new
archives/messages and participant-evidence changes. Profile dry run reports
projected profile changes and avatar offers; avatar downloadability remains
unknown.

History apply exits nonzero for incomplete history scanning or message
persistence even if some threads committed. It has no profile/API/avatar
completion dimension. Expected per-user profile/URL degradation is visible in
the later profile task and does not make complete history fail. The profile
task exits nonzero for authentication, identity/contract, pagination,
rate-limit-wait-budget, avatar budget/retry/storage/association, or cleanup
failure. Those failures never modify history markers.

## Failure modes

- **Incompatible predecessor:** fail before Meta and before marker writes.
- **Mutated/live archive:** fail before Meta and before marker writes; never
  repair it back to archive state.
- **Interrupted platform:** retain committed rows and predecessor markers;
  rerun the same acknowledged expansion.
- **Graph authentication failure:** abort the run and do not normalize the
  platform.
- **Conversation/message pagination or transient detail failure:** mark the
  scan incomplete, leave predecessor markers, and rerun.
- **Graph client `detail=nil`:** keep the platform incomplete/nonzero and block
  marker normalization; it is not eligible for contentless-set acceptance.
- **Fully validated structurally contentless detail:** create no synthetic
  message; strict default is incomplete/nonzero. Only an exact operator-
  accepted platform count/fingerprint permits degraded completion and marker
  normalization.
- **Ambiguous participant/sender:** do not guess or create a contact; count
  the failed thread.
- **Pre-existing archive not returned by Meta:** retain it, count the API
  omission, and normalize its locally validated marker with the platform.
- **Profile permission/consent/privacy denial:** skip enrichment, continue
  other contacts, and count the unavailable profile.
- **Profile identity/field-contract failure:** perform no merge, mark
  enrichment incomplete/nonzero, stop further profile requests, skip the avatar
  phase, and retry only through the profile task.
- **Profile quota approaching 80%:** pause before the next request in
  strictly lease-renewed slices and report only aggregate utilization.
- **Profile rate limit:** honor the server estimate or bounded fallback waits;
  on wait-budget exhaustion retain completed fill-only changes, exit nonzero,
  and rerun the profile task after quota recovery.
- **Profile lease loss before a wait slice:** do not start the slice or make
  another Graph request; stop every later scalar/avatar write, retain completed
  fill-only changes, purge staged unattached importer blobs, exit nonzero, and
  release only with the owner token.
- **Profile lease loss during ordinary work:** due-renewal checkpoints before
  and after requests/writes/avatar iterations stop subsequent work with the
  same preservation, cleanup, nonzero, and owner-token release contract.
- **Profile lease loss during production prestate capture:** delete only
  unsealed temp artifacts, create no final evidence file, make no Meta request
  or product write, exit nonzero, and release only with the owner token.
- **Production writer quiescence or ingress boundary not proven:** stop before
  the pre-attempt backup, prestate, Meta, or product writes; do not infer safety
  from maintenance mode alone.
- **Pre-attempt backup creation/semantic verification failure:** never start the
  profile task. Prove no sealed backup and no task/prestate/Meta/write phase,
  quarantine or remove only the exact isolated build directory, seal the
  attempt with backup/pre/post/staging hashes `none`, and restore service.
- **Production profile crash after prestate:** keep every application writer
  stopped, seal only complete evidence, and invoke the root recovery wrapper
  with the attempt's durable binding and exact pre-attempt backup. Resume only
  after isolated restore, prestate/state equality, paired activation, and final
  readiness checks succeed.
- **Crash after blob upload but before avatar association:** the already-fsynced
  exact-key intent makes the blob/object discoverable; purge and verify it
  absent before staging manifest or poststate sealing. A missing/malformed
  intent or failed purge blocks service resumption.
- **ContactInbox relink/source drift:** re-resolve under lock before scalar and
  avatar writes; enrich a valid current Contact, but on identity drift write
  nothing, purge any staged blob, and exit nonzero.
- **Multiple selected identities merged into one Contact:** do not mix profile
  data; count a structural ambiguity, write nothing for those identities, and
  exit nonzero for operator review.
- **Profile approval exhaustion/correction:** never enlarge a budget, change an
  image, or edit approval on production. Keep writers stopped, restore the
  attempt's coordinated DB/storage backup, then repeat fresh clone evidence
  and create a new initial approval with both reserved predecessor fields
  `none`.
- **Concurrent archive mutation during normalization:** the all-archive
  transaction locks, reloads, and revalidates before updating, so it rolls
  back without overwriting unrelated attributes.
- **Concurrent agent name/profile edit:** row locking and fill-only/exact
  comparisons preserve the agent value.
- **Concurrent avatar attach:** keep the winner, purge the importer’s
  unattached staged blob, and count the race.
- **Expired/unsafe/invalid avatar:** keep the contact without an avatar,
  continue other contacts, and count the expected permanent reason without
  logging the URL.
- **Download-budget exhaustion:** do not commit a thread whose staged
  attachments cross the remaining budget; do not upload an over-budget avatar;
  an attachment-budget failure blocks history normalization, while an
  avatar-budget failure is isolated to the profile task.
- **Avatar retry/storage/association/cleanup failure:** keep already-committed
  messages and normalized history markers, mark enrichment incomplete, and
  exit nonzero so a controlled profile rerun can finish it.
- **Existing avatar:** do not fetch or replace it.
- **Requests-folder or other Meta omission:** impossible to infer; disclose
  the API boundary in the final report.

## Rejected alternatives

### Delete and rebuild the partial import

Rejected because it would destroy production ids, activity timestamps, read
state, links, and auditability. Model deletion can also emit product side
effects.

### Create a second full-history archive namespace

Rejected because one Meta thread would be split across two Chatwoot archives
and the source-id anti-join would make the split permanent.

### Rewrite production markers manually, then run the existing importer

Rejected because an untested SQL/console mutation can advance the guard before
validating every archive and provides no crash-safe, repeatable operator
contract.

### Remove configuration equality validation

Rejected because it would allow narrower reruns or policy changes that cannot
undo already-imported rows. Expansion must be explicit and monotonic.

### Use Koala's hook or unmodified response-component error path

Rejected because Koala 3.4.0 constructs and raises an API error before selecting
`http_component: :response`; its error initializer parses usage headers and
logs the full malformed value. The importer therefore cannot distinguish
malformed from absent error metadata or enforce redaction after the fact. A
global hook would also affect unrelated live Meta clients, and a per-client
instance inherits the global hook unless `nil` is passed explicitly. The
version-pinned sanitized subclass intercepts both success and error paths before
that parser while continuing to use Koala's HTTP and Graph behavior.

### Run the live Instagram contact builder or avatar job

Rejected because ordinary writes and jobs can overwrite data, emit events,
replace avatars, log signed URLs, or introduce live-channel side effects.

### Enrich every target-inbox contact independently of Meta threads

Rejected because it expands the migration beyond Meta-returned identities and
could issue profile requests for unrelated/manual contacts. Existing contacts
are enriched only when encountered in the profile conversation scan, linked by
an exact importer-owned history archive, or named in the immutable six-row
importer-placeholder target file.

### Import every absent outbound mid with `OUTBOUND_POLICY=all`

Rejected because Chatwoot can retain only one mid for a native multipart
bubble. Exact source-id idempotency cannot prove the other mids are not
user-visible duplicates. The established `pre_presence` boundary remains.

## Test and verification plan

Bug-fix tests are written and run red before implementation:

- an existing exact `Instagram user ####` remains unchanged today even when a
  profile name is available;
- a broader apply against a predecessor archive configuration is rejected
  today.

After implementation, focused specs must prove:

- byte-exact contentless fingerprint vectors for empty/nonempty sets, input
  order invariance, platform separation, length framing, invalid UTF-8, and
  cross-thread duplicate rejection;
- accepted-contentless parser coverage for valid input, arbitrary entry order,
  canonical output order, missing strict default, leading zero/overflow,
  uppercase or malformed digest, whitespace, empty/trailing/extra fields,
  selected/unselected platform, duplicate platform entries, combined-manifest
  storage, and selected-platform projection;
- acceptance configuration errors fail before writer-lock acquisition, any
  Meta request, or any write;
- unaccepted-probe mode is dry-only, canonical two-platform/all/
  `pre_presence`/deferred, rejects approval paths and direct acceptance, and
  generates or validates the frozen cutoff; approved mode requires the exact
  fixed manifest/checksum paths, derives every manifest-bound scope/profile/
  acceptance value internally, allows only the selected-platform projection,
  and rejects manual overrides before the lock, Meta, or writes;
- the manifest parser enforces exact schema/order/bytes, encoding, ownership,
  modes, regular-file/link-count rules, checksum and live-envelope validation;
  rejects missing, duplicate, reordered, unknown, control-character, malformed,
  tampered, or mismatched input; and treats values only as data, never code;
- every fingerprint-producing dry/apply/recovery command requires
  `pre_presence`; `report_all` evidence cannot be accepted;
- strict-default contentless failure; exact accepted-set degraded success with
  no synthetic Contact/Conversation/Message and marker normalization;
  count-only/hash-only mismatch; dry mismatch retaining
  `write_complete=not_applicable`; and a rake degraded-success exit;
- `detail=nil`, request/auth/pagination/identity/participant/validation, and
  attachment failures remain outside the accepted digest and stay fatal;
- every all-history dry/apply/recovery command operates in deferred mode,
  makes zero profile/avatar requests or downloads, and rejects malformed
  approval/profile mode or configuration before any side effect;
- apply mismatch after an earlier thread commit retains append-only rows,
  blocks markers and aborts later selected platforms, while dry run
  continues to report every selected platform;
- a recovery clone after partial production writes preserves the original
  22/48 ID-bound baseline, admits only snapshotted resumable rows from the
  failed attempt and predecessor/target marker mixtures, and does not require
  the total scoped counts to remain 22/48;
- an accepted mid that later regains content can commit before a mismatch, then
  a revised-map exact rerun creates no duplicate and normalizes; and
- two accepted dry runs are repeatable and leave database/storage unchanged;
- one unique compatible predecessor, exact target,
  predecessor/target resume, second/third predecessor rejection, `all`
  ordering, narrower interval, changed policy, malformed marker, duplicate
  deterministic archive, and wrong-platform behavior;
- selected-platform validation/normalization does not inspect or advance the
  other platform;
- markers normalize atomically only after a structurally complete platform
  scan and every returned pre-existing archive was identity-verified; locally
  valid archives Meta omitted are counted and normalized;
- concurrent archive or ContactInbox identity mutation during normalization
  is preserved and rolls back every marker change;
- interruption before normalization resumes without duplicate rows;
- the field-level preservation matrix holds while new rows append;
- no new archive/contact for empty, already-present-only, policy-skipped, or
  all-unavailable threads;
- deferred history still uses participant names and observed incoming
  usernames, repairs only exact placeholders/fill-only fields, and creates no
  contact without a prepared message;
- the profile task scans conversation pages only, never message/detail pages,
  unions current exact-mapped participants with every exact importer-owned
  history ContactInbox and the six legacy seeds, directly looks up stable local
  targets omitted by the later Meta scan, deduplicates exact
  platform/participant ids, enriches only an existing exact target-inbox
  ContactInbox, and never creates contacts, conversations, messages, or
  historical attachments;
- the strict six-row placeholder target file is checksummed and release-bound,
  rejects schema/identity/file-integrity drift before Meta or writes, unions
  omitted native-only targets with Meta-returned participants, deduplicates an
  overlapping target, and requires one repair/preservation/blank-name/
  classified-unavailable/blocking outcome for every seed before completion;
- a seed's recorded Contact id remains provenance across a legitimate pre-run
  ContactInbox relink; stable inbox/source/platform identity is still required
  and the current Contact is resolved under lock;
- stable-target fingerprint vectors pin platform/source-id separation, length
  framing, per-platform sort/projection, deduplication, and mapping conflicts;
  every stable target requires one terminal outcome, and production rejects
  selected-platform count/fingerprint drift before the lock, Meta, or writes;
- clone-evidence profile mode requires the history-manifest clone database and
  rejects production predecessor-approval inputs. It reuses one canonical
  positive settings set across explicit dry/apply/idempotency phases, requires
  dry/apply prestate to equal the source snapshot, and cryptographically chains
  idempotency to the apply poststate. Clone mode requires and reports the
  explicit distinct production
  database name; production rejects that option and derives its name from
  approval. The strict 31-line profile approval parser binds the
  history/placeholder-target/state/stable-target/evidence hashes, exact
  profile release/scope, both database names, platforms,
  delay, page ceiling, wait budget, and avatar budget; production mode derives
  those values only from the validated profile approval and rejects manual
  overrides before the lock, Meta, or writes;
- profile approval requires both reserved predecessor fields `none` and
  rejects predecessor paths or a non-`none` production approval before the
  lock, Meta, or writes;
- a nonzero production attempt retains every independently sealed state,
  staging, and summary hash, using `none` only for an artifact that never
  sealed. Partial evidence is recovery input, never retry authorization.
  Exit-zero parsing requires backup/prestate/poststate/staging/summary hashes.
  A replacement release requires coordinated restore,
  then repeats fresh clone evidence and creates a new initial approval while
  retaining the unused old approval;
- a failed production dry run still seals prestate/poststate/run/
  summary-or-none evidence and proves byte-identical state; a corrected image
  requires coordinated restore and fresh clone acceptance;
- profile-state vectors pin the exact 4-line header/27-field row grammar,
  numeric sorting/duplicate rejection, typed nil/false/zero/string/time/
  collection framing, allowed-field removal, absent-state encoding, avatar
  metadata/object hashing, same-lineage comparison, and every deterministic
  delta bucket; malformed UTF-8/control bytes, size/row/line overflow,
  count/missing/duplicate/order/hash ambiguity, forbidden clone deltas, and
  missing avatar objects fail closed. Every
  production dry/apply/recovery attempt requires verified ingress maintenance
  and full Chatwoot-writer quiescence, takes and recursively verifies a fresh
  coordinated pre-attempt DB/storage backup, captures prestate after lock and
  poststate before release, and seals the strict 15-field attempt artifact that
  binds the backup, both states, and avatar-staging manifest to
  mode/image/log/summary/exit evidence. Backup tests pin DB/image/path/id
  cross-field equality, component/fsync/directory-fsync ordering, atomic
  directory seal, no-sealed-backup crash behavior, regenerated restore-list
  equality, scratch DB restore plus schema/scope identity, hostile tar entry
  rejection, isolated extraction, and regenerated storage-manifest equality.
  State snapshot batches, sealing, and pre-Meta continuation are fault-tested;
  a prestate-capture lease loss leaves no product write, while a later crash
  keeps writers stopped until staging cleanup, poststate/comparison/attempt
  evidence, and the applicable backup/recovery decision are sealed;
- avatar staging fault-injection proves an intent file is atomically sealed and
  directory-fsynced before every exact-key blob creation/upload; crashes before
  intent, after intent, after blob row, after object upload, after attachment,
  and during cleanup are all recovered without an unlisted or unattached
  blob/object. The strict staging manifest grammar/outcome tuples, collision
  refusal, wrong-target attachment block, exact-key-only purge, empty dry-run
  manifest, counter agreement, and transitive attempt validation are pinned;
- an exit-zero attempt resumes writers only after clean staging and pre/post
  comparison plus recursive artifact validation; any nonzero attempt keeps
  writers stopped and retains honest partial evidence until the exact paired
  recovery completes;
- a Messenger-only profile dry projection rejects a supplied Instagram target
  path, neither opens the target sidecar nor makes an Instagram seed request;
  a one-platform apply/recovery projection is rejected, while every
  Instagram-selected run requires all six terminal seed outcomes;
- one cached logical profile lookup per unique platform/participant (including
  unavailable results), separate logical-lookup/HTTP-attempt counters, a
  four-attempt total ceiling across mixed rate/network/5xx failures, correct
  Facebook-linked endpoint/token/version/fields, returned-id validation, fatal
  auth/contract mismatch, narrowly classified nonfatal per-user denial, and
  aggregate-only error type/code/subcode buckets;
- conversation-page headers, profile response-component reads, and structured
  errors all feed one run-local controller without changing global Koala
  configuration; the version-pinned raw-response `api` boundary removes debug
  and usage metadata before Koala success, 4xx/429, or 5xx processing,
  explicitly preserves sanitized `ServerError`, and ignores any global rate
  hook; it validates app/business/ad-account usage JSON/shapes without logging
  raw ids/headers, fails on malformed present metadata, pauses at the
  80-percent threshold, honors positive regain minutes, uses the
  1/5/15-minute fallback, and stops before exceeding the cumulative wait
  budget;
- preventive, fallback, and server-directed waits renew the writer lease
  before every at-most-60-second slice; a false or raised renewal starts no
  sleep, makes no later Graph request or scalar/avatar write, reports lock loss,
  exits nonzero, preserves completed fill-only writes, and uses only
  owner-token compare-and-delete release;
- conversation/profile attempts, scalar transactions, ordinary Graph-delay
  slices, and every avatar stage/association/cleanup iteration invoke the
  specified due-renewal checkpoints; ordinary-work lease loss stops later
  requests/product writes while still purging unattached importer blobs;
- exact placeholder repair, blank candidate, near-match, different suffix,
  agent-edited name, and edit-at-write-time race;
- scalar and queued-avatar relink races re-lock/revalidate the stable
  ContactInbox identity and resolve the current Contact; valid relinks enrich
  the current Contact, while source/inbox/platform drift writes nothing and a
  staged avatar is purged;
- fill-only Instagram username/optional fields preserve existing values and
  unrelated social profiles;
- existing avatar preservation, safe blank-avatar attach, concurrent attach,
  explicit association shape, invalid/expired profile URL, private-network
  configuration refusal, independent history/profile download-budget
  exhaustion, zero-duplicate production index preflight, concurrent partial
  unique index, and `RecordNotUnique` winner cleanup,
  retry/storage/association failure, and complete all-blob cleanup;
- profile/avatar failure does not alter message counts or transaction outcome;
- no product events, callbacks, customer notifications, automations, bots,
  outbound sends, webhooks, `AvatarFromUrlJob`, or Enterprise attachment
  hooks; counted Active Storage MirrorJobs remain allowed; and
- the ContactInbox late-winner path rolls back its speculative Contact and
  leaves no orphan; and
- idempotent profile reruns may fill a previously unavailable profile/avatar
  without reopening history expansion and continue until a final pass performs
  zero contact/profile/avatar writes, with remaining classified permanent
  omissions explicitly counted.

Implementation adds
`docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md`, a focused operator runbook containing
the exact dry-run/apply commands, immutable-baseline snapshot queries,
invariant queries, comparison procedure, and audit-log locations. It does not
introduce a generalized test harness. Every importer command in that runbook
passes the mandatory same-process expected-database name. Before production
apply:

1. Resolve the merged build to an exact registry digest, bind every clone
   one-off to that digest, and repeat full acceptance on a fresh coordinated
   production database/storage clone. Pre-merge candidate evidence does not
   approve a different merged digest. The clone database dump and local
   storage archive share one writer-quiesced backup ID/checksum set; the
   isolated restore must match the nonempty source storage manifest and the
   verified container bind mount before apply.
2. Capture the exact 22 archive and 48 message baseline, including archive
   metadata and imported Attachment/blob/Active Storage associations, as
   ID-bound PII-free hashes. Pin the pre-existing live conversation IDs and
   their stable identity/linkage hashes. Normalize only the documented mutable
   archive history bounds/configuration and compare the same ID sets after
   every apply/recovery. Create the strict six-row placeholder-target file from
   the exact target-inbox ContactInbox/Contact/source mappings and bind its
   checksum into the approval manifest.
3. Verify zero duplicate `Contact/avatar` Active Storage keys before the
   concurrent unique-index migration.
4. Run one `UMI_FBIG_HISTORY_APPROVAL_MODE=unaccepted_probe` dry command with
   canonical `SINCE=all`, `OUTBOUND_POLICY=pre_presence`,
   `PROFILE_MODE=defer`, both platforms, and a generated safe cutoff.
   Immediately snapshot the entire `PIPESTATUS` array, restore `errexit`
   immediately, then require exactly two statuses with rake status `1` and
   `tee` status `0` plus exactly one complete terminal summary. Reject it
   unless the only history exit failures are exact contentless-set mismatches
   and every profile/avatar counter is zero.
5. Review the per-platform count/fingerprint values and create the immutable,
   checksummed, release/clone/scope-bound approval manifest. Then run two fresh
   `UMI_FBIG_HISTORY_APPROVAL_MODE=approved` clone dry scans from the mounted
   manifest/checksum and selected-platform projections, require zero exit,
   compare counts/fingerprints, and prove whole clone database/storage
   immutability across both. No accepted-set/scope value is copied into an
   environment override.
6. Apply Messenger first as the smaller 73-thread canary, loading only the
   manifest's Messenger projection and deferred-profile mode.
7. Verify baseline stability, invariants, and side-effect absence; run exact
   Messenger recovery passes until one pass writes nothing except explicitly
   accepted contentless omissions.
8. Apply Instagram with the same cutoff and only the manifest's Instagram
   projection and deferred-profile mode.
9. Verify all history, contact, placeholder, and observed-username invariants;
   run exact two-platform recovery passes until one pass writes nothing except
   explicitly accepted contentless omissions. Only that final pass is history
   idempotency proof.
10. Create the strict PII-free source profile-state snapshot/checksum. After a
    Meta quota cooldown, run the profile task dry on the clone with an explicit
    rate-limit wait budget. Require no rate-limit, authentication, identity,
    contract, pagination, or structural failure and prove dry-state
    immutability. Inspect only aggregate error type/code/subcode buckets; the
    four observed Messenger errors must remain blocking unless they match a
    documented per-user unavailable condition. Require one explicit terminal
    outcome for every stable target and seeded placeholder, including the
    native-only target if Meta omits its thread.
11. Apply the profile task on the clone with explicit avatar-byte and
    rate-limit-wait budgets. Verify it creates no product/history row, preserves
    existing contact fields and avatars, repairs only exact placeholders and
    blank/absent profile fields, and attaches only safe missing avatars.
12. Rerun the clone profile task until one pass performs zero scalar/avatar
    writes and has zero transient/unclassified failures; classified permanent
    unavailability and successful blank-name seed outcomes remain counted
    degradation, and all six seed outcomes remain present.
13. Hash the exact clone profile dry/apply/idempotency logs and terminal
    summaries and create the immutable 31-line profile approval plus checksum.
    Verify it roots the accepted history scope and six-row target checksum,
    binds the source state, exact per-platform stable target
    counts/fingerprints,
    clone-reviewed profile release/settings, and distinct clone/production
    databases, with both predecessor fields `none`. Production profile commands
    must use production mode and derive every bound setting from this artifact.
14. After clone Redis is removed, create one checksummed terminal acceptance
    manifest. The exact standalone acceptance program and finalizer must be
    written into a root-owned `0700` directory as root-owned `0400`,
    single-link regular files and checksummed **before** the systemd unit is
    started. The exact unit fragment is protected and checksummed before
    `daemon-reload`; drop-ins are forbidden. A checksummed pre-launch effective
    unit descriptor records the fragment path/SHA, exact-one `ExecStart`,
    explicit environment, empty environment-file/pass-environment sets, and
    working directory. The same effective properties and fragment SHA are
    re-read after exit and must match the pre-launch descriptor before the
    invocation id and both program SHAs are bound into the terminal manifest.
    The manifest also binds the merged commit/digest,
    clone/production database names, inbox, history/profile approvals, target
    manifest, clone baseline, final history/profile idempotency summaries, and
    exact unrecoverable-envelope sidecar. A reusable unit's last exit status
    is secondary evidence; a mutable-at-launch program, unbound environment,
    missing/stale/partial directory, or historical post-launch permission
    hardening never authorizes production work. The finalizer holds a
    dedicated root-owned descriptor-verified lock through validate-or-publish
    and uses atomic no-replace publication; concurrent finalizers can only
    validate the same complete pair, never interleave publications. The
    current R4 invocation is rehearsal evidence only and must be repeated from
    this protected pre-launch state.
15. Run the production database migration under the same deployment lock used
    by deploy/history/profile operations. Before creating any fixed production
    evidence, re-prove the Compose and live Rails/Sidekiq digest, both
    `/app/.git_sha` values, migration `20260724000000`, the exact unique/valid/
    ready three-column Contact-avatar partial index and predicate, and zero
    duplicate Contact-avatar rows.
16. Treat every production profile wrapper return as an attempt requiring
    recursive sealed-evidence validation. The wrapper proves both the approved
    digest and `/app/.git_sha` in running Rails/Sidekiq and again inside the
    mutating Rails one-off before it stops at task authorization.
    Exit zero alone is not idempotency:
    the terminal pass must have identical PII-free pre/post snapshots and zero
    scalar/name/username/optional/avatar mutation counters, avatar bytes, and
    mirror jobs. If it writes anything, classify it as another apply and
    continue to a later newly labeled pass.
17. Between every profile maintenance window, seal an audit bound to that
    attempt's manifest. It must prove page and Instagram subscription state,
    completion of the maintenance-interval delivery/retry audit, and
    `zero unrecovered deliveries` before another maintenance window starts. A window
    with no offered deliveries may be recorded honestly as no retry observed;
    it is not evidence that retry delivery itself was exercised.
18. Execute production profile work as a resumable phase sequence: one sealed
    attempt, one evidence-producing delivery audit after the reconciliation
    grace period, then the next attempt. No process-local variable is
    continuity evidence. A final live-database reconciliation must bind the
    exact protected terminal acceptance, approvals, backup, per-platform apply summaries,
    terminal history/profile zero-write evidence, release/schema proof, and
    exact unrecoverable envelope before completion is reported.
19. Generate each production history, profile, delivery-checkpoint,
    delivery-audit, and final-audit phase as a complete standalone script.
    Publish the profile maintenance wrapper and storage artifact helper through
    the same no-replace builder; bind their exact SHAs into every consumer and
    invoke the read-only Python helper explicitly rather than relying on an
    executable, mutable host copy.
    Protect and checksum its exact bytes before execution; do not ask an
    operator to concatenate fences or prepend helpers manually. Syntax-check
    and ShellCheck those exact scripts, and bind their SHAs into their result
    manifests. Root execution rejects a symlinked program root and any
    non-root-owned or group/world-writable ancestor. Acceptance publishes a
    checksum-bound start intent before starting the systemd unit; terminal
    adoption accepts only the newer invocation created by that intent, never a
    retained historical success. The controller and acceptance unit validate
    every binding-derived stack, backup, production-storage, audit, and clone
    path as canonical and link-free beneath root-owned, non-writable
    ancestors before root execution can create files, restore data, or invoke
    Compose. Every delivery checkpoint additionally binds the running image,
    commit, reconciliation-service source SHA, inbox, Page, and Instagram
    identities. Even before deploy, the producer runs read-only from the exact
    candidate image later accepted by gate 14. Final chain validation requires
    every checkpoint to equal that accepted commit/digest/implementation and
    those accepted identities; a candidate change discards and restarts the
    chain.
20. Every production history execution selects exactly one platform and seals
    a result that binds its label,
    canonical log and summary paths and SHAs, selected platforms, dry/apply
    mode, byte budget, release/schema proof, approval SHA, and predecessor
    result. Every Rails one-off resolves through a sealed per-attempt Compose
    override that pins the accepted digest. An apply also binds two distinct,
    successful, zero-write dry results for the same platform and requires
    their terminal summaries to be byte-identical before the first production
    write; every apply result carries the resulting dry-pair SHA. Before Meta
    access or importer writes, it atomically publishes a
    checksummed attempt identity, reconciles durable historical-attachment
    staging intents, and captures a scoped per-platform importer prestate.
    Every staged production blob carries a PII-free marker binding the run,
    account, inbox, platform, and hashes of its thread/message identity before
    upload. Association clears the marker inside the message transaction.
    A resumable finalizer runs under the deployment lock after normal exit or
    interruption, proves that the attempt process is no longer live,
    reconciles and validates staging markers again, captures the scoped
    poststate, and seals per-platform deltas for the complete
    importer-owned graph: created/reused/linked Contacts and ContactInboxes,
    archive identity/configuration/activity bounds, Messages and directions,
    Attachments and Active Storage blob/association state, and marker
    normalization. Shared Contact activity, profile/avatar fields, and ordinary
    Chatwoot timestamps are excluded from the history-attempt continuity graph
    because live webhook/Sidekiq traffic can legitimately mutate them; Contact
    and ContactInbox scope retains stable identity/linkage only. A missing
    terminal summary is classified as an adopted
    interrupted attempt, not erased; the next attempt cannot start until that
    result is sealed into the ordered chain. Thus per-thread commits made
    before a host/process interruption remain attributable. The protected
    program rejects combined-platform production attempts, so each result is
    intrinsically Messenger-only or Instagram-only; combined scans remain
    available only where the approved rake-task interface permits them.
    Snapshot capture applies a conservative count preflight before allocating
    the graph and enforces a 100,000-row / 128-MiB artifact ceiling; exceeding
    either bound is a stop condition requiring a separately reviewed
    streaming implementation, never an in-process best effort.

    The terminal history proof comprises canonical production results for
    separate Messenger and Instagram exhaustive zero-write executions after
    the last writeful attempt for each platform, never operator-supplied
    summary paths. Final reconciliation sums the per-platform live deltas from
    every writeful normal or adopted result and compares those sums with the
    accepted-baseline-to-live deltas. Importer summary write counters must
    equal the same delta for normally completed attempts. Final reconciliation
    also requires zero historical-attachment intent markers, preventing an
    interrupted upload from leaving an untracked blob/object.
21. A history-state validation never accepts an earlier snapshot as current
    evidence. Under the same descriptor-identity-verified deployment lock it
    captures a fresh temporary live snapshot, compares it with the immutable
    baseline, then atomically seals that observation. Delivery and final audit
    hold that same lock continuously from release/schema verification through
    all evidence reads and terminal publication, so a deploy or another
    maintenance phase cannot interleave.
22. Read-only delivery reconciliation starts while clone acceptance is still
    running and emits a checksummed ordered checkpoint chain. The reviewed
    producer configures an effective lower bound of
    `max(service rolling-window start, frozen history cutoff)`: accepted
    history owns every `created_at < cutoff` item, while checkpoint
    zero-missing applies to `created_at >= cutoff` with an inclusive lower
    bound. Every checkpoint
    records the service rolling-window start, effective lower bound, grace-end,
    accepted release/implementation and inbox/Page/Instagram identities,
    subscription evidence, platform summaries, and predecessor SHA; requires
    zero post-cutoff missing/failed/capped/error results; and is taken before
    the prior checkpoint's grace-end can fall outside the next 48-hour window.
    The first effective window starts at the frozen cutoff, adjacent windows
    overlap (`next.effective_start <= previous.grace_end`), and the final
    window ends no earlier than the last maintenance attempt finish.
    Pre-cutoff missing items are accounted for only by the accepted history
    scan and conservation proof. Each
    profile maintenance audit additionally requires its own attempt interval
    to lie inside its checkpoint window. This continuous chain, rather than
    one late 48-hour invocation, proves cutoff-to-completion coverage. A broken
    or missing overlap fails closed and requires a separately reviewed
    backfill/reacceptance decision; a recent zero result cannot conceal an
    older unaudited gap.
23. Profile delivery and final audits use validate-and-skip only for a fully
    sealed, recursively valid result. A partial directory is resumed only
    through explicit monotonic publication stages; it is not deleted or
    silently reused. Every referenced artifact and checksum is individually
    fsynced before the terminal manifest/checksum pair is published, and the
    containing directory is fsynced after every rename/publication boundary.
    These byte-exact checksum and strict TSV rules apply to acceptance,
    history, profile, delivery-checkpoint, delivery-audit, and final-audit
    artifacts: checksum verification compares generated bytes with `cmp`, and
    parsing rejects every blank, comment, malformed, duplicate, reordered, or
    extra row. The acceptance finalizer has explicit validate-and-skip for a
    complete pair, manifest-only checksum publication after revalidation, and
    rejection of checksum-only or mismatched pairs, all under its dedicated
    lock.
24. Final reconciliation seals concrete per-platform scan and outcome totals,
    not hashes alone: pages, threads, message ids, already-present and imported
    directions, policy skips, contentless and API-unavailable omissions,
    attachment offer/download/unavailable/byte counters, non-empty archives,
    currently linked contacts plus created-versus-reused Contact/ContactInbox
    deltas, stable profile targets and terminal
    success/unavailable/blocking outcomes. Aggregate-only profile mutation and
    avatar counters are labeled aggregate. A live stable-target query counts
    and fingerprints exact generated Instagram placeholders remaining. It
    reports an overlap-aware union with `seed_only`, `importer_only`, and
    `seed_and_importer` membership, so a seeded archive target is not
    double-counted. It requires no unclassified target. A remaining placeholder after the
    successful exhaustive final profile scan is explicitly classified as
    `name unavailable during final scan`; genuine unavailable-name outcomes
    may remain, but are reported rather than called repaired.
    Every live count, linkage, placeholder set, and fingerprint comes from one
    repeatable-read transaction (or equivalent consistent database snapshot);
    its snapshot timestamp and transaction identity are bound into the audit.
25. Coverage and mutation aggregation have separate sources. Each platform's
    final exhaustive zero-write history result supplies its pages, threads,
    ids, already-present, policy, omission, fingerprint, and completeness
    totals. For that result, mechanically require:

    - `in_scope_mids_scanned =
      already_present + candidate_incoming + candidate_outbound`;
    - `candidate_outbound = outbound_pre_presence_import +
      outbound_pre_presence_skip`;
    - `candidate_incoming + outbound_pre_presence_import =
      imported_messages + late_already_present +
      <platform>_contentless_details`;
    - `imported_messages = imported_incoming + imported_outgoing`; and
    - `content_unavailable = <platform>_contentless_details`, with zero non-accepted
      detail/API, pagination, cap, authentication, retry, sender, identity,
      storage, or thread failure except the one exact separately fingerprinted
      unrecoverable Instagram envelope.

    The importer adds `in_scope_mids_scanned` as an explicit counter incremented
    only after the `since`/`before` filter; `mids_scanned` remains the raw
    returned-listing count and their difference is reported as
    `out_of_scope_mids`. These mutually exclusive equations classify every in-scope candidate as
    already present (including previously imported), policy-skipped,
    concurrently/late present, currently imported, or exact accepted
    contentless. The unrecoverable envelope is reported outside candidate and
    conversation totals. Actual history writes come only from the summed
    per-platform pre/post DB deltas in the ordered attempt-result chain.
    Actual profile repairs/fills/avatar outcomes come from summed writeful
    profile results; stable-target coverage/outcomes and remaining placeholders
    come only from the final exhaustive zero-write profile result plus live
    reconciliation. Historical attachment offers/omissions come from the
    accepted pre-write production dry summaries and are reconciled with live
    imported-message attachment/omission metadata; persisted attachment counts
    and bytes come from the live database. Repeated scans are never summed as
    mutations.

If a production profile attempt stops after committing rows, keep all
application writers stopped. The root recovery wrapper recursively verifies
the failed attempt, its durable binding, and its exact coordinated backup,
restores the database and storage to isolated targets, proves the regenerated
PII-free state equals the sealed attempt prestate, and activates the pair while
writers remain stopped. It retains the failed database and storage for audit
and resumes only after final state equality, Rails readiness, and a live
Sidekiq process are proven. Sealed monotonic stages make the exact command
resumable after an interruption.

Production follows the same staged sequence under the existing channel lock,
after a fresh coordinated database/local-storage backup under writer
quiescence. Ansible renders `repository:tag@sha256:digest`, and the deployed
Rails/Sidekiq containers must retain the exact digest accepted on the fresh
clone. That `tag@sha256:digest` must be committed to the persistent
infrastructure inventory before the playbook runs so a later ordinary deploy
cannot restore a moving tag. Production history verification uses the
importer-owned ID-bound baseline, not racy whole-database/storage fingerprints
while live writers continue. Before apply, production runs two accepted
`pre_presence` dry scans using deferred-profile projections from the
clone-approved manifest. The protected apply binding checksum-binds both
same-platform dry results, and the program independently proves successful
termination, zero writes, identical summaries, and the accepted release/scope
before it can start;
any omission-set
drift returns the rollout to a fresh clone rather than changing approval on
production. After history reaches the zero-write recovery pass, production
runs profile dry/apply/recovery in production mode with the immutable profile
approval and checksum mounted read-only. A Messenger-only dry canary may run
without opening the Instagram sidecar, but the accepted apply and zero-write
idempotency pass use the complete `messenger,instagram` set and one
clone-reviewed avatar budget per invocation. The task derives the exact
clone-reviewed allowed platforms, delay, page ceiling, wait budget, avatar
budget, release, and scope from that artifact; a dry `PLATFORMS` value only
narrows the projection and no production command can restate or override
another bound value. Immediately before every dry/apply/recovery invocation it
enters verified full-writer quiescence, seals the fresh coordinated
same-production pre-attempt backup, and then captures prestate under the task's
lock; writers remain stopped through poststate, avatar-staging reconciliation,
comparison, and sealed attempt evidence. Any unclassified profile error, lease
loss, or wait-budget exhaustion stops the profile phase without reopening or
rolling back history. Each command and full summary is saved beside the
existing import audit logs. Stop on any new structural failure or invariant
change.

Each production history/profile/checkpoint/audit stage is validate-and-skip when its
complete root-owned artifact and exact checksum already exist. An interrupted
stage resumes only from its last checksummed monotonic publication boundary;
it is never silently rerun under the same label. The delivery-checkpoint
producer re-queries the configured Meta app subscriptions and runs the
cutoff-aware two-platform reconciliation on the required overlapping cadence.
The delivery audit recursively verifies the complete predecessor-linked chain,
requires its first effective bound to equal the frozen cutoff, every adjacent
interval to overlap, and the attempt interval to be contained by the final
checkpoint, with zero post-cutoff missing, failed, capped, or errored results.
No single late 48-hour window is treated as cutoff-to-attempt coverage.

The final live-database reconciliation reports per-platform scan, omission,
archive, message direction, attachment, linked-contact, stable-profile-target,
and remaining exact-placeholder totals and fingerprints. It separately
records pre-existing importer rows from the accepted baseline and current
production writes, and proves the current-write delta equals the sum of every
writeful result in the ordered production history chain. Profile mutation and
avatar counters remain explicitly aggregate because the profile task does not
expose an auditable per-platform mutation split. The completion report says
that all Meta-exposed history was exhaustively scanned and every eligible,
recoverable message was already present or imported; it lists exact classified
omissions and never claims that every historical event or every exposed
profile datum was migrated.

Profile approval is never edited in place. If an attempt exits before sealing
prestate, its attempt artifact must have prestate, poststate, and staging
digests all `none` and prove zero Meta requests, product writes, and staging
intents. The operator retains that unused approval and attempt, restores
service, fixes the preflight/release, and repeats fresh clone evidence against
the same accepted history manifest to create a new initial approval with both
reserved predecessor fields `none`.

If production profile work exits nonzero after prestate because of page
ceiling, quota/wait/avatar budget, lease loss, corrected code, or another
retryable profile-only condition—even after partial scalar/avatar writes—the
operator preserves the manifest, attempt artifacts, logs, and bound backup
while keeping every application writer quiesced. Any protected/unattributed
delta, unresolved staging key, changed image, or changed setting requires
restoring the checksum-verified pre-attempt database and storage artifacts as
one pair. Then create a fresh isolated clone, reprove the history and stable
target invariants, rerun clone profile dry/apply/idempotency, and create a new
initial approval with both reserved predecessor fields `none`.

The same unchanged approval/release/settings may be rerun after a clean,
counter-attributed retryable outcome only by a separately reviewed operator
decision. No manual production override, approval mutation, or non-`none`
predecessor chain is permitted.

## Coordinated recovery

Before history apply, take a fresh coordinated database/local-storage backup
under writer quiescence. Separately, after quiescing writers and immediately
before every production profile dry/apply/idempotency attempt, take and bind
that attempt's fresh coordinated backup as specified above; never use the
older history backup for a profile restoration. Verify each backup's
`pg_restore` list, tar manifest, and checksums, and record:

- existing history archive ids and marker/configuration values;
- existing imported message ids, source ids, content, timestamps, directions,
  and associations;
- existing imported Attachment, Active Storage attachment, and blob
  associations;
- target Contact ids, names, profile attributes, and avatar attachment ids;
  and
- the exact command configuration and container digest.

If profile verification fails, leave writers stopped and invoke
`fbig_profile_recover.sh` with the exact failed-attempt and bound-backup
directories. The wrapper restores and activates PostgreSQL and local storage as
one verified pair; it never restores PostgreSQL alone after new blobs may have
been attached. Do not selectively delete imported rows or restore contact JSON
by hand without a separately reviewed recovery plan. History corruption still
requires a separately reviewed coordinated restore from the pre-history
backup because the profile recovery wrapper deliberately accepts only a bound
profile attempt.

## Implemented files

- `umi/app/services/fbig/history_import_service.rb`
- `umi/app/services/fbig/history_import_graph_client.rb`
- `umi/app/services/fbig/history_import_profile_service.rb` (new)
- `umi/app/services/fbig/history_profile_backfill_service.rb` (new)
- `umi/app/services/fbig/sanitized_koala_api.rb` (new)
- `db/migrate/*_add_unique_contact_avatar_attachment_index.rb` (new,
  concurrent partial index)
- `db/schema.rb`
- `lib/tasks/umi_fbig_history_import.rake`
- focused specs under `spec/services/umi/fbig/`
- `spec/lib/tasks/rake/umi_fbig_history_import_spec.rb`
- `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md`
- `docs/UMI-FBIG-FULL-HISTORY-RUNBOOK.md` (new)
- this spec
- `UMI-PATCHES.md`
- `umi-vps-infra/ansible/roles/chatwoot/files/fbig_storage_artifact.py`
- `umi-vps-infra/ansible/roles/chatwoot/files/fbig_{coordinated_backup,history_run,profile_attempt,profile_recover}.sh`
- `umi-vps-infra/ansible/roles/chatwoot/tasks/main.yml`

No OSS `app/`, Enterprise overlay, frontend, route, initializer, or scheduled
job is planned. The one schema change is the narrow concurrent partial index
that makes the existing `has_one_attached :avatar` invariant enforceable
during this live migration.

## Sources

- Existing design and runbook:
  `docs/UMI-FBIG-HISTORY-IMPORT-SPEC.md`
- Existing importer:
  `umi/app/services/fbig/history_import_service.rb`
- Existing Graph and media boundaries:
  `umi/app/services/fbig/history_import_graph_client.rb`,
  `umi/app/services/fbig/history_import_attachment_service.rb`
- Upstream Instagram profile mapping:
  `app/services/instagram/messenger/message_text.rb`,
  `app/services/instagram/message_text.rb`,
  `app/services/instagram/webhooks_base_service.rb`
- Upstream avatar safety limits:
  `app/jobs/avatar/avatar_from_url_job.rb`
- Meta Conversations API:
  https://www.postman.com/meta/messenger-platform-api/folder/22794852-255610cd-47f5-4f4d-b3fa-71aec360be9a
- Meta Instagram User Profile API:
  https://www.postman.com/meta/instagram/folder/23987686-22b3a5b0-4a51-449a-9299-e3667d69b182
- Meta Graph API rate-limit contract:
  https://developers.facebook.com/docs/graph-api/overview/rate-limiting/
- Meta Messenger examples exposing `x-business-use-case-usage`:
  https://www.postman.com/meta/messenger-platform-api/documentation/iyp204x/messenger-platform-api
- Koala 3.4 per-client `rate_limit_hook` and structured error usage:
  https://github.com/arsduo/koala/blob/v3.4.0/readme.md#rate-limits
