# One Shopify customer, at most one contact (binding guard G)

Status: approved by Ivan on 2026-11-22: prohibit binding one Shopify customer to several contacts,
keep Klaviyo, a new fork release is allowed. Base: `umi-v4.16.0-43` (`7a81028d`).
Evidence and rejected options: shumabit-claude branch `crm-chat-order-link`,
`docs/CRM-CHAT-IDENTITY-DECISION-SPEC.md` (Mechanism; Option 1 gap; Option 2 B/G). Out of scope:
making the sync honour an existing binding ("Option A" there), historical repairs, merges, event moves,
Klaviyo changes. Reviewed by two independent spec reviews (concurrency/feasibility, domain/safety) and two
independent code reviews (concurrency/correctness, regression/safety); their must-fixes are folded in.

## Problem

A contact is bound to a Shopify customer through `contacts.additional_attributes['shopify_customer_id']`.
Several writers set it, and none checks whether another contact already carries the same customer:

- the contact sync creates a second contact for a customer whose bound contact has other identifiers
  (a WhatsApp phone, or an Instagram contact with no identifiers);
- sync `enrich`, the orders sidebar and the commerce panel bind whichever contact they are looking at.

Once two contacts carry customer X, `PaidCustomerLink` holds X's paid events as `customer_ambiguous`:
no contact, no attribution, and the Klaviyo delivery waits. No read API can prove from outside that a
contact is the only one bound, so the rule has to be enforced where the binding is written.

## Rule

*Binding* means setting `shopify_customer_id` to X on a contact that does not already carry X.

**G: refuse to bind contact C to X while any other contact in the account carries X.**

- Writing X again on a contact that already carries X (a refresh) stays allowed.
- G never unbinds, merges or moves anything. The existing duplicate pairs stay exactly as they are.
- Removing a binding (erasure, the compliance phone-only strip, `link_customer` replacing a previous
  customer, an API request with a blank value) is not binding and is not guarded.
- A contact that was redacted but still carries X (possible only through a merge edge case) counts as a
  carrier, so X is not bound again: consistent with erasure.

## Binders

`grep -rn shopify_customer_id` over `app umi lib config enterprise`, plus the generic writers that merge
caller-supplied `additional_attributes`:

| # | Writer | Today | With G |
|---|---|---|---|
| 1 | `Umi::Shopify::ManualLinkService.link_customer`: commerce `PUT …/customer`; `validate_identity!` in `link` for `POST …/links` and `DraftLinkReconcileJob`; `CommerceController#linked_customer_id` on panel `GET` | binds or replaces under the contact lock | raises `CommerceError 'customer_bound_elsewhere'` before any write |
| 2 | `Umi::Shopify::PersistCustomerLink` (core orders sidebar) | binds a blank contact on an exact email/phone match, no lock | skips the write and logs; the orders response is unchanged |
| 3 | `ContactSyncService#enrich` | binds the email/phone-matched contact | writes nothing to that contact, counts `bound_elsewhere` |
| 4 | `ContactSyncService#per_record_create` / `#bulk_create` | creates a new contact carrying X | creates no contact for X while any contact carries X, counts `bound_elsewhere` |
| 5 | `ContactMergeAction` (+ `Umi::Funnel::CustomerMerge`) | the base inherits the mergee's id when it has none | unchanged; not a second binding (below) |
| 6 | Agent contacts API `POST/PATCH /api/v1/accounts/:a/contacts` (merges caller `additional_attributes`) | can write any value | a request that sets a non-blank id the contact does not carry: contact lock → customer lock → check → 422 `{"error":"customer_bound_elsewhere"}`, whole request rolled back; every other request unchanged |
| 7 | Widget `Api::V1::Widget::ContactsController#update/#set_user` → `ContactIdentifyAction` (deep-merges visitor `additional_attributes`; public `website_token`) | a visitor can write any `shopify_*` value | sync-owned `SHOPIFY_KEYS` are dropped from visitor input (UMI technical keys were already refused, see below) |

Draft commands call `link` but never bind: `DraftCommand.validate_draft!` requires the draft's customer
to equal the contact's current binding (or both absent), so `validate_identity!` never reaches
`link_customer`.

