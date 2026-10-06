# Playbook: Tycoon (plots, generators and rebirth)

Kind: genre
Covers: Simulation > Tycoon

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no theme, items, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Plot**: each player claims one plot on join; ownership ends on leave (or persists, TBD).
- **Generators**: machines produce currency over time or per item (droppers, conveyors, collectors).
- **Purchase buttons**: buying unlocks the next buttons along a dependency graph; each purchase places parts on the plot.
- **Collect and spend**: income accumulates (on the plot or in the wallet) and pays for the next unlock.
- **Rebirth**: reset plot and currency for a permanent multiplier or unlock.
- **Optional**: offline earnings, stealing or raiding other plots, shared upgrades.

## Kit modules
- `GameKit/Plots`: plot claim, ownership and release.
- `GameKit/Generators`: income sources with rates, caps and offline accrual inputs.
- `GameKit/UnlockGraph`: purchase-button dependency graph, validated for no cycles and reachability from the start.
- `GameKit/Wallet`, `GameKit/EconomySim`: currency ledger and economy simulation of the full unlock path.
- `GameKit/Progression`: multipliers, upgrades and rebirth resets.
- `GameKit/PlacementGrid`: when players place their own machines instead of fixed buttons.
- `GameKit/PlayerData`: persisted plot state (serialised unlocks, not instances).
- `GameKit/Interact`: purchase pads and prompts; `GameKit/Zones` for plot boundaries.
- `UIKit/Components/RollingCounter`, `UIKit/Components/ShopCard`, `UIKit/Components/ConfirmDialog`: earnings and purchases.
- `Feel/Popups`, `AVKit/VfxLibrary`: purchase and income feedback.
- `GameKit/Telemetry`: economy sources and sinks events.

## Data to author
- Unlock graph: nodes (key, cost, prerequisites, what it places) and edges (TBD).
- Generator table: output, interval, cap, upgrade multipliers (TBD).
- Rebirth rules: what resets, what persists, cost curve, multiplier curve (TBD).
- Plot layout: plot count per server and plot size, built with `SceneKit/Layout` or `ProcGen/Settlement` lots.
- Economy targets for `EconomySim`: time to first rebirth, time per unlock (TBD).

## Authority and abuse risks
- **Purchases**: the server checks prerequisites, cost and plot ownership in one step; the client only asks.
- **Collector spoofing**: income is computed from server time and generator state, never from client-reported item counts.
- **Plot theft and griefing**: only the owner (or invited players, TBD) can buy or collect on a plot.
- **Rebirth duplication**: rebirth is one atomic server operation that resets and grants together, saved before acknowledging.
- **Offline earnings**: computed from the saved timestamp with a cap; the client clock is never used.

## Performance pitfalls
- Physical droppers spawning parts forever: cap live items, pool them, or simulate output without parts.
- Many plots with full builds: stream or simplify distant plots; budget parts per plot with `SceneKit/Budgets`.
- Saving instance trees: save unlock keys and rebuild from data on join.
- Per-second remote updates of every counter: replicate rates and let the client extrapolate.

## Policy notes
- Paid multipliers and boosts are developer products or passes; prompts go through `GameKit/CommerceRoblox` and the factory hooks ask before any prompt.
- Random rewards bought with Robux follow the paid random items rules (`GameKit/OddsTable`, `GameKit/PolicyGate`).
- Stealing mechanics that touch paid items interact with `IsPaidItemTradingAllowed` when items move between players (check with `GameKit/PolicyGate`).

## Test checklist
- [ ] `UnlockGraph` validation: no cycles, every node reachable from the start; a cycle is refused with its path.
- [ ] `EconomySim` over the full graph reaches the last unlock and the first rebirth within the target band (TBD).
- [ ] Buying without prerequisites, without currency or on another player's plot is refused with a reason.
- [ ] Rejoin restores the plot from saved keys; a forced shutdown loses nothing acknowledged.
- [ ] Rebirth twice in quick succession grants once.
- [ ] Offline earnings respect the cap and ignore client time.
- [ ] Plot release on leave cleans every instance (`GameKit/Scope`).

## Design questions (TBD)
- TBD: Fixed purchase buttons or free placement of machines?
- TBD: Does income go to the plot (collect step) or straight to the wallet?
- TBD: What survives a rebirth?
- TBD: Is there interaction between plots (visiting, stealing, trading)?
- TBD: Are there offline earnings, and with what cap?

## Reference systems
- Roblox template "Move It Simulator" and the feature packages (Bundles, Season Passes) as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Systems X13 (plots and generators), X03 (wallet), X05 (progression and rebirth) in the genre coverage research.
- Factory: `ProcGen/Settlement` lots and `SceneKit/Layout` for plot grids; skill `roblox-persistence-and-commerce`.
