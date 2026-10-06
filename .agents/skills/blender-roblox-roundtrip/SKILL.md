---
name: blender-roblox-roundtrip
description: Prove the Blender to Roblox import path for an asset, its look and its clips, and for updates. Blender half - create, bake, modify, export, then re-import checks for size, facing, side, one material, colour map and colour attribute. Studio half - import, then ImportInspector checks size (unit and axis mistakes), rotation, pivot at the base centre, facing and side (mirroring) from the mesh surface, triangle count, collision fidelity, the appearance route (colour map and PBR maps on a SurfaceAppearance or MeshPart, vertex colours, MaterialVariant names) and clips against a clips/1 sidecar (present, length, markers, play plan). Then revise and verify the update. Use whenever a pipeline or importer setting changes or before trusting a new asset type.
---

# Blender -> Roblox round trip

## Purpose
Never claim the pipeline works because an FBX exists. Both halves (Blender export and re-import, then Studio import) must be observed, for a first version and for an update, for shape, look and animation.

## Triggers
- An exporter, importer, bake or pipeline setting changed.
- A new asset type or look route is about to be trusted.
- An imported asset is the wrong size, faces the wrong way, is mirrored, is grey, or its pivot is off.
- Clips are missing or the wrong length in Studio.

## Inputs
- The output folder.
- The asset. The default is the marker `SM_RoundTripMarker` built by `bkit/roundtrip.py`: a body, an orange nose at the front (-Y) and a blue fin on its left (+X), palette-baked.
- The expectation JSON and, for rigs, the clips/1 sidecar.
- For the Studio half, an unpublished diagnostic place with `fixtures/factory.project.json` (or `fixtures/kits.project.json`) synced.

## Required context
- `tools/blender/bkit/roundtrip.py` (Blender half) and `bkit/expectation.py` (axes: Blender (x, y, z) → Roblox (-x, z, y)).
- The `packages/Pipeline/ImportInspector.luau` header: `inspect`, `appearanceChecks`, `partMaps`, `inspectClips`, `studioClips`, `compareRevisions`.
- `docs/blender.md` "Studio import behaviour" and `docs/mcp.md` (Studio safety gates).

## Tools
- `python3 tools/blender/factory.py roundtrip <dir>` and `compare-export <files> --expect <json>`.
- `rojo serve fixtures/factory.project.json`, which puts `packages/*` under `ReplicatedStorage.Workbench`.
- T3 probes (owner-run): `tests/engine/import_appearance.luau` and `tests/engine/import_clips.luau`. They print `ENGINE_CHECK` lines and one `ENGINE_DONE`. In Lune they are exercised by `tests/import_inspector.spec.luau`.
- Studio MCP `execute_luau`, `screen_capture`, `get_console_output` (roblox-studio-testing). The 3D Importer is used by hand.

## Procedure
1. Blender half (headless): `factory.py roundtrip build/roundtrip`.
   - QA-checks v1 (no export on errors), palette-bakes it (`<asset>_vN_Color.png`) and exports FBX and GLB.
   - Re-imports both and checks: triangles, dimensions, origin, front (-Y), side (fin at +X), surface offsets, one material, colour map and face colours sampled from the atlas, colour attribute, stable name.
   - Revises to v2 and proves the change is detected.
   - Writes `roblox_expectation_vN.json` with `front_offset`, `up_offset`, `side_offset` and the `appearance` block.
2. Studio half, done by the owner, since every import uploads the mesh as a private asset and needs the owner's go-ahead:
   - Open the diagnostic place and sync with Rojo.
   - Import the FBX or GLB with Import 3D: Scale Unit = Stud, Insert In Workspace, Insert Using Scene Position. The Model is named after the file.
3. Shape and look:
   - Put the expectation JSON in a StringValue under `ReplicatedStorage.ImportExpectations`, named like the model.
   - Run `tests/engine/import_appearance.luau`, or call `ImportInspector.inspect(model, expectation)` via `execute_luau`.
   - Checks: scale, pivot, `orientation_front`, `orientation_side`, triangles, and per the appearance route:
     - `appearance` + `appearance_color` etc. (map content on a SurfaceAppearance or MeshPart);
     - `appearance_part_color` for vertex colours;
     - MaterialVariant names for the library route.
4. Clips:
   - Import `<asset>_clips.glb` (or a clip's FBX).
   - Put `<asset>_clips.json` in `ReplicatedStorage.ImportClips`.
   - Run `tests/engine/import_clips.luau`. It scans the model and `ServerStorage.RBX_ANIMSAVES` and records where the clips landed, then checks `clip_present`, `clip_length` (within half a frame) and `clip_markers`, and reports the play plan.
5. `screen_capture` from the front: the orange nose faces the camera on -Z, and the blue fin is on the model's left.
6. Import v2 next to v1, inspect it, and check that `I.compareRevisions(r1, r2).changed` is true.
7. Record the Studio reports under `reports/` with the Studio version and importer settings. Only then can gap rows B06, B02 and B07 leave BLOCKED_EXTERNAL.

## Outputs
- `SM_RoundTripMarker_v1/_v2` `.fbx`/`.glb`, their colour atlases, `roblox_expectation_v*.json` and `roundtrip-report.json`.
- Studio probe output (`ENGINE_CHECK`/`ENGINE_DONE` lines) for appearance and clips.
- The front capture.

## Acceptance
- The Blender report passes.
- `inspect(...).pass` holds in Studio for v1 and v2, with `notChecked` empty.
- `import_appearance` and `import_clips` print `ENGINE_DONE` with every check ok.
- `compareRevisions(...).changed == true`.
- The capture shows the front on -Z and the fin on the left.
- Status lives in gap-matrix rows:
  - B04 (Blender half);
  - B05 (Studio half);
  - B06 (colour);
  - B02 (PBR maps);
  - B07 (animation import).

  The 2026-10-05 Studio run is `reports/studio/roundtrip-2026-10-05.json`.

## Failure
- ImportInspector names the cause in each check's `detail`:
  - scale: metre/stud mismatch (Scale Unit), Y/Z swap, centimetre scale;
  - orientation: rotation on import, a mirrored import (`orientation_side`), front/up from the mesh triangles;
  - pivot offset;
  - stale file (triangles);
  - precise collision.
- Pivot off by a fixed offset: the imported pivot is the file origin. Export at the world origin (`studio_pivot_at_origin`).
- Grey mesh or `appearance` failing with B06: no colour map arrived. Check the MeshPart's TextureContent or SurfaceAppearance ColorMapContent. Vertex colours need a white part Color.
- `appearance_normal` and other maps missing (B02): Reimport finds maps by suffix in the same folder (`_Normal`, `_Roughness`, ...).
- `orientation_side` mirrored: an axis flip on export or import. Re-check the axis settings, never "fix" by mirroring the mesh.
- `clip_present` fails: the clip was renamed (Studio may prefix `<rig>|`, which is matched) or not imported. `clip_length` is off: FBX keying or simplification lost frames.
- "front undetermined" / "up not verified": confirm with `screen_capture`, never assume.
- Blender half fails: read `revisions[].checks` and `source_qa` in `roundtrip-report.json`.

## Related
blender-asset-factory, blender-asset-qa, roblox-animation-integration, roblox-studio-testing, visual-qa.
