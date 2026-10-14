# UMI weekly support and sales report

Status: implementation approved by Ivan; implementation and independent code review in progress.
Date: 13 October 2026. Owner: Ivan. Audience: Mai and Linh.

## Purpose and agreed result

Help the team improve customer support and selling: what changed, where customers got stuck, what worked, and what to do next. Telegram carries the important findings; the PDF supplies useful detail in **roughly three to four readable A4 pages**, including notes. Five pages is acceptable when the extra page adds a concrete useful finding; length is governed by value, not a rigid cutoff. No cover-only page or raw technical appendix. A short, actionable agent investigation prompt belongs at the end when technical findings exist.

Chatwoot owns deterministic operational facts; Shopify owns commerce facts; Shumabit interprets evidence and prepares the report. The deliverable combines weekly performance reporting with an operational audit against Mai’s instructions. Keep the existing report job and private evidence files. This is a report correction, not a new analytics platform or change to classification, campaign delivery, customer messages, or financial attribution policy.

## Evidence and what is wrong

Reviewed artifact: `.orca/drops/report.pdf` in the original chatwoot.crm workspace. It reports 2–8 October, frozen 9 October at 09:00 Bangkok, and contains 27 pages.

| Finding | Evidence / status | Required correction |
|---|---|---|
| Useful coaching buried | Examples only appear on pages 26–27. Confirmed presentation defect. | Put key customer issue and action on page 1; coaching by page 3. |
| Opening figures describe lifetime population | 175 one-time buyers, 39 repeat buyers, 38 VIP contacts. Not weekly achievements. | Lead with weekly support and sales, remove account inventory. |
| No useful week-over-week scorecard | Collector fetches current operational/funnel facts and two cohort periods, not prior-week operational/funnel facts. Confirmed source gap. | Collect comparable previous-period facts, with coverage and definitions attached. |
| Empty channels occupy pages | Website has zero eligible observations yet full distributions; configured schedules printed for all inboxes. | Omit inactive-channel detail. Retain true zero outcomes for active populations. |
| Meaning of missing data is lost | `display()` renders null/undefined as “Unavailable”; zero samples and missing schedules appear similarly. | Distinguish no activity, incomplete tracking, not measured, pending outcome window, and source failure. |
| Technical counters dominate | Delivery states, preparation holds, erasure checks, classifier executions and sync inventories. | Keep raw counters in private diagnostics. Put actionable technical findings in the final agent investigation prompt; mention a business impact in the main report only when supported. |
| Mixed populations/time bases | 35 observed conversations; 955 classifier result events; current classification totals; all-account cash. | Separate weekly activity, cohort outcomes and historical/customer context. Never treat AI executions as customers. |
| Payments are not attributed sales | 2 paid events, THB 6,353; 0 conversation links. The PDF cannot show whether either sale came from chat. | Read-only verification of both order facts and linkage; distinguish unlinked store payment from confirmed chat sale. |
| Existing SLA is not proof of reply obligation | Instagram reports 9/12 first replies and 2/12 within target. Source excludes spam/auto-reply email but not every mention, thanks, solicitation or no-reply-needed item. | Validate actionable membership before using performance judgments. Do not accuse Mai of missing a reply based on raw inbound counts. |
| Cohorts overwhelm the reader | Day × inbox × ad rows, each printing mature and immature grids including empty groups. | One compact comparison of two fully aged weekly groups; one short provisional line for recent arrivals. |
| Coaching is useful but hard to apply | Internal rule IDs and message IDs; restock and pickup examples are actionable. | Plain issue, short supported example, improved response, conversation link. No fabricated policy or promise. |

These are confirmed document/source-design findings, not a claim that every production calculation is broken. Unverified: exact payment provenance, real SLA exclusions, source coverage for backfill, and whether omitted channel activity was absent or excluded. Resolve these during implementation verification and record the result; never silently turn them into zero.

## Reader-facing structure and length target

### Page 1 — What changed and what to do

