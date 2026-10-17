# Customer waiting acknowledgements

Status: implemented and reviewed, 17 October 2026; not activated. User approved night and delayed-day acknowledgements; activation waits for a duplicate check in Meta Business Suite.

## Problem and scope

Customers arriving from the messaging campaign should know that their message reached UMI even when Mai cannot answer immediately. Acknowledgements must not conceal unanswered work or inflate human response statistics.

First activation is the existing Facebook/Instagram inbox (account 1, inbox 2). Existing website away messaging remains unchanged; email, voice, test and other inboxes are not silently opted in. No AI is needed and no historical messages are replayed.

## Chosen approach and alternatives

Use one small UMI acknowledgement service for both modes, using native business hours and public template delivery. Templates are excluded from human first-response/waiting calculations. A message commit hook queues an immediate night check or a five-minute day check. No new table, permission system or worker service. Selected inboxes leave native out_of_office_message empty, preventing two independent senders.

Meta Business Suite away/instant replies are an alternative, but split ownership and can duplicate Chatwoot acknowledgements. Inspect those live settings before activation; if an equivalent reply is already active, consolidate ownership before enabling this path. Native Chatwoot automation rules have no five-minute unanswered-message trigger. Independent review found the native night guard counts every template that calendar day: a daytime acknowledgement suppresses a later night reply. Senderless outgoing day messages avoid that suppression but inflate outgoing volume and allow cross-mode duplicates. One shared template acknowledgement per unanswered burst is simpler and consistent. Polling or AI-based acknowledgement decisions add unnecessary delay and failure dependencies.

Sources: Chatwoot business-hours guide https://app.chatwoot.com/hc/user-guide/articles/1777421876-business-hours-and-auto_responder and the pinned fork's MessageTemplates::HookExecutionService, Message model, SendReplyJob and UMI operator queue/operational report.

## Behavior

- Schedule is daily 09:00–21:00 Asia/Bangkok, read from the configured inbox.
- Night: on a new eligible incoming message outside business hours, acknowledge immediately unless that unanswered burst already has an acknowledgement or a successful public human reply occurred within the last five minutes. No midnight repeat. A later new incoming message can receive the away acknowledgement after the active-exchange suppression expires.
- Day: each new public incoming message may schedule a check five minutes later. At execution, re-read current conversation and messages. Send only during business hours, for an open conversation, when the current incoming burst has waited at least five minutes and has not received a successful public human response or a previous acknowledgement in either mode. A fresh daytime message after an unanswered night acknowledgement does not produce another acknowledgement; the operator still owes the original answer. Additional incoming messages do not restart the five-minute clock or create repeated acknowledgements.
- A genuine public human reply ends that burst; a later customer question may begin a new one. Private notes, classification notes, bot messages and template acknowledgements do not end the burst.
- Resolve/Snooze cancels the pending day acknowledgement; reopening without a new incoming message does not replay it. Night messages get their away reply, with no extra catch-up acknowledgement at 09:05. A day check that runs after closing time does not send.
- Ignore private messages, automatic emails, deleted/recovered messages, activity and bot messages as triggers. Pure Instagram story mentions/system share events must not receive either acknowledgement; a customer's actual text/question following the share can trigger it. Existing spam-labelled conversations are excluded.
- Only messages arriving after activation trigger jobs. Configuration stores an activation timestamp and allowed inbox IDs; pending jobs are tied to that activation timestamp so a later activation cannot replay old work. A delayed job older than the standard messaging window is discarded. Feature disable/inbox removal cancels pending sends.
- Serialize duplicate job checks on the conversation; record the burst reference on the created template itself, atomically. The burst starts at the earliest eligible incoming after activation, the latest successful public human response, and the latest resolved/snoozed boundary. A before-update conversation callback persists that lifecycle boundary as a message ID in additional_attributes. Jobs carry their trigger message and must not switch to a newer burst after a human reply or status boundary. This follows the existing Umi::Funnel::OperatorResolution pattern. Failed/ambiguous sends are not automatically duplicated by this feature; existing channel delivery status remains visible.
- Recheck at template creation; the normal channel job performs delivery. A simultaneous human reply at the final provider handoff cannot be made atomic with a remote API, just as for native out-of-office replies. Do not add a custom provider transport or retry loop.

## Copy

Use one concise bilingual message, Thai then English, without AI language detection or product questions.

Night: ขอบคุณที่ติดต่อ UMI ค่ะ ทีมงานให้บริการทุกวัน 09:00–21:00 น. (เวลาประเทศไทย) เราจะกลับมาตอบข้อความตั้งแต่เวลา 09:00 น. ค่ะ

Thank you for contacting UMI. Our team is available daily, 09:00–21:00 Bangkok time. We’ll be back to reply from 09:00.

Day: ขออภัยที่ทำให้คุณต้องรอนะคะ เราได้รับข้อความแล้วและจะรีบตอบกลับโดยเร็วที่สุดค่ะ

