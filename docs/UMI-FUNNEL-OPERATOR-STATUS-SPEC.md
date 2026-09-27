# Confirm funnel status in the existing conversation sidebar

27 September 2026. Draft for review. The current event core accepts confirmed
classifications only through a rake command. It provisions a Sales status field
but deliberately rejects generic writes to that projection. That protects paid
truth, yet leaves the single Chatwoot operator without a usable confirmation
control. Complete the first iteration through the existing sidebar dropdown.

## Choice

Reuse the existing `ConversationsController#custom_attributes` action and native
list custom attribute. The Vue sidebar already sends the full attribute hash to
this authenticated, account-scoped action. A UMI controller prepend can recognize
an explicit changed `umi_sales_status` and call the reviewed transition service.
No new control, endpoint, model judgement, permission system or shell command is
needed for the operator. Small changes to the existing sidebar/store/API wiring
carry the edited attribute key and propagate rejected requests. A new private-note command would work but adds syntax
and message-ID copying where a dropdown already exists. Automatic Shumabit
classification remains a separate later change; Shumabit can suggest a status in
its private analysis and the operator confirms it.

## Contract

Only an enabled funnel account and `Current.user` of type User use the special
path. Existing controller authentication and conversation authorization remain in
place. All other attributes/actions retain upstream behavior. The sidebar forwards `changed_attribute_key` through its store action and API
client, for both edits and deletes. Only `changed_attribute_key ==
umi_sales_status` expresses an explicit status edit. A full stale attribute hash,
a missing marker, or another edited key cannot create a classification; preserve
the current managed sales value while applying ordinary attributes. This is
request intent, not an authentication mechanism. Explicit deletion of the managed
status is rejected visibly, rather than removing it.

When an explicit status edit differs from the current status, require one of the
existing human statuses (unevaluated, engaged, qualified, inactive, not_sales).
Reject attempts to set or replace commerce-owned order_placed/purchased, including
changing an already commerce-owned status back to a human state. Keep the existing
model guard in place for every other write path. Paid labels/status remain
Shopify-owned, regardless of which user has a token.

For this UI confirmation, record reason `Operator confirmed sales status in
conversation sidebar`. It is an audit description of the human action, not a
claimed extracted qualification reason or an AI label. Use the latest live public
incoming message at/after the observation boundary as the referenced conversation
evidence; choose deterministically by created_at then ID, ignoring recovered
messages. The operator is responsible for judging the conversation as a whole.
If no eligible message exists, qualification fails visibly. Other human statuses
may use empty evidence. Existing explicit rake transitions can still supply a
specific reason and selected evidence IDs.

Within a contact-first then conversation transaction, re-read the conversation,
call ConversationTransition, and apply other submitted attributes while preserving
the resulting sales projection. A failed classification or other attribute save
rolls back both. Omitted status preserves the managed value as today. A duplicate
unchanged selection creates no event. Do not return success after silently refusing
a commerce-status change. Render expected invalid input as the application's usual
422 error response, without hiding unexpected failures. The existing store action
currently swallows failures; make it propagate them to the sidebar's existing
catch/error alert. Inspect both existing edit and delete callers. Use the usual
Axios `response.data` message/error shape with the existing translated fallback;
never show the success alert after a rejection. Return the existing
custom-attributes response shape so the native sidebar refreshes normally.

The UI qualifier's timestamp continues to follow the event core's evidence-time
contract. This operation does not send immediately; configured background delivery
handles the durable outcome. Human confirmation is not automatic text analysis.

## Files and failure modes

Add a UMI controller module and guarded initializer, using the same prepend
convention as existing overlays. The three small core frontend wiring changes
cannot be expressed in a Ruby initializer; keep them limited to explicit edit
intent and error propagation. Keep enterprise compatible by wrapping the
existing controller action and preserving its callbacks/rendering. Check related
enterprise overrides before editing. Add explanatory help text to the Sales status
attribute so staff know qualification is confirmed here and paid statuses are
automatic; do not change its allowed values or existing provisioning invariant.

Concurrent Shopify projection wins through the shared locks. Stale sidebar
requests cannot demote purchased/order_placed. Unrelated attribute edits must not
erase a newer sales projection. A redacted contact cannot be classified. The
controller must not pick evidence from another conversation or call the service
for generic unrelated custom-attribute edits.

## Verification

Request specs exercise the actual authenticated custom-attributes endpoint:
qualification produces one event and labels from the latest live evidence;
recovered/private/outgoing evidence is ignored; duplicate selection does not add
an event; other field edits preserve status; invalid/no-evidence requests return
422 with no partial write; bot and other-account access cannot enter the path;
commerce-owned and redacted states cannot be changed. Test a stale full attribute
hash after a paid projection and require preservation/error rather than demotion.
Add frontend regression tests proving the changed key reaches the API, a rejected
request reaches the sidebar error path with no success alert, and current success
behavior remains. Demonstrate the existing swallowed-error regression failing
before the fix. Run existing custom-attributes request and transition specs,
focused Vitest, lint and boot guards.
Browser acceptance uses the existing dropdown after deployment; API tests do not
substitute for that last UI check. No customer messages or provider POSTs in tests.
