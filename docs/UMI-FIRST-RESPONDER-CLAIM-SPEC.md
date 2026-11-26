# First authenticated human reply claims an unassigned conversation

Status: implemented for proposed release `umi-v4.16.0-46`, base `umi-v4.16.0-45` (`cc960dc39`). Tracking: issue #117.
Two independent spec reviews and a focused re-review of the capture ordering folded in; root accepted the provenance
boundary (§2). Two independent code reviews folded in. Feature off until reviewed source, deployment and config
acceptance.

## Problem

Mai is temporarily unavailable. Ivan (User 1) and Dina (User 6) share the queue of unassigned conversations. Infra has
set Mai offline and disabled native auto-assignment on inboxes 1, 2, 3, 5, 6, 7 and 8 (2026-11-26), so new and reopened
conversations stay unassigned. Today a public reply does not assign its sender (`Messages::MessageBuilder`,
`Api::V1::Accounts::Conversations::MessagesController#create`). Ownership needs the explicit **Assign to me** banner
action, which also shows on conversations owned by someone else and reassigns them without a lock (last writer wins).
Wanted: the first actual human who answers an unassigned conversation becomes its owner without a click, and later
replies do not move it. Taking a conversation from its owner stays the explicit one-click action.

The hard constraint: User 1 is both Ivan and the shared automation actor (both automation access tokens belong to
User 1, infra preflight), so the sender id alone cannot tell a human reply from an automated one.

## 1. Behaviour

A reply claims the conversation for its sender when **all** of these hold. They are checked in this order, cheapest
first:

1. Before the action: the request was not token-authenticated and `Current.user` is a `User`. That user and the
   devise `client` validated for the request are recorded (§2).
2. The request created the message through `POST /api/v1/accounts/:account_id/conversations/:id/messages` and
   answered with a status below 400. Every error response is excluded, including a reply that was committed although
   its request answered 422 (§3).
3. The message is `outgoing` and not private. Its sender is the recorded user (a `sender_type: AgentBot` request is
   excluded, also when it carries `external_echo`), and native `human_response?` holds (no automation rule, no
   campaign).
4. The conversation's inbox is in the configured inbox list. The configuration is read only now; absent means off.
5. The user is a member of the conversation's inbox. That covers any member (today Users 1, 5, 6 and 8), not only Ivan
   and Dina.
6. **Human provenance (§2):** the recorded client belongs to an interactive login session of that user. This row is
   read last.
7. Under a row lock on a freshly loaded conversation, re-read: the conversation is `open` and has no assignee and no
   assignee agent bot.

The claim is `update!(assignee: user)` on that freshly loaded conversation, the same save path as native assignment.
Native callbacks then:
- record the activity "… self-assigned this conversation" (`AssigneeActivityMessageHandler`, `self_assign?`);
- dispatch `ASSIGNEE_CHANGED`;
- skip the notification for self-assignment (`Conversation#notifiable_assignee_change?`).

Changing only the assignee does not trigger auto-assignment.

**Captain.** On a Captain-pending conversation, `Enterprise::Message#mark_pending_conversation_as_open_for_human_response`
opens it when a human replies, before the claim runs. So the human who takes over from Captain claims it. A
conversation pending for an AgentBot stays pending and is not claimed. The target inboxes are expected to have no
Captain assistant; that is an activation readback item.

**A human-sent WhatsApp template counts.** A WhatsApp template sent from the composer is an `outgoing` message with
`template_params` from a User and claims like any reply. `message_type: template` rows (native templates, UMI
acknowledgements) never pass through this action.

Never claims:
- private notes;
- bot replies, AgentBot tokens, `sender_type: AgentBot`;
- external echoes from Meta apps, and webhook, recovered or imported messages (they never pass through this action);
- macros, automation rules, campaigns, UMI product-card and draft endpoints, and the contact-page compose path
  (`ConversationsController#create`). All are out of scope; they create messages elsewhere;