Sorry to keep you waiting. We’ve received your message and will reply as soon as possible.

## Implementation and configuration

UMI overlay owns the message callback and delayed job/service, attached through a guarded initializer. A single InstallationConfig JSON object UMI_CUSTOMER_ACKNOWLEDGEMENTS contains inbox_ids and started_at; absent configuration disables the feature. Configured inboxes must be FacebookPage channels, have business hours enabled and a valid timezone, and keep native greeting/away replies disabled. Fail visibly on incompatible setup. Other inboxes retain native behavior. Use the native weekly schedule, comparing local minutes with inclusive opening and exclusive closing (09:00 included, 21:00 excluded), native public `template` message type with no human sender, and a dedicated content-attribute marker identifying acknowledgement and burst. No labels, customer status, leads, purchase events or orders are changed.

Check native send behavior for both Facebook and Instagram-through-Facebook; automatic messages must not carry HUMAN_AGENT. Verify the production flag before activation. Check that external echoes match the existing source message rather than creating a human response.

## Verification and release

Tests: unanswered day message sends once after five minutes; subsequent messages and duplicate jobs do not multiply it; a human answer suppresses it; private/bot/template replies do not; failed human send does not falsely satisfy it; resolved/snoozed/deleted/recovered/spam/mention messages excluded; next real customer burst can acknowledge; closing-time and night boundaries; disable and stale job; source template preserves waiting_since and first_reply_created_at and remains excluded from UMI SLA. Exercise native FB and IG template payloads/echo matching. Use a deterministic failing-before/passing-after test for any existing behavior changed.

Independent design and code reviews precede release. Build immutable image, run required focused tests, deploy through canonical infrastructure with its backup and reminder-lock procedure. Activate only after Meta duplicate settings are verified. No test messages to real customers. Verify persisted configuration and queued-job behavior using controlled fixtures; first live delivery remains an explicit observation if no owner-only live test is available.

Update Mai's editable Google Doc: acknowledgements are automatic, do not replace her reply, do not stop SLA/reminders; she still answers, resolves or snoozes normally. Preserve human edits and both tabs. Record release evidence and any unverified gates here.

## Design review resolution

Two independent reviews identified native day/night template suppression and status-transition replay. The unified template service and durable resolved/snoozed message boundary address both. Night/day share one acknowledgement until a human reply; this explicitly prevents repeated apologies for the same unanswered customer. API login is pending; activation remains blocked, implementation can proceed under the approved behavior.

Final review clarifications: both modes require open status and identical message eligibility. Night jobs executed after opening are discarded, never converted to day catch-up. Every activation/re-add uses a fresh started_at. Acknowledgement lookup uses the whole current human/lifecycle/activation boundary, surviving deletion of its first incoming. Successful human follows existing UMI reporting: public human_response? and !failed?, not a new transport receipt definition. Day jobs are scheduled for the first eligible incoming plus five minutes; duplicate later triggers can enqueue redundant checks, but cannot send additional replies.

Inherited transport limitation: native Instagram echo deduplication assumes the send response persists source_id before its echo is processed. Review found a possible early-echo race, not an observed production incident. This feature tests normal response/echo order and does not introduce custom transport, metadata guessing or retries. Do not claim an all-ordering provider guarantee; an actual trace warrants a separate transport fix.

## Delivery checkpoint, 17 October

- Two independent design reviews and two independent code reviews completed; material findings fixed and re-reviewed.
- Local isolated database: 84 examples passed, zero failures, no skipped examples (acknowledgements, concurrent workers and existing operator queue suite).
- Scheduling regression: expected one five-minute job, observed zero before implementation; passes after implementation.
- Review regression: recent human reply followed by resolve and fresh incoming incorrectly generated a night reply; test failed before correction and passed after.
- Native send tests cover Facebook RESPONSE without HUMAN_AGENT, Instagram template delivery, persisted provider message IDs and ordinary echo deduplication. They do not send to real customers.
- Production readback: inbox 2 is FacebookPage, Asia/Bangkok, working hours enabled, greeting disabled, away text empty, global HUMAN_AGENT unset. New feature configuration is absent.
- Remaining: Meta Business Suite browser login and duplicate-auto-reply inspection; immutable build/deployment; activate with fresh timestamp; publish the guide addition below and verify an owner-only or first live delivery. No production customer acknowledgement has been sent by this change.

## Mai guide addition prepared for activation

**Automatic acknowledgements (Facebook and Instagram)**

Customers receive a short automatic confirmation immediately outside 09:00–21:00 Bangkok, or after five minutes during those hours if no team member has answered. It is sent once while the customer is waiting; extra messages do not trigger repeated apologies. A new question after a team member answers can start a new wait. Pure story mentions and known spam are excluded.

This automatic message is not your reply. Read the actual question, answer it, and finish any promised check. The five-minute human-response target and Telegram reminders keep running. Resolve when finished; Snooze when intentionally postponing. Do not enable a second away/instant reply in Meta Business Suite.
