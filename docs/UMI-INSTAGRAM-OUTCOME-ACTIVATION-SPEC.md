# Instagram qualification and purchase activation

4 October 2026. Narrow correction to the stage-one delivery contract.

## Goal and current authority

The user requests automatic lead classification followed by Meta conversion
feedback for Instagram now, with the first real purchase verified when it
occurs. This supersedes the earlier requirement to wait for a paid-in-chat
acceptance candidate before enabling the purchase channel. It does not authorize
invented purchases, changing campaign settings or replaying historical events.

Production auto-classification and Meta destination dispatch are already enabled.
The deployed qualification adapter nevertheless rejects every non-Messenger
event. Instagram Purchase is implemented, but its channel configuration is empty.
This is a real missing Instagram feedback path, not merely missing launch proof.

## Research and choice

The current [Meta Business Messaging guide](https://developers.facebook.com/documentation/ads-commerce/conversions-api/business-messaging)
lists QualifiedLead, LeadSubmitted and Purchase among supported messaging events.
Its FAQ says Instagram advertising optimization is unavailable beyond
conversations. An earlier real-account validate-only request nevertheless
accepted Instagram's purchase goal. This contradiction remains unresolved:
neither ingestion nor validation establishes selectable goals, campaign launch,
attribution or learning performance. The authenticated
[Meta purchase optimization help](https://www.facebook.com/business/help/1214599109289826)
does list Instagram Direct; its expanded Instagram eligibility section requires
at least ten purchases shared in thirty days through the Instagram professional
inbox, with business-activity sharing and predefined purchase labels. That
specific route does not establish eligibility from UMI's CAPI events alone.

The guide's example uses instagram_business_account_id, but the actual UMI Graph
v23 endpoint rejected that key and accepted ig_account_id (see
[release 25 evidence](UMI-META-RELEASE25-ACCEPTANCE.md)). Preserve that empirically
verified key and ig_sid. Do not change the working purchase mapping to the stale
example. Retain the existing Meta client, delivery ledger and scheduler.

Alternative: continue Messenger-only, or send a website/custom event for IG
qualification. The former fails the user's IG scope; the latter misstates the
event source. A new service, permissions system or generalized event framework
is unnecessary. LeadSubmitted is not added merely because the API supports it:
we have a reviewed qualified-lead business definition, not a separate submission
milestone. Arbitrary CRM labels are not individual conversion events.

## Interface and data flow

1. Existing full-history classifier records a genuine conversation_qualified
   milestone from eligible fresh incoming evidence. Existing operator correction,
   once-per-conversation and historical-exclusion rules remain in effect.
2. The existing Meta delivery adapter accepts messenger and instagram for this
   milestone. Messenger payload stays unchanged. Instagram sends QualifiedLead,
   business_messaging, instagram, and user_data ig_account_id + ig_sid, matching
   the configured Instagram asset to the event's frozen instagram_id.
3. The same unique delivery row handles the one external attempt. Mismatched
   channel identity, old events, redacted sources and corrected qualifications
   remain excluded; rejected or uncertain attempts are not automatically replayed.
4. Enable Instagram purchases through the existing infra-owned channel list.
   Existing verified payment, order-to-conversation link and /paid-in-chat
   settlement evidence remain required. Website checkout and unknown-origin
   purchases remain outside this messaging sender. Messenger Purchase stays off.
5. Inspect previously excluded Instagram qualification rows. A bounded one-time
   recovery may return only never-attempted channel_not_enabled rows with empty
   payload/destination to pending after confirming current nonhistorical,
   unredacted, uncorrected qualification and the original seven-day/source bounds.
   Recheck all predicates under locks, including attempted_at being null.
   Use the same event and delivery IDs; do not fabricate a new timestamp/outcome.
   Do not change attempted, historical, expired or otherwise excluded deliveries.

No database migration, AI model change, new classification, public customer
message, ad creation or marketing-flow activation belongs to this patch.

## Failure handling and rollout

Reuse existing pending/excluded/accepted/rejected/unknown state handling. A
provider refusal must stay visible and cannot be reported as working feedback.
Existing local deduplication is not a claim that Meta deduplicates messages.

Deploy the reviewed image through the canonical umi-vps-infra owner, with
Instagram Purchase enabled and existing Meta dispatch enabled. Record exact
image/config readback and resulting delivery states. Check a genuine eligible
qualification now if one exists; inspect provider response and Events Manager.
The first real chat purchase is an operational follow-up, not an activation gate.
Do not claim selectable qualification optimization or campaign improvement from
HTTP acceptance; record current channel/goal limitations separately for Linh.

Rollback restores the prior image and purchase-channel configuration together
through the canonical infra owner and graceful worker drain. Preserve every
delivery state and receipt: disabling exports or rolling back an image cannot
undo an external send. Previous deployment scripts that require byte-identical
ENV need to accept exactly this intended configuration delta, not arbitrary drift.

## Verification

- RED then GREEN: valid Instagram qualification must prepare and dispatch instead
  of channel_not_enabled, with exact Instagram identity and original event time.
- Preserve Messenger mapping; unsupported channels and mismatched IG assets
  must not send. Existing age, redaction, corrected qualification, concurrent
  dispatch and ambiguous-result tests remain green.
- Run delivery, automation, transition and settlement specs and focused lint.
- Independently review spec and actual diff. Full CI before merge and release.
- Infra render/config checks plus live Rails/Sidekiq image and flag readback.
- Recover only audited never-attempted IG rows, observe one automatic dispatch
  where eligible, and record provider receipt separately from advertising use.
- Correct operator/acceptance wording: public IG comments are a proposed manual
  responsibility, not a workflow proven to be in use by Mai. Current ad scope is IG.
