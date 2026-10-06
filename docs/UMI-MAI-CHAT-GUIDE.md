# UMI chat guide for Mai

Editable team guide: [UMI chat guide for Mai](https://docs.google.com/document/d/1F2DG54uY7P6a8r-_Ms2vYbqUBL_JcGfCuJ_sNI9-qHw/edit),
in UMI Team → Docs → Processes. Mai has inherited editor access.
This file is the 6 October publication snapshot. Read the living Google Doc before
future edits and preserve changes made there; do not overwrite it from this snapshot.

6 October 2026. Use this with the current product, delivery and returns information.
Examples below show how to structure a reply; they are not promises about stock,
fit, prices, delivery dates or policy.

The reminder workflow below is live as of 6 October 2026.

## At the start of a conversation

Read the customer's latest question and the earlier context before replying.
Check the latest private customer summary and linked Shopify customer/order.
Labels such as `repeat`, `vip` and `influencer` help you orient yourself quickly;
the app may show only some labels. Open the customer attributes when needed.
An absent buyer label means history may be unknown, not that the person is new.

Aim for the first human reply within five working minutes, daily 09:00–21:00
Bangkok. If you need to
check something, acknowledge the exact question and give a time you can meet.
Acknowledge, then do the check: an acknowledgement does not finish the task.
Chatwoot is the first notification. Telegram adds a reminder after ten working
minutes when a reply may still be needed; there is no extra three-minute alert.

## What you see in Chatwoot

| Visible fact | Meaning / action |
| --- | --- |
| `client` | One verified paid purchase. |
| `repeat` | At least two verified paid purchases; this person can still be asking about support now. |
| `chooser` / `seeker` | Recent browsing/product interest, or cart/checkout intent, for a verified non-buyer. These are website behavior, not a payment. |
| `vip`, `influencer`, `model`, `wholesale`, `high-value` | Independent customer roles. Several may apply at once. Correct the contact attribute, not its display label. |
| `barter` | Confirmed barter history, kept separate from paid purchase history. A free collaboration order is not a paid sale. |
| `lead-qualified` / `lead-converted` | Display of the conversation's qualified / purchased state. Read Sales status and the linked evidence for detail. |
| `source-paid-ads` | Recorded advertising referral evidence. This is not proof that a sale was attributed to an ad. |
| `intent-*` / `support-*` | Conversation topics. Size, colour and refund topics can coexist; correct ordinary topic labels when needed. |

The contact attributes are the facts; managed labels are their visible display.
You do not maintain two independent copies. Private notes explain changes and
customer matches. The compact mobile list may omit some labels, so open the
conversation and latest summary before making assumptions. No label is not the
same as an explicit "no" or "new customer".

## Six habits to use in every relevant conversation

| Habit | What to do | Check before sending |
| --- | --- | --- |
| Read and answer | Answer each actual question, using information already supplied. | If they asked about XS and S, did I address both? |
| Understand the choice | Ask only for information needed to help. | Am I asking again for something already in the history? |
| Recommend with a reason | Give a specific suggestion supported by measurements, product facts or the customer's preference. | Can I explain why without guessing fit or fabric properties? |
| Make the next step easy | Offer the appropriate next step: a verified option, fitting, checkout or service action. | Does this help their stated need, without an unnecessary upsell? |
| Keep promises | Complete checks and updates by the time you promised; explain delays before that time where possible. | Did I return with the answer, rather than only saying I would check? |
| Follow up appropriately | Follow up when useful and permitted, respecting refusals and preferences. | Is there a real reason to write, and does the channel allow this message? |

Use the customer's language where possible and a warm, clear tone. Give facts
before decorative wording. A simple factual answer can be enough; every message
does not need another question, sales pitch or follow-up.

## Common situations

**Size advice.** Compare the requested sizes using the actual size chart and the
customer's stated fit preference. If a measurement is missing and matters, ask for
it. Do not substitute “this will fit perfectly” for evidence. If you give a size
recommendation, explain the relevant measurement or intended fit.

**Availability or delivery.** Check the current variant and destination. State
what is confirmed and what still needs checking. Do not describe “dispatched” as
“delivered,” or promise a date from an old conversation.

**A customer goes quiet.** Silence is not proof of a lost sale or poor service.
Offer a useful next step only when appropriate and within channel rules. Do not
send repeated “just checking” messages or revive old audit examples as live tasks.

**Returns or complaints.** First understand the requested outcome and check the
order and current policy. A customer can remain Repeat or VIP while this
conversation is `not_sales` with a support topic. Do not turn a service problem
into a sales pitch.

**Collaborations and mentions.** A story mention or a friend tagging someone is
not automatically a sales lead, spam or proof of influencer status. Explicit
evidence of the person’s own creator activity or agreed content work can justify
an influencer role. Generic collaboration interest, event attendance or manager
representation alone leaves the role unknown. Keep purchase questions separate
from collaboration logistics within the same history.

**An unknown fact.** Say what you will check and return with the result. Do not
invent a discount, product benefit, delivery promise or returns exception.

## Customer, order and payment checks

1. Confirm the customer's identity using the existing Shopify linking controls.
   Matching a name or Instagram handle alone is insufficient. If a suggested
   customer is wrong or ambiguous, leave the link unresolved and ask Ivan.
2. Link the specific draft/order to this conversation through the existing
   Shopify integration. A customer's order history does not mean every order
   belongs to every conversation with that customer.
3. For checkout links, use the existing conversation-linked checkout flow.
   A draft or checkout link is not a completed purchase.
4. For QR payment, verify payment in Shopify and the order's conversation link.
   If the purchase was actually settled in this chat, send the following as a
   **private note**, replacing the example with the visible Shopify order number:
   `/paid-in-chat #1234`.
5. The private acknowledgement says the command is queued. Wait for that same
   note to change to its result; queued does not mean applied. The command records where settlement happened;
   it does not create an order, mark it paid, link it, message the customer or prove
   Meta accepted an event. Do not use it for payment completed at the shop or
   through a customer checkout link; checkout tracking belongs to Shopify.
   If it stays queued, check the original command was not deleted and ask Ivan
   before retrying. Deleting a note is not a payment reversal.
6. To reverse a mistaken settlement confirmation, use
   `/paid-in-chat cancel #1234` and read the private result. A submitted Meta
   attempt may already be irreversible. Until the private result arrives, a
   pending cancellation has not stopped submission. Ask Ivan about an incorrect
   order link.

Try-before-you-buy and unpaid store pickup remain unpaid until payment is
confirmed. Do not manually set a buyer/payment field to make a label appear.
If Shopify says paid but the CRM reports a payment mismatch, ask Ivan to check
the actual payment record. A status label alone does not resolve that mismatch.

## Public comments on advertisements

Current advertising is Instagram-only. Mai owns the manual comment check in
Meta Business Suite: at the start of the shift and during regular queue checks,
inspect comments on active Instagram ads. On the first shift using this guide,
confirm with Ivan that the advertising comments are visible in your account;
report missing access rather than assuming there are no comments. Adoption of
this routine has not yet been verified.

Comments are separate from the Chatwoot DM queue and its Telegram reminders.
Answer product questions using the same service rules;
move personal order or payment details into a private conversation. The Friday
report does not yet measure public-comment response coverage or timing.

## Correcting the system and getting help

Change the conversation's **Sales status** when the AI misunderstood the enquiry.
`engaged` covers an ordinary question about price or delivery; `qualified` needs
a concrete purchase discussion or meaningful product consultation. `not_sales`
includes support, social and collaboration conversations; it does not mean spam.
`order_placed` and `purchased` come from linked Shopify facts, not manual labels.

Correct an ordinary topic label if needed. To change VIP, Influencer, Model,
Wholesale or High value,
edit the corresponding contact attribute; the visible managed labels follow it.
Do not edit a managed label as a substitute for changing the underlying fact.
Use `no` for an explicit correction, and `unknown` when the role is not established.

Ask for assistance in a private note, for example:
`@shumabit summarize this chat and suggest a reply`.
Read and check the suggestion before sending it yourself. Shumabit's private
response is not a customer message, and this iteration does not authorize it to
create orders or reply to customers autonomously.

## Handling Telegram reminders

Telegram points you to work in **Chatwoot**. Open the linked conversation, read
what has happened since the reminder, and act there. You do not need to answer
every Telegram reminder or contact every listed customer. Dismissing a Telegram
message does not finish the work.

| Situation | What to do in Chatwoot |
| --- | --- |
| A question or promised action needs your attention now | Answer the actual question or complete the action. An acknowledgement alone does not finish a promised check. |
| The current work is finished | **Resolve** the conversation. This stops reminders for the current work. A brief private outcome note is helpful, but is not required just to close it. |
| Work must wait until a particular time | **Snooze** until that time. Record what you are waiting for, such as customer information or an internal stock check. Reminders pause until the selected time; a new customer message follows Chatwoot's normal reopening behavior. |
| You have already asked the customer for information | Waiting for their answer is not an unanswered operator task. Do not send another request simply because a reminder appeared. Set a check-back only when there is a useful reason. |
| There is a useful future follow-up | Record the specific reason and date, including the time in Bangkok when relevant, in a private note. An agreed follow-up can remain scheduled even after you **Resolve** the current conversation. |
| A reminder is wrong, or a planned follow-up is cancelled | Add a private note explaining what was completed, cancelled or misunderstood. Resolve finished current work. Respect a customer's refusal or request not to be contacted. |

Private-note examples, with the actual facts and dates filled in:

- “Fitting completed. Customer kept size S; no further fitting action needed.”
- “Waiting for the customer's order number. We have already asked; no further
  action until they reply.”
- “Customer agreed that we will check back on [date] at [time] Bangkok to discuss
  the fitting after their trip. Current enquiry is complete.”
- “Cancel the follow-up planned for [date]. Customer no longer wants a fitting.”
- “Move the follow-up to [new date] at [time] Bangkok. The customer asked us to
  contact them after their trip instead.”

These are ordinary private notes, not special commands. Record only what really
happened or was agreed. Do not invent a follow-up date to clear the queue.
For a change or cancellation, add a **new private note**. Editing or deleting
the original scheduling note cancels its old timing but does not establish a
replacement reminder; write the new date in a new note.

A scheduled **Follow-up opportunity** appears once when due, including for a
resolved conversation. It means “review whether this contact would still be
useful,” not “the old work is unfinished.” Check the latest history, customer
preferences and channel rules before sending anything. Shumabit does not send
the customer a message automatically. Generic repeated sales nudges, personal
exchanges and retrospective coaching do not belong in this action queue; real
support and collaboration work can still belong here.

The ten-working-minute unanswered-message alert remains. The 09:00 Bangkok
summary may repeat genuinely outstanding current work once a day. Hourly
summaries contain newly actionable or newly due work, not repeated descriptions
of the same task. A resolved follow-up opportunity does not repeat every morning.
If the same completed action keeps returning, give Ivan the conversation number
and point to the outcome note so the reminder can be corrected.

## Friday coaching

The report separates response-time measurements, confirmed order/payment facts
and AI judgments about conversation quality. It shows supported strengths as
well as improvements. Unknown attachments, private calls and missing policy facts
are marked uncertain rather than treated as mistakes.

You do not need to approve every classification. When a judgment is wrong, tell
Ivan the conversation number, which conclusion is wrong and why; point to the
message or missing fact. The team uses those corrections to improve the rubric.
Historical examples are for learning; they are not a new outreach list.

## Start and end of shift

At the start, check unanswered conversations, promised updates, linked order
issues and public Instagram ad comments. Read Telegram's action summary, then
open each relevant chat before acting. At the end, record outstanding promises
and the next action clearly in a private note. Resolve or snooze a conversation
only when that matches the work; changing its open/resolved state does not
rewrite its customer or purchase history.

## Internal sources

This guide implements the agreed CRM data contract, operator reminders spec,
settlement-command behavior and calibrated six-rule quality rubric. It adapts
the earlier `shumabit-claude/docs/chat-sales-playbook.html` into practical checks;
it does not adopt that document's illustrative product or delivery claims as facts.
