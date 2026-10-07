# Monetization, store page and ads

How a game made from the starter gets a complete shop (game passes, developer products, a subscription, offers and boosts), store art that gets clicks, store page text and an Ads Manager plan. The research behind every default is [monetization-ads-store-2026-10.md](research/monetization-ads-store-2026-10.md); the commerce API facts (prompts, receipts, policy) are in [gamekit-platform.md](gamekit-platform.md) and [release-monetization-analytics-2026-10.md](research/release-monetization-analytics-2026-10.md).

**Boundary.** The tools plan, write data files, compose art and check text. They never create products, set prices, upload, publish or buy ads. The owner creates each product in Creator Hub, pastes its id back (`monetize.py set-id`), sets prices, uploads art and decides any ad spend in Ads Manager. Every catalog stays in setup mode (disabled, placeholder ids) until the owner does that.

## What top games teach (the short version)

- The top earners sell repeatable things: currency packs, timed boosts, server luck and gifts, on top of a few permanent passes (VIP, 2x currency, more storage, auto-collect). Viral hits earn mostly from developer products, not passes.
- Every top game shows a shop button on the HUD, a starter pack for new players, a "best value" anchor in each ladder and contextual offers (out of currency, after a death, at a locked door). None of them nag: offers are capped and dismissable.
- Prices cluster on a few points (49, 99, 149, 199, 249, 299, 399, 499, 799, 999, 1999 and up). A ladder of three to five currency packs with the biggest pack as the best value is the norm.
- PvP games avoid selling power over other players (RIVALS sells cosmetics and keys); co-op and solo games sell power freely.
- Since May 30, 2026 products are sold only in their own experience; Roblox Plus (April 2026) adds a subscription surface.

## The pipeline for one game

```text
production/brief.json (genre)
  -> python3 tools/monetize.py plan          catalog, offers, boosts, perks, shop, store.csv, plan, sheet
  -> python3 tools/monetize.py check         minimums and cross-file consistency (release check A18)
  -> python3 tools/store_art.py briefs       one task per asset: icon, 5 thumbnails, item icons, ad
  -> python3 tools/store_art.py compose ...  each asset from a subject render, then lint and preview
  -> python3 tools/store_page.py draft       store/page.json: title, hook, features, update log
  -> python3 tools/store_page.py lint        copy rules (release check A18)
  -> python3 tools/ad_kit.py plan / sheet    store/ads/campaign.json and the Ads Manager entry sheet
owner: create products, set-id, set prices, upload art, paste text, decide ads
```

### 1. Plan the shop: `monetize.py`

`python3 tools/monetize.py plan` reads the genre from `production/brief.json` (or `--genre` and `--subgenre`) and picks archetypes from `tools/storekit/genre_sets.json`: a base set for every game (VIP, starter pack, three currency packs, gift VIP) plus the genre's products. `python3 tools/monetize.py list` prints all 31 archetypes and the genre sets. Options:

| Option | Effect |
|---|---|
| `--currency LABEL` | the soft currency's name in product text (default from the genre) |
| `--tier low\|mid\|high` | which point of each archetype's price ladder the sheet suggests |
| `--add KEY`, `--drop KEY` | add or remove archetypes |
| `--allow-power` | keep power products in PvP genres (dropped by default) |
| `--allow-random` | include the paid random item (`lucky_crate`); needs odds disclosure and the PolicyService gate |
| `--dry-run`, `--force` | print without writing; replace existing files |

It writes the catalog (catalog/1, setup mode), `offers.json`, `boosts.json`, `perks.json`, `shop.json`, `src/localization/store.csv`, `monetization/plan.json` and `docs/design/monetization.md`, the owner's Creator Hub sheet: one row per product with its type, suggested price, description and icon brief. Prices exist only in the plan and the sheet; the game reads real prices at runtime (A14). After creating a product, the owner runs `python3 tools/monetize.py set-id KEY ID`.

`check` fails the game when it has fewer than 3 passes or 4 developer products, no starter offer, no visible shop entry, a product no section shows, or files that disagree. Generated examples for eight genres live in [fixtures/monetization](../fixtures/monetization/).

### 2. Runtime modules

All four are pure T0 cores with Lune specs ([gamekit_monetization.spec.luau](../tests/gamekit_monetization.spec.luau)). None of them prompts: purchases still go through `CommerceRoblox.prompt` and grants through the receipt handler.

