---
name: blender-asset-factory
description: Create Roblox-ready 3D assets in Blender from neutral templates (humanoid/NPC/enemy with R15-named rig, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests) and reusable ops (primitives, extrude, inset, bevel, boolean, mirror, array, curves, UV, PBR materials, rigging, weighting, keyframe clips, FBX/GLB export). Use for any modeling, rigging, animation or export task.
---

# Blender asset factory

**Purpose.** Repeatable asset creation with the conventions Roblox import needs, scriptable headlessly and through Blender MCP.

**Triggers.** Model/rig/animate/texture/export a prop, character, creature, enemy, boss, weapon, vehicle, building, modular kit, vegetation, rock.

**Inputs.** Asset kind, target size in studs, triangle/material budget, style colours, whether rigged/animated.

**Required context.** `tools/blender/bkit/__init__.py` (conventions), `tools/blender/bkit/templates.py` (closest template), `tools/blender/bkit/ops.py` (operation list). `docs/blender.md` for MCP ownership.

**Conventions.** 1 BU = 1 stud; Z up; front faces -Y; pivot base-centre (weapons: grip); collections `<Kind>/Source` (cutters, references) and `<Kind>/Export`; prefixes `SM_` static, `SK_` skinned, `RIG_` armature, `MAT_` material; `rbx_*` custom properties carry QA metadata (category, budget, expected_dims, rigged, bone_names). Max 4 bone influences; one action per export.

**Tools.** `python3 tools/blender/factory.py template <kind> <out>` (bpy wheel, no GUI) or `blender -b --python tools/blender/factory.py -- ...`; Blender MCP (`mcp-for-blender`, one client at a time, telemetry off) for interactive work on Ethan's machine.

## Procedure
1. Start from the nearest template: `factory.py template <kind> build/blender` (writes .blend, FBX, GLB, qa.json, previews).
2. Edit with `bkit.ops` in a script (preferred: reproducible) or via MCP `execute_blender_code` calling the same ops. Keep destructive steps explicit (`apply_modifiers`, `apply_transforms`, `set_origin_base_center`).
3. Materials: `pbr_material` + `assign`; UVs: `box_uv` (deterministic) or Blender unwrap for organic shapes.
4. Rig/animate: `armature`, `bind_rigid` (or weight paint), `keyframe_clip` (one clip per export).
5. Run blender-asset-qa; fix errors; review warnings.
6. Look at the previews (`render.render_objects`) before calling it done.
7. Export with `ops.export_fbx` / `ops.export_glb` only (they hold the Roblox settings, including the animation bake fix).

**Outputs.** `.blend` source, FBX/GLB, `qa.json`, preview PNGs, `rbx_*` metadata.

**Acceptance.** QA has zero errors; export probe (FBX and GLB re-import) matches triangles, bounds and animation presence; previews show the intended silhouette and front.

**Failure handling.** Known traps (fixed in ops): mirror around the wrong origin creates non-manifold geometry (apply transforms first); joined meshes lose material indices (use `ops.join`); FBX drops the clip unless NLA baking is off; glTF import adds bone-shape meshes (excluded from signatures).

**Related.** blender-asset-qa, blender-roblox-roundtrip, roblox-asset-intake.
