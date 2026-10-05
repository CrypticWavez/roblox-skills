---
name: roblox-procedural-generation
description: Generate seeded, validated layouts (dungeons/room graphs, caves, arenas, settlements) with ProcGen, assign spawn/goal/encounter/treasure/landmark roles from gameplay requirements, validate connectivity/reachability/loops/dead ends/spawn fairness/player scale, save manifests and convert to SceneKit geometry.
---

# Procedural generation (ProcGen)

**Purpose.** Maps generated from requirements, reproducible from a seed, with validation that proves they are playable before anyone opens Studio.

**Triggers.** "generate a dungeon/cave/arena/town", room graphs, encounter placement, treasure/optional spaces, landmark placement, layout regression.

**Inputs.** Seed, size, cell size (studs), corridor width, loop requirements (`minLoops`, `loopChance`), encounter count, rules for `Validate` (`minCorridorStuds`, `minEncounterAreaStuds`, `maxSpawnDistanceSpread`, `maxParts`).

**Required context.** `packages/ProcGen/*.luau` headers; `tests/procgen.spec.luau` shows every API in use.

**Tools.** `lune run tests/run.luau procgen`, `lune run tools/lune/build_fixtures.luau`.

## Procedure
1. Generate: `Dungeon.generate`, `Cave.generate`, `Arena.generate`, `Settlement.generate` (all take `seed`).
2. Roles: `Placement.assign(layout, { encounters, landmarks, treasureInDeadEnds, minEncounterAreaStuds })` puts spawn on the periphery, goal farthest away, encounters paced along the critical path, purpose in every dead end.
3. Validate: `Validate.rooms / arena / grid / settlement` then `Validate.summary`. Checks: connectivity, reachability, redundant_paths, dead_end_ratio, purposeless_branches, encounter_space, camera_clearance_room, player_scale_corridor, spawn_fairness, spawn_sightline_blocked, performance_part_estimate, footprint checks.
4. When a check fails, change generator parameters or requirements (never loosen a rule silently); if a rule is wrong for the game, change it explicitly and record why.
5. Save `Manifest.fromLayout(layout, { roles = placement.roles })` (canonical JSON + hash). Same seed must give the same hash.
6. Convert: `SceneKit.Layout.toScene(scene, layout, { wallHeight, placement })` and continue with roblox-scene-authoring.

**Outputs.** Layout manifest JSON with hash, validation report, SceneKit scene.

**Acceptance.** All structural checks pass across a seed sweep (the spec runs 10-25 seeds per generator); hash reproducible.

**Failure handling.** Seed-specific failure: keep the seed as a regression test. Systematic failure: fix the generator (examples in git history: arena cover gaps, guaranteed loops, encounter room sizing).

**Related.** roblox-scene-authoring, roblox-level-design-review.
