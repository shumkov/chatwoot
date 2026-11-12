# Funnel bookkeeping writes without fan-out

Status: approved by Ivan on 2026-11-12 and implemented for release `umi-v4.16.0-43`.

## Problem

Since `umi-v4.16.0-15`, Sidekiq runs about 600k jobs a day, up from about 6k. The table gives the hourly
counts from Sidekiq `Performed` lines. Each of the 8 sampled hours, 14:00–22:00 Bangkok on 2026-11-09,
was within 1 % of these figures:

| Job | per hour |
|---|---|
| `Umi::Funnel::CustomerProjectionJob` | 7,499 |
| `EventDispatcherJob` | 7,520 |
| `ActionCableBroadcastJob` | 7,523 |
| `Umi::Funnel::ProfileSyncJob` | 2,500 |
| `Umi::Funnel::SegmentRefreshJob` / `Umi::Funnel::ReconcileJob` | 12 / 12 |

Release `-42` stopped these jobs from logging their arguments. The jobs themselves still run. Almost none
of this work changes anything that a webhook or Klaviyo sees. An operator sees a change through only one
time-relative note line, described under Risks.

## Root cause, measured

The measurements are read-only production queries, counts only, taken 2026-11-09 15:53–16:57 UTC
(22:53–23:57 Bangkok). The `-42` restart came later, at 16:59 UTC, so it does not overlap them.

Account 1 has **833 linked contacts**: a Klaviyo profile id and binding, not redacted. Every one of them
is rewritten roughly every 10 minutes. The `contacts` table took 3,677 UPDATEs in 29.1 minutes and 3,731
in 30.1 minutes, about **7,500/h**.

1. **SegmentRefreshJob: 4,998 writes/h.** `ReconcileJob` (cron `*/5`) calls `ProfileSyncJob.enqueue_due`,
   which enqueues `SegmentRefreshJob`. The job skips itself until `next_sync_at`, which it sets five minutes
   after the end of the previous pass, so it does real work about 6 times an hour. Each pass:
   - loads every contact of the account (23,169 rows) into Ruby;
   - reads two Klaviyo segments;
   - calls `CustomerMutation#perform` for **all 833** linked contacts with
     `snapshot: { 'segments' => { …, 'observed_at' => now } }`.

   That timestamp is new on every pass, so `additional_attributes` always differs and `save!` always issues
   an UPDATE. 6 × 833 = 4,998.
2. **ProfileSyncJob: ~2,500 writes/h.** `acknowledge` sets `next_sync_at` 15 minutes ahead. The job only
   runs after a `*/5` reconcile tick, so each profile is effectively visited every 20 minutes:
   833 × 3 ≈ 2,500/h, within the 3,000/h capacity (250 per tick).
   - Each visit reads the Klaviyo profile.
   - `acknowledge` always writes new `checked_at` and `next_sync_at` values through `CustomerMutation`.
   - It also copies Klaviyo's snapshot timestamps `umi_payment_snapshot_at` and `umi_service_snapshot_at`,
     which the Klaviyo side advances about hourly.
3. **Fan-out.** Each contact UPDATE fires `after_update_commit`:
   - `Umi::Funnel::CustomerContact#enqueue_umi_customer_projection` enqueues `CustomerProjectionJob`
     whenever `custom_attributes` or `additional_attributes` changed at all;
   - upstream `Contact#dispatch_update_event` dispatches `contact.updated`. The sync dispatcher's
     `ActionCableListener` enqueues one `ActionCableBroadcastJob`, which pushes the full contact to every
     agent session of the account. `AsyncDispatcher#dispatch` enqueues one `EventDispatcherJob` before any
     listener runs.

   4,998 + ~2,500 matches the 7,499 projection jobs within rounding. Ordinary traffic adds 21–24 dispatch
   and broadcast jobs an hour on top.

### What actually changes

The 1,082 contacts that carry `umi_klaviyo_sync` were fingerprinted at the start and end of two windows.
Hashes stayed on the host and only counts were read.

