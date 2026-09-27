# Shumabit in Chatwoot: a small bridge to the existing agent stack

Revised 2026-09-27 following the user's direction. This replaces the previous
stateless, tool-free observer proposal. Use the existing VPS, Shumabit workspace,
shared memory, skills, model/proxy setup and Orchestra session engine. Do not
build a new permission system, model gateway or analysis platform.

## What the first version does

A staff member writes a private note such as `@shumabit summarize this chat and
suggest a reply`. A small worker receives that Chatwoot event, reads the
conversation through the existing Chatwoot client, resumes its agent session and
posts Shumabit's answer as a private note. `@shumabit make that shorter` resumes
the same session and understands the prior answer. Start with one existing
account and the current staff workflow.

The agent can summarize, analyze sales intent, suggest replies, consult business
knowledge and use the selected existing skills. The human sends customer replies.
Order creation and automatic campaign/status changes remain later work. Sharing
business memory is wanted; isolating the agent from all existing knowledge is not.

## Reuse rather than rebuild

- Add a `shumabit-chatwoot` agent file in the Shumabit workspace, with the existing
  identity/business-memory references and a selected skill set. Reuse the
  Chatwoot API skill/client and relevant existing product/FAQ/Shopify reads.
- Reuse Orchestra, the session engine already used by Polygram and Water. Its
  `ProcessManager#getOrSpawn` and `send` support resumed sessions. A plain-text
  conversation needs no new structured-output protocol.
- Run one small Chatwoot worker under the existing VPS service conventions.
  Polygram remains the Telegram transport; the new worker is the Chatwoot
  transport. Do not pretend Polygram's current IPC `send` starts an agent turn:
  it currently sends a Telegram message.
- Use the existing configured model through the existing CLIProxy/subscription
  route, once the deployed runtime's compatible configuration is inspected.
  Do not introduce another model account, SDK upgrade or proxy service.
- Use normal existing Chatwoot API credentials and ordinary service configuration.
  Selected skills/instructions are workflow scope, not a new security sandbox.

## Sessions and memory

Keep one conversation session keyed by account plus Chatwoot conversation ID.
Persist the engine session ID with the existing agent/working-directory identity
convention so a worker restart resumes the right discussion.
Keep the worker alive, not every agent process: Orchestra can release idle
processes and resume their saved sessions on demand.

All these sessions can read the same Shumabit business memory and follow its
existing memory-writing convention. Customer conversations have separate working
histories; they do not all append into Ivan's Telegram session. This is context
organization, not a new permissions model. Shared business knowledge and a shared
live transcript are different things. Do not copy conversation transcripts into
global memory automatically or invent a new memory database.

## Small bridge responsibilities

1. Use Chatwoot's normal `message_created` webhook as the entry point, reachable
   through the existing VPS networking/auth arrangement. Verify its concrete
   route during wiring; do not add bespoke cryptographic request envelopes.
2. React only to staff-authored private notes beginning `@shumabit`. Ignore
   customer text, ordinary notes and Shumabit's own output to avoid loops.
3. Remember source message IDs and session IDs in a small local store. Process
   messages in order for each conversation; duplicate webhooks do not run twice.
   Start with one agent turn at a time for this one-person workflow.
4. Fetch current conversation context using the existing client. Include staff
   requests and prior assistant replies, so follow-ups work normally. Treat
   customer text as conversation content, not instructions to change the agent.
5. Deliver final answers using a small existing-client helper that always posts
   a private note to the originating conversation. Reuse the engine's existing
   tool-delivery / `alreadyDelivered` convention so fallback text is not posted
   a second time. Keep normal human assignment
   and status. Do not attach an inbox bot that takes ownership of conversations.
6. Report an obvious failure to staff; allow retry with a new mention. Do not
   promise exactly-once delivery through crashes or build an outbox/reconciliation
   platform for this prototype. A missed webhook can be retried by staff.

Verify the actual configured Chatwoot automations do not turn these private notes
into public messages or workflow changes. If an existing rule does that, make
only the small necessary exclusion. Reuse normal Chatwoot behavior otherwise.
No broad fork patch, new Rails tables, custom ACLs, signed context snapshots,
structured result contracts or separate tool-free model service are planned.

## Implementation and verification

First inspect the deployed non-secret runtime wiring: Shumabit working directory,
agent/memory conventions, Orchestra/backend version and existing proxy route.
Local source confirms the reuse points; it does not establish deployed versions.
Then implement the agent definition, small worker, private-note helper and service
configuration in the appropriate isolated repositories. Do not change current
Polygram behavior or upgrade its runtime as part of this task.

Use fake Chatwoot/agent adapters to test: mention filtering, duplicate events,
conversation-to-session mapping, ordered turns, follow-up continuity, session ID
persistence, private reply routing, loop avoidance and visible failures. Inspect
existing automation behavior. Then verify a staff-only example on the actual
integration when ready; distinguish local checks from a deployed working bridge.

The recovered-message provenance fix remains independently useful to later
funnel classification. This bridge does not depend on completing the full funnel
ledger or Meta/Klaviyo integrations first. Later scheduled analysis can reuse the
same agent/skills; deterministic payment and campaign sync remain separate jobs.

## Alternatives

Embedding a new transport directly into Polygram would also reuse sessions, but
its dispatcher/output handling is Telegram-specific. Prefer a small consumer of
Orchestra, as Water already is, over changing the working Telegram bot. Polling
Chatwoot is an alternative if exposing a normal webhook receiver needs more setup
than the pilot warrants; choose based on the existing VPS network, not a new
platform design. The previous stateless restricted-worker design is superseded.

## Review

Independent runtime-feasibility and simplicity/domain reviews accepted this
revised scope with no blockers. Incorporated the existing session-identity and
already-delivered conventions. No bridge code or live changes have been made.
