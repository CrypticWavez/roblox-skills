---
name: blender-asset-factory
description: Create Roblox-ready 3D assets in Blender from neutral templates (R15 humanoid/NPC/enemy, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests, and ten function-named gameplay greyboxes - pickup, pad button, dropper, conveyor, tower base, checkpoint gate, obby platforms, track segment, pet follower with clips, rigid accessory) and reusable ops (modeling, retopology, LOD, UV, PBR materials, rigging, weights, collision proxies, keyframe clips). Bakes the look into a palette atlas, vertex colours or PBR maps so it survives Import 3D, exports multi-clip GLB and per-clip FBX with a clips/1 sidecar, writes kit/1 for SceneKit, renders icons and normalises third-party models (intake). Use for any modeling, baking, rigging, animation, kit or export task.
---

# Blender asset factory

## Purpose
Repeatable asset creation with the conventions Roblox import needs. Assets are scripted headless with `bkit` and inspected interactively through Blender MCP. Their look is baked so it arrives in Studio, and they are exported only after QA passes.

## Triggers
- Model, rig, animate, texture, bake or export a prop, character, creature, weapon, vehicle, building, modular kit, vegetation, rock or gameplay piece.
- Start an asset from a template.
- Build a kit for SceneKit, render UI icons, bake a library material, or bring in a third-party model.

## Inputs
- Asset kind: a key of `templates.TEMPLATES`. `templates.GAMEPLAY` lists the ten gameplay kinds.
- Size in studs and a triangle/material budget.
- Look route: palette (default), vertex, maps or library.
- Clip list with slots, loop flags and markers for rigs.
- Output folder.
- For intake, a `cc0:<src>:<id>` source.

## Required context
- Conventions (`bkit/__init__.py`, `templates.py` header):
  - Units and axes: 1 BU = 1 stud, Z up, front faces -Y. A character's left is +X.
  - Pivot at the base centre; weapons use the grip with `rbx_pivot = "custom"`.
  - Collections: `<Kind>/Source` and `<Kind>/Export`.
  - Prefixes: `SM_`, `SK_`, `RIG_`, `MAT_`.
  - QA metadata goes in `rbx_*` custom properties (`env.set_meta`).
- Read `docs/blender.md` (commands, bake routes, texture rules, clips/1, R15 profiles, kit/1, Studio observations) and the frozen contracts in `docs/runtime-kits.md`: 9.4 clips/1, 9.5 kit/1, 9.6 material-library/1.
- Nodes are found by type, never by name (`ops.principled`, `ops.material_output`).
- `docs/mcp.md` "Operation ownership": bpy scripts for reproducible work, MCP for inspection, one client per Blender instance.

## Tools
- Build:
  - `python3 tools/blender/factory.py template <kind> <dir> [--bake palette|vertex|none]`;
  - `templates <dir> [--kinds a,b]` (23 kinds);
  - `kit --templates a,b --out kit.json [--library assets/material-library.json]`.
- Bake, render and intake:
  - `bake <kind|file.blend> <dir> --mode palette|vertex|maps|tile`;
  - `material-preview <library> <dir>`;
  - `icon <kind|file.blend> <out.png>`;
  - `intake <file> <dir> --key k --source cc0:<src>:<id> --height H`.
- `bkit.ops`:
  - primitives and edits: `box`, `cylinder`, `sphere`, `icosphere`, `wedge`, `extrude`, `inset`, `noise_displace`, `bevel`, `boolean`, `mirror`, `array`, `solidify`, `curve_tube`, `join`, `box_uv`;
  - materials: `pbr_material`, `principled`, `assign`;
  - retopology and LOD: `voxel_remesh`, `quadriflow`, `lod_chain`;
  - rigging and animation: `armature`, `bind_rigid`, `bind_auto`, `limit_weights`, `keyframe_clip`;
  - collision and export: `collision_proxy`, `export_fbx`, `export_glb`.
- Other `bkit` modules:
  - `bkit.bake`: `palette_atlas`, `vertex_colors`, `atlas_uvs`, `bake_maps`;
  - `bkit.textures`: roles, colour spaces, suffixes, material-library/1;
  - `bkit.clips`: `add_clip`, `export_clips`;
  - `bkit.r15`: rig profiles;
  - `bkit.kit`, `bkit.icons`, `bkit.intake`;
  - `bkit.render.render_objects` for preview stills.
- `python3 tools/gltf_validate.py <file.glb>` checks the structure without bpy.
- Blender MCP (`mcp-for-blender`, telemetry off) runs on the owner's machine: `execute_blender_code`, `look`, `get_scene_info`.

