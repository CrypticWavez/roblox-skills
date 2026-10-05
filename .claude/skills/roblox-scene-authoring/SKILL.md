---
name: roblox-scene-authoring
description: Build or edit Roblox environments with the SceneKit API (buildings with doors/windows/stairs/roofs, floors, props, paths, roads, fences, vegetation, terrain heightmaps, lighting profiles) instead of hand-writing one-off Studio scripts; validate clearances and apply with undo. Use for "build a house/street/room", "dress this area", "make terrain", "place props".
---

# Roblox scene authoring (SceneKit)

## Purpose
Turn layout requirements into deterministic, validated geometry. Plans are pure data (Lune- and CI-testable); `Apply` instantiates them in Studio inside one undo recording.

## Triggers
Building, room, street, settlement, interior, prop dressing, path/road/fence, vegetation, terrain, lighting setup, greybox blockouts.

## Inputs
Footprints/regions in studs, storeys, style profile (`greybox`, `neutral-stone`, `neutral-timber`), seed, gameplay requirements (door sizes, corridor widths, cover).

## Required context
`packages/SceneKit/SceneKit.luau` (facade and usage) and `docs/scene-authoring.md` (concept-to-call map). Read a module only when you need its option names; `tests/scenekit.spec.luau` shows each API in use.

## Tools
- Lune: `lune run <script>`; `tools/lune/build_fixtures.luau` is the pattern for offline builds.
- Studio MCP `execute_luau` with `fixtures/factory.project.json` synced: `local SceneKit = require(game.ReplicatedStorage.Workbench.SceneKit.SceneKit)`.
- Blender preview: `python3 tools/blender/factory.py render-manifest <manifest.json> <out_dir>`.

## Procedure
1. Write the plan in Luau: `local scene = SceneKit.Scene.new({ name = ..., seed = ..., style = ... })`, then `Building.create`, `Building.wall/floor/roof/stairs/ramp/railing/column/arch/trim`, `Props.place/scatter/distribute/alignToWall/snap`, `Paths.path/road/fence`, `Vegetation.scatter/cluster/clear`, `Terrain.heightmap` -> `sculpt/flatten/smooth/paint` -> `toOps`. Use `scene:transformed(offset, yaw, fn)` to place rotated pieces; fronts face -Z.
2. Validate before applying: `SceneKit.Validate.summary(SceneKit.Validate.scene(scene, { maxParts = ... }))` (part budget, door clearance, room clearance, stair rise, stair obstruction, stair headroom, prop clipping, prop support). Use `Measure` for jump reach, sightlines, camera clearance and cover class (roblox-level-design-review).
3. Observe offline: in Lune, `fs.writeFile("build/<name>.manifest.json", serde.encode("json", scene:manifest()))`, then `factory.py render-manifest build/<name>.manifest.json build/previews` (cameras are framed from the part bounds) and look at the PNGs (visual-qa).
4. Apply in Studio via `execute_luau`: `SceneKit.Apply.scene(scene, workspace)` replaces the previous SceneKit model with the same name (only one carrying `SceneKitHash`) inside one ChangeHistory recording; pass `{ replace = false }` to keep it, `{ dryRun = true }` for counts and hash only. Lighting: `SceneKit.Lighting.apply(game.Lighting, "neutral-day")`. Terrain: `SceneKit.Apply.terrain(ops, workspace.Terrain)`.
5. Capture in Studio (`screen_capture`) from `Camera.captureSet` angles (visual-qa) and compare with the Blender preview.

## Outputs
A Model in Workspace with `SceneKitHash`, `SceneKitSeed`, `SceneKitStyle` and `Provenance` attributes (parts carry `SceneKitId` and `Role`), the manifest JSON, the validation report. `Apply.scene` returns `summary, model`.

## Acceptance
Validation summary passes; the manifest hash is stable for the same seed; the Studio capture matches the preview; no unanchored or floating props.

## Failure
- Assertion errors name the bad input (opening outside a wall, footprint too small for stairs): fix the requirement, not the validator.
- If the Studio apply errors, the ChangeHistory recording is cancelled and the new model is never parented; read `get_console_output`.
- A duplicate model after re-applying means `replace = false` was passed or the old model has no `SceneKitHash` (not SceneKit-made); delete it by hand.
- Terrain ops need Studio's voxel engine; Lune cannot apply them.

## Related
roblox-procedural-generation, roblox-level-design-review, visual-qa, roblox-studio-testing.