| Module | Data | Use |
|---|---|---|
| [Offers](../packages/GameKit/Offers.luau) | offers/1, offer-state/1 | `Offers.session(data, state, now)` per player; `session:evaluate(trigger, ctx)` returns the offer to show or a reason (`grace`, `spacing`, `session_cap`, `quiet_after_purchase`, `prompt_open`, `none_eligible`); then `shown`, `purchased`, `expiresAt` and `save` |
| [Boosts](../packages/GameKit/Boosts.luau) | boosts/1, boost-state/1 | `Boosts.new(data, saved, now)` per player or server; the receipt grant calls `tracker:add(key, now)`; game code asks `tracker:value(stat, now, base)`; playtime boosts `pause` and `resume` on leave and join |
| [Perks](../packages/GameKit/Perks.luau) | perks/1 | `Perks.resolve(data, owns)` with an ownership predicate from `Commerce.ownership`; then `Perks.value(resolved, stat, base)` and `Perks.has(resolved, flag)` |
| [ShopLayout](../packages/GameKit/ShopLayout.luau) | shop/1 | `ShopLayout.build(shop, catalog, { owned, hideOwned })` gives the sections for Tabs and Grid, featured first and owned passes last; `ShopLayout.lint` reports merchandising problems |

Triggers are labels the game fires: `join`, `death`, `locked`, `low_currency`, `level_up`, `round_end`, `shop_open`, `idle`, `event_start`. `shop_open` skips the popup rules because the player asked for the shop. The default rules allow 3 popups a session, 180 s apart, none in the first 120 s of a first session and none for 300 s after a purchase.

### 3. UI

[ShopCard](../packages/UIKit/Components/ShopCard.luau) takes a `ribbon` (`best_value`, `most_popular`, `limited`, `new`, `sale`, `starter`). [OfferPopup](../packages/UIKit/Components/OfferPopup.luau) shows the offer `Offers` picked: a ShopCard, an optional time-left Timer, "Get it" and "Not now". It is always dismissable and closes itself with `expired` when the timer runs out. Both report `onSelect(productKey)`; the game prompts. See [uikit.md](uikit.md).

### 4. Store art: `store_art.py`

`specs` prints the rules per kind from `tools/storekit/art.json` (icon 512x512 shown at 150 px; thumbnails 1920x1080 under 3 MB, up to 10; pass, product and badge icons with a circle crop; the ad creative is a 16:9 thumbnail). `briefs` writes `store/art/briefs.json`: the icon, five thumbnail concepts (hero, core action, reward, social, update) for thumbnail personalization, one icon per product and the ad creative, each with a codex-image prompt and a Blender shot. `compose --template T` builds an asset from a transparent subject render (templates `icon_hero`, `icon_clean`, `thumbnail_hero`, `thumbnail_action`, `pass_icon`, `product_icon`, `badge_icon`; seven palettes; fonts fetched by sha256 pin with `fonts --fetch`). `lint` checks the hard rules (errors) and readability at the shown size (warnings); `preview` writes a contact sheet at real display sizes. Compose, lint heuristics and preview need Pillow. Running codex-image costs the owner's Codex credits, so ask first.

### 5. Store page: `store_page.py`

`draft` writes `store/page.json` (store-page/1) from the brief and the plan: a stable name with at most one bracketed update tag, a hook that names the genre in the first 160 characters, features, the latest update and a line about optional purchases. `lint` applies `tools/storekit/copy_rules.json`: title up to 50 characters, at most 3 emoji, description up to 1000, and no free Robux, giveaway, discount or pressure wording, hashtags, prices with "only" or "just", or off-platform links. `render` prints what to paste into Creator Hub; `update --tag --notes` records each update.

### 6. Ads plan: `ad_kit.py`

`plan` writes `store/ads/campaign.json` (ad-campaign/1): goal (Plays by default), the New Players audience, tier-1 countries, devices from the brief, three to five creatives from the thumbnail concepts, a test plan (pause a creative under 2% CTR after 20,000 impressions, no restart within 7 days) and budget scenarios estimated from Roblox's published cost per play. `purchase` is always `false`, and `lint` refuses a file that says otherwise or carries credential or payment fields. `sheet` prints the Ads Manager entries field by field; `estimate --credits N` shows plays for a budget. Remember that players acquired from ads do not count toward Recommended for You: ads buy a test audience, and the game's own play-through rate and retention decide organic growth.

## Release check

Item A18 (Shop, offers and store page) runs `monetize.check_docs` and the store page lint. A fresh starter fails it until `monetize.py plan` and `store_page.py draft` have run. Owner items O07 to O10 cover the uploads.
