---
name: roblox-monetization-and-store
description: Plan and build a game's whole money and store side - game passes, developer products, a subscription, starter packs, contextual offers, timed boosts, gifts, the in-game shop UI with ribbons and an offer popup - plus the store page (icon, five thumbnails, pass and product icons, title, description, update log), an Ads Manager plan that never buys ads, and store setup through Open Cloud once the owner approves it (create passes and products, set prices, upload art). Uses monetize.py, store_art.py, store_page.py, ad_kit.py, store_publish.py and GameKit Offers, Boosts, Perks and ShopLayout. Use for shops, passes, dev products, microtransactions, pricing, thumbnails, icons, store descriptions and ad creatives.
---

# Monetization and store

## Purpose
Every game ships a shop players notice and want to use, a store page that gets clicks and a ready-to-enter ad plan, built from the research and the tested tools rather than guessed. **Gate:** production skill. In a game repository it runs after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against `fixtures/monetization/` and scratch scaffolds. Nothing ever spends money: no ad credits, no badges that cost Robux, no purchases. Place publishing stays with the owner. Creating products, setting prices and uploading store art and text go through `tools/store_publish.py` only after the owner approves store setup for that game. The API key lives in the owner's `ROBLOX_OPEN_CLOUD_KEY` environment variable; never ask for it in chat.

## Triggers
Game passes, developer products, subscriptions, microtransactions, a shop or store UI, starter packs, limited offers, boosts, gifting, pricing, "make players spend", store icon, thumbnails, title, description, update tags, ads, ad creatives, ad targeting, release check A18.

## Inputs
`production/brief.json` (genre, subgenre, devices, PvP or not), the game's soft currency and core loop, its stats that passes and boosts can change, subject renders or captures for art, the latest update notes.

## Required context
- Guide: `docs/monetization.md` (the pipeline, every option, the boundary).
- Research: `docs/research/monetization-ads-store-2026-10.md` (Part 1 top-game shops and genre sets; Part 2 Ads Manager; Part 3 icons, thumbnails and copy).
- Data: `tools/storekit/archetypes.json` (31 products, price ladders, why each sells), `genre_sets.json`, `art.json`, `copy_rules.json`, `ads.json`.
- Runtime: `packages/GameKit/Offers.luau`, `Boosts.luau`, `Perks.luau`, `ShopLayout.luau`; `packages/UIKit/Components/ShopCard.luau` (ribbon) and `OfferPopup.luau`; prompts and receipts through skill roblox-persistence-and-commerce (`CommerceRoblox.prompt`, the receipt handler).

## Tools
`python3 tools/monetize.py plan|check|set-id|list`, `python3 tools/store_art.py specs|briefs|compose|lint|preview|fonts`, `python3 tools/store_page.py draft|render|lint|update`, `python3 tools/ad_kit.py plan|lint|sheet|estimate`, `python3 tools/store_publish.py scopes|target|approve|plan|run`, `python3 tools/release_check.py` (A18). Lune: `lune run tests/run.luau gamekit_monetization`. Pillow for compose, lint heuristics and preview. codex-image or Blender for subject renders; each codex-image run costs one Codex turn from the owner's plan, so confirm their credit auto-reload is off before a large batch.

## Procedure
1. Plan: `python3 tools/monetize.py plan` (genre from the brief). Keep the base set (VIP, starter pack, three currency packs, gift VIP); add genre products with `--add`. PvP genres keep power products out unless the owner says `--allow-power`; paid random items need `--allow-random`, OddsTable disclosure and PolicyGate.
2. Check: `python3 tools/monetize.py check` until clean: at least 3 passes and 4 developer products, a starter offer, a visible HUD shop button, every product in a section. ShopLayout's lint also warns about a section with one product or two best-value ribbons.
3. Wire the runtime: `Perks.resolve` with `Commerce.ownership` for pass effects; `Boosts.new` per player (and one for the server) with `add` called from the receipt grant; `Offers.session` per player, firing triggers where the player feels the need (out of currency, death, locked door, round end); `ShopLayout.build` feeding Tabs, Grid and ShopCard; OfferPopup for offers. `onSelect` leads to `CommerceRoblox.prompt`; never grant from prompt events.
4. Art: `python3 tools/store_art.py briefs`, then for each task a subject render, `compose --template ...`, `lint` (no errors; read warnings at the shown size) and `preview`. Five thumbnail concepts (hero, core action, reward, social, update) feed thumbnail personalization; the icon reads at 150 px; no text in a thumbnail's bottom 20%.
5. Page: `python3 tools/store_page.py draft`, edit the hook and features to the real game, `lint` until clean, then `render` for the owner. Each update: `update --tag --notes`.
6. Ads: `python3 tools/ad_kit.py plan`, `lint`, `sheet`. Leave `purchase` false. Hand the sheet to the owner.
7. Store setup: with the owner's approval recorded (`store_publish.py approve`), the experience recorded (`target`) and the key in the environment, run `store_publish.py plan`, read every request, then `run --yes`. Subscriptions go to Creator Hub. Without approval, hand the owner `docs/design/monetization.md` (create each product, `monetize.py set-id KEY ID`). Then `python3 tools/release_check.py` shows A18 green.

## Outputs
`src/shared/catalog.json`, `offers.json`, `boosts.json`, `perks.json`, `shop.json`, `src/localization/store.csv`, `monetization/plan.json`, `docs/design/monetization.md`, `store/art/briefs.json` and composed files, `store/page.json`, `store/ads/campaign.json`, the runtime wiring and its specs.

## Acceptance
`monetize.py check`, `store_page.py lint` and `ad_kit.py lint` report no errors; `store_art.py lint` has no errors on every file; release check A18 passes; the shop opens from a HUD button, every offer can be dismissed, and no popup shows in a new player's first two minutes or right after a purchase.

## Failure
- A price or "only 99 Robux" lands in data or UI text: remove it; prices are read at runtime (A14) and live only in the plan and sheet.
- Copy lint flags free Robux, giveaway, discount or pressure wording: rewrite it; Roblox moderates these and ad review rejects them.
- Pillow is missing: `python3 -m pip install pillow`; specs, briefs and size checks still work without it.
- An offer shows too often in a playtest: tune `rules` in offers.json (spacing, cap, grace); never remove the dismiss path.
- Someone asks to buy ads, buy Robux or create a paid badge: stop. Spending is never an agent step.
- `store_publish.py` refuses with an HTTP 401 or 403: the key lacks a permission from `scopes` or is not scoped to this experience; the owner fixes the key.
- A store_publish run stops partway: rerun it. `store/publish.json` records each finished step.

## Related
roblox-persistence-and-commerce (prompts, receipts, policy), roblox-ui-ux-pass (shop screens), roblox-genre-systems (genre loops), roblox-release-pass (A18, O06 to O10), roblox-presentation-pass (art direction).
