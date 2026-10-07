# Monetization, ads and store assets: top-game shops, Ads Manager and click-worthy thumbnails (verified 2026-10-07)

**Scope.** What the factory needs so every game ships a shop players want to use (game passes, developer products, subscriptions, offers and boosts), a store page that gets clicks (icon, thumbnails, title, description) and a ready-to-enter Ads Manager plan. It has three parts, each with its own source list: Part 1 reads the live Top Earning chart and the live pass lists of 34 top games; Part 2 covers self-serve Ads Manager; Part 3 covers icons, thumbnails, copy and the art pipeline. It extends [release-monetization-analytics-2026-10.md](release-monetization-analytics-2026-10.md), which owns the API facts for prompts, receipts and policy.

**What the factory built from it.** `templates/starter/tools/monetize.py` with `tools/storekit/archetypes.json` and `genre_sets.json` (Part 1, sections 2.21 to 4), `store_art.py` with `storekit/art.json` (Part 3), `store_page.py` with `storekit/copy_rules.json` (Part 3 section 4 and Part 2 section 5), `ad_kit.py` with `storekit/ads.json` (Part 2), and the runtime modules `GameKit/Offers`, `Boosts`, `Perks`, `ShopLayout` and `UIKit/Components/OfferPopup` (Part 1 section 3). The usage guide is [docs/monetization.md](../monetization.md).

**Boundary.** Research only: nothing here buys ads, sets live prices or publishes. Prices are suggestions for the owner to enter in Creator Hub. Ad spend is always the owner's decision in Ads Manager.

## Part 1. Monetization: top games, passes, developer products, shop UX and genre sets

All sources fetched **2026-10-07** unless noted otherwise. Source numbers like [S12] point to the Sources section at the end.
If something has no source, or the source could not be checked, it is marked **UNVERIFIED**.
Where a claim is my own analysis of the fetched data and not a sourced fact, it is labeled **(analysis)**.

**How the data was gathered.**
- **Game pass lists and prices** come from Roblox's public game-pass endpoint, `apis.roblox.com/game-passes/v1/universes/{universeId}/game-passes?passView=Full&pageSize=100`. These are the live prices on the fetch date [S30-S58].
- **Universe IDs** were resolved with `apis.roblox.com/universes/v1/places/{placeId}/universe`.
- **The top-earning ranking** comes from Roblox's own "Top Earning" sort, `apis.roblox.com/explore-api/v1/get-sort-content?sortId=top-earning` [S29].
- **Developer products** cannot be read from a public API, so their prices come from third-party guides. These prices go stale fast; treat them as indicative only.
- **Fandom wikis** returned HTTP 402 to the fetcher, and the BreezeWiki mirrors returned captcha or access-denied pages. No Fandom page was read directly.

---

### 0. Executive summary (key findings)

1. **Roblox does not publish per-game revenue.** Every per-game dollar figure is a third-party estimate.
   - The only widely cited hard-ish number is **Grow a Garden: about $12M of virtual-item sales in May 2025** [S5]. Its original source is not named, so treat it as UNVERIFIED.
   - RoWatcher's Q1-2026 estimates put Rivals ($8-15M/mo), Blox Fruits ($8-14M/mo) and Brookhaven ($6-12M/mo) at the top [S1]. This is low-confidence aggregation.
   - The platform-level facts are solid:
     - Creators earned more than $1B through DevEx from March 2024 to March 2025 [S8].
     - The top 10 creators averaged **$33.9M** in 2024 [S8].
     - FY2025 DevEx payouts were **about $1,503M** [S10].
2. **The live Top-Earning chart (2026-10-07)** reads, in order [S29]:
   - Slayers 2, Adopt Me!, Blox Fruits, Steal An Egg, RIVALS, Fisch, Dandy's World, ABA, Jujutsu Shenanigans, Blade Ball.
   - Then Pet Simulator 99, Grand Piece Online, Sniper Arena, Build the Pyramid!, Tower Defense X, Murder Mystery 2, Tower Defense Simulator, and others.
   - 2025's viral hits rank much lower: 99 Nights is #38, Brookhaven #72 and Steal a Brainrot #75. Grow a Garden (the original) is not in the top 96.
   - Takeaway: viral peaks fade, and long-running games with deep progression keep earning.
   - Newzoo [S2] and the Q2-2026 shareholder letter back this up. In Q2 2026 the top 10 games held only about 20% of hours, down from 30% three years earlier [S12].
3. **The biggest viral hits earn mainly from developer products, not passes.**
   - Grow a Garden has a single game pass, and it is off-sale [S30]. Animal Hospital, a 2026 breakout, has zero passes [S55].
   - Steal a Brainrot has only 3 passes (2x Money, VIP, Admin Commands) [S31]. Most of its revenue comes from paid lucky blocks, Robux-only brainrots and Robux gear [S60][S61].
   - Pattern: consumables tied to a social or competitive loop (stealing, server-wide events, restock or skip) beat one-time passes for hyper-casual hits **(analysis)**.
