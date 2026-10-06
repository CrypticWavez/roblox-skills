# Playbook: Pet care, collection and trading

Kind: genre
Covers: Roleplay & Avatar Sim > Pet Care
Also: Simulation > Incremental Simulator

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no creatures, rarities, odds, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Obtain**: hatch, roll, adopt, earn or buy companions; each has a kind and attributes (rarity, variant, level).
- **Care** (pet care): needs and tasks raise a companion's age or level; homes and roleplay around it.
- **Collect**: an index of kinds and variants; fusing or upgrading duplicates.
- **Follow and help**: equipped companions follow the player and may multiply output (simulator style).
- **Trade**: two players exchange companions and items in a confirmed, atomic trade.
- **Value**: rarity and demand drive player-perceived value; trading makes duplication and scams high-impact.

## Kit modules
- `GameKit/Followers`, `GameKit/FollowersRoblox`: equipped companions that follow and animate.
- `GameKit/OddsTable`: weighted rolls with exact disclosure (sums to exactly 100% at display precision); paid rolls refused unless the policy predicate allows.
- `GameKit/Trade`: two-sided offers, confirmation, atomic swap, cancellation.
- `GameKit/PolicyGate`, `GameKit/PolicyGateRoblox`: `ArePaidRandomItemsRestricted` and `IsPaidItemTradingAllowed`, fail closed.
- `GameKit/Inventory`, `GameKit/ItemDefs`: companion instances with unique ids and attributes.
- `GameKit/Vitals`, `GameKit/Objectives`, `GameKit/Progression`: needs, care tasks, ageing and levels.
- `GameKit/PlayerData`: saved collection with unique ids and trade history.
- `GameKit/RateLimit`, `GameKit/RemoteGuard`: trade and roll request limits.
- `UIKit/Components/InventoryGrid`, `UIKit/Components/ConfirmDialog`, `UIKit/Components/Card`: collection, trade window, odds card.
- `Cinematics/Cinematics`, `Feel/Cues`: hatch and reveal sequences (skippable).
- `GameKit/Telemetry`: economy events for sources and sinks.

## Data to author
- Companion kinds, variants and attributes (TBD).
- Roll tables per source: weights and the disclosed percentages (TBD).
- Care model: needs, tasks, ageing steps (TBD).
- Trade rules: what can be traded, value limits, cooldowns, account age (TBD).
- Fuse or upgrade rules (TBD).

## Authority and abuse risks
- **Duplication**: every companion has a unique id; a trade moves ids atomically and is saved for both players before completion (session-locked data).
- **Trade scams**: both sides confirm the final state; any change resets confirmation; a short countdown before execution.
- **Roll manipulation**: rolls happen on the server with server randomness; results are saved before the reveal.
- **Policy**: paid-roll results cannot be traded by players where `IsPaidItemTradingAllowed` is false.
- **Rollback on crash**: a trade either completes for both or for neither.

## Performance pitfalls
- Many followers per player replicated to all players: cap visible followers and simplify distant ones.
- Large collections in one remote payload: page the inventory.
- Hatch effects for every viewer: show reveals to the owner and a short version to others.

## Policy notes
- Paid random items rules: odds as percentages summing to exactly 100%, shown before purchase; odds update when an outcome can be obtained only once; probability modifiers numerically explained.
- Where `ArePaidRandomItemsRestricted` is true, apply one of the six treatments (unpaid path, predetermined order, direct purchase, hide, block, keep out of the area).
- "Paid random items and trading" is a Maturity & Compliance questionnaire category.
- No simulated gambling (Community Standards).

## Test checklist
- [ ] Odds tables sum to exactly 100% at display precision; a table that does not is refused (`GameKit/OddsTable` spec).
- [ ] Paid rolls are refused when the policy predicate fails closed.
- [ ] Trades conserve ids: no duplicate or lost companion across concurrent trades, disconnects and server crashes (scenario bots with fake stores).
- [ ] Changing an offer after confirmation resets both confirmations.
- [ ] Trading a paid-roll result is refused where trading is not allowed.
- [ ] Rejoin restores the collection; unique ids stay unique.

## Design questions (TBD)
- TBD: Care-focused, collection-focused, or both?
- TBD: How are companions obtained, and is any route paid and random?
- TBD: Is trading part of the experience, and with what limits?
- TBD: Do companions affect gameplay output or only look and roleplay?
- TBD: Is there fusing or upgrading of duplicates?

## Reference systems
- Paid random items and PolicyService rules in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1e.
- Systems X14 (followers and rolls) and X15 (trading) in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md).
- Skill `roblox-persistence-and-commerce` for session locking and receipts.
