---
name: roblox-procedural-generation
description: Generate seeded, validated layouts (dungeons/room graphs, caves, arenas, settlements, forests with biome dressing) with ProcGen, assign spawn/goal/encounter/treasure/landmark roles from gameplay requirements, validate connectivity/reachability/loops/dead ends/spawn fairness/player scale/path clearance/vegetation density, save manifests and convert to SceneKit geometry. Use for "generate a dungeon/cave/arena/town/forest", biome dressing, encounter or treasure placement and layout regressions.
---

# Procedural generation (ProcGen)

## Purpose
Maps generated from requirements, reproducible from a seed, with validation that proves they are playable before anyone opens Studio.

## Triggers
"Generate a dungeon/cave/arena/town/forest", biome or vegetation dressing of an outdoor area, room graphs, encounter placement, treasure or optional spaces, landmark placement, a layout regression or a changed layout hash.

## Inputs
Seed, size, cell size (studs), corridor width, loop requirements (`loopChance`, `minLoops`, `minLoopWallStuds`: the wall a loop must wrap, default 144 sq studs), encounter and landmark counts, and `Validate` rules (`minCorridorStuds`, `minLoops`, `maxDeadEndRatio`, `minEncounterAreaStuds`, `maxSpawnDistanceSpread`, `maxParts`, `minRoomStuds`). Forests: `width`/`depth` studs, `clearings`, `clearingRadius`, `pathWidth`, `shares` and `bands` (per-band `spacing`, `fill`, tree/bush/rock weights); rules `minTrunkSpacing` (6), `minObstacleGapStuds` (3), `spawnClearStuds` (8), `bandDensity` (default `Validate.FOREST_BAND_DENSITY`).

## Required context
`packages/ProcGen/*.luau` headers (generator params, `Validate` `Rules` and defaults); `tests/procgen.spec.luau` shows every API in use, `tests/procgen_forest.spec.luau` the forest API and its broken inputs.

## Tools
`lune run tests/run.luau procgen` (specs whose file name contains `procgen`), `lune run tools/lune/build_fixtures.luau build/fixtures` (fixtures, hashes, `report.json`), `python3 tools/check.py --update-golden` for intended hash changes.

## Procedure
1. Generate: `Dungeon.generate`, `Cave.generate`, `Arena.generate`, `Settlement.generate`, `Forest.generate` (all take `seed`). A forest is noise-ranked bands (open, sparse, dense, rocky), clearings with landmark/encounter/treasure roles, a spanning path network from the west-edge entry through every clearing to the east-edge exit, and trees, bushes and rocks spaced per band outside the path corridor; it needs no `Placement`.
2. Roles: `Placement.assign(layout, { encounters, landmarks, treasureInDeadEnds, optionalEncounters, minEncounterAreaStuds })` puts the spawn on the periphery and the goal in the farthest room big enough for an encounter, choosing among the shortest routes the one with room for the requested encounters; encounters are paced along that critical path and every dead end gets a purpose. Encounters that do not fit are returned as `unplacedEncounters`, never squeezed into cramped rooms.
3. Validate: `Validate.rooms(layout, placement, rules)`, `Validate.arena(layout, rules)`, `Validate.grid(grid, rules)`, `Validate.settlement(layout)` or `Validate.forest(layout, rules)`, then `Validate.summary(checks)`. Checks: connectivity, reachability, redundant_paths (walkable loops on the carved grid that wrap at least `minLoopWallStuds` of wall, not loops in the abstract room graph), dead_end_ratio, purposeless_branches, encounter_space, encounters_placed, camera_clearance_room, critical_path_studs, player_scale_corridor, spawn_fairness, spawn_sightline_blocked, performance_part_estimate, and the settlement footprint, road and lot checks. Forest checks are measured from geometry: path_clearance (no trunk or rock edge in the corridor), clearing_reachability (BFS on a 2-stud walk grid of path and clearing cells minus trunk/rock discs grown by half a character width), spawn_clear, band_density (trunks+rocks per 1000 sq studs of plantable band area; bands under 4096 sq studs are reported unchecked), min_trunk_spacing, obstacle_gap, clearing_space, clearings_placed, performance_part_estimate (exact `Forest.partEstimate`).
4. When a check fails, change generator parameters or requirements; never loosen a rule silently. If a rule is wrong for the game, change it explicitly and record why.
5. Save `Manifest.fromLayout(layout, { roles = placement.roles })` (canonical JSON plus hash). The same seed must give the same hash.
6. Convert: `SceneKit.Layout.toScene(scene, layout, { wallHeight, ceiling, placement })`; forests: `ProcGen.ForestScene.toScene(scene, layout)` (band ground tiles, paths, clearing pads, `Vegetation.tree/bush`, rock props, non-collidable role markers). Continue with roblox-scene-authoring.

## Outputs
Layout manifest JSON with hash, validation report (`{name, pass, value, limit, detail}` per check), SceneKit scene, ASCII grid (`layout.grid:toAscii()`; forests `Forest.toAscii(layout)`).

## Acceptance
All structural checks pass across a seed sweep (the specs sweep 10-30 seeds per generator); the hash is reproducible; fixture hashes change only when intended.

## Failure
- Seed-specific failure: keep the seed as a regression test in `tests/`.
- Systematic failure: fix the generator, not the validator (git history has examples: arena cover gaps, guaranteed loops, encounter room sizing).
- Hash drift without a generator change: something non-deterministic crept in (`math.random`, table iteration order); use `Rng` and sorted keys.

## Related
roblox-scene-authoring, roblox-level-design-review, visual-qa, luau-quality.
