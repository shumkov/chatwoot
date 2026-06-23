# UMI Knowledge & Agent Architecture — FAQ surfaces + source of truth

**Status:** spec v1 — planning. **Phase 1 shipped** (Chatwoot Help Center → Shopify
`help` blog, see `UMI-SHOPIFY-HELP-CENTER-SPEC.md`). **Phase 2 (next): shumabit agent
integration into Chatwoot** + the knowledge-source decision below.
**Driver:** Ivan Shumkov. **Updated:** 2026-06-23.

## 1. Why this spec

UMI's FAQ/knowledge content has to reach several audiences through different
surfaces. We've shipped one (the storefront blog). Before building the next big
piece — **our own agent (shumabit) answering shoppers inside Chatwoot** — we need
to settle **where each kind of knowledge lives (source of truth)** so we don't
duplicate or drift. Shopify's recently-installed **Knowledge Base + Storefront
MCP** changes the calculus and is the trigger for writing this down.

## 2. Surfaces & audiences

| # | Surface | Audience | Reads from | Status |
|---|---------|----------|-----------|--------|
| 1 | Storefront FAQ — blog `/blogs/help/<x>` | shoppers browsing **and searching** the store | Chatwoot Help Center (synced) | ✅ **shipped** |
| 2 | Chatwoot chat widget — Help Center articles | shoppers in the chat widget | Chatwoot Help Center (native) | ✅ existing |
| 3 | Shopify AI surfaces (Sidekick, AI shoppers, **Storefront MCP**) | AI shopping agents | Shopify KB (`shopify--faq` metaobjects) | KB installed, auto-populated |
| 4 | **shumabit** agent inside Chatwoot | shoppers chatting → agent answers | **? — Phase 2 decision** | 🔜 next task |

Storefront **search** is why #1 must be the blog: Shopify's native search indexes
products/pages/**articles**, **not** metaobjects — so the KB can never replace the
blog for search/SEO (confirmed by spike + docs).

## 3. Source of truth — **split by content type** (the key decision)

There is **no single source of truth.** Each fact lives in exactly one system,
chosen by what kind of knowledge it is:

- **Commerce / store facts → Shopify is the system of record.**
  Shipping zones, return rules, pickup, payments, taxes, product data, store
  languages. Shopify already *derives* these (the KB's "Store FAQs" are auto-built
  from Return Rules, Shipping, Pickup, Pages, Languages — all "Created by Shopify").
  **Do not re-maintain these in Chatwoot** — they'd drift from the store's real
  config. The agent reads them live via the **Storefront MCP**.
- **Curated / editorial help → Chatwoot Help Center is the source of truth.**
  How-tos, product care, brand/mission content, nuanced support answers, anything
  the team authors as narrative. This powers the widget (#2), the storefront blog
  (#1, shipped), and shumabit's curated answers.
- **No duplication.** A given answer has one home. If a curated Chatwoot answer
  also needs to reach Shopify's AI shoppers, **bridge** it (§6) rather than copy it.

Rule of thumb: *"Is this a fact about how the store operates?"* → Shopify.
*"Is this something a human wrote to help a customer?"* → Chatwoot.

## 4. Phase 1 — shipped (scope boundary for now)

Chatwoot Help Center (portal `umi-help`, en) → Shopify `help` blog, in-process via
the fork plugin. Covers surfaces #1 (+ feeds #2 natively). **This is the agreed
scope to ship now.** Remaining to go live: reconnect the Shopify integration for
the OAuth scopes, pick the blog handle, run the backfill, deploy (see the
help-center spec §7–8). Everything below is **the next task, not this one.**

## 5. Phase 2 — shumabit agent in Chatwoot (next task, sketch only)

**Goal:** shumabit, wired into Chatwoot, answers shopper questions in live chat.

**Shape (to be designed in its own spec):**
- shumabit runs as a **Chatwoot Agent Bot** — registered bot receives new-message
  webhooks, retrieves knowledge, posts replies via the Chatwoot API; hands off to a
  human agent when unsure.
- **Knowledge retrieval = both sources, by domain (per §3):**
  - **Shopify Storefront MCP** → commerce/store facts (live, accurate, zero
    maintenance; also auto-logs the shopper's question to the KB so gaps surface).
  - **Chatwoot Help Center** (API: list/search articles) → curated help content.
- shumabit picks the right source per question (commerce fact vs help content), or
  queries both and synthesizes.

**Why this is "much bigger":** agent-bot wiring, retrieval/grounding quality,
human-handoff rules, conversation state, guardrails, eval. It deserves its own
research → spec → review pass; this section just fixes the **knowledge model** it
will build on.

## 6. Optional bridge — Chatwoot → Shopify KB custom FAQ (additive)

When a **curated** Chatwoot answer should also reach **Shopify's AI shoppers**
(Sidekick / external AI / the MCP), sync it into the KB as a custom `shopify--faq`
metaobject — a *second, additive* sync target alongside the blog. This is the
metaobject path we spiked. It does **not** replace the blog (metaobjects aren't
searchable) and is **not** needed for shumabit (shumabit reads Chatwoot directly).
Build it only if/when AI-shopper coverage of curated content is a goal.

## 7. Spike findings (2026-06-23, `pizeev-ys`, via `shopify store execute`)

- KB app is **installed**; it auto-generated Store FAQs from store settings and
  exposes a **Storefront MCP** for agents ("Develop your store's own assistant").
- Before install: zero metaobject definitions. After install: `shopify--faq` is a
  **Shopify-reserved** type (can't be self-created), so the KB app is the only way
  to provision it — confirming the KB/AI path is **gated on the app being present**
  (now satisfied).
- The `metaobjectCreate` write spike (can our token add custom `shopify--faq`
  entries) is **still pending** — needs a CLI re-auth with
  `read_metaobjects,write_metaobjects` scopes. Only relevant if we build §6.

## 8. Open questions (decide before Phase 2 build)

1. **MCP vs Help-Center for the agent:** does shumabit hit the Storefront MCP for
   commerce facts and the Chatwoot API for curated help, or do we mirror one into
   the other? (Recommended: query both; don't mirror.)
2. **Does the Storefront MCP cover everything we need** (auth, rate limits, what
   resources it exposes beyond FAQs)? → research task in the Phase 2 spec.
3. **Human handoff & guardrails** for shumabit — out of scope here, but the
   gating decision for going live.
4. **§6 bridge** — build it now (AI-shopper coverage) or defer? Defer unless
   AI-shopper representation of curated content is a near-term goal.

## 9. Out of scope (this spec)

The shumabit agent-bot implementation, retrieval/eval design, handoff logic, and
the §6 metaobject sync. Each is its own task. This spec only fixes the
**surfaces** and the **source-of-truth split** they share.
