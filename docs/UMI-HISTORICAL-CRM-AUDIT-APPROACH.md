# Historical CRM audit and stage-two enrichment

1 October 2026. Approach for the user's requested historical audit. This is not
authorization to replay old sales as new Meta events or start customer outreach.

## Order of work

Activate live reminders independently, for new/resumed conversations only.
Combine historical customer/order matching, classification and audit in one
stage-two pass so the report does not call an unmatched buyer a lost opportunity.
The previous stage-one/lifecycle decisions explicitly deferred bulk historical
classification and linking; this extends that deferred work into a useful audit.

1. Inventory all retained conversations in the six customer text inboxes,
   including resolved chats, customers, orders/payment/refund evidence and date
   coverage. The reminder queue's 380 candidates are not the full audit universe.
   Record omitted/deleted/redacted or unavailable data and recovered timestamps.
2. Match customer identity first, using existing explicit Shopify IDs and exact,
   unambiguous identity evidence. Names, social handles and similar order values
   can propose candidates, not prove a match. Present only ambiguities to Ivan.
3. Link orders to individual conversations only with attribution evidence or
   explicit operator confirmation. Knowing the customer does not attribute every
   purchase to every chat. Reuse existing links/financial reconciliation and
   keep paid-event correction constraints. No bulk contact merges from AI guesses.
4. Read complete available histories with matched commerce facts. Distinguish
   shopping episodes from support, influencer/collaboration, social mentions,
   recruitment, spam and tests. Reuse the current taxonomy and operator corrections;
   do not create another set of labels. Historical episode analysis can be a
   report table without adding a new CRM opportunity entity.
5. Produce proposed enrichment changes and the audit from the same evidence.
   Persist factual corrections and reviewed classification through supported
   paths only after checking their sync/export effects. Reconcile before/after
   counts; do not double-count customers across channels or orders across chats.

## Useful report

Telegram: five to seven key numbers, the three most important findings and the
few actions worth doing now. Attach a readable PDF with breakdowns and examples;
provide a private sortable action list linked to the relevant Chatwoot chats.
Chatwoot supplies facts/numbers; the Shumabit script/skill formats and explains.

- Coverage: conversations vs unique identified customers; time periods and
  channels covered; share with reliable identity, purchase history and attribution.
- Commercial outcomes: genuine shopping enquiries, substantive consultations,
  linked orders, verified paid orders, paid value, refunds and net cash, keeping
  counts and monetary bases explicit. Drafts, unpaid pickups and unpaid TBYB are
  not paid conversions. Returning customer status is separate from this chat's sale.
- Leakage by step: no successful human reply, unanswered purchase question,
  missing promised check, order created but unpaid, explicit refusal or a known
  product/service constraint. Silence alone is an unknown outcome. The report
  distinguishes confirmed non-purchase, no linked payment, pending and unknown.
- Service quality: response-time distribution and five-minute SLA coverage where
  original timestamps and applicable working hours are trustworthy; completeness
  of answers, useful recommendations, clear next step and kept promises, based on
  the Mai framework. Separate retrospective coaching from current tasks.
- Sources/channels: comparisons only where actual attribution exists. No inferred
  organic source or advertising ROI without the necessary source/spend evidence.
- Actions: urgent unresolved service/payment checks; relevant recoverable buying
  opportunities; data corrections needing a person; and recurring coaching/process
  changes. Each has evidence, next action, owner and a genuine deadline if known.
  Show good examples too. Do not generate generic outreach for every silent chat.

Do not label a guessed basket value as lost revenue. Confirmed unpaid order value
may be shown as such; recoverable value estimates, if useful, must be separate
with their assumptions. Revenue in an associated customer's history is not proof
that this conversation caused it. Current labels do not reconstruct every old
funnel transition. Any retrospective inferred stage is marked reconstructed.

Use monthly/cohort views with an explicit observation cutoff, so recent enquiries
with time remaining to buy are not compared as final failures against old cohorts.

## Checks before a detailed implementation plan

- Verify actual Shopify historical order access. Default API access covers only
  60 days; an incomplete window must remain incomplete, not become zero purchases.
  Source: https://shopify.dev/docs/api/usage/access-scopes .
  A read-only production check on 1 October found that the Chatwoot integration
  has `read_orders` but no `read_all_orders`; its earliest visible order was
  4 August 2026. Inventory existing Shumabit/Klaviyo history and previously
  reconciled evidence before deciding whether extra Shopify access is needed.
  This finding applies to the Chatwoot app token, not every store integration.
- Inventory native Shopify/Klaviyo order history before importing anything;
  reuse it and avoid duplicate events. Historical custom event replay, if needed,
  requires original times, stable identities and `backfill: true`; also inspect
  profile/segment-triggered flows because property updates are a separate path.
  Source: https://developers.klaviyo.com/en/reference/events_api_overview .
- Verify that historical label/identity application cannot emit fresh Meta
  conversions, customer messages or old-tail reminders. Reporting can begin
  read-only while this check is completed.
- Sample ambiguous identity, multi-channel duplicates, repeat purchase plus
  return, TBYB, manual QR payment, paid-after-chat, no-reply, influencer and tests.
  Ask Ivan only about ambiguous evidence or incorrect conclusions, not to
  classify the entire dataset himself.
- Complete independent review of the concrete enrichment/write procedure before
  bulk writes. The audit approach does not authorize changing paid attribution
  already assigned to another conversation.

The existing report services enforce the live collection boundary and must not be
presented as complete historical reports by simply widening their date parameters.
The audit needs a separately declared historical dataset and coverage statement.
