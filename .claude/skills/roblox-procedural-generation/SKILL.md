---
name: roblox-procedural-generation
description: Generate seeded, validated layouts with ProcGen. Covers dungeons and room graphs, caves, arenas, settlements and forests, plus course generators sized from real jump physics (obby linear, tower, race loop, tower-defense lanes, micro-arenas). Assign spawn, goal, encounter, treasure and landmark roles; validate connectivity, reachability, loops, dead ends, spawn fairness, player scale, jumpable gaps, checkpoint spacing, turn radius, lane balance and vegetation density; save manifests and convert to SceneKit geometry. Use for "generate a dungeon/cave/arena/town/forest/obby/tower/track/lanes/minigame arena" and layout regressions.
---

# Procedural generation (ProcGen)

## Purpose
Maps and courses generated from requirements, reproducible from a seed, with validation that proves they are playable before anyone opens Studio. Courses are sized from the character's jump physics (`SceneKit/Measure`), so every gap is jumpable by construction and `Validate.course` proves it from the geometry alone.

## Triggers
"Generate a dungeon/cave/arena/town/forest", "an obby/tower/race track/TD lanes/minigame arena", biome or vegetation dressing, room graphs, encounter placement, treasure or optional spaces, landmark placement, a layout regression or a changed layout hash.

## Inputs
- Layouts: seed, size, cell size (studs), corridor width, loop requirements (`loopChance`, `minLoops`, `minLoopWallStuds`: the wall a loop must wrap, default 144 sq studs), encounter and landmark counts, and `Validate` rules (`minCorridorStuds`, `minLoops`, `maxDeadEndRatio`, `minEncounterAreaStuds`, `maxSpawnDistanceSpread`, `maxParts`, `minRoomStuds`).
- Forests: `width`/`depth` studs, `clearings`, `clearingRadius`, `pathWidth`, `shares` and `bands` (per-band `spacing`, `fill`, tree/bush/rock weights); rules `minTrunkSpacing` (6), `minObstacleGapStuds` (3), `spawnClearStuds` (8), `bandDensity` (default `Validate.FOREST_BAND_DENSITY`).
- Courses (course/1): every generator takes `seed`, `difficultyCurve` (nil, a number, `{from, to, shape}` or `{points}`), `segmentKinds` (subset of `Course.SEGMENT_KINDS[kind]`), `playerScale` (a number, or a table overriding `scale`, `gravity`, `walkSpeed`, `jumpHeight`, `characterHeight`, `characterWidth` for `Measure.profile`), plus per kind: linear `length`, `checkpointEvery`, `baseHeight`, `turnChance`, `margin`; tower `floors`, `floorHeight`, `coreRadius`; race loop `laps`, `length`, `width`, `gates`, `maxGateSpacing`, `slots`, `minTurnRadius`, `maxBank`, `maxGrade`, `hillHeight`; lanes `lanes`, `length` (rows), `bandWidth`, `cellSize`, `slots`, `range`; micro-arena `players`, `shape` (round or square), `areaPerPlayer`, `edge` (drop or wall), `edgeClearance`. Limits marked "convention" in the module headers are level-design choices, not Roblox numbers.

## Required context
`packages/ProcGen/*.luau` headers (generator params, `Validate` `Rules` and defaults; `Course.luau`, `CourseValidate.luau` and `CourseScene.luau` for courses); `tests/procgen.spec.luau` shows every layout API in use, `tests/procgen_forest.spec.luau` the forest API and its broken inputs, `tests/procgen_course.spec.luau` the course API, a seed sweep and exact failure reasons.

## Tools
- `lune run tests/run.luau procgen` (specs whose file name contains `procgen`).
- `lune run tools/lune/build_fixtures.luau build/fixtures` (fixtures, hashes, `report.json`; includes `course_linear`, `course_tower`, `course_race_loop`, `course_lanes`, `course_micro_arena`).
- `python3 tools/blender/factory.py render-manifest build/fixtures/<fixture>.manifest.json build/previews` (headless top and three-quarter previews; look at them with the Read tool).
- `python3 tools/check.py --update-golden=fixture-hashes` for intended hash changes (scoped; it adds or rewrites fixture hashes only).

