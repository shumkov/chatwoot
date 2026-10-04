# UMI Instagram messaging campaigns

Campaign and measurement brief for Linh. Updated 5 October 2026, Bangkok.

## What is ready, and what still needs checking

The system can receive Instagram conversations, classify buying intent, show
customer context, link Shopify orders and send eligible Instagram outcomes to
Meta. A genuine `QualifiedLead` has been accepted and now appears as **Active**
in Events Manager. Future eligible paid-in-chat `Purchase` delivery is enabled.

The first genuine paid-in-chat Purchase has not yet occurred with all required
links and settlement evidence. Its delivery and campaign attribution are still
to be observed. An accepted event does not prove that an ad set uses it for
optimization, or that it caused an attributed sale.

Linh owns the offer, audience, creative, budget, schedule and campaign launch.
This brief does not authorize or report a campaign launch.

## Recommended setup to check in Ads Manager

| Setting | Selection / check |
| --- | --- |
| Objective | Engagement is a supported starting path for messaging. |
| Conversion location | Message destinations. |
| Destination | Instagram Direct, professional account `@umi.asia`. For an IG-only test, do not leave Messenger or WhatsApp selected. |
| Performance goal | Prefer **Maximise number of purchases through messaging** if it is offered for this account and destination. |
| If Purchase is unavailable | Tell Ivan before launch. A Conversations goal is a possible separate test, but optimizes conversations rather than verified purchases. Do not present it as the same experiment. |
| Tracking | Use the existing UMI assets and integration; do not install a second Purchase sender or substitute a website conversion location. |

Meta's current help describes purchase optimization for Instagram Direct, subject
to eligibility. UMI's earlier API validation accepted an Instagram-only messaging
Purchase configuration without creating an ad set. That is useful configuration
evidence, not proof of launch eligibility in every UI path. The existing paused
ad set still shows **Maximise number of conversations** with Messenger and
Instagram selected; its published goal controls are locked. Check the available
goal in the new campaign you prepare. No ads were changed during this inspection.

Source: [Meta's messaging purchase setup](https://www.facebook.com/business/help/1214599109289826)
and [Instagram messaging ads setup](https://business.facebook.com/business/help/198088077975174).

## Which signals mean what

| Signal / fact | Meaning | Does not mean |
| --- | --- | --- |
| Engaged | An ordinary enquiry, such as price or general delivery availability. | A qualified buying opportunity or a paid sale. |
| QualifiedLead | Concrete buying discussion or meaningful product/fit consultation, confirmed by the classifier or operator with eligible live evidence. | Every new message, story mention, collaboration or support request. |
| Order placed | A linked unpaid or partly paid order supported by Shopify facts. | Payment received, or merely creating a draft link. |
| Messaging Purchase | Verified Shopify payment, exact conversation attribution and confirmation that settlement happened in that chat, with eligible channel evidence. | A draft, unpaid fitting/pickup, barter, or checkout merely being completed. |
| VIP / Repeat / Influencer | Customer context for service and audiences. | Independent Meta conversion events. |

AI classification runs automatically for the approved customer inboxes. Mai can
correct mistakes. Meta outcome delivery currently targets Instagram; classifying
LINE, email or WhatsApp does not imply those channels send Meta outcomes.

The integration preserves available advertising referral evidence. A referral or
source label helps explain where a chat came from; it is not itself a conversion,
and missing referral evidence must not be invented. Website-ad message add-ons
can also produce chats; inspect the recorded source before calling a conversation
a click-to-Instagram ad result.

## Paid must mean paid

Try-before-you-buy and unpaid pickup stay unpaid until a real payment is verified.
For QR settlement in the conversation, Mai links the correct customer/order,
checks payment in Shopify, then posts `/paid-in-chat #1234` as a private note.
The command records the settlement location; it does not collect money, create
an order or prove that Meta accepted the resulting event.

An order paid through a customer checkout link remains owned by Shopify's
website sender, even if the conversation helped the sale. Chatwoot does not
send a second messaging Purchase for that checkout. The CRM order link still
lets the team see the relationship; it does not change Meta's conversion source.

**Separate website tracking limitation:** Shopify's native Meta pixel currently
sends website `Purchase` on checkout completion. Its live browser code has no
paid-status filter, so an unpaid TBYB checkout can generate that signal. This is
separate from our verified messaging Purchase. Do not use native website Purchase
counts as paid revenue or compare them directly with verified messaging sales.
Do not choose website Purchase as a workaround for a missing messaging goal.

Fixing that native website behavior requires a separate tracking decision.
Options are a separate verified-payment conversion target, or a controlled
replacement of native tracking. Neither has been activated. The working native
catalog and website integration remain in place. Shopify documents the native
event timing in its [Meta data-sharing guide](https://help.shopify.com/en/manual/promoting-marketing/analyze-marketing/meta-data-sharing).

## Audiences and reporting

Shopify is the source of order/payment facts. Klaviyo maintains customer
lifecycle and audiences; Chatwoot holds conversation meaning and operator work.
Client means one verified paid purchase; Repeat means at least two. A customer
may be Repeat or VIP while their latest conversation is about a return.

Recent conversation intent is a rolling 30-day audience of profiles with a
genuine UMI Conversation Qualified event. It includes existing buyers when they
show new intent. It needs an exact Klaviyo profile identity; an Instagram handle
alone is not enough. At this checkpoint no eligible qualification has reached
a bound Klaviyo profile, so the audience has not yet been created. Do not treat
that as zero customer interest. No new marketing flow or customer send is launched
by this integration.

Use the Friday report for response speed, unanswered work, conversation quality
and verified commerce facts. Keep platform-attributed results separate from CRM
facts. No reliable lost-revenue or ROAS number should be inferred from silence,
unlinked orders or missing ad-spend data. Public Instagram comments must be
checked separately in Business Suite; Mai's access and routine still need
confirmation. They are not included in Chatwoot DM SLA coverage.

## Launch handoff

1. Record the chosen objective, destination and available performance goal.
2. Confirm the offer and that Mai can cover replies, daily 09:00-21:00 Bangkok.
3. Confirm Mai can see and handle public comments on the Instagram ads.
4. After launch, inspect genuine conversations and the first eligible paid-in-chat
   outcome in CRM, Events Manager and Ads Manager. Do not create a fake purchase.
5. Report delivery, attribution and campaign results separately. If a goal is
   unavailable, agree the fallback with Ivan before spending.