- Exact reporting dates and comparison dates, Bangkok time.
- Up to three short findings: improvement, problem, commercial outcome. Each cites a real number or conversation evidence; omit unsupported categories.
- Compact scorecard: metric | this week | previous week | change. At most six rows: customer conversations; sales enquiries; qualified enquiries; first replies within five working minutes; unanswered actionable requests at cutoff; verified chat-linked paid orders and gross paid value (combined cell if needed).
- At most three priority actions, each with one proposed owner (Mai: responses; Linh: ads; Ivan: tracking/integration), exact action, and observable completion condition. Do not imply those owners already accepted an assignment or post tasks automatically.
- One short material data caveat only if it changes interpretation. No vague “investigate exceptions.”

### Page 2 — Support and sales performance

- One compact table for active customer channels, separating Instagram and Messenger even when sharing an inbox: actionable requests, within-target replies, median first reply in working minutes, unanswered at cutoff. First-response rates explicitly show x/y eligible first-response episodes; all actionable requests and unanswered requests are separate counts, not that denominator. Counts accompany rates; at most six relevant channel rows, others aggregated only for additive counts with a clear label.
- Explain the biggest bottleneck in plain language. Subsequent waits/follow-up failures get a short finding if material; do not repeat whole distribution tables.
- One compact seven-day cohort comparison: conversations, qualified conversations, paid conversations / orders, verified gross paid value. Clear dates and denominators. Cohort is conversations, not unique people.
- Campaign-specific finding only when spend, source and matching dates are verified. No ROAS or “lost revenue” from unlinked orders, guesses or AI judgments. No new Meta collector required for this revision; omit unavailable ad metrics.

### Page 3 — Conversation coaching

- Select useful, distinct coaching lessons: normally two or three effective approaches and three or four improvements when supported. Do not force quotas or silently discard an additional material lesson to meet a fixed example count. Prioritize recurring/customer-impacting issues; identify one-off examples as such.
- Each heading: customer display name + plain-language topic (for example, “[Customer name] — size and availability question”), followed by a clickable conversation reference. If a verified ad is associated with the relevant enquiry, show its human-readable campaign/ad name and a link when available. Never use internal rule names such as `read answer` as headings. Then explain what the customer needed, the observed reply/action, why it mattered, and a short suggested improvement. Preserve relevant nuance, no long transcript.
- Resolve the name and ad context from source records deterministically, not from model guesses. Use the ad associated with that enquiry, not an unrelated ad elsewhere in the customer history. If only an ad ID is verified, say “Ad referral — name unavailable” with the reference available via a link; do not invent a product/ad title. Without referral evidence omit the ad line; do not claim organic acquisition. If the customer name is missing/redacted, use a neutral “Customer” label and the conversation link. Include display names only in the internal team report, no extra contact details. Existing anonymized AI coaching can remain anonymized: the renderer adds verified names/ad context to its evidence-linked example.
- Use Mai's existing six-rule framework. State how many eligible conversations were assessed; no algorithm internals. Do not claim a trend from a changing sample or unreliable previous assessment.
- Candidate themes must come from actual evidence (e.g. sizing, availability, restock, delivery, payment, pickup), not a mandatory checklist filled by AI.

### Optional page 4 — Actions and follow-through

- Use only when meaningful evidence/actions cannot fit legibly in three pages.
- Follow-through on previous report actions: completed / still open / not verified, backed by evidence. Never invent a task ledger or infer completion from a resolved conversation alone.
- At most five additional conversation-specific opportunities, with link, reason and next step. This is not a duplicate of the live Orders queue. Historical items must say whether still open as of a separate current check.
- Small explanatory notes for definitions/data gaps if needed. No raw diagnostic tables.

Telegram: approximately 150–220 words maximum, up to 3 key findings plus up to 3 actions and attached PDF; no dump of metrics. No invented trend when comparison unavailable. Publication is a separate explicit step from regeneration.

