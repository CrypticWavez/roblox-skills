---
name: blender-asset-qa
description: Run the machine-readable Blender asset quality gate (transforms, scale, orientation, pivot, normals, non-manifold and degenerate geometry, loose verts, UVs, materials, texture paths, triangle limits and budgets, bone influences, unweighted verts, bone names, animation clips, FBX/GLB export re-import probe) on a .blend, .fbx or .glb.
---

# Blender asset QA

**Purpose.** Catch import-breaking and budget problems before Roblox import, with a JSON report another agent can act on.

**Triggers.** "check this model", before any export/upload, after editing an asset, reviewing third-party meshes.

**Inputs.** Path to `.blend`/`.fbx`/`.glb`; optional `rbx_*` metadata on objects (category, budget, expected_dims, rigged, bone_names, allow_open, pivot=custom).

**Tools.** `python3 tools/blender/factory.py qa <file> [report.json]` (exit code 1 on errors).

## Procedure
1. Run QA. For `.blend` it also runs the export probe (exports FBX+GLB to temp, re-imports, compares triangles/bounds/animation in rest pose).
2. Read `summary.errors` first: each is `object:check`. Error checks: scale applied, Roblox 20k triangle limit, non-manifold edges, degenerate faces, loose vertices, normals consistent, UV present, material assigned, texture paths, bone influences <= 4, unweighted vertices, armature bound, bone names, animation clip, export probe.
3. Warnings need a decision: budgets per category (`BUDGETS` in qa.py), open boundaries (Roblox collision prefers watertight), pivot, UV zero-area faces, material count.
4. Fix in the source, re-run until errors are zero; record accepted warnings in the asset's provenance note.

**Outputs.** `qa.json` with per-object checks, export signatures, summary.

**Acceptance.** `summary.pass == true`; warnings either fixed or explained.

**Failure handling.** If a check is wrong for an asset class, set metadata (`allow_open`, `pivot="custom"`, `budget`) on that asset rather than changing global limits.

**Related.** blender-asset-factory, blender-roblox-roundtrip.
