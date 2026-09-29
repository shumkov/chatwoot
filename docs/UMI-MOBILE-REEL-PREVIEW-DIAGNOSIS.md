# Mobile Instagram Reel preview: missing translation

29 September 2026. Diagnosis only; no production messages, translations or app code changed.

## Confirmed symptom and cause

The user screenshot shows a file icon, outgoing arrow and `[missing "en.CONVERSATION.A…` for conversations 245 and 50. Read-only production inspection identified the latest messages as 12084 and 12080 respectively, created 28 September at 14:34:03Z and 14:29:44Z. Both are public outgoing Meta echoes, with empty text and an attachment of type `ig_reel`. Neither stored message contains the missing-translation string. No customer text or media URLs are retained here.

Mobile `ConversationLastMessage.tsx` chooses the attachment branch when there is no text. It constructs `CONVERSATION.ATTACHMENTS.${lastMessageFileType}.CONTENT` without a supported-type fallback. For these messages the key is `CONVERSATION.ATTACHMENTS.ig_reel.CONTENT`.

The English mobile dictionary contains image/audio/video/file/location/fallback/contact, but not ig_reel. Its pinned i18n-js 3.9.2 therefore returns exactly:

```
[missing "en.CONVERSATION.ATTACHMENTS.ig_reel.CONTENT" translation]
```

The generic file icon also follows directly from the default branch of getAttachmentIcon; the outgoing arrow follows message_type=outgoing. This accounts for all visible elements in the screenshot.

The server Attachment enum already defines ig_reel in upstream v4.16.0; `git diff v4.16.0 -- app/models/attachment.rb` is empty. This is not a custom UMI translation key or a funnel/private-note message. The missing dictionary entry and unsafe mobile lookup are present in latest published GitHub release v4.9.0 (18 August 2026) and develop commit ffd77e38d4ec1af018a62ed924db6da759bb2c0c checked on 29 September. The installed iPhone build was not independently read, and GitHub release metadata is not an App Store inventory.

## Reproduction evidence

Downloaded the v4.9.0 English dictionary and its pinned i18n-js version into a temporary directory. Calling `I18n.t('CONVERSATION.ATTACHMENTS.ig_reel.CONTENT')` reproduced the exact error string. A human-readable-label assertion failed. The same call for image returned `Picture message`, serving as a working control. This reproduces translation lookup with the production input shape; it is not a launched iOS rendering test.

Targeted upstream issue/PR searches for ig_reel and missing translation found no matching fix. This bounded search is not proof none exists.

## Correct repair boundary

Fix the mobile client: add missing supported attachment labels and a fallback to existing `CONVERSATION.ATTACHMENT_CONTENT` for unknown types; treat an empty attachments array as no attachment. Regression cases belong around ConversationLastMessage: empty-text ig_reel, ordinary image, unknown type, empty list, text caption taking precedence. Broader content rendering must be verified separately; this diagnosis proves the list-preview error only.

Adding a server en.yml/en.json key cannot supply the separately bundled native dictionary. A server-side display-only preview fallback might avoid the symptom on an unchanged client, but is a separate compatibility change requiring review and proof that original messages, attachments, classifier evidence and outbound payloads remain unchanged. Do not rewrite stored customer messages to hide a UI error. No mobile fork is proposed as a campaign-launch requirement.

## Sources

- Mobile renderer: https://github.com/chatwoot/chatwoot-mobile-app/blob/v4.9.0/src/screens/conversations/components/conversation-item/ConversationLastMessage.tsx#L113
- English dictionary: https://github.com/chatwoot/chatwoot-mobile-app/blob/v4.9.0/src/i18n/en.json
- Latest release inspected: https://github.com/chatwoot/chatwoot-mobile-app/releases/tag/v4.9.0
- Server attachment type: app/models/attachment.rb:47