| Window | Contacts that changed | What changed |
|---|---|---|
| 29.1 min | 835 | 389 changed beyond `checked_at`/`next_sync_at`/`failed_at`/`segments.observed_at`. Only 2 changed labels, stage, roles, paid count, barter, freshness status, service state or the identity warning. |
| 30.1 min, per field | — | `payment_snapshot_at` (custom attribute and sync copy) and `service.observed_at` changed for **436**. Real changes: `service.state` 2, `revision` 2, `status` 2, `error` 1, segment membership 1, roles 0, other custom attributes 0. |

These are net diffs. A value that changed and changed back inside a window, such as a `status` flap, is
invisible to them. Read them as "about 16 net real changes an hour, seen in two windows on one evening".
The post-deploy job counts are the real measurement.

### Answers

- **Does `CustomerProjection.apply!` save unchanged conversations?** It calls `save!` every time. But the
  833 linked contacts own only **18 non-resolved conversations (17 contacts)**, and an unchanged save
  issues no SQL UPDATE: `conversations` took 6 UPDATEs in the first window and 25 in the second, while
  `contacts` took ~3,700 in each.

  Rails 7.1 still runs `after_update_commit` on an empty save (`@_trigger_update_callback = true`).
  `Conversation#notify_conversation_updation` and `invalidate_filtered_unread_count_conversation` then
  return early because `previous_changes` is empty. This is a wasted job, not write amplification.
- **Does SegmentRefresh re-project every customer every 5 minutes?** Every effective pass, about every 10
  minutes. Each pass writes all 833 linked contacts, and each write enqueues one projection, one dispatch
  and one broadcast.
- **Does ReconcileJob re-sync unchanged profiles?** Yes, by design: every profile about every 20 minutes.
  Every sync writes its timestamps, and those writes fan out like any other contact write.
- **What writes trigger the dispatch and broadcast fan-out?** The two kinds of contact write above. Nothing
  downstream needs them for timestamp-only changes:
  - account 1's two webhooks subscribe only to `message_created`/`message_updated`;
  - the only integration hook (`shopify`) is not in `HookListener`'s `contact.updated` map, which is
    `leadsquared` only;
  - no automation, enterprise or UMI listener consumes it;
  - the dashboard's `onContactUpdate` only refreshes the contacts store;
  - no code sorts or filters contacts by `updated_at`.

## Proposed fix

Persist timestamp-only funnel writes without model callbacks, and re-project open conversations on the
reconcile cadence.

### 1. Freshness-only writes in `CustomerMutation`

`Umi::Funnel::CustomerMutation#perform` is the only writer for segment publishing, profile
`acknowledge`, `record_error`, discovery `observe_discovery` and role submission. Inside its existing
`@contact.with_lock`, which reloads the row, the unconditional `@contact.save!` becomes:

```ruby
# Timestamps that the funnel's own schedulers and freshness checks read back from the row.
FRESHNESS_PATHS = [%w[checked_at], %w[next_sync_at], %w[failed_at], %w[payment_snapshot_at],
                   %w[segments observed_at], %w[service observed_at]].freeze
FRESHNESS_FIELDS = %w[umi_payment_snapshot_at].freeze

if freshness_only?
  @contact.update_columns(@contact.changes.transform_values(&:last)) # rubocop:disable Rails/SkipsModelValidations
else
  @contact.save!
end
```

`freshness_only?` compares `attribute_in_database` against the new values. It is true only when all of
these hold:

- at least one attribute is dirty. A no-op mutation keeps today's `save!`, which writes nothing and still
  dispatches. Operator contact edits call `perform(roles: {})`, and some AI role calls end up unchanged;
- every dirty attribute is `custom_attributes` or `additional_attributes`;
- `custom_attributes` before and after are equal once `FRESHNESS_FIELDS` are removed from deep copies of
  both. The constant is shared with the existing `CONTACT_FIELDS - ['umi_payment_snapshot_at']`
  revision exclusion;
