# Messages associated with website-purchase ads

Investigation and authorized access setup, 2–3 October 2026 Bangkok. Campaigns,
budgets, subscriptions and customer messages were unchanged. The dedicated funnel
credential was rotated and a nonmonetary Instagram TestEvent was accepted; no
Purchase or QualifiedLead was sent during this access check.

## What is established

A current UMI sales campaign optimized for website purchases reports Instagram
messaging outcomes. Its two conversation starts split into one view-attributed
result and one click-attributed result. The one-day and seven-day click windows
overlap; adding them would double count. These metrics do not identify people
or prove that both conversations began through a message button in the ad.

The queried creative and standard Instagram feed preview show a website
`SHOP_NOW` destination. Neither establishes whether a messaging add-on appears
inside the post-click browser. An omitted API field does not mean the add-on is
disabled; the later authenticated UI check below resolves the current setting.

The existing Chrome Ads Manager tab was also inspected. It remained blank after
one reload, so no browser add-on setting or selected messaging destination could
be read. No login, setting change or contact action was attempted.

### Later live verification on 2 October

A fresh Chrome tab loaded the exact active ad `120253234494870415`,
`Carousel_1 without price`, in campaign `120253233055410415`. Its editor shows
Destination → Personalised destinations **0/3**. Opening that dialog and selecting
Browser add-ons shows the switch **Off**; Shop and Product browsing are also Off.
There is no active messaging channel for this disabled add-on. No control was
changed and nothing was saved or published. This supersedes the earlier browser
blocker and does not support the hypothesis that this ad currently enables an
Instagram Direct browser add-on. It does not establish its setting at an earlier
message's timestamp or the configuration of the other four ads.

The final-card destination preview opens `https://umi.store/collections/flow`.
After leaving the browser's existing Shopify theme-preview session, the published
desktop site shows the Cotton Flow hero and sale products. Its Assistance button
opens the Chatwoot FAQ, web chat and WhatsApp, LINE, Messenger and Instagram links.
The Instagram link is the plain `https://ig.me/m/umi.asia`, with no ad ID in that
link. This is a website contact path, not the disabled Meta browser add-on.
Individual carousel cards may have their own product destinations. This check
does not reproduce a real mobile Instagram in-app click or identify which path
produced the historical messaging outcomes.

The same session also confirmed `instagram_manage_events` **Advanced access
granted**, Ready to use (0), in UMI Store's Permissions and Features. Production
`debug_token` checks at 13:31:12 UTC still show that permission absent from both
the valid configured system-user token and the valid inbox-2 Page token. App
approval is now established; token authorization and a genuine eligible event
remain separate acceptance steps. A fresh Instagram dataset GET at 13:37:10 UTC
still returns HTTP 403/code 200 for missing `instagram_manage_events`.
After the owner completed two-factor reauthentication, the existing Shumabit
system user and its UMI Store assignment were verified. The token wizard still
returns "No matching results" for `instagram_manage_events`; it was closed
without issuing a token. Graph API Explorer for UMI Store does offer that scope
in its User Token authorization flow. The owner completed that consent. A
refreshed user token with `instagram_basic` and `instagram_manage_events`
returned dataset `1540380063308828` from the v26.0 Instagram dataset GET, matching
the existing Shopify dataset. `me/permissions` independently reports both scopes
as granted. The earlier user token without `instagram_basic` returned code
100/subcode 33; the successful read followed adding that scope.

This proves authorized dataset access, not event ingestion or advertising
optimization. The Explorer token is not a replacement for the broader production
system-user credential. Two distinct API issuance attempts failed: the existing
scope set plus `instagram_manage_events` on v23.0 at 15:27:18 UTC, then a bounded
six-scope funnel candidate on v26.0 at 15:39:06 UTC. Both returned HTTP 500/code 2;
neither returned a token or wrote a candidate file. Provider-side issuance is
unknown. Further system-token issuance attempts are stopped; production
credentials remain unchanged at that checkpoint.

After the owner confirmed the Page permission request, a server-side exchange
and exact UMI Page token derivation succeeded at 16:40:56 UTC. The candidate is a
valid PAGE token for app `2163627007746338`, Page `516819784857962`, with both
`page_events` and `instagram_manage_events`. Instagram and Messenger dataset
reads both return `1540380063308828`, verified on v26.0 and independently on the
application's v23.0. `expires_at` is zero, but `data_access_expires_at` is
**31 December 2026, 16:34:46 UTC (23:34:46 Bangkok)**; access renewal remains
required. The infra owner activated only the dedicated funnel credential in
Rails and Sidekiq at 16:54:01 UTC, retaining release 24. Both runtime tokens pass
v23 validation and both dataset reads; public health returns 200. Inbox tokens,
sibling services and export gates were preserved. Receipts:
`meta-approved-scope-system-user-ui-check.json`,
`meta-instagram-authorized-dataset-read-20261002.json` and
`meta-instagram-limited-system-candidate-20261002.json` and
`meta-page-token-candidate-verified-20261002.json`.

