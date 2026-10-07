# Serialize Instagram conversation selection

## Problem and evidence

On 7 October 2026 a shared Instagram post and an ad icebreaker, arriving about
1.6 seconds apart, created two open conversations for the same existing contact
and contact-inbox binding. The first builder keeps its transaction open while
processing attachments. The second transaction cannot see its uncommitted
conversation and creates another. Distinct message IDs mean message deduplication
cannot prevent this. Both messages were retained; no customer duplication occurred.

## Chosen change

In the UMI overlay, prepend a private `set_conversation_based_on_inbox_config`
wrapper to `Messages::Instagram::BaseMessageBuilder`: acquire the existing
contact row with `contact.with_lock` and then call `super`. Selection and creation
run inside the builder's existing transaction, so the lock remains held until
message and attachment processing commits. The waiting builder then performs a
fresh query and reuses the committed conversation. This covers Instagram via the
Facebook Page channel and native Instagram without modifying either core builder.
Use the existing contact-before-conversation lock order used by customer context
and ad attribution. An idempotent initializer checks the patched method still
exists and the two subclasses do not override it.

No new tables, background workers, retries, customer replies, or changed lifecycle
rules. Open/pending/snoozed threads remain reusable; resolved threads get a new
conversation when single-conversation mode is off, and are reused when it is on.
Do not merge or delete the existing incident pair in this patch.

## Research and alternatives

Rails 7.1 `with_lock` reloads the row under SELECT FOR UPDATE within a transaction:
https://api.rubyonrails.org/v7.1.5.2/classes/ActiveRecord/Locking/Pessimistic.html
The existing builders perform a query-then-create without serializing it. UMI's
customer projection already uses the contact-before-conversation lock order.

- Lock an existing conversation: cannot lock a row that does not exist yet.
- Unique open-conversation index: changes upstream semantics globally and requires
  cleanup/migration plus conflict retry; unnecessarily broad for this incident.
- Redis/advisory lock: extra lock namespace or lease semantics without a benefit
  over the existing contact row.
- Contact-inbox lock: narrower across channels, but using the established contact
  lock avoids adding another ordering relationship to contact/conversation writes.
- Force one lifelong conversation: does not fix concurrent first creation and
  changes the agreed completed-request lifecycle.

## Failure modes and limits

Slow attachment processing delays another message and other contact-row writes
for that same contact; unrelated contacts proceed independently. The existing builder error and transaction rollback
behavior is preserved. Lock timeout or deadlock remains an error, not a reason to
create a second thread. No network call is added. Existing contact merge/redaction
semantics are not redesigned. The patch addresses conversation selection for an
existing resolved identity; simultaneous new-contact creation is a separate path. A concurrent merge deleting
the memoized contact can still fail ingestion; this existing identity-change race
is not solved by this patch.

## Verification

Use an isolated PostgreSQL test database, disable transactional fixtures, commit
setup before worker launch, and use two worker connections plus an observer.
Capture swallowed builder exceptions as test failures; assert both retained messages
as well as the final conversation count. Synchronize with queues and PostgreSQL
blocking evidence rather than sleep-based timing. Pause the first
builder during attachment processing, after it has created its conversation but
before commit. Start the second builder with a different source message ID and an
ADS referral. Observe its query blocking with the patch (or completion without the
patch), release the first, and assert one conversation, both messages and the
original referral. Run first without implementation and record failure (two rows),
then the same test with the patch and record success. Bound all waits and clean up
threads/fixtures. Cover both Instagram entry points, resolved/single-thread behavior,
sequential open reuse and unrelated contacts progressing while one is blocked.
Run existing Instagram builder, ad attribution and attachment-resilience suites.
Independent spec and code reviews precede release; deploy through umi-vps-infra,
verify loaded wrapper, health and retained incident messages. No synthetic production
customer messages or fabricated conversion events.

## Review outcome

Two independent reviews accepted the narrow approach. Incorporated requirements:
real committed concurrency fixtures, database blocking evidence, assertions for both
source IDs and swallowed errors, and explicit shared-contact latency/merge limits.
The owner approved fixing this race after the diagnosis; implementation follows the
explained one-at-a-time selection without changing lifecycle or repairing old rows.

## Implementation verification — 7 October 2026

Both concurrent-builder examples failed against the unpatched code with two
conversations instead of one, then passed with the wrapper. The final combined
suite passed all 58 examples: concurrency and lifecycle checks, existing Instagram
builders, ad attribution and attachment resilience. RuboCop passed all three Ruby
files. Two independent code reviews accepted the implementation; the test-cleanup
finding was fixed and verified with scoped persisted-fixture checks before release.

Production deployment is tracked in the canonical umi-vps-infra checkout. Existing
incident conversations are preserved; this patch prevents recurrence rather than
rewriting their history.