- `additional_attributes` before and after are equal once `FRESHNESS_PATHS` are removed from deep copies of
  `umi_klaviyo_sync`. A path is ignorable only when it exists on both sides.

Anything else takes today's `save!` path. That includes stage, roles and pending/submitted roles, paid
count, barter, `status`, `error`, `service.state`, segment membership, `revision`, `identity_identifiers`,
binding, profile id, conflicts, a first-ever sync, and any key added later.

### 2. Open-conversation re-projection guard in `ReconcileJob`

Today's churn re-projects every open conversation of a linked contact about every 10 minutes. That
matters for one time-relative output. `summary_content` writes
`Service reservation: hold|clear (fresh).` only while `service.freshness` is `fresh`, and freshness is
`service.observed_at` within 2 hours (`customer_projection.rb:20-28, 96`). Under the fix, a write that
moves only `service.observed_at` (stale→fresh), or the 2-hour window simply running out (fresh→stale),
produces no projection. **The guard is required for note correctness.**

Right after `Umi::Funnel::ProfileSyncJob.enqueue_due` in `ReconcileJob#perform`, enqueue
`CustomerProjectionJob.perform_later(contact_id)`, keeping today's signature so an old image can drain
it. Enqueue it for every contact that:

- passes the same linked-contact filter as `enqueue_due`: account, profile id, binding, not redacted;
- and has a conversation matching `CustomerProjectionJob`'s own filter (`where.not(status: :resolved)`,
  that is open, pending or snoozed).

Today that is 17 contacts, about 204 jobs/h, a load that grows with open work. `apply!` is a no-op write
when nothing changed. The guard refreshes the note and `facts` within one reconcile cycle plus `high`-queue
latency, the queue `CustomerProjectionJob` already runs on. Today's cadence is about 10 minutes.

The filter lives in `ProfileSyncJob.linked_contacts`, which `enqueue_due` now also uses, and the enqueue in
`CustomerProjectionJob.enqueue_open`.

### Expected reduction

| | today /h | after /h |
|---|---|---|
| `CustomerProjectionJob` | 7,499 | ~220 (~16 real changes + ~204 guard; target ≤ 400) |
| `EventDispatcherJob` | 7,520 | ~16 from the funnel + ~21 ordinary (target ≤ 100) |
| `ActionCableBroadcastJob` | 7,523 | ~16 from the funnel + ~24 ordinary (target ≤ 100) |
| `ProfileSyncJob`, `SegmentRefreshJob` | ~2,500 / 12 | unchanged (these are the Klaviyo reads) |
| `contacts` UPDATEs | ~7,500 | ~7,500, but no longer bumping `updated_at` |

That is about 22.2k fewer jobs an hour, ~530k a day. What remains is ~70k a day, mostly `ProfileSyncJob`
(~60k). Sidekiq log volume falls in proportion on top of the `-42` cut.

## Risks and why they are acceptable

- **CRM projections and notes.** Every non-time input of `CustomerProjection.state` lies outside the
  freshness set, so a real change still projects immediately. These are stage, roles, paid count,
  history-complete, barter, the profile id, `revision`, `status`, `service.state` and the
  identity-unresolved error. The time-relative input, service freshness, and the stored
  `facts.umi_payment_snapshot_at` are refreshed by the guard within one reconcile cycle. Nothing outside
  `CustomerProjection` reads the stored `facts`. Resolved conversations are not re-projected today either:
  `apply!` returns early. Reopen and unsnooze re-assign the projection in `lock_umi_customer_status`.
- **Funnel segments, stage and Klaviyo sync.** `fresh_membership?`, `fresh_profile?`, `stage_for`,
  `ProfileSyncJob.enqueue_due`, `ClassificationContext` and `CustomerContextReport` all read
  `observed_at`, `payment_snapshot_at`, `checked_at` and `next_sync_at` from the row. `update_columns`
  persists the same JSON. A fresh↔stale `status` flip, a stage change and a membership change are all
  outside the set and keep `save!`. `enqueue_umi_profile_refresh` fires only on binding, email/phone or
  pending-role changes, which also keep `save!`.
