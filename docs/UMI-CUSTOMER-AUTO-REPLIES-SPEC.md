# Customer waiting acknowledgements

Status: activated for inbox 2 on 18 October 2026 at 11:33 Bangkok, after live Meta duplicate-automation verification. First real delivery remains to be observed.

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

Two independent reviews identified native day/night template suppression and status-transition replay. The unified template service and durable resolved/snoozed message boundary address both. Night/day share one acknowledgement until a human reply; this explicitly prevents repeated apologies for the same unanswered customer. At design review, Meta login was pending; implementation proceeded with activation disabled until the duplicate check.

Final review clarifications: both modes require open status and identical message eligibility. Night jobs executed after opening are discarded, never converted to day catch-up. Every activation/re-add uses a fresh started_at. Acknowledgement lookup uses the whole current human/lifecycle/activation boundary, surviving deletion of its first incoming. Successful human follows existing UMI reporting: public human_response? and !failed?, not a new transport receipt definition. Day jobs are scheduled for the first eligible incoming plus five minutes; duplicate later triggers can enqueue redundant checks, but cannot send additional replies.

Inherited transport limitation: native Instagram echo deduplication assumes the send response persists source_id before its echo is processed. Review found a possible early-echo race, not an observed production incident. This feature tests normal response/echo order and does not introduce custom transport, metadata guessing or retries. Do not claim an all-ordering provider guarantee; an actual trace warrants a separate transport fix.

## Delivery checkpoint, 17 October

- Two independent design reviews and two independent code reviews completed; material findings fixed and re-reviewed.
- Local isolated database: 84 examples passed, zero failures, no skipped examples (acknowledgements, concurrent workers and existing operator queue suite).
- Scheduling regression: expected one five-minute job, observed zero before implementation; passes after implementation.
- Review regression: recent human reply followed by resolve and fresh incoming incorrectly generated a night reply; test failed before correction and passed after.
- Native send tests cover Facebook RESPONSE without HUMAN_AGENT, Instagram template delivery, persisted provider message IDs and ordinary echo deduplication. They do not send to real customers.
- Production readback: inbox 2 is FacebookPage, Asia/Bangkok, working hours enabled, greeting disabled, away text empty, global HUMAN_AGENT unset. New feature configuration is absent.
- PR #92 merged as `82c95d16b03a8de5beb2f443ef00a826b6a5cc00`. All 21 executed CI checks passed; unrelated deployment/MFA workflows were skipped by their conditions. Signed release tag `umi-v4.16.0-32` built successfully (run `39013724172`).
- Deployed through the canonical infrastructure checkout at 07:56 UTC: `ghcr.io/shumkov/chatwoot:umi-v4.16.0-32@sha256:6628f4a6f55650e98b571ec9e6cd225d1aa2804ec779ee0618bda6d478f793c4`. Infra pin commit `0230fcbd59cb8b56abf1d64eb8389c0dee48c9ab`. Image commit and all five implementation file hashes verified before installation. No migrations; protected database dump and prior configuration retained.
- Runtime acceptance: HTTPS 200; Rails/Sidekiq on the exact image with zero restart counts; acknowledgement hooks loaded, configuration absent, disabled scheduling is a no-op, zero acknowledgement messages. Unrelated services were not restarted.
- Under both reminder locks, fresh analysis covered 62 candidates (2 refreshed, zero unavailable or remaining). No-send preview had zero operator items/sends and no pending presentation changes; collaboration queue had 10 entries with zero pending/sends. Delivery receipts and crontab remained unchanged. Both locks released and reacquisition verified.
- Remaining: Meta Business Suite browser login and duplicate-auto-reply inspection; activate with fresh timestamp; publish the guide addition below and verify an owner-only or first live delivery. No production customer acknowledgement has been sent by this change. The editable Mai guide has not yet been changed to claim these acknowledgements are active.

## Activation checkpoint, 18 October

