# Blender factory

Headless: `python3 tools/blender/factory.py <command>` with the `bpy` wheel (CI: bpy 5.1.2 and 5.2.2 LTS on Python 3.13; 5.0.1 also passes) or `blender -b --python tools/blender/factory.py -- <command>` with an installed Blender (local: 5.1.2).

| Command | Output |
|---|---|
| `template <kind> <dir>` | `.blend`, `.fbx`, `.glb`, `qa.json` (incl. export re-import probe), front/three-quarter PNGs |
| `templates <dir>` | all 13 kinds + `templates-summary.json` |
| `qa <file> [report]` | QA JSON; exit 1 on errors |
| `render-manifest <manifest> <dir>` | Cycles previews of a SceneKit manifest |
| `roundtrip <dir>` | v1/v2 marker asset, FBX+GLB re-import checks, `roblox_expectation_v*.json`, `roundtrip-report.json` |

Kinds: humanoid, npc, enemy (R15-named rigs, rigid skinning), creature (quadruped rig), weapon (grip pivot), prop, vehicle (boolean cut), building (solidify + boolean openings), modular (4-stud grid kit), environment (rock, tree), material_test, rig_test, animation_test.

Built-ins used: bmesh, modifiers (Bevel, Boolean EXACT, Mirror, Array, Solidify, Armature), curves, Principled BSDF, glTF/FBX exporters. Rigify and LoopTools are now extensions (optional; not required by any script). Geometry Nodes, Asset Browser and baking are not yet scripted (gap matrix).

Fixed defects found by running (2026-10-05): FBX export dropped animation (NLA baking default), joined meshes lost material indices, mirror around the part's own origin produced non-manifold geometry, glTF bone-shape meshes polluted import signatures, SceneKit wedge preview orientation.
