# Review: UMI shared-number spec

Reviewed `docs/UMI-SHARED-NUMBER-SPEC.md` against the current checkout. No live Meta experiment or runtime test was run; the findings below distinguish checkout-proven behavior from proposed or externally dependent behavior.

## Blocking findings

### 1. The status regression example is not concrete or runnable

Spec §3, lines 191–209, calls `status_params_for(...)` without defining it, does not identify the spec file/context that provides `whatsapp_channel`, and omits the payload shape. The proposed call passes a bare `statuses` hash to `Whatsapp::IncomingMessageWhatsappCloudService`; that is valid for the service-level API only when the test intentionally targets the already-processed `value` shape. A test through `Webhooks::WhatsappEventsJob` instead needs the full `object → entry → changes → value` envelope because the job resolves the channel from `metadata.display_phone_number` and `metadata.phone_number_id` (`app/jobs/webhooks/whatsapp_events_job.rb:146-160`).

The checkout does prove the no-op implementation: `IncomingMessageBaseService#process_statuses` takes the first status and returns when `find_message_by_source_id` finds nothing (`app/services/whatsapp/incoming_message_base_service.rb:49-57`). Existing status specs are in `spec/services/whatsapp/incoming_message_service_spec.rb:229-296`, but they cover existing messages, not an unknown status.

Required correction:

- Choose and name the boundary: preferably add one service-level example beside the existing status examples, or add a job-level example with a complete webhook envelope and a real channel lookup.
- Define the exact `status_params` inline or via a named fixture/helper, using indifferent-access keys consistently.
- Execute the service/job once, not twice.
- Assert unchanged `Message`, `Conversation`, and `Contact` counts; assert no exception; if the job boundary is used, assert the job completes without retry-worthy failure.
- State whether “no log” is required. The current no-match branch has no logging, but observability is a separate behavior from the database no-op.

The “Klaviyo-only” part is not code-proven: the checkout proves how any unknown status is handled, not that a particular Meta/Klaviyo event will arrive at this job. Keep those claims separate.

### 2. The two-app experiment does not yet distinguish safe from unsafe outcomes

Spec §1.1, lines 105–147, says the initial subscription requests “establish each app's subscription and WABA-level callback,” but the shown requests only POST `subscribed_fields`; they do not set either collector callback. The phone-level POSTs then overwrite the same resource in sequence, and the reads are only `GET /{WABA-ID}/subscribed_apps`. This conflicts with §1, lines 61–79, which correctly says a WABA-level array cannot establish phone-level override scoping.

The safe criterion “A→A and B→B” is also not defined as an observable assertion. A single inbound event after B’s write, followed by “both collectors” receiving it, needs an explicit mapping: which app token/subscription, callback URL, event ID, timestamp, and `changes[].field` were observed at each collector. Otherwise fan-out, callback replacement, and misattribution can be confused. The optional Cloud API sends are not optional if they are part of the stated safety claim; if they are only a send-authorization control, say so and define their separate result.

Required correction:

- Define callback setup/verification for each app, or explicitly state that phone-level writes are the only callback-setting operation under test.
- Capture and read phone-level webhook configuration where the API supports it; do not treat the WABA subscription response as proof of phone-level scoping.
- Test and record deliveries after each write, not only after B overwrites A: A-only, A→B, reverse-order B-only, and B→A. Use unique inbound message IDs and a result table keyed by collector/app.
- Make the safe matrix explicit: each subscribed app receives the same event at its own intended callback; no app receives only the other app’s callback; order does not change the result. Define unsafe, indeterminate, timeout, duplicate, and partial-delivery outcomes as fail/stop conditions.
- Make Cloud API sends mandatory or remove them from the gate. If retained, specify what they prove (send authorization, status delivery, or echo-field behavior) and how each event is correlated.
- Add collector lifecycle, cleanup, timeout, redaction, raw-response storage, and token-revocation steps. “If possible” is incompatible with a migration gate.

### 3. Broken section references undermine the gate

The decision gate at lines 10–12 cites “§4.1,” but the experiment is §1.1. Lines 267–269 repeat the same nonexistent §4.1 reference. Correct both references before treating the document as an executable gate.

## Important findings

### 4. Proven, inferred, and unknown are mostly useful but blur at key boundaries

The High/Medium/Unknown convention at lines 36–41 is a good foundation. The following separation should be made explicit:

