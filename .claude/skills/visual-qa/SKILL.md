---
name: visual-qa
description: See and compare what was built - render SceneKit manifests and Blender assets to PNG headlessly, capture Studio views from standard camera angles as named capture plans, flag captures whose scene hash went stale, and diff scene manifests for regressions. Use after any visual change, before claiming something looks right, and for before/after evidence.
---

# Visual QA

## Purpose
Close the loop between authoring and looking. Screenshots alone are not proof; pair them with manifest diffs and validation results.

## Triggers
After any change to SceneKit/ProcGen output or a Blender asset; before saying something looks right; when before/after evidence is needed; when a fixture hash changed or `tools/capture_staleness.py` reports STALE.

## Inputs
A SceneKit manifest (`scene:manifest()` JSON or `build/fixtures/<name>.manifest.json`), a Blender asset, or a model in the Studio diagnostic place; for regressions, the old and new manifests.

## Required context
`packages/SceneKit/Camera.luau` (`ANGLES`, `frame`, `captureSet`; fronts face -Z), `packages/Pipeline/CaptureSet.luau` (named capture plans, schema capture-manifest/1), `tools/blender/bkit/render.py` (`render_manifest`, `render_objects`), `docs/scene-authoring.md`.

## Tools
- Scenes offline: `python3 tools/blender/factory.py render-manifest <manifest.json> <out_dir>` (Cycles CPU) writes `<scene name>.three-quarter.png` and `<scene name>.top.png`. A manifest without `cameras` (plain `scene:manifest()`) is framed from its part bounds the same way `Camera.captureSet` does.
- Assets: `factory.py template <kind> <out_dir>` (and `templates` unless `--no-previews`) writes `<kind>.front.png` and `<kind>.three-quarter.png`; `factory.py qa` renders nothing. For any other object set: `bkit.render.render_objects(objects, out_dir, prefix)`.
- Studio: `SceneKit.Camera.captureSet(min, max)` returns `{ eye, focus, fov }` per angle as plain `{x, y, z}` tables; convert them before `CFrame.lookAt` (snippet below), then Studio MCP `screen_capture`.
- Capture plans: `Pipeline.CaptureSet.plan({ scene, source = "fixture" | "studio-smoke", sceneHash, bounds = { min, max }, profiles?, angles? })` names every shot `<scene>.<profile>.<angle>` (file `<id>.png`) and records the scene hash; `CaptureSet.apply(camera, shot, { Vector3 = Vector3, CFrame = CFrame })` sets the Studio camera; `CaptureSet.validate(manifest)` lists problems. Save the plan as `manifest.json` next to the images.
- Staleness: `python3 tools/capture_staleness.py [paths]` compares each capture manifest's scene hash, and each `reports/studio/smoke-*.json` record, with `tests/golden/fixture-hashes.json` or `tests/golden/studio-smoke.json`: CURRENT, STALE (recapture), INCOMPLETE (an image is missing), INVALID. `--json` for machines; `--fail-stale` makes STALE and INCOMPLETE exit 1.
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
2. Render or capture the standard angles (`front`, `three-quarter`, `side`, `top`). In Studio apply a fixed lighting profile first: `SK.Lighting.apply(game.Lighting, "inspection-flat")` for geometry, `"neutral-day"` for look. For captures you keep, make a CaptureSet plan with the current scene hash, take one image per shot under `reports/`, and write `manifest.json` beside them.
3. Look at every image with the Read tool; describe what is wrong concretely (floating parts, z-fighting, wrong front, gaps, scale against a 5.5-stud character).
4. For changes, diff the manifests with `Scene.compare` and attach before/after images.
5. After a fixture hash changes, run `python3 tools/capture_staleness.py` and recapture (or rerun the Studio smoke for) every STALE entry before citing it.

## Outputs
PNG previews or Studio captures per angle (with a capture-manifest/1 `manifest.json` for kept captures), the manifest diff, and a short written finding per image.

## Acceptance
Every image was reviewed in this session; the diff explains every changed part; SceneKit/ProcGen validation passes; every capture cited as evidence is CURRENT in `capture_staleness.py`.

## Failure
- Blender previews use approximate materials (Roblox materials map to flat colours); the final look needs a Studio capture, and art quality needs human approval.
- A capture looks wrong: check the camera came from `captureSet` (front on -Z), the model is where the manifest says, and no stale model with the same name remains.
- `render-manifest` on an empty manifest fails: there are no parts to frame.
- `capture_staleness.py` STALE: the scene changed after the capture; the old image no longer shows the current scene. Recapture, do not edit the recorded hash. INVALID: a malformed manifest, an unknown scene or source; fix the record. INCOMPLETE: an image named in the manifest is missing.

## Related
roblox-scene-authoring, roblox-procedural-generation, blender-asset-factory, roblox-studio-testing.