Not binders: `PreferLinkedCustomer`, `DraftCommandsController#customer_id`, `PaidCustomerLink`,
`CustomerRedactionService`/`Privacy`/the compliance handler (they read or remove), `LegacyCleanup`,
`HistoricalClassification` (read), and the `shopify_customer_id` columns of `ShopifyOrderAttribution` and
`ShopifyDraftLink` (link rows, not contacts). The public inbox contacts API does not permit
`additional_attributes`; CSV import writes only `company_name` and `city`.

**Residual writers, accepted.** Some writers save the whole `additional_attributes` column from a copy
read earlier: `AvatarFromUrlJob` (`update_columns` after a download), `ContactIpLookupJob`, Enterprise
`CompanyAssociationService`, the core contacts `update` without customer context (no row lock), and
`ContactMergeAction` without `CustomerMerge` (it builds the merged attributes before reloading the
mergee). Each can write back an X that was removed inside its window; none can write an X the contact
never had. This exists today and is outside G's reach; a unique index is impossible while the
historical pairs exist.

## Mechanism

New `Umi::Shopify::CustomerBinding` (umi overlay):

- `lock!(account_id, customer_ids)`: `pg_advisory_xact_lock(hashtextextended('umi-shopify-customer:<account>:<id>', 0))`
  for each id, normalised with `to_s`, deduplicated and taken in ascending string order. It raises unless a
  transaction is open, because a transaction-level advisory lock taken in autocommit is released at the
  end of its own statement and would guard nothing. It uses the same key scheme as the Klaviyo
  `ProfileBinding` lock (`umi-klaviyo:…`), so the two namespaces do not collide in practice; the two-key
  `74219` order lock is a separate key space.
- `bound_elsewhere?(contact, customer_id)`: takes `lock!` for that customer, then lists the contacts of
  the account other than `contact` whose `additional_attributes->>'shopify_customer_id'` equals the id.
  Locking inside the predicate means no caller can check without the lock. When it answers true it logs a
  warning with contact ids only (no email or phone).
- `bound_customer_ids(account_id, ids)`: the same query for a batch with no exclusion, used by the
  create paths after `lock!`.

`->>` returns text, so integer ids written by the REST sync (`42`) and string ids written by the GraphQL
panel (`"42"`) compare equal; Ruby comparisons use `to_s`.

### Why the check is race-free

Every binder runs *lock X → check → write* inside one transaction and holds the advisory lock until
commit. In READ COMMITTED each statement takes a fresh snapshot, so a binder's check runs after the
previous holder of X has committed or rolled back, and sees its binding. Two binders of X therefore
serialise and the second refuses. No binder runs at another isolation level. Writers that only *remove*
bindings do not take X; a concurrent removal can only make G refuse when it might have allowed, never
the reverse.

### Lock placement

The customer lock X is taken **after** the row lock of the contact being bound, and before the link rows
the binder touches next:

```
[account FOR NO KEY UPDATE] → [order advisory 74219] → contact row (the one being bound) → X → attribution / draft / state / conversation rows
```

The bracketed locks are taken only by the paths that already took them before G. This is not a claim
about every lock in the code base (for example `PurchaseSource` and `SettlementCommand` lock a contact
before message rows, and `with_order_lock` creates the financial-state row before taking 74219); it is
where X sits on every path that takes it.

Why after the contact:

- `link_customer` is already called with the contact locked (`validate_identity!` inside
  `@contact.with_lock`; `linked_customer_id` inside `@contact.with_lock`), so those call sites need no
  restructuring.
- A binder decides *whether* it binds from a fresh read of the contact. With the row lock held that read
  is stable, and X is taken only when a new binding is about to be written; a refresh takes no customer lock.
- An `UPDATE` of a contact takes its row lock implicitly. A binder that locked X and then updated an
  unlocked contact would really be taking *X → contact*. So `PersistCustomerLink` and `enrich`, which
  wrote without a row lock, now lock the contact explicitly first, and the contacts API guard does too.

**Per binder, as the code runs:**