## Procedure
1. Start from the nearest template: `factory.py template <kind> build/blender`. It saves the `.blend`, bakes the look, runs QA, and exports `<kind>.fbx`/`.glb` only without errors. It also writes `<kind>_expectation.json`, `qa.json` and the previews; rigs with clips also get `<kind>_clips.glb`, one FBX per clip and `<kind>_clips.json`.
2. Edit with `bkit.ops` in a script (reproducible) or via MCP calling the same ops. Keep destructive steps explicit.
3. Organic shapes and retopology go before UVs and rigging, because remeshers drop UVs and vertex groups. Use `noise_displace` for rocks, `voxel_remesh` to fuse blockout parts and `quadriflow` for clean quads.
4. Materials: `pbr_material` + `assign`. Then pick the look route:
   - flat colours → palette atlas (default);
   - stylised kits on Roblox materials → `vertex_colors` (white part);
   - procedural shaders or high-to-low detail → `atlas_uvs` + `bake_maps` (`bake --mode maps`);
   - tiling surfaces → tag the material `rbx_library = "<name>"` for a material-library/1 entry, or make that entry with `bake --mode tile`.
5. Rig and animate:
   - Rig with `armature`.
   - Skin with `bind_rigid` for blocky parts or `bind_auto` (at most 4 normalised influences).
   - Characters that play standard clips use the `r15_pose` bone names.
   - Add clips with `clips.add_clip(rig, name, keys, fps, start, end, loop, slot, root_motion, priority, weight, markers)`.
   - Export with `clips.export_clips(rig, meshes, out_dir, asset, rig_kind)`: one multi-clip GLB, one FBX per clip and the clips/1 sidecar.
6. Collision: `collision_proxy(obj, "hull"|"box")` for anything players stand on or bump into. Roblox imports neither collision meshes nor LODs.
7. LODs: `lod_chain`. Each LOD must pass QA.
8. Run blender-asset-qa. Fix every error and decide on every warning.
9. Look at the previews (and icons, material previews) with the Read tool before calling it done.
10. Export only through `export_fbx`/`export_glb`, the gated `template`/`bake`/`kit`/`intake`, or `clips.export_clips`. Run `factory.py qa` and `gltf_validate.py` on what they write.
11. For SceneKit: `factory.py kit --templates ... --out build/kit.json` writes kit/1, with each piece exported alone at the world origin and QA'd again.

## Outputs
- `.blend`, FBX and GLB (only when QA passes) and `qa.json`.
- `<asset>_expectation.json`, which records size, offsets, side, triangles and the `appearance` route with maps.
- Maps named `<Asset>_Color/_Normal/_Roughness/_Metalness/_Emissive.png`.
- `<asset>_clips.json` + `<asset>_clips.glb` + `<asset>_<clip>.fbx` for rigs with clips.
- kit/1 JSON, icons and preview PNGs.
- For intake, `intake-report.json` and `<key>_kit.json`.

## Acceptance
- `qa.json` `summary.pass` is true, and the probe re-imported FBX and GLB with matching triangles, bounds, names and animation.
- `appearance_declared` passes, so the look travels as an atlas, vertex colours, maps or library names.
- `gltf_validate.py` reports pass. Clips pass `clip_*` QA, and the sidecar validates against clips/1.
- The kit validates against kit/1.
- Previews show the intended silhouette and colours, with the front facing -Y.
- Studio arrival (B06/B02/B07) is proven only by the T3 probes (blender-roblox-roundtrip).

## Failure
- QA errors: the command exits 1 and leaves no FBX/GLB. The `.blend`, `qa.json` and previews remain.
- Grey in Studio: the look was not baked (route `none`, or plain material colours). Re-run with the palette route; `appearance_declared` names it.
- `atlas_uvs` "poll() failed": the mesh was not the active object in the view layer. Use `bake.atlas_uvs`, which sets it up.
- Slow packing: CONCAVE packing takes minutes. `atlas_uvs` uses AABB with axis-aligned rotation.
- Clip too short or long in Studio: FBX start/end keying or simplification was on. Use `clips.export_clip_fbx`, which follows Roblox's recipe.
- Markers are missing after import: the sidecar is their source, and AnimSet applies them.
- Left/right swapped on a character: `rig_profile_sides` fails. Left bones belong at +X.
- `bind_auto` prints "bone heat left N of M vertices": fuse the shells or add bones (`fallback=None` raises). `quadriflow` raises on non-manifold input, so run `voxel_remesh` first.
- Sculpting is INTENTIONALLY_EXCLUDED from scripts because it needs a viewport. Use `noise_displace`, or sculpt by hand and run QA.
- MCP silent: run `get_scene_info`, check the add-on socket, and check that no second client is connected.

## Related
blender-asset-qa, blender-roblox-roundtrip, roblox-animation-integration, roblox-scene-authoring, visual-qa, roblox-asset-intake.
