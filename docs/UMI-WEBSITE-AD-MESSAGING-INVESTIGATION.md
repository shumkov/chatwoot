# Messages associated with website-purchase ads

Read-only investigation, 2 October 2026. No campaign, budget, subscription,
customer message or conversion event was changed.

## What is established

A current UMI sales campaign optimized for website purchases reports Instagram
messaging outcomes. Its two conversation starts split into one view-attributed
result and one click-attributed result. The one-day and seven-day click windows
overlap; adding them would double count. These metrics do not identify people
or prove that both conversations began through a message button in the ad.

The queried creative and standard Instagram feed preview show a website
`SHOP_NOW` destination. Neither establishes whether a messaging add-on appears
inside the post-click browser. An omitted API field does not mean the add-on is
disabled. Its exact setting and delivered webhook remain unverified.

The existing Chrome Ads Manager tab was also inspected. It remained blank after
one reload, so no browser add-on setting or selected messaging destination could
be read. No login, setting change or contact action was attempted.

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

Confirm the exact ad's add-on setting and actual post-click surface. A separately
authorized real test through that surface must connect the original webhook to
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
