# Blender factory

Headless: `python3 tools/blender/factory.py <command>` with the `bpy` wheel (CI: bpy 5.1.2 and 5.2.2 LTS on Python 3.13; 5.0.1 also passes) or `blender -b --python tools/blender/factory.py -- <command>` with an installed Blender (local: 5.1.2).

| Command | Output |
|---|---|
| `template <kind> <dir>` | `.blend`, `qa.json`, front/three-quarter PNGs; QA runs first and `.fbx`/`.glb` are written (then re-imported and compared) only when it has no errors, otherwise exit 1 and no FBX/GLB |
| `templates <dir> [--no-previews]` | all 13 kinds + `templates-summary.json` |
| `qa <file> [report]` | QA JSON only (no previews) for a `.blend`, `.fbx`, `.glb` or `.gltf`; exit 1 on errors, 2 on another file type. A `.blend` also probes its Export collections; the factory's own `.fbx`/`.glb` pass |
| `qa-selftest <dir>` | known-good and known-bad assets must get the same verdict from source, FBX and GLB QA; `qa-selftest-report.json`, exit 1 on any disagreement |
| `render-manifest <manifest> <dir>` | Cycles previews (`<name>.three-quarter.png`, `<name>.top.png`) of a SceneKit manifest; cameras are framed from the part bounds when the manifest has none |
| `roundtrip <dir>` | v1/v2 marker asset, FBX+GLB re-import checks, `roblox_expectation_v*.json`, `roundtrip-report.json` |

Reproducible work goes through these scripts; Blender MCP is for interactive inspection, one client per Blender instance (`docs/mcp.md`, Operation ownership). Workflows: skills `blender-asset-factory`, `blender-asset-qa`, `blender-roblox-roundtrip`.

Kinds: humanoid, npc, enemy (R15-named rigs, rigid skinning), creature (quadruped rig), weapon (grip pivot), prop, vehicle (boolean cut), building (solidify + boolean openings), modular (4-stud grid kit), environment (rock, tree), material_test, rig_test, animation_test.

Built-ins used: bmesh, modifiers (Bevel, Boolean EXACT, Mirror, Array, Solidify, Armature), curves, Principled BSDF, glTF/FBX exporters. Rigify and LoopTools are now extensions (optional; not required by any script). Geometry Nodes, Asset Browser and baking are not yet scripted (gap matrix).

Studio import behaviour observed on 2026-10-05 (Studio 0.741.19, Import 3D, `reports/studio/roundtrip-2026-10-05.json`):
- With `bkit.ops.export_fbx` defaults and Scale Unit = Stud, 1 Blender unit is 1 stud and Blender -Y (front) becomes Roblox -Z (front).
- The imported Model's pivot is the FBX file origin, not the object origin: export single assets at the world origin (QA error `studio_pivot_at_origin`).
- Per-material base colours without image textures arrive as plain grey: colour has to be baked into a texture (gap B06).
- Every import uploads the mesh as a private asset on the account; there is no local-only route.

Fixed defects found by running (2026-10-05): FBX export dropped animation (NLA baking default), joined meshes lost material indices, mirror around the part's own origin produced non-manifold geometry, glTF bone-shape meshes polluted import signatures, SceneKit wedge preview orientation.
