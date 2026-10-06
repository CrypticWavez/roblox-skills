# Blender factory

Headless: `python3 tools/blender/factory.py <command>` with the `bpy` wheel (bpy 5.0.1, 5.1.2 and 5.2.2 LTS all pass; CI runs 5.1.2 and 5.2.2 on Python 3.13) or `blender -b --python tools/blender/factory.py -- <command>` with an installed Blender. Axes: Z up, front -Y, 1 BU = 1 stud. Blender (x, y, z) arrives in Roblox as (-x, z, y): front -Y becomes front -Z, and a character's left (+X in Blender) stays its left.

| Command | Output |
|---|---|
| `template <kind> <dir> [--bake palette\|vertex\|none]` or `template --kind <kind> --out <dir\|file.glb\|file.fbx>` | Builds the kind and bakes its look (palette atlas by default), then saves `.blend`. QA runs before export: `.fbx`/`.glb` are written only without errors and are then re-imported and compared. Also writes `<kind>_expectation.json`, the clips (rigs with clips), `qa.json` and front/three-quarter PNGs. QA errors exit 1 with no FBX/GLB. `--out <file>` also copies the shipped file there |
| `templates <dir> [--kinds a,b]` | every kind (23) or the listed ones + `templates-summary.json` |
| `qa <file> [report]` | QA JSON for `.blend`/`.fbx`/`.glb`/`.gltf`; exit 1 on errors, 2 on another type. A `.blend` also probes its Export collections |
| `qa-selftest <dir>` | Known-good and known-bad assets must get the same verdict from source QA, the saved `.blend`, the FBX and the GLB. Also runs the ops, the bake routes, texture and library rules, icons, clips, R15 profiles, collision proxies, the ten gameplay templates (QA, glTF validation, compare-export), kit/1 and the offline intake. Writes `qa-selftest-report.json`; exit 1 on any disagreement |
| `render-manifest <manifest> <dir>` | Cycles previews of a SceneKit manifest |
| `roundtrip <dir>` | Marker v1/v2 with a body, front nose and side fin, palette-baked. Exports FBX and GLB, re-imports them and checks scale, pivot, facing, side, one material, colour map and colour attribute. Writes `roblox_expectation_v*.json` and `roundtrip-report.json` |
| `kit --templates a,b --out <kit.json> [--library <material-library.json>]` | kit/1 (SceneKit pieces): one GLB+FBX per piece at the world origin, QA'd again after export |
| `compare-export <file>... --expect <expectation.json> [--source factory\|studio]` | Re-imports FBX/GLB/glTF and diffs them with an expectation (the same rules as `ImportInspector`). Names a metre/stud mismatch (ratio 3.571 or 0.28: Scale Unit not set to Stud) |
| `textures <material-library.json> [--cache <dir>]` | Validates material-library/1 and every map on disk (size, colour mode, suffix). A ref that is neither in the repo nor in the cache is listed as not checked |
| `bake <kind\|file.blend> <dir> --mode palette\|vertex\|maps\|tile [--size N] [--library L] [--material M]` | Bakes a template or `.blend` and ships it through the gated export (palette, vertex, maps). `tile` instead bakes one material onto a 1x1 tile and writes `<name>_material-library.json`, keeping base_material/studs_per_tile/pattern from the `--library` entry of the same name |
| `material-preview <material-library.json> <dir>` | sphere+cube renders at `studs_per_tile` for every material whose maps are on disk |
| `icon <kind\|file.blend> <out.png> [--size N]` | deterministic transparent thumbnail (fixed camera, lights, samples, seed); reports `pixel_hash` |
| `intake <file> <dir> --key k --source cc0:<src>:<id> [--height H\|--scale S] [--bake auto\|palette\|vertex\|maps]` | Third-party model: QA the raw import, normalise (bake transforms, join to `SM_<Key>`, weld, recalc normals, base-centre pivot, size), bake, gated export, `<key>_kit.json` (kit/1 piece), expectation, raw and final previews, `intake-report.json`. Refuses armatures |

`python3 tools/gltf_validate.py <file.glb|.gltf> [--json] [--gltf-transform]` is pure Python (no bpy). It checks the GLB container, buffers and views, accessor bounds and alignment, mesh attributes, at most 4 joint influences, normalised weights, nodes (cycles, parents, TRS), skins, morph targets, animation samplers, image headers (PNG/JPEG size, at most 1024 px, power of two) and that textures use TEXCOORD_0. It writes `gltf-validate/1`. `@gltf-transform/cli inspect` runs only with `--gltf-transform` or `FACTORY_GLTF_TRANSFORM=1` and when npx exists. Tests: `python3 -m unittest tests/test_gltf_validate.py`.

Reproducible work goes through these scripts. Blender MCP is for interactive inspection, with one client per Blender instance (`docs/mcp.md`). Workflows are in the skills `blender-asset-factory`, `blender-asset-qa`, `blender-roblox-roundtrip` and `roblox-animation-integration`.

