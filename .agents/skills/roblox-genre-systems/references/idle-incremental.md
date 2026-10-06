# Playbook: Idle and clicker

Kind: genre
Covers: Simulation > Idle
Also: Simulation > Incremental Simulator; Puzzle > Match & Merge

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no theme, generators, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Tap or click**: an active action yields currency; upgrades raise its yield.
- **Generators**: bought producers yield currency per second without input; their costs grow per purchase.
- **Offline progress**: time away converts to currency with a cap.
- **Prestige**: reset for a permanent multiplier, sometimes in several layers.
- **Milestones**: generator counts or totals unlock multipliers and new generators.
- **Merge variant**: combine equal items into higher tiers on a board.
- **Small space**: often a single screen or a small area, so UI carries most of the experience.

## Kit modules
- `GameKit/Generators`: producers with rates, cost growth and caps.
- `GameKit/Progression`: upgrades, milestones, prestige layers, offline accrual from explicit timestamps.
- `GameKit/Wallet`, `GameKit/EconomySim`: currencies and simulated pacing to each milestone and prestige.
- `GameKit/Objectives`, `GameKit/Streaks`: goals and daily returns.
- `GameKit/PlayerData`: saved state with large-number values.
- `GameKit/RateLimit`: click and tap request limits.
- `GameKit/PlacementGrid`: the merge board, when the game has one.
- `UIKit/Components/RollingCounter`, `UIKit/Components/ProgressBar`, `UIKit/Components/Card`: number-heavy panels.
- `Feel/Popups`, `Feel/Spring`: number pops and button feel.
- `GameKit/Telemetry`: economy sources and sinks.

## Data to author
- Generator table: base rate, base cost, growth factor, unlock condition (TBD).
- Upgrade and milestone tables (TBD).
- Prestige formula and what resets (TBD).
- Offline rules: cap, rate, whether boosts apply (TBD).
- Number format: notation and precision for very large values (TBD).
- Pacing targets for `EconomySim` (TBD).

## Authority and abuse risks
- **Auto-clickers**: rate-limit taps per player; derive yield from server-side counts within the limit.
- **Clock tampering**: offline progress uses server timestamps saved with the profile, never the client clock.
- **Precision**: values beyond 2^53 lose integer precision; pick a large-number format and test the top of the curve.
- **Save rollback exploits**: saves are session-locked; a stale server cannot overwrite newer progress.

## Performance pitfalls
- Updating many counters every frame with remotes: send rates and timestamps, let the client extrapolate, resync periodically.
- Number formatting per frame for many labels: cache formatted strings.
- Particle effects on every tap: pool and throttle.

## Policy notes
- Boosts sold for Robux are developer products or passes routed through `GameKit/CommerceRoblox`; random boosts follow the paid random items rules.
- Rewarded video ads, if ever used, cannot give random rewards or gate progress (release research, section 2).

## Test checklist
- [ ] `EconomySim` reaches each milestone and prestige within the target band; a curve that stalls is reported.
- [ ] Offline progress respects the cap and ignores the client clock.
- [ ] Tap requests above the rate limit are refused.
- [ ] Values at the top of the curve stay finite and display correctly.
- [ ] Prestige resets exactly what the rules say and grants once.
- [ ] Save and rejoin restore every generator count and multiplier.

## Design questions (TBD)
- TBD: How much active play versus idle time?
- TBD: How many prestige layers?
- TBD: Is there an offline cap, and what is it?
- TBD: Single screen, small world, or merge board?
- TBD: Which number notation do players see?

## Reference systems
- Systems X05, X06 and X13 in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md); no Idle-labelled game appeared in the sorts read there.
- Rewarded video ads rules in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 2.
- Skill `roblox-persistence-and-commerce` for session-locked saves.
