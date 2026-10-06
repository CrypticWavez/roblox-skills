# Playbook: Tower defense (waves, lanes and placement)

Kind: genre
Covers: Strategy > Tower Defense
Also: Shooter > PvE Shooter

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no theme, units, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Map**: one or more lanes from spawn edges to a base, with build slots beside them.
- **Waves**: a director spends a per-wave budget on unit groups, spawns them on lanes over time, rests between waves and escalates.
- **Units**: follow lane waypoints, take damage, leak into the base when they arrive.
- **Defences**: placed on a grid or on build slots, pick targets in range, attack on a cooldown, upgrade or sell.
- **Economy**: currency from kills and waves pays for placement and upgrades; base health or leaks decide the loss.
- **Session**: lobby, queue and party into a match server, then results and rewards (often co-op).

## Kit modules
- `ProcGen/Course`: `Course.lanes` (seed, lane count, length) gives lane paths, spawn edges, the base and build slots; `Validate.course` checks lane balance and slot access; `Course.toScene` builds the greybox.
- `GameKit/WaveDirector`: data-defined waves (groups, cost, weight, minimum wave, budget curve, escalation, rest windows) on a seeded `ProcGen/Rng`; `tick` returns due spawns.
- `GameKit/NavAgent`, `GameKit/NavAgentRoblox` (T3): waypoint following with stuck detection and repath policy; lane units can follow authored lane points without PathfindingService.
- `GameKit/PlacementGrid`: footprints, rotation, snapping, blocked cells, refusal reasons, serialise and restore.
- `GameKit/Perception`: range and occlusion checks for targeting; `GameKit/BehaviorTree` for defence and unit behaviour with a per-tick budget.
- `GameKit/Vitals`, `GameKit/Projectile`, `GameKit/StatusEffects`: unit health, projectiles, slows and burns.
- `GameKit/Wallet`, `GameKit/Progression`, `GameKit/Inventory`: match currency, unlocks and owned defences.
- `GameKit/RoundLoop`, `GameKit/Queue`, `GameKit/TeleportRoblox` (T4), `GameKit/TeamBalance`: match flow, lobby to match server.
- `UIKit/Components/Countdown`, `UIKit/Components/StatBar`, `UIKit/Components/Card`: wave timer, base health, unit cards.
- `AVKit/VfxLibrary`, `Feel/Popups`: hits and damage numbers.

## Data to author
- Lane layout parameters or hand-built lanes, with build slots (TBD).
- Wave spec: groups with cost, weight and first wave; budget base, per-wave growth, escalation, rest; number of waves or endless (TBD).
- Unit definitions: health, speed, resistances as keys and numbers (TBD).
- Defence definitions: footprint, range, cooldown, damage, upgrade paths, placement rules (TBD).
- Economy: income per kill and per wave, costs, sell refund (TBD; simulate with `GameKit/EconomySim`).

## Authority and abuse risks
- **Placement**: the client asks, the server validates with `PlacementGrid.canPlace` (cell, rotation, ownership, currency) and refuses with a reason.
- **Currency**: only the server credits kills and waves; one credit per unit death.
- **Wave skipping and speed-up**: server-side only, with a vote or host rule (TBD).
- **Targeting and damage**: computed on the server; clients only render.
- **Rewards**: granted once per finished match, keyed by match id, after the match server validates the result.

## Performance pitfalls
- Hundreds of units with Humanoids and pathfinding: lane units can be anchored models moved along precomputed lane points; PathfindingService is only needed off-lane.
- Per-unit `Touched` and per-defence loops: batch targeting in one step function at a fixed rate.
- Projectile instances: pool them (`AVKit/Pool`) and cap live effects.
- Replicating every unit position every frame: replicate spawn time and lane, let clients interpolate, correct occasionally.

## Policy notes
- Paid random unit or defence rolls follow the paid random items rules: odds shown before purchase, summing to exactly 100% (`GameKit/OddsTable`), and a `GameKit/PolicyGate` treatment where `ArePaidRandomItemsRestricted` is set.
- Trading rolled units is gated by `IsPaidItemTradingAllowed`.
- Violence and fear levels go into the Maturity & Compliance questionnaire.

## Test checklist
- [ ] Every generated lane map passes `Validate.course` (`lane_connectivity`, `lane_balance`, `lanes_disjoint`, `slot_access`, `slot_balance`).
- [ ] Same seed, same waves: `WaveDirector.plan` is identical across runs (`tests/gamekit_world_waves.spec.luau`).
- [ ] Every spawned unit is killed or leaks; the director finishes (slice `wave_lane` in `tests/golden/gamekit-world.json`).
- [ ] Placement refuses blocked, occupied, out-of-bounds and unaffordable cells with reasons; serialise and restore round-trips.
- [ ] A client firing placement or upgrade remotes with forged arguments changes nothing.
- [ ] Economy simulation over all waves: income can afford the intended defences (TBD target) without runaway.
- [ ] Rewards grant once per match after a rejoin or teleport (T4 for real teleports).
- [ ] Probe `lvl_pathfinding_probe` (T3) when units use PathfindingService.

## Design questions (TBD)
- TBD: Fixed lanes, open-field mazing with placement-blocking, or both?
- TBD: Solo, co-op or competitive, and how many players per match?
- TBD: Endless waves or a fixed count with a final wave?
- TBD: Are defences unlocked by progression, rolls or both?
- TBD: Can players speed up or skip waves, and who decides?

## Reference systems
- Factory: fixture `course_lanes` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); slice `wave_lane` in [gamekit-world.json](../../../../tests/golden/gamekit-world.json).
- Engine: PathfindingService agent parameters, modifiers, links and blocked-path recompute ([gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), section 3).
- Systems X12 (wave director), X18 (placement grid) and X16 (matchmaking) in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md).
