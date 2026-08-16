# UMI Meta ad attribution diagnosis

Status: diagnosis only. No production, Meta, VPS, or repository code was changed.

## Conclusion

The original premise that `umi` lacked attribution is false because the local
`umi` ref was stale. After `git fetch origin umi`, `origin/umi` was at
`d70c0f1a22ea3295e3126daffd6663e9a2183f01`; its release tag
`umi-v4.16.0-3` points to `34504c886d692d2fc60bb8ff7212cfc6d02d672d`. Patch 20
and the `messaging_referrals` subscription are ancestors of that release.

Production is running the immutable `umi-v4.16.0-3` image, not the stale local
checkout's `umi` ref. The current 4% is therefore not evidence that the builder
is missing. It is the observed share of the inbox cohort for which Meta sent an
ad referral that the live builder could promote. The data also shows that the
33 values came through the deployed referral path, not from a mystery writer.

## Evidence

### Deployed code and timing

Read-only inspection of both `umi-chatwoot-rails-1` and
`umi-chatwoot-sidekiq-1` showed:

- image: `ghcr.io/shumkov/chatwoot:umi-v4.16.0-3`
- image/container digest: `sha256:148cf8954b2101132abdf8c5377d51d9009c7797f87ccad01a2fc6bf4ad15f56`
- image created: `2026-08-16T04:46:11Z` (11:46:11 Bangkok)
- attribution builder present at `umi/app/builders/fbig_ad_attribution.rb`
- attribution initializer present at `config/initializers/zz_umi_fbig_ad_attribution.rb`
- attribution spec absent, as expected for a production image
- no embedded Git revision or `.git` directory was present

The deployed builder SHA256 is
`e01a442d319108d5781d75bf43167d0fc6d9d677a061a27c232fe3bc46a264de`; it
matches the builder at the fetched `origin/umi` release ancestry. The deployed
initializer SHA256 is
`96853d172e0ee575ffc8edc0077344b795eede4d2b7b5fdafba997e83cfe7e3a`.

The retained release sequence is consistent with the code being deployed
before the current image was built:

| Release image | Built (Bangkok) | Relevant ancestry |
|---|---:|---|
| `umi-v4.16.0-1` | 2026-08-12 02:29 | initial Meta attribution capture |
| `umi-v4.16.0-2` | 2026-08-13 11:19 | attribution telemetry and `messaging_referrals` subscription |
| `umi-v4.16.0-3` | 2026-08-16 11:46 | current production image |

The capture, hardening, telemetry, and subscription commits landed on August
11–12, before the current image and before the first raw referral found below.

### Meta subscription

The required read-only Graph API GET was executed inside the Rails container,
using the stored page token only in the container and never printing it. The
single Facebook Page channel returned HTTP 200 with:

`message_deliveries,message_echoes,message_reads,messages,messaging_handovers,messaging_referrals,standby`

Meta documents `messaging_referrals` as the webhook notification for a customer
resuming a Page conversation through an `ig.me`/`m.me` link or an ad:

<https://developers.facebook.com/docs/messenger-platform/reference/webhook-events/messaging_referrals/>

### Production cohort and platform split

The read-only Rails aggregate query reproduced the supplied measurement:

- Meta inbox conversations: **841**
- conversations with `custom_attributes.meta_ad_id`: **33 (3.92%)**
- distinct ad IDs: **5**
- attributed conversation creation range: **2026-06-07 → 2026-08-16**

The 33 are not all one platform. Their first incoming message source-ID
formats split as **21 Instagram** (`aWdf…`) and **12 Messenger** (`m_…`). The
same 33 cross-tabbed against `contact_inboxes.source_id` length as follows:

| Platform | Contact-inbox source-ID lengths | Count |
|---|---:|---:|
| Instagram | 15, 16, 17 digits | 1, 19, 1 |
| Messenger | 17 digits | 0, 0, 12 |

This rules out “all captured values are coming from the Instagram path” as the
explanation. Messenger attribution is demonstrably working after the field was
subscribed.

### Why June-created conversations contain August referrals

All 33 attributed conversations have a raw `message.content_attributes.referral`
payload. The raw referral payloads first appear on **2026-08-12 18:00:46Z**
(2026-08-13 01:00:46 Bangkok) and run through the measurement time on August
16. Only 24 of the 33 have the raw referral on the first incoming message in
the Chatwoot conversation.

The June 7 date is therefore the conversation's creation date, not the date on
which Meta supplied the referral. The live builder can promote a referral from
a later inbound event into the existing Chatwoot conversation. That explains
the old conversation dates without implying historical replay or a separate
writer.

## The honest ceiling

Meta referrals are not a property of every Meta conversation. They require a
click-to-message entry point, and the referral is delivered with the relevant
initial/resume event. Organic DMs and returning senders do not acquire an ad
referral merely because they are in the same inbox.

As a database-derived upper bound, **804 of 841 (95.6%)** were the first-ever
conversation for the contact. The other 37 already had an earlier conversation
and cannot be expected to carry a first-click referral under this campaign
model. Even 804 is only a ceiling: it includes organic first-time DMs and any
other non-ad entry points. The actual attributable denominator must come from
Meta's campaign delivery/click data, not from the Chatwoot inbox total.

The 33/841 value is thus an observed attribution rate, not a promise that the
whole inbox should be attributed. It is also not enough to judge the SMM
campaign specifically; that requires a campaign-scoped cohort of new test
clicks and their webhook outcomes.

## Diagnosis and next verification

There is no code gap to propose. The deployed builder reads the nested
`message.referral`, stores the raw object, promotes only `source == ADS`, and
logs both referral promotion and referral absence/failure. The Page is already
subscribed to `messaging_referrals`. No port, deploy, Meta mutation, or code
change is warranted by this diagnosis.

For a human verification of the SMM campaign, use a test account that has never
opened that Page's Messenger/Instagram thread, click the real ad, send the
first message, and verify both the raw referral and `meta_ad_id` on the newly
created/updated conversation. Check the Rails log for the corresponding
`[UMI-FBIG] stage=referral_promoted` line. Repeat separately for a Messenger
placement and an Instagram placement; do not use an existing conversation as
the test denominator.

Historical conversations cannot be back-attributed from Chatwoot after the
fact. Meta does not replay a referral that was never delivered. An old Chatwoot
conversation may receive attribution when a later live ad-resume event carries
the referral, as the 33-row evidence shows; that is live-event enrichment, not
historical reconstruction.

## Post-diagnosis measurement (2026-08-16, orchestrator)

Cohort-corrected rate, which is the number that matters:

| Cohort | Conversations | Attributed | Rate |
|---|---:|---:|---:|
| All time | 841 | 33 | 3.9% |
| Created since attribution went live (2026-08-12 18:00 UTC) | 44 | 32 | **72.7%** |

Attributed conversations by creation day: 2026-06-07 ×1 (an older thread enriched by a later
ad-resume event), then 08-12 ×7, 08-13 ×18, 08-14 ×4, 08-15 ×1, 08-16 ×2.

The headline "4%" was a denominator artefact — four days of attribution measured against
seventeen months of conversations. No code change is warranted.