- any request with an `api_access_token` header (User 1's automation tokens, integration clients);
- devise tokens without an interactive login session: impersonation, server-minted tokens, account-signup responses;
- retries of an existing message (`messages#retry`);
- conversations that already have a human or bot owner, or that are resolved, snoozed or bot-pending at claim time.

## 2. Human provenance (consequential boundary, for root review)

How a request is authenticated, on the deployed source:

| Fact | Source |
|---|---|
| A request with an `api_access_token` header (Puma maps `Api-Access-Token` in any case to `HTTP_API_ACCESS_TOKEN`) authenticates by `AccessToken` and sets `Current.user` to its owner; otherwise devise `authenticate_user!` runs. Neither reads a query string or cookie for the token. | `app/controllers/api/base_controller.rb:4-12`, `app/controllers/concerns/access_token_auth_helper.rb:9-21` |
| `set_current_user` reads devise first; a token header then overrides `Current.user`. A request carrying both is treated as the token owner. | `app/controllers/application_controller.rb:10,16-19` |
| Devise standard (cookie) support is off, so a super-admin browser session cannot authenticate API calls. | `config/initializers/devise_token_auth.rb` (`enable_standard_devise_support`, `cookie_enabled`) |
| A `user_sessions` row is written only by a successful interactive sign-in: password, SSO or MFA, never on impersonation. Activity tracking only updates existing rows, and rows are removed when their token is removed. | `app/controllers/devise_overrides/sessions_controller.rb` (`render_create_success` → `track_user_session unless @impersonation`), `app/services/user_session_tracking_service.rb` (`create_or_update!` vs `update_activity!`), `app/models/user.rb` (`sync_user_sessions`) |
| The web dashboard sends devise `access-token`/`client`/`uid` headers from its auth cookie, and nothing under `app/javascript` sends `api_access_token`. | `app/javascript/dashboard/helper/APIHelper.js:9-23` |
| The official mobile app signs in through `auth/sign_in` and sends devise `access-token`/`uid`/`client`; there is no `api_access_token` in its source. | `chatwoot/chatwoot-mobile-app` latest commit `4a0cd5a5` (2026-11-25; not necessarily the installed store build): `src/store/auth/authService.ts:24,42-45`, `src/services/APIService.ts:74-83` |
| Shumabit's Chatwoot client sends `Api-Access-Token`; no local automation repo signs in through `auth/sign_in`. | `shumabit-claude@798f0684` `skills/chatwoot-api/scripts/cw.js:44-51`; repo search 2026-11-26 |

**How devise binds the current request (devise_token_auth 1.2.5, `app/controllers/devise_token_auth/concerns/set_user_by_token.rb`).**
- `set_user_by_token` (lines 26-99) reads `uid`, `access-token` and `client`, from the header first, then params,
  then a Bearer token; the auth cookie is not read because cookies are off.
- It checks `user.valid_token?(@token.token, @token.client)`, which requires an entry for **this client** in
  `user.tokens` whose token hash matches and whose `expiry` is in the future (`app/models/devise_token_auth/concerns/user.rb:106-131`).
- On success `@token.client` holds that validated client. On any failure it is set to `nil` and the user is `nil`,
  so `authenticate_user!` answers 401 and `create` never runs.
- Chatwoot runs devise with `change_headers_on_each_request = false` and `token_lifespan = 2.months`
  (`config/initializers/devise_token_auth.rb:6,10`): the token does not rotate per request, and the client never changes.
- The claim captures the authenticated user and the validated client in a **`before_action` on `create`**. Rails 7.1
  runs it inside the authentication, account and conversation callbacks, after `authenticate_user!` or the token
  checks and after authorisation. It runs before the action, so code inside the action that swaps or resets
  `Current.user` cannot change the provenance. The session-row query itself runs in the `after_action`, only after the
  cheap checks pass.
- On a token request, `@token.client` can hold an **unvalidated** `client` header: devise fails first, token auth then
  sets the resource, and a later `current_user` call re-reads the header without validating it. The token exclusion is
  therefore checked first and carries real weight.

**Predicate.** The two decisive checks are:
- `!authenticate_by_access_token?`: the same method that chose the authentication path. A request with
  `api_access_token` is rejected even when its user also has interactive sessions, and even when it carries a valid
  devise `client` or a bare `client` header.
- `user.user_sessions.exists?(client_id: client)`, where `client` is the devise `@token.client` captured before the
  action: that exact, validated client came from an interactive sign-in.

`Current.user.is_a?(User)` is captured with them, but it can never decide on its own, because devise only
authenticates `User`.

So the check binds the current request's validated token and client to a session row for the same client. Any other
session User 1 has, past or present, does not satisfy it. A devise comparison such as `current_user == Current.user`
would add nothing, because token authentication also stores the token owner as devise's resource
(`access_token_auth_helper.rb:19`).

**Session lifecycle.**
- **Creation.** A row is written only by `DeviseOverrides::SessionsController#render_create_success` →
  `track_user_session`, for password, SSO and MFA (`mfa_token`) sign-ins through `create`
  (`app/controllers/devise_overrides/sessions_controller.rb:13-30,52,110,222-231`). It is skipped on impersonation
  (`track_user_session unless @impersonation`; `@impersonation` set at :99 from `sso_auth_token_impersonation?`).
- **Activity tracking never creates rows.** `TrackSessionActivity` only calls `update_activity!`, which updates an
  existing row (`app/controllers/concerns/track_session_activity.rb:10-18`, `user_session_tracking_service.rb:24-29`).
- **Expiry.** An expired token fails `valid_token?`, so the request is a 401 before any check.
- **Revocation.** Sign-out deletes the client's token. Profile session revoke (`sessions_controller.rb:180-185`) and
  device-limit eviction (`max_number_of_devices = 25`) delete the token too. `User#sync_user_sessions` then removes rows
  whose client is gone (`app/models/user.rb:122,219-222`), and the old headers get a 401.
- **Rotation.** None per request. If it were turned on, devise rotates the token but keeps the client, so the row
  still matches.
- **Sessions older than tracking.** Tracking shipped upstream in v4.15.0 (`20260611184600_create_user_sessions`) and
  no migration backfills rows. A session signed in before that has no row and fails safe until the next sign-in.
- **Sign-ins without a row.** `AuthHelper#send_auth_headers` (account signup, password reset, email confirmation) and
  devise registrations log a browser in with a client that has no row. Invited agents start this way. Their replies
  fail safe (no claim) until they sign in through the normal login.
- It holds for a browser or mobile client that signed in interactively, and fails for every access-token request,
  whatever user owns the token.
- It also fails for impersonation, `create_new_auth_token` and signup-response tokens.
- It is evaluated inside the request, because the message row does not record the authentication method; the claim
  cannot move to a later job.

**Accepted limitation (root, 2026-11-26).** The check proves an authenticated interactive session of that user, not the
physical presence of a person. Anyone who completes an interactive sign-in, or drives an already signed-in session,
acts as that user. This is the standard property of any signed-in session, not a new permission flow:
- automation that signs in with Ivan's or Dina's password or SSO;
- an SSO login link a Platform API app generates for that user (`POST /platform/api/v1/users/:id/login`);
- browser automation driving a logged-in dashboard, or a copied `cw_d_session_info` cookie (tokens do not rotate; the
  session stays valid for about two months).

This is safe only while automation keeps using access tokens and nobody automates a signed-in session. Every client
found today does so, but Chatwoot does not enforce it. Client headers such as `X-Chatwoot-Client-Name` add no proof,
because they are client-controlled. No new API bypass or token type is introduced.

Activation readback, a root/infra action with no production access from this worker. These are **checks, not
permission** to change signup, Platform Apps, Captain or roles. Any unexpected value is reported before activation:
- `ENABLE_ACCOUNT_SIGNUP` false;
- no Platform App with access to users 1, 5, 6 or 8;
- no Captain assistant on the target inboxes;
- `custom_role_id` nil for users 1, 5, 6 and 8;
- every configured inbox member has signed in through the normal login since session tracking shipped, otherwise their
  replies do not claim;
- native auto-assignment off on the configured inboxes;
- the configured inbox list, as integer inbox ids. String ids match nothing, so the feature would stay off silently;
  a value that is not an `inbox_ids` hash logs the claim-failed line on every reply.

## 3. Claim event and failure semantics

- The claim happens **at message creation**, in an `after_action` on `create`. That runs after the action, after
  `Umi::Funnel::SettlementMessages`' `Message.transaction` has committed, inside `handle_with_exception` and before
  `Current.reset`. It never happens at provider delivery: delivery is asynchronous (`SendReplyJob`) and the
  authentication method is gone by then.
- **Ownership is not delivery proof.** If the send later fails (`status: failed`), the claim stays. The responder owns
  the conversation and sees the failed message to retry or resolve. The action does not check the channel's messaging
  window, so a reply outside it is created, claims, and fails at delivery.
- A create that ends in an error response does not claim. The builder may have raised, or the settlement transaction
  may have rolled the reply back. In production `Umi::Funnel::SettlementMessages`' `Message.transaction` is the outer
  transaction, so an after-commit step of the message (such as the `SendReplyJob` enqueue) that raises does so after
  the reply committed, and the request still answers 422. The status check keeps that committed reply out too.
- **A claim error never breaks the reply.** It is rescued without rendering (a second render would turn the created
  reply into a 500 and invite a duplicate retry). The successful reply response is unchanged. The conversation then
  stays unassigned and visible.
- **Monitoring is log-only.** The rescue writes one static, searchable error line,
  `[umi-first-responder-claim] claim failed conversation=<id> message=<id>: <error class>`, and calls
  `ChatwootExceptionTracker`. In this deployment the tracker has no DSN, so that call is also only a log line. No
  external alert exists: a failed claim is visible only in the Rails log and as a conversation that stayed unassigned.
- The rescue also covers the claim's own after-commit callbacks (broadcasts, event dispatch). If one of those raises,
  the line is logged although the assignment committed, so read the assignee before treating a line as a lost claim.

## 4. Concurrency

- The claim runs in its own transaction: `Conversation.find(id).with_lock('FOR NO KEY UPDATE')`, re-read,
  conditional `update!`.
- It locks a freshly loaded record, not `@conversation`. Rails 7.1 `lock!` raises on unsaved changes, and autosaved
  associations could re-save the in-memory message. Either would surface only as a rescued, silent no-claim.
- `FOR NO KEY UPDATE` serialises claimants without blocking unrelated row reads.
- Two simultaneous responders serialise on the lock. The owner is whoever completes the **first successful conditional
  claim**; the second sees an assignee and leaves it. This is not a promise about which reply was created, sent or
  delivered first. Both replies are created as usual.
- The claim stays outside the message transaction for two reasons. A claim error must not roll back the reply, and the
  lock should not span message creation. (`messages.conversation_id` has no foreign key, so there is no lock-upgrade
  deadlock either way.)
- A manual **Assign to me** or assignment API call that commits first wins, because the claim re-reads under the lock.
  One that commits later overrides the claim, as any explicit human assignment should. Native assignment takes no
  lock; neither do the v2 assignment service and the UMI voice webhook, so the same holds for them.
- A lock wait is bounded by the 14 s `statement_timeout`; a cancelled wait is rescued like any claim error. A
  production `Rack::Timeout` is not a `StandardError` and is not rescued. The claim holds the lock only for one update,
  and message creation already writes the same row, so this adds no new exposure.

## 5. Effects of having an owner (same as a native Assign to me)

Message delivery and transports are unchanged. Giving a conversation an assignee does change:
- the self-assignment activity and the `ASSIGNEE_CHANGED` event;
- `ConversationReplyMailer`: widget transcript emails use `@inbox.email_address || @agent&.email` as Reply-To, so an
  inbox without an email address now shows the claimer's address;
- `reply_time` reporting, which reads `assignee_id` in an asynchronous job, so its attribution is racy;
- the UMI operator queue revision.

It also affects Shumabit consumers, to coordinate before activation:
- `crm-optional-assistance.js` gates cards on `eligible_assignee_ids`; check whether User 1 is eligible;
- `crm-operator-reminders.js` retires items on `assignment_changed`.

**Visibility.** Claiming changes no visibility for agents and administrators without a custom role: both still see
claimed conversations. A custom role limited to unassigned conversations would hide the other person's claims; the
readback checks there are none. New inbound messages stay visible while unassigned.

**Mai's conversations.** Releasing Mai's open assignments is approved and is being carried out separately with the
standard assignment API. It is not part of this change. This change never touches an existing assignment: a
conversation released to unassigned can be claimed by its next authenticated human reply, and one still owned by Mai
keeps her as owner.

## 6. Configuration and rollout

- `InstallationConfig` `UMI_FIRST_RESPONDER_CLAIM`, value `{ "inbox_ids": [...] }`, read only after the cheap checks
  pass. Absent or empty means off. Inbox scope implies the account.
- Activation (adding inbox ids) is a separate owner action after release acceptance and the §2 readback. There is no
  replay and no bulk assignment: only replies created after activation can claim. Existing assignments, Mai's included,
  are never touched.
- Rollback: remove the configuration, or deploy the previous image. Claims already made stay as normal assignments.

## 7. Implementation outline

- `umi/app/controllers/conversations/first_responder_claim.rb` (`Umi::Conversations::FirstResponderClaim`), a concern
  adding `before_action :capture_first_responder_session, only: :create`, which records the §2 provenance, and
  `after_action :claim_for_first_responder, only: :create`.
- `config/initializers/zz_umi_first_responder_claim.rb` includes it into
  `Api::V1::Accounts::Conversations::MessagesController`. It fails loud unless these still exist:
  - `create` (public);
  - `authenticate_by_access_token?` (`private_method_defined?`);
  - `Message#human_response?` (`private_method_defined?`; called through `send`);
  - `User#user_sessions`;
  - `DeviseOverrides::SessionsController#track_user_session` (`private_method_defined?`), the only writer of session
    rows;
  - `DeviseTokenAuth::Concerns::SetUserByToken#set_user_by_token`.
- Registry row 74 in `UMI-PATCHES.md`, with remove-when: native first-reply assignment with authenticated-human
  provenance, or the shared queue is no longer needed.
- No model change, migration or frontend change, and no change to `MessageBuilder`, transports or auto-assignment.

## 8. Alternatives rejected

| Alternative | Why not |
|---|---|
| Native **Assign to me** only (current interim) | Still available; needs a click, and reassigns other owners with last-writer-wins. |
| Re-enable round-robin auto-assignment | Assigns on open, not on reply; picks whoever is online, not the responder. |
| Assign by sender id in a message callback or automation rule | User 1 is also automation; sender id cannot separate them. |
| Token-free devise check only (no session row) | Also admits impersonation, server-minted and signup-response tokens. |
| Claim when delivery succeeds | Asynchronous and after the request; the authentication method is lost. |
| Conditional `update_all` | Atomic but skips native activity, events and broadcasts. |
| New token type or header for automation | Broader scope and a new API surface. |

## 9. Tests

Request specs. A browser or mobile session is produced by a real `POST /auth/sign_in`, which creates the session row;
a token request uses the `api_access_token` header. Each exclusion has a positive control among the claim tests. A
mutation run removes each predicate in turn and records which test turns red.

Red on the base (the base never claims). On `cc960dc39` the three spec files give 22 examples and 9 failures: tests
1-8 and the later-reply case of 16, which needs a first claim.
1. A signed-in session reply to an open unassigned conversation in a configured inbox → assigned to the sender.
   Exactly one activity job is enqueued ("… self-assigned this conversation"), and `SendReplyJob` exactly once.
2. Two simultaneous responders (`use_transactional_tests = false`). Both replies are created before either claim
   locks: responder B's claim is held before it takes the lock, responder A's claim takes the lock and is held inside
   it, B is released and observed in `pg_stat_activity` waiting on the `FOR NO KEY UPDATE`, then A is released.
   Assignee is A, although A's reply was created second; exactly one self-assigned activity; both replies 200.
3. Reopening: a customer message reopens a resolved unassigned conversation, then the first reply → claimed.
4. Captain-pending conversation opened by the human reply → claimed (enterprise spec).
5. Send failure: the reply later turns `failed` → the claim stays. This pins creation-time ownership against a
   future change that would react to the failure; nothing re-runs the claim.
6. The production path with the UMI funnel and customer context configured for the account → claimed.
7. A mobile-shaped sign-in (`X-Chatwoot-Client-Name` headers) and a regular SSO sign-in → claimed.
8. An injected claim error: the reply stays 200, the conversation stays unassigned, and the static log line is written.

Exclusions, green on the base except that later-reply case:

9. Access token (reply 200 and persisted): alone; with the devise headers of the same user's interactive session A
   (row asserted); with only a `client: A` header → no claim.
10. Per-client binding: a client B minted by `create_new_auth_token` on a reloaded user (no row) while session A
    exists → no claim. An impersonation SSO sign-in → no row → no claim.
11. A private note; `sender_type: AgentBot`; `sender_type: AgentBot` with `external_echo` (passes native
    `human_response?`, fails the sender check); an automation-rule message; a campaign message.
12. A create that fails (422); a reply the settlement transaction rolls back after creating it (422, no message); a
    reply committed before an after-commit step raised (422, message kept).
13. An unconfigured inbox; the configuration absent.
14. An administrator who is not an inbox member.
15. A resolved, snoozed or AgentBot-pending conversation.
16. An existing human owner or bot owner is kept, including against a later reply from the other agent.
17. A retry of the agent's own failed message (`messages#retry`).

Lifecycle checks, green under the mutation run because devise answers first: after sign-out
(`delete destroy_user_session_url`), after revoking session A from session B (`delete /api/v1/profile/sessions/:id`),
and after expiry (`travel 2.months + 1.day`), the old headers get a 401 and the conversation stays unassigned.

Fixtures:
- a sign-in is `post new_user_session_url, params: { email:, password: }, as: :json`, taking the response
  `access-token`, `client` and `uid` headers;
- SSO uses `sso_auth_token: user.generate_sso_auth_token(impersonation: true | false)`.

Mutation run: each predicate removed one at a time, every one turns its test red (file restored afterwards):
- the token check → 9;
- the session-row check → 10 (both cases);
- `only: :create` on both callbacks → 17;
- the status check → 12 (the rollback and the committed-but-422 cases);
- the sender check alone, `human_response?` alone, the whole sender/human line, the private flag → 11;
- the inbox config → 13;
- the membership check → 14;
- the open check → 15;
- the unassigned check → 16;
- the check moved before the lock (check-then-lock) → 2, with the later claimant overwriting the owner;
- the row lock replaced by a plain transaction → 2.

Regression: the messages, conversations, assignments and auto-assignment specs, the settlement-command and acknowledgement
specs, the UMI request suites, and rubocop.
