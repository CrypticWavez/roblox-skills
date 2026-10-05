---
name: blender-asset-qa
description: Run the machine-readable Blender asset quality gate (transforms, scale, orientation, pivot, normals, non-manifold and degenerate geometry, loose verts, UVs, materials, texture paths, triangle limits and budgets, bone influences, unweighted verts, bone names, animation clips, FBX/GLB export re-import probe) on a .blend, .fbx or .glb. Use after editing an asset, before any export or hand-off, and on third-party meshes.
---

# Blender asset QA

## Purpose
Catch import-breaking and budget problems before Roblox import, as a JSON report another agent can act on. Error-level failures block the factory's export.

## Triggers
"Check this model"; after editing an asset; before any export or hand-off; reviewing a downloaded or third-party `.fbx`/`.glb`.

## Inputs
A `.blend`, `.fbx` or `.glb` path. Optional `rbx_*` metadata on objects: `category` (budget row), `budget` (`{tris, materials}`), `expected_dims` (`[x, y, z]` studs, Blender axes), `rigged`, `animated`, `bone_names`, `allow_open`, `pivot = "custom"`, `up_axis_longest`, `qa = "skip"`; `rbx_cutter` marks boolean cutters.

## Required context
`tools/blender/bkit/qa.py` (`BUDGETS`, `run`, `gated_export`, check functions); `tools/blender/bkit/env.py` (`set_meta`, `get_meta`).

## Tools
`python3 tools/blender/factory.py qa <file> [report.json]` (or `blender -b --python tools/blender/factory.py -- qa ...`); exit 1 on any error. `factory.py template` runs the same checks as its export gate.

## Procedure
1. Run QA. A `.blend` also gets the export probe: the `<Kind>/Export` collections (the whole scene if there are none) are exported to FBX and GLB in a temp folder, re-imported and compared in rest pose (triangles, bounds, mesh names, animation). An `.fbx`/`.glb` is checked as imported (GLB vertices welded at 1e-5, importer bone shapes skipped), so the factory's own exports can be re-checked.
2. Read `summary.errors` first; each is `object:check` or `export:<detail>`. Errors: world scale not applied (parents included), armature rotation not applied, over the 20k Roblox triangle limit, non-manifold edges, degenerate faces, loose vertices, inconsistent normals, no UVs, unassigned material, missing texture file, more than 4 bone influences, vertices without deform-bone weight, skinned mesh without armature, bone count, missing `bone_names`, empty animation clip, `expected_dims` mismatch, Z not tallest with `up_axis_longest`, export probe mismatch.
3. Decide on `summary.warnings`: category budgets (`BUDGETS`), open boundaries (Roblox collision prefers watertight), pivot not at base centre, zero-area UV faces, material count, unapplied mesh rotation, implausible size.
4. Fix in the source (template script or `.blend`) and re-run until there are no errors; record accepted warnings in the asset's provenance note.

## Outputs
JSON report: `objects[].checks[]` (`name`, `pass`, `level`, `value`, `limit`, `detail`), `export` (probe result per format, `.blend` only), `summary` (`pass`, `errors`, `warnings`).

## Acceptance
`summary.pass == true`; every warning fixed or explained; for a `.blend`, the probe matched for both FBX and GLB.

## Failure
- A check is wrong for an asset class: set metadata on that asset (`allow_open`, `pivot = "custom"`, `budget`, `qa = "skip"` for helper objects) instead of changing global limits in `qa.py`.
- Probe mismatch: compare `export.formats.<fmt>.signature` with `export.source`; usual causes are unapplied modifiers, render-hidden meshes or an object outside the Export collection.
- An unreadable `.fbx`/`.glb` makes the importer raise and the command fail: open it in Blender to see why.

## Related
blender-asset-factory, blender-roblox-roundtrip, roblox-asset-intake.
