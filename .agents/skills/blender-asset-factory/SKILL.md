---
name: blender-asset-factory
description: Create Roblox-ready 3D assets in Blender from neutral templates (humanoid/NPC/enemy with R15-named rig, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests) and reusable ops (primitives, extrude, inset, bevel, boolean, mirror, array, curves, UV, PBR materials, rigging, weighting, keyframe clips, FBX/GLB export). Use for any modeling, rigging, animation or export task.
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
- `bkit.ops`: `box`, `cylinder`, `sphere`, `wedge`, `extrude`, `inset`, `bevel`, `boolean`, `mirror`, `array`, `solidify`, `curve_tube`, `apply_modifiers`, `apply_transforms`, `set_origin_base_center`, `join`, `box_uv`, `pbr_material`, `assign`, `armature`, `bind_rigid`, `keyframe_clip`, `export_fbx`, `export_glb`.
- `bkit.render.render_objects(objects, out_dir, prefix)` for preview stills of any object set.
- Blender MCP (`mcp-for-blender`, telemetry off) on Ethan's machine: `execute_blender_code` calling the same ops, `get_viewport_screenshot`, `get_scene_info`.

## Procedure
1. Start from the nearest template: `factory.py template <kind> build/blender` saves `<kind>/<kind>.blend`, runs QA, exports `<kind>.fbx`/`<kind>.glb` only when QA has no errors, and writes `qa.json` plus `<kind>.front.png`/`<kind>.three-quarter.png`.
2. Edit with `bkit.ops` in a script (preferred: reproducible) or via MCP `execute_blender_code` calling the same ops. Keep destructive steps explicit (`apply_modifiers`, `apply_transforms`, `set_origin_base_center`).
3. Materials: `pbr_material` + `assign`. UVs: `box_uv` (deterministic) or a Blender unwrap for organic shapes.
4. Rig and animate: `armature`, `bind_rigid` (or weight paint), `keyframe_clip`; one action per export, at most 4 bone influences per vertex.
5. Run blender-asset-qa; fix every error and decide on every warning.
6. Look at the previews with the Read tool before calling it done.
7. Export only through `ops.export_fbx` / `ops.export_glb` (Roblox axes and scale, animation bake fix) or the gated `template` export.

## Outputs
`.blend` source, FBX and GLB (only when QA passes), `qa.json` (per-object checks, export re-import probe, summary), preview PNGs, `rbx_*` metadata on objects.

## Acceptance
`qa.json` `summary.pass` is true; the probe re-imported the shipped FBX and GLB with matching triangles, bounds, mesh names and animation; warnings fixed or explained; previews show the intended silhouette with the front facing -Y.

## Failure
- QA errors: `template` exits 1 and leaves no FBX/GLB (stale ones are removed); the `.blend`, `qa.json` and previews remain. Fix the source and re-run.
- Traps already handled in `ops`: mirroring around the wrong origin makes non-manifold geometry (apply transforms first); joined meshes lose material indices (use `ops.join`); FBX drops the clip unless NLA baking is off (`export_fbx`); glTF import adds bone-shape meshes (QA skips them).
- MCP silent: run `get_scene_info`; check the add-on socket on 127.0.0.1:9876 and that no second client is connected.

## Related
blender-asset-qa, blender-roblox-roundtrip, visual-qa, roblox-asset-intake.