## Kinds
- humanoid, npc, enemy: R15 `r15_pose` rigs, rigid skinning. creature: quadruped. weapon: grip pivot. prop. vehicle: boolean cut. building: solidify and openings. modular: 4-stud kit. environment. material_test. rig_test and animation_test: smooth `bind_auto` weights.
- The neutral gameplay greyboxes (function-named, no theme) are:
  - pickup: upright disc, emissive core, no collision;
  - pad_button;
  - dropper: post, hopper, nozzle;
  - conveyor_segment: chevrons point travel -Y;
  - tower_base;
  - checkpoint_gate: 12 studs wide, with a respawn socket;
  - obby_platform_set: 6 separate kit pieces;
  - track_segment: 12x16;
  - pet_follower: custom rig with `idle` and `walk` clips in place, plus a clips/1 sidecar;
  - accessory_rigid: one mesh, a HatAttachment, at most 4000 triangles.

  Each one gets a `<kind>_Collision` proxy where its shape needs one.

## Look: bake routes (gap rows B06, B02)
Studio's Import 3D drops plain material colours: both marker parts arrived grey on 2026-10-05. A look must therefore travel as an image or as vertex colours. `bkit/bake.py` has three routes:
- `palette_atlas` (default). Each material becomes a cell of one small `<asset>_Color.png`. UV islands move into their material's cell, inside 0..1 with one UV set, and the materials collapse to one `MAT_<asset>`. No Cycles, so it is pixel-exact on every version. Roughness, metalness and emissive maps are written only when the materials differ in them. The same colours also go into a `Color` attribute as a fallback.
- `vertex_colors`: a `Color` attribute and one white material. Studio multiplies vertex colours by the part Color, so the part must be white.
- `atlas_uvs` + `bake_maps`: Cycles CPU bakes with fixed samples and seed and no denoiser. They produce base colour (sRGB), roughness and metalness (Non-Color, 8-bit grey), a tangent-space OpenGL normal and emissive. Use this route for procedural shaders and high-to-low detail. Island packing uses the AABB shape with axis-aligned rotation, because CONCAVE packing took up to 82 s per mesh. The bake margin is `max(2, size // 64)` px.

`tile` writes MaterialVariant-ready maps for the material library. Materials tagged `rbx_library = "<name>"` are left unbaked and listed as `library:<name>`. The kit command and QA check those names against material-library/1: G5's `assets/material-library.json`, or `tools/blender/fixtures/material-library.json` in tests. Every route records `rbx_appearance` on the mesh. The expectation and kit/1 cite it, and `ImportInspector` checks it in Studio.

## Texture rules (`bkit/textures.py`, QA)
- Maps are named `<Asset>_Color/_Normal/_Roughness/_Metalness/_Emissive.png`, the suffixes Studio's Reimport finds (`texture_suffix`, warning).
- Colour and emissive maps are sRGB. Normal, roughness and metalness maps are Non-Color (`texture_colorspace`, error). On an FBX re-import the check passes with a note, because FBX stores no colour space.
- PBR maps are at most 1024 px (`texture_size`, error). 2048 is allowed only with `rbx_texture_max` and a written `rbx_texture_justify`. Maps should be square powers of two (warning). Missing files fail `texture_paths`.
- There is one UV set (`uv_single_set`) inside 0..1 (`uv_unit_square`). Every mesh declares how its look travels (`appearance_declared`).

## Animation clips (clips/1, `bkit/clips.py`)
- A clip is an action tagged `rbx_clip = {name, slot, start, end, loop, root_motion, priority, weight, markers}`, listed on the rig's `rbx_clips`.
- Slots are the standard ones: idle, walk, run, jump, fall, climb, swim, sit, land, action_1..action_8.
- Export produces one multi-clip GLB (`<asset>_clips.glb`, one glTF animation per clip through temporary NLA tracks) and one FBX per clip (`<asset>_<clip>.fbx`).
- The FBX follows Roblox's Blender recipe: the active action baked over its own range, forced start/end keys off, simplify 0.0.
- The `<asset>_clips.json` sidecar (`docs/runtime-kits.md` 9.4) carries what files do not: loop, priority, root motion and marker frames. AnimSet applies them, and markers become `GetMarkerReachedSignal` names.
- Clip QA:
  - `clip_range`, `clip_names_unique`, `clip_slot`, `marker_in_range`, `clip_bones_known`;
  - `clip_loop_closed`: a loop's first and last poses match;
  - `clip_in_place`: no root travel unless `root_motion`;
  - `clip_scale_keys`.

## R15 rig profiles (`bkit/r15.py`, QA `rig_profile*`)
- `r15_pose` is what a Motor6D character's KeyframeSequence drives: `HumanoidRootPart > LowerTorso > ...` with 15 part bones.
- `r15_avatar` is an avatar body: `Root > HumanoidRootNode > LowerTorso`, `<Part>_Geo` meshes, nothing weighted to `Root`.
- Checks: hierarchy, extra bones, facing -Y, grounded, rest pose (each limb chain extends away from its shoulder or hip), sides and symmetry.
- A character facing -Y has its left at +X. The pre-existing humanoid, npc and enemy rigs had Left and Right mirrored. They are fixed and `rig_profile_sides` guards it.