| Binder | Locks, in order |
|---|---|
| `PUT …/customer` | account → contact (`link_customer`'s `with_lock`) → X |
| `POST …/links`, order | account → (state row insert) → 74219 → contact → X (`validate_identity!` → `link_customer`) → attribution row → draft row |
| `POST …/links`, draft | account → contact → X → draft row |
| `GET …/` auto-bind | account → contact (`linked_customer_id`) → contact again (re-entrant) → X |
| `DraftLinkReconcileJob` (no account lock) | contact (`prepare_draft`, committed) ; then 74219 → contact → X → attribution row |
| draft commands | account → message → contact; never X |
| `PersistCustomerLink` | contact (`lock!`) → X |
| sync `enrich` | contact (`reload(lock: true)`, before any read that decides) → X only when the contact is blank; `save!` updates the already-locked row |
| sync `per_record_create` | X only, one per transaction; the new row is inserted, no existing contact is locked |
| sync `bulk_create` | X₁ < X₂ < … in one transaction per page; inserts only |
| contacts API `update` | contact (`lock!`; with customer context `CustomerContacts`' `with_lock` on the same row, re-entrant) → X |
| contacts API `create` | X only; the new row is inserted |

### Deadlock analysis

A new wait cycle needs a transaction T1 holding X and waiting for a resource R, and a chain from R's
holder to a transaction T2 that waits for X.

- A waiter for X holds at most: the account row (commerce paths), the order advisory lock, the one
  contact it binds, and — in `bulk_create` only — lower-ordered customer locks.
- A holder of X then touches: the contact it already holds; rows created or linked for that contact
  (attribution, draft, financial state, the contact's conversations through `CommerceProjection.refresh`,
  `CustomerMutation` in the contacts API); inserts of new contacts; higher-ordered customer locks.
- Two commerce binders never both hold X and wait: both take the account lock first. Several customer
  locks in one transaction happen only in `bulk_create`, ascending, so two batches cannot cross even
  when sync runs overlap (the Redis `SyncLock` is a lease that can expire; it is not relied on).

**One residual cycle, detected.** The `customers/redact` handler holds the account lock and, through
`Privacy.redact_customer_orders!` and `apply_redaction`, locks attribution and state rows and then
several contacts. So: T1 `DraftLinkReconcileJob` binding C1 holds C1 and X and waits for attribution A1
in `link_order!`; T3 redact for X holds A1 and waits for contact C2 (matched by email); T2 sync `enrich`
of C2 holds C2 and waits for X. Without G, T2 would not wait. It needs a redact of the same customer, a
reconcile of its draft and a poll enriching an email-matched contact in the same instant. Postgres
detects the cycle and aborts one transaction with `deadlock_detected` (no hang); each party is safe to
abort (job retry; for the compliance side, the durable rechecked retry described under
"Erasure reach"; the poll run retried next tick).

## Per-binder behaviour

**`link_customer(contact, customer)`** (unchanged order of checks, one new one): `contact.with_lock` →
`redacted` → same id: no-op (refresh) → previous id in use: `customer_in_use` →
**`bound_elsewhere?` → `customer_bound_elsewhere`** → write. Commerce actions run inside the
account-locked transaction, so the raise rolls back the whole request (including a financial-state row
`with_order_lock` created) and `rescue_from` renders `422 {"error":"customer_bound_elsewhere"}`:

- `PUT …/umi/shopify/conversations/:display_id/customer` → 422, no write.
- `POST …/links` → `validate_identity!` binds only when the contact is blank and the object has a
  customer → 422, no attribution or draft link, no financial-state row.
- `DraftLinkReconcileJob` → `record_error` sets status `conflict` ("Needs review") and
  `last_error = 'customer_bound_elsewhere'`, like `customer_mismatch`: it is a lasting identity conflict.

**`CommerceController#linked_customer_id`** (panel `GET`): keeps its structure (contact lock, bind only
while still blank). A `customer_bound_elsewhere` refusal is rescued and treated like an inexact match:
the method returns `nil`, so `show` renders 200 with `customer: null`, no order or draft history for that
customer, no `error` key, and the saved `linked` purchases. Returning the matched customer instead would
be wrong: the panel shows `data.customer` as *this contact's* customer, lists its history, and hides the
"also link the customer" hint. The rescue is narrow (only this error; a database error would leave the
transaction aborted). Other `CommerceError`s behave as today.

**`PersistCustomerLink`**: `Contact.transaction { contact.lock!; next unless still blank; next if
bound_elsewhere?; update! }`. The rescue-everything wrapper and the orders response are unchanged.

**`ContactSyncService#enrich`**: `Contact.transaction { contact.reload(lock: true)` → bound to another
customer: `conflicted` (as today) → bound to X: refresh as today, no customer lock → blank and
`bound_elsewhere?`: count `bound_elsewhere`, write nothing → otherwise enrich and bind `}`.
`reload(lock: true)`, not `lock!`: one contact object can be matched by two rows of a page, a failed
`save!` leaves it dirty, and Rails 7.1 refuses `lock!` on a dirty record. "Write nothing" rather than
"skip only `shopify_*`": filling this contact's name, email or phone from a customer it does not carry
would be half an identity merge, and would widen what an erasure of X has to find.

**`per_record_create`**: one transaction per row: `lock!` → `bound_customer_ids` → skip and count
`bound_elsewhere`, or `create!`. **`bulk_create`**: one transaction per page: `lock!` all ids (ascending)
→ one `bound_customer_ids` query → drop and count the bound rows → `Contact.import` the rest. The check
runs under the lock immediately before the insert.

`bound_elsewhere` appears in the existing per-page `[umi-contact-sync] … counters` log line; every
skipped contact or row also logs a warning with ids.

**Cost of the skips.** When X's carrier holds other identifiers, X's own email and phone may never land
on any contact, so an inbound call or message from X's phone does not resolve to a named contact.
Before G the duplicate contact provided that, at the price of making X's paid events ambiguous. This is
the trade-off Ivan approved.

## Existing duplicate pairs

Customers already carried by two or more contacts (three known historical pairs) are left untouched: no
unbind, merge or event move.

- **Refresh is unchanged.** Sync refreshes the one contact a customer row matches by email, else phone,
  as it does today; a pair member that the row does not match stays as stale as it is today. Re-linking a
  member to its own customer in the panel is a no-op. Nothing is frozen that refreshes today.
- **Any new binding of such a customer is refused**: panel 422, sidebar skip and log, sync
  `bound_elsewhere` and log, no new contact created.
- Editing other fields of a pair member through the contacts API, or resending its own id, works as today.
- `PaidCustomerLink` keeps resolving them exactly as today (operator-linked order first, otherwise
  `customer_ambiguous`).

## Merge is not a second binding

`ContactMergeAction` deep-merges the mergee's attributes under the base's, destroys the mergee and
updates the base in one transaction. The base can gain X only from the mergee, which is deleted in the
same commit, so a merge does not add a carrier: two carriers become one, and base Y + mergee X keeps Y
while X leaves with the mergee. A concurrent binder of X sees the mergee (before commit) or the base
(after) carrying X and refuses. Merge needs neither the check nor the lock and is unchanged.

One upstream race remains when customer context is off: two concurrent merges of the same mergee into
two different bases read the mergee before `reload.destroy!` (a 0-row delete does not raise) and can
copy X onto both. `Umi::Funnel::CustomerMerge` locks and reloads both contacts first and closes it.

## Erasure reach (compliance-path change)

The `customers/redact` handler is either/or: when any contact carries the id it redacts those and
returns, and the exact-email fallback runs only when none does. Before G, an unbound contact holding X's
exact email was usually bound by sync, the sidebar or the panel, became a second carrier and was erased
with X. Under G it stays unbound, so the id match alone would no longer reach it.

To keep erasure at its pre-G reach, after redacting the id-bound contacts the handler applies the
existing exact-email fallback (`account.contacts.from_email`) to one more contact, only when that
contact is not in the id set and carries no `shopify_customer_id`. A contact bound to any customer is
never touched by this step; phone-only matching is unchanged; a payload whose id matches no contact
behaves as today. Approved by the coordinator on 2026-11-22.

**Fresh recheck.** Binders do not take the account lock, so the "carries no customer" condition is
re-read under the contact's row lock inside the per-contact savepoint, in the same transaction as the
erasure. A contact bound to customer Y in between is left alone: erasing it would also purge Y's
financial states (`CustomerRedactionService` purges by the customer the contact carries).

**Durable retry, never a dropped erasure.** The step can fail like any other database work, and the
deadlock analysis above names one way: the residual cycle aborts this step's row lock with
`deadlock_detected`. Shopify never redelivers a compliance webhook (the handler always answers 200), so
a failure must not end in a log line. On any error the step's savepoint rolls back and the handler
enqueues the existing durable retry, `Umi::Shopify::CustomerRedactionRetryJob`, with
`unbound_only: true`, before re-raising into the existing `compliance_safely` tracker. In that mode the
job calls `CustomerRedactionService#perform(only_unbound: true)`, which repeats the fresh recheck inside
its own row lock and erases (anonymize; the record is kept) only a contact that still carries no
customer. The avatar purge stays after the database commit, so a storage failure never undoes the
erasure; the retry repeats only the purge. If the contact was bound meanwhile, the service erases
nothing and the job reports a compliance gap through the existing gap reporting (exception tracker and
an error log line; with no tracker DSN in production that is the log line), because the person's email
now sits on a contact that belongs to another customer's erasure. The job's `retry_on StandardError`
(10 attempts, then Sidekiq's own retries) covers further failures; a failure inside the lock rolls the
recheck and the erasure back together.

A contact that already carries a customer when the webhook arrives is skipped before any lock, so the
step takes no row lock it does not need.

The step calls `CustomerRedactionService` directly instead of `apply_redaction`: `anonymize_contact`
enqueues the job *without* the recheck, which could later anonymize a contact bound to Y. Without
conversations the contact is destroyed, as the email fallback does today. The job argument is the
contact id only; no email or other personal data goes into the queue.

## Unchanged

`PaidCustomerLink` resolution; Klaviyo `ProfileBinding` and delivery; `CustomerRedactionService`,
`Privacy`, the compliance handler's redaction of every contact bound to the id, the phone-only strip;
events; draft and order link semantics other than the new refusal; merges; `PreferLinkedCustomer`.

## Generic writers

The coordinator confirmed on 2026-11-22 that Ivan's rule covers these too.

**Widget identify.** `Umi::Shopify::WidgetContactKeys` is prepended to
`Api::V1::Widget::ContactsController` and removes keys from `permitted_params[:additional_attributes]`
before `ContactIdentifyAction` merges them. That controller is the only `ContactIdentifyAction` caller
that passes `additional_attributes`: the widget message and conversation controllers pass fixed keys, and
the public inbox API does not permit them. A website visitor holds only the public `website_token`, so
any customer id it sends is an unverified claim, and under G it would also block the real binding. The
storefront theme never sends `additional_attributes`. Keys the contact already carries are kept: only
the visitor's input is filtered, not the merge result.

The filter drops `CustomerContactMapper::SHOPIFY_KEYS`. The UMI technical keys
(`Umi::Funnel::Configuration::TECHNICAL_KEYS`: `umi_profile_redacted`, `umi_klaviyo_*`,
`umi_customer_projection`) need no filter: `Umi::Funnel::CustomerBoundary`, included in every widget and
public inbox controller, already answers 422 before the action when visitor input carries one of them.
That matters under G, because a visitor who submits someone else's email is merged into that contact,
and marking it erased would keep its customer from ever being bound again. A spec now pins that refusal.

**Agent contacts API.** `Umi::Shopify::ContactBindingGuard` is prepended to
`Api::V1::Accounts::ContactsController`:

- the request names a non-blank `additional_attributes.shopify_customer_id` → guarded; a missing key or a
  blank value → `super` untouched, no extra lock;
- `update`: `Contact.transaction(requires_new: true) { @contact.lock!` → the fresh value equals the
  requested one (refresh) → `super`; otherwise `bound_elsewhere?` → raise
  `CommerceError 'customer_bound_elsewhere'`, else `super` `}`;
- `create`: `Contact.transaction(requires_new: true) { lock!(account, [X])` → `bound_customer_ids`
  non-empty → raise, else `super` `}`;
- a `rescue_from Umi::Shopify::CommerceError` on the controller renders
  `422 {"error":"customer_bound_elsewhere"}` through the existing `render_could_not_create_error`;
- no write may outlive an error response. The guard is prepended after `Umi::Funnel::CustomerContacts`
  (its `config.to_prepare` runs after that `reloader.to_prepare`), so it runs first and its transaction
  encloses the wrapper's. The wrapper's `with_lock`/`transaction` then joins it, and when the wrapper
  rescues its own `ArgumentError` (for example an invalid role after the core create) and renders 422,
  nothing would roll back. So after `super` the guard raises `ActiveRecord::Rollback` when an error
  response was rendered (`performed? && !response.successful?`; a successful action renders only after it
  returns). `requires_new` makes that rollback effective even inside an outer transaction. The refusal
  itself is raised, so it also rolls back in the opposite prepend order.
- the initializer fails loud if `create`/`update` (or the widget's `permitted_params`) disappear from the
  controller classes' own methods; `method_defined?` would be satisfied by the other UMI prepends.

## Failure modes

| Case | Result |
|---|---|
| Two binders of X race | serialised by X; exactly one binds, the other refuses or skips with no write |
| Panel auto-bind refused | `GET` 200, `customer: null`, saved links listed, warning logged |
| Operator links an order/draft, or picks a customer, bound elsewhere | 422 `customer_bound_elsewhere`, whole request rolled back |
| Agent API binds a customer bound elsewhere | 422 `customer_bound_elsewhere`, no write (including other fields of the request) |
| Sync meets a customer bound to another contact | contact untouched or no contact created; `bound_elsewhere` counted and logged |
| Lock helper called outside a transaction | raises |
| The unbound exact-email erasure step fails (including `deadlock_detected` from the residual cycle) | savepoint rolled back, `CustomerRedactionRetryJob(contact_id, unbound_only: true)` enqueued, error tracked; the job rechecks under the row lock and erases, or reports a gap if the contact was bound meanwhile |
| Lock wait exceeds `statement_timeout` (14 s) or `deadlock_detected` | commerce: 500, rolled back; sidebar: logged, orders still render; sync: the poll run fails without advancing the watermark and the next tick retries everything (idempotent), a backfill page is retried by Sidekiq; `enrich`/`per_record_create` deliberately do not count these as `failed`, which would drop the update until the customer changes again |
| Hash collision of two lock keys | the two customers serialise; no correctness impact |
| Check cost | one scan of the account's contacts (the predicate `PaidCustomerLink` and the compliance handler already run) per new binding and one per bulk page; no index, no migration |

X is held for milliseconds, except by a panel `GET` that binds: that transaction also makes its Shopify
reads before commit, as the account and contact locks already did before G. A contact whose matched
customer is carried elsewhere repeats the Shopify search, the customer lock and the warning on every
panel open; that is the price of never binding it.

Operators have no in-product way to move a binding (unlinking a purchase never unbinds the customer).
The 422 text therefore says to leave the purchase unlinked and ask maintenance; it does not suggest
merging contacts, which can leave the survivor with identifiers that no longer match its Klaviyo profile.

## Tests

Red against `7a81028d`, green after (output in the PR):

- `link_customer`: refuses a customer another contact carries (no write); refuses moving a contact onto
  it; an existing pair: refresh of each member is a no-op, a third contact is refused; `link` of an
  order and of a draft refused with no link rows.
- Commerce requests: `PUT …/customer` and `POST …/links` → 422 `{"error":"customer_bound_elsewhere"}`,
  no attribution, no financial-state row, contact unchanged; `GET` → 200, `customer` null, no `error`,
  `linked` listed, contact unchanged.
- `DraftLinkReconcileJob`: refusal → `conflict` + `last_error`, no attribution.
- `PersistCustomerLink`: no bind, orders still rendered.
- Sync: `enrich` writes nothing to a blank email-matched contact when another contact carries X;
  `per_record_create` and `bulk_create` create nothing for X and still create other rows; a pair keeps
  refreshing the matched member.
- Agent contacts API: refusal with no write (with and without customer context); a free customer binds;
  pair members edit as before; `create` refused with no contact created.
- Widget: visitor `shopify_*` keys dropped, existing keys kept; visitor input carrying a UMI technical key
  refused with 422 and no write (pins existing behaviour).
- Compliance: id-bound and unbound exact-email contacts both erased; a contact bound to another
  customer with the same email untouched; with no id-bound contact the email fallback and the phone-only
  strip behave as today.
- Concurrency (`use_transactional_tests = false`, two sessions): a panel `link_customer` holding X racing
  a sync create, and racing a sync `enrich` of another contact, the second session observed waiting on
  the lock in `pg_stat_activity` → exactly one contact carries X.
- Merge: a bound mergee into an unbound base leaves exactly one carrier.
- Regression: manual-link, commerce, draft-command, draft reconcile, sync, poll/backfill, persist-link,
  linked-orders, compliance, erasure-race, customer-identity, contacts and widget controllers, merge,
  funnel and Shopify suites.

## Rollout and rollback

Two commits in one PR into `umi`: the G patch (code, this spec, `UMI-PATCHES.md` row, i18n string) and
a test-only commit pinning the widget's existing refusal of UMI technical keys. No migration. CI builds the preview image. Proposed release tag
`umi-v4.16.0-44`; the deploy belongs to `umi-vps-infra`. Rollback: the previous image digest
(`umi-v4.16.0-43`); bindings written while G was live stay, nothing is unbound. After deploy, read-only:
the poll's `bound_elsewhere` counter and the contacts of the next chat order.
