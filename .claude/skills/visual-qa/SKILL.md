---
name: visual-qa
description: See and compare what was built - render SceneKit manifests and Blender assets to PNG headlessly, capture Studio views from standard camera angles, and diff scene manifests for regressions. Use after any visual change, before claiming something looks right, and for before/after evidence.
---

# Visual QA

**Purpose.** Close the loop between authoring and looking. Screenshots alone are not proof; pair them with manifest diffs and validation.

**Tools.**
- Offline scenes: `python3 tools/blender/factory.py render-manifest build/fixtures/<name>.manifest.json build/previews` (Cycles CPU; angles `three-quarter`, `top`).
- Assets: `factory.py template|qa` writes `<kind>.front.png`, `.three-quarter.png`; `bkit.render.render_objects` for any object set.
- Studio: `SceneKit.Camera.captureSet(min, max)` gives eye/focus per angle; set `workspace.CurrentCamera.CFrame = CFrame.lookAt(eye, focus)` via `execute_luau`, then `screen_capture`.
- Regression: `SceneKit.Scene.compare(oldManifest, newManifest)` lists added/removed/changed part ids; `lune run tools/lune/build_fixtures.luau` reports hashes.

## Procedure
1. Produce the manifest (SceneKit) or asset (Blender).
2. Render/capture the standard angles at a fixed lighting profile (`inspection-flat` for geometry, `neutral-day` for look).
3. Look at every image with the Read tool; describe what is wrong concretely (floating parts, z-fighting, wrong front, gaps, scale versus a 5.5-stud character).
4. For changes, diff manifests and attach before/after images.

**Acceptance.** Images reviewed this session; diff explains every change; validation passes.

**Limits.** Blender previews use approximate materials (Roblox materials map to flat colours); final look needs Studio capture. Human approval is still required for art quality.

**Related.** roblox-scene-authoring, blender-asset-factory, roblox-studio-testing.
