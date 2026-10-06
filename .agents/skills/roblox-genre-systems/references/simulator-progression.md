# Playbook: Incremental simulator (collect, upgrade, unlock zones)

Kind: genre
Covers: Simulation > Incremental Simulator; Simulation > (none)

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no theme, items, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Collect**: an action (click, swing, walk, fish, dig) yields a resource; capacity limits how much is carried.
- **Convert**: selling or depositing turns the resource into currency.
- **Upgrade**: currency buys better tools, capacity and multipliers.
- **Expand**: gated zones open with currency or progress, each with richer sources.
- **Reset layers**: rebirth or prestige trades progress for permanent multipliers.
- **Collection layer** (often): followers or items that multiply output, obtained by rolls or quests.
- **Retention layer**: quests, daily rewards, timed events, boards.

## Kit modules
- `GameKit/Progression`: upgrades, multipliers, rebirth layers and offline accrual.
- `GameKit/Wallet`, `GameKit/EconomySim`: currencies and simulated pacing of the whole curve.
- `GameKit/Inventory`, `GameKit/ItemDefs`: tools, capacity items and collectables.
- `GameKit/Followers`, `GameKit/FollowersRoblox`, `GameKit/OddsTable`: followers and weighted rolls when the game has them.
- `GameKit/Objectives`, `GameKit/Streaks`, `GameKit/LiveOps`: quests, daily rewards and timed events.
- `GameKit/Zones`, `GameKit/Interact`: zone gates and sell or deposit points.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4): totals and rebirth boards.
- `GameKit/PlayerData`, `GameKit/Onboarding`: saved progress and the first-session path.
- `UIKit/Components/RollingCounter`, `UIKit/Components/ProgressBar`, `UIKit/Components/InventoryGrid`: counters, capacity and items.
- `Feel/Popups`, `Feel/Cues`: collection feedback.

## Data to author
- Resource sources per zone: yield, respawn, tool requirement (TBD).
- Upgrade tables and multiplier stacking rules (additive or multiplicative, TBD).
- Zone gates: cost or requirement per zone (TBD).
- Rebirth layers: cost curve, reward, what resets (TBD).
- Pacing targets for `EconomySim`: time to each zone and to the first rebirth (TBD).

## Authority and abuse risks
- **Auto-clickers and macros**: rate-limit collect requests per player (`GameKit/RateLimit`) and derive yield from server-side cooldowns.
- **Remote spoofing**: the client sends intent ("collect at node X"); the server checks distance, cooldown, tool and capacity.
- **Number overflow**: very large values lose precision past 2^53; store big numbers in a defined format and test the top of the curve.
- **Duplication on rejoin**: save after grants and never trust client-side totals.
- **Boards**: write server totals only, at a bounded rate (DataStore budgets).

## Performance pitfalls
- Thousands of collectable parts: spawn per player on the client, validate on the server, or recycle nodes.
- Many followers per player replicated to everyone: cap visible followers and simplify distant ones.
- Floating text and particles per click: pool them and throttle per frame (`AVKit/Pool`).
- Leaderboard writes every change: batch and write on a timer.

## Policy notes
- Paid rolls (eggs, crates, luck boosts) follow the paid random items rules: odds as percentages summing to exactly 100%, shown before purchase, with a `GameKit/PolicyGate` treatment for restricted players.
- Trading of rolled items checks `IsPaidItemTradingAllowed`.
- Rewarded video ads, if ever used, cannot give random rewards or gate progress (release research, section 2).

## Test checklist
- [ ] `EconomySim` reaches every zone and the first rebirth inside the target band; a broken curve (an unreachable zone) is reported.
- [ ] Collect requests above the rate limit, out of range or over capacity are refused.
- [ ] Multiplier stacking matches the authored rule at the top of the curve (no overflow, no NaN).
- [ ] Rejoin restores currencies, upgrades and zones; shutdown loses nothing acknowledged.
- [ ] Odds tables sum to exactly 100% at display precision (`GameKit/OddsTable` spec).
- [ ] Onboarding funnel events fire in order for a new player (`GameKit/Telemetry`; delivery is T4).

## Design questions (TBD)
- TBD: What is the collect action and how does it scale?
- TBD: Is there a follower or pet layer, and how are followers obtained?
- TBD: How many reset layers, and what does each keep?
- TBD: Do zones gate by currency, by progress or by both?
- TBD: Which boards exist, and what do they rank?

## Reference systems
- Feature packages Missions and Engagement Rewards as API shapes to mirror ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5; reference only).
- Systems X03, X05, X06, X14 and X19 in the genre coverage research; paid random items in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1e.
- Skills `roblox-persistence-and-commerce` and `roblox-multiplayer-integrity`.
