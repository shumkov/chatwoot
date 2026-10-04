# Private settlement command feedback

Status: reviewed for implementation. This completes the already approved deferred feedback
item in the historical CRM audit specification; it does not change settlement
eligibility, create an order, accept payment or send a customer reply.

## Problem and selected approach

Today an operator posts `/paid-in-chat #1234` or its cancellation variant and
sees nothing until the asynchronous job finishes. Registration already runs
inside the native message transaction and the existing command metadata already
stores a `response_message_id` after completion. Use those same mechanisms:

1. During registration, create one outgoing private text response with no human
   sender, marked with the existing `umi_paid_in_chat_response` field. Its text
   says the command is queued for checking and has not taken effect. Wait for
   its final result; if it stays queued, check that the command still exists and
   ask Ivan before retrying. A pending cancellation has not stopped a send.
2. Store that response ID together with the pending command metadata in the same
   transaction. Failed native creation/registration leaves neither orphan note
   nor queued work. Preserve the original staff command text and actor binding.
3. At settlement completion, update the response's content using native Message
   update callbacks. Preserve all existing final success/rejection wording.
   A queued response is never evidence of payment, settlement or Meta delivery.
4. Old pending commands without a response ID still receive one final private
   response. If an operator deleted the pending response, create a replacement
   instead of blocking settlement. Scope lookup to the same conversation,
   private outgoing text and the response marker; never edit an arbitrary note.
   Lock and reload the response row before validating and updating it. Native
   deletion can set `content_attributes.deleted` without taking settlement locks;
   a soft-deleted response must receive a replacement, never be resurrected.
5. Existing contact/message/source locks and the pending-state check retain
   single completion. Repeated worker execution edits no second result. Privacy
   erasure already follows `response_message_id` and removes both notes.

This covers both existing settlement commands, confirmation and cancellation.
Shumabit free-form conversations remain owned by the separate bridge. Do not
add a generic command framework or change that runtime to share a Ruby helper.

## Alternatives and failure behavior

Creating an acknowledgement only when the job starts leaves the operator without
feedback while the low queue waits. Posting separate start/end notes adds noise
and loses the requested single visible result. A new status table or service is
unnecessary because the native message and metadata already contain the link.

Expected business failures (unlinked/unpaid/ambiguous order, invalid syntax,
Shopify read failure) retain their final rejection message. Unexpected transient
worker failures retain the queued, not-applied text while the existing retry and
unfinished-command scheduling runs; they must not be reported as success. Do not
change delivery retries or payment state to improve cosmetic feedback.

Deleting the original pending command removes its registration. The queued note
can remain as a receipt, but must not promise a future result unconditionally;
its text directs the operator to check the original command before retrying.
This avoids a second command-deletion callback and does not misrepresent deletion
as reversal of an already completed financial operation.

## Files and verification

Runtime: `umi/app/services/funnel/settlement_command.rb` only, unless review proves
an existing callback requires a surgical compatibility change. Check OSS,
Enterprise and UMI native message update callbacks before implementation.

Add a failing request test before implementation: after a real authenticated
private command POST, before executing its job, exactly one private queued
response exists and its ID is linked. Run it RED against current code. After
implementation run GREEN and cover same-ID completion/rejection/cancellation,
legacy pending commands, an acknowledgement soft-deleted between lookup and
update, repeat execution and privacy
cleanup. Run the existing settlement/request/race suites and Ruby lint.

Independent code review precedes the signed patch/release. Production readback
must verify source/image and natural commands; no fake order/payment or new
customer-facing message is needed to demonstrate this cosmetic change.

## Review receipt

Two independent source reviews completed on 5 October. Domain/simplicity review
found no blockers. Callback/privacy review identified the native soft-deletion
race; the response-row lock/revalidation and regression requirement above resolve
it. Implementation remains limited to feedback for the existing commands.
