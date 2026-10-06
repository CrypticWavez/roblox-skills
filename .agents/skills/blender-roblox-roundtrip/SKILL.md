---
name: blender-roblox-roundtrip
description: Prove the Blender to Roblox import path for an asset and its updates - create/modify/material/save/export in Blender, re-import checks, then import in Studio and verify scale, orientation, pivot, materials, geometry and collision with ImportInspector, revise the source and verify the update. Use whenever a pipeline or importer setting changes or before trusting a new asset type.
---

# Blender -> Roblox round trip

## Purpose
Never claim the pipeline works because an FBX exists. Both halves (Blender export/re-import and Studio import) must be observed, for a first version and for an update.

## Triggers
An exporter, importer or pipeline setting changed; a new asset type is about to be trusted; an imported asset is the wrong size, faces the wrong way or has its pivot off in Studio.

## Inputs
Output folder; the asset (default: the asymmetric `SM_RoundTripMarker` built by `bkit/roundtrip.py`); for the Studio half, an unpublished diagnostic place with `fixtures/factory.project.json` synced.

## Required context
`tools/blender/bkit/roundtrip.py` (what the Blender half checks), the `packages/Pipeline/ImportInspector.luau` header (Studio API), `docs/mcp.md` (Studio safety gates).

## Tools
- `python3 tools/blender/factory.py roundtrip <out_dir>`.
- `rojo serve fixtures/factory.project.json` (puts `packages/*` under `ReplicatedStorage.Workbench`).
- Studio MCP `execute_luau`, `screen_capture`, `get_console_output` (see roblox-studio-testing); 3D Importer by hand.

## Procedure
1. Blender half (headless): `factory.py roundtrip build/roundtrip` QA-checks v1 (no export on errors), exports FBX and GLB, re-imports both and checks triangles, dimensions, origin at the base centre and at the world origin, front (-Y), surface offsets, materials and a stable name; then revises to v2 and proves the change is detected.
2. Studio half (Ethan's machine): open the diagnostic place, sync with Rojo, import `SM_RoundTripMarker_v1.fbx` with Import 3D, **Scale Unit = Stud**, Insert In Workspace and Insert Using Scene Position on, defaults otherwise. Each import uploads the mesh as a private asset on the account, so every import needs Ethan's go-ahead; the file picker reopens the last folder, so check the path. The importer creates a Model named after the file (`SM_RoundTripMarker_v1`) holding the MeshPart `SM_RoundTripMarker`.
3. Inspect via `execute_luau`: `local I = require(game.ReplicatedStorage.Workbench.Pipeline.ImportInspector); local HS = game:GetService("HttpService"); local r1 = I.inspect(workspace.SM_RoundTripMarker_v1, HS:JSONDecode(<text of roblox_expectation_v1.json>)); print(HS:JSONEncode(r1))`.
4. `screen_capture` from the front: the orange nose (`MAT_Front`) must face the camera on -Z.
5. Import v2 next to v1, inspect `workspace.SM_RoundTripMarker_v2` with the v2 expectation into `r2`; `I.compareRevisions(r1, r2).changed` must be true.
6. Record both Studio reports under `reports/` with the Studio version and importer settings.

## Outputs
`SM_RoundTripMarker_v1/_v2` `.fbx` and `.glb`, `roblox_expectation_v1.json`/`_v2.json` (Roblox axes, studs, with `front_offset`/`up_offset`: surface centroid minus bounds centre along front and up), `roundtrip-report.json`, Studio inspection JSON for v1 and v2, the front capture.

## Acceptance
Blender report `pass`; Studio `inspect(...).pass` for v1 and v2; `compareRevisions(...).changed == true`; the capture shows the front on -Z. Current status lives in gap-matrix rows B04 (Blender half), B05 (Studio half) and B06 (colour); the 2026-10-05 Studio run is `reports/studio/roundtrip-2026-10-05.json`.

## Failure
- `ImportInspector` names the cause in each check's `detail`: metre/stud mismatch (Scale Unit), Y/Z swap (axis settings), centimetre scale (FBX unit scale), rotation on import, pivot off base centre, asset facing +Z or upside down (measured from the mesh triangles via EditableMesh against `front_offset`/`up_offset`), precise collision.
- Pivot off by a fixed offset: Studio sets the imported Model's pivot at the FBX file origin, so the asset's origin must be at Blender's world origin (QA's `studio_pivot_at_origin` blocks single-root exports that are not).
- Grey mesh: per-material base colours do not survive Import 3D; colour needs a baked texture (gap row B06).
- If it cannot read the mesh, `orientation_front` reports "front undetermined" and fails: confirm facing with `screen_capture`, never assume it.
- Blender half fails: read `revisions[].checks` and `revisions[].source_qa` in `roundtrip-report.json`.

## Related
blender-asset-factory, blender-asset-qa, roblox-studio-testing, visual-qa.
