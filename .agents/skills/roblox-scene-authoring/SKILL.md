---
name: roblox-scene-authoring
description: Build or edit Roblox environments with the SceneKit API (buildings with doors/windows/stairs/roofs, floors, props, paths, roads, fences, vegetation, terrain heightmaps, lighting profiles) instead of hand-writing one-off Studio scripts; validate clearances and apply with undo. Use for "build a house/street/room", "dress this area", "make terrain", "place props".
---

# Roblox scene authoring (SceneKit)

**Purpose.** Turn layout requirements into deterministic, validated geometry. Plans are pure data (Lune/CI-testable); `Apply` instantiates them in Studio with one undo waypoint.

**Triggers.** Building, room, street, settlement, interior, prop dressing, path/road/fence, vegetation, terrain, lighting setup, greybox blockouts.

**Inputs.** Footprints/regions in studs, storeys, style profile (`greybox`, `neutral-stone`, `neutral-timber`), seed, gameplay requirements (door sizes, corridor widths, cover).

**Required context.** `packages/SceneKit/SceneKit.luau` (facade + usage), `docs/scene-authoring.md` (namespace map). Do not read every module; the facade comment and the doc are enough to start.

**Tools.** Lune (`lune run`), Studio MCP `execute_luau` (apply in Studio), `tools/lune/build_fixtures.luau` (pattern for offline builds), Blender preview (`tools/blender/factory.py render-manifest`).

## Procedure
1. Write the plan in Luau: `local scene = SceneKit.Scene.new({ name, seed, style })`, then `Building.create`, `Building.wall/floor/roof/stairs/ramp/railing/column/arch/trim`, `Props.place/scatter/distribute/alignToWall/snap`, `Paths.path/road/fence`, `Vegetation.scatter/cluster/clear`, `Terrain.heightmap -> sculpt/flatten/smooth/paint -> toOps`, `Lighting.apply`. Use `scene:transformed(offset, yaw, fn)` to rotate pieces; fronts face -Z.
2. Validate before applying: `SceneKit.Validate.summary(SceneKit.Validate.scene(scene))` (part budget, door clearance, room clearance, stair rise, stair headroom, prop clipping/support). Use `Measure` for jump reach, sightlines, camera clearance, cover class.
3. Observe offline: write `scene:manifest()` to JSON and render with `python3 tools/blender/factory.py render-manifest <manifest> <dir>`; look at the PNGs.
4. Apply in Studio through Studio MCP `execute_luau`: require SceneKit from ReplicatedStorage (Rojo-synced) and call `SceneKit.Apply.scene(scene, workspace)` (replaces the previous model with the same name; one ChangeHistory waypoint). Terrain: `Apply.terrain(ops, workspace.Terrain)`.
5. Capture in Studio (`screen_capture`) from `Camera.captureSet` angles and compare with the Blender preview.

**Outputs.** Model in Workspace with `SceneKitHash/Seed/Style` attributes, manifest JSON, validation report.

**Acceptance.** Validation summary passes; manifest hash is stable for the same seed; Studio capture matches the preview; no unanchored or floating props.

**Failure handling.** Assertion errors name the bad input (opening outside wall, footprint too small for stairs). Fix the requirement, not the validator. If Studio apply fails, the waypoint is cancelled; read `get_console_output`.

**Related.** roblox-procedural-generation, roblox-level-design-review, visual-qa, roblox-studio-testing.