## Metric and comparison contract

### Weekly service/activity

Keep the existing week: Friday 00:00 through next Friday 00:00, Asia/Bangkok, start inclusive/end exclusive. Friday generation remains unchanged. “Previous week” means the immediately preceding seven days under identical definitions.

Activity counts use the actual message/event occurrence time, not when a late webhook or replay was processed. Preserve observation time in technical evidence. New and reopened conversations both count for weekly activity, deduplicated by conversation ID within the week. Do not rename this to customers: one person may have several conversations/channels. Split customer sales and customer support from collaboration/vendor/system traffic. Unknown membership stays explicit in coverage; do not silently discard it or assume customer.

Keep an older unresolved actionable wait separate as “carried over,” with its own count at cutoff; the existing episode-start filter otherwise omits it from weekly metrics. Do not reset its age or count it as a new enquiry. Response episodes start at the first unanswered actionable inbound message; repeated messages do not restart the clock. An accepted human public reply ends a wait; private notes, automation and failed sends do not. First response retains the source definition (first eligible episode of a conversation), and subsequent episodes are separately identified; do not redefine every reopened thread as a new acquisition.

Reuse existing stored judgment evidence to establish reply obligation if it identifies the exact message/episode and is reliable. Do not treat today's classification or the latest reminder judgment as historical proof for all older episodes. When valid evidence is missing, inspect eligible episodes from full contextual history for the two target weeks and preserve a reproducible assessment alongside the report, or withhold the affected performance claim. No new persistent classification subsystem. Support requests stay eligible even when not sales; influencer outreach is outside the customer sales denominator.

Use matching observation cutoffs for the two weekly service reports: each period end plus the same nine-hour generation lag, not today's time for the older period. Restrict reply and judgment evidence appropriately; document unavoidable current schedule/label restatements. Show unanswered at that historical cutoff separately from actions that remain open today. If the 5-minute deadline has not elapsed, label pending and exclude from assessed SLA denominator, while retaining in actionable request coverage. Preserve raw episode evidence privately.

Counts show absolute change. Rates show percentage-point change with numerator/denominator. Duration shows minutes faster/slower. Money stays per currency with source scope. Avoid relative percentage changes from zero; say “0 → 2.” Missing/partial baseline: no delta, concise reason. Small samples show counts, no “significant improvement” claim. Do not average per-channel medians/percentiles; calculate overall distributions from source episodes or omit an overall duration.

### Weekly scorecard units

- Customer conversations: distinct conversation IDs with at least one actual incoming customer support/sales request in the week; new and reopened included. Multiple episodes in one conversation count once here.
- Sales enquiries: distinct conversation IDs with at least one evidence-backed buying/product-choice enquiry occurring in the week, whether new or reopened. Support-only and collaborations do not count; a mixed support/sales thread can count once in each relevant descriptive category, never sum them as exclusive groups.
- Qualified enquiries: distinct conversation IDs with a valid qualification milestone occurring in the week; repeated evaluations do not add leads. Apply known invalidation/correction evidence up to that period's observation cutoff. This count is not divided by weekly sales enquiries to claim conversion: qualification can follow an earlier week's enquiry.
- Verified chat-linked paid orders/value: distinct shop-domain + Shopify-order-ID whose first actual paid occurrence falls in the week and has verified conversation attribution; sum that first-paid gross value once per currency. Earlier enquiry weeks may produce these payments, so this is weekly paid activity, not this week's enquiry conversion rate. Later refunds remain separate and cannot silently turn this into net revenue.
- Unanswered actionable requests: episodes still awaiting a required human reply at the weekly observation cutoff; show this week's starts and older carried-over waits separately, without adding duplicated episodes. A later request is not a missed first reply. Current action recommendations require a separate current-state check.

### Sales cohorts: equal opportunity to convert

