---
name: blender-asset-factory
description: Create Roblox-ready 3D assets in Blender from neutral templates (humanoid/NPC/enemy with R15-named rig, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests) and reusable ops (primitives, extrude, inset, bevel, boolean, mirror, array, curves, seeded noise displacement in place of sculpting, voxel remesh and QuadriFlow retopology, decimate LOD chains, UV, PBR materials, rigging, rigid or automatic bone-heat skin weights limited to 4 normalised influences, keyframe clips, FBX/GLB export). Use for any modeling, retopology, LOD, rigging, weighting, animation or export task.
---

# Blender asset factory

## Purpose
Repeatable asset creation with the conventions Roblox import needs: scripted headlessly with `bkit`, inspected interactively through Blender MCP, and exported only after QA passes.

## Triggers
Model, rig, animate, texture or export a prop, character, NPC, enemy, creature, weapon, vehicle, building, modular kit, vegetation or rock; start an asset from a template.

## Inputs
Asset kind (a key of `templates.TEMPLATES`), target size in studs, triangle/material budget, colours, static or rigged/animated, output folder.

## Required context
- Conventions (`tools/blender/bkit/__init__.py`, `templates.py` header): 1 BU = 1 stud; Z up; front faces -Y; pivot at base centre (weapons: grip, with `rbx_pivot = "custom"`); collections `<Kind>/Source` (cutters, references) and `<Kind>/Export` (what ships); prefixes `SM_` static, `SK_` skinned, `RIG_` armature, `MAT_` material; QA metadata as `rbx_*` custom properties (`env.set_meta`).
- `tools/blender/bkit/templates.py` (closest template) and `tools/blender/bkit/ops.py` (operation list).
- `docs/blender.md` (CLI commands, kinds). `docs/mcp.md` "Operation ownership": bpy scripts for reproducible work, MCP for interactive inspection, one client per Blender instance.

## Tools
- `python3 tools/blender/factory.py template <kind> <out_dir>` (bpy wheel) or `blender -b --python tools/blender/factory.py -- template <kind> <out_dir>`; `templates <out_dir> [--no-previews]` builds all 13 kinds.
- `bkit.ops`: `box`, `cylinder`, `sphere`, `icosphere`, `wedge`, `extrude`, `inset`, `noise_displace`, `bevel`, `boolean`, `mirror`, `array`, `solidify`, `curve_tube`, `apply_modifiers`, `apply_transforms`, `set_origin_base_center`, `join`, `box_uv`, `pbr_material`, `assign`, `triangles`, `voxel_remesh`, `quadriflow`, `lod_chain`, `armature`, `bind_rigid`, `bind_auto`, `limit_weights`, `keyframe_clip`, `export_fbx`, `export_glb`.
- `bkit.render.render_objects(objects, out_dir, prefix)` for preview stills of any object set.
- Blender MCP (`mcp-for-blender`, telemetry off) on Ethan's machine: `execute_blender_code` calling the same ops, `get_viewport_screenshot`, `get_scene_info`.

## Procedure
1. Start from the nearest template: `factory.py template <kind> build/blender` saves `<kind>/<kind>.blend`, runs QA, exports `<kind>.fbx`/`<kind>.glb` only when QA has no errors, and writes `qa.json` plus `<kind>.front.png`/`<kind>.three-quarter.png`.
2. Edit with `bkit.ops` in a script (preferred: reproducible) or via MCP `execute_blender_code` calling the same ops. Keep destructive steps explicit (`apply_modifiers`, `apply_transforms`, `set_origin_base_center`).
3. Organic shapes and retopology, before UVs and rigging (remeshers drop UVs and vertex groups; they re-project material indices and re-apply box UVs): `noise_displace(obj, strength, scale, seed)` on an `icosphere` for rocks and cliffs; `voxel_remesh(obj, voxel_size)` fuses intersecting blockout parts into one watertight shell; `quadriflow(obj, target_faces, seed)` gives clean quads near a face target (deterministic per seed). Sculpting is not scripted (see Failure).
4. Materials: `pbr_material` + `assign`. UVs: `box_uv` (deterministic) or a Blender unwrap for organic shapes.
5. Rig and animate: `armature`; `bind_rigid` for blocky parts that move as units (R15-style templates), `bind_auto` for one continuous mesh (bone heat, then `limit_weights`: at most 4 influences per vertex, normalised); `keyframe_clip`, one action per export. After hand weight painting, run `limit_weights`.
6. LODs: `lod_chain(obj, (0.5, 0.25, 0.1))` adds `<name>_LOD1..` copies (Decimate collapse; triangle counts strictly decrease; skinned copies keep the Armature modifier and are re-limited). Each LOD must pass QA.
7. Run blender-asset-qa; fix every error and decide on every warning.
8. Look at the previews with the Read tool before calling it done.
9. Export only through `ops.export_fbx` / `ops.export_glb` (Roblox axes and scale, animation bake fix) or the gated `template` export.

## Outputs
`.blend` source, FBX and GLB (only when QA passes), `qa.json` (per-object checks, export re-import probe, summary), preview PNGs, `rbx_*` metadata on objects.

## Acceptance
`qa.json` `summary.pass` is true; the probe re-imported the shipped FBX and GLB with matching triangles, bounds, mesh names and animation; skinned meshes pass `bone_influences` and `unweighted_vertices` on the `.blend` and `.fbx`, where a `.glb` cannot show them; every LOD passes on its own; warnings fixed or explained; previews show the intended silhouette with the front facing -Y.

## Failure
- QA errors: `template` exits 1 and leaves no FBX/GLB (stale ones are removed); the `.blend`, `qa.json` and previews remain. Fix the source and re-run.
- Traps already handled in `ops`: mirroring around the wrong origin makes non-manifold geometry (apply transforms first); joined meshes lose material indices (use `ops.join`); FBX drops the clip unless NLA baking is off (`export_fbx`); glTF import adds bone-shape meshes (QA skips them).
- `bind_auto` prints "bone heat left N of M vertices ... unweighted": Blender's heat solve found no bone for a separate shell, and those vertices were bound rigidly to the nearest bone (`rbx_weighting.fallback_vertices`). For smooth results, fuse the shells (`voxel_remesh`) or put a bone inside each. `fallback=None` raises instead.
- `quadriflow` raises RuntimeError: QuadriFlow cancels on non-manifold, inconsistently oriented or degenerate input; run `voxel_remesh` first. `lod_chain` raises ValueError when a ratio cannot cut more triangles; it removes the copies it made.
- Sculpting is intentionally excluded from scripts: `bpy.ops.sculpt.brush_stroke` fails its poll headless (it needs a 3D viewport), and scripted strokes are not reviewable art. Use `noise_displace`, or sculpt by hand in Blender and run QA on the saved file.
- MCP silent: run `get_scene_info`; check the add-on socket on 127.0.0.1:9876 and that no second client is connected.

## Related
blender-asset-qa, blender-roblox-roundtrip, visual-qa, roblox-asset-intake.
