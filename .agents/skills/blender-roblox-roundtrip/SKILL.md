---
name: blender-roblox-roundtrip
description: Prove the Blender to Roblox import path for an asset and its updates - create/modify/material/save/export in Blender, re-import checks, then import in Studio and verify scale, orientation, pivot, materials, geometry and collision with ImportInspector, revise the source and verify the update. Use whenever a pipeline or importer setting changes or before trusting a new asset type.
---

# Blender -> Roblox round trip

**Purpose.** Never claim the pipeline works because an FBX exists. Both halves must be observed.

**Inputs.** Asset (default: the asymmetric `SM_RoundTripMarker`), output folder.

## Procedure
1. Blender half (headless, verified in CI): `python3 tools/blender/factory.py roundtrip build/roundtrip`. It builds v1, exports FBX+GLB, re-imports both, checks tris, dims, pivot, front (-Y), materials and stable name; then revises to v2 and proves the change is detected. Writes `roblox_expectation_v1.json` / `_v2.json` (Roblox axes, studs).
2. Studio half (Ethan's machine; Studio MCP or by hand):
   - Open an unpublished diagnostic place. Import `SM_RoundTripMarker_v1.fbx` with 3D Importer, **Scale Unit = Studs**, default rig settings.
   - Run in the command bar or via `execute_luau`: `local I = require(game.ReplicatedStorage.Workbench.Pipeline.ImportInspector); print(game:GetService("HttpService"):JSONEncode(I.inspect(workspace.SM_RoundTripMarker, <expectation table>)))`.
   - `screen_capture` from the front: the orange nose must face the camera on -Z.
   - Re-import v2 over v1 (same name), inspect again, `I.compareRevisions(v1Report, v2Report).changed` must be true.
3. Record both reports under `reports/` with Studio version and importer settings.

**Acceptance.** Blender report `pass`; Studio inspection passes for v1 and v2; revision detected; visual front correct.

**Failure handling.** `ImportInspector` names the cause: metre/stud mismatch (Scale Unit), Y/Z swap (axis settings), cm scale (FBX unit scale), rotation on import, precise collision.

**Status.** Blender half VERIFIED in cloud CI; Studio half BLOCKED_EXTERNAL until run on Ethan's machine.

**Related.** blender-asset-factory, blender-asset-qa, roblox-studio-testing.