Use a seven-calendar-day outcome window anchored to the existing first live inbound of a new conversation created after collection began, provided its initial enquiry is a customer sales request. Do not move entry time to later qualification or first detected purchase intent. Old reopened conversations and support-first threads that later become sales stay in weekly activity but are outside this new-sales-conversation cohort; label that scope. This revision does not introduce repeat sales-episode cohorts. Reuse existing conversation identity and horizon machinery, but validate membership: existing first-live-message cohorts include non-sales traffic and exclude old imported threads; they cannot simply be renamed “sales enquiries.” Apply a documented evidence-backed customer-sales membership rule consistently to both weeks. Unknown membership is reported in coverage; never default to a non-buyer. Do not select the denominator using eventual qualification/purchase, which would bias conversion upward.

At a Friday report, the just-ended week is still developing. Compare the two most recent complete Friday–Thursday arrival weeks for which every included conversation has had seven days. Show exact dates; do not compare a mature group with an immature group, or only the mature slice of a partial week as though it were the whole week. Recent week's observed counts may be shown as “so far,” without a final conversion rate. If no complete pair exists, one short honest line replaces the table.

For each member, count qualifying and paid outcomes only inside its own seven-day window. A late legitimate correction may restate the results but must be labeled in the regenerated report. Count distinct qualifying conversations, distinct paid conversations, and distinct paid orders separately. Report gross verified paid amount; do not label it net revenue without refund evidence for the correct interval. Purchase = actual payment, not draft checkout, reservation, pickup promise, or 100%-discount barter. Shopify remains financial truth.

Verify a paid order's existing attribution using order/conversation/customer evidence. Use the stricter cohort verification (valid attribution record, matching conversation/contact and financial evidence), not merely the weekly report’s non-null conversation_id count. Shared identity alone does not prove that a purchase originated in a conversation or campaign. When unbound customer identities mean purchases may be invisible, “0 verified chat-linked purchases” is not a complete 0% customer conversion rate; withhold a definitive paid-conversion claim and state the coverage gap. An unlinked store purchase is not automatically a tracking failure or lost chat sale. Never create a link to improve the report. No inferred total lost revenue.

### Missing and zero values

- No eligible activity: omit empty channel/table; one sentence if needed.
- Genuine zero outcome in a nonempty, covered population: retain zero.
- Required source failed/missing: mark affected metric “not measured” with reason and technical owner; no fabricated zero or successful complete-report status for unusable core data.
- Partial baseline: “Previous week tracking incomplete”; suppress comparison, not current valid results.
- Window unfinished: “Still within the seven-day purchase window.”
- Attribution incomplete: “No verified chat-linked orders; X recorded store payments need origin checking,” only where that count and scope are verified.
- An inactive channel missing business hours is not a team action. A missing schedule affecting real requests is a specific tracking action.

## Operational audit: explain the gap, not just count it

The report is both a performance summary and an audit of how the team follows the applicable Mai guide. Existing code assesses six conversational-quality rules, but this is not yet a complete workflow-compliance audit: its prompt restricts assessment to weekly public evidence and has no explicit order-linking/private payment-command criterion. Its report-level sync warning merely tests an account-wide error count. Neither constitutes investigation of why the two paid events have no conversation link.

Use the version of instructions applicable to the reporting week. Separate new coaching advice from an actual missed instruction; do not retroactively fault an operator for a rule introduced later. Include public replies plus relevant private command/acknowledgement records and verified commerce/link facts as evidence appropriate to each check. Private notes remain internal evidence, never customer replies or SLA completion.

Audit the existing guide's relevant obligations: answer the actual question; give grounded product/fit advice; provide an appropriate buying next step; fulfil promised updates and relevant follow-up; correctly link a customer and the particular chat-assisted order; for an actual manual QR settlement in chat, verify payment/link and the applicable `/paid-in-chat` result. Never require that command for website checkout or payment at the shop. Resolve/Snooze compliance must be based on whether an action is actually outstanding, not just a status mismatch. Reuse existing judgment and command/attribution records; do not build a new general rules engine.

