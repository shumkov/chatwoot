# Meta stage-one readiness: 30 September 2026

Read-only evidence gathered against production APIs and authenticated Meta/Shopify UI. This is a prerequisite receipt, not activation or campaign attribution acceptance. No campaign, budget, token, data-sharing setting or production code was changed. After a separate explicit confirmation, the verified company was saved as the default advertiser and payer. After explicit user confirmation, instagram_manage_events was added to an App Review request draft; submission/approval is not yet confirmed.

## Access update, 3 October 2026 Bangkok

The access observations below are the historical 30 September checkpoint.
Advanced `instagram_manage_events` is now granted. The dedicated production
funnel Page credential was rotated, and v23 accepts an Instagram technical
TestEvent using `ig_account_id`. See the [current access and transport receipt](UMI-WEBSITE-AD-MESSAGING-INVESTIGATION.md#instagram-event-transport-verification-3-october-bangkok).
Real Purchase delivery, matching Events Manager evidence and Instagram-only
optimization remain unverified; Purchase channels remain disabled. The Page
credential has a finite data-access expiry: 31 December 2026, 23:34:46 Bangkok.

## Verified assets and access

- UMI Ads account: `521070490831440`; existing messaging ad set `120252533076010415` uses `CONVERSATIONS`, destination `MESSAGING_INSTAGRAM_DIRECT_MESSENGER`, Page `516819784857962`.
- Page `516819784857962` is UMI clothing; linked Instagram account `17841468119523354`.
- App `2163627007746338` is UMI Store.
- Page `/dataset` returns `1540380063308828`.
- Production token grants `page_events`, `pages_messaging`, `ads_read`, `ads_management`, `business_management`, `instagram_basic`, `instagram_manage_messages` and `instagram_manage_comments`. It does **not** grant `instagram_manage_events`.
- Instagram `/dataset` returns HTTP403, code200: app lacks `instagram_manage_events` on the Instagram account. This is an actual access gap, not a payload bug.
- App Review UI shows `instagram_manage_messages`: Advanced access granted; `instagram_manage_events`: Standard access, ready to use, no App Review requested. Its requirements tooltip lists Business verification and App Review for advanced access. After the user confirmed, Request advanced access changed to Edit App Review request and exposed Continue request. Permission remains Standard access; submission/approval is not yet confirmed.

## Website sender ownership

Authenticated Shopify Facebook & Instagram -> Settings shows **Maximum** sharing: Meta Pixel, advanced matching and Conversions API. Dataset `1540380063308828`, displayed name `cherry.cheap's pixel`, owner UMI STORE CO., LTD. Connected Page `516819784857962` and Instagram `@umi.asia`.

This proves a native Shopify website sender is configured on the same dataset. It does not prove paid-only timing or absence of all duplicate senders. Chatwoot must not send another messaging Purchase for a website checkout merely because an invoice/draft link was shared in a chat.

Shopify Shumabit API token can read orders/drafts and all order history. Listing app installations returns ACCESS_DENIED, so the sharing configuration was verified in the existing authenticated Shopify UI. No new scopes were granted.

Official Shopify documentation describes the Purchase pixel trigger at completed checkout/thank-you page, not verified payment settlement. Outstanding: correlate a genuine manual-payment/TBYB checkout and its paid state with native Meta event evidence; establish whether correction is needed before enabling a second eligible sender. Public storefront HTML inspection did not expose a pixel ID and does not override the authenticated configuration.

Sources: [Shopify Meta pixel](https://help.shopify.com/en/manual/promoting-marketing/analyze-marketing/meta-pixel), [Shopify Meta data sharing](https://help.shopify.com/en/manual/promoting-marketing/analyze-marketing/meta-data-sharing).

## Purchase optimization eligibility

Authenticated [Meta Business Help](https://www.facebook.com/business/help/1214599109289826), including the expanded eligibility sections, explicitly describes purchase optimization for Messenger, Instagram Direct and WhatsApp:

- Messenger generally requires 10 purchases within 30 days; businesses in Thailand and Vietnam have an exception without prior purchase events.
- Instagram-only eligibility describes 10 purchases within 30 days through the professional inbox and business activity data sharing; its specified Ordered/Paid/Dispatched labels are Instagram's own labels, not Chatwoot labels. This does not establish that arbitrary CAPI events unlock the standalone Instagram goal.
- Combined Messenger+Instagram eligibility requires Messenger eligibility.

This is more specific current product guidance than the broader Blueprint announcement, and differs from the older channel limitation in the [Business Messaging CAPI guide](https://developers.facebook.com/documentation/ads-commerce/conversions-api/business-messaging.md). The combined route is a plausible Thailand route, **not yet actual-account selectable-goal evidence**.

The existing published ad set's optimization selector is disabled. Reading it confirms CONVERSATIONS only; it cannot prove available goals for a new campaign. No draft was created and no campaign settings were altered; Linh owns campaign creation.

## Remaining acceptance

1. Resolve Instagram event scope/access and read back the correct dataset using the production token.
2. Completed for combined Messenger + Instagram in Thailand: validate_only accepted MESSAGING_PURCHASE_CONVERSION after supplying the verified advertiser/payer identity. No campaign was created. Instagram-only remains unverified and is not claimed.
3. Settle explicit origin evidence for manual chat/PromptPay versus in-store and web checkout; unknown origin holds Meta Purchase while retaining the paid fact and Klaviyo event.
4. Verify native website Purchase timing for unpaid/TBYB and single-sender ownership using genuine evidence.
5. Eligible messaging Purchase mappings and their fixtures are implemented in the delivered application; the Purchase channel allowlist remains empty. Obtain separate provider receipt, dataset diagnostics, source/identity evidence and usable optimization before enabling the eligible channel. Test-event acceptance alone is insufficient.

## Observed website event diagnostics

Events Manager for 2–29 September shows Purchase active, 14 received events, both browser and server integration, match quality 4.4/10, and a high-priority warning for low browser Purchase coverage by Conversions API. The deduplication view says it is still parsing and cannot yet report deduplication. These are website diagnostics, not proof of successful messaging Purchase.

A read-only Shopify query for September returned 20 orders (pagination complete): four web PAID, one web VOIDED/TBYB, fourteen PAID and one VOIDED from numeric source 325329387521. The TBYB order 6935423320111 was created 11 September 17:29:03 UTC and has no successful payment transaction. This is a genuine unpaid candidate for native-event timing verification; no test order or payment was created. Source/gateway alone does not prove chat settlement.

## Validation-only objective probe

The official [Ad Account Ad Sets reference](https://developers.facebook.com/docs/marketing-api/reference/ad-account/adsets/) documents execution_options=[validate_only] as running validation without mutation. With that required option, a request copied the existing ad set's targeting/billing/budget, used PAUSED and MESSAGING_PURCHASE_CONVERSION with combined Instagram/Messenger destination. No ad set was created.

Meta returned HTTP 400/code 100/subcode 3858634, blame compliance_section: provide a verified advertiser for the selected locations. Trace A4qwlqKvu_qR2ikBdAGU0kp. Immediate GET of the existing ad set matched the prior read exactly, including CONVERSATIONS and updated_time 2026-08-16T22:46:40+0700. This error does not prove the purchase goal is unsupported or available; advertiser compliance must be satisfied before this probe can reach a conclusive result. No compliance identity was invented or submitted.

## Permission request draft

After explicit user confirmation, request 2325891674853203 was created for instagram_manage_events. It is **Not submitted**. Verification and App settings show 100%; Allowed usage, Data handling and Reviewer instructions remain incomplete. The intended-use description was saved. Meta requires a screencast and allowed-usage agreement; no fabricated demonstration, compliance certification or submission was made. Existing instagram_basic, Business Asset User Profile Access, pages_messaging and instagram_manage_messages appear as access for renewal. This request is not a token-scope grant and does not resolve the production 403.

Further UI readback: UMI STORE COMPANY LIMITED has one successful verification. Default advertiser/payer are both absent. The company was selected in the unsaved default dialog and the user was asked whether it should fill both roles; no settings saved pending answer. Existing ad set readback has regional_regulated_categories=[VOLUNTARY_VERIFICATION], no returned regional_regulation_identities, targeting Bangkok/Thailand only. Missing default selection and missing API identity are distinct from failed business verification.

## Confirmed advertiser/payer setting

User explicitly confirmed UMI STORE COMPANY LIMITED for both roles. Ads Manager now displays that company under both default Advertiser and Payer. This affects default selections for future ads, not existing ad sets. A subsequent API validate_only request with the existing LOWEST_COST_WITHOUT_CAP bidding strategy still returns Advertiser is missing, code100/subcode3858634, trace AvPdha0wT-s_1CrKh4qAY23. An additional validation with the officially documented THAILAND_UNIVERSAL category returned the same error, trace Avxyvq3EXdfOQJINqEk8uN2. Existing ad set readback was unchanged after each. The UI default did not supply the verified identity to these API requests; optimization eligibility remains unproved. An earlier probe omitted bid_strategy and stopped at subcode2490487; it supplied no eligibility evidence. No ad set was created.

The [official Ad Set reference](https://developers.facebook.com/docs/marketing-api/reference/ad-campaign/) requires universal_beneficiary and universal_payer verified identity IDs for THAILAND_UNIVERSAL. Those IDs must be obtained from actual verification evidence, never substituted with the business or Page ID.

## Purchase-goal configuration validation succeeded

Business Suite -> Authorisations and verifications -> Verify yourself or an organisation -> Ad accounts -> UMI Ads displays **UMI STORE COMPANY LIMITED (ID: 497970999394825), Verification successful**. This is the verified organisation ID shown by the actual account UI, not an assumed substitution.

Using that observed ID for both universal_beneficiary and universal_payer, regional_regulated_categories=[THAILAND_UNIVERSAL], the existing campaign OUTCOME_ENGAGEMENT, combined MESSAGING_INSTAGRAM_DIRECT_MESSENGER destination, page 516819784857962 and LOWEST_COST_WITHOUT_CAP, the validate_only request for MESSAGING_PURCHASE_CONVERSION returned **HTTP200, {"success":true}**. Existing ad set readback remained exactly unchanged. No new object ID was returned and no ad set was created.

This supplies actual-account configuration eligibility evidence for the combined Messenger + Instagram purchase route in Thailand. It does not prove Instagram-only eligibility, an accepted messaging purchase, correct CAPI attribution, or improved advertising performance. The earlier missing-advertiser validation blocker is resolved by explicit verified identity parameters; setting UI defaults alone did not resolve the API probe. Instagram permission and genuine event/source/identity acceptance remain outstanding.

## Own-app Standard Access investigation

The authenticated [Meta access-level documentation](https://developers.facebook.com/docs/graph-api/overview/access-levels/) says Standard Access is sufficient when all app users hold roles on the app; Advanced Access is needed for users without such roles. The production token is a valid SYSTEM_USER token issued by UMI Store app 2163627007746338; instagram_manage_events is absent. Therefore the missing token permission alone does not prove App Review is required for this own-business deployment. The app-role/asset grant and ability to issue that scope through the existing system user must be checked before treating Advanced approval as the only route.

Opening Business Suite system users triggered passkey reauthentication. The user was asked to complete that existing sign-in; no new token or permission grant was created. The existing App Review draft remains unsubmitted while the narrower own-app route is investigated.

After the user completed passkey reauthentication, Shumabit's assigned assets show UMI Store with Full access, @umi.asia with content/messages/ads access and the existing dataset with Use events dataset. UMI Store appears installed since 27 March 2026. The token-generation permission selector for that existing Shumabit/app pair has 40 existing permissions selected; searching exactly instagram_manage_events returns No matching results. The wizard was closed without generating a token, accepting terms or modifying installed permissions. Thus the UI Standard Access route did not expose the missing scope, despite the app being assigned. Advanced request remains a draft pending actual demonstration and required submission material.

## Authenticated API contract readback

On 30 September the official [Business Messaging onboarding guide](https://developers.facebook.com/documentation/ads-commerce/conversions-api/business-messaging) (page updated 5 May 2026) was readable in authenticated Chrome after the old URL redirected; the unauthenticated fetch returned HTTP429. Its Instagram Purchase example uses `user_data.instagram_business_account_id` and `user_data.ig_sid`, with `action_source=business_messaging` and `messaging_channel=instagram`. `ig_account_id` is not the documented field. The delivered implementation and fixture use these documented names; this readback proves the contract, not provider acceptance.

The same guide's FAQ still limits purchase optimization to Messenger and WhatsApp and describes conversation optimization for Instagram. This conflicts with treating the earlier Instagram `validate_only` HTTP200 as optimization eligibility: retain that response only as configuration-validation evidence. Instagram Purchase optimization remains unproven, separately from its missing token permission. No events, ads, or settings were changed by this documentation check.

## Unpaid checkout correlation (read-only follow-up)

A current Shopify REST read of order `6935423320111` confirms checkout present, source web, created 2026-09-11T17:29:03Z, manual Pay after your fitting, currently voided/cancelled. Its only payment transactions are a pending sale and a successful zero-value void; no successful sale/capture. A complete orders query for 17:00–18:00Z returned this one order and no next page. Dataset Graph v23 stats aggregation=event returns four raw Purchase counts in the same 17:00Z bucket. The broader stats response is paginated; this observation uses only the returned bucket and does not claim a complete multi-day census.

This is strong aggregate evidence of an unpaid-checkout signal risk, not an individual event/order receipt or a deduplicated conversion count. We have not established the exact sender payload/order_id or whether native deduplication handled the four raw counts. Native website paid-only acceptance remains open; no pixel/sharing setting was changed and Chatwoot must not create an overlapping Purchase.

Historical research found at the existing Shumabit source snapshot `reports/meta-research/04-pos-orders-in-meta.md` (19 August) similarly correlates checkout presence rather than source_name with Purchase activity. That document explicitly lacks outbound payloads and proof for drafts marked paid without checkout; it is context, not current provider acceptance.

## Ad-comment source coverage (bounded read-only sample)

Existing ad set `120252533076010415` returned two ads with no further page. Their effective Facebook story IDs and Instagram media IDs were available from creative metadata. Both ads have effective status CAMPAIGN_PAUSED; no ad state was changed.

- Facebook comments: the system-user token is rejected by the comments edge (190/2069032). Reading the existing Page access token via the assigned Page and using it in memory succeeds for both stories (HTTP200). One story returns one comment with created_time and no replies; the other returns none. Neither response has another page. No token or commenter content was logged or persisted.
- Instagram comments: existing system-user access succeeds for both effective media IDs (HTTP200), each returns an empty complete page. Accepted fields include timestamp/from and replies; no real reply record was present in this sample, so reply coverage is not proven.
- Scope: these are source/API availability checks on two existing ads, not account-wide historical completeness, webhook ingestion, reply SLA, or automatic reporting acceptance. Current Chatwoot DM reports do not collect public comments. Until a bounded collector is defined and verified, the current operator monitors comments in Meta Business Suite and the Friday report must state comment coverage is incomplete. No public reply was sent.

## Operational schedule and report destination — 30 September Bangkok

User confirmed daily 09:00–21:00 Asia/Bangkok and Friday report delivery to UMI group → Orders topic. Production Website inbox1 already had that enabled schedule. Facebook/Instagram inbox2 had the same seven-day hours stored but disabled; enabled only `working_hours_enabled`, then reloaded and verified unchanged timezone/hours and enabled=true (29 September 19:53 UTC). No out-of-office message is configured on inbox2. Other inbox schedules were not changed. This confirms schedule configuration, not deployment of the new operational report or its scheduled delivery.

## Klaviyo read-only contract canary — 30 September Bangkok

Working production token returned HTTP 200 for both configured segment definitions (SS6aWp/RUy6Wc) and 57 metrics using revision 2026-07-15. The candidate SegmentRefreshJob validator then checked both live definitions against its exact expected metric IDs/rules: `definitions_match`. Only GET requests; no profile writes, segment changes or new jobs. Evidence: `/tmp/u9-segment-read-canary.log`. This does not establish PATCH/unset/readback or scheduled sync activation. Candidate uses the documented `fields[segment]=name,definition`, omits unsupported metrics page-size query, and accepts terminal collections without a next link. Official contracts: https://developers.klaviyo.com/en/reference/get_segment and https://developers.klaviyo.com/en/reference/get_metrics; pagination schema https://raw.githubusercontent.com/klaviyo/openapi/main/openapi/stable/apis/get_profiles_for_segment.json.

## Native Klaviyo checkout shape inventory

A read-only full pagination of the native Shopify `Checkout Started` metric (TaQ75B) returned 415 events across three pages, with metric relationship checked on every event. UMI has no metric named `Started Checkout`. Fifty observed events carried known checkout webhook topics (3 create, 47 update); 365 omitted that topic. Property shapes vary and some historical entries contain order-like `$extra` fields. No event's `Items` contained the documented `Amount to pay for order` draft marker. This establishes absence of that marker in the accessible history, not a tested draft exclusion. No identifiers or event values were saved in this aggregate receipt. The separate native Placed Order metric is TMR9Ge.

The [official Get Events contract](https://developers.klaviyo.com/en/reference/get_events) supports metric filtering and sparse event fields. Future recovery instructions must select the actual metric name and preserve native Placed Order-since-entry exclusion. The documented draft item-name exclusion remains unverified for this account; do not claim it was tested or activate recovery flows based on an unobserved example. Service state/freshness adds a separate suppression condition, not proof of native draft behavior. No flow, profile or event was written.
