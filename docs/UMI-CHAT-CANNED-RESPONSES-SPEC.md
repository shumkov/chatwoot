# UMI Chatwoot reply shortcuts and Mai guide update

Status: content reviewed and ten native canned responses installed in Chatwoot account 1 on 18 October 2026. The `/back-in-stock` command is enabled, and the living Mai guide was updated and verified after activation. The private draft and command implementation live in the Shumabit repository; this document defines operator-facing copy only.

## Why this pack

Mai can insert a short reply in the customer's language, then edit it against the actual conversation, product page and Shopify variant. The shortcuts save typing; they neither answer autonomously nor establish stock, fit, delivery or booking facts. Chatwoot's native account-scoped `CannedResponse` stores `short_code` and `content`, with uniqueness per account. The live account 1 returned **zero canned responses** immediately before installation.

The [living Mai guide](https://docs.google.com/document/d/1F2DG54uY7P6a8r-_Ms2vYbqUBL_JcGfCuJ_sNI9-qHw/edit) contains 15 October updates about short private context notes, staff-reviewed AI suggestions and automatic acknowledgements, plus the targeted 18 October insert described below. The repository's `docs/UMI-MAI-CHAT-GUIDE.md` is an older snapshot and was not used to replace the living guide.

## Native canned responses

`short_code` is typed after Chatwoot's slash. Each row is a complete `content` value; do not include the shortcut or explanatory text in the stored content. Mai must remove any question already answered by the customer. The two language variants are separate so no bilingual block is sent accidentally.

| Short code | Content |
| --- | --- |
| `umi-size-en` | Happy to help with sizing. Which piece and size are you considering? If you tell us how you like it to fit, we can compare its garment measurements with a piece you own that fits well. |
| `umi-size-th` | ยินดีช่วยเลือกไซซ์ค่ะ สนใจรุ่นและไซซ์ไหนอยู่คะ? ถ้าบอกได้ว่าชอบใส่พอดีตัวหรือหลวมประมาณไหน เราจะช่วยเทียบขนาดของสินค้า กับเสื้อผ้าที่คุณใส่แล้วชอบได้ค่ะ |
| `umi-fabric-en` | I can check the composition and care instructions for the exact piece. Could you send its product link or photo so I don't mix it up with another style? |
| `umi-fabric-th` | เราช่วยตรวจสอบส่วนประกอบผ้าและวิธีดูแลของรุ่นที่สนใจให้ได้ค่ะ รบกวนส่งลิงก์สินค้าหรือรูปมาได้ไหมคะ จะได้ไม่สับสนกับรุ่นอื่นค่ะ |
| `umi-delivery-en` | Where would you like the order delivered? I’ll check the available shipping options and estimate for your destination before confirming the details. |
| `umi-delivery-th` | ต้องการให้จัดส่งไปที่จังหวัดหรือประเทศไหนคะ? เราจะตรวจสอบวิธีจัดส่งและระยะเวลาโดยประมาณสำหรับปลายทางของคุณก่อนยืนยันรายละเอียดค่ะ |
| `umi-restock-en` | Would you like an email alert if this size and colour comes back? Which email address should we use? We’ll confirm the exact item before requesting the alert; a restock date isn’t guaranteed. |
| `umi-restock-th` | หากไซซ์และสีนี้กลับมาวางขาย สนใจรับอีเมลแจ้งเตือนไหมคะ? ต้องการให้ส่งไปที่อีเมลไหนคะ? เราจะตรวจสอบรุ่นให้ตรงก่อนส่งคำขอแจ้งเตือน และยังไม่สามารถรับประกันวันที่สินค้าจะกลับมาได้ค่ะ |
| `umi-tbyb-en` | In Phuket, Try Before You Buy is available for eligible pieces: a stylist brings your reserved items, and you pay only for what you keep. Which piece and size would you like to try, and where in Phuket would you like the appointment? I’ll check eligibility and booking options. Our team will confirm the date and time before the booking is final. [How it works](https://umi.store/pages/try-before-you-buy) |
| `umi-tbyb-th` | ในภูเก็ตมีบริการลองก่อนซื้อสำหรับสินค้าที่เข้าร่วมค่ะ สไตลิสต์จะนำสินค้าที่จองไปให้ลอง และชำระเฉพาะชิ้นที่เลือกเก็บไว้ สนใจรุ่นและไซซ์ไหน และสะดวกให้ไปพบที่บริเวณไหนในภูเก็ตคะ? เราจะตรวจสอบว่าสินค้าเข้าร่วมและมีช่วงเวลานัดใดบ้าง การจองจะสมบูรณ์เมื่อทีมงานยืนยันวันและเวลานัดค่ะ [ดูวิธีใช้บริการ](https://umi.store/th/pages/try-before-you-buy) |

These are question-first drafts, deliberately without price, composition, stock count, shipping fee/date or booking confirmation. Those details depend on the variant, destination and current Shopify state. The TBYB explanation follows the published [English service page](https://umi.store/pages/try-before-you-buy) and [Thai Help page](https://umi.store/th/pages/help): Phuket only, eligible items, pay for what is kept. The [English](https://umi.store/pages/explore) and [Thai](https://umi.store/th/pages/explore) Help FAQs state Thailand shipping options and estimates, but destination and checkout must still be checked; the delivery shortcut therefore avoids static promises. Product pages expose per-piece composition and size guides; do not apply one style's facts to another. The [Thai Help page](https://umi.store/th/pages/help) describes a product-page restock email alert and the option to ask the team with an exact item/size.

## Living Mai guide update

Two short paragraphs were inserted in the living guide: contextual drafts and shortcuts near the existing private-draft guidance, and restock requests near “An unknown fact.” The reviewed source copy below records the intended operator guidance; the living guide has concise wording fitted to its existing sections.

> **Contextual private suggestions and reply shortcuts.** Shumabit may add a private draft after a new unanswered Facebook or Instagram customer message. It can include ad/referral clues and a short staff check. Treat an ad title, greeting, photo or old chat as clues, not proof of the exact item, size, stock or price. Read the customer's message and the current product/variant in Shopify. If clues conflict, ask which piece they mean. Edit the draft and send the customer reply yourself. The draft and staff check are private suggestions; they do not send a reply or perform the suggested action. The Chatwoot shortcuts `/umi-size-en`, `/umi-size-th`, `/umi-fabric-en`, `/umi-fabric-th`, `/umi-delivery-en`, `/umi-delivery-th`, `/umi-restock-en`, `/umi-restock-th`, `/umi-tbyb-en`, `/umi-tbyb-th` are optional starting text. Remove questions already answered, confirm product facts and send only the relevant language.
>
> **Exact-item restock email request.** Use `/umi-restock-en` or `/umi-restock-th` only when relevant. First confirm that the customer wants an email alert for one particular item, colour and size and has supplied or confirmed the destination email. A contact email, order email or newsletter permission alone is not this request. Identify the exact sold-out Shopify variant. In FB/IG inbox 2, Shumabit can suggest a ready-to-copy variant command in a private note; verify the item, colour and size in Shopify before using it. In other inboxes, find the variant in Shopify or ask Shumabit outside the Chatwoot conversation. Then, in **your own private note** in that customer conversation, enter `/back-in-stock <numeric Shopify variant ID or UMI product URL with variant=ID> <confirmed customer email>`. Use the customer's actual email, never a guessed address. Read the private result: accepted means Klaviyo accepted the request, not proof that the item will return or that an email was delivered. If the result is uncertain, check with Ivan before issuing a new command. This does not add the customer to marketing or send a customer message. If the variant is already available, use the normal product/checkout path instead.

The command is for a real staff user's private note across the configured Chatwoot account; `@shumabit` in-conversation help and contextual automatic drafts are limited to FB/IG inbox 2. Mai should not be asked to infer numeric IDs from photos or ad text. If Shumabit cannot verify the variant, escalate or use the product-page alert with the customer; do not guess.

## Application and verification

An independent Thai/domain review corrected the booking-confirmation and location wording; both TBYB destination URLs were checked. Account 1 then received the ten rows using a conflict-first, create-if-absent operation: identical rows would be left unchanged and differing existing content would abort before writes. Production Rails readback matched all ten `short_code`/`content` pairs (`READBACK_OK 10`, 18 October 2026, 16:26 UTC). No existing row was modified or deleted, and no customer message was sent. Composer insertion has **not** yet been visually checked.

After runtime activation on 18 October, the two targeted Google Doc insertions were each made against the latest revision and read back. A PDF export was rendered and visually checked; surrounding guide sections and the second tab were preserved. The guide states that `accepted` is provider acceptance, not email delivery. No customer message was sent by the guide edit.