State audit coverage: eligible conversations/order candidates, checked, and unresolved/unassessed. Selected coaching examples are not evidence of complete workflow compliance. Every reported miss must explain: **which conversation/order; which applicable instruction; what the evidence shows; business consequence or risk; what to do; proposed owner**. Distinguish operator omission, system failure, missing information, external issue, and not yet established. Uncertain evidence becomes a precise investigation task, not an accusation. Include strengths as well as failures; do not force quotas or attach invented revenue loss.

For the two paid events in this report, investigate each separately with read-only evidence:
1. Verify the distinct Shopify order, real payment time/value and absence/presence of the stored conversation attribution. Raw event count must not be assumed to equal two distinct orders until checked. Establish linkage at the original cutoff and now: a later successful link is a corrected historical gap, not a currently open task. If historical link timing cannot be established, say so.
2. Check existing exact customer/order references and relevant conversation context. Name/handle similarity alone is insufficient. An identity match does not establish a chat-assisted sale.
3. Establish whether the sale was independent web/store activity (no chat link expected), chat-assisted with a missed operator step, chat-assisted with attempted linking/command that failed, or unresolved for lack of evidence.
4. For attempted operations inspect acknowledgement/final result and persisted link state. A queued command is not completion. Missing command is a breach only when manual chat settlement and the applicable instruction are evidenced.
5. Include the finding and concrete next action in the human report if material. If independent sales are confirmed, explain briefly that there were no verified chat-linked sales, not that two orders were lost. If unresolved, name the specific fact to check and owner. Do not merely repeat “2 paid / 0 linked.”

For identity/sync warnings, inspect reason and affected records, then limit findings to a demonstrated impact on report conclusions or current customer work. Examples of relevant impact: a known buyer's order history unavailable to Mai, or a verified qualified lead blocked from the intended downstream sync. Distinguish absent identifiers, conflicting matches and a failed integration write. Dormant historical exceptions remain private diagnostics. Do not infer that account-wide sync errors caused these particular order-link gaps.

The report may accurately say an investigation is unresolved, but only after recording what was checked and exactly what evidence is missing. Never link orders, alter customer identity, mark payment or replay conversion events as a side effect of generating a report.

## Final section — Agent investigation prompt

When the report discovers technical anomalies, append a short copy-ready prompt titled “For the agent: investigate.” It is the last section, after the human findings and actions, and is omitted when there is nothing concrete to investigate. No routine green checks, raw log dumps, or repeated generic sync warnings. Group findings with the same underlying symptom; prioritize by business impact. Keep the section concise enough to fit the report's usefulness/length target.

Each item must provide: reporting period and observation time; expected versus observed behavior; affected conversation/order/event identifiers or internal evidence links; whether the issue is confirmed or suspected; checks already performed; and the next question to resolve. Use only verified identifiers, no credentials or unnecessary customer personal details. For provider delivery, distinguish pending, rejected, accepted and confirmed: an accepted event alone is not proof of attribution, and a missing link alone is not proof of a missing event.

End the prompt with a clear requested result: explain the cause, identify affected scope and business impact, propose the smallest correction, and state how it will be verified. Investigation is read-only by default; the report itself neither dispatches an agent nor authorizes event replay, identity/order-link changes, payment actions or customer messages. A later agent follows the authority in its own session.

Template (fill only with supported facts):

> Investigate the following issues found in the UMI report for [dates], observed at [time].
> [Issue]: expected [behavior]; observed [evidence]. Affected records: [IDs/internal links]. Already checked: [checks]. Still unknown: [specific question].
> Establish the cause and affected scope, distinguish system failure from an operator omission or normal behavior, and propose a correction with verification. Report unresolved evidence explicitly. Begin with read-only inspection; do not replay or alter business records merely to reconcile the report.

