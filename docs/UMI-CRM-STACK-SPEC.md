# UMI customer stack — implementation spec

**Status:** draft v2, revised after four-lens review (feasibility · scope · failure-modes ·
fork-fit) · **Date:** 2026-08-13 · **Base:** upstream `v4.16.0`

Changes in v2 are marked **[R]**. Three decisions need a human before code — see §7.

## 1. What we decided

| Question | Decision |
|---|---|
| Is Chatwoot the CRM? | **No.** Contact storage only — no deals, no pipeline. It stays the conversation system of record. |
| Where does customer state live? | **Klaviyo.** Segments computed from Shopify. No CRM purchase, no funnel board — UMI is pure DTC, so no human owns a stage transition. |
| Campaign engine | **Klaviyo** for email; **Lumo** for LINE; **UMI's own transport** for WhatsApp. Chatwoot's built-in campaigns are unusable (§2.1). |
| WhatsApp number | Consolidate on **+66975311301** (Twilio, shared with voice). **Retire +66800053593** (Cloud API). |
| IG / Messenger broadcast | **Not possible.** Promotional content outside the 24-hour window is prohibited and message tags exclude offers/discounts — [Meta messaging policy](https://developers.facebook.com/documentation/business-messaging/messenger-platform/policy), re-check quarterly. **[R]** Cited because, unlike every code claim here, it can't be verified from the repo. |
| Signup + 10% off | **Klaviyo forms**, unique Shopify discount codes. Email field only. (Form design is a separate workstream.) |
| Loyalty | Smile.io or Rivo; events flow into Klaviyo. |
| Meta ads asks | Audiences: **no code**. Attribution: **already half-built**. Lead status: real work, gated on §3.8. |

**Ownership rule.** One writer per fact, and no fact travels in both directions. Chatwoot
sends Klaviyo events and never attributes; Klaviyo sends Chatwoot `klaviyo_*` attributes and
never identity. **[R]** Two amendments the review forced:

- **The rule extends to events, not just facts.** A private note is a fact written by
  Klaviyo *and* an event Chatwoot emits — see W5's loop guard.
- **Every writer of `additional_attributes` merges, never assigns**, and the namespace prefix
  (`shopify_*`, `klaviyo_*`, `umi_*`) is the ownership boundary.

## 2. Why the obvious shortcuts don't work

### 2.1 Chatwoot campaigns **[R] — corrected**
`Campaign#validate_campaign_inbox` accepts only Website, SMS, Twilio SMS and Whatsapp
inboxes — no email, LINE, IG or Messenger (`app/models/campaign.rb:105-109`).

The earlier draft claimed a Twilio WhatsApp inbox falls back to
`Twilio::OneoffSmsCampaignService` and fails per contact. **That is wrong, and all four
reviewers caught it.** `Channel::TwilioSms#name` returns `'Whatsapp'` when
`medium == 'whatsapp'` (`app/models/channel/twilio_sms.rb:52-56`) and `Inbox#inbox_type` is
just `channel.name` (`app/models/inbox.rb:182-184`), so `Campaign#execute_campaign` dispatches
to `Whatsapp::OneoffCampaignService` (`campaign.rb:81-90`). The SMS service raises
`"Invalid campaign"` on entry for any other inbox type and is unreachable here.

What actually happens, and why it is worse:

1. `Campaign#trigger!` returns **silently** unless the account has the `whatsapp_campaign`
   feature — no log, no status change (`campaign.rb:58-70`; off by default,
   `config/features.yml:192-194`).
2. With the flag on, `mark_processing!` flips the campaign to `processing` **before**
   `execute_campaign` runs (`campaign.rb:72-79`).
3. `validate_provider!` calls `channel.provider` (`whatsapp/oneoff_campaign_service.rb:27-29`)
   — a method `Channel::TwilioSms` does not have. `NoMethodError`, not the intended guard.
4. The campaign is stuck in `processing` forever, because `mark_processing!` short-circuits on
   `processing?`. The error retries 3× against the global cap and lands in the dead set that
   nothing watches.

### 2.2 Klaviyo owning WhatsApp
A number can be active with exactly one provider; Klaviyo becoming it takes the Chatwoot inbox
down. A second number is worse — two UMI profiles in the customer's WhatsApp reads as two
companies.

### 2.3 The identity gap **[R] — sourced**
Measured on production 2026-08-13 via `rails runner` on `umi-chatwoot-rails-1`:

| Figure | Value | Query |
|---|---|---|
| Contacts | 5,350 | `Contact.count` |
| Shopify-linked | 796 (759 with email) | `Contact.where("additional_attributes ? 'shopify_customer_id'")` |
| Meta-inbox conversations | 800, of which ~740 Instagram | inbox `Channel::FacebookPage`, IG split by `contact_inboxes.source_id` shape |
| WhatsApp / LINE conversations | 16 / 4 | per-inbox `conversations.count` |
| Phone country split | 111 `+66`, 75 foreign (45 `+7`) | `Contact.where("phone_number LIKE '+66%'")` etc. |

**These are floors, not counts.** Patch 12 records that Meta never delivered a class of
messages (the `message_echoes` gap found 2026-07-22), so any conversation-derived figure and
every channel ratio understates reality. Re-run before using them to justify new work.

The consequence stands: of the people who have messaged the Meta inbox, effectively none carry
a Shopify link, email or phone, and only six Shopify-linked contacts have ever had a
conversation. Cross-channel profiles, conversation→revenue attribution and Meta conversion
events are all blocked on W4.

## 3. Workstreams

### 3.1 W1 — Configuration (no code)
**Owner:** human, vendor UIs. **Depends on:** nothing.

1. Install the Klaviyo Shopify app; let it back-populate customers and orders.
2. Enable the Klaviyo **app embed in the published theme** — per-theme; add to the theme deploy
   checklist, since a republish silently kills every form.
3. Klaviyo → Meta Ads app: segments as custom audiences (100-profile minimum).
4. Lumo, **free tier**: connect the LINE OA, wire identity and consent sync. **Send-only** —
   do not distribute Lumo's agent app; LINE replies stay in Chatwoot. Trigger from Klaviyo,
   never Lumo's own Shopify connector.
5. Loyalty app install, Klaviyo integration on.
6. **[R]** Sync Twilio content templates for the WhatsApp inbox
   (`POST inboxes/:id/sync_templates`) — W3 cannot resolve a template until this has run.

**Verification:** a Klaviyo profile for a known customer shows order history; a test form
submission yields a unique discount code; one segment appears in Meta Ads Manager; a Lumo test
message reaches a LINE follower and its delivery event lands on the Klaviyo profile.

### 3.2 W2 — Reverse identity lookup (Chatwoot → Shopify)
**Owner:** code, `umi/` overlay. **Depends on:** nothing. **Size:** small.
**Remove-when [R]:** upstream ships bidirectional Shopify identity resolution, or patch 7 is
retired. Extends registry **row 7** rather than opening a new one — it shares the mapper, the
service and the lock.

**Problem [R] — narrowed.** The earlier draft claimed nothing links Chatwoot-side identity.
Wrong: `Umi::Shopify::PersistCustomerLink` already persists `shopify_customer_id` on an exact
email or E.164 phone match when an agent opens the Shopify sidebar
(`umi/app/controllers/shopify/persist_customer_link.rb:14-37`). What is actually missing is
narrower: it stores **only the id** (the sidebar requests `fields: 'id,email,phone'`), so no
name upgrade, no `shopify_orders_count` / `total_spent` / `tags` / consent — **and it only
fires if a human opens that panel.** W2 exists to make enrichment automatic and agent-free.

**Approach.** A `Umi::` concern included into `Contact` from `config/initializers/zz_umi_*.rb`
(the pattern patch 3 uses for `Article`; never an edit to `app/models/contact.rb`). Trigger is
**`saved_change_to_email? || saved_change_to_phone_number?`** — not presence, because unrelated
writers (`AvatarFromUrlJob`, ip-lookup) rewrite `additional_attributes` constantly and a
presence check would fire a Shopify call on every save forever.

The job fetches one customer and enriches **only the triggering contact**, reusing the existing
rules rather than reimplementing them. **[R] Matching lives in
`ContactSyncService#existing_contacts` (lowercased email, then exact phone), not in
`CustomerContactMapper`, which is pure payload→attributes with no DB access.**

**Why fork code and not n8n [R].** `contact_updated` is a webhook event, so the loop is
expressible in n8n — but the enrichment rules (fill-blanks-only, placeholder-name upgrade,
conflicted guard, `fillable_phone?`) already exist in Ruby, and reimplementing them in n8n
would create a second writer with different rules, violating §1.

**Failure modes [R] — expanded.**

- **Duplicate creation.** Feeding the fetched customer to `ContactSyncService#perform`
  re-matches on *its* keys; when the agent typed `0812345678` and Shopify holds
  `+66812345678`, the mapper drops the non-E.164 phone, the row matches nothing and falls into
  `create_contacts` — creating a duplicate. Pass the target contact explicitly, or assert the
  fetched customer's normalized email/phone equals the trigger's before handing it over.
- **Id already owned by another contact.** `enrich` guards only the inverse direction, and
  there is no unique index. Two contacts sharing a `shopify_customer_id` makes
  `customers/redact` under-delete silently — it takes `.first` and returns 200, which Shopify
  never redelivers. **A statutory deletion that reports done and isn't.** W2 must refuse when
  another contact already carries the id; separately, add a partial unique index on
  `(account_id, additional_attributes->>'shopify_customer_id')` and make the redact lookup fail
  loud on >1 (patch 17 is the precedent).
- **Phone mis-merge.** Agent-typed phones carry none of the protections the Shopify path has,
  shared phones are common in this market, there is no unique phone index and Contact has no
  audit trail. **Restrict the reverse lookup to email matches**; treat a phone-only match as
  *suggest, don't write* (a private note or `shopify_candidate_customer_id` an agent confirms).
- **Concurrency.** Patch 7's invariant is single-writer per account under
  `Umi::Shopify::SyncLock`. Taking the account lock risks starving the poll, which skips its
  entire tick when held (`LOCK_TTL` 25 min against a 30-min cron) and stalls the watermark —
  a failure patch 7's runbook calls invisible. **Preferred: a single-contact, row-locked
  enrich that neither uses the batch service nor takes the account-wide lock.**
- **Multi-match.** Bail on `customers.size > 1`. Do not reuse `#dedup`, which keeps the most
  recently updated and strips the loser's key — wrong for a single-customer lookup.
- **No match.** Stamp `shopify_lookup_missed_at`; allow exactly one delayed retry (Shopify's
  customer search index is eventually consistent), then stop.
- **API.** Verify `GET /customers/search.json` still exists at the pinned `2026-01` REST
  version; prefer the GraphQL `customers(query:)` connection. Declare the job's own `retry_on`
  against the global cap of 3.

**Tests.** Email typed → one job. Match → `shopify_*` filled, agent name untouched. Local-format
phone → **no duplicate contact**. Id owned by another contact → refused, counted conflicted.
Already linked to a different id → untouched. No match → no writes, stamp set.

### 3.3 W3 — WhatsApp broadcast
**Owner:** **[R] open — see §7 decision 1.** **Depends on:** W1.6 and W6 for production.
**Remove-when:** upstream `Whatsapp::OneoffCampaignService` supports the Twilio provider, or
UMI moves WhatsApp broadcast to a vendor.

**Mechanism (verified real by three reviewers).** An outgoing message carrying
`additional_attributes['template_params']` drives `SendReplyJob` →
`Twilio::SendOnTwilioService#send_template_message` → `TemplateProcessorService` → Twilio, with
`status_callback` set so delivery flows back normally. Sends land in the customer's real thread.

**[R] Gate before any build.** Send one approved template from the dashboard to a staff number
whose last inbound is **>24 h old**, on +66975311301, and confirm delivery plus status
callback. This costs zero code and proves the entire premise. If it fails, no loop code helps.

**[R] Corrections that change the design:**

- **The audience is not conversations.** `send_template_message` sends to
  `contact_inbox.source_id`, and contact-inboxes are created on *inbound* only — so "skip
  contacts without a contact_inbox" would target roughly nobody. The skip condition is **no
  E.164 phone**; contact-inbox creation is part of the design.
- **Never build `whatsapp:+E164` by hand.** v4.16 supports BSUID-keyed source ids
  (`Twilio::WhatsappIdentifierHelper`); string concatenation would create a duplicate
  contact-inbox and a second conversation, so the customer's reply lands in a thread nobody
  watches. Resolve through `Contacts::ContactableInboxesService#twilio_contactable_inbox`.
- **`campaign_id` and `template_params` cannot both survive `Messages::MessageBuilder`** — it
  builds each as a separate single-key hash and shallow-merges, so `template_params` replaces
  the whole `additional_attributes` and `campaign_id` is silently dropped
  (`message_builder.rb:128-156`). `campaign_id` is exactly what keeps campaign traffic out of
  agent metrics (`Message#human_response?`, `valid_first_reply?`), so without it a broadcast
  stamps `first_reply_created_at` across the entire audience, irreversibly. Build the row
  directly, or ship a prepend that deep-merges.
- **Keep broadcasts out of agent workflow.** Create broadcast conversations `resolved` (an
  inbound reply reopens them) and label them so reports can exclude them. W5.1 refuses to write
  outgoing messages for exactly this reason; W3 must not exempt itself.
- **Per-recipient idempotency.** One job per recipient keyed on `(broadcast_id, contact_id)`,
  with its own `retry_on`, skipping any contact already stamped with this `broadcast_id`.
  Two duplicate-send vectors exist: a non-Twilio exception replaying the whole run, and a crash
  between the Twilio create and the `source_id` write letting `SendReplyJob` re-send a paid
  template.
- **Template failures are silent.** `TemplateSyncService#derive_status` returns `'approved'`
  for *every* fetched template, and a miss sets `status: :failed` per message with no raise and
  no log. Pre-flight resolve the template once and refuse to start; derive the summary from
  message **status** (`sent / failed / skipped / template_not_found`), never from rows created;
  hard-abort if the first K recipients all fail.
- **Pacing.** `SendReplyJob` is `queue_as :high` — the same queue as live agent replies — and
  fires unconditionally from `after_create_commit`, so there is no throttle at send time.
  Pace at **message creation** (a self-enqueuing chain with spacing, like patch 7's backfill),
  and route broadcast sends to a lower queue.
- **Consent.** The only consent bit stored is `shopify_accepts_sms_marketing`, which is not
  WhatsApp opt-in; Meta requires channel-specific opt-in for marketing templates. Name the
  carrier (a `whatsapp_marketing_consent` attribute or label) and the opt-out path — Twilio
  STOP handling is not automatic for WhatsApp content sends, so an opt-out arrives as an
  ordinary inbound message and needs a rule.

**Tests.** Template message carries the right `template_params`. Contact without an E.164 phone
is skipped, not crashed. BSUID-keyed contact-inbox receives the broadcast in the **existing**
conversation, no second contact-inbox. A broadcast does **not** set `first_reply_created_at`.
A retried run sends to no contact twice. Template-not-found aborts the run.

### 3.4 W4 — Order ↔ conversation link
**Owner:** code, **two repos** (`chatwoot`, `umi-store-theme`) **plus a Shopify app-config
redeploy**. **Size:** the real design work. **Critical path.**
**Remove-when:** none — **keep**, like patch 2. Declared permanent, with a per-rebase re-check
of `Message`'s create-callback chain.

**Problem.** Nothing connects a conversation to the order it produced, so funnel reporting
measures six conversations, Meta CAPI has no `Purchase` to send, and campaign→revenue
attribution is impossible.

**Approach — tag outbound links, persist through checkout.**

1. **Chatwoot** — rewrite `umi.store` URLs in *outgoing* messages to carry a token.
   **[R] The rewrite must happen before the row commits** (`before_create` on `Message` via a
   `Umi::` concern, or in the builder path). `Message` enqueues `SendReplyJob` from
   `after_create_commit`, so a post-commit rewrite races the send: the customer receives the
   untagged link while the stored thread shows the tagged one — an attribution hole that looks
   correct in the UI.
2. **Storefront** — **[R]** capture is necessarily JS (Liquid cannot read arbitrary query
   params): read the param, `POST /cart/update.js` with attribute **`_cw`** (underscore-prefixed
   so Shopify hides it from the customer-facing checkout, order-status page and notification
   templates), mirror to `localStorage` with an explicit TTL, and re-apply on every add-to-cart
   so a cart clear doesn't drop it. The mirror matters because IG/Messenger in-app browsers
   routinely hand off to Safari mid-journey.
3. **Back — [R] this is new work, not reuse.** No order webhook exists anywhere in either tree;
   the only Shopify topics handled are `shop/redact` plus patch 7's two compliance topics. W4
   needs: an `orders/create` (and a decision on `orders/paid`) subscription in the
   version-controlled `umi-vps-infra/shopify/umi-chatwoot/shopify.app.toml` plus
   `shopify app deploy`; a new HMAC-verified branch in the existing prepend; and a storage
   decision, because **Chatwoot has no orders table**. Note the compliance module answers
   `head :ok` *always* by design — order webhooks are the opposite, since Shopify retries on
   non-2xx and we want that retry. Keep an `X-Shopify-Webhook-Id` claim-once guard for
   idempotency, not for dropping deliveries. The handler must no-op cheaply when no token is
   present, since it fires for every organic order.

**[R] Carrier question, answered:** a cart attribute is the only thing that flows to the order
automatically (as `note_attributes`). An order metafield is a *destination*, not a carrier.

**[R] Coverage rule — state it, don't bury it.** Only orders that pass through the storefront
cart carry the tag. Shop Pay / Apple Pay / Google Pay / PayPal dynamic-checkout buttons on the
product page, Shop-app purchases, draft orders and POS all bypass the cart entirely. See §7
decision 2.

**[R] Token design, decided rather than left open.** Signed, scoped to
`conversation_id + contact_id`, expiring (30 days), single-claim (binds to the first cart that
presents it). The webhook writes the link **only when the order's email or phone matches the
conversation's contact**; a mismatch is recorded as `attribution: unverified` and is never
emitted to Meta or Klaviyo. This degrades the forwarded-link case to "unlinked", which the
coverage rule already accepts — and it protects W8 and W5.2, which would otherwise inherit a
`Purchase` attributed to the wrong person, unrecoverably, since Contact has no audit trail.

**Rejected alternatives.** Per-conversation discount codes (heavy, distorts pricing, codes get
shared). Email/phone matching at checkout (that *is* the identity problem — circular).
"How did you hear about us?" (weak signal, hurts conversion). **[R] Not rewriting messages at
all** — a macro or canned response that inserts an already-tagged link, or per-agent links:
cheaper and touches no core path, but loses the "agent forgot" case. See §7 decision 3.

**[R] Accepted gaps.** Replies sent from Meta Business Suite or the native IG app never pass
through Chatwoot and go untagged; this fork already knows Messenger echoes are unreliable
(patch 12). Organic purchases by unidentified senders stay unlinked.

**Verification [R].** Before building the Chatwoot side, place one test order per path — cart
checkout, Shop Pay accelerated from PDP, and an in-app-browser session opened from an IG DM
link — and assert `note_attributes` on each. Add a canary afterwards: a scheduled check that at
least one order in the last N days carried the attribute, because a theme republish drops the
snippet exactly as it drops the Klaviyo embed, and the symptom is silence.

### 3.5 W5 — n8n workflows
**Owner:** n8n on umi-vps. **Depends on:** W1; workflow 2 also on W4.

1. **Klaviyo → Chatwoot attributes** (first — works today for the 796 identified customers):
   flow webhook → `klaviyo_*` contact attributes, plus a private note on the open conversation
   for LINE and WhatsApp sends. Never an outgoing message.
2. **Chatwoot → Klaviyo events**: conversation events as Klaviyo custom events.
   **[R] Identifier policy, decided:** emit only for contacts with an **email** — the only
   identifier Klaviyo bills and can act on, given it owns neither WhatsApp nor LINE — and
   always pass `external_id: shopify_customer_id` when known, so phone-first and email-first
   profiles converge instead of double-billing. Filter unidentified contacts before the API
   call.
3. **Chatwoot → Klaviyo profile sync**: low value until W4; deferred.

**[R] Loop guard.** Private notes **do** fire `message_created` webhooks — `webhook_sendable?`
is `incoming? || outgoing? || template?` with no privacy check; the private-note exclusion
lives in the *send* path, not the webhook path. So workflow 1's note would emit an event that
workflow 2 forwards to Klaviyo, re-triggering the flow that wrote the note. Workflow 1 stamps
its notes (`content_attributes.umi_klaviyo`); workflow 2 drops any message that is `private` or
carries that stamp, and counts the drop.

### 3.6 W6 — Retire +66800053593
**Owner:** human + ops. **Blocks:** W3 in production.

1. Sweep external references: click-to-WhatsApp ads (a live ad routing to a dead number fails
   silently and burns budget), Google Business, packaging, invoices.
2. Deregister on the Meta side.
3. **Do not delete the Chatwoot inbox** — `Inbox has_many :conversations, dependent:
   :destroy_async`, so deletion destroys its 13 conversations and their messages. Leave it in
   place, receiving nothing.
4. **[R]** Do not "normalize" either inbox's `phone_number`: the WhatsApp inbox stores
   `whatsapp:+66975311301` and the voice inbox the bare `+66975311301`; both satisfy the unique
   index and `send_message_from` returns the raw string. Removing the prefix breaks sends.

### 3.7 W7 — Label taxonomy execution
**Owner:** human, Chatwoot admin. **Size:** ~1 hour.
**[R]** The label-taxonomy spec lives on branch `investigate/label-taxonomy`
(`docs/UMI-LABEL-TAXONOMY-SPEC.md`) and must be landed on `umi` before this is actionable.
Actions: delete the rule "Auto: tag new conversations as New Lead"; delete the 25 unused
labels; create `recruitment`; create the two automation rules; set `ref=hiring` on hiring ads;
verify an ad id appears in the sidebar after a real click. The `lead-*` funnel stays retired.

### 3.8 W8 — Meta conversion events
**Owner:** code. **Depends on:** W4 and Instagram verification. **Do not scope until verified.**

~740 of 800 Meta-inbox conversations are Instagram. Business-messaging CAPI must support the
Instagram *surface* — the account being connected is necessary but not sufficient. Send one
test event for the Instagram surface in Events Manager and confirm acceptance before
estimating. The *Conversions API for CRM integration* (Conversion Leads goal) is Lead-Ads-only
and does not apply.

## 4. Sequencing

```
W1 config ──┬─> W5.1 Klaviyo→Chatwoot attributes   ← first payoff, no W4 dependency
            └─> audiences, forms, loyalty live
W7 labels          ── independent (after landing the taxonomy spec on umi)
W6 retire number   ──> W3 WhatsApp broadcast (production)
W2 reverse lookup  ── independent
W4 order link ─────┬─> W5.2 Chatwoot→Klaviyo events
                   └─> W8 Meta CAPI (if IG verified)
```

**[R] First two weeks: W1 → W5.1 → W7 → W6.** Critical path is W4; everything measuring
revenue depends on it.

## 5. Conventions and production constraints

Per `CONTRIBUTING-UMI.md`: idempotent `zz_umi_*.rb` initializers over core edits; UMI code in
`umi/app/**` under `Umi::`; one patch = one `UMI:`-prefixed commit; a registry row with a
remove-when for each. Glue that can live in n8n does not go in the fork. **[R] Next free patch
number is 18.** Registry rows for W2/W3/W4 reference `docs/UMI-CRM-STACK-SPEC.md`.

Production: global Sidekiq `max_retries` is 3, so chains declare their own `retry_on`;
`Rails.cache` is a per-container FileStore, so cross-container locks use Redis as
`Umi::Shopify::SyncLock` does.

**[R] Observability — name the reader.** "Emit a summary line" is not a control: patch 7's
rollout already recorded that with `SENTRY_DSN` empty every reported path degrades to a
container log nobody greps. Each new run (the W2 job, each W3 broadcast, each n8n workflow)
writes a heartbeat consumed by the **Ansible-managed netdata filecheck dead-man's-switch** on
umi-vps, alerting on *absence*. "Heartbeat wired" is part of each workstream's verification, not
a convention paragraph. If that is out of scope, delete the claim rather than assert a property
the deployment lacks.

## 6. Fork surface and rebase risk **[R]**

| Workstream | Mechanism | Rebase risk |
|---|---|---|
| W2 | initializer + `Umi::` concern on `Contact`, reusing patch 7 | Low — no core files |
| W3 (standalone service) | pure `umi/` | Low on conflicts, but depends on two upstream privates — `send_template_message` and the `template_params` contract. Pin both with specs |
| W3 (prepend on campaign service) | initializer prepend | Low-medium — campaigns are actively changing upstream; and the dashboard UI won't offer a `Channel::TwilioSms` inbox in the campaign picker, so campaigns would be created via API/rake/n8n |
| W4 Chatwoot side | concern on `Message` create path | **Highest in the stack** — hot upstream code, permanent patch. Treat like patch 2 |
| W4 Shopify side | new webhook topic + storage | Medium; a migration touches `db/schema.rb`, which conflicts on rebase |

## 7. Decisions needed before code **[R]**

1. **Where does W3 live?** (a) n8n workflow — the entire send path is reachable over the public
   API, including creating a conversation with an inline message, and n8n does pacing, opt-out
   filtering and retry natively; (b) a `Umi::` service in the fork; (c) a prepend on upstream's
   `Whatsapp::OneoffCampaignService`, which already implements audience-by-label, a
   duplicate-send lock and cron pickup — but whose UI won't show a Twilio inbox, and which
   creates no `Message` row, so the prepend must replace the send path too, not just the
   provider guard. **Recommendation: (a)**, per the fork's own "glue does not go in the fork"
   rule, with the deep-merge problem handled by posting a pre-built message payload.
2. **Accelerated checkouts.** Accept the coverage gap, or disable dynamic checkout buttons on
   product pages? Disabling costs conversion; accepting means a share of orders can never be
   attributed. Size it with the three test orders first.
3. **W4's rewrite mechanism.** Automatic rewrite on every outgoing message (permanent, highest
   blast radius, catches everything) versus a macro/canned tagged link (no core patch, agent
   opt-in, loses the "agent forgot" case).

## 8. Review provenance **[R]**

v2 folds in four independent reviews (feasibility, scope, failure-modes, fork-fit), each of
which verified the spec's code claims against the files. Two claims were wrong in v1 and are
corrected here: the Chatwoot-campaign failure chain (§2.1) and "the existing Shopify webhook
path" (§3.4). Reviews are retained in the session scratchpad.

## 9. LINE — what shipped, and the handoff to the subscription popup

Two patches were built after v2 and are the reason the popup can do more than collect an email.
**Read this before building the signup form**; the form has a hard dependency on the second one.

### 9.1 What shipped

| Patch | Branch | What it does |
|---|---|---|
| **18 — LINE dual consumer** | merged to `umi` (`065bf6256`) | Chatwoot forwards validated LINE webhook events to a second consumer, so a vendor (Lumo or similar) can be added **without** taking the single LINE webhook URL away from Chatwoot. Off unless three env vars are set; scoped to channel `2010611374`. |
| **LINE identity binding** | `feat/line-identity-binding` (`c7d90e8cb`) | `/line-connect?token=…` serves a LIFF page that obtains the visitor's LINE `userId` and writes `line_user_id` onto the Klaviyo profile the token identifies. Ships the storefront snippet and a rollout runbook. |

Why this matters commercially: together they make a paid LINE↔Klaviyo connector **optional
rather than necessary** — UMI owns both the fan-out and the identity binding.

### 9.2 The constraint that forced this design

LINE permits **exactly one webhook URL per channel**, and every vendor evaluated wants it. None
offers self-service module-channel attachment. Chatwoot must keep that URL, so anything else
that needs LINE events has to be fed by Chatwoot — which is what patch 18 does.

### 9.3 What the popup must do

**[Revised 2026-08-17 — the popup now collects WhatsApp and LINE subscriptions, not just email.]**

**Step 1 — email (required) plus phone with its own WhatsApp opt-in (optional).** Issue the
personalised discount code here.

The asymmetry to understand before designing the form: **WhatsApp can be a form field; LINE
cannot.** A phone number is typeable, so a phone input plus a consent checkbox is a legitimate
WhatsApp opt-in. LINE has no equivalent — there is no LINE identifier a customer can type, so it
needs the follow plus the binding in step 2.

The WhatsApp consent must be **its own checkbox**, never bundled with the email one:

- Meta requires explicit, channel-specific opt-in before a marketing template may be sent;
- PDPA requires specific rather than bundled consent;
- and Klaviyo's native consent does not cover this channel at all (see Consent below).

Phone numbers must be stored E.164. The Shopify sync deliberately refuses to guess Thai local
formats into `+66…` because a wrong guess poisons caller-ID matching — the form should normalise
at entry rather than leaving that to a downstream guess.

**Step 2 — the LINE invite, personalised.**

- The button (mobile) and the **QR (desktop)** must both point at
  `/line-connect?token=<signed token>` — **not** at a generic add-friend link. A generic QR
  produces a follow with no identity, which is the whole problem this was built to solve.
- The token is minted from the email captured client-side. The storefront snippet
  (`docs/UMI-LINE-IDENTITY-BINDING-STOREFRONT-SNIPPET.js` on the binding branch, with
  instructions alongside) hooks Klaviyo's client-side form-submit event, mints the token and
  rewrites the href and QR. It belongs in `umi-store-theme`.
- The same URL goes in the **welcome email**, for everyone who skips step 2. One
  implementation, two entry points.

**Consent — the trap that makes this dangerous rather than merely fiddly.** Klaviyo's native
consent covers email, SMS, push and *Klaviyo-sent* WhatsApp. UMI's WhatsApp is sent through its
own Twilio number, and LINE through Lumo or a UMI service — **neither is a Klaviyo channel**. So:

| Channel | Consent lives in | Enforced by |
|---|---|---|
| Email | Klaviyo native | Klaviyo |
| WhatsApp | `whatsapp_marketing_consent` property | **the send path — us** |
| LINE | `line_marketing_consent` property | **the send path — us** |

**Unsubscribing from email will not stop a WhatsApp or LINE send.** Nothing in Klaviyo enforces
those two; every sender we build must check the property itself before dispatch, and must honour
an opt-out arriving as an ordinary inbound message (Twilio's STOP handling does not apply to
WhatsApp content sends). Treat a missing consent property as *no consent*, never as unknown.

Each channel needs its own explicit, unbundled consent under PDPA. Legal copy is a human
decision; do not invent it.

**Consequence for sequencing.** Collecting WhatsApp opt-ins creates an obligation to be able to
send to them, which promotes two items that were previously "later":

- the **WhatsApp broadcast service** — an opt-in list you cannot send to is worse than no list;
- the **number consolidation** onto +66975311301 — opt-ins should be collected for the surviving
  identity, not migrated afterwards.

**Trust boundary, recorded deliberately.** A client-side email event does not prove mailbox
ownership, so someone could bind their LINE account to a profile whose email they know. This was
accepted knowingly: the asset is "which LINE account gets our marketing", not authentication.
The mitigation, if it is ever wanted, is to treat popup-created bindings as unconfirmed and
require a welcome-email click before sending personalised content.

### 9.4 Prerequisites that will silently waste the work if skipped

1. **The LINE Login channel must be created under the same provider as the Messaging API
   channel** (`2010611374`). Otherwise `liff.getProfile().userId` will not match the `userId` in
   webhooks, and every binding collected is worthless. Verify by comparing the first real
   webhook's `source.userId` against what LIFF returned for the same person.
2. **The Klaviyo app embed is per-theme.** A theme republish silently disables every form and
   all onsite tracking — and would disable the step-2 snippet with it. Put it on the theme
   deploy checklist.
3. **฿888 OA verification.** Since 2026-04, LINE Thailand shows a fraud warning before users add
   an unverified Official Account — appearing at exactly the moment step 2 asks for trust. Verify
   before any follower push.

### 9.5 Discount mechanics for step 1

Personalised codes with a **relative** expiry ("14 days from issue"), never a fixed date — a
fixed date kills the entire pre-generated batch at once and hands late subscribers dead codes.
Merge the actual date into the email and the success screen. Give the **static fallback code an
expiry too** and check on it; an unexpiring fallback is what ends up on coupon sites. Restrict
usage to one per customer, first-time customers only. The welcome flow is two messages: the code
immediately, then a reminder ~48 h before expiry to anyone who has not ordered — that second
message is usually where the revenue is.