4. **Pass price ladders cluster at the same points** **(analysis)**. Prices end in 9 or 5 at 49, 99, 149, 199, 249, 299, 349, 399, 449/450, 499, 599, 749/799, 999, 1,299-1,499, 1,999 and 2,400-3,250, plus 7,999 "whale anchors".
   - Steal a Brainrot Admin Commands and TDS Sandbox Plus+ both cost 7,999.
   - **VIP ranges from 240 to 799 Robux, with a median of about 375-400** across the 15 games sampled.
   - **2x Money ranges from 240 to 450.**
   - **Starter packs cost 49-59** (Sol's RNG, Hypershot, Rivals) or about 240 (PS99 Super Starter Pack).
5. **Roblox now runs pricing for you.**
   - Managed Pricing combines price optimization and regional pricing [S17]. New games and new items are auto-enrolled.
   - Regional prices are clamped to 30-100% of the default price [S18].
   - Reported results:
     - Price optimization gave a median earnings lift of **4%**, and over 15% for Slap Battles [S16].
     - Regional pricing raised the share of users who spend by about **17% in Mexico, 26% in Brazil and 52% in the Philippines** [S16].
   - Prices must be read dynamically through `MarketplaceService` (no hard-coded prices) to qualify [S15].
5b. **Roblox's own analytics docs** recommend first-purchase welcome offers, tiered consumables to raise ARPPU, varied price points, and seasonal items [S14].
6. **Ads are a minor revenue line.**
   - Rewarded video was expected to reach "up to 3% of your earnings" in its first months, with a long-term goal of 5-10% growth from ads products [S19].
   - Initial eligibility was 100K+ average DAU [S19]. About 140 creators were onboarded by Q3 2025 [S11].
   - Immersive ads pay per impression or teleport and need 2,000+ monthly unique visitors [S21].
   - Creator Rewards pays 5 Robux per day per qualifying Active Spender and 35% of a new or returning user's first $100 [S20].
7. **Subscriptions and platform changes for 2026:**
   - Experience subscriptions start at 49 Robux, or $2.99-$14.99 in local currency. Robux subscriptions pay 70%; local-currency subscriptions pay 70% in month one and 100% after [S22].
   - **Roblox Plus ($4.99/mo, launched April 30 2026)** replaces new Premium signups. Subscribers get 10%, then 20%, discounts on in-game items, and **Roblox covers the discount, so creators earn the same per sale** [S23].
   - Plus also pays creators up to 100 Robux per subscriber for time in paid private servers, and a 250 Robux per month acquisition bonus [S23].
   - Cross-game developer product sales were disabled from **May 30, 2026** [S24].
8. **Compliance and reputation risk is rising.**
   - The paid random items policy requires odds before purchase that sum to 100%, plus `PolicyService` gating [S25].
   - Roblox's monetization docs warn against fake discounts, inaccurate timers and high-pressure language aimed at minors [S13].
   - A May 2026 University of Sydney study found deceptive practices in 14 of the 15 Roblox games it examined [S26].
   - Grow a Garden's pay-to-steal and pay-to-grow mechanics drew public criticism [S6][S27].

---

### 1. Which Roblox games earn the most, and why

#### 1.1 Platform context (hard numbers)

| Metric | Value | Source |
|---|---|---|
| FY2025 revenue / bookings | $4.9B revenue (+36%), $6.8B bookings (+55%) | Newzoo via GameDevReports [S2] |
| Q3 2025 bookings | $1.92B (+70% YoY); DAU 151.5M; MUP 35.8M (+88%) | Q3 2025 shareholder letter [S11] |
| Q1 2026 | Bookings $1.7B (+43%), DAU 132M, MUP 31M, DevEx $423M | Q1 2026 letter [S12b] |
| Q2 2026 | Bookings $1,557M (+8%), DAU 123M (+10%), MUP 27M, DevEx $363M | Q2 2026 letter [S12] |
| DevEx rate | $0.0035 -> $0.0038 per earned Robux (+8.5%) on 2025-09-05 | [S11][S10] |
| O18 US DevEx boost | Effective rate 26.6% -> 37.8% for spend by age-checked US 18+ users (from June 8 2026) | [S12b] |
| O18 users monetize | "over 50% higher than our under 18 users" | [S12b] |
| FY2025 DevEx payouts | ~$1,503.1M to 23,500+ creators | 10-K [S10] |
| Top creators (2024) | Top 10 avg $33.9M; top 100 avg $6M; top 1,000 avg $820K; median DevEx participant $1,575 | Economic Impact Report [S8] |
| Concentration | Top game's share of visits went from 22% (Q1'25) to 43% (Q4'25) | Newzoo [S2] |
| Long tail | Q2'26: top 10 = ~20% of hours (was 30% three years ago); non-top-10 Robux spend +20% YoY | [S12] |
| Robux packs (US) | 400 = $4.99, 800 = $9.99, 1,700 = $19.99, 4,500 = $49.99, 10,000 = $99.99 | RoWatcher [S28] (secondary) |

What the numbers imply for designers **(analysis)**:
- Developers keep about 70% of the Robux a player spends. Each Robux is then worth $0.0038 at DevEx.
- So 1,000 Robux spent in your game is roughly 700 earned Robux, or about $2.66.

#### 1.2 Live "Top Earning" chart, 2026-10-07 [S29]

Rank is Roblox's own order. The player count is the CCU at fetch time.

| # | Game | Genre | CCU at fetch |
|---|---|---|---|
| 1 | Slayers 2 | Anime RPG (Demon Slayer-like) | 69,764 |
| 2 | Adopt Me! | Pet / roleplay / trading | 143,695 |
| 3 | Blox Fruits | Anime RPG | 122,353 |
| 4 | Steal An Egg | Steal-'em-up / tycoon (brainrot-like) | 1,031,270 |
| 5 | RIVALS | PvP FPS | 89,865 |
| 6 | Fisch | Fishing collection sim | 55,668 |
| 7 | Dandy's World | Horror co-op | 105,291 |
| 8 | ABA | Anime fighting | 15,685 |
| 9 | Jujutsu Shenanigans | Battlegrounds fighter | 88,114 |
| 10 | Blade Ball | PvP party / skill | 12,101 |
| 11 | Pet Simulator 99 | Pet collection sim | 52,373 |
| 12 | Grand Piece Online | Anime RPG | 17,077 |
| 13 | Sniper Arena | PvP shooter | 14,293 |
| 14 | Build the Pyramid! | Builder / incremental | 14,139 |
| 15 | Tower Defense X | Tower defense | 4,080 |
| 16 | Murder Mystery 2 | Social deduction / party | 151,964 |
| 17 | Tower Defense Simulator | Tower defense | 7,893 |
| 19 | Hypershot | PvP shooter (battle pass) | 18,454 |
| 21 | Forsaken | Asymmetric horror | 44,822 |
| 22 | Volleyball Legends | Sports | 42,404 |
| 27 | DOORS | Horror | 31,874 |
| 31 | Welcome to Bloxburg | Life-sim builder | 14,475 |
| 32 | BedWars | PvP | 19,126 |
| 38 | 99 Nights in the Forest | Survival co-op | 120,843 |
| 44 | Dress To Impress | Fashion / social | 45,985 |
| 48 | Animal Hospital | 2026 breakout | 25,420 |
| 49 | Anime Vanguards | Tower defense (gacha) | 21,374 |
| 59 | Sol's RNG | RNG | 29,425 |
| 61 | Bee Swarm Simulator | Simulator | 23,269 |
| 71 | War Tycoon | Tycoon / PvP | 5,418 |
| 72 | Brookhaven RP | Roleplay | 242,545 |
| 75 | Steal a Brainrot | Steal-'em-up | 89,562 |
| 80 | The Strongest Battlegrounds | Battlegrounds | 39,145 |
| 81 | +1 Speed Keyboard Escape | Obby / incremental | 41,832 |
| 87 | Ink Game | Party / minigame (Squid Game) | 9,183 |

What the chart shows **(analysis)**:
- **Revenue rank is not CCU rank.** Brookhaven (243K CCU) ranks #72, while Slayers 2 (70K CCU) ranks #1. Earning per player varies by 10x or more depending on genre and economy depth.
- Games games.gg called "high-playtime but under-monetized" in June 2025 (Brookhaven, 99 Nights) still rank low [S4].
- Anime RPGs, pet and trading games, and PvP cosmetic economies earn much more per player.
- The Top Earning sort is personalised by country and device, so ranks can differ by viewer (UNVERIFIED).

#### 1.3 Published estimates and records per game

| Game | Published figure | Source / confidence |
|---|---|---|
| Grow a Garden | ~$12M virtual-item sales in May 2025; peak 21.3M CCU (2025-06-21); 22.3M (2025-08-23); #1 on Top Earners by 2025-07-19 | Calcalist [S5] (original source not given, UNVERIFIED); Wikipedia [S6] |
| Grow a Garden | 12.3B visits in Q2 2025 | Newzoo [S2] |
| Steal a Brainrot | 26.4B visits in Q3 2025; passed 25M CCU in Oct 2025 | Newzoo [S2], Q3 letter [S11] |
| 99 Nights in the Forest | 10B+ visits within months | Newzoo [S2] |
| Rivals | $8-15M+/mo, 400K CCU | RoWatcher [S1] (aggregated estimate, low confidence) |
| Blox Fruits | $8-14M/mo | RoWatcher [S1] (low confidence) |
| Brookhaven | $6-12M/mo; 347K+ CCU | RoWatcher [S1] (low confidence); conflicts with its #72 earning rank [S29] |
| Adopt Me! | $5-10M/mo | RoWatcher [S1] (low confidence) |
| Pet Simulator 99 | $4-8M/mo | RoWatcher [S1] (low confidence) |
| Steal a Brainrot | $3-7M/mo | RoWatcher [S1] (low confidence) |
| Fisch | $3-6M/mo | RoWatcher [S1] (low confidence) |
| Dress to Impress | $2-5M/mo | RoWatcher [S1] (low confidence) |
| Anime Defenders | $2-5M/mo | RoWatcher [S1] (low confidence) |
| Royale High | $1.5-4M/mo | RoWatcher [S1] (low confidence) |
| Top-10 combined | "$40-90 million" per month | RoWatcher [S1] (low confidence) |

- In June 2025, games.gg ranked Grow a Garden, Rivals and Blox Fruits as the top earners, with The Strongest Battlegrounds 5th and Steal a Brainrot debuting at 11th [S4].
- No dollar figures from RoMonitor Stats, Rolimons, Bloomberg, GameRefinery or Deconstructor of Fun were found in this session. Their per-game revenue numbers, if any exist, are **UNVERIFIED** here.
- Rolimons focuses on limited-item trading values, not experience revenue (UNVERIFIED).

#### 1.4 Why the top games earn (analysis, grounded in the store data below)

- **Deep progression plus a trading economy.** Examples: Adopt Me, Blox Fruits, PS99, MM2.
  - Tradable scarce items create demand for each purchase. Adopt Me's pet-trading economy and limited-time eggs [S1]. MM2's dozens of retired Godly bundles [S36]. Blox Fruits' Robux-priced permanent fruits from 50 up to 5,000 Robux [S62].
  - Naavik calls this the "remix model": proven F2P loops (Neopets/Tamagotchi, Covet Fashion, MMORPG) re-skinned for Roblox [S7].
- **Social and competitive consumables.** Examples: Grow a Garden, Steal a Brainrot.
  - Paying to speed up or to steal from neighbours adds a social layer that classic farm sims lack [S7]. Wikipedia notes that "pay-to-steal" and loot-box pets drew criticism [S6].
- **Cosmetic-first PvP.** Examples: Rivals, Forsaken, TSB, JJS, Dandy's World.
  - Weapon bundles, wraps, keys and skins, with almost no stat power in passes [S47][S50][S51][S56][S49].
  - Rivals' biggest pass is a 1,425-Robux bundle. Its third-party-listed "Legendary Key Bundle" is 4,999 Robux [S63] (reseller page, treat with caution).
- **Luck stacking in RNG and pet games.** Example: PS99 sells eight separate stackable luck, hatch-count and drop passes from 275 to 3,250 Robux [S34].
- **Slot and QoL ladders in sports and fighting games.** Volleyball Legends sells 15 separate "Style Slot" passes from 149 to 499 [S53].
- **Live-ops cadence.** Roblox's docs recommend weekly updates as the target and monthly updates at minimum. They also recommend limited-time events and trading [S13].
  - Grow a Garden released exclusive weekly items that needed players online [S6].
  - Steal a Brainrot runs scheduled "Admin Abuse" windows (Saturdays and Tuesdays, 30 minutes, per a 2026 guide) [S60].

---

### 2. Store data for top games

The pass tables below are **live Roblox API data (2026-10-07)**. Off-sale passes are summarised.
Developer product prices come from third-party guides and may be stale (each one is labeled).
The full machine-readable version is in `top-game-products.json`.

#### 2.1 Steal a Brainrot (steal-'em-up / tycoon) [S31]
- **Passes (live):** Admin Commands **7,999** (whale anchor) · VIP **375** · 2x Money **299**.
- **Price history:** an older Deltia's guide lists 2X Money 199, VIP 199 and HD Admin 1,999 [S61]. That points to price increases over the game's life, possibly through price optimization **(analysis; the reason is UNVERIFIED)**.
- **Dev products:**
  - Robux gear: Blackhole Slap 199, Flying Carpet 499, Laser Gun 999, Ban Hammer 1,499 [S61].
  - Lucky blocks: Mythic Lucky Block 175, Brainrot God Lucky Block 599 [S60].
  - Direct brainrots: Noo La Polizia 499, Doi Doi Do 29 [S60] (April 2026).
  - "Server luck" and luck boosts are sold, but no price was found (UNVERIFIED).
- **Design notes:**
  - Combat gear gives PvP power for stealing and defending. That is pay-to-win, but it fits the chaotic tone.
  - Lucky blocks are paid random items, so odds must be disclosed [S25].

#### 2.2 Grow a Garden (farming / idle) [S30]
- **Passes (live):** only "Premium Seed Pack", which is off-sale. **Effectively passes-free.**
- **Dev products:**
  - Robux gear: Watering Can 39, Basic Sprinkler 79, Advanced 99, Godly 149, Master 199 [S64]; Grandmaster 279 [S65].
  - Seeds can be bought with Robux, from Carrot at 7 Robux upward [S66].
  - Others with unknown prices: "Forever Pack" with daily-resetting rewards starting at 37 and rising to 495, Robux seed packs and chests (gacha), pet and egg slot expansions with scaling prices, a timed starter pack, and Robux eggs [S67]. Exact prices are UNVERIFIED.
- **Design notes:**
  - Every shop item has a Robux price next to the soft-currency price. This "buy it now" pattern sits on a restocking shop.
  - The Forever Pack is a ladder that resets daily and gets more expensive, a modern "progressive offer".
  - Pay-to-steal and Robux-skip mechanics drew criticism [S6][S27].

#### 2.3 Blox Fruits (anime RPG) [S32]
- **Passes (live):** Fruit Notifier **2,700** · Dark Blade **1,200** · 2x Money 450 · 2x Mastery 450 · Fast Boats 350 · 2x Boss Drops 350.
- **Dev products:** permanent and physical fruits from **50 (Rocket) to 5,000 (Dragon)** Robux. Legendary fruits cost 1,500-2,250 [S62].
- **Design notes:**
  - The 2,700 Fruit Notifier is an information advantage priced as a whale item.
  - Doubler passes are priced at the same 450.
  - Fruit prices scale with rarity, a classic ladder.

#### 2.4 Adopt Me! (pet / roleplay / trading) [S33]
- **Passes (live, for sale):** 1.25x Candy Multiplier **50** (Halloween 2026 event) · VIP 480 · Premium Plots 285 · +1 Pet Pen Slot 295 · Cozy Home Lure 765 · Millionaire Pack 795.
- **Off-sale passes:** 18+ retired houses, vehicles and pets (Griffin, Horse, Celebrity Mansion, and others). These are rotating limited-time passes.
- **Dev products:** Bucks packs, eggs and potions are sold, but no prices could be verified (Fandom blocked). UNVERIFIED.
- **Design notes:**
  - The cheap event multiplier (50) is a low-friction first purchase tied to a live event.
  - The house packs act as high anchors.

#### 2.5 Pet Simulator 99 (pet collection) [S34]
- **Passes (live):** Huge Hunter **3,250** · Super Drops 2,400 · Double Stars 2,400 · Super Shiny Hunter 1,600 · Magic Eggs 1,200 · Ultra Lucky 800 · +15 Eggs 625 · Daycare Slots 625 · VIP 400 · +15 Pets 375 · Auto Tap 350 · Lucky 275 · Auto Farm 175.
- **Dev products:** Super Starter Pack **240**, containing a Dragon Egg, 2 potions, a hoverboard, an enchant and 2,000 diamonds (Dec 2023) [S68]. Exclusive eggs are sold; current prices UNVERIFIED.
- **Design notes:**
  - The richest luck and automation pass ladder in the sample: 13 passes from 175 to 3,250.
  - The luck passes are described as stackable, an upsell from Lucky to Ultra Lucky to Huge Hunter.
  - The cheap Auto Farm (175) is the entry pass.

#### 2.6 Brookhaven RP (roleplay) [S35]
- **Passes (live):** VIP **749** · Prison Landmark 699 · Estates Unlocked 599 · Vehicle Pack 599 · House Pets 599 · Land Unlocked 375 · Disaster Pass 375 · Premium 320 · Vehicle Customization 299 · Boat Pack 299 · Theme Pack 299 · Vehicle Boost Upgrade 199 · Vehicle Speed Unlocked 199 · Music Unlocked 199 · Penthouse 180 · Horse Upgrade 85 · On Demand Fire 40 · Vehicle Upgrade **35**.
- **Design notes:**
  - All content unlocks; no consumables are visible.
  - The ladder runs from 35 to 749. Impulse buys at 35, 40 and 85 sit next to "content packs" at 299-699.
  - The low earning rank (#72) despite the highest CCU suggests a one-time-pass-only economy caps ARPDAU **(analysis)**.

#### 2.7 Dress to Impress (fashion / social) [S37]
- **Passes (live):** VIP Pass **799** · x2 Money 399 · Queen of Hearts 399 · Moonlight Butterfly 379 · Custom Makeup 349 · Sweet Berry Set 349 · Materials+ 299 · Moongazer / Denim / Rich Girl sets 299 · French Luxury 279 · Haunting Beauty 259 · Run Faster 149 · Increased Item Limit 129.
- **Design notes:**
  - Outfit sets are sold as passes at 259-399 and rotate seasonally (Futuristic Suit is off-sale).
  - A creative-tool pass (Custom Makeup) and a slot pass (Item Limit) round out the store.

#### 2.8 Murder Mystery 2 (party / social deduction) [S36]
- **Passes (live):** BUNDLE: Beach **3,399** (Godly knife, effect and gun) · Elite 499 (1.5x XP, tag, knife, pet) · Radio 475.
- **Off-sale passes:** about 70 retired Godly knife, gun and bundle passes. Only the current seasonal bundle is ever on sale.
- **Design notes:**
  - The textbook "one limited bundle at a time" FOMO model. Retired items keep their trading value.
  - Purely cosmetic, which suits a party game where fairness matters.

#### 2.9 Blade Ball (PvP skill) [S38]
- **Passes (live):** VIP 240 · Double Coins 240 · Instant Spin **120** (skips the crate animation) · Trading Sign 112.
- **Design notes:**
  - Pays the bills through crates and cosmetic swords **(analysis; crate prices UNVERIFIED)**.
  - "Instant Spin" sells time-skip for a gacha animation, a common RNG-adjacent pass.

#### 2.10 Jailbreak (cops and robbers) [S39]
- **Passes (live):** VIP Lifetime **750** (+20% cash) · Pro Garage 450 · Crime Boss 400 · SWAT Team 400 · Duffel Bag 345 · VIP Trading 350 · Car Stereo 200.
- **Design notes:**
  - Each team gets its own pass (Crime Boss and SWAT), so both sides can pay for an edge.
  - When Jailbreak retired a pass (Extra Storage), it compensated former owners with cash, fuel and an exclusive vehicle. That is good practice for retiring a pass.

#### 2.11 Tower Defense Simulator [S40]
- **Passes (live):** Sandbox Plus+ **7,999** · Hacker 2,249 · Gatling Gun FPS 1,949 · Engineer 1,690 · Pursuit 1,500 · Mercenary Base 1,350 · Executioner [LIMITED] 799 · Warden 450 · Saboteur 449 · VIP 375 · Unwavering Tides skin bundle 360 · Cowboy / Turret early unlock 340 · Mortar / Vigilante skins 300 · Crook Boss 225 · DJ 85 · Resize 70 · Meme Emotes 55.
- **Off-sale passes:** many [LIMITED] and [LAST CHANCE] towers and skins.
- **Design notes:**
  - Premium towers are sold as passes at 1,350-2,249.
  - "Early unlock" passes (225-1,500) sell time on towers that are free to earn later.
  - Labels like "LIMITED" and "LAST CHANCE" create urgency.

#### 2.12 DOORS (horror) [S41]
- **Passes (live):** ADMIN PANEL **499** (spawn entities and items; "You CANNOT gain Knobs or any general progression with the ADMIN PANEL enabled") · KITTY BUNDLE 299 (flashlight cosmetics).
- **Design notes:**
  - The admin panel is a sandbox toy, kept separate from progression so it does not break the economy.
  - Revive purchases (UNVERIFIED price) are the classic horror developer product.

#### 2.13 Fisch (fishing collection) [S43]
- **Passes (live):** Appraise Anywhere 499 · Sell Anywhere 399 · Spawn Boat Anywhere 299 · Appraisers Luck 299 · Enchant Anywhere 239 · Double XP 239 · Supporter 169 · Emote Pack 99 · Bobber Pack 99.
- **Design notes:** this is the **"___ Anywhere" convenience pattern**. It removes a walk to an NPC, saves time, and does not break PvP.

#### 2.14 RIVALS (PvP FPS) [S44]
- **Passes (live):** Heavy Duty Bundle **1,425** · Energy Bundle 975 · Classic Bundle 865 · Standard Weapons Bundle 849 · Exogun 649 · Medkit 289 · RPG Bundle 95 · Starter Bundle **59**.
- **Dev products:** keys, wrap boxes and charm capsules. A reseller page claims the "Legendary Key Bundle" (1,100 keys, 40 charm capsules, 15 wrap boxes, and more) costs 4,999 Robux in game [S63] (UNVERIFIED secondary).
- **Design notes:**
  - A starter bundle at 59 sits next to bundles up to 1,425.
  - Weapon unlocks are earnable sidegrades. Most revenue is cosmetics.

#### 2.15 Sol's RNG (RNG) [S45]
- **Passes (live):** RNG Premium Pass - Season VIII **499** · VIP+ 350 (auto-collect, 1.2x luck) · VIP 249 (1.2x luck, daily rerolls) · Quick Roll 100 · Invisible Gear 80 · **Starter Pack 49** · Merchant Teleporter 40.
- **Off-sale passes:** Seasons I-VII premium passes and the Innovator packs.
- **Design notes:**
  - The **battle pass is implemented as a per-season game pass**, with old seasons retired.
  - VIP and VIP+ form a decoy pair: for +101 Robux, VIP+ adds auto-collect.

#### 2.16 99 Nights in the Forest (survival co-op) [S46]
- **Passes (live):** Decorator Pass 199. The Diamond Hunter, Ranger Class and Medic Class passes are off-sale.
- **Dev products:** diamond bundles are sold for Robux, but prices were not found (UNVERIFIED) [S69]. Diamonds buy classes, for example Camper 10, Medic 40, Ranger 70 and Assassin 500 diamonds [S70].
- **Design notes:**
  - Class unlocks moved from passes to a premium currency, so diamonds can be both earned and bought. This is a soft-currency bridge.

#### 2.17 Plants vs Brainrots (tower-defense idle) [S48]
- **Passes (live):** VIP 249 (+25% money) · Extra Inventory Space 149 (+150 slots).
- **Dev products:** UNVERIFIED.

#### 2.18 Slayers 2 (#1 on the live chart; anime RPG) [S47]
- **Passes (live):** Extra Slots **900** (2 character slots) · Emotes 600 · Night Market Locator 500 · Muzan/Spider Lily Locator 500 · Set Spawn Anywhere 400 · Horse Spawn Locator 120.
- **Design notes:**
  - Locator passes sell information about rare spawns at 120-500.
  - Character slots, at 900, are the top pass.

#### 2.19 Steal An Egg (#4 on the live chart) [S50]
- **Passes (live):** X2 GROWTH SPEED 467 · X2 MONEY 399. Revenue comes mostly from developer products (UNVERIFIED).

#### 2.20 Other games sampled (live passes)

| Game (genre) | Passes (Robux) | Source |
|---|---|---|
| Dandy's World (horror co-op) | Star-Time / Show-Time cosmetic packs 200 each; +2 Sticker Wheels 199; profile bundles 100 | [S49] |
| Forsaken (asymmetric horror) | V.I.P 599 (25% EXP, skins, emotes); Skin Pack #3 399; 2x Emotes 199; Emote Pack #2 175 | [S51] |
| The Strongest Battlegrounds (fighting) | Private Servers+ 499; Early Access 299; VIP 299; Kill Sound 199; Awakening Outfit / emote slots 99 | [S52] |
| Jujutsu Shenanigans (fighting) | Early Access 345; Second Emote Page 220; More Emote Slots 175; More Build Saves 125; Custom Kill Sound 120; Awakening Outfits 115 | [S54] |
| Anime Vanguards (gacha TD) | Shiny Hunter 1,299; Cosmetic Recolor 799; Display All Units 599; VIP 299 (20% summon discount); Extra Unit Storage 149 | [S42] |
| Welcome to Bloxburg (life-sim builder) | Transform Plus 600; Multiple Floors 360; Excellent Employee 300; Premium 300; Advanced Placing 250; Large Plot 250; Marvelous Mood 180; Basements 100 | [S57] |
| Hypershot (PvP shooter) | The Big Guns 975; Essential Weapons 799; Pizza Party 399; VIP 299; INFINITE Title Changes 239; Emote Pack 199; Rainbow Bullets 159; Lucky (case odds) 149; 67 Bundle 80; Starter Pack 49 | [S58] |
| Volleyball Legends (sports) | VIP 399 (2x Yen); Spin Skipping 49; Style Slot 4-18 ladder 149/299/399/499...; Ability Equip Slots 149-499; 2x Emote Slots 150 | [S53] |
| BedWars (PvP) | Kit Bundle 799; VIP Rank 400; ~45 kits at **399** each (flat price); Clan Pass 399; retired seasonal battle passes | [S56] |
| War Tycoon (tycoon / PvP) | Jets/ships 1,999; Explosive Sniper / AbramsX 1,499; Hovercraft 999; 2X CASH 299; Auto Collect 149; Double HP 199; Speedy Oil Extractor **9**; Desert Eagle 49 | [S59] |
| +1 Speed Keyboard Escape (obby / incremental) | 40+ trail and aura cosmetics from **19 to 2,645**; Wins Multiplier x2 95; More Equipped Items 299; Premium Trade Booth 159 | [S71] |
| Royale High (roleplay / fashion) | Faster Flight 299; Paintbrush 300; Crystal Ball (free cam) 300; Custom Fabrics 200; Special Fabrics 150; Sticker Packs 125; Hair Colors 100; Materials 100 | [S72] |
| Ink Game (party / minigame) | Permanent Guard 799; VIP 649 (+25% luck); Glass Manufacturer Vision 649 (see the glass bridge answer); Private Server+ 499; 2x Vote Count 249 | [S73] |
| Animal Hospital (2026 breakout) | **No game passes**; revenue from developer products (UNVERIFIED) | [S55] |
| Bee Swarm Simulator | API shows its 4 classic passes (x2 Ticket Chance, Bear Bee, x2 Pollen, x2 Convert Speed) as **not for sale** on 2026-10-07; reason UNVERIFIED | [S42b] |

#### 2.21 What is sold: frequency across the sample (analysis)

| Product archetype | Examples (price) | Prevalence |
|---|---|---|
| VIP (bundle of small perks plus tag) | 240-799; median ~375-400 | Almost every game |
| Currency doubler (2x Money / Coins / Yen) | 240-450 | Sims, tycoons, PvP |
| XP or mastery doubler | 239-450 | RPG, fishing |
| Luck multiplier (stackable) | 149-3,250 | Pet, RNG, gacha TD, shooter cases |
| Auto-farm / auto-collect / auto-tap | 149-350 | Pet, tycoon, RNG |
| Inventory / slot / storage expansion | 129-900 | RPG, TD, life-sim, sports |
| "Anywhere" convenience (sell / teleport / spawn) | 239-499 | Fishing, RPG, driving |
| Locator / notifier (info on rare spawns) | 40-2,700 | RPG, RNG |
| Animation skip (instant spin / quick roll) | 49-120 | RNG, crate games |
| Admin / sandbox toy | 499 (DOORS), 7,999 (SaB, TDS) | Whale anchor |
| Premium content unit (tower, kit, vehicle) | 225-2,249 | TD, PvP, tycoon |
| Cosmetic sets and bundles | 19-3,399 | All; dominant in PvP, horror, fashion |
| Starter pack | 49-59 (240 for PS99) | RNG, shooters, pet |
| Seasonal battle pass (as a game pass) | 499 (Sol's), Hypershot, BedWars | RNG, PvP |
| Event multiplier | 50 (Adopt Me Candy) | Live-event games |
| Private server plus / custom rules | 499 | Fighting, party |
| Emote slots or pages | 99-220 | Fighting, horror |
| Robux shortcuts on soft-currency items | 7-279 per item (Grow a Garden) | Hyper-casual viral hits |
| Paid random items (lucky blocks, eggs, crates) | 175-599 (SaB lucky blocks) | Brainrot, pet, PvP |

#### 2.22 Price ladders and anchoring (analysis from the live data)

- **The common ladder** is 49 / 99 / 149 / 199 / 249 / 299 / 399 / 499 / 599 / 799 / 999 / 1,499 / 1,999 / 2,499 / 3,250 / 7,999.
  - Prices end in 9 almost everywhere. Brookhaven and Adopt Me also use 5-endings (285, 295, 375, 765, 795).
  - DevForum advice says to align prices with standard Robux pack sizes instead of odd numbers like 439 [S74] (single forum thread, low-confidence advice).
- **Anchors.**
  - One extreme item at 2,400-7,999 makes mid-tier passes look cheap: SaB Admin 7,999, TDS Sandbox Plus+ 7,999, PS99 Huge Hunter 3,250, MM2 bundle 3,399, Blox Fruits Fruit Notifier 2,700.
  - These anchors are toys or status items, not core power, which limits pay-to-win backlash.
- **Decoys.**
  - Sol's RNG VIP 249 against VIP+ 350. PS99 Lucky 275 against Ultra Lucky 800. Brookhaven Premium 320 against VIP 749.
  - The pairs are set up so the upper tier looks like the better deal.
- **Flat pricing for catalog-like content.** BedWars prices about 45 kits at 399 each, so a purchase never feels like a pricing decision.
- **Slot ladders.** Volleyball Legends' style slots go 149 / 299 / 399 / 499 / 499 / ..., so each extra slot is a separate pass.
- **Impulse floor.** Items at 9-59 lower the first-purchase barrier: War Tycoon Speedy Oil Extractor 9, Sol's Starter 49, Hypershot Starter 49, Rivals Starter 59, Brookhaven 35/40, Adopt Me 50.
- **"Best value" tags.** No sampled pass names include "BEST VALUE". The tags live in in-game UI, which the API cannot see (UNVERIFIED for specific games). Pass names do use urgency labels, such as TDS "[SUPER DEAL]", "[LAST CHANCE]" and "LIMITED".

---

### 3. Shop UX patterns, conversion drivers and anti-patterns

#### 3.1 Roblox's official guidance
- **Plan monetization before launch.** Offer both consumables and durables, and design the storefront with the same care as gameplay [S14].
- **To raise conversion:** remove barriers (high prices, poor visibility, unappealing offers), add **welcome or first-purchase discounts**, and audit the purchase funnel [S14].
- **To raise ARPPU:** offer tiered options, including repeatable consumables, plus seasonal items [S14].
- **To raise ARPDAU:** offer diverse price points and invest in retention [S14].
- **Player types:** "Tourists" want variety and instant gratification. "Locals" value long-term benefits such as battle passes. Social features, limited-time events and trading drive success. Live ops should be weekly where possible and monthly at minimum [S13].
- **No deceptive practices:** discounts must be genuine, timers accurate, and high-pressure language minimised, especially for minors [S13].
- **Native Shop surface:**
  - Roblox has a built-in Experience Shop in the in-game menu and an optional **global Shop button in the upper-left next to the top bar**. Roblox recommends turning it on [S24b].
  - Passes are always listed there. Developer products can be Listed or Unlisted. Listed products can appear on other Roblox surfaces, but only if `ProcessReceipt` is correctly implemented, and Roblox checks this continuously [S24][S24b].
- **Personalised ranking:** `MarketplaceService:RankProductsAsync()` and `RecommendTopProductsAsync()` return personalised product orderings [S24]. Use them to sort your shop.
- **Since May 30 2026,** cross-game developer product sales are disabled [S24].

#### 3.2 Patterns seen in top games (analysis plus sources where noted)

| Pattern | What it is | Seen in |
|---|---|---|
| Robux price next to soft price | Each shop item shows both prices; one tap to "buy now" | Grow a Garden gear and seeds [S64][S66] |
| Progressive daily offer | A pack ladder that resets each day and rises in price | Grow a Garden "Forever Pack", 37 -> 495 [S67] |
| Timed starter pack | Cheap one-time offer for new players | Grow a Garden [S67]; Sol's 49; Hypershot 49; Rivals 59; PS99 240 [S45][S58][S44][S68] |
| One limited bundle at a time | A single seasonal bundle on sale; older ones retired | MM2 [S36], Adopt Me [S33], TDS [S40] |
| Event-tied cheap multiplier | Bonus currency during an event at a trivial price | Adopt Me 1.25x Candy 50 [S33] |
| Scheduled server-wide events | Fixed "Admin Abuse" windows that concentrate CCU and spending | Steal a Brainrot (Sat/Tue, 30 min) [S60] |
| Seasonal pass as a game pass | A new pass ID each season; the old one goes off-sale | Sol's RNG [S45], BedWars [S56], Hypershot [S58] |
| Animation skip | Paying to skip the gacha or crate reveal | Blade Ball 120, Sol's 100, Volleyball 49 |
| Contextual "anywhere" passes | Offered where friction happens (the walk to the merchant) | Fisch [S43], Slayers 2 [S47], Jailbreak Pro Garage [S39] |
| Sandboxed admin | Fun power isolated from progression | DOORS ADMIN PANEL (no Knobs gained) [S41] |
| Retirement compensation | Paying owners back in items when a pass is retired | Jailbreak Extra Storage [S39] |

These are common practice but have **no source in this session (UNVERIFIED)**:
- Left-side HUD shop buttons
- Offer popups on join
- A revive prompt on death (horror, obby)
- A skip-stage prompt on obbies
- A "not enough coins" popup that opens the currency pack
- Gifting through separate "gift" developer products, one per item. Third-party services sell Rivals bundles as gifts, which suggests gifting exists in Rivals [S63].

#### 3.3 Subscriptions, private servers, Roblox Plus
- **Experience subscriptions:**
  - Robux subscriptions start at 49 Robux. Local-currency tiers are $2.99, $4.99, $7.99, $9.99 and $14.99.
  - Robux subscriptions pay 70%. Local-currency subscriptions pay 70% in month one and **100% after** [S22].
  - You must offer the same benefits on every platform, keep benefits for the whole term, and not gate them behind unpaid tasks [S22].
  - When subscriptions launched in Nov 2023, developers complained about the payout ratio and region exclusions [S22b].
  - No public results on subscription revenue were found (UNVERIFIED).
- **Roblox Plus (April 30 2026, $4.99/mo):**
  - Subscribers get 10% off in-game items, rising to 20% from the third month. **Roblox absorbs the discount, so creators earn the same per item.**
  - It includes free private servers in supported games.
  - Creators earn up to 100 Robux per subscriber who spends 60+ minutes a month in paid private servers.
  - Creators earn **250 Robux per new Plus subscriber acquired through the in-game API**, for up to 3 months (750 maximum).
  - Premium signups are discontinued [S23].
  - Design takeaway **(analysis)**: support private servers and add the Plus upsell API. The bonus is a real side revenue.

#### 3.4 Anti-patterns and rule risks

1. **Paid random items without odds** [S25]. This covers direct Robux rolls and also rolls paid with currency bought with Robux, capsules, enhancement and combination mechanics, and probability modifiers.
   - Show odds as percentages that sum to 100% **before purchase**. Use a clearly labelled "Info" or "Details" pop-up when the list is long.
   - Update odds dynamically when probability modifiers are active.
   - When `PolicyService:GetPolicyInfoForPlayerAsync().ArePaidRandomItemsRestricted` is true, offer an alternative: an earnable path, a fixed sequence, a direct purchase, or hide or block the feature.
   - `IsPaidItemTradingAllowed` restricts trading of paid outcomes.
   - Free random rewards (a found key opening a chest) need no odds.
2. **Misleading pricing and pressure** [S13][S26].
   - Fake "was" prices, inaccurate countdowns, near-miss visuals, and loss-triggered pressure prompts.
   - The Sydney study flagged these in 14 of 15 games and is pushing for regulator involvement.
3. **Pay-to-win in competitive PvP.**
   - The top PvP earners keep passes mostly cosmetic or sidegrade (Rivals, Forsaken, TSB, JJS, Dandy's World).
   - Pay-to-steal and pay-to-grow drew press criticism of Grow a Garden [S27].
   - Specific review-bombing incidents for named games were **not found (UNVERIFIED)**.
4. **Hard-coded prices.** They disqualify you from price optimization and regional pricing [S15][S18].
5. **Broken `ProcessReceipt`.** Your developer products get pulled from external surfaces [S24].
6. **Subscription benefit changes mid-term, or benefits that differ by platform.** Both are prohibited [S22].
7. **Directing users to buy off-platform, or cross-trading for real money.** Both are prohibited [S22][S75].
8. **Retiring paid passes without compensation.** Jailbreak shows the remedy [S39].

---

### 4. Genre-by-genre recommended monetization sets

Built from the live store data above **(analysis)**. Prices are suggested starting points. Let Managed Pricing tune them [S17].
"GP" = game pass, "DP" = developer product.

| Genre | Core GPs (suggested Robux) | Core DPs | Avoid / notes |
|---|---|---|---|
| **Simulator (clicker/collect)** | VIP 299-399; 2x Currency 249-399; Auto-Collect/Auto-Tap 149-349; +Storage 149; Faster Walk 99 | Currency packs (ladder 49/99/249/499/999/2,499); 15/30/60-min boosts; rebirth skip | Model on PS99's stacking ladder [S34]; offer a 49 starter pack |
| **Tycoon** | 2x Cash 299 (War Tycoon) [S59]; Auto Collect 149; premium droppers/vehicles 199-1,999; VIP 249 | Cash packs; instant build; "Speedy extractor" style 9-49 impulse buys | Premium weapons in PvP tycoons attract complaints; keep them sidegrades |
| **Obby** | Cosmetic trails/auras 19-2,645 (Keyboard Escape) [S71]; Wins x2 95; Gravity/Speed coil 99-149; VIP 199 | **Skip stage** 15-49; checkpoint save; revive/no-reset 15-25 (UNVERIFIED prices) | Keep a free path to every stage; skips are the bread-and-butter DP |
| **Tower defense** | Premium towers 450-2,249; early-unlock towers 225-1,500 (TDS) [S40]; VIP 299-375; Extra unit storage 149; Shiny/Luck 1,299 (AV) [S42]; Sandbox anchor 7,999 | Summon currency (gems) packs; summon x10 bundles; wave skip; revive base | Gacha summons are paid random items: disclose odds and check PolicyService [S25] |
| **RPG / anime fighter** | 2x Money/Mastery/Drops 350-450; Locators 120-2,700; Extra slots 900; Spawn anywhere 400 (Blox Fruits, Slayers 2) [S32][S47] | Direct rare item buys (Blox Fruits fruits 50-5,000) [S62]; stat reset; race/trait reroll | Highest earning per player in the chart; gate PvP power carefully |
| **Horror** | Cosmetic packs 200-399; VIP 599 (Forsaken) [S51]; admin/sandbox panel 499 that disables progression (DOORS) [S41]; emote slots 199 | **Revive** (contextual on death); extra items or lives; "knobs" currency packs | Do not sell survival power in matchmade PvP horror (Forsaken stays cosmetic) |
| **Roleplay / life-sim** | VIP 499-799; content packs (houses/vehicles/pets) 299-699; creative tools 100-600 (Brookhaven, Bloxburg, Royale High) [S35][S57][S72]; cheap fun toggles 35-85 | Currency for furniture; limited-time house/vehicle drops | One-time passes alone cap ARPDAU (Brookhaven's rank); add rotating limited drops and a currency sink |
| **PvP shooter** | Starter 49-59; weapon bundles 95-1,425 (Rivals) [S44]; VIP 299; Lucky (case luck) 149; seasonal battle pass | Keys/cases (odds required); wraps; charm capsules | Cosmetic-only or earnable sidegrades; never paid stat power |
| **Fighting / battlegrounds** | Early Access 299-345; emote slots/pages 99-220; kill sound 120-199; awakening outfit 99-115; Private Servers+ 499 (TSB, JJS) [S52][S54] | Cosmetic emotes; character unlock currency | Expression and QoL monetize well with no balance impact |
| **Racing / driving** | Car packs 299-1,999; speed upgrade 35-199 (Brookhaven vehicle passes as reference) [S35]; garage-anywhere 450 (Jailbreak) [S39]; customization 299 | Cash packs; individual limited cars | UNVERIFIED for racing-specific titles; no racing game was sampled |
| **Survival** | Decorator/base pass 199 (99 Nights) [S46]; class unlocks; extra storage | Premium currency (diamonds) that buys classes [S70]; revive | A currency bridge lets free players earn the same classes |
| **Social hangout** | VIP 299-499; radio/DJ 85-475 (MM2 Radio 475, TDS DJ 85) [S36][S40]; custom tags 199; emotes | Tips/donations (UNVERIFIED pattern); limited cosmetics | Keep it cheap and expressive; private server support for Roblox Plus revenue [S23] |
| **Pet / collection** | Luck tiers 275/800/3,250; auto-farm 175; +Eggs/+Pets 375-625; slot passes 295 (PS99, Adopt Me) [S34][S33] | Eggs (odds), potions, currency, starter pack 240 | The trading economy multiplies value; respect `IsPaidItemTradingAllowed` [S25] |
| **RNG / gacha** | Starter 49; VIP 249 / VIP+ 350 decoy pair; Quick Roll 100; season premium pass 499 (Sol's RNG) [S45] | Luck potions; server-wide luck boosts (SaB-style); roll bundles | Odds disclosure is mandatory; dynamic odds when boosted [S25] |
| **Idle / clicker / incremental** | 2x speed/growth 399-467 (Steal An Egg) [S50]; auto-collect; offline earnings x2 (UNVERIFIED) | Time skips; Robux price beside every shop item (Grow a Garden) [S64]; progressive daily packs [S67] | Grow a Garden shows a passes-free, all-DP model can top the chart |
| **Sports** | VIP 399 (2x Yen); style/ability slot ladders 149-499; spin skip 49 (Volleyball Legends) [S53] | Style/ability spins (gacha, odds required) | The slot ladder is the main ARPPU engine |
| **Party / minigame** | VIP 649; Private Server+ 499; vote x2 249 (Ink Game) [S73]; bundles (MM2 3,399) [S36] | Cosmetic crates; round effects | Info passes like "Glass Vision" 649 [S73] are pay-to-win; use carefully |
| **Puzzle** | Hints pass 99-199; level pack unlocks 149-299; cosmetics (UNVERIFIED; no puzzle game sampled) | Hint and skip consumables 10-25 | Low ARPPU genre; consider rewarded video for hints [S19] |

---

### 5. Ads, Creator Rewards, subscriptions and price optimization results

| Program | Mechanics | Published results | Source |
|---|---|---|---|
| **Rewarded video ads** | Developer chooses the reward, value, placement and frequency; shown to 13+ only; paid by EPM x impressions; better EPM at 90%+ completion and minimal maturity | "Up to 3% of your earnings" in the first months; long-term ads goal of 5-10% revenue growth; ~100 publishers by Jul 2025 (incl. Brookhaven, Driving Empire); 140+ by Q3 2025; Q1 2026 letter says "strong results" | [S19][S20b][S11][S12b] |
| Rewarded video eligibility | Initially 100K+ avg DAU over 28 days, minimal or mild maturity, ad-publisher status; broader rollout planned | Developers complained about low expected earnings and the DAU bar | [S19] |
| **Immersive ads** | Image / video / portal billboards; 13+ creator, ID-verified, 2FA, 2,000+ monthly unique visitors; paid per impression, per 15s view, or per teleport; billboards 8-32 studs wide | 2024 Naavik: the top 50 developers got ~1% of revenue from immersive ads | [S21][S21b] |
| **Ads Manager (buying traffic)** | Cost-per-play campaigns | ~18,000 creators used it in Q3 2025; cost per play -30% QoQ; 45,000+ experiences used it in 2025; 60+ of the top 100 creators by spend use it (Q1 2026) | [S11][S9][S12b] |
| **Creator Rewards** (from 2025-07-24; replaced Engagement-Based Payouts and Affiliates) | 5 Robux/day when your game is among the first 3 an Active Spender (spent $9.99+ in 60 days) plays for 10+ minutes; 35% of the first $100 spent by new or reactivated users you bring in (needs 100+ DAU for 60 days, ID-verified, DevEx account) | No aggregate payout number found (UNVERIFIED) | [S20] |
| **Experience subscriptions** | 49+ Robux or $2.99-$14.99 local currency; 70% / 70%->100% payout | No public results found (UNVERIFIED) | [S22][S22b] |
| **Roblox Plus** | Platform subscription $4.99; Roblox-funded discounts; creator private-server and acquisition bonuses | Too new for results (UNVERIFIED) | [S23] |
| **Price optimization** | Randomised price tests; needs 60,000+ transactions in 30 days; tests at least every 90 days; prices applied only if they raise total revenue | **Median +4% earnings**; Slap Battles **+15%+** | [S15][S16] |
| **Regional pricing** | Passes on by default; developer products opt-in (needs `GetUsersPriceLevelsAsync`); price = 30-100% of default; subscriptions and private servers auto-regionalised | Payer share up ~17% (MX), ~26% (BR), ~52% (PH); median lift across countries 26%; drove "significant" payer growth in Indonesia | [S16][S18][S11] |
| **Managed Pricing** | Optimization and regional pricing under one opt-in; auto-enrols new games and items | Dashboard shows revenue impact; no aggregate number | [S17] |

What this means for designers **(analysis)**:
- Ads add a few percent at most. The real money is in passes and developer products tuned with Managed Pricing.
- Use rewarded video mainly for non-payers: free revive, extra spin, 2x a reward.
- Add Plus-compatible private servers.

---

### Sources (all fetched 2026-10-07)

- [S1] RoWatcher, "The 10 Highest-Earning Roblox Games in 2026" - https://rowatcher.com/news/the-10-highest-earning-roblox-games-in-2026-and-what-they-mean-for-the-platform
- [S2] GameDevReports / Newzoo, "Top Roblox Games in 2025" - https://gamedevreports.substack.com/p/newzoo-top-roblox-games-in-2025
- [S4] games.gg, "Roblox top earning games in June 2025" - https://games.gg/hi/news/roblox-top-earning-games-in-june-2025/
- [S5] Calcalist (CTech), Grow a Garden - https://www.calcalistech.com/ctechnews/article/dj4lxef8r
- [S6] Wikipedia, Grow a Garden - https://en.wikipedia.org/wiki/Grow_a_Garden
- [S6b] Legit.ng (AFP), Grow a Garden numbers - https://www.legit.ng/business-economy/economy/1661580-robloxs-grow-a-garden-explodes-online-video-game-numbers/
- [S7] Naavik, "Predicting the Next Big Hits on Roblox" (2025-07-06) - https://naavik.co/digest/predicting-the-next-big-hits-on-roblox/
- [S8] Roblox, Annual Economic Impact Report (2025-09) - https://about.roblox.com/newsroom/2025/09/roblox-annual-economic-impact-report
- [S8b] Outlook Respawn, top developers average $33.9M - https://respawn.outlookindia.com/gaming/gaming-news/robloxs-top-developers-average-339-million-in-annual-earnings
- [S9] Roblox, RDC 2025 announcements - https://about.roblox.com/newsroom/2025/09/roblox-rdc-2025
- [S10] Roblox FY2025 Form 10-K - https://www.sec.gov/Archives/edgar/data/1315098/000131509826000024/rblx-20251231.htm
- [S11] Roblox Q3 2025 shareholder letter - https://www.sec.gov/Archives/edgar/data/1315098/000131509825000326/ex991-q32025shareholderl.htm
- [S12] Roblox Q2 2026 shareholder letter - https://www.sec.gov/Archives/edgar/data/0001315098/000162828026051059/ex991-robloxq22026earnin.htm
- [S12b] Roblox Q1 2026 shareholder letter - https://www.sec.gov/Archives/edgar/data/0001315098/000162828026028882/ex991-q12026earningsshar.htm
- [S13] Roblox Creator Docs, Monetization overview - https://create.roblox.com/docs/en-us/production/monetization (and .md)
- [S13b] Roblox Creator Docs, Get started: monetization - https://create.roblox.com/docs/en-us/get-started/monetization.md
- [S14] Roblox Creator Docs, Monetization analytics - https://create.roblox.com/docs/en-us/production/analytics/monetization
- [S15] Roblox Creator Docs, Price optimization - https://create.roblox.com/docs/en-us/production/monetization/price-optimization
- [S16] Roblox Newsroom, Regional pricing launch (2025-04-22) - https://about.roblox.com/newsroom/2025/04/roblox-launches-regional-pricing-for-in-experience-items
- [S17] Roblox Creator Docs, Managed pricing - https://create.roblox.com/docs/en-us/production/monetization/managed-pricing
- [S18] Roblox Creator Docs, Regional pricing - https://create.roblox.com/docs/en-us/production/monetization/regional-pricing
- [S19] DevForum, "More Creators Can Now Use Rewarded Video Ads" (2025-07-24) - https://devforum.roblox.com/t/more-creators-can-now-use-rewarded-video-ads/3838678
- [S20] Roblox Creator Docs, Creator Rewards - https://create.roblox.com/docs/en-us/creator-rewards
- [S20b] PPC Land, Roblox rewarded video launch - https://ppc.land/roblox-expands-google-advertising-partnership-with-rewarded-video-launch/
- [S21] Roblox Creator Docs, Immersive ads - https://create.roblox.com/docs/en-us/production/monetization/immersive-ads
- [S21b] Naavik, "Solving Roblox's Ads Problem" (2024-01-31) - https://naavik.co/digest/solvng-roblox-ads-problem/
- [S22] Roblox Creator Docs, Subscriptions - https://create.roblox.com/docs/en-us/production/monetization/subscriptions
- [S22b] DevForum, "Subscriptions within experiences: Now available" (2023-11-15) - https://devforum.roblox.com/t/2702306
- [S23] Roblox Newsroom, Introducing Roblox Plus (2026-04) - https://about.roblox.com/en-au/newsroom/2026/04/introducing-roblox-plus-subscription
- [S24] Roblox Creator Docs, Developer products - https://create.roblox.com/docs/en-us/production/monetization/developer-products.md
- [S24b] Roblox Creator Docs, Shop - https://create.roblox.com/docs/en-us/production/monetization/shop
- [S25] Roblox Creator Docs, Paid random items policy - https://create.roblox.com/docs/en-us/production/monetization/paid-random-items
- [S26] University of Sydney, "Inside the pay-to-play world of Roblox" (2026-05-17) - https://www.sydney.edu.au/news-opinion/news/2026/05/17/inside-the-pay-to-play-world-of-roblox-targeting-children-.html
- [S27] Multiplayer.it, Jacob Navok on Grow a Garden (2025-07-18) - https://multiplayer.it/notizie/grow-a-garden-su-roblox-e-un-gioco-maligno-in-cui-si-paga-per-ogni-cosa-per-un-ex-square-enix.html
- [S28] RoWatcher, Robux prices 2026 - https://rowatcher.com/news/robux-prices-bundles-2026-guide
- [S29] Roblox Explore API, Top Earning sort - https://apis.roblox.com/explore-api/v1/get-sort-content?sessionId=1&sortId=top-earning&cpuCores=8&maxResolution=1920x1080&maxMemory=8192&networkType=wifi&device=computer&country=us
- Game pass API pages, all of the form `https://apis.roblox.com/game-passes/v1/universes/{id}/game-passes?passView=Full&pageSize=100`:
  - [S30] Grow a Garden 7436755782
  - [S31] Steal a Brainrot 7709344486
  - [S32] Blox Fruits 994732206
  - [S33] Adopt Me 383310974
  - [S34] Pet Simulator 99 3317771874
  - [S35] Brookhaven 1686885941
  - [S36] Murder Mystery 2 66654135
  - [S37] Dress to Impress 5203828273
  - [S38] Blade Ball 4777817887
  - [S39] Jailbreak 245662005
  - [S40] Tower Defense Simulator 1176784616
  - [S41] DOORS 2440500124
  - [S42] Anime Vanguards 5578556129
  - [S42b] Bee Swarm Simulator 601130232
  - [S43] Fisch 5750914919
  - [S44] RIVALS 6035872082
  - [S45] Sol's RNG 5361032378
  - [S46] 99 Nights in the Forest 7326934954
  - [S47] Slayers 2 5595353122
  - [S48] Plants vs Brainrots 8316902627
  - [S49] Dandy's World 5569032992
  - [S50] Steal An Egg 10563114921
  - [S51] Forsaken 6331902150
  - [S52] The Strongest Battlegrounds 3808081382
  - [S53] Volleyball Legends 6931042565
  - [S54] Jujutsu Shenanigans 3508322461
  - [S55] Animal Hospital 10148749921
  - [S56] BedWars 2619619496
  - [S57] Welcome to Bloxburg 88070565
  - [S58] Hypershot 5995470825
  - [S59] War Tycoon 1526814825
  - [S71] +1 Speed Keyboard Escape 9584852943
  - [S72] Royale High 321778215
  - [S73] Ink Game 7008097940
- Universe IDs were resolved through `https://apis.roblox.com/universes/v1/places/{placeId}/universe`.
- [S60] BuffGet, "Steal a Brainrot Robux Guide" (2026-04-08) - https://buffget.com/news/steal-a-brainrot-robux-guide-boosters-and-rare-auras
- [S61] Deltia's Gaming, Steal a Brainrot gear and game passes - https://deltiasgaming.com/roblox-steal-a-brainrot-all-gear-and-game-passes
- [S62] AllThings.How, Blox Fruits fruit Robux prices (Aug 2026) - https://allthings.how/blox-fruits-fruit-values-and-robux-prices/
- [S63] Timesaver.gg, Rivals Legendary Key Bundle (third-party reseller) - https://timesaver.gg/products/roblox-rivals-legendary-key-bundle
- [S64] Sportskeeda, Grow a Garden gear guide - https://www.sportskeeda.com/roblox-news/grow-garden-gear-guide-all-gears
- [S65] RBLXGuide, Grow a Garden shops - https://rblxguide.com/games/grow-a-garden/shops
- [S66] GrowAGardenCalculator, Carrot - https://www.growagardencalculator.io/values/carrot
- [S67] MitchCactus, "Do you need Robux for Grow a Garden?" (2025-08-16) - https://mitchcactus.co/blog/grow-a-garden/do-you-need-robux-for-grow-a-garden/
- [S68] Pro Game Guides, PS99 Super Starter Pack - https://progameguides.com/roblox/is-the-super-starter-pack-worth-it-in-pet-simulator-99-roblox/
- [S69] esports.gg, Diamonds in 99 Nights in the Forest - https://esports.gg/news/roblox/diamonds-99-nights-in-the-forest/
- [S70] Sportskeeda, 99 Nights classes costs - https://www.sportskeeda.com/roblox-news/all-classes-99-nights-forest-costs-perks-upgrades
- [S74] DevForum, "Help on optimizing monetization" (2026-03-18) - https://devforum.roblox.com/t/help-on-optimizing-monetization/4526613
- [S75] DevForum, "Shop Maker Pro - Implementing Secure Gifting Support" (2026-01-11) - https://devforum.roblox.com/t/tutorial-shop-maker-pro-implementing-secure-gifting-support/4245440

**Sources that could not be accessed:**
- All `*.fandom.com` wiki pages (HTTP 402) and BreezeWiki mirrors (captcha or access denied).
- U7Buy and The Filibuster Blog (HTTP 403).
- RoMonitor Stats, Rolimons, Bloomberg, GameRefinery and Deconstructor of Fun were not reached or yielded no per-game revenue in this session.

## Part 2. Ads: self-serve Ads Manager for your own experience

All sources fetched 2026-10-07. Every claim carries a source tag such as [S1]; the full list is in **Sources** at the end.

**How to read the labels**
- **OFFICIAL**: Roblox Creator Docs (create.roblox.com/docs, read from the `Roblox/creator-docs` GitHub source at `main`), the Roblox Help Center, Roblox newsroom posts, or DevForum posts written by Roblox staff.
- **COMMUNITY**: DevForum posts by developers, and third-party blogs or vendors. These are anecdotes, not policy.
- **UNVERIFIED**: claims I could not confirm in an official source, or that come from one low-reliability source.
- **CONFLICT**: places where official sources disagree. Check the live Ads Manager UI before you rely on these.

> Scope note: we never buy ads. This report only supports preparing creatives and campaign plans. Everything below about spending and budgets is descriptive.

---

### 1. Executive summary

1. **There is one self-serve product, Ads Manager** (`create.roblox.com/advertise`). A campaign "sponsors" your game, and the creative is a **16:9 thumbnail** shown in the **Sponsored** row on Home *and* in Search. Since Nov 2025, Home and Search run as one combined campaign and keyword search ads are gone [S1][S12]. Brands buy video, rewarded video, billboards, portals and Home takeovers through Roblox or Google rather than through self-serve [S6][S16].
2. **Bidding is automated cost-per-play (CPP).** You set a budget (daily or lifetime), a start time and a duration, and Roblox sets the bids. You get no manual CPM or CPC bid [S1][S10]. Games that are engaging get "ads system discounts" [S1].
3. **Minimums.** You must convert at least 1 ad credit. A campaign needs at least **10 ad credits** [S12]. Since Sep 2025, **1 ad credit = 263 Robux**, down from 285 [S14]. Community posts put one credit at about US$1 [S20] (UNVERIFIED as an exact figure).
4. **Campaign goals:** **Plays**, **Earnings** (limited), and **Engagement**. Engagement targets age-checked highly engaged players, who count toward the **Roblox Kids and Select** threshold [S1][S18].
5. **Audiences:** All, New (180+ days since last play), Recent (last 30 days; needs 10K+ recent players), and Lapsed (30-180 days; needs 20K+). **Advanced targeting** covers location (country), age group, gender, genre and device type [S1][S13]. **Users under 18, and anyone who opted out of data sharing, do not get personalized ads** [S13][S5].
6. **Creatives:** up to 10 thumbnails per campaign in the docs, 25 per a May 2026 staff post (CONFLICT, see §4) [S1][S15]. The docs say thumbnails are "evenly distributed" [S1]. An Aug 2025 staff post announced automated budget shifting toward the best creatives [S11]. Ads Manager can also generate 3 thumbnail variants with AI [S1].
7. **Moderation:** Roblox aims to review each ad within 24 hours, and the asset library within 48 hours. Rejected assets can be appealed [S1]. The rules are the **Advertising Standards**: no "free Robux" claims, no deception, no URLs or QR codes pointing to unapproved sites, English only for self-serve ads, and a long list of banned categories [S5].
8. **Ads and Recommended for You (RFY):** ads can *speed up* consideration for RFY. However, "Roblox doesn't count the engagement, monetization, or retention of users first acquired from ads ... in the ranking stage of Recommended for You" [S7]. Paid players do not move your RFY rank. Only RFY-acquired players do.
9. **Official CPP benchmarks (Nov 11, 2025):** Plays $0.0073, Retention $0.0113, Reactivate $0.011, Acquire New Users $0.0187 [S12]. Roblox said in Sep 2025 that users can be acquired "for less than $0.01" [S14]. Developers also reported price spikes of 2-3x in Oct 2025 [S21].
10. **Creative playbook (official and community):** accurate gameplay, unique art, distinct concepts per test, and refreshing creatives for updates. Hypershot scaled from 10 to 25 creatives and paused the losers. Sponsored ads now bring up to 10% of its plays [S17][S8][S9].

---

### 2. Products and placements

| Product | Who can buy | Placement | What the advertiser pays for | Status (Oct 2026) | Source |
|---|---|---|---|---|---|
| **Sponsored game (Ads Manager)** | Any creator 13+ with a verified email | Home "Sponsored" sort, plus Search results (combined since Nov 2025) | Auto-bid; reported as CPP | Live; the core self-serve product | OFFICIAL [S1][S12] |
| Sponsored sort position | n/a | Row 2-10 of Home, chosen dynamically per user | n/a | Since Aug 2025 (staff estimate: +13.4% quality plays) | OFFICIAL [S11] |
| **Search ads (keyword)** | Formerly self-serve | Top of search results, exact keyword match, up to 10 keywords per ad set, 13+ only, no targeting | Second-price eCPM auction plus $0.01 | **Superseded.** Search was folded into the combined campaign and the classic flow was sunset. The `search-ads` doc page is stale | OFFICIAL [S3][S12] |
| **Portal ads (advertiser side)** | Formerly in the classic flow | A teleport door inside other creators' games | Per teleport | The docs still list "immersive portal ad campaigns" [S2]. In Mar 2025 portals were "classic only" [S10]. Self-serve availability after the classic sunset is **UNVERIFIED** | OFFICIAL [S2][S4][S10] |
| **Feature Tile (managed beta)** | Selected creators via sign-up form | A prominent Home placement | Minimum **US$5K** | Managed beta since May 2026 | OFFICIAL [S15] |
| Sponsored Takeovers / Premium Home ads (24h) | Brands (direct) | Home | Direct deal | Listed in acquisition analytics, not self-serve | OFFICIAL [S19][S16] |
| Billboards (image/video) and rewarded video | Brands via Roblox direct IO or Google Ad Manager | Inside other creators' games | Image impression, video impression, 15s view (CPV15) | Not self-serve for creators. Creators *earn* from these | OFFICIAL [S4][S6][S16] |
| Sponsored items | Creators | Marketplace | n/a | Separate product, out of scope | OFFICIAL [S2] |

**Takeaway for planning:** the only paid lever we would realistically prepare for is a **Sponsored game campaign**, whose creative is a set of 16:9 thumbnails. "Video ads" and "rewarded video" are formats we would *host* (publisher side), not formats we buy.

---

### 3. Campaign setup: goals, audiences, targeting, budgets, scheduling

#### 3.1 Requirements
- You must be 13+ with a verified email [S1].
- Card payment is for users 18+. Roblox places a temporary $1.00 hold to verify the card [S1]. First-time card users are charged $5 when they submit a campaign, credited toward the first bill [S1].
- Any user 13+ can convert Robux to ad credits. **The conversion is irreversible** [S1].
- Group-owned games: the "Create Ad campaigns for the group" permission is needed to create campaigns. "Configure and spend group revenue" is needed to convert group Robux and to turn on auto-reload [S1].
- **Uniqueness warning:** "Ad campaigns for games that are not unique can result in no ad spend and no conversions" [S1].

#### 3.2 Goals (objectives)
| Goal | What it optimizes | Notes | Source |
|---|---|---|---|
| **Plays** | Players most likely to start a session | Recommended for broad reach and testing, and for "initial traffic to help recommendation systems learn" | [S1] |
| **Earnings** (Limited) | Players most likely to spend Robux | Gated by monetization thresholds. Shows **ROAS / Estimated ROAS**. Staff say "most achieved positive ROAS within 30 days" in tests | [S1][S15] |
| **Engagement** (beta) | Age-checked highly engaged players | Counts toward the Kids and Select threshold. Expect **higher CPP**. Campaigns don't auto-pause at the threshold. Evaluate after 3-5 days | [S1][S18] |
| *Legacy names:* Maximize Plays, Drive Retention, Reactivate Users, Acquire New Users | | 2025 objectives, now expressed as Goal plus Audience | [S9][S11][S12] |

COMMUNITY: a dev spent 10 credits over 2 days on an **Engagement** campaign and got about 13K impressions, a **2.36% CTR**, and about 200 plays. They called it "VERY disappointing". Repliers recommended Plays instead, because "engagement speeds up exponentially once you hit home recommendations" [S22].

#### 3.3 Audiences and advanced targeting
| Dimension | Values | Source |
|---|---|---|
| Audience (recency) | All Players; New Players (never played, or 180+ days since last play); Recent Players (played in the last 30 days, game needs 10K+ recent players); Lapsed Players (played 30-180 days ago, game needs 20K+ lapsed players) | OFFICIAL [S1] |
| Location | Specific countries. Up to 10 regions/countries in the 2024 flow. The current limit is UNVERIFIED | OFFICIAL [S13][S23] |
| Age | "Age groups". The exact bands are **not published**. A user reported selecting "18-24" [S13]. Gupta Media lists 13-17 / 18-24 / 25+ (UNVERIFIED) [S24] | OFFICIAL/COMMUNITY |
| Gender | Available. Gupta Media says it is restricted for ages 13-17 in Europe (UNVERIFIED) | OFFICIAL [S1][S13]; [S24] |
| Genre (interests) | Players who enjoy certain genres. The list isn't published. Gupta Media lists 9: Action, Adventure, Obby, Roleplaying, Simulation, Social, Sports, Strategy, Tycoon (UNVERIFIED) | OFFICIAL [S1][S13]; [S24] |
| Device | Desktop, mobile, console | OFFICIAL [S13] |
| Personalization limit | "Users under 18 and anyone who's opted out of data sharing won't see personalized ads." Advertising Standards: "Ads may not be personalized for users under the age of 18." Narrower targeting raises CPP | OFFICIAL [S13][S5] |
| Language | **No language targeting found.** Self-serve ad *content* must be in English. Other languages are only available through Roblox pilot partnerships | OFFICIAL [S5] |
| Lookalikes / custom audiences | **None found** in docs or announcements (UNVERIFIED absence) | n/a |
| Frequency caps | **No advertiser-set cap found.** The platform does throttle "users who have seen too many ads in a short period" for immersive ads (UNVERIFIED for sponsored) | OFFICIAL [S4] |
| Under-13 delivery | In 2022 Roblox stopped showing sponsored experiences and ads to under-13s [S25]. Whether that still holds in 2026 is **UNVERIFIED**. Separately, games that haven't passed the Kids and Select evaluation are only shown to age-checked 16+ users anyway [S18] | COMMUNITY press [S25]; OFFICIAL [S18] |

#### 3.4 Budgets, credits, pacing
- Budget type is **Daily** or **Lifetime**, and you cannot change it after publishing. You *can* change the amount, schedule, creatives and name. Goal and audience are fixed [S1]. Budgets can be adjusted on live campaigns (May 2026) [S15].
- **Minimum campaign size is 10 ad credits.** The minimum credit purchase dropped from 10 to 1 in Nov 2025 [S12]. In May 2025 it was described as "5 daily, 2-day minimum" [S9]. The original 2023 minimum was 10 credits, then 2,850 Robux [S26].
- **Ad credit price:** 285 Robux per credit at launch (2023) [S26], changed to **263 Robux** in Sep 2025 [S14]. The first Robux converted are those earned at the US 18+ exchange rate [S1]. Community members value one credit at about US$1 [S20] (UNVERIFIED).
- **Auto-reload** buys one day's worth of credits at a time [S1]. **Continuous campaigns** have no end date; a third of campaigns used them as of Aug 2025 [S11].
- **Learning phase:** the first 24 hours of an active campaign [S1]. Staff say to judge performance after 7-10 days, not in the first 24-48 hours [S15]. Unused credits are refunded at campaign end [S1].
- **Pacing:** automatic. Staff reported "80% decrease in pacing spikes" in May 2025 [S9].
- **Fraud refunds:** campaigns are analysed 14 days after they end, and refunds for invalid traffic are applied 16 days after the end date [S1].
- **Billing:** cards are charged at a payment threshold or monthly. Ad credits are deducted in real time with a single daily charge [S1].

#### 3.5 Scheduling
- You set a start date, start time and duration [S1]. You can cancel up to **6 hours before start**, which refunds credits [S1].
- Day-parting is not offered as a setting (UNVERIFIED absence). BLOXG's advice to "pause during low-activity hours" [S27] can only be done by toggling the campaign on and off by hand.

#### 3.6 Advanced join options (useful for planning)
- You can send ad clickers to a specific **start place**, and attach **launch data**, which you read with `Player:GetJoinData().LaunchData` [S1].
- Roblox suggests three uses: onboarding tailored to the audience, a spawn point that matches the ad, and **ad-only cosmetic rewards** ("a good way to increase campaign conversion") [S1].
- Launch data is visible in the URL and shareable, so counts won't match exactly [S1].

---

### 4. Creative specs

| Asset | Aspect | Pixels | File types | Max size | Duration | Source |
|---|---|---|---|---|---|---|
| **Sponsored campaign thumbnail** | 16:9 (other ratios are auto-resized) | 1920x1080 recommended (same as Home thumbnails) | jpg, gif, png, tga, bmp (thumbnail spec) | 3 MB (Home thumbnail upload guidance) | n/a | OFFICIAL [S1][S8] |
| Thumbnails per campaign | n/a | n/a | n/a | n/a | n/a | **CONFLICT:** the docs say up to 10 [S1]; a May 2026 staff post says the limit rose from 10 to 25 [S15]; the Hypershot story uses 25 [S17]. History: 5 (Mar 2025) [S10], 10 (Aug 2025) [S11] |
| Asset library upload | n/a | n/a | n/a | n/a | n/a | Up to 10 files at once; AI generates 3 images; moderated within about 48h [S1] |
| Home and detail-page thumbnails (organic, used for personalization) | 16:9 | 1920x1080 | jpg, gif, png, tga, bmp | under 3 MB | n/a | OFFICIAL [S8] |
| Detail-page video thumbnail (organic) | n/a | n/a | n/a | n/a | n/a | 3 uploads per month quota. No voice-over, lyrics, real-world footage or promo text ("50% off", "Free UGC!") [S8]. Exact length and size limits are not given in the docs |
| Off-Platform Featuring event art | 16:9 or 9:16 | 1920x1080 or 1080x1920, or a layered PSD at 4000x4000 | image / PSD | n/a | n/a | OFFICIAL staff post [S28] |
| Event thumbnail | n/a | n/a | n/a | n/a | n/a | Up to 5 thumbnails. Use one distinct from the game thumbnail [S7][S29] |
| Immersive video ad (brand-bought, shown in games) | n/a | n/a | n/a | n/a | up to 30 s; publishers are paid on a 15s view (click-to-play) or an impression (autoplay) | OFFICIAL [S4] |
| Rewarded video (brand-bought) | full-screen | n/a | n/a | n/a | 6-30 s | OFFICIAL [S6][S16] |
| Legacy image ad (classic Ads Manager) | 16:9 | min 500 px wide | PNG, JPEG | 30 MB | n/a | **UNVERIFIED.** From the third-party Gupta Media guide [S24], which probably mirrors old Roblox docs |
| Legacy video ad (classic) | 16:9 | 720p-1080p, min 720 px wide | MP4, MOV | 100 MB | 15-30 s | **UNVERIFIED** [S24] |

**Creative content rules that matter for thumbnails** (OFFICIAL [S7][S8][S5]):
- Show real gameplay and the actual theme. A dinosaur thumbnail on a generic obby is the docs' own bad example [S7].
- Avoid monetary bait in titles and art. "Robux! Play now!" gets less exposure [S7]. Never offer free Robux [S5].
- Don't put essential elements at the **bottom** of the thumbnail, where the player count may cover them [S8].
- Use unique, original imagery. Copycat metadata is deprioritized [S1][S7].
- No URLs, partial links or QR codes. The only approved social platforms are YouTube, Twitch, Facebook, Instagram, Snapchat, Discord and X [S5].
- No profanity, including misspellings or foreign-language evasion. No real-world tragedies, politics or religion. Under-18 rules: no "only" or "just" price qualifiers, no urging kids to buy or ask parents, no implying an item gives status or popularity [S5].

---

### 5. Ad review and moderation, and the Advertising Standards (policy digest)

- **Review time:** Roblox tries to review ads within 24h; the asset library takes about 48h. Statuses include In Review, Moderated (with a reason), Rejected, and Learning. Rejected assets can be **appealed** [S1].
- **Ads and transparency:** advertising outside Roblox-served units needs clear disclosure. Creatives must not mimic system UI or obscure disclosures [S5].
- **Deception:** no deceptive claims, including "offering free Robux to entice engagement" [S5]. No clickbait or spam games in search [S3].
- **Banned categories (all ages):** child safety violations, violence and gore, extremism, drugs, tobacco, alcohol, cannabis, weapons, **gambling** (casinos, betting, lotteries), counterfeit goods, self-serve health or pharma, body alteration, sexual or dating content, hate, profanity, real-world tragedies, politics and religion, self-serve financial services, crypto and NFTs, MLM, dangerous stunts [S5]. COMMUNITY: devs warned that casino-themed games and dev products risk enforcement [S30].
- **Under-13 and under-18 content rules:** tiered bans covering mature media, food and beverage, cosmetics, social media and AI chatbots, and more. Under-18 creatives may not urge purchases [S5].
- **Off-platform links:** no unapproved URLs or QR codes. Landing pages must not be misleading [S5].
- **PII:** don't collect or show it, including social media handles. Real faces of private individuals are only allowed in video ad campaigns [S5].
- **Language:** self-serve ads must be in **English**. Other languages are pilot-only [S5].
- **Publisher-side rules** (if we host ads):
  - No random rewards in rewarded video.
  - No forced ads as progress gates.
  - No rewards that incentivize under-13s.
  - No portal reward mechanics.
  - Ads must be gated with `PolicyService.AreAdsAllowed`.
  - Rewarded video needs ID verification plus 2FA, 13+, and 2,000+ unique monthly visitors. Rewards must be developer products, worth about 3-10 Robux [S5][S6][S4].
- **Enforcement:** content removal, campaign or account suspension, and blocking affiliated accounts [S5].

---

### 6. Reporting and metrics

| Metric | Definition / notes | Source |
|---|---|---|
| Amount Spent, Impressions, Clicks, Plays, Playtime, Earnings | Earnings include ad revenue, Creator Rewards and in-game purchases; subscriptions are excluded | OFFICIAL [S1] |
| **CPP** | Total spend / plays | OFFICIAL [S1] |
| **CTR** | Added to reporting in Nov 2025 | OFFICIAL [S12] |
| ROAS / Estimated ROAS | Earnings campaigns only | OFFICIAL [S1] |
| Asset-level breakdown | Compare creatives inside a campaign | OFFICIAL [S1] |
| Attribution | New users: 30 days of plays and earnings. Recent (<7d): the ad-click session only. Resurrected 7-29d: 7 days. Resurrected 30d+: 30 days. Up to 48h data delay | OFFICIAL [S1] |
| qPTR (quality / qualified play-through rate) | The key quality metric in staff posts. A "qualified play" filters out accidental clicks and quick bounces | OFFICIAL [S7][S9][S12] |
| D1 / D7 retention of paid users | **No dedicated D1-of-paid metric in Ads Manager.** Use Creator Analytics acquisition and retention broken down by source (Sponsored ads, Search ads, Portal ads) | OFFICIAL [S19][S14] |
| Acquisition source buckets | "Sponsored ads" (sponsored experiences plus Sponsored Takeovers), "Search ads", "Portal ads" | OFFICIAL [S19] |
| Share links | Off-platform tracking with launch data; unlimited links | OFFICIAL [S31] |

---

### 7. How paid users interact with Recommended for You

- The **retrieval** stage can be *accelerated* by "signals from sponsored ads, curation, search ... social media sharing" [S7].
- The **ranking** stage counts only users who arrived *through RFY*: "Roblox doesn't count the engagement, monetization, or retention of users first acquired from ads, curation, friends, search, social media, or any other source" [S7].
- Roblox's worked example: a game gets 10K players a day from RFY, then adds 5K a day from ads. RFY traffic stays the same "as long as the behavior of the 10 thousand daily players from Home Recommendations does not change" [S7].
- Ads Manager docs say Plays campaigns help "recommendation systems learn what's working and qualify your game for Recommended For You" [S1].
- **Planning implication:**
  - Ads buy *exploration*, not rank.
  - The game's first-session hook and retention decide whether RFY scales afterwards.
  - Fix onboarding before spending. Roblox's own advice for Engagement campaigns that stall after 3-5 days is "improving your game's onboarding" [S1].
- COMMUNITY: devs report the algorithm drifting traffic toward high-retention, low-spend regions. One reported a "20x ARPDAU margin" between US-heavy and SEA-heavy games [S32]. No staff response.

---

### 8. Benchmarks

| Metric | Value | Context | Source | Verified |
|---|---|---|---|---|
| CPP, Maximize Plays | $0.0073 | Roblox average as of 2025-11-11 | [S12] | Official |
| CPP, Drive Retention | $0.0113 | as of 2025-11-11 | [S12] | Official |
| CPP, Reactivate Users | $0.011 | as of 2025-11-11 | [S12] | Official |
| CPP, Acquire New Users | $0.0187 | as of 2025-11-11 | [S12] | Official |
| CPP, Plays / Retention / Reactivate | $0.008 / $0.007 / $0.011 | Aug 2025 | [S11] | Official |
| CPP trend | -44% (May 2025); -71% ("less than $0.01", Sep 2025) | Staff claims | [S9][S14] | Official |
| Winning bid range (old manual-bid era) | $0.04-0.07 per play | May 2024 bid-insights example | [S23] | Official (historical) |
| Ad lift | +150% impressions, +24% plays, +16% playtime for games that run ads | Roblox marketing page | [S17] | Official (no methodology) |
| Sponsored share of plays | up to 10% of plays (Hypershot, top 100) | Case study | [S17] | Official |
| Thumbnail personalization | +8.5% qPTR on average, up to +50% | Roblox testing | [S8] | Official |
| 16:9 creatives vs 1:1 | up to +40% PTR in the Sponsored sort | Mar 2025 | [S10] | Official |
| Home+Search combined | +271% qPTR vs the keyword model | Nov 2025 | [S12] | Official |
| CTR target | about 2% "realistically" | Single dev comment | [S30] | Community |
| CTR observed | 2.36% (Engagement goal, 13K impressions) | 2026 thread | [S22] | Community |
| Play rate | 3.6% to 4.2%; impressions per credit fell from ~20K to 7.5K-10K | Oct 2025 "x3 more expensive" thread | [S21] | Community |
| CPP observed | ~$0.02 (US 57%, UK 12.5% audience) | 2024 manual-bid era | [S33] | Community |
| CTR tiers | 1-2% good, 3%+ great, 5%+ exceptional; "$0.10-0.50 per click"; "$1/day min" | BLOXG vendor guide. The $1/day minimum contradicts official docs | [S27] | UNVERIFIED |
| Rewarded video completion | >80% (some >90%) | Brand-side stat | [S16] | Official |
| Developer complaints | "95% worse results", costs doubled after the Home+Search merge | Thread replies | [S12] | Community |

---

### 9. What makes ads perform (synthesized playbook)

#### 9.1 Creative
1. **Accurate gameplay and a clear genre read at thumbnail size.** Theme and color should signal the genre: bright and comical, or dark for horror. Avoid ambiguous graphics [S8]. Misleading art lowers qPTR, and qPTR is what the system optimizes [S7][S9].
2. **Test distinct concepts, not tweaks.** Combat vs puzzle vs character vs environment [S34]. Hypershot ran up to 25 creatives and paused weak ones: a sniper character, a pink "Kawaii" skin, a first-person duel, a flaming dragon skin [S17].
3. **Refresh with updates.** "Showcase new content or gameplay in your thumbnails" [S34].
4. **Keep the bottom strip clear** [S8]. Keep text minimal and in English [S5].
5. **Don't restart tests within 7 days.** Keep several thumbnails active [S34].
6. **Pair ad creatives with organic thumbnail personalization.** Use the same concept family on Home thumbnails (2+ active), which lifts qPTR by 8.5% on average [S8]. Ad clickers then see a matching detail page.
7. **AI-generated thumbnails** are supported [S1]. COMMUNITY: they were "discouraged" in one feedback thread [S22] (subjective).

#### 9.2 Campaign structure and pacing
- Start with a **Plays** goal and the **All Players** or **New Players** audience. Use Recent or Lapsed only after reaching 10K or 20K players [S1].
- Run at the official minimum of 10 credits for at least 7-10 days before judging [S12][S15].
- Treat **Engagement** as a separate budget only when you are targeting Kids and Select eligibility [S1][S22].
- Narrower targeting means a higher CPP [S13]. Start broad and let auto-bid learn.

#### 9.3 Timing
- COMMUNITY data: Roblox concurrency peaks **Saturday around 19:00 UTC (~16M)** and bottoms out on **Tuesday around 08:00 UTC (~7.3M)**. Weekends run at about 12.2-12.5M vs 8.7-9.8M on weekdays [S35]. Launching on a Saturday evening reaches "nearly twice the audience".
- BLOXG claims school-holiday launches get "40-60% more engagement" (UNVERIFIED) [S36].
- Plan spend around updates and events. You can announce updates once every 3 days, max 60 characters [S29]. Submit events for **Off-Platform Featuring** at least 7 days ahead. The docs say 7; the launch post said 14 (CONFLICT) [S29][S28].
- "US after-school hours" as a specific window: **UNVERIFIED.** The UTC peak is consistent with US afternoon or evening overlapping with EU evening [S35].

#### 9.4 Country strategy
- Officially, you can pick specific countries [S13].
- No official guidance on tier-1 vs tier-2 targeting was found.
- COMMUNITY: US-heavy audiences monetize far better; one dev cited ~20x ARPDAU [S32]. Narrowing to the US, UK, Canada and Australia will raise CPP [S13].
- A reasonable plan is a broad Plays test first, then splits by country and device compared on CPP *and* earnings or retention (inference).

---

### 10. Free and off-platform promotion

| Channel | Rules / facts | Source |
|---|---|---|
| **Social links on the game page** | Up to 3 links: Facebook, Twitter/X, YouTube, Twitch, Discord, Guilded, Roblox community. The **creator must be age-verified 16+** to add them, and only **16+ age-verified viewers** see them (since Jun 30, 2026). Links are only allowed on the details page. You may not put "discord.gg/..." inside the game, but "Links on our game's page" is OK | OFFICIAL [S37][S18] |
| **Share links** | Trackable, unlimited, support launch data. Feed Creator Rewards "Audience Expansion": a 35% share on a new or reactivated user's first $100 of purchases | OFFICIAL [S31][S38] |
| Creator Affiliate Program | **Deprecated on Jul 24, 2025** and replaced by Creator Rewards | OFFICIAL [S39] |
| **Video Stars** (influencer program) | Members can earn Creator Rewards. Separate program at influencers.roblox.com | OFFICIAL [S38] |
| **Events & Updates** | Events appear on the details page with Notify Me plus push notifications. Updates: 60 characters, 1 per 3 days, sent to followers | OFFICIAL [S29] |
| **Off-Platform Featuring** | Free App Store / Google Play / Roblox marketing featuring for selected events. Best events run 7-30 days. 13+ with email | OFFICIAL [S29][S28] |
| Experience notifications | Reach 13+ opted-in users | OFFICIAL [S2] |
| Invite prompts and friend referral rewards | In-game virality tools | OFFICIAL [S2] |
| Communities (groups) | Name the group after the studio, add social links | OFFICIAL [S2] |
| TikTok / YouTube Shorts | Vendor claims: "TikTok is the #1 discovery engine", post 3-5 times a week, micro-influencers with 10K-50K followers give better ROI (all UNVERIFIED) | COMMUNITY [S36] |
| Sponsored or paid influencer content | Advertising Standards require clear disclosure for advertising outside Roblox-served units | OFFICIAL [S5] |
| Agencies (Gamefam, Super League/Bloxbiz, The Gang) | No public creative or CTR guidance about *sponsored-game* ads found. Their public material is about brand activations. Super League acquired Bloxbiz in 2021 | COMMUNITY [S40] |

---

### 11. Conflicts and open questions (check in the live UI)

1. **Thumbnails per campaign:** 10 (docs) vs 25 (May 2026 staff post) [S1][S15].
2. **Kids and Select threshold:** the docs say **250** unique plays from highly engaged players in 60 days, with a **50,000 Robux** expedited fee [S18]. The June 2026 staff post says **500** entry players and **100,000 Robux** [S41]. The docs on `main` are likely newer.
3. **Search-ads doc** still describes a keyword "Visits" campaign. This has been superseded by the combined Home+Search campaign [S3][S12]. The Nov 2025 post dated the classic sunset "January". The fetch summary said "2025", which is presumably a typo for Jan 2026 (UNVERIFIED).
4. **Exact age bands, genre list, and country limits** in advanced targeting are not published [S13].
5. **Whether under-13 users see sponsored games in 2026** is unclear. In 2022 they were excluded [S25].
6. **Portal ad campaigns:** the docs still list them as a promotion method [S2], but self-serve availability after the classic sunset is not confirmed.
7. **Frequency caps, day-parting, lookalikes and language targeting:** none found.

---

### Sources

Fetched 2026-10-07. For creator-docs pages, the live page is listed; the content was read from `https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/<path>.md`.

- [S1] OFFICIAL. Ads Manager docs: https://create.roblox.com/docs/production/promotion/ads-manager
- [S2] OFFICIAL. Promotion overview: https://create.roblox.com/docs/production/promotion
- [S3] OFFICIAL (stale). Search ads: https://create.roblox.com/docs/production/promotion/search-ads
- [S4] OFFICIAL. Immersive ads: https://create.roblox.com/docs/production/monetization/immersive-ads
- [S5] OFFICIAL. Advertising Standards (Help Center): https://en.help.roblox.com/hc/en-us/articles/13722260778260-Advertising-Standards
- [S6] OFFICIAL. Rewarded video ads: https://create.roblox.com/docs/production/promotion/rewarded-video-ads
- [S7] OFFICIAL. Discovery / Recommended for You: https://create.roblox.com/docs/discovery
- [S8] OFFICIAL. Thumbnails and thumbnail personalization: https://create.roblox.com/docs/production/publishing/thumbnails
- [S9] OFFICIAL (staff, 2025-05-21). "More Ads Manager Upgrades!": https://devforum.roblox.com/t/more-ads-manager-upgrades/3659656
- [S10] OFFICIAL (staff, 2025-03-31). "Leveling Up Ads Manager With New Features": https://devforum.roblox.com/t/leveling-up-ads-manager-with-new-features/3587640
- [S11] OFFICIAL (staff, 2025-08-05). "Ads Manager Updates: Acquire New Users, Continuous Campaigns and More": https://devforum.roblox.com/t/ads-manager-updates-acquire-new-users-continuous-campaigns-and-more/3862159
- [S12] OFFICIAL (staff, 2025-11-20). "Ads Manager Updates: Home + Search Combined, New Benchmarks and Sunsetting the Classic Flow": https://devforum.roblox.com/t/ads-manager-updates-home-search-combined-new-benchmarks-and-sunsetting-the-classic-flow/4084863
- [S13] OFFICIAL (staff, 2026-02-04). "Ads Manager UI & Targeting Enhancements": https://devforum.roblox.com/t/ads-manager-ui-targeting-enhancements/4333400
- [S14] OFFICIAL (staff, 2025-09-10). "Ads for Creators: RDC Recap and What's Next": https://devforum.roblox.com/t/ads-for-creators-rdc-recap-and-what%E2%80%99s-next/3929106
- [S15] OFFICIAL (staff, 2026-05-07). "Ads Manager Updates - Maximize Earnings, Attribution Updates, New Tile in Beta": https://devforum.roblox.com/t/ads-manager-updates-maximize-earnings-attribution-updates-new-tile-in-beta-other-updates/4623762
- [S16] OFFICIAL (newsroom, 2025-04-01). Rewarded video and the Google partnership: https://about.roblox.com/newsroom/2025/04/roblox-scales-video-ads-partners-with-google
- [S17] OFFICIAL. Advertising for creators (Hypershot case study, lift stats): https://create.roblox.com/docs/production/promotion/advertise
- [S18] OFFICIAL. Roblox Kids and Select: https://create.roblox.com/docs/production/publishing/kids-and-select
- [S19] OFFICIAL. Acquisition analytics: https://create.roblox.com/docs/production/analytics/acquisition
- [S20] COMMUNITY (2024-07-28). "Cost of one ad credit in euro": https://devforum.roblox.com/t/cost-of-one-ad-credit-in-euro/3091495
- [S21] COMMUNITY (2025-10-08). "Why are sponsored ads suddenly x3 more expensive?": https://devforum.roblox.com/t/why-are-sponsored-ads-suddenly-x3-more-expensive/3983531
- [S22] COMMUNITY (2026). "Best Ad strategy to reach 500 Highly Engaged Players": https://devforum.roblox.com/t/what-is-the-best-ad-strategy-to-reach-500-highly-engaged-players-for-an-under-16-multiplayer-focused-game/4806311
- [S23] OFFICIAL (staff, 2024-05-16). "Enhancements to Sponsored Experiences and Ads Manager": https://devforum.roblox.com/t/enhancements-to-sponsored-experiences-and-ads-manager/2972589
- [S24] COMMUNITY (agency blog, 2025-01-08). Gupta Media, "The Roblox Advertising Playbook for 2025": https://www.guptamedia.com/insights/roblox-advertising
- [S25] COMMUNITY (press, 2022). Kidscreen, "Roblox removes ads and sponsored experiences for non-teens": https://kidscreen.com/?p=194489
- [S26] OFFICIAL (staff, 2023-10-26). "Sponsored Experiences moving to Ads Manager": https://devforum.roblox.com/t/sponsored-experiences-moving-to-ads-manager/2661756
- [S27] COMMUNITY (vendor, Mar 2026). BLOXG "Complete Guide to Roblox Advertising (2026)": https://bloxg.com/guides/roblox-ads-guide
- [S28] OFFICIAL (staff, 2025-12-10). "Introducing Off-Platform Featuring for Creator Events": https://devforum.roblox.com/t/introducing-off-platform-featuring-for-creator-events/4142230
- [S29] OFFICIAL. Events and updates: https://create.roblox.com/docs/production/promotion/experience-events
- [S30] COMMUNITY. "Good CTR and Play Rates for Sponsorships": https://devforum.roblox.com/t/good-ctr-and-play-rates-for-sponsorships/3143443
- [S31] OFFICIAL. Share links: https://create.roblox.com/docs/production/promotion/share-links
- [S32] COMMUNITY (2024-10 to 2025-07). "Algorithm unnecessarily pushing games to 'Other' countries": https://devforum.roblox.com/t/algorithm-unnecessarily-pushing-games-to-%E2%80%9Cother%E2%80%9D-countries-which-majorly-impacts-games-longevity/3235335
- [S33] COMMUNITY (2024). "Optimizing my game's Cost Per Play from Ads": https://devforum.roblox.com/t/optimizing-my-games-cost-per-play-from-ads/3047197
- [S34] OFFICIAL (staff, 2025-02-13). "5 Tips From Roblox Staff to Get the Most Out of Thumbnail Personalization": https://devforum.roblox.com/t/5-tips-from-roblox-staff-to-get-the-most-out-of-thumbnail-personalization/3471689
- [S35] COMMUNITY (data blog, 2026-06-09). RoWatcher, "When Is Roblox Busiest?": https://rowatcher.com/news/when-is-roblox-busiest-we-mapped-every-hour-of-the-week
- [S36] COMMUNITY (vendor, Mar 2026). BLOXG "Complete Guide to Roblox Game Marketing (2026)": https://bloxg.com/guides/roblox-marketing
- [S37] OFFICIAL. Social media links: https://create.roblox.com/docs/production/promotion/social-media-links
- [S38] OFFICIAL. Creator Rewards: https://create.roblox.com/docs/creator-rewards
- [S39] OFFICIAL. Creator Affiliate Program (deprecated): https://create.roblox.com/docs/affiliates
- [S40] COMMUNITY (press release, 2021). Super League acquires Bloxbiz: https://ir.superleague.com/news-events/press-releases/detail/123/super-league-gaming-acquires-metaverse-ad-platform-bloxbiz
- [S41] OFFICIAL (staff, 2026-06-16). "Roblox Kids and Select Global Launch: Upcoming Updates to Eligibility, Ads Manager, and Expedited Review": https://devforum.roblox.com/t/roblox-kids-and-select-global-launch-upcoming-updates-to-eligibility-ads-manager-and-expedited-review/4685717

Method note: DevForum pages were read through a summarizing fetcher, so wording is paraphrased unless quoted. Direct HTTP to devforum.roblox.com and archive.org was blocked by the proxy, so older versions of the docs (for example the classic image and video ad specs) could not be checked against an archive.

## Part 3. Store assets: icons, thumbnails, titles, descriptions and item icons

Research date: 2026-10-07. All URLs were fetched on 2026-10-07 unless marked otherwise.
Labels used:
- **VERIFIED**: stated on an official Roblox page (Creator Hub docs, DevForum staff post, Roblox Help) fetched today.
- **OBSERVED**: read off a live roblox.com game page today (titles/descriptions only, since image CDNs were not reachable from the research sandbox).
- **COMMUNITY**: DevForum community posts, third-party blogs. These are opinions or anecdotes, not policy.
- **UNVERIFIED**: from general knowledge or widely repeated, with no confirming source found today. Treat as a heuristic.

---

### 0. TL;DR

1. **Icon**: square 512x512 (VERIFIED), often shown around 150x150 (VERIFIED). It reads as a single bold subject: one character's face with a strong expression, saturated colors, a dark outline, a simple background, and 0-3 big words. Keep key content inside an inset of about 10% because UI rounds the corners and puts overlays on the edges (UNVERIFIED margin).
2. **Thumbnails**: 16:9, ideally 1920x1080, under 3 MB, jpg/gif/png/tga/bmp, up to 10 media items per game (VERIFIED). Home-page **thumbnail personalization** needs at least 2 active thumbnails. Roblox recommends 2-5, and 5 is the current maximum (VERIFIED docs plus DevForum). Roblox reports +8.5% average qualified play-through rate (PTR), with some games up to +50% (VERIFIED). Keep text out of the bottom band, where player count and other metadata appear (VERIFIED).
3. **Testing in 2026**: the native thumbnail personalization and comparison is the Home Page tab in Creator Hub. Since Aug 24-28, 2026 there is also an **Open Cloud API to test thumbnails programmatically** (VERIFIED, DevForum weekly recap). Roblox's general **Experiments** system (A/B testing of in-game configs, with targeting, segmentation and early harm detection) launched in Aug 2026 (VERIFIED, press and recap). **Icon A/B testing does not exist**: it is an open feature request (VERIFIED DevForum, Nov 2024; no launch found).
4. **Ranking**: Home recommendations rank on qualified **play-through rate**, first-play bounce, play days, playtime, co-play and spend (VERIFIED). Misleading metadata, giveaways in the title, and irrelevant keywords cause demotion (VERIFIED). CTR alone is not the target. Retention after the click matters, the same philosophy as YouTube's watch-time-share winner metric.
5. **Description**: the first ~160 characters are the hook (search snippet), and the total limit is 1000 characters (VERIFIED, Roblox "Game descriptions" guide, labelled experimental). No hashtags or tags. 1-2 emojis in the title is fine. Repetitive or excessive decoration can get the game demoted (VERIFIED).
6. **Passes and dev products**: max 512x512, jpg/png/bmp, displayed as a **circle** (VERIFIED). **Badges**: 512x512 template, auto-cropped to a circle, 5 free per 24h per game, then 100 Robux each (VERIFIED).

---

### 1. Official specs and rules

#### 1.1 Asset specs table

| Asset | Size | Formats | Max bytes | Count | Crop / display | Status | Source |
|---|---|---|---|---|---|---|---|
| Experience icon | 512x512 square (min, recommended) | not listed in docs; jpg/png accepted (UNVERIFIED) | not stated | 1 per locale | Scales to ~150x150 in places; rounded-corner tile in apps (corner rounding UNVERIFIED) | VERIFIED size | [experience-icons](https://create.roblox.com/docs/production/publishing/experience-icons), [game-icons](https://create.roblox.com/docs/production/promotion/game-icons) |
| Image thumbnail | 16:9, ideally 1920x1080 | .jpg .gif .png .tga .bmp | < 3 MB | up to 10 images/videos per game | Bottom band may be covered by metadata (player count) | VERIFIED | [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails), [promotional-thumbnails](https://create.roblox.com/docs/production/promotion/promotional-thumbnails) |
| Video thumbnail | (gameplay video) | upload | n/a | 3 uploads / month quota | Not shown on Xbox, PlayStation, VR | VERIFIED | same |
| Auto-generated thumbnail | from Studio camera at last publish | n/a | n/a | 1 | n/a | VERIFIED | same |
| Home personalization set | same as image thumbnail | same | same | min 2, recommended 2-5, max 5 | Roblox picks per user | VERIFIED (max 5 from DevForum feature request) | [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails), [DevForum](https://devforum.roblox.com/t/thumbnail-personalization-dynamic-max-limit/4637385) |
| Game pass icon | max 512x512 | .jpg .png .bmp | not stated | 1 per pass | Circular display; keep details inside the circle | VERIFIED | [game-passes](https://create.roblox.com/docs/production/monetization/game-passes) |
| Developer product icon | max 512x512 | .jpg .png .bmp | not stated | 1 per product | Circular; required for external (off-experience) sales | VERIFIED | [developer-products](https://create.roblox.com/docs/production/monetization/developer-products) |
| Badge icon | 512x512 template | not stated (png works, UNVERIFIED) | not stated | 5 free / 24h (GMT) per game, then 100 Robux each | Auto-trimmed to a circle | VERIFIED | [badges](https://create.roblox.com/docs/production/publishing/badges) |

Notes:
- Roblox serves Home tiles from 16:9 renditions. The Grow a Garden detail page served its thumbnail as a **500x280 JPEG** rendition (`tr.rbxcdn.com/.../500/280/Image/Jpeg/noFilter`, OBSERVED), and press kits use 768x432. Design at 1920x1080 and then **check legibility at 500x281 and 384x216**.
- Thumbnails can have "alt" text for accessibility, set on the Experience Detail Page tab (VERIFIED, thumbnails doc).
- Creator Hub has two separate tabs, **Home Page** and **Experience Detail Page**, so the Home set and the detail-page gallery can differ (VERIFIED).

#### 1.2 Thumbnail personalization, A/B testing, and "Experiments" (state as of 2026-10)

| Feature | What it does | Status | Source |
|---|---|---|---|
| Thumbnail personalization (Home Page tab) | You activate 2-5 thumbnails, and Roblox shows each user the most relevant one. Metrics shown: impressions, qualified plays, avg playtime, qualified PTR, "winning segment". Roblox recommends keeping several active instead of choosing one winner. | Live | [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails) |
| Reported uplift | "+8.5% in qualified play through rate on average, some games +50%" | Roblox-reported | same |
| Max set size | 5. A community request asks for a CCU-based dynamic limit (May 2026), with no staff reply seen. | Live limit | [DevForum 4637385](https://devforum.roblox.com/t/thumbnail-personalization-dynamic-max-limit/4637385) |
| Open Cloud thumbnail testing API | "test thumbnails programmatically, with no manual Creator Hub work" | Announced Aug 24-28, 2026 | [Weekly Recap Aug 24-28 2026](https://devforum.roblox.com/t/weekly-recap-august-24%E2%80%9328-2026-persistent-leaderboards-opencloud-apis/4836039) |
| Experiments system | A/B tests of in-game changes and configs, with targeting, segmentation, early harm detection (alerts on playtime, ARPU, conversion), and conditional configs by player type | Announced Aug 2026 | [GamesBeat](https://gamesbeat.com/roblox-announces-new-creator-tools-for-analytics-a-b-testing-and-live-ops-exclusive/), [PocketGamer.biz](https://www.pocketgamer.biz/roblox-launches-new-analytics-and-experimentation-tools/), recap above |
| Icon A/B testing | No native feature. Feature request open since Nov 25, 2024. | Not available | [DevForum 3274267](https://devforum.roblox.com/t/icon-ab-testing/3274267) |

Practical implications:
- Icon changes can only be compared **sequentially**: swap the icon, then compare PTR week over week while controlling for updates and weekends. Treat any such result as noisy.
- Thumbnails are where you can test properly. Keep 3-5 distinct *concepts* active, not 5 color variants of one concept, because personalization works best when it can pick different hooks for different segments (COMMUNITY reasoning, consistent with the docs' "adapt to changing user trends").

#### 1.3 Text limits

| Field | Limit | Status | Source |
|---|---|---|---|
| Description, total | 1000 characters | VERIFIED (descriptions guide) | [descriptions](https://create.roblox.com/docs/production/publishing/descriptions) |
| Description hook | first ~160 characters populate search snippets | VERIFIED (guidance, not a hard limit) | same |
| Experience name (title) | **50 characters** is widely cited, but no official page found today states it | UNVERIFIED | none found ([publish doc](https://create.roblox.com/docs/production/publishing/publish-games-and-places) has no number) |
| Pass, product, badge name and description | Not stated in docs | UNVERIFIED (commonly ~50 for names, ~1000 for descriptions) | [game-passes](https://create.roblox.com/docs/production/monetization/game-passes), [badges](https://create.roblox.com/docs/production/publishing/badges) |
| Name and description moderation | Text filter can reject saves ("New universe name or description has been rejected") even for innocuous words | COMMUNITY | [DevForum 2663909](https://devforum.roblox.com/t/roblox-wont-save-my-experience-name-suddenly-and-im-not-sure-why-update/2663909) |

The descriptions guide says it is "only meant for select creators" and experimental. Its structure is still the best official template available.

#### 1.4 Title conventions ("[UPDATE]", emoji)

Official guidance ([publish-games-and-places](https://create.roblox.com/docs/production/publishing/publish-games-and-places), VERIFIED):
- "Decorating the name with one or two well-placed emojis isn't harmful, but misplaced or excessive decorations can confuse players."
- Do not spam repetitive words or phrases, which can lead to demotion.
- Keep naming consistent so players can find the game again.
- [Discovery](https://create.roblox.com/docs/discovery) lists "leading with giveaways" (monetary rewards in titles or descriptions) as something that reduces exposure.

Observed top-game titles on 2026-10-07 (OBSERVED from roblox.com):

| Game | Title as displayed | Pattern |
|---|---|---|
| Grow a Garden | `[🧑‍🌾] Grow a Garden 🌶️` | bracketed emoji prefix (update/event marker) plus trailing emoji |
| Steal a Brainrot | `[🌗] Steal a Brainrot` | bracketed emoji prefix only |
| Pet Simulator 99 | `🎃 [HATCH WARS] Pet Simulator 99! 🍀` | seasonal emoji, then an ALL-CAPS update name in brackets, the name, and a trailing emoji |
| Adopt Me! | `[🎃] Adopt Me!` | seasonal emoji in brackets |
| 99 Nights in the Forest | `99 Nights in the Forest 🔦` | name plus a single brand emoji |
| DOORS | `DOORS 🚨` | name plus a single brand emoji |
| Dress To Impress | `Dress To Impress ⭐` | name plus a single brand emoji |
| Blox Fruits | `Blox Fruits` | no decoration; the update goes in the first description line |

Pattern: `[<1 emoji or SHORT UPDATE NAME>] <Stable Name> <0-1 emoji>`. The stable name never changes. The bracketed prefix rotates with each update or event. The update name is at most 2 words in caps. Nobody uses "FREE", "ROBUX", or more than 3 emojis.

#### 1.5 Genre, subgenre and maturity

- **Genre/subgenre** ([experience-genres](https://create.roblox.com/docs/production/publishing/experience-genres), VERIFIED): set in Creator Dashboard > Configure > Settings. One primary genre plus an optional subgenre. It drives the genre-specific top and trending sorts on Charts. The docs page says "21" genres, but the fetched list named: Action, Adventure, Education, Entertainment, Obby & Platformer, Party & Casual, Puzzle, RPG, Roleplay & Avatar Sim, Shooter, Shopping, Simulation, Social, Sports & Racing, Strategy, Survival, Utility & Other. Example subgenres: Simulation has Idle, Incremental Simulator, Physics Sim, Sandbox, Tycoon, Vehicle Sim. Action has Battlegrounds & Fighting, Music & Rhythm, Open World Action. **You can change the genre only once every 3 months.** Roblox may audit and correct it. Discovery takes days to update after a change.
- **Maturity labels** ([content-maturity](https://create.roblox.com/docs/production/promotion/content-maturity), VERIFIED): Minimal, Mild, Moderate, Restricted (18+ ID-verified only). Minimal and Mild reach Roblox Kids (5-8) and Select (9-15). Moderate reaches Select (9-15) and 16+. They come from the Maturity & Compliance Questionnaire. Inaccurate answers restrict playability, and repeated inaccuracy can lead to account action ([experience-guidelines](https://create.roblox.com/docs/production/promotion/experience-guidelines)).
- The docs do not say that icons and thumbnails must match the label, but the general rule against misleading metadata applies. A Minimal-rated game should not use gory or horror imagery, and vice versa (UNVERIFIED inference).
- Title and description wording can reclassify the game: "if your title or description includes content referencing social hangouts, your experience will be classified as a social hangout" (VERIFIED, experience-guidelines).

#### 1.6 Content rules for icons, thumbnails, titles and descriptions

From [Roblox Rules of Conduct / Community Standards](https://en.help.roblox.com/hc/en-us/articles/203313410-Roblox-Rules-of-Conduct), [Discovery](https://create.roblox.com/docs/discovery), and the [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails) / [promotional thumbnails](https://create.roblox.com/docs/production/promotion/promotional-thumbnails) docs:

| Rule | Status |
|---|---|
| No "deceptive, sensational, or otherwise misleading content or metadata used to inappropriately drive discoverability or engagement" | VERIFIED |
| No false advertising such as "offer free Robux" | VERIFIED |
| No leading with giveaways (monetary rewards) in the title or description, which reduces exposure | VERIFIED |
| Metadata must be accurate, unique and truthful, matching actual gameplay | VERIFIED |
| No off-platform links in descriptions, and no masked or partial links. Roblox community or group links are fine (Dress To Impress links its `roblox.com/communities/...` page, OBSERVED) | VERIFIED / OBSERVED |
| No others' brands or logos without permission (IP) | VERIFIED |
| No current or recent government officials or candidates | VERIFIED |
| Real people's likeness in general: avoid it. Real photos or footage are banned in video thumbnails. For still images, this is a moderation risk and IP or likeness issue | UNVERIFIED for stills (VERIFIED for video: no real-life footage) |
| Video thumbnails: authentic gameplay only. Varied camera angles, light grading, highlight cuts, in-game UI and catalog music are OK. No misrepresented mechanics, no artificially enhanced graphics, no external footage, no voice-over or lyrical music, no advertising or subjective text claims | VERIFIED |
| Overlay text: minimal, for gameplay context only (e.g. "Collect coins to boost jumps"). No ads, discounts or "special offer" claims | VERIFIED (stated in promotional-thumbnails, for video and overlays) |
| Paid promotion disclosure: "ad", "paid", "sponsored" | VERIFIED |
| All icons and thumbnails pass moderation before they are shown | VERIFIED |
| Experience-teleporter bait (fake game that teleports elsewhere), botted likes | COMMUNITY ([fandom](https://roblox.fandom.com/wiki/Deceptive_advertising)) |

---

### 2. What top-chart games do

#### 2.1 Common visual grammar (2025-2026)

The image CDN was not reachable, so these points come from general knowledge of the 2025-2026 charts plus community sources. Treat them as **UNVERIFIED observations** unless a source is cited.

| Element | Typical treatment | Why |
|---|---|---|
| Focal subject | One character or creature, cropped close (head and shoulders, or face only). It takes 40-70% of the icon. | Must read at 150 px. Rowatcher says close crops beat scenic shots and claims a 20-40% CTR improvement for single-subject designs (COMMUNITY, unverified number) |
| Expression | Exaggerated: shock (open mouth, wide eyes), greed, fear, mischief. Brainrot games use the meme creature's face. | Emotion reads in under 200 ms (COMMUNITY) |
| Color | High saturation, warm subject on a complementary background (orange/yellow on blue/teal, green on magenta). Horror is the exception: dark scene plus one warm light source (99 Nights: campfire or flashlight against a dark forest). | Roblox docs: saturated for fantasy, muted for somber, high contrast for horror (VERIFIED) |
| Outline | Thick dark or white stroke around the subject (2-4% of canvas width). Often a second colored outer glow. | Separates the subject from any UI background (light or dark theme) |
| Background | Simple radial gradient, blurred in-game scene, or sunburst. Low detail. | Keeps one focal point |
| Text | 0-3 words, heavy rounded display font, bright fill, dark stroke, slight 3D extrusion or drop shadow. Often the update name ("HALLOWEEN", "NEW PETS") on a tilted ribbon. | DevForum feedback: text-only icons perform badly, and small text reads as "a blank line" (COMMUNITY) |
| Update badge | Corner ribbon or starburst ("NEW!", "UPDATE", event emoji), usually top-left or top-right, kept away from the extreme corner. | DevForum suggestion: a "NEW" ribbon may raise CTR (COMMUNITY) |
| Render style | Mostly Blender renders of Roblox rigs and assets with stylized lighting, rather than raw Studio screenshots. Simulators often use painted or over-painted renders. | Polished renders win the grid. The docs require that thumbnails do not misrepresent gameplay, so keep renders faithful to real in-game assets |
| Brand mascot | A recurring character or object (Pet Sim's pets, DOORS' entity eyes, Grow a Garden's crops or farmer, Adopt Me's pets, Dress To Impress models) appears in every icon iteration, so returning players recognize it. | Consistency plus novelty |

Game-specific notes (UNVERIFIED unless noted):
- **Grow a Garden**: bright cartoon farm palette, large crop or fruit and character close-ups. The title's emoji prefix changes with each event (OBSERVED title).
- **Steal a Brainrot**: meme "brainrot" creature faces, saturated, chaotic comedy tone. Title prefix emoji rotates (OBSERVED title).
- **99 Nights in the Forest**: dark forest, warm firelight or flashlight, a looming creature silhouette (the "something is watching you" hook in the description, OBSERVED). Uses horror contrast, not saturation.
- **Blox Fruits**: anime-styled action characters and fruit powers, high-energy VFX. The update name goes in the description's first line, "OUT NOW: 🧲 Magnet + 🏝️ Sea 1 + MORE" (OBSERVED).
- **Pet Simulator 99**: huge glossy pets, sparkles, ALL-CAPS event name in the title (OBSERVED `[HATCH WARS]`).
- **Adopt Me!**: cute pets and characters, seasonal reskins (OBSERVED `[🎃]` for Halloween). Rowatcher cites it as a close-crop, high-contrast, face-forward example (COMMUNITY).
- **DOORS**: dark, high-contrast horror with one glowing entity. The title has a single 🚨 brand emoji (OBSERVED).
- **Dress To Impress**: fashion models posed in outfits, pink and purple glamour palette, ⭐ brand emoji (OBSERVED).

#### 2.2 Refresh cadence

- Top games refresh the **title prefix with every update or event** (OBSERVED: four of eight sampled titles carried a seasonal or update token in early October 2026).
- Icons and thumbnails are usually refreshed **every major update**, often weekly for top simulators during peak events (UNVERIFIED). The brand mascot and logo stay constant while the background, prop and ribbon change.
- Because icon A/B testing does not exist, studios change icons with updates and watch PTR. Thumbnails rotate inside the personalization set (VERIFIED feature).

#### 2.3 Benchmarks (CTR / PTR)

No official numeric PTR benchmark is published. The [acquisition analytics](https://create.roblox.com/docs/en-us/production/analytics/acquisition) docs compare you to "similar games" benchmarks inside the dashboard only.

| Number | Context | Status |
|---|---|---|
| +8.5% avg qualified PTR, up to +50% | Effect of thumbnail personalization | VERIFIED (Roblox) |
| 0.5% PTR | Called "pitiful" by an OP (minigames game) | COMMUNITY ([4858140](https://devforum.roblox.com/t/how-should-i-go-about-improving-play-through-rate/4858140)) |
| 0.134% ad CTR, called poor; PC ads reported 50-100x worse than mobile | Sponsored ads, old ad system | COMMUNITY ([2625742](https://devforum.roblox.com/t/is-my-game-icon-actually-this-bad-horrible-click-rate/2625742)) |
| 0.012% sponsor CTR | Old sponsor system | COMMUNITY ([2038721](https://devforum.roblox.com/t/is-this-game-icon-really-that-bad-game-only-got-0012-sponsoring-ctr/2038721)) |
| +0.87% qualified PTR | From auto-translating the name and description (June 2025 experiment) | VERIFIED ([DevForum 3878129](https://devforum.roblox.com/t/automatic-translation-experiment-results-and-next-steps/3878129)) |
| 20-40% CTR lift for single high-contrast subject; text at least 40 px; max 5 elements | Blog claims | COMMUNITY / UNVERIFIED ([rowatcher](https://rowatcher.com/news/the-roblox-thumbnail-is-a-conversion-ad-stop-designing-it-like-art)) |

#### 2.4 Applicable YouTube thumbnail research

- A 300k-video 2025 study found faces vs no faces perform **similarly overall**. Effects depend on niche, and multiple faces beat a single face ([SEJ](https://www.searchenginejournal.com/do-faces-help-youtube-thumbnails-heres-what-the-data-says/563944/)). For Roblox, a character face is useful mainly as a genre or emotion signal, not as magic.
- YouTube's title and thumbnail A/B test picks winners by **watch-time share, not CTR**, to avoid clickbait ([YouTube Help](https://support.google.com/youtube/answer/16391400?hl=en)). Roblox follows the same logic: recommendations reward qualified plays and penalize first-play bounce ([Discovery](https://create.roblox.com/docs/discovery)). A thumbnail that overpromises raises CTR but lowers ranking.
- General composition heuristics (UNVERIFIED but standard): rule of thirds, with the face on a third line and text on the opposite third. Use a value (lightness) contrast between subject and background, not just a hue contrast. Grayscale-test the image.

#### 2.5 Community thumbnail-artist advice (COMMUNITY)

- Show the core fantasy and gameplay, not the logo, unless the brand is already known ([2625742](https://devforum.roblox.com/t/is-my-game-icon-actually-this-bad-horrible-click-rate/2625742)).
- Use real Roblox rigs rather than drawings so viewers know it is Roblox gameplay. Avoid baseplate backgrounds, floating weapons and heavy blur. Be bright ([4772142](https://devforum.roblox.com/t/how-to-get-playthrough-rate-up/4772142)).
- Make the genre obvious. If it is a minigames game, show a specific exciting minigame. "Too busy" is the most common criticism ([4858140](https://devforum.roblox.com/t/how-should-i-go-about-improving-play-through-rate/4858140)).
- Preview in the real grid next to competitors (desktop, mobile and console 10-foot; Home, Search and Charts layouts). Community tool: qptr.io ([4690127](https://devforum.roblox.com/t/qptrio-%E2%80%94-see-your-thumbnail-the-way-players-will/4690127)), a third-party tool not evaluated here.

---

### 3. Reproducible art pipeline

#### 3.1 Getting assets into Blender

1. **Avatar or rig**: use RBX Toolbox (free Blender add-on, GitHub releases). It imports a Roblox avatar and accessories directly, spawns R6/R15/Rthro dummies, and has HDRI presets and preconfigured cameras ([DevForum 2170259](https://devforum.roblox.com/t/rbx-toolbox-free-blender-addon/2170259)). Alternatively, in Studio, right-click a model > Export Selection (.obj with textures), or use FBX or glTF per the [Studio-Blender config guide](https://create.roblox.com/docs/en-us/art/blender.md). Roblox does not document an official "import Studio scene into Blender" plugin (VERIFIED absence).
2. **Map props**: Export Selection from Studio, so the image shows real in-game assets (this keeps you compliant with "accurately portray content").
3. Blender version: the current manual is **Blender 5.2 LTS** (docs.blender.org header, 2026-10-07).

#### 3.2 Scene recipe (icon at 512 px, rendered at 2048 then downscaled)

| Setting | Value | Notes |
|---|---|---|
| Output resolution | Icon: 2048x2048 (downscale to 512). Thumbnail: 3840x2160 (downscale to 1920x1080). | Supersampling gives cleaner edges after downscale |
| Engine | EEVEE for iteration, Cycles (128-256 samples plus denoise) for final | DevForum beginner guides use EEVEE with AO (distance 2 m, factor 3) and bloom ([1183890](https://devforum.roblox.com/t/how-to-do-gfx-for-beginners/1183890)) |
| Camera | 50-85 mm focal length for faces (less distortion), camera at eye level or slightly low for "heroic". 35 mm for dramatic action. Place the subject's eyes on the upper third line. | UNVERIFIED (standard practice) |
| Materials | Roblox plastic: roughness ~0.35, specular ~1 (DevForum recipe). Boost base saturation 10-20% in the shader or later in grading. | COMMUNITY |
| Key light | Area light, 45° to the side and 30-45° above, warm (~4500 K), the strongest light | 3-point rig, standard |
| Fill light | Opposite side, 1/4-1/3 of key power, cool (~7000 K), large and soft | |
| Rim/back light | Behind the subject, 1.5-3x key power, saturated color (cyan, magenta or the brand color), narrow spread. Gives the "glowing edge" that separates the subject from the background. | Most important for small-size readability |
| World / HDRI | Low-strength HDRI (0.2-0.5) for reflections only (Poly Haven CC0), or a flat color world. Hide the HDRI from the camera (Film > Transparent) and composite a gradient. | DevForum recommends HDRIs ([2776630](https://devforum.roblox.com/t/using-hdris-in-blender/2776630), [535013](https://devforum.roblox.com/t/rendering-roblox-scenes/535013)) |
| Outline option A: inverted hull | Duplicate the character mesh or use a Solidify modifier: thickness negative (~0.02-0.05 studs-scale), **Flip Normals** on, Material Index Offset 1 pointing to a black emission material with **Backface Culling** on | Works in EEVEE and Cycles, and gives a consistent silhouette line |
| Outline option B: Freestyle | Render > Freestyle on. Line set: Silhouette + Border + External Contour. Thickness 3-6 px at 2048 (absolute), black or dark tinted. | Easier to set up but slower. Good for the outer contour only |
| Outline option C: 2D | Render with transparent film, then in ImageMagick dilate the alpha into a stroke (see 3.3) | Cheapest and most controllable for the outer outline |
| Depth of field | Off for icons (everything must be crisp). For thumbnails, a light f/2.8-f/4 on the background only. | DevForum critics dislike heavy blur ([4772142](https://devforum.roblox.com/t/how-to-get-playthrough-rate-up/4772142)) |
| Color management | View transform **AgX** (default since Blender 4.0) with a contrast look such as "Medium High Contrast" or "Punchy", or **Standard** for flat toon colors | AgX default verified in the [4.0 release notes](https://developer.blender.org/docs/release_notes/4.0/color_management/). Look names are UNVERIFIED for 5.2 |
| Passes to output | RGBA PNG 16-bit, plus optional Cryptomatte or an object-index mask for the subject | Compositing and masking |

Command-line render (no GUI):
```
blender -b icon_scene.blend -o //out/icon_#### -F PNG -x 1 -f 1
```

#### 3.3 Compositing and text (ImageMagick 7 syntax; use `convert` on IM6)

Background, subject with stroke, then text:
```
# 1) radial gradient background (brand colors)
magick -size 2048x2048 radial-gradient:"#4fd1ff"-"#1a237e" bg.png

# 2) subject render with an outer stroke from its alpha (12 px at 2048 = 3 px at 512)
magick subject.png \( +clone -alpha extract -morphology Dilate Disk:12 \
        -background black -alpha shape \) +swap -background none -layers merge subject_stroked.png

# 3) composite subject, slightly above center
magick bg.png subject_stroked.png -gravity center -geometry +0-80 -composite base.png

# 4) text: heavy font, light fill, dark stroke, drop shadow
magick base.png -gravity south -font LilitaOne-Regular.ttf -pointsize 300 \
   \( -clone 0 -fill black -stroke black -strokewidth 40 -annotate +0+260 'GROW!' -blur 0x8 \) \
   -fill '#ffe14d' -stroke '#3b1f00' -strokewidth 24 -annotate +0+260 'GROW!' -flatten text.png

# 5) final sizes + small-size preview
magick text.png -filter Lanczos -resize 512x512 -strip -define png:compression-level=9 icon_512.png
magick icon_512.png -resize 150x150 preview_150.png
magick icon_512.png -resize 64x64 preview_64.png     # hardest case (lists/search)
magick icon_512.png -colorspace Gray preview_gray.png # value-contrast check
```
Krita (layers, brush paint-overs, "Layer Style > Stroke") and Inkscape (vector text with `paint-order: stroke` and exact strokes, exported with `inkscape --export-type=png --export-width=2048`) are free alternatives for the text layer.

#### 3.4 Fonts (license checked against google/fonts METADATA.pb on 2026-10-07)

| Font | License | Feel | URL |
|---|---|---|---|
| Lilita One | SIL OFL 1.1 | chunky rounded, a common game-UI font | https://fonts.google.com/specimen/Lilita+One |
| Luckiest Guy | **Apache 2.0** (not OFL) | cartoon bubbly caps | https://fonts.google.com/specimen/Luckiest+Guy |
| Fredoka (variable, successor to "Fredoka One") | SIL OFL 1.1 | soft rounded | https://fonts.google.com/specimen/Fredoka |
| Bangers | SIL OFL 1.1 | comic action caps | https://fonts.google.com/specimen/Bangers |
| Titan One | SIL OFL 1.1 | heavy rounded | https://fonts.google.com/specimen/Titan+One |
| Baloo 2 | SIL OFL 1.1 | friendly rounded, many weights | https://fonts.google.com/specimen/Baloo+2 |
| Bowlby One | SIL OFL 1.1 | ultra heavy | https://fonts.google.com/specimen/Bowlby+One |
| Russo One | SIL OFL 1.1 | techy and sporty | https://fonts.google.com/specimen/Russo+One |
| Passion One | SIL OFL 1.1 | condensed heavy | https://fonts.google.com/specimen/Passion+One |
| Chewy | Apache 2.0 | goofy cartoon | https://fonts.google.com/specimen/Chewy |

OFL and Apache 2.0 both allow commercial use and embedding text in images. OFL restricts selling the font file by itself. Rendering it into a PNG has no attribution requirement.

#### 3.5 Safe zones

| Asset | Safe zone | Status |
|---|---|---|
| Icon 512 | Keep the face and text inside a centered square inset of about 8-10% (about 40-50 px) per side. App tiles round the corners (radius roughly 8-15% of side) and may add badges or overlays. | UNVERIFIED (observed UI behavior) |
| Pass, product, badge icon 512 | Everything important goes inside the **inscribed circle** (radius 256 centered). Better: inside radius about 230 (90%) to allow for the ring or border. Corners are discarded. | VERIFIED circle crop. 90% inset is a heuristic |
| Thumbnail 1920x1080 | No essential text or elements in the bottom band (metadata such as player count). Use about the bottom 20% (216 px) as a no-text zone. Keep about 5% side margins. Put the title or hook text in the upper half. | VERIFIED (bottom), 20% figure UNVERIFIED |
| Thumbnail at Home size | Text must survive at about 500x281. Glyph cap height at least ~6% of thumbnail height (about 65 px at 1080p), which gives about 17 px at 281p. | UNVERIFIED heuristic |

#### 3.6 File formats

- Icons and pass icons: **PNG** (lossless, crisp edges). For badges, use transparent corners (they are cropped anyway). Thumbnails: **PNG under 3 MB**, or high-quality JPEG (q 90-95) when the PNG would exceed 3 MB. Strip metadata. Upload sRGB 8-bit (UNVERIFIED but standard). Avoid GIF and BMP (lossy palette or large files).

---

### 4. Titles and descriptions

#### 4.1 Official description structure ([descriptions guide](https://create.roblox.com/docs/production/publishing/descriptions), VERIFIED)
1. **Hook**, about 160 characters: the core genre and primary search terms, used in search snippets.
2. **Recent updates** (optional), kept short.
3. **Main content**: core loop and key features, easy to digest.
4. **Additional info**: device support, codes, concise FAQ, credits.
- Avoid tags and hashtags, lists of controls, and FAQs that use up the 1000-character budget.
- Also: lead with a one-sentence summary of concept and genre, use keywords naturally, and avoid stuffing ([publish doc](https://create.roblox.com/docs/production/publishing/publish-games-and-places)).

#### 4.2 What top games write (OBSERVED 2026-10-07)

| Game | Hook (first line) | Rest |
|---|---|---|
| Blox Fruits | `OUT NOW: 🧲 Magnet + 🏝️ Sea 1 + MORE` | Premise paragraph, level cap, a long fruit list (keyword-rich, relevant), FAQ bullets, anti-exploit note |
| Adopt Me! | "Adopt and raise 🐶🦄👶, trade and collect legendary pets, build your dream home, and roleplay with friends!" | Event bullet list (🎃 Halloween...), "press 🔔NOTIFY" call to action, credits plus a DevForum link |
| DOORS | `EXPLORE THE STAIRWELL NOW! 🚨🔥⚙️` | One-line genre ("A horror game involving doors."), warnings (loud sounds, flashing lights), group-join reward, UGC tie-in, music credit |
| Dress To Impress | "Create stunning outfits 👗💖⭐, and strut the runway..." | 4 emoji bullets, then a Roblox community link |
| Grow a Garden | "🍅Welcome to Grow a Garden🍅 / Are you ready to grow your very own garden?..." | "[How To Plant]" bullets, "grows while you are offline⭐" |
| Steal a Brainrot | "The original brainrot game! Sneak, steal, and outsmart players in this chaotic comedy PvP stealth game." | short |
| Pet Simulator 99 | "Create an army of the coolest pets! They will help you get RICH! ✨ Currently 3,000+ pets to collect!" | short |
| 99 Nights in the Forest | "Build a camp with friends. / Something is watching you." | 3 lines total: mood over features |

Takeaways:
- The hook is either an **update banner** (live-ops games) or a **genre-plus-fantasy sentence** containing the search keywords (pets, garden, horror, outfits, PvP stealth).
- Emoji bullets at 1 per line, and no more than ~6 bullets.
- Social and community links: on-platform community or group links appear in descriptions. Off-platform links are not allowed in descriptions. Use the experience page's Social Links feature for Discord, X, YouTube and similar. Its exact rules, including age gating, were not verified today (UNVERIFIED).
- A group-join reward ("Join the group for a free Revive!") is common (DOORS). It is allowed because it is an on-platform reward, not Robux.

#### 4.3 Search and ranking

- **Search** uses relevance of the query against metadata, now with semantic understanding of natural-language queries ("food games") across supported languages ([Discovery](https://create.roblox.com/docs/discovery), VERIFIED). Put the plain genre noun ("tycoon", "obby", "horror", "pets", "tower defense") in the name or the hook.
- **Home recommendations** use play-through rate, first-play bounce rate (negative), play days per user (D1, D2-7, D8-28), playtime per user (capped at 60 min/day), intentional co-play days, qualified sessions, spend days, and Robux per user (VERIFIED). Only organic Home traffic counts.
- Demotion triggers: irrelevant keywords, non-unique or duplicate metadata, metadata that does not match gameplay, giveaways, and repetitive words in the title (VERIFIED).

#### 4.4 Localization

- Automatic translation covers the **experience name and description** ("Experience Information"), plus in-game strings and products, in 18 languages: ar, zh-hans, zh-hant, en, fr, de, hi, id, it, ja, ko, pl, pt, ru, es, th, tr, vi ([automatic translations](https://create.roblox.com/docs/en-us/production/localization/automatic-translations), VERIFIED). Lock an entry to approve or override it.
- **Badge and pass names and descriptions are not captured** by automatic translation and need manual entries (VERIFIED).
- A June 2025 experiment found that translating the name and description gave +0.87% qualified PTR, and about +4% new-player playtime for Korean and Japanese speakers ([DevForum 3878129](https://devforum.roblox.com/t/automatic-translation-experiment-results-and-next-steps/3878129), VERIFIED).
- Icons: one icon **per locale** is supported ([experience-icons](https://create.roblox.com/docs/production/publishing/experience-icons), VERIFIED). Localize the text on the icon, or use a text-free icon to avoid that work.
- Implication: avoid puns, slang and ALL-CAPS wordplay in the name. Emojis and stable proper names translate cleanly.

#### 4.5 Avoid
- "FREE", "ROBUX", "GIVEAWAY", "ADMIN", or "% OFF" in the title, description or images.
- Keyword lists, hashtags, repeated words, and more than 2-3 emojis in the title.
- Showing features, UI or graphics that do not exist in the game.
- Others' logos, characters or IP, and real people.
- External URLs in the description.

---

### 5. Linter checklist

Each rule is machine-checkable from the image file plus a small sidecar manifest (`{kind, text_layers:[{text, bbox, cap_height_px}], title, description}`). OCR is optional. A manifest is more reliable.

| ID | Check | Threshold | Severity |
|---|---|---|---|
| ICON-DIM | Icon is square, exactly 512x512 (warn if larger square, error if < 512 or not square) | w==h==512 | error |
| THUMB-DIM | Thumbnail aspect 16:9 within 0.5%, ideally 1920x1080, min 1280x720 | ratio 1.7778±0.009 | error |
| ROUND-DIM | Pass, product and badge icons square, at most 512, ideally 512 | w==h, ≤512 | error |
| FILE-FMT | Icons: png/jpg. Thumbnails: png/jpg (gif/tga/bmp allowed but warn). Pass/product: jpg/png/bmp | ext plus magic bytes | error |
| FILE-SIZE | Thumbnail < 3,000,000 bytes (stay under 3 MiB with margin). Icons < 3 MB (UNVERIFIED limit, same budget) | bytes | error |
| COLOR-SPACE | 8-bit sRGB, no CMYK, no 16-bit | mode in {RGB,RGBA} | error |
| THUMB-COUNT | 2-5 Home personalization thumbnails, at most 10 total media | count | warn |
| CIRCLE-SAFE | Round icons: pixels outside the inscribed circle hold < 5% of the edge or saliency energy. Text bboxes lie fully inside a circle of radius 0.45·W | geometry | error (text), warn (energy) |
| ICON-SAFE | Icon text and focal bboxes inside a centered inset of 8% per side | geometry | warn |
| THUMB-BOTTOM | No text bbox in the bottom 20% of thumbnail height | bbox.y2 ≤ 0.8H | error |
| THUMB-SIDE | Text bboxes inside a 5% side and top margin | geometry | warn |
| TEXT-WORDS | Icon at most 3 words. Thumbnail at most 6 words. Pass/badge at most 2 words | count | warn |
| TEXT-SIZE-ICON | Icon text cap height at least 10% of canvas (≥51 px at 512, so ≥15 px at 150) | px | error |
| TEXT-SIZE-THUMB | Thumbnail text cap height at least 6% of height (≥65 px at 1080) | px | warn |
| TEXT-CONTRAST | WCAG contrast ratio between text fill and its stroke or local background at least 4.5:1, and the stroke at least 2% of cap height | ratio | warn |
| LUMA-CONTRAST | At 150x150 grayscale downscale: luminance std-dev ≥ 0.18 (on 0-1), and the subject-vs-background mean luminance difference ≥ 0.25 if a mask is supplied | stats | warn |
| SATURATION | Mean HSV saturation ≥ 0.35 unless genre ∈ {Horror, Survival-horror} (VERIFIED docs: color conveys genre) | stats | info |
| CLUTTER | Edge density (Canny at 150 px) ≤ 0.25 of pixels. Fewer than 6 salient blobs | stats | warn |
| SMALL-PREVIEW | Emit 150, 64 and grayscale previews for human review | n/a | info |
| BANNED-TEXT | Title, description and text layers must not match `/free\s*robux|robux|giveaway|free\s*admin|\d+%\s*off|discount/i` | regex | error |
| NO-URL | Description contains no `https?://` except `roblox.com/(communities|groups|games)` | regex | error |
| DESC-LEN | Description ≤ 1000 chars. First line or sentence ≤ 160 chars and contains the genre keyword | len | error / warn |
| TITLE-LEN | Title ≤ 50 chars (UNVERIFIED hard limit; warn at > 40) | len | warn |
| TITLE-EMOJI | At most 3 emoji in the title (docs: 1-2 well placed) | count | warn |
| TITLE-REPEAT | No word repeated in the title (case-insensitive, ignoring stopwords). No more than 1 bracketed tag | regex | warn |
| TITLE-CAPS | ALL-CAPS only inside the bracketed update tag (≤ 2 words) | regex | info |
| HASHTAGS | No `#tag` tokens in the description | regex | warn |
| ALT-TEXT | Every detail-page thumbnail has alt text | manifest | info |
| LOCALE | Icon text string is listed in the manifest for localization, or the icon is text-free | manifest | info |

---

### Sources (fetched 2026-10-07)

Official Roblox:
- https://create.roblox.com/docs/production/publishing/thumbnails
- https://create.roblox.com/docs/en-us/production/publishing/thumbnails.md
- https://create.roblox.com/docs/production/promotion/promotional-thumbnails
- https://create.roblox.com/docs/production/publishing/experience-icons
- https://create.roblox.com/docs/production/promotion/game-icons
- https://create.roblox.com/docs/production/publishing/publish-games-and-places
- https://create.roblox.com/docs/en-us/production/publishing/descriptions.md
- https://create.roblox.com/docs/discovery
- https://create.roblox.com/docs/en-us/production/analytics/acquisition
- https://create.roblox.com/docs/en-us/production/publishing/experience-genres.md
- https://create.roblox.com/docs/en-us/production/promotion/content-maturity.md
- https://create.roblox.com/docs/en-us/production/promotion/experience-guidelines
- https://create.roblox.com/docs/production/monetization/game-passes
- https://create.roblox.com/docs/production/monetization/developer-products
- https://create.roblox.com/docs/production/publishing/badges
- https://create.roblox.com/docs/en-us/production/localization/automatic-translations.md
- https://create.roblox.com/docs/en-us/art/blender.md
- https://en.help.roblox.com/hc/en-us/articles/203313410-Roblox-Rules-of-Conduct
- https://devforum.roblox.com/t/weekly-recap-august-24%E2%80%9328-2026-persistent-leaderboards-opencloud-apis/4836039
- https://devforum.roblox.com/t/automatic-translation-experiment-results-and-next-steps/3878129

Live game pages (titles and descriptions as of 2026-10-07):
- https://www.roblox.com/games/126884695634066/Grow-a-Garden
- https://www.roblox.com/games/109983668079237/Steal-a-Brainrot
- https://www.roblox.com/games/79546208627805/
- https://www.roblox.com/games/2753915549/
- https://www.roblox.com/games/8737899170/
- https://www.roblox.com/games/920587237/
- https://www.roblox.com/games/6516141723/
- https://www.roblox.com/games/15101393044/

Press:
- https://gamesbeat.com/roblox-announces-new-creator-tools-for-analytics-a-b-testing-and-live-ops-exclusive/
- https://www.pocketgamer.biz/roblox-launches-new-analytics-and-experimentation-tools/

Community (DevForum and blogs):
- https://devforum.roblox.com/t/icon-ab-testing/3274267
- https://devforum.roblox.com/t/thumbnail-personalization-dynamic-max-limit/4637385
- https://devforum.roblox.com/t/qptrio-%E2%80%94-see-your-thumbnail-the-way-players-will/4690127
- https://devforum.roblox.com/t/how-should-i-go-about-improving-play-through-rate/4858140
- https://devforum.roblox.com/t/how-to-get-playthrough-rate-up/4772142
- https://devforum.roblox.com/t/is-my-game-icon-actually-this-bad-horrible-click-rate/2625742
- https://devforum.roblox.com/t/is-this-game-icon-really-that-bad-game-only-got-0012-sponsoring-ctr/2038721 (search result only)
- https://devforum.roblox.com/t/roblox-wont-save-my-experience-name-suddenly-and-im-not-sure-why-update/2663909
- https://devforum.roblox.com/t/how-to-do-gfx-for-beginners/1183890
- https://devforum.roblox.com/t/rendering-roblox-scenes/535013
- https://devforum.roblox.com/t/using-hdris-in-blender/2776630 (search result only)
- https://devforum.roblox.com/t/rbx-toolbox-free-blender-addon/2170259
- https://rowatcher.com/news/the-roblox-thumbnail-is-a-conversion-ad-stop-designing-it-like-art
- https://roblox.fandom.com/wiki/Deceptive_advertising

Adjacent research:
- https://www.searchenginejournal.com/do-faces-help-youtube-thumbnails-heres-what-the-data-says/563944/
- https://support.google.com/youtube/answer/16391400?hl=en
- https://dev.epicgames.com/documentation/uefn/ctr?lang=en-US

Tools and fonts:
- https://developer.blender.org/docs/release_notes/4.0/color_management/
- https://github.com/google/fonts (ofl/lilitaone, apache/luckiestguy, ofl/fredoka, ofl/bangers, ofl/titanone, ofl/baloo2, ofl/bowlbyone, ofl/russoone, ofl/passionone, apache/chewy METADATA.pb)

Not reachable from the sandbox: roblox image CDNs and APIs (tr.rbxcdn.com, apis.roblox.com). Icon and thumbnail imagery of top games could not be inspected directly, so section 2.1's visual descriptions are UNVERIFIED.