For the current paid-event gap, reference the two event/order records only after identifying them; ask whether a conversation link was expected and whether any downstream event was actually missing. Do not pre-label both payments as integration failures. Main-body wording stays limited to the consequential caveat, such as “Chat-linked sales are not fully verified yet”; technical diagnosis belongs here. Confirmed operator instruction misses remain human coaching/actions, not hidden in this technical section.

Verification: a known actionable technical anomaly produces a specific prompt; healthy/irrelevant counters produce none; speculative missing events are labeled as questions; no fabricated IDs, duplicate warnings or automatic dispatch. Main findings and final prompt must use the same facts and uncertainty.

## Implementation boundary and alternatives

Chosen: extend existing facts collector with prior-period operational/activity aggregates and fully aged cohort pairs, build one small report-specific presentation object with explicit availability reasons, then render a bounded template. Keep detailed existing JSON/diagnostics privately. AI selects/explains findings and drafts coaching; deterministic code computes counts, dates, deltas and formatting limits.

Rejected: only hiding empty tables (leaves misleading comparisons and populations); AI summarizing the existing PDF (cannot repair missing data and unreliable denominators); new BI dashboard (unnecessary scope). Google Analytics' cohort guidance supports common membership criteria and elapsed-time comparison; this plan uses existing CRM events rather than introducing GA: https://support.google.com/analytics/answer/9670133?hl=en .

Relevant implementation paths:
- Shumabit: `scripts/crm-friday-report.js`, its tests, `scripts/crm-weekly-quality.js` and tests, existing report skill/prompt located during implementation.
- Chatwoot: `umi/app/services/funnel/{report,operational_report,cohort_report}.rb` and corresponding tests; change only source contracts needed for verified metrics.
- Existing `renderReportHtml` prints unbounded loops; `display` conflates missing reasons; `collectFacts` lacks prior service facts. Existing `reformatSaved` preserves old facts and interpretation and cannot on its own create new comparisons or corrected metrics.

Render explicit bounded sections, normal 11pt+ body text and readable tables. Reduce content by priority, never scale the PDF to tiny text, clip overflow or silently truncate an important caveat. Automated page-count checks flag more than four pages for editorial review. A fifth useful page is allowed; excess length must trigger pruning/review before delivery, not tiny text or automatic deletion of findings. Repeated evidence can remain in private files, not an attached 27-page appendix.

## Regeneration and delivery

First regenerate the supplied report's period **2–8 October 2026**, comparison **25 September–1 October**, without silently switching to Monday–Sunday. Collection began 27 September 23:33 Bangkok; the baseline is incomplete unless safely reconstructed and verified. At the original 9 October cutoff, two fully covered mature weekly cohorts are not available. The new report must say that, not invent a cohort trend. Future reports acquire the comparisons as coverage matures.

Preserve original facts, PDF and delivery receipt. Write a distinct revision directory and source manifest. Reuse original weekly facts when valid; gather missing prior-week facts with equal cutoffs; record regenerated-at separately from reporting cutoff. Current order linkage/classification may restate history: label this plainly and keep provenance privately. Do not advance only one cohort's observation window to make it look better. If later-age outcomes are shown at all, separate them explicitly from the original-cutoff weekly comparison.

Regenerate analysis from corrected scoped facts; do not reuse the old generic prose. Validate examples against retained full context and current redaction rules. Build a private preview first. Existing Orders scheduled message state must remain untouched while preparing the revision; no duplicate scheduled send. Sending/replacing a team report happens only after the corrected artifact is reviewed under the user's chosen delivery scope.

## Work sequence and acceptance

1. Finish spec review, explain material caveats to Ivan, obtain alignment before nontrivial code.
2. Audit two paid events and a representative set of counted/excluded SLA episodes read-only; record confirmed bugs versus presentation issues. Reconcile relevant report counts to retained facts; do not export raw customer transcripts to public artifacts.
3. Implement source/comparison changes only as needed, then bounded renderer and concise interpretation/prompt. Red→green regression tests for each confirmed bug.
4. Independently review actual diff; resolve correctness and simplicity findings.
5. Generate the revised 2–8 October report privately; verify figures and every page visually. Return the PDF and a concise correction summary. Production scheduling/deployment follows the reviewed implementation scope, preserving delivery idempotency.