## Procedure
1. Generate: `Dungeon.generate`, `Cave.generate`, `Arena.generate`, `Settlement.generate`, `Forest.generate`, or a course with `Course.linear`, `Course.tower`, `Course.raceLoop`, `Course.lanes`, `Course.microArena` (or `Course.generate({ kind = ... })`). All take `seed`. A forest is noise-ranked bands, clearings with roles and a spanning path network from the west-edge entry to the east-edge exit; it needs no `Placement`. A course returns its own spawn, finish, checkpoints, segments and hash; generator `problems` (bad params) raise.
2. Roles (room layouts): `Placement.assign(layout, { encounters, landmarks, treasureInDeadEnds, optionalEncounters, minEncounterAreaStuds })` puts the spawn on the periphery and the goal in the farthest room big enough for an encounter, paces encounters along the critical path and gives every dead end a purpose. Encounters that do not fit are returned as `unplacedEncounters`, never squeezed in.
3. Validate: `Validate.rooms(layout, placement, rules)`, `Validate.arena(layout, rules)`, `Validate.grid(grid, rules)`, `Validate.settlement(layout)`, `Validate.forest(layout, rules)` or `Validate.course(course, rules)`, then `Validate.summary(checks)`.
   - Layout checks: connectivity, reachability, redundant_paths (walkable loops on the carved grid that wrap at least `minLoopWallStuds` of wall), dead_end_ratio, purposeless_branches, encounter_space, encounters_placed, camera_clearance_room, critical_path_studs, player_scale_corridor, spawn_fairness, spawn_sightline_blocked, performance_part_estimate, and the settlement footprint, road and lot checks.
   - Forest checks are measured from geometry: path_clearance, clearing_reachability (2-stud walk grid minus trunk/rock discs grown by half a character width), spawn_clear, band_density, min_trunk_spacing, obstacle_gap, clearing_space, clearings_placed, performance_part_estimate.
   - Course checks are measured from the manifest, never from the generator's notes: linear and tower jumpable_gaps (`Measure.canJump` with the course's profile and margin), reachability, checkpoint_gating, checkpoint_spacing, difficulty_curve (monotone within a tolerance), landing_size, pad_overlap, headroom, hazard_placement, spawn_clearance; race loop loop_closed, min_turn_radius, max_grade, max_bank, track_clearance, gate_spacing, gate_coverage, grid_slots; lanes lane_connectivity, lanes_disjoint, lane_balance, slot_balance, slot_access, lane_width; micro-arena spawn_fairness, spawn_symmetry, spawn_separation, spawn_edge_clearance, area_per_player, spawn_clear, spawn_on_floor, piece_overlap; every kind course_hash.
4. When a check fails, change generator parameters or requirements; never loosen a rule silently. If a rule is wrong for the game, change it explicitly and record why. A micro-arena that cannot fit its hazard ring reports it in `course.dropped` instead of overlapping pieces.
5. Save `Manifest.fromLayout(layout, { roles = placement.roles })` (canonical JSON plus hash); a course is its own manifest (`course.hash`). The same seed must give the same hash.
6. Convert: `SceneKit.Layout.toScene(scene, layout, { wallHeight, ceiling, placement })`; forests `ProcGen.ForestScene.toScene(scene, layout)`; courses `Course.toScene(course, style?, { name? })`. Course parts carry an `asset` attribute (a kit/1 piece key such as `course_platform`) plus the attributes GameKit binds to (`Checkpoint`, `SpawnSlot`, `Finish`, `Hazard`, `Gate`, `BuildSlot`, `Lane`), so `SceneKit/Apply` `Apply.swap` can replace greybox with kit pieces and `GameKit/Checkpoints.fromCourse` can drive the run. Continue with roblox-scene-authoring.
7. Look: render the fixture previews and inspect them; fix overlaps, floating pieces or skirts in the generator.

## Outputs
Layout or course manifest JSON with hash, validation report (`{name, pass, value, limit, detail}` per check), SceneKit scene, ASCII grid (`layout.grid:toAscii()`; forests `Forest.toAscii(layout)`), preview PNGs under `build/previews`.

## Acceptance
- All structural checks pass across a seed sweep (the specs sweep 10-40 seeds per generator); the hash is reproducible; fixture hashes change only when intended.
- Courses: a deliberately broken course (a widened gap, an open loop, unequal lanes, a spawn on a hazard) fails with its exact check and detail.
- Previews inspected for each changed generator.
- Engine numbers: probe `lvl_course_run` confirms gravity, walk speed and jump height match `Measure.ENGINE` on the diagnostic place (T3; pending until the owner runs it).

## Failure
- Seed-specific failure: keep the seed as a regression test in `tests/`.
- Systematic failure: fix the generator, not the validator (git history has examples: arena cover gaps, guaranteed loops, encounter room sizing, micro-arena hazard rings).
- Hash drift without a generator change: something non-deterministic crept in (`math.random`, table iteration order); use `Rng` and sorted keys.
- The game changes character physics (jump power, gravity, scale): pass the changed numbers through `playerScale` (a table of overrides) and regenerate; never hand-widen a validated gap.

## Related
roblox-scene-authoring, roblox-level-design-review, roblox-genre-systems, visual-qa, luau-quality.
