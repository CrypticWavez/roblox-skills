---
name: blender-asset-qa
description: Run the machine-readable Blender asset quality gate on a .blend, .fbx, .glb or .gltf - transforms, scale, orientation, pivot, normals, non-manifold and degenerate geometry, UVs (one set, inside 0..1), materials and how the look travels (palette atlas, vertex colours, maps, library), texture size, colour space and suffix, triangle budgets, bone influences and weights, R15 rig profiles, animation clips and markers, collision proxies, FBX/GLB re-import probe - plus the pure-Python glTF structural validator. Use after editing, baking, remeshing, weighting or making LODs, before any export or hand-off, and on third-party meshes.
---

# Blender asset QA

## Purpose
Catch import-breaking, look-losing and budget problems before Roblox import, as a JSON report another agent can act on. Error-level failures block the factory's export.

## Triggers
- "Check this model".
- After editing or baking an asset.
- Before any export or hand-off.
- Reviewing a downloaded `.fbx`/`.glb`.
- After changing `qa.py`, `bake.py`, `clips.py`, `r15.py` or an exporter setting.

## Inputs
A `.blend`, `.fbx`, `.glb` or `.gltf` path. Optional `rbx_*` metadata on objects:
- `category` (budget row), `budget`, `expected_dims`;
- `rigged`, `animated`, `bone_names`;
- `rig_profile` (`r15_pose`, `r15_avatar`);
- `allow_open`, `pivot = "custom"`, `up_axis_longest`, `qa = "skip"`;
- `texture_max` with `texture_justify` (2048 px);
- `appearance` (set by the bake routes);
- `collision` / `collision_max_tris` (set by `ops.collision_proxy`).

Clip actions carry `rbx_clip`; materials may carry `rbx_library`.

## Required context
- `tools/blender/bkit/qa.py` (`BUDGETS`, `run`, `gated_export`, `appearance_check`).
- `bkit/textures.py` (`image_checks`, colour spaces, suffixes), `bkit/clips.py` (`clip_checks`), `bkit/r15.py` (profiles, `check`), `bkit/env.py`.
- `docs/blender.md`: texture rules, clips/1, R15 profiles.

## Tools
- `python3 tools/blender/factory.py qa <file> [report.json]`: exit 1 on errors, 2 on an unsupported type. `template`, `bake`, `kit` and `intake` run the same gate.
- `python3 tools/gltf_validate.py <file.glb|.gltf> [--json]`: no bpy needed. It checks the container, accessor bounds, mesh attributes, at most 4 influences, normalised weights, the node graph, skins, animation samplers, image headers and TEXCOORD_0. `--gltf-transform` (or `FACTORY_GLTF_TRANSFORM=1`) adds `@gltf-transform/cli inspect` when npx exists.
- `factory.py qa-selftest <dir>`: known-good and known-bad assets must get the expected verdict from source QA, the saved `.blend`, the FBX and the GLB. It also runs the pipeline cases: bake routes, texture rules, library names, maps and tile bakes, icons, clips, clip failures, R15 profiles, collision, the ten gameplay templates, kit and intake. It writes `qa-selftest-report.json` and exits 1 on any disagreement.
- `factory.py compare-export <files> --expect <expectation.json>` diffs re-imported files with the expectation, using the ImportInspector rules.

## Procedure
1. Run QA. A `.blend` also gets the export probe: its Export collections are exported to FBX and GLB, re-imported and compared (triangles, bounds, names, animation). An `.fbx`/`.glb` is checked as imported.
2. Read `summary.errors` first.
   - Geometry: scale or rotation not applied, over 20k triangles, non-manifold, degenerate, loose vertices, inconsistent normals.
   - UVs: none, more than one set (`uv_single_set`), outside 0..1 (`uv_unit_square`).
   - Materials: unassigned material.
   - Textures: missing file (`texture_paths`), over 1024 px (`texture_size`), wrong colour space (`texture_colorspace`: colour and emissive sRGB; normal, roughness and metalness Non-Color).
   - Look: no declared look route (`appearance_declared`: Studio drops plain material colours, B06).
   - Skinning: over 4 influences, unweighted vertices, bone count.
   - Rig profile (`rig_profile*`): hierarchy, extra bones, facing, grounded, rest pose, sides, symmetry.
   - Clips: `clip_range`, `clip_names_unique`, `clip_slot`, `marker_in_range`, `clip_bones_known`, `clip_loop_closed`, `clip_in_place`.
   - Collision: `collision_proxy_tris` over its limit.
   - Export: probe mismatch, or a single root off the world origin (`studio_pivot_at_origin`).
3. Decide on `summary.warnings`:
   - budgets and open boundaries;
   - pivot not at the base centre;
   - zero-area UV faces and material count;
   - texture not a square power of two (`texture_pow2`) or not named with a Reimport suffix (`texture_suffix`);
   - weights not summing to 1.
4. Run `gltf_validate.py` on every GLB you ship (`pass`, no errors). Warnings such as `SECOND_UV_SET`, `IMAGE_SIZE` and `MESH_TRIANGLES` need a decision.
5. Fix in the source and re-run until there are no errors. Record accepted warnings in the asset's provenance note.

## Outputs
- QA JSON: `objects[].checks[]` (`name`, `pass`, `level`, `value`, `limit`, `detail`), `export` (probe per format, `.blend` only) and `summary`.
- gltf-validate/1 JSON: `pass`, `errors`, `warnings`, `info` (counts, animations, durations, skins).

## Acceptance
- `summary.pass == true` and every warning fixed or explained.
- For a `.blend`, the probe matched for FBX and GLB.
- `gltf_validate.py` passes on shipped GLBs.
- `qa-selftest` reports every case OK after any change to the gate.

## Failure
- A check is wrong for an asset class: set metadata on that asset (`allow_open`, `pivot = "custom"`, `budget`, `qa = "skip"`). Do not change global limits.
- `appearance_declared` fails: bake the look (`factory.py bake ... --mode palette`), or tag library materials `rbx_library`.
- `texture_colorspace` fails: a map's image is in the wrong space, or one image feeds both colour and data. FBX stores no colour space, so on an `.fbx` the check passes with a note.
- `uv_unit_square` fails after a bake: the packing margin pushed islands out. `bake.atlas_uvs` refits to 0..1.
- `rig_profile_sides` fails: Left bones sit at -X. A character facing -Y has its left at +X.
- `rig_profile_rest_pose` fails: a limb chain does not extend away from its shoulder or hip.
- `clip_loop_closed` fails: the loop's last frame does not repeat its first pose.
- A `.glb` hides skin-weight defects, because the exporter keeps the 4 strongest influences. Judge weights on the `.blend` or `.fbx`.
- An unreadable `.fbx`/`.glb` makes the importer raise. Run `gltf_validate.py` on a GLB to see the structural fault.

## Related
blender-asset-factory, blender-roblox-roundtrip, roblox-animation-integration, roblox-asset-intake.