- **CRM reminders and the operator queue.** `OperatorQueue` reads the contact row directly. Its
  `revision` already hashes `payment_snapshot_at`, `segments` and `service`, so it keeps changing as
  today.
- **Webhooks and integrations.** No subscriber for `contact_updated` exists today. If one is added later,
  it will not receive timestamp-only noise.
- **Agent UI.** Agents stop receiving ~7.5k `contact.updated` pushes an hour. An open contact sidebar shows
  the "Payment snapshot at" custom attribute until the next real change or a reload.
- **`contacts.updated_at`.** It stops moving for freshness-only writes. No UMI or upstream code sorts,
  filters or renders it for contacts.
- **Skipped callbacks and validation.**
  - `before_save :sync_contact_attributes` only re-derives city/country and the visitor→lead promotion;
    neither input changes here.
  - Avatarable and the enterprise company callbacks key off email, company or `last_activity_at`.
  - There is no search indexing or optimistic locking on Contact.
  - Validation is skipped for freshness-only writes. Today a linked contact that fails validation raises on
    every pass and aborts `SegmentRefreshJob#refresh` partway through. Afterwards only its real changes
    raise.
- **Concurrency.** `update_columns` runs under the same `SELECT … FOR UPDATE` as today's `save!` and clears
  the dirty state. No caller reads `saved_changes`/`previous_changes` after `perform`. `CustomerContextSync`
  and `SegmentRefreshJob#publish` reload.

## Alternatives rejected

- **Skip the SegmentRefresh write when membership is unchanged.** That breaks `fresh_membership?`, which
  needs `observed_at` to advance, and turns every non-buyer stage stale after 15 minutes.
- **Narrow only `enqueue_umi_customer_projection`.** That removes a third of the jobs.
  - Filtering inside `ActionCableListener` or another listener cannot remove `EventDispatcherJob`:
    `AsyncDispatcher#dispatch` enqueues it before any listener runs.
  - Suppressing dispatch would mean a flag plus a prepend onto upstream's private
    `Contact#dispatch_update_event`, which is more code and more rebase exposure than the funnel's own
    write.
- **`save!(touch: false)` / `no_touching`.** These only stop `updated_at`; every callback still runs.
- **Move the timestamps to their own table or Redis.** That needs a migration, a backfill and changes to
  every reader of `umi_klaviyo_sync`. It is too large for the gain.
- **`save! if changed?` in `CustomerProjection.apply!`.** No measurable effect, since empty saves already
  write nothing, and it risks skipping the acts-as-taggable label save path.

## Out of scope, noted

- `SegmentRefreshJob#refresh` loads all ~23k account contacts into Ruby on every pass to find the 833
  eligible ones. A SQL filter like `enqueue_due`'s would be cheaper.
- `ClassificationContext#comparison` includes the whole `umi_klaviyo_sync` blob. A sync write that lands
  during a classifier call marks its result stale (`conversation_classifier.rb:143`), and the conversation
  is not re-classified until a new message arrives. The freshness set could later be reused there. This
  proposal leaves it unchanged, because the timestamps are still written.

## Test plan

A new `spec/services/umi/funnel/freshness_writes_spec.rb` drives the real producers, freezing time with
`travel_to`. The two segment-refresh cases live in `spec/jobs/umi/funnel/segment_refresh_job_spec.rb`, which
already stubs the Klaviyo segment definitions. The forced `ProfileSyncJob` after an operator role edit is
already covered by `profile_sync_job_spec.rb`. Every negative case below must fail on today's code. Scope the `EventDispatcherJob`
assertions to `contact.updated`.