Acceptance tests must cover: empty channel omission versus true zero; absent data versus zero; baseline partial/zero; percentage-point math; occurrence versus observed time; first/subsequent and reopened requests; mentions/thanks/spam versus genuine support; pending deadline versus missed; previous/current equal cutoffs; two mature full cohorts versus immature/partial; multi-conversation person and distinct order dedup; unpaid draft/barter excluded; order identity without attribution; no current snapshot masquerading as weekly metric; revised artifacts preserve original receipts; retry does not repost. Audit regression cases include exact identity match without sale attribution, later-introduced instructions, queued versus final command result, and later-corrected links; independent web/store purchase requires no chat-settlement command; evidenced manual chat settlement with omitted required step is an operator omission; attempted command with failed/unpersisted result is a system issue; unknown historical guide version or insufficient evidence is unresolved, not operator blame. Include normal and worst-case text fixtures with actual PDF page counts recorded, target three to four pages (five allowed with useful content), and no clipped content.

Release checklist: figures reconciled, unresolved gaps explicitly labeled, all included findings supported with no forced quota, owners/actions concrete, readable customer/topic headings and verified relevant ad context, clickable conversation links, prior-week comparability verified, length justified by useful content, Telegram summary matches PDF, no technical inventory, no unrequested customer/provider mutations. A report may honestly lack a cohort comparison; it may not claim that unavailable comparisons were completed.

## Review receipt

Independent business/simplicity and metric-correctness reviews completed 13 October. Incorporated: no forced quota of findings; explicit first-response denominators; exact weekly units and distinct-order rules; pinned cohort entry anchor and reopened-thread scope; stricter attribution evidence and missing-identity caveat. Source audit corroborated previous-week collector gap, unbounded rendering, overloaded missing-value wording and reply-obligation limitation. No production data repair or application code was performed during planning. Remaining verification tasks are explicitly listed above, not represented as completed.

User clarification, 13 October: four pages is a target, not a hard limit; five is acceptable when useful. Added operational instruction audit and per-order root-cause investigation, rather than a generic technical warning. Targeted business and correctness re-reviews completed; incorporated audit coverage, historical/current linkage timing and audit-specific regression cases. Implementation alignment remains pending.

User clarification, 13 October: replace “read answer · Conversation 1109” style headings with customer name and readable topic, plus the associated ad name when verified. Keep conversation links for traceability.


## Coaching completeness correction — 14 October 2026

Ivan approved restoring the useful coaching lost in the three-page revision. This section supersedes older example-count limits. The original report had three strengths and three improvements; the renderer cut these to one and two, and the one-off regeneration additionally filtered the source list. The brief report made an order-link investigation its opening headline instead of presenting the overall service lesson.

### Chosen change and alternatives

Keep the current facts, audit, PDF renderer and scheduled job. Restore the complete small set of validated examples rather than creating another ranking agent or copying old model conclusions. Group strengths by the six plain-language rules into compact bullets (customer name, concrete observed lesson, link, verified ad when relevant), without repeating long topic synopses for every strength. Keep fuller improvement cards with suggested responses. This is formatting, not code inferring which distinct advice is unimportant; customer examples retain names, topic and links. Remove both the summarizer and renderer example caps. Exact duplicate examples (same kind, conversation, rule, weekly/context evidence and advice) may be collapsed; distinct evidence or advice must remain. Normal editorial target is 2–3 strengths and 3–4 improvements, not a forced quota. If more supported material exists, retain it for editorial review; the existing PDF page check prevents an oversized report from being sent silently.

