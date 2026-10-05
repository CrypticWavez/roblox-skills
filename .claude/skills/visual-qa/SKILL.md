---
name: visual-qa
description: See and compare what was built - render SceneKit manifests and Blender assets to PNG headlessly, capture Studio views from standard camera angles, and diff scene manifests for regressions. Use after any visual change, before claiming something looks right, and for before/after evidence.
---

# Visual QA

## Purpose
Close the loop between authoring and looking. Screenshots alone are not proof; pair them with manifest diffs and validation results.

## Triggers
After any change to SceneKit/ProcGen output or a Blender asset; before saying something looks right; when before/after evidence is needed; when a fixture hash changed.

## Inputs
A SceneKit manifest (`scene:manifest()` JSON or `build/fixtures/<name>.manifest.json`), a Blender asset, or a model in the Studio diagnostic place; for regressions, the old and new manifests.

## Required context
`packages/SceneKit/Camera.luau` (`ANGLES`, `frame`, `captureSet`; fronts face -Z), `tools/blender/bkit/render.py` (`render_manifest`, `render_objects`), `docs/scene-authoring.md`.

## Tools
- Scenes offline: `python3 tools/blender/factory.py render-manifest <manifest.json> <out_dir>` (Cycles CPU) writes `<scene name>.three-quarter.png` and `<scene name>.top.png`. A manifest without `cameras` (plain `scene:manifest()`) is framed from its part bounds the same way `Camera.captureSet` does.
- Assets: `factory.py template <kind> <out_dir>` (and `templates` unless `--no-previews`) writes `<kind>.front.png` and `<kind>.three-quarter.png`; `factory.py qa` renders nothing. For any other object set: `bkit.render.render_objects(objects, out_dir, prefix)`.
- Studio: `SceneKit.Camera.captureSet(min, max)` returns `{ eye, focus, fov }` per angle as plain `{x, y, z}` tables; convert them before `CFrame.lookAt` (snippet below), then Studio MCP `screen_capture`.
- Regression: `SceneKit.Scene.compare(oldManifest, newManifest)` returns `identical`, `added`, `removed`, `changed` part ids; `lune run tools/lune/build_fixtures.luau build/fixtures` prints and records each fixture's hash in `report.json`.

Studio camera via `execute_luau` (`scene` is the SceneKit plan; for an existing model use `model:GetBoundingBox()` and pass `{x, y, z}` corner tables):
```lua
local SK = require(game.ReplicatedStorage.Workbench.SceneKit.SceneKit)
local function v3(t) return Vector3.new(t.x, t.y, t.z) end
local view = SK.Camera.captureSet(scene:bounds())["three-quarter"]
local cam = workspace.CurrentCamera
cam.FieldOfView = view.fov
cam.CFrame = CFrame.lookAt(v3(view.eye), v3(view.focus))
```

## Procedure
1. Produce the manifest (SceneKit) or asset (Blender).
2. Render or capture the standard angles (`front`, `three-quarter`, `side`, `top`). In Studio apply a fixed lighting profile first: `SK.Lighting.apply(game.Lighting, "inspection-flat")` for geometry, `"neutral-day"` for look.
3. Look at every image with the Read tool; describe what is wrong concretely (floating parts, z-fighting, wrong front, gaps, scale against a 5.5-stud character).
4. For changes, diff the manifests with `Scene.compare` and attach before/after images.

## Outputs
PNG previews or Studio captures per angle, the manifest diff, and a short written finding per image.

## Acceptance
Every image was reviewed in this session; the diff explains every changed part; SceneKit/ProcGen validation passes.

## Failure
- Blender previews use approximate materials (Roblox materials map to flat colours); the final look needs a Studio capture, and art quality needs human approval.
- A capture looks wrong: check the camera came from `captureSet` (front on -Z), the model is where the manifest says, and no stale model with the same name remains.
- `render-manifest` on an empty manifest fails: there are no parts to frame.

## Related
roblox-scene-authoring, roblox-procedural-generation, blender-asset-factory, roblox-studio-testing.
