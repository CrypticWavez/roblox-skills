---
name: roblox-procedural-generation
description: Generate seeded, validated layouts (dungeons/room graphs, caves, arenas, settlements) with ProcGen, assign spawn/goal/encounter/treasure/landmark roles from gameplay requirements, validate connectivity/reachability/loops/dead ends/spawn fairness/player scale, save manifests and convert to SceneKit geometry. Use for "generate a dungeon/cave/arena/town", encounter or treasure placement and layout regressions.
---

# Procedural generation (ProcGen)

## Purpose
Maps generated from requirements, reproducible from a seed, with validation that proves they are playable before anyone opens Studio.

## Triggers
"Generate a dungeon/cave/arena/town", room graphs, encounter placement, treasure or optional spaces, landmark placement, a layout regression or a changed layout hash.

## Inputs
Seed, size, cell size (studs), corridor width, loop requirements (`loopChance`, `minLoops`), encounter and landmark counts, and `Validate` rules (`minCorridorStuds`, `minLoops`, `maxDeadEndRatio`, `minEncounterAreaStuds`, `maxSpawnDistanceSpread`, `maxParts`, `minRoomStuds`).

## Required context
`packages/ProcGen/*.luau` headers (generator params, `Validate` `Rules` and defaults); `tests/procgen.spec.luau` shows every API in use.

## Tools
`lune run tests/run.luau procgen` (specs whose file name contains `procgen`), `lune run tools/lune/build_fixtures.luau build/fixtures` (fixtures, hashes, `report.json`), `python3 tools/check.py --update-golden` for intended hash changes.

## Procedure
1. Generate: `Dungeon.generate`, `Cave.generate`, `Arena.generate`, `Settlement.generate` (all take `seed`).
2. Roles: `Placement.assign(layout, { encounters, landmarks, treasureInDeadEnds, optionalEncounters, minEncounterAreaStuds })` puts the spawn on the periphery, the goal farthest away, encounters paced along the critical path and a purpose in every dead end.
3. Validate: `Validate.rooms(layout, placement, rules)`, `Validate.arena(layout, rules)`, `Validate.grid(grid, rules)` or `Validate.settlement(layout)`, then `Validate.summary(checks)`. Checks: connectivity, reachability, redundant_paths, dead_end_ratio, purposeless_branches, encounter_space, camera_clearance_room, critical_path_studs, player_scale_corridor, spawn_fairness, spawn_sightline_blocked, performance_part_estimate, and the settlement footprint, road and lot checks.
4. When a check fails, change generator parameters or requirements; never loosen a rule silently. If a rule is wrong for the game, change it explicitly and record why.
5. Save `Manifest.fromLayout(layout, { roles = placement.roles })` (canonical JSON plus hash). The same seed must give the same hash.
6. Convert: `SceneKit.Layout.toScene(scene, layout, { wallHeight, ceiling, placement })` and continue with roblox-scene-authoring.

## Outputs
Layout manifest JSON with hash, validation report (`{name, pass, value, limit, detail}` per check), SceneKit scene, ASCII grid (`layout.grid:toAscii()`).

## Acceptance
All structural checks pass across a seed sweep (the specs sweep 10-25 seeds per generator); the hash is reproducible; fixture hashes change only when intended.

## Failure
- Seed-specific failure: keep the seed as a regression test in `tests/`.
- Systematic failure: fix the generator, not the validator (git history has examples: arena cover gaps, guaranteed loops, encounter room sizing).
- Hash drift without a generator change: something non-deterministic crept in (`math.random`, table iteration order); use `Rng` and sorted keys.

## Related
roblox-scene-authoring, roblox-level-design-review, visual-qa, luau-quality.