Begin with “This week at a glance”: supported positive pattern, most important service improvement and next actions, before detailed workflow/technical findings. The interpretation prompt must request this ordering explicitly, use the six-rule evidence, and distinguish uncertainty from failure. Avoid heading “What changed” when no comparison is supported. Preserve existing compatibility with string model output and structured findings/actions; no new model schema is required. Supported service/coaching actions take precedence over workflow-audit actions when selecting the short priority list, so three workflow findings cannot erase all service advice. Telegram must use the same service-first interpretation, not exclusively the first workflow finding; its caption remains within the existing Telegram limit.

Restore a compact six-rule overview from validated rule counts using plain-language names. Present met / assessed, opportunities to improve (partly met + missed), and not verifiable, where assessed = met + partly met + missed. Not-verifiable and not-applicable are outside that denominator; show not-verifiable separately. Missing rule fields remain unavailable, never default to zero. Explain that these are audit judgments, not conversion rates, and that categories have different denominators. Rules with no assessable evidence say “Not assessed”; do not turn missing evidence into failure or praise. This gives breadth beyond selected anecdotes. If delivery-time revalidation withholds examples or workflow checks because sources changed, withhold the aggregate rule overview with a short explanation; do not publish stale aggregate judgments or rebuild per-record provenance in this change. Do not aggregate into a numeric overall grade or compare differing audit populations as a trend.

Compute subsequent-response results from the existing validated response episodes, using the same membership, weekly scope, cutoff, timing, pending and carried-over rules as first responses. Keep first and subsequent separate. Display a compact subsequent-reply summary only for active channels; use business-minute medians from answered episodes, never combine channel medians. Untimed evidence withholds the affected rate, with a short caveat. First and subsequent missing timing are independent. Pending-only subsequent groups say pending, not zero performance or “No eligible first replies”; shared unanswered/carry counts are not duplicated. Retain the established nearest-rank median convention. Partial coverage labels rates as assessed samples and medians as measured answered episodes; give matching caveats in HTML and Markdown. No change to Chatwoot collector, stored classification or response attribution.

Regenerate 2–8 October from retained facts and the complete corrected quality audit. Preserve all older artifacts and delivery receipts in a separate revision directory. Recheck the old restock criticism against retained conversation evidence rather than importing it by fiat: if evidence remains insufficient, state the unresolved outcome rather than operator fault. Creator-contact handling can be secondary coaching but should not vanish merely because customer examples exist. Do not invent a policy prohibiting contact sharing or promise a restock date.

### Scope, failure modes and verification

Owned implementation: Shumabit `crm-business-facts.js`, `crm-business-report.js`, `crm-business-runner.js`, `crm-weekly-quality.js`, their focused tests, and report guidance. No live customer, commerce, advertising or conversation mutations. No new model calls needed to restore already validated examples. Separate source audit evidence from presentation choices; never rewrite saved model judgments just to make the report look better.

Regression tests must fail before changes: more than three distinct examples per kind survive summarization and all supplied distinct examples survive HTML/Markdown rendering; test actual retained full-state material (the original had 24 strengths), not just the already capped summary; coaching overview exposes partial/missing evidence fairly; opening interpretation appears before technical/order detail and remains the Telegram priority; three workflow actions cannot displace supported coaching; changed-source revalidation withholds stale rule totals; subsequent replies use their own denominator and omit unavailable/empty data rather than misreporting zero. Check unknown timing, pending requests, carried-over waits and customer versus collaboration membership through existing fixtures. Existing comparison and delivery-idempotency tests continue to pass.

Independent spec review precedes code; independent code review precedes delivery. Render the actual PDF and inspect every page; four or five useful pages are acceptable. If it exceeds five, edit repeated prose and layout while preserving distinct lessons and caveats; do not silently truncate. Updated code must affect the recurring report, not only this PDF. Regeneration does not itself send another Orders message.

Independent business and metric/failure-mode spec reviews completed. Incorporated summarizer caps/deduplication, explicit rule denominator, changed-source overview withholding, service-first caption/action selection, and independent subsequent timing/coverage. User alignment: “go” after the comparison and proposed correction; these clarifications preserve that agreed scope.