- Live Meta Business Suite inspection for UMI Page `516819784857962`, business `497970999394825`: Away message and FAQ off; Auto-reply not configured (offered under Suggested / Try It); Business Agent offered for activation. Existing Lead reminder was inspected: an admin-only note after 12 hours in Qualified, not a customer reply. Meta settings were not changed.
- Reviewed inbox validation passed before creating InstallationConfig `107`, `UMI_CUSTOMER_ACKNOWLEDGEMENTS`, with `{"inbox_ids":[2],"started_at":"2026-10-18T04:33:14.091044Z"}`. Persisted readback confirmed activation. No historical messages were replayed or test messages sent to customers.
- Rails and Sidekiq read back the same configuration; hooks and validator passed, and the live worker consumes the high queue. Fresh analysis: 63 candidates, zero unavailable or remaining. No-send preview: zero operator items/sends/pending presentation changes; collaboration queue 9 with zero pending. Existing receipts and crontab unchanged; both reminder locks released and reacquisition verified. HTTPS 200, no restart or redeploy. At 04:34:18 UTC there were zero incoming messages since activation and zero acknowledgements, so real delivery was not yet observable.
- Updated both tabs of [UMI chat guide for Mai](https://docs.google.com/document/d/1F2DG54uY7P6a8r-_Ms2vYbqUBL_JcGfCuJ_sNI9-qHw/edit): full operating guidance in the main tab and a reminder in the playbook's delayed-response section. Each update used a fresh document revision; readback verified the additions and preserved existing paragraphs, styles and the other tab. Exported PDF pages 2 and 12 were visually checked.
- Remaining observation: the first eligible real incoming message and its provider delivery status. Configuration activation does not by itself prove live delivery; no customer message was manufactured for this check.

## Mai guide addition published at activation

**Automatic acknowledgements (Facebook and Instagram)**

Customers receive a short automatic confirmation immediately outside 09:00–21:00 Bangkok, or after five minutes during those hours if no team member has answered. It is sent once while the customer is waiting; extra messages do not trigger repeated apologies. A new question after a team member answers can start a new wait. Pure story mentions and known spam are excluded.

This automatic message is not your reply. Read the actual question, answer it, and finish any promised check. The five-minute human-response target and Telegram reminders keep running. Resolve when finished; Snooze when intentionally postponing. Do not enable a second away/instant reply in Meta Business Suite.

## Extension: website, working WhatsApp and LINE (18 October, reviewed design)

This section extends the already active inbox 2 implementation; it does not restart that activation. User-approved scope is website inbox 1, Twilio WhatsApp inbox 6 and LINE inbox 7. Email inbox 8, native legacy WhatsApp inbox 3, SMS/voice inbox 5 and technical inbox 9 remain excluded. No customer test messages, historical replay or provider migration is part of this change.

### Findings and chosen design

Production readback on 18 October confirms inbox 6 is `Channel::TwilioSms` with `medium=whatsapp`; inbox 5 has `medium=sms`. All four selected inboxes have seven daily 09:00–21:00 Asia/Bangkok rows. Only website inbox 1 has a native away message. Its text must be backed up and cleared at cutover, not left running beside the shared acknowledgement service.

Reuse the same service, delayed job, message marker and conversation lifecycle boundary. Extend validation to WebWidget, Line and TwilioSms only when its medium is WhatsApp. Keep explicit configured inbox IDs; recognizing a channel type never activates every inbox of that type. The HUMAN_AGENT validation is specific to FacebookPage; it must not prevent website, WhatsApp or LINE acknowledgements. Shared hours/native-greeting/native-away validation still applies to all selected inboxes. Native Whatsapp channels remain unsupported in this extension.

Native `SendReplyJob` already accepts text templates. Twilio sends them as free-form `body`, without a Content SID; Chatwoot's internal template type does not mean a WhatsApp-approved template. LINE uses its existing push transport. Website delivery uses the existing public-message broadcast/widget rendering. No provider sender, polling loop, new table, AI, custom retry or UI is needed. No Enterprise override of these acknowledgement classes was found; native transport paths remain unchanged.

Website acknowledgements appear in the widget only. Review found that native email continuity schedules notification mail for a text template but then filters its text out of the mail body, potentially sending a useless recap. Add a small guarded UMI prepend to `Messages::SendEmailNotificationService` that skips only WebWidget messages bearing the acknowledgement marker, before taking the Redis notification lock or incrementing the email counter. Human replies and unmarked templates retain native continuity; explicit transcripts are unchanged. This intentionally replaces the old website-away email side effect, rather than changing the mailer or disabling continuity globally.

### Activation boundaries without interrupting Facebook/Instagram

Keep `inbox_ids` and the existing global `started_at`. Add an optional `inbox_started_at` JSON object keyed by string inbox ID. Effective activation for a selected inbox is its explicit timestamp when present, otherwise the existing `started_at`. Initial extension config retains inbox 2's original timestamp and supplies fresh timestamps for 1, 6 and 7. All selection, scheduling, execution and current-burst queries use the same effective timestamp; job arguments remain `(message_id, generation, mode)` and generation is that inbox's effective timestamp.

The worker loads the message and confirms inbox membership before comparing the job generation to that inbox's effective timestamp. Existing queued inbox 2 jobs remain valid. Old messages in newly enabled inboxes cannot trigger or enter the new burst. Disabling/removing an inbox cancels its jobs; any re-add must set a fresh explicit timestamp for that inbox. Unchanged inboxes retain their timestamps. This is an additive configuration field, so rolling back to the previous image also requires restoring the saved inbox-2-only configuration before old workers run.

Alternatives rejected: resetting the global timestamp cancels existing Facebook/Instagram waits; adding new inboxes with the old timestamp gives them the wrong historical boundary. Replacing the entire configuration format requires an unnecessary coordinated format migration. Provider-specific automations divide ownership and cannot share our human-response and resolved/snoozed checks. Separate LINE reply-token handling adds a second transport and cannot cover the five-minute delay because reply tokens normally expire after one minute.

### Provider limits and duplicate checks

- WhatsApp: free-form replies require the customer-service window opened by an incoming customer message. Existing age guard discards a trigger older than 24 hours; retain it. Twilio transport charges still apply. Verify the actual sender or messaging-service incoming webhook routes directly to Chatwoot and has no additional Studio/Function/TwiML auto-response. Local callback code returns HTTP 204 and only enqueues inbound processing; this alone does not prove the live Twilio routing.
- LINE: native push messages count against the account's monthly allowance. Check remaining quota and response settings before enabling. LINE Official Account Manager auto-response messages must not duplicate this waiting acknowledgement. A greeting on adding the account is a separate event; inspect rather than blindly disabling all greetings. API success is not proof that a blocked user received a message.
- Website: activate during daytime, well away from the 09:00/21:00 boundaries, when native night replies cannot run. Clear the native away message and add the new inbox activation in one database transaction; preserve the exact old value for rollback. Reload the inbox before acknowledgement validation so an inbound request spanning cutover cannot retain the old away text and fail validation. The database transaction alone does not serialize in-flight requests. Verify public template visibility through the widget's real message path. Keep human-reply email continuity and website business-hours display unchanged.
- Preserve existing transport failure reporting. Create no additional acknowledgement records or custom retries. Native delivery retries remain: provider acceptance followed by failed local persistence can cause a duplicate send on retry. One acknowledgement record therefore does not guarantee exactly one provider delivery. LINE native delivered status means API acceptance, not confirmed recipient receipt. Do not redesign provider transports in this extension.

Sources consulted: [Twilio WhatsApp overview](https://www.twilio.com/docs/whatsapp/api), [Twilio WhatsApp pricing](https://www.twilio.com/en-us/whatsapp/pricing?locale=en), [LINE sending messages](https://developers.line.biz/en/docs/messaging-api/sending-messages/), [LINE API reference](https://developers.line.biz/en/reference/messaging-api/nojs/). Pinned source: `SendReplyJob`, `Base::SendOnChannelService`, `Twilio::SendOnTwilioService`, `Line::SendOnLineService`, `Messages::SendEmailNotificationService`, `ConversationReplyMailer`, `ActionCableListener`, widget `ChatMessage.vue`, and the existing UMI acknowledgement service/job/callbacks.

### Verification and rollout

1. Independent design reviews: simplicity/channel fit and activation/delivery failure modes. Resolve findings before implementation.
2. Add tests before code: eligible website/LINE/Twilio WhatsApp triggers currently fail channel validation; pin the actual failure, then implement. Reject Twilio SMS, native legacy WhatsApp, Email and API even if accidentally configured. Test the two modes and shared human-response/dedup/lifecycle behavior on newly supported channels.
3. Test activation preservation: an existing inbox 2 job still executes after adding other inboxes; pre-cutover messages in a new inbox do not schedule/replay; removal and fresh re-add reject old jobs. Include old configuration without the new field.
4. Exercise native delivery with mocked provider boundaries: Twilio free-form body/no Content SID/provider source ID and failure status; LINE push payload and success/failure status; website public event/visible template. In the same conversation, assert acknowledgement skips notification job/Redis lock/email counter and a later human reply still queues email normally; include an unmarked template control. Test a stale inbox instance spanning daytime cutover and record native post-acceptance failure behavior. Keep existing SLA and operator queue regression suite green. No real customer sends during tests.
5. Review the actual code independently, update patch row 62, merge and build an immutable release. Deploy via the canonical infrastructure owner with existing inbox-2 config unchanged. Verify all Rails and Sidekiq processes run the new image before any config activation. Run focused runtime readback before activating additional inboxes.
6. Verify live provider duplicate settings and quota. Activate each ready inbox with a fresh timestamp; website settings cutover is atomic and performed in daytime as above. For rollback restore website away text and saved inbox-2-only config together before reverting the image. Pending UMI checks are cancelled by config removal; already-created messages in native SendReplyJob are not recalled. Test and report this boundary. Unverified channels stay off and are reported explicitly, without blocking already verified channels. Preserve inbox 2's original generation. Never claim all channels live based only on a code deployment.
7. Read back settings in Rails/Sidekiq, verify hooks and no-send operator preview. Update Mai's guide for the actual active channels, preserving human edits; leave the Meta-specific playbook unchanged when its instructions still apply. Confirm first natural delivery per channel when available; otherwise record it as an outstanding observation, not a passed test.

### Implementation evidence (local branch, 18 October)

The extension is implemented in the UMI service/job plus a guarded email-notification prepend. The original global timestamp remains the fallback and inbox 2's queued generation is unchanged. A new focused spec first failed on website's Facebook-only validation, then passed for website, LINE and Twilio WhatsApp, generation preservation and cancellation, stale website inbox state, unsupported channels, native send boundaries, and website email continuity. The local test uses an isolated database and Redis DB 13; it does not contact customers. This was code/test evidence before runtime activation; the production receipt below is separate.

LINE API quota readback on 18 October: monthly limit 300, totalUsage 0. Website continuity_via_email is enabled. Live Twilio routing and LINE response settings are still unverified; those inboxes remain disabled.

Independent design review: channel/simplicity reviewer confirmed native delivery compatibility and identified the website-email filtering issue. Failure-mode reviewer identified in-flight cutover state and native retry ambiguity. The revisions above address these findings with a marker-only notification skip, daytime cutover plus fresh inbox validation, and explicit delivery/rollback limits; no additional worker or transport is introduced.

Both independent reviewers accepted the revised design with no remaining must-fix findings. The user approved implementation. Twilio sender-list API responded successfully, but its returned entry has not yet been matched to the configured inbox sender; do not treat routing as verified.

### Website activation receipt (18 October)

Release `umi-v4.16.0-33` uses merged source `69af2aa22cfd6c2f23cd16a646361e7fe05ca60a`. Rails and Sidekiq independently reported image digest `d1bc4d91bf4985415962040d731ac9d9415cd8eb8176463e473f77604a46160b`, and each validated both configured inboxes, the acknowledgement hooks and the high-priority queue. InstallationConfig `107` now selects inboxes `[1, 2]`. Its original global `started_at` remains `2026-10-18T04:33:14.091044Z` for Facebook/Instagram inbox 2; `inbox_started_at` sets website inbox 1 to `2026-10-18T05:53:10.310234Z`. The website's native away message is blank. Twilio WhatsApp inbox 6 and LINE inbox 7 remain off. No historical replay or customer test message was sent; first natural website delivery is still unobserved.

After that activation, the [main tab of Mai's guide](https://docs.google.com/document/d/1F2DG54uY7P6a8r-_Ms2vYbqUBL_JcGfCuJ_sNI9-qHw/edit?tab=t.0) added website to the acknowledgement heading and states that the acknowledgement appears only in the chat widget while later human replies retain normal email continuity when enabled. The edit used a fresh document revision and required-revision write control. Readback preserved all other main-tab paragraphs and the Meta-specific playbook tab; the exported PDF was visually checked. No comment or team message was added.