## Collision and kit/1
- `ops.collision_proxy(obj, kind="hull"|"box", max_tris=256)` builds an invisible `<name>_Collision`. It is a convex hull, replaced by a 26-DOP when the hull has too many triangles. The proxy is tagged `rbx_collision`. Roblox imports neither collision meshes nor LODs. Whether FBX custom properties become attributes is UNVERIFIED, so the expectation and kit/1 carry the tags.
- kit/1 (`docs/runtime-kits.md` 9.5) entries record, per piece, in studs in Roblox axes around the base-centre pivot:
  - file, bounds, sockets, materials (`atlas:<file>`, `vertex_color`, `library:<name>`, `builtin:<Enum>`), collision, triangles and provenance.
- Templates use provenance `local-template`. Intake uses the `cc0:<src>:<id>` source.

## Retopology, LOD, weighting, sculpting (`bkit.ops`)
- `voxel_remesh(obj, voxel_size)` fuses blockout parts into one watertight shell. `quadriflow(obj, target_faces, seed)` makes clean quads and raises on non-manifold input. Both re-project materials and box UVs. Vertex groups are lost, so remesh before rigging. Same seed gives the same vertices on all three versions.
- `lod_chain(obj, ratios)` builds `<name>_LOD1..` with strictly decreasing triangle counts. `bind_auto(mesh, rig)` uses bone heat, then limits to 4 normalised influences; vertices heat misses go to the nearest bone. `bind_rigid` is for parts that move as units.
- Scripted sculpting is INTENTIONALLY_EXCLUDED: `sculpt.brush_stroke` needs a 3D viewport. The headless stand-in is `noise_displace`. Judge weights on the `.blend` or `.fbx`, because the glTF exporter keeps only the 4 strongest influences.

## Studio import behaviour
Observed 2026-10-05 (Studio 0.741.19, Import 3D, `reports/studio/roundtrip-2026-10-05.json`):
- With `export_fbx` defaults and Scale Unit = Stud, 1 BU = 1 stud and Blender -Y becomes Roblox -Z.
- The pivot is the file origin, so export single assets at the world origin (`studio_pivot_at_origin`). A kit of several roots only warns.
- Flat material colours arrive grey (B06), which is why palette atlas is the default.
- Every import uploads the mesh as a private asset. There is no local-only route, so Studio checks are owner-run.

Pending T3 probes run by the owner in the unpublished diagnostic place after a manual import:
- `tests/engine/import_appearance.luau` checks colour map, PBR maps, vertex colours, side and facing. It closes B06 and B02.
- `tests/engine/import_clips.luau` checks clips present, lengths within half a frame, markers and the play plan. It also records where the importer stores clips: the model or `ServerStorage.RBX_ANIMSAVES`. It closes B07.

Until those run, B06 and B07 stay BLOCKED_EXTERNAL.

UNVERIFIED:
- how Studio's glTF import treats the packed metallicRoughness image the exporter writes (QA accepts its name on a `.glb`; the FBX route ships separate `_Roughness`/`_Metalness` files);
- FBX markers reaching Studio;
- custom properties becoming attributes;
- where Import 3D stores animations. The Clip Editor saves to RBX_ANIMSAVES, and since 2026-08-04 it auto-saves animations from imported models (research).

## REVISIT
- Animation Graphs: full release 2026-07-15, with state machines, Blend1D/2D and `AnimationTrack:SetParameter`. Graphs "must be published as assets" to work in live games, so they cannot be exercised in SETUP_ONLY.
  - Trigger: a game repository needs state-machine or blend-space locomotion, or Roblox lets unpublished graphs run in a local place.
  - Then: export blend-space clip sets from `bkit.clips` and emit a graph description next to clips/1.
- Adaptive Animation: full release 2026-04-29. `HumanoidRigDescription` and `DigitsRigDescription` map at least 15 joints of a custom rig to the standard skeleton so it plays R15 clips. It is configured in the Avatar tab; no script API is documented.
  - Trigger: a game repository needs R15 clips on a non-R15 rig (pet_follower-style custom rigs), or a script API appears.
  - Then: add an `adaptive` rig profile and a joint-map sidecar.

## Fixed defects found by running
- 2026-10-05:
  - FBX dropped animation;
  - joined meshes lost material indices;
  - mirroring produced non-manifold geometry;
  - glTF bone shapes polluted import signatures;
  - SceneKit wedge preview orientation.
- 2026-10-06:
  - the humanoid, npc and enemy Left/Right bones were mirrored;
  - the glTF export wrote no vertex colours, because the default only writes colours a material reads;
  - the FBX animation recipe was not Roblox's: forced start/end keys and simplification were on;
  - materials were looked up by localised node name;
  - CONCAVE UV packing took minutes;
  - the conveyor's +X chevron arm was coplanar with the belt;
  - a relative output folder made Blender resolve baked map paths against the filesystem root;
  - `qa` crashed on re-imported clip files, whose actions come back without `rbx_clip`.
