# Blender factory

Headless: `python3 tools/blender/factory.py <command>` with the `bpy` wheel (CI: bpy 5.1.2 and 5.2.2 LTS on Python 3.13; 5.0.1 also passes) or `blender -b --python tools/blender/factory.py -- <command>` with an installed Blender (local: 5.1.2).

| Command | Output |
|---|---|
| `template <kind> <dir>` | `.blend`, `qa.json`, front/three-quarter PNGs; QA runs first and `.fbx`/`.glb` are written (then re-imported and compared) only when it has no errors, otherwise exit 1 and no FBX/GLB |
| `templates <dir> [--no-previews]` | all 13 kinds + `templates-summary.json` |
| `qa <file> [report]` | QA JSON only (no previews) for a `.blend`, `.fbx`, `.glb` or `.gltf`; exit 1 on errors, 2 on another file type. A `.blend` also probes its Export collections; the factory's own `.fbx`/`.glb` pass |
| `qa-selftest <dir>` | Known-good and known-bad assets must get the expected verdict from source QA and from `qa` on the saved `.blend` (no Export collection), the FBX and the GLB. This covers an off-origin single root, the retopology, LOD and weighting ops' output and the export gate. Op refusals must raise, and seeded-op geometry hashes are reported. Writes `qa-selftest-report.json`; exit 1 on any disagreement |
| `render-manifest <manifest> <dir>` | Cycles previews (`<name>.three-quarter.png`, `<name>.top.png`) of a SceneKit manifest; cameras are framed from the part bounds when the manifest has none |
| `roundtrip <dir>` | v1/v2 marker asset, FBX+GLB re-import checks, `roblox_expectation_v*.json`, `roundtrip-report.json` |

Reproducible work goes through these scripts; Blender MCP is for interactive inspection, one client per Blender instance (`docs/mcp.md`, Operation ownership). Workflows: skills `blender-asset-factory`, `blender-asset-qa`, `blender-roblox-roundtrip`.

Kinds: humanoid, npc, enemy (R15-named rigs, rigid skinning: blocky parts move as units), creature (quadruped rig), weapon (grip pivot), prop, vehicle (boolean cut), building (solidify + boolean openings), modular (4-stud grid kit), environment (rock, tree), material_test, rig_test and animation_test (one continuous column, smooth `bind_auto` weights).

Built-ins used: bmesh, modifiers (Bevel, Boolean EXACT, Mirror, Array, Solidify, Armature, Remesh voxel, Decimate collapse), QuadriFlow, automatic bone-heat weights, `mathutils.noise`, curves, Principled BSDF, glTF/FBX exporters. Rigify and LoopTools are now extensions (optional; not required by any script). Geometry Nodes, Asset Browser and baking are not yet scripted (gap matrix).

Retopology, LOD, weighting and sculpting (`bkit.ops`; headless on bpy 5.0.1, 5.1.2 and 5.2.2; `qa-selftest` covers each):
- `voxel_remesh(obj, voxel_size)` fuses intersecting blockout parts into one watertight quad shell. `quadriflow(obj, target_faces, seed)` gives clean quads near a target and raises on non-manifold or inconsistently oriented input. Both bake the modifier stack, re-project material indices from the source and re-apply box UVs; vertex groups are lost, so remesh before rigging. Same seed, same vertices: the self-test's geometry hashes match on all three versions.
- `lod_chain(obj, ratios)` adds `<name>_LOD1..` copies (Decimate collapse) with strictly decreasing triangle counts, or raises and removes them. Skinned copies keep the Armature modifier and get `limit_weights` again.
- `bind_auto(mesh, rig)`: bone-heat weights, then `limit_weights` (at most 4 influences per vertex, Roblox's limit, normalised). Heat can fail silently on shells no bone reaches. `bind_auto` binds those vertices to the nearest bone and prints the count (`rbx_weighting`), or raises with `fallback=None`. `bind_rigid` stays the choice for parts that move as units.
- Sculpting is intentionally excluded from scripts: `bpy.ops.sculpt.brush_stroke` fails its poll in background mode ("context is incorrect": it needs a 3D viewport), and a scripted stroke path is not reviewable art. The headless stand-in is `noise_displace(obj, strength, scale, seed)`: seeded fractal noise along normals, for rocks, cliffs and terrain pieces. Hand sculpting happens in Blender; the saved file then goes through `qa`.
- Weights must be judged on the `.blend` or `.fbx`. Blender's glTF exporter keeps the 4 strongest influences and re-imports unweighted vertices bound to one bone, so a `.glb` passes `bone_influences`/`unweighted_vertices` either way.

Studio import behaviour observed on 2026-10-05 (Studio 0.741.19, Import 3D, `reports/studio/roundtrip-2026-10-05.json`):
- With `bkit.ops.export_fbx` defaults and Scale Unit = Stud, 1 Blender unit is 1 stud and Blender -Y (front) becomes Roblox -Z (front).
- The imported Model's pivot is the FBX file origin, not the object origin: export single assets at the world origin. QA error `studio_pivot_at_origin` covers the export set of `template` and of a `.blend` with Export collections. It also covers the scene roots of a `.blend` without them (minus cutters, `qa = "skip"` helpers, cameras and lights) and the imported roots of an `.fbx`/`.glb`/`.gltf`. Several roots (a kit) only warn.
- Per-material base colours without image textures arrive as plain grey: colour has to be baked into a texture (gap B06).
- Every import uploads the mesh as a private asset on the account; there is no local-only route.

Fixed defects found by running (2026-10-05): FBX export dropped animation (NLA baking default), joined meshes lost material indices, mirror around the part's own origin produced non-manifold geometry, glTF bone-shape meshes polluted import signatures, SceneKit wedge preview orientation.