| Claim | Evidence status in this checkout | Review conclusion |
|---|---|---|
| Unknown status IDs are ignored by the incoming service | Proven by `app/services/whatsapp/incoming_message_base_service.rb:49-57` | High, once pinned by a runnable regression test |
| The webhook job completes and does not retry/dead-letter for that case | Strongly inferred from the no-op branch plus job retry policy; not tested at the job boundary | Inferred until a job-level test or explicit boundary rationale is added |
| The status belongs to a Klaviyo-only message | Not representable from the local status handler alone | Unknown/experiment-dependent |
| A manual Cloud channel auto-runs `perform` | Proven: `Channel::Whatsapp` after-commit callback and predicate (`app/models/channel/whatsapp.rb:38,162-165`) | High |
| `perform` may call `/register`, while registration failure is swallowed | Proven: `app/services/whatsapp/webhook_setup_service.rb:9-18,34-44` | High |
| `register_callback` is registration-free | Proven by `app/services/whatsapp/webhook_setup_service.rb:20-23` | High for the primitive; not yet proven as a safe channel create/update path |
| Phone-level Meta override is app-scoped | Not established by checkout or WABA-level reads | Unknown; disposable-asset experiment required |
| `message_echoes` will mirror sends between Cloud API apps | Not established | Unknown; n8n remains the only approved mirror |
| The n8n W5 payload/idempotency contract | Not inspected in this checkout | Unknown, not merely Medium; name the external artifact and inspection owner |

In particular, §4 labels routing evidence “High” while also saying exact identity matching is only Medium. Cite the exact local files/specs that establish the high-confidence portion, and limit it to the payload shapes actually covered. Do not cite “local Cloud API examples/specs” without paths. The local checkout does show `metadata`-based channel selection in `app/jobs/webhooks/whatsapp_events_job.rb:146-160` and BSUID coverage in `spec/services/whatsapp/incoming_message_whatsapp_cloud_service_spec.rb`, but those are narrower than every real Meta payload shape.

### 5. The private-note verification should follow the existing stronger pattern

The code claims in §5 are supported: `Message` always enqueues `SendReplyJob` after commit (`app/models/message.rb:397-400`), but `Base::SendOnChannelService#invalid_message?` rejects private messages (`app/services/base/send_on_channel_service.rb:46-50`), and private messages cannot be valid first replies (`app/models/message.rb:224-233`). The existing UMI test at `spec/jobs/umi/meta/ad_context_note_job_spec.rb:61-110` already demonstrates the desired assertions for reporting, delivery, and idempotency.

The spec should require the n8n test to assert the actual message contract (`private: true`, `message_type: outgoing`, `sender: nil`, event marker), provider-call absence, reporting fields, and duplicate suppression after persistence. “No `SendReplyJob`-driven network call” is weaker than either spying on the provider service or running the job with a provider spy. Also require the idempotency key and lookup/uniqueness behavior to be named, not just “event ID.”

### 6. Runbook gates need operator-grade evidence fields

The pre-migration gate and rollback are directionally complete, but the experiment and cutover steps still leave operational decisions to the operator. Add, for each gate item: command/request, expected response predicate, artifact filename, redaction rule, timeout, owner, and stop condition. In particular, define how to prove that no production save/after-commit callback occurred, how to capture `/register` attempts, and how to restore or disable callbacks without deleting historical data.

The rollback correctly says not to assume Twilio remains active, but “restore through the provider's documented number-reconnection process” needs the named provider procedure, credential owner, and a tested pre-migration checkpoint. Otherwise it is a dependency, not a runnable rollback step.

## Simplicity assessment

The overall decision gate is appropriately conservative. The simplest viable evidence set is smaller than the current prose suggests: one focused service/job regression test; one disposable two-app experiment with an explicit delivery matrix and both write orders; one foreign-number no-register guard; and one private-note/idempotency test. Remove or mark as secondary the optional Cloud sends, continuous collector health checks, and broad echo-shape monitoring unless they have a defined decision they change. Keeping them is reasonable only if their pass/fail effect is stated.

## Recommended acceptance bar for this spec

The document is ready to guide implementation when:

1. Every cross-reference resolves, especially §1.1.
2. The status test names its file/class, supplies a complete payload, has one invocation, and asserts all relevant counts and job behavior.
3. The Meta experiment has a deterministic order-by-order result matrix with callback/event correlation and explicit indeterminate failures.
4. Every claim is tagged as checkout-proven, locally inferred, externally supported, or real-asset unknown, with the evidence artifact named.
5. Each pre-migration and rollback step has an owner, command/action, expected result, captured artifact, and stop/rollback condition.