1. **No fan-out for timestamp-only writes.** Each of these, run a second time, enqueues no
   `CustomerProjectionJob`, `contact.updated` `EventDispatcherJob` or `ActionCableBroadcastJob`. Each also
   persists the new timestamps, leaves `updated_at` unchanged and leaves `changed?` false:
   - `SegmentRefreshJob.perform_now` run twice, about 6 minutes apart, with unchanged membership;
   - `CustomerContextSync#perform` with only Klaviyo's `*_snapshot_at` values advanced;
   - `record_error` twice with the same error class;
   - `observe_discovery` twice with the same error and identifiers.
2. **Fan-out preserved for real changes.** Each of these, mixed with timestamp changes the way production
   sends them, still takes `save!` and enqueues all three:
   - membership (`chooser`) changes;
   - a `status` flip;
   - a `service.state` change;
   - a paid-count change;
   - a first-ever sync, where `umi_klaviyo_sync` is absent;
   - a first error and its recovery;
   - an `identity_identifiers` change;
   - `record_submission` (`roles.*.submitted`);
   - a conflict acknowledge, which still writes the `write_conflicts!` note;
   - an unknown new key in `umi_klaviyo_sync`.

   Also: a no-op mutation (`roles: {}`) behaves exactly as today, and an operator role edit still enqueues
   a forced `ProfileSyncJob`.
3. **The guard keeps the note true.** Set up a contact with service `hold`, a non-resolved conversation and
   a "(fresh)" note.
   - Move time past 2 hours. An acknowledge that changes only `checked_at` enqueues nothing. After
     `ReconcileJob` and the projection job run, the projection's `service.freshness` is `stale` and exactly
     one updated note exists.
   - The reverse, stale→fresh, via a `service.observed_at`-only acknowledge, is fixed the same way.
   - None of these is enqueued: a contact with only resolved conversations, an unlinked contact with an
     open conversation, a redacted contact.
4. **Existing specs pass unchanged.** Review found none that depend on callbacks for timestamp-only
   writes:
   - `spec/services/umi/funnel/*` and `spec/jobs/umi/funnel/*`;
   - `spec/enterprise/services/umi/funnel/{customer_projection,customer_captain_lifecycle}_spec.rb`;
   - `spec/requests/umi/customer_labels_spec.rb`;
   - `customer_identity_spec.rb`;
   - `conversation_classifier_spec.rb`.

## Production acceptance

Measure the same hours as the baseline, 14:00–22:00 Bangkok, for at least 8 hours after deploy:

- **Job counts per hour (`Performed`):**
  - `CustomerProjectionJob` ≤ 400;
  - `EventDispatcherJob` ≤ 100;
  - `ActionCableBroadcastJob` ≤ 100;
  - `ProfileSyncJob` still ~2,500;
  - all queues drained.
- **Freshness writes still land:** the maximum age across linked contacts of `checked_at` stays under 30
  minutes, and of `segments.observed_at` under 15 minutes.
- **Callback-path writes fall:** linked contacts with `updated_at` in the last hour drop from 833 to
  roughly the number of real changes. `contacts` `n_tup_upd` stays ~7.5k/h; that only shows the writes
  still happen.
- **Projection invariant** at +15 minutes and +1 hour: for every linked contact with a non-resolved
  conversation and no write in the last 10 minutes, the stored projection's labels, `revision`, `status`
  and `service` equal `CustomerProjection.state(contact)`. Expect 0 mismatches.
- **Smoke:** the operator queue still returns `capabilities.message_window_version: 1`. Capture a CRM
  reminder no-send preview before deploy and compare it after.

## Rollback

Triggers:

- any projection mismatch that lasts longer than one reconcile cycle;
- `CustomerProjectionJob` or `ReconcileJob` errors;
- `checked_at` or `observed_at` stops advancing.

Action: restore the previous image's compose backup, as in the deploy skill. There is no migration, and
`update_columns` writes the same JSON as `save!`, so no data needs repair. A mid-way rollback leaves only
self-healing lag: `updated_at` catches up on the next write, open sidebars miss pushes until reload, and
projections catch up within one old-code cycle (~10 minutes).
