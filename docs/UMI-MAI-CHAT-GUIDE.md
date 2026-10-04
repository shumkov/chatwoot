# UMI chat guide for Mai

2 October 2026. Use this with the current product, delivery and returns information.
Examples below show how to structure a reply; they are not promises about stock,
fit, prices, delivery dates or policy.

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
5. Wait for the private result. The command records where settlement happened;
   it does not create an order, mark it paid, link it, message the customer or prove
   Meta accepted an event. Do not use it for payment completed at the shop.
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

Current advertising is Instagram-only. The proposed shift routine is to check
public comments under Instagram ads in Meta Business Suite; before adopting it,
Ivan and Mai need to confirm access and review this instruction together. This
routine has not yet been confirmed in use. Comments are separate from the Chatwoot DM queue and
its Telegram reminders. Answer product questions using the same service rules;
move personal order or payment details into a private conversation. The Friday
report does not yet measure public-comment response coverage or timing.

## Correcting the system and getting help

Change the conversation's **Sales status** when the AI misunderstood the enquiry.
`engaged` covers an ordinary question about price or delivery; `qualified` needs
a concrete purchase discussion or meaningful product consultation. `not_sales`
includes support, social and collaboration conversations; it does not mean spam.
`order_placed` and `purchased` come from linked Shopify facts, not manual labels.

Correct an ordinary topic label if needed. To change VIP, Influencer or Wholesale,
edit the corresponding contact attribute; the visible managed labels follow it.
Do not edit a managed label as a substitute for changing the underlying fact.
Use `no` for an explicit correction, and `unknown` when the role is not established.

Ask for assistance in a private note, for example:
`@shumabit summarize this chat and suggest a reply`.
Read and check the suggestion before sending it yourself. Shumabit's private
response is not a customer message, and this iteration does not authorize it to
create orders or reply to customers autonomously.

Telegram's morning/hourly reminders point to work to check, not instructions to
contact every listed person without reading the chat. Reply or finish the action
in Chatwoot; do not merely dismiss the Telegram message. If a reminder is wrong,
record what was already done or which fact is missing in the conversation.

## Friday coaching

The report separates response-time measurements, confirmed order/payment facts
and AI judgments about conversation quality. It shows supported strengths as
well as improvements. Unknown attachments, private calls and missing policy facts
are marked uncertain rather than treated as mistakes.

You do not need to approve every classification. When a judgment is wrong, tell
Ivan the conversation number, which conclusion is wrong and why; point to the
message or missing fact. The team uses those corrections to improve the rubric.
Historical examples are for learning; they are not a new outreach list.

## Internal sources

This guide implements the agreed CRM data contract, operator reminders spec,
settlement-command behavior and calibrated six-rule quality rubric. It adapts
the earlier `shumabit-claude/docs/chat-sales-playbook.html` into practical checks;
it does not adopt that document's illustrative product or delivery claims as facts.