## Instagram event transport verification, 3 October Bangkok

At 17:00:46 UTC on 2 October, Graph v23 accepted the nonmonetary Instagram
`TestEvent` `umi-technical-instagram-fieldcheck-20261002T170021Z`:
HTTP 200, `events_received: 1`, `messages: []`, trace `AGlIXeOAKHdgq-xj_Rs9xhh`.
It used Events Manager test code `TEST98219`, its synthetic `ig_sid: "0"`, and
`user_data.ig_account_id: "17841468119523354"`. No order, value or currency was
supplied. The preceding request using `instagram_business_account_id` was
rejected with HTTP 400/code 100/subcode 2804079, explicitly requiring
`ig_account_id`. The same configured account ID was accepted after changing the
field name; no new account-ID mapping is needed.

This pins a one-field correction in the Purchase payload builder. A focused
regression must fail on the old field and pass on `ig_account_id`; Messenger
identity and channel/source/payment gates remain unchanged. Release 24 still
contains the old field until the corrected application release is deployed.

API acceptance proves test-event transport. The Events Manager UI has not yet
shown a matching event record. It does not establish a real Purchase, attribution
or Instagram-only purchase optimization. Combined Messenger/Instagram purchase
optimization had already passed `validation_only`; that earlier result remains
separate. `UMI_FUNNEL_META_PURCHASE_CHANNELS` stays empty pending eligible paid
source evidence and provider acceptance, without duplicating Shopify website
conversions.

Private receipts in the historical-audit artifact directory:
`meta-token-rotation/accepted.json`, `meta-token-rotation/final-check.json`,
`meta-ig-rejected-test-diagnostic-receipt-20261002.json`, and
`meta-ig-fieldcheck-receipt-20261002.json`. Credential values are excluded.

## What our existing capture covers

The current [Meta Instagram webhook examples](https://developers.facebook.com/documentation/instagram-platform/webhooks/examples?locale=en_US)
place an advertising referral inside `messaging[].message.referral`, with
`source: ADS`, `ad_id` and `type: OPEN_THREAD`. The existing UMI builder reads
that shape, preserves it on the message, promotes valid incoming evidence to
conversation ad fields and supplies the ad-context private-note workflow. It
does not exclude a referral because the campaign targets website purchases.

The deployed builder and handlers match the reviewed source. The unchanged
production-shaped nested-referral regression suite passed 17 examples, with
zero failures or pending/skipped examples. This verifies the documented payload
path locally; it does not prove that every website messaging surface supplies it.

Source entry points:

- `umi/app/builders/fbig_ad_attribution.rb` — referral persistence and promotion.
- `config/initializers/facebook_messenger.rb` — Facebook event handlers.
- `app/jobs/webhooks/instagram_events_job.rb` — Instagram event dispatch.
- `spec/builders/umi/fbig_ad_attribution_spec.rb` — covered message shapes.

The official examples also describe a standalone Instagram referral for ig.me
links. Our handlers do not process standalone referral/postback events. That is
a separate coverage limitation; the available evidence does not establish it as
the route used by the alleged website add-on, or as the cause of missing data.
The Page subscription already includes `messaging_referrals`; subscription alone
is not proof that every event shape is handled.

## What remains unknown

The seven retained public incoming FB/IG messages inspected from Bangkok midnight
to 17:41 on 2 October had no retained referral objects.
Current container logs begin after the interval in question, so the original
payloads are unavailable in those logs. Missing attribution is not proof of
organic traffic or evidence that Chatwoot discarded a delivered ad ID.

No primary source examined establishes that every website-browser messaging
add-on must send an ADS referral, or guarantees appearance in Lead Center
within 24 hours. The [official welcome-message ads documentation](https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login/welcome-message-ads?locale=en_US)
describes engagement-ad flows and does not settle that website-add-on question.

## Follow-up acceptance

The current exact-ad setting and published desktop destination are confirmed
above. No test through an enabled add-on is possible with that setting Off;
changing ads remains the campaign owner's decision. If that surface is enabled,
a separately authorized real test must connect the original webhook to
the retained message referral, conversation fields and ad-context note. If the
payload uses the documented nested shape, the existing path applies. A genuinely
different delivered shape would justify a narrow handler change; no such change
is justified solely by an aggregate Ads Manager count.

Keep account timezone, report interval, action type, reporting time and
attribution window with each comparison. Do not fabricate ad IDs, infer people
from matching times/counts or convert view-through attribution into a direct
message referral.

Private source receipts are indexed by `linh-website-ad-evidence-manifest.json`
in the 2 October historical-audit artifact directory. They contain campaign/API
and preview evidence and are not published with this document. The later browser
limitation is recorded separately in `linh-meta-browser-setting-check.json`. Identifying
Linh's individual conversations is delegated to Shumabit.
The later successful check is recorded in
`linh-meta-browser-setting-confirmed-20261002.json`; the earlier receipt is
preserved as historical evidence.
