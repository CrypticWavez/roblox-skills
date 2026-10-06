# Blender and animation pipeline to Roblox (verified 2026-10-06)

Scope: texture baking and colour transfer (gap-matrix row B06), Roblox import behaviour for FBX/glTF, Roblox character standards, animation export from Blender, LOD and collision, Geometry Nodes and the Asset Browser, and the free tools around them. This extends existing research rather than repeating it:
- [tooling-2026-10.md](tooling-2026-10.md) sections 4-6: Blender versions, `bpy` wheel, Rigify/LoopTools versions, mesh import basics.
- [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md) section B: Animation Editor, Animation Capture, the Roblox Blender plugin and Moon Animator 2 decisions.
- [genre-coverage-2026-10.md](genre-coverage-2026-10.md) section 5: the 2026 animation stack (Animation Graphs, Adaptive Animation, Clip Editor import).
- [ui-cinematics-feel-2026-10.md](ui-cinematics-feel-2026-10.md) sections 4d and 6.2: camera and cutscene export from Blender as data.

Inputs read in this repo: `tools/blender/factory.py`, `tools/blender/bkit/*.py`, the three `blender-*` skills, `roblox-animation-integration`, `packages/Pipeline/ImportInspector.luau`, `docs/blender.md` and gap rows B01-B09 in `reports/gap-matrix.json`.

**Method.** Every source was fetched on 2026-10-06. Source ids (R, D, E, G, B, T) refer to the list at the end.
- Primary sources only: create.roblox.com `.md` page variants (located through `/docs/llms.txt`), DevForum announcements and staff posts, Blender source and manual sources on projects.blender.org, PyPI, the npm registry, extensions.blender.org, GitHub repo pages and vendor pages.
- Some fetch routes failed. docs.blender.org pages returned only navigation through the fetcher, so the manual's RST source was used. The Blender API reference body could not be read, so operator properties were read from the Blender source on the `blender-v5.2-release` branch. developer.blender.org redirected in a loop, so the release-notes Markdown source was used. Creator Store pages render client-side, so asset metadata came from Roblox's public read-only economy endpoint (`https://economy.roblox.com/v2/assets/<id>/details`).
- Pages were read through a summarising fetcher; short quotes are given where wording matters.
- DevForum feature requests and user reports are leads, not evidence, and say so.
- Nothing was installed, bought, downloaded or signed up for.

**Decision rule** (as in the addendum). SELECT means use now, or keep using, inside SETUP_ONLY. REJECT means do not adopt. REVISIT means the decision waits for a stated trigger. Anything that publishes, uploads, spends or picks game content is REJECT here, whatever its merit.

---

## 1. Key findings

1. **Why B06 happens and the cheapest fixes.** The importer turns image textures wired into the Principled BSDF into a SurfaceAppearance (D1). Studio renders vertex colours "multiplied against the BrickColor or Color property of the meshPart" (D3, Roblox staff). Plain Principled values with no image are dropped, which the repo observed (`reports/studio/roundtrip-2026-10-05.json`). That gives three routes, in this order:
   - a deterministic **palette atlas**: per-material flat colours written into a small texture with bpy, no Cycles needed;
   - **vertex colours** from material colours, with no texture at all;
   - a **Cycles bake** for procedural or high-poly detail.
2. **Texture rules that fix bake settings** (R3, R4):
   - Normal maps must be OpenGL tangent space. Blender's bake defaults are tangent space with swizzle +X/+Y/+Z, which is the OpenGL convention (B2).
   - Roughness, metalness and emissive maps are 8-bit single-channel greyscale.
   - One UV set per mesh, in 0..1; overlapping UVs are allowed.
   - Basic textures go up to 4096 px. The SurfaceAppearance budget table tops out at "1024×1024 (maximum)". Avatar bodies and accessories sold on the Marketplace may use 2048 (R13, R18).
   - Cycles has no Metallic bake type (B1), so metalness needs an emission swap or a generated image.
   - Studio's Reimport recognises PBR maps by filename suffix (R11). Adopt `<Asset>_Color.png`, `_Metalness.png`, `_Roughness.png`, `_Normal.png` and `_Emissive.png`.
3. **Roblox imports neither LODs nor collision meshes.**
   - The engine makes 4 LOD levels in the cloud. The opt-in `Workspace.MeshStreamingAndImprovedLoDs` ignores `RenderFidelity` (D7). A 2025 feature request for custom LODs shows no staff answer (D8).
   - Collision is chosen per MeshPart with `CollisionFidelity`: Box, Hull, Default, PreciseConvexDecomposition or Tunable (R8). Neither the importer nor the collisions page mentions a custom collision mesh (R1, R9).
   - So `ops.lod_chain` copies cannot become Roblox LODs, and collision has to be handled with invisible proxy parts in the scene.
4. **"R15" means two different naming trees.**
   - A KeyframeSequence for a Motor6D character has a root Pose named `HumanoidRootPart`, with `LowerTorso` and the other parts below it. Each Pose is matched to a part by name and drives that part's Motor6D (R27, R28).
   - An avatar body follows a different spec (R13):
     - the bone tree is `Root > HumanoidRootNode > LowerTorso > ...`;
     - there are 15 separate meshes named `<Part>_Geo`, and `_Att` attachments;
     - a vertex may not be weighted to `Root`;
     - triangle budgets are 4000 for the head, 1750 for the torso and 1248 for each limb (10,742 in total);
     - each body-scale type (Classic, Normal, Slender) has its own size range.
   - `bkit/templates.py` `R15_BONES` follows the first tree only.
   - Cages must start from Roblox's template cages, and their vertices and UVs must not change (R19). So the factory cannot generate valid cages itself. The Avatar Setup tool generates rigging, skinning, cages, FACS and the 15-part split inside Studio (R15).
5. **Animation export settings.**
   - Roblox's Blender export recipe for animation: NLA Strips, All Actions and Force Start/End Keyframes off, Simplify 0.0, Custom Properties on, Leaf Bones off (R20).
   - `ops.export_fbx` keeps the exporter defaults for Force Start/End Keying (True) and Simplify (1.0) (B4), so it deviates from that recipe on two settings.
   - The Animation Clip Editor imports FBX and glTF, several clips per file, and saves them to `ServerStorage/RBX_ANIMSAVES`; "a separate step is still required to upload them" (D5). Since 2026-08-04 the import also lets you pick the rig type, rig scale, rest-pose source and which tracks to import (D6).
   - `AnimationClipProvider:RegisterAnimationClip` returns a Studio-only temporary id (R25), which gives a way to test clip playback with no upload.
   - The Curve Editor converts a KeyframeSequence to a CurveAnimation one way only (R23). Emotes "must be sourced from a CurveAnimation" (R21).
6. **Studio can now export what it holds.** 3D Export (beta, page updated 2026-09-24) writes glTF with meshes, textures, rigging and skinning, vertex colours, cages and FACS data. It does not export animation (R12). An exported file can be checked headlessly with bpy, so B06 and B07 no longer depend only on the untested EditableMesh colour reader in Studio.
7. **Blender 5.x API changes that bkit must follow** (B6):
   - the legacy `Action.fcurves`, `Action.groups` and `Action.id_root` were removed in 5.0; use channelbags instead;
   - `material.use_nodes` is deprecated (it always returns True) and will be removed in 6.0;
   - `ImageFormatSettings.media_type` must be set before `file_format`;
   - `ops.pbr_material` and `render.py` find the Principled node by its English name. The Blender MCP guidance says to look nodes up by type, because names are localised.
8. **Tools.**
   - SELECT the built-ins: Cycles bake, UV packing, colour attributes, Geometry Nodes, Asset Browser catalogs, FBX/glTF exporter settings, Node Wrangler, and on the Roblox side the 3D Importer, Clip Editor import, `AnimationClipProvider` and 3D Export.
   - SELECT `@gltf-transform/cli` 4.5.1 (MIT) as an optional pinned validator and clip resampler, and Krita 5.3.4 (GPL-3.0) as an optional PC painting tool.
   - REJECT Moon Animator 2, which is paid; its listing was updated 2026-09-27, and a third-party "Free Version" reupload exists. Also REJECT Auto-Rig Pro (USD 25/50), TexTools (not on the Extensions Platform), Material Maker and ImageMagick (both overlap existing tools), and Bool Tool (overlaps `ops.boolean`).

## 2. Roblox import behaviour (FBX/glTF)

| Fact | Source |
|---|---|
| FBX and glTF carry "basic and PBR textures", rigging, skinning, animation, cages and vertex colours. The importer page was last updated 2026-03-31 | R1, R2 |
| Import settings: Upload to Roblox ("By default, this is enabled"), Import Only As Model, Insert Using Scene Position, Set Pivot to Scene Origin, Keep Zero Influence Bones, Anchored, Uses Cage (cages become WrapInstances), Rig Type (R15, Custom or No Rig), Validate UGC Body (opens Avatar Setup), Rig Scale, World Forward/Up, Scale Unit (default Studs), Merge Meshes, Invert Negative Faces, and per-object Use Imported Pivot, Make Double Sided and Ignore Vertex Colors (off by default) | R1 |
| PBR on import: in Blender, connect image texture nodes "for Base Color, Metallic, and Roughness directly into the correlating BSDF slots"; the importer creates the SurfaceAppearance in the same step (2022 announcement). A 2026-05-11 user report says the importer now adds a SurfaceAppearance to every avatar import (lead) | D1, D2 |
| A MeshPart takes one texture through `TextureID` or up to four PBR maps through a SurfaceAppearance, which "overwrites the original assigned texture". "Setting a Texture ID can't override the PBR textures" | R3, R7 |
| SurfaceAppearance maps are ColorMap, NormalMap, RoughnessMap, MetalnessMap and EmissiveMaskContent. AlphaMode can be Opaque, Overlay (default), Transparency or TintMask. `Color` multiplies the ColorMap | R3 |
| Textures (R4):<br>- formats: png, jpg, tga, bmp;<br>- albedo is 24-bit RGB; normal maps are 24-bit RGB, "OpenGL format - Tangent Space";<br>- roughness, metalness and emissive maps are 8-bit greyscale; no packed ORM map is mentioned;<br>- one UV set in 0:1, overlapping UVs allowed;<br>- 4096 px for basic textures; the SurfaceAppearance budget table tops out at 1024 "(maximum)" | R4 |
| Blender FBX export recipe: Path Mode Copy, Embed Textures, Apply Scalings = FBX Unit Scale, Add Leaf Bones off, Bake Animation off unless the file is animated | R5 |
| Vertex colours: in Blender, a colour attribute with Domain Vertex and Data Type Color. In Studio they are "multiplied against the BrickColor or Color" of the MeshPart, whose default is grey. Under a SurfaceAppearance in Overlay mode they tint the pixels masked by the albedo alpha (staff, 2024-07-02). A 2025-10-06 feature request says they have "no effect on surface appearance rendering" (lead; conflicts with the staff post) | R6, D3, D4 |
| Reimport updates the mesh and transform but keeps CollisionFidelity and RenderFidelity. It detects PBR maps in the same folder by suffix (color: color/col/diffuse/diff/albedo/alb/base; metalness: metal/metallic/metalness/mtl/met; roughness: rough/roughness/rgh; normal: normal/nor/nrm/nrml/norm; emissive: emissive/emission/emiss/emit/glow/...). It uploads, but skips meshes it already knows | R11 |
| 3D Export (beta: File > Beta Features > glTF Export; right-click > Save / Export > Export as glTF) exports meshes, textures, rigging and skinning, vertex colours, cages and FACS data. It "does not support animation data". The page does not mention a script API | R12 |

Consequences for the factory:
- Keep FBX as the textured route. Its exporter writes separate maps and embeds them; the importer's handling of glTF's packed metallic-roughness texture is not documented (UNVERIFIED).
- Every textured import uploads images as well as the mesh, so each Studio test needs the owner's go-ahead, as B05 already records.
- `Use Imported Pivot` and `Set Pivot to Scene Origin` may change the pivot behaviour recorded in B05. Their effect is UNVERIFIED; the world-origin export rule stays until a Studio test shows otherwise.

## 3. Texture baking and colour transfer (B06)

### 3.1 Blender facts

| Fact | Source |
|---|---|
| Bake types: Combined, Ambient Occlusion, Shadow, Position, Normal, UV, Roughness, Emit, Environment, Diffuse, Glossy, Transmission. There is no Metallic type | B1 |
| The active Image Texture node of each material is the bake target. Target can be "Image Textures" or "Active Color Attribute", so a bake can write vertex colours directly | B1 |
| Selected to Active: a cage, or "Cage Extrusion" and "Max Ray Distance"; normal space Object or Tangent; R/G/B swizzle | B1 |
| `OBJECT_OT_bake` defaults on the 5.2 branch, as C constants: `type` `SCE_PASS_COMBINED`, `margin` 16 px, `margin_type` `R_BAKE_EXTEND` (the other option is Adjacent Faces), `normal_space` `R_BAKE_SPACE_TANGENT`, `normal_r/g/b` `R_BAKE_POSX/POSY/POSZ` (+Y green, the OpenGL convention), `target` `R_BAKE_TARGET_IMAGE_TEXTURES`, `width`/`height` 512, `use_clear` false. Other properties: `use_selected_to_active`, `cage_extrusion`, `max_ray_distance`, `cage_object`, `uv_layer`, `use_split_materials`, `save_mode`. Python enum identifiers should be read from RNA, not assumed | B2 |
| `UV_OT_pack_islands` properties: `shape_method` (CONCAVE, CONVEX or AABB), `margin_method` (SCALED, ADD or FRACTION), `margin` (default 0.001), `rotate`/`rotate_method`, `scale`, `merge_overlap`, `pin`, `udim_source`. The poll is `ED_operator_uvedit`, which by its name needs an edit-mode mesh rather than a UV editor window; row 4 of section 9 confirms this headless | B3 |
| FBX exporter 5.15.0 defaults: `colors_type` SRGB (vertex colours exported), `embed_textures` false, `use_custom_props` false, `bake_anim_use_nla_strips` true, `bake_anim_use_all_actions` true, `bake_anim_force_startend_keying` true, `bake_anim_simplify_factor` 1.0, `add_leaf_bones` true, `use_tspace` false | B4 |
| glTF exporter 5.2.40 defaults: `export_vertex_color` MATERIAL (vertex colours only when a material uses them; the other options are ACTIVE, NAME and NONE), `export_animation_mode` ACTIONS (every action becomes a glTF animation), `export_force_sampling` true, `export_optimize_animation_size` true, `export_influence_nb` 4, `export_image_format` AUTO, `export_apply` false, `export_extras` false | B5 |
| `bpy` 5.2.2 (2026-09-15) is the latest; 5.1.2 (2026-05-19) and 5.0.1 (2025-12-16) are the other pinned versions. Python 3.13 only, GPL-3.0 | B11 |

### 3.2 Design for `bkit/bake.py`

The routes in order of preference:
1. **`palette_atlas` (default for the 13 templates; they all use flat colours).** No Cycles, so the output is pixel-exact and the same on every bpy version.
   - Give each material slot a cell of a grid image, 16 px per cell by default, padded to a power of two.
   - Move each material's existing box-UV islands into the inner half of its cell. The UVs keep their area, so QA's `uv_zero_area_faces` stays quiet and tangents stay defined.
   - Write `<Asset>_Color.png` (Principled base colour, converted from scene-linear to sRGB with `mathutils.Color.from_scene_linear_to_srgb`, alpha 255).
   - Write `<Asset>_Roughness.png` and `<Asset>_Metalness.png` only when the materials differ in those values, and `<Asset>_Emissive.png` only when some material emits.
   - Replace the slots with one `MAT_<Asset>` that wires these images into the Principled BSDF.
   - Mipmap bleeding between cells is a heuristic risk. Cells of at least 16 px keep about four mip levels pure; this is UNVERIFIED on Roblox.
   - gltf-transform's `palette` does the same for glTF, but "materials already containing texture coordinates (UVs) are not eligible" (T2). The factory's meshes all have UVs, so a bpy implementation is needed.
2. **`vertex_colors_from_materials`.** Write a `BYTE_COLOR` attribute from each face's material colour, then use one white material.
   - Export with FBX `colors_type="SRGB"` and GLB `export_vertex_color="ACTIVE"`.
   - Roblox docs ask for the Vertex (point) domain (R6). For welded meshes such as `voxel_remesh` output, face-corner colours are needed to keep material borders hard; whether Roblox keeps them is UNVERIFIED.
   - The MeshPart `Color` must be white in Studio, because Studio multiplies it.
   - Use this route for no-texture stylised kits, combined with Roblox materials or MaterialVariants.
3. **`atlas_uvs` + `bake_maps` (for procedural shaders and high-to-low-poly detail).**
   - `atlas_uvs` makes a new `AtlasUV` layer with `uv.smart_project` and `uv.pack_islands(shape_method="CONCAVE", margin_method="FRACTION", margin=margin_px/size)`, then deletes every other UV layer before export.
   - `bake_maps` uses Cycles on the CPU with `samples=1` for the value passes:
     - colour: `DIFFUSE` with `pass_filter={"COLOR"}`;
     - roughness: `ROUGHNESS`;
     - metalness: temporarily route Metallic into an Emission shader and bake `EMIT`;
     - normal: `NORMAL`, tangent space, Selected to Active from an optional high-poly source with `cage_extrusion`;
     - emissive: `EMIT`.
   - Save 8-bit PNGs: sRGB for colour, Non-Color for the others. Use 1024 px by default (the SurfaceAppearance table) and a 16 px EXTEND margin (the Blender default).
   - Read enum identifiers from RNA at run time instead of hard-coding them, as the MCP guidance asks.

```python
# sketch of the public API (bkit/bake.py); each returns a manifest dict also stored as rbx_appearance
palette_atlas(obj, out_dir, asset=None, cell=16) -> {"kind": "texture", "maps": {...}, "cells": {...}}
vertex_colors_from_materials(obj, domain="CORNER") -> {"kind": "vertex_colors", "colors": n}
atlas_uvs(obj, size=1024, margin_px=16, method="smart", angle_limit=66) -> "AtlasUV"
bake_maps(obj, out_dir, maps=("color", "roughness", "metalness", "normal"), size=1024,
          margin=16, high=None, cage_extrusion=0.02) -> {"kind": "texture", "maps": {...}}
```

QA additions in `qa.py`:
- errors for a textured mesh with more than one UV layer (`uv_single_set`) or UVs outside 0..1 (`uv_unit_square`);
- an error for a PBR map over 1024 px or a basic texture over 4096 px (`texture_size`);
- an error for a normal, roughness or metalness map not in Non-Color (`texture_colorspace`);
- a warning for a texture name without a Roblox suffix (`texture_suffix`) and for a size that is not a power of two;
- a warning, and an error once templates bake by default, for a multi-material mesh with no texture and no vertex colours (`appearance_declared`, "colours will be lost in Studio, B06").

The round-trip expectation gains an `appearance` block (`kind`, map names, palette size). Today `ImportInspector` passes `appearance_bound` whenever an asset has at most one material, which is exactly what a baked asset will have. With the new block it must instead require one of these:
- a SurfaceAppearance with a ColorMap, or a `TextureID`;
- or, for vertex colours, as many distinct vertex colours as the palette has, plus a white part `Color`.

## 4. Character and avatar standards

| Fact | Source |
|---|---|
| Avatar body: 15 meshes named `<Part>_Geo` (UpperTorso, LowerTorso, Head, and Left/Right UpperArm, LowerArm, Hand, UpperLeg, LowerLeg, Foot). Bone tree `Root > HumanoidRootNode > LowerTorso > UpperTorso > Head`, arms under UpperTorso, legs under LowerTorso. Higher-fidelity optional bones (Spine, Chest, HeadBase, clavicles, three bones per finger, toe bases), up to 37 | R13 |
| Attachments (`_Att`):<br>- Head: FaceCenter, FaceFront, Hat, Hair;<br>- UpperTorso: LeftCollar, RightCollar, Neck, BodyBack, BodyFront;<br>- LowerTorso: Root (must be at 0,0,0), WaistFront, WaistBack, WaistCenter;<br>- shoulders on the upper arms;<br>- grips on the hands, "perpendicular to the lower arm bone";<br>- feet | R13 |
| Rigging: at most 4 influences, no weights on Root, I-, A- or T-pose, transforms frozen with pivots at 0,0,0 | R13 |
| Budgets: DynamicHead 4000 triangles, torso 1750, each arm or leg 1248, 10,742 in total. Body textures up to 2048. Body scale (studs, width/height/depth): Normal 1.35-8.6 / 3.6-9.5 / 0.7-2.25; Slender 1.35-6 / 3.6-9.5 / 0.7-2; Classic 1.35-8 / 3.6-9.1 / 0.7-2 | R13 |
| Heads need at least 17 FACS reference poses "to support avatar chat" | R14 |
| Cages:<br>- bodies need only `_OuterCage` meshes;<br>- layered clothing needs `<Name>_InnerCage` and `<Name>_OuterCage`, starting from template cages;<br>- vertices and UVs "should not be deleted or removed";<br>- clothing is skinned to an R15 armature with at most 4 influences;<br>- accessories may have at most 4k triangles and textures up to 2048 | R13, R18, R19 |
| Avatar Setup (page updated 2026-10-02) rigs and skins a body, generates FACS poses, facial rig and animation, adds cages and splits the mesh into 15 parts. Input is a Model of MeshParts. Its Save step uploads to the inventory or publishes to the Marketplace, which costs an upload fee | R15 |
| Reference files (page updated 2026-07-15):<br>- higher-fidelity Mannequin, Robuta, HipToBeSquare and Roxie;<br>- Lola, Fish-Person, BlockyCharacter and GoblinCharacter;<br>- Classic, Rthro and Rthro Slender mannequins, each also with cages;<br>- Blender templates `Rig_and_Attachments_Template`, `Body_Cage_Template` and `Combined-Template`;<br>- 12 head templates.<br>No licence is stated. creator-docs licenses only its prose (CC-BY-4.0) and code samples (MIT) | R16, R17, G1 |
| Adaptive Animation: a character with `HumanoidRigDescription` and `DigitsRigDescription`, with at least 15 joints mapped to the standard skeleton, plays any R15 animation. Studio tries to fill in the mapping automatically; it can be fixed by hand in the Avatar tab. The page names no script API | R29 |

What a factory template needs to be avatar-compatible, compared with `bkit/templates.py` today:

| Requirement | Today | Needed |
|---|---|---|
| Bone tree | `R15_BONES`, rooted at `HumanoidRootPart` (matches the KeyframeSequence pose tree) | Two explicit profiles: `r15_pose` (today's tree, for Motor6D clip export) and `r15_avatar` (`Root > HumanoidRootNode > ...`) |
| Meshes | One joined `SK_Humanoid` | `r15_avatar`: 15 `<Part>_Geo` meshes, each skinned with no Root weights |
| Attachments | none | `_Att` objects at the positions in the spec. Whether Roblox's Blender template uses empties or meshes for them is UNVERIFIED; compare with `Rig_and_Attachments_Template` on the PC |
| Budgets and scale | category budget 8000 triangles | Per-part budgets as above; total size within the chosen body-scale range |
| Cages and FACS | none | Not generated. They come from Roblox template cages (licence UNVERIFIED, so not vendored) or from Avatar Setup in Studio |

## 5. Animation export (Blender to Roblox)

| Fact | Source |
|---|---|
| Blender animation export for Roblox: Apply Scalings FBX Unit Scale; Add Leaf Bones off; NLA Strips, All Actions and Force Start/End Keyframes off; Simplify 0.0; Custom Properties on; Path Mode Copy with Embed Textures | R20 |
| Emotes: under 10 s; "must reference a standard R15 rig"; the root may not move far or fast; "must be sourced from a CurveAnimation" | R21 |
| Animation Editor: priorities Action4 > Action3 > Action2 > Action > Movement > Idle > Core. For a smooth loop, duplicate the first keyframes as the last. Clips save to ServerStorage; "Publish to Roblox" is a separate action | R22 |
| The Curve Editor converts quaternions to Euler tracks, and "it's impossible to convert them back" | R23 |
| Replaceable default character animations: run, walk, jump, idle (two weighted variants), fall, swim, swimidle, climb. A non-humanoid rig plays through an AnimationController with a child Animator. Markers fire `GetMarkerReachedSignal` | R24 |
| `AnimationClipProvider`: `RegisterAnimationClip` and `RegisterActiveAnimationClip` give temporary ids for "localized testing" in Studio; `GetAnimationClipAsync` loads one. The page describes it as replacing KeyframeSequenceProvider. The KeyframeSequenceProvider page itself marks only two of its methods deprecated | R25, R26 |
| A KeyframeSequence's length is the time of its last Keyframe. Poses nest by joint hierarchy, and the root Pose is `HumanoidRootPart` | R27, R28 |
| Clip Editor import:<br>- FBX and glTF, several clips per file (2026-01-15);<br>- clips save locally to `ServerStorage/RBX_ANIMSAVES`; uploading is separate;<br>- since 2026-08-04: Rig Scale, rest-pose source (Imported Rig, or Imported Rig with Zeroed Rotations), Rig Type R15 or Custom, track selection, and auto-save of animations from imported 3D models | D5, D6 |

Design for `bkit/clips.py`. `ops.keyframe_clip` stays as the low-level primitive.
- **Clip names.** Names match `^[a-z][a-z0-9_]{0,47}$`. Neutral default names follow the documented replaceable set (idle, walk, run, jump, fall, climb, swim, swimidle), plus neutral slots `action`, `hit` and `death`. Choosing a game's move set stays out of scope.
- **Per-clip metadata.** `rbx_clip = {fps, frames, loop, priority, markers: [[name, frame, param]], in_place}`.
- **`export_clips(rig, meshes, out_dir, asset)`** writes:
  - one FBX per clip (`<Asset>_<clip>.fbx`), using the Roblox recipe above. This needs a change to `ops.export_fbx` for animated exports: `bake_anim_force_startend_keying=False`, `bake_anim_simplify_factor=0.0`, and `colors_type="SRGB"` stated explicitly;
  - one GLB with every clip (`<Asset>_clips.glb`, `export_animation_mode="ACTIONS"`) for the Clip Editor's multi-clip import;
  - `<Asset>_clips.json` with name, fps, frame range, duration, loop, priority and markers. Blender's FBX exporter does not carry timeline markers (UNVERIFIED), so markers travel in this file and are applied in Studio.
- **Clip QA:**
  - the name pattern;
  - at least 1 frame;
  - for a loop, the first and last poses match within a tolerance (R22);
  - a warning for keyed bone scale, because a Pose holds only a CFrame (an inference from R27, UNVERIFIED);
  - keyed bones must be a subset of the rig's deform bones;
  - for an in-place clip, root translation stays within a set bound (R21 gives no number);
  - emote-tagged clips must be under 10 s;
  - re-importing the GLB gives N actions with the expected names and ranges.
  Any code that walks F-curves must use the 5.x channelbag API (B6).
- **Keyframe reduction:** no custom reducer. FBX keeps every frame (Roblox's recipe sets Simplify to 0.0). The glTF exporter already removes redundant keys (`export_optimize_animation_size`). `gltf-transform resample` removes duplicate keyframes "losslessly" if the GLB size matters (T2).
- **Studio half (owner, part of B07):**
  1. Import the rig with Import 3D (uploads).
  2. Run Clip Editor import on `<Asset>_clips.glb` (saves locally).
  3. With `execute_luau`, register each saved clip with `RegisterAnimationClip`, then load it through `Animator:LoadAnimation`, and compare `AnimationTrack.Length` and the marker names with the sidecar. This works for both KeyframeSequence and CurveAnimation; which one the import produces is UNVERIFIED.

## 6. LOD and collision

- Do not build an LOD import path. Rescope `ops.lod_chain` in `docs/blender.md` and gap row B08 to budget previews and script-swapped variants: Roblox makes its own LODs (D7, R7).
- Add `ops.collision_proxy(obj, kind="hull"|"box", max_tris=256)`:
  - build a convex hull with `bmesh.ops.convex_hull` and decimate it if needed;
  - name it `<name>_Collision` and tag it `rbx_collision={"role": "proxy", "fidelity": "Hull"}`;
  - tag the visual mesh `{"role": "visual", "can_collide": false, "fidelity": "Box"}`.
- The expectation JSON carries these tags, because whether FBX custom properties become Roblox attributes is UNVERIFIED. A Studio-side helper sets `CanCollide`, `Transparency` and `CollisionFidelity` from them. This is a scene pattern built from documented properties, not an importer feature.
- ImportInspector's existing `collision_fidelity` check (no PreciseConvexDecomposition on props) stays.

## 7. Geometry Nodes and the Asset Browser

| Fact | Source |
|---|---|
| Distribute Points on Faces: Random or Poisson Disk, with a `Seed` input. It writes a stable `id` attribute, so "when the mesh is deformed or the density changes the values will be consistent for each remaining point" | B9 |
| Asset catalogs live in `blender_assets.cats.txt` at the library root: UTF-8, a `VERSION 1` line, then `{UUID}:{path}:{simple name}` lines. An asset stores its catalog's UUID, so a catalog can be renamed without editing any .blend | B7 |
| Objects, materials, collections, node groups, worlds, actions and poses, scenes and brushes can be assets; Mark as Asset generates a preview. A library is a folder registered in Preferences | B8 |

Design:
- **`bkit/gn.py`** builds node groups in Python, creating nodes by `bl_idname` and never looking them up by display name.
  - `gn_scatter(surface, piece, density, seed, min_distance, scale=(a, b))` chains Distribute Points on Faces (Poisson), Instance on Points, a seeded Random Value and Realize Instances, then applies the result.
  - `gn_array_on_curve(curve, piece, spacing)` makes rails, fences and pipes; `gn_stairs(steps, rise, run, width)` makes stairs.
  - The output passes through the usual QA and `apply_modifiers`.
  - Each generator gets a seeded geometry-hash case in `qa-selftest` on bpy 5.0.1, 5.1.2 and 5.2.2. Determinism across versions is UNVERIFIED until those cases pass.
  - The node groups are also saved as assets, so a person can adjust them in the Blender GUI. Placing things in the world stays with SceneKit and ProcGen in Luau.
- **`bkit/library.py` and `factory.py library <out_dir>`**:
  - save one `.blend` per template kind, with its Export objects, materials and GN groups marked through `ID.asset_mark()`;
  - set `asset_data.catalog_id` to `uuid5` of `rbx-factory/<category>`, and add tags (category, budget) and a description;
  - write `blender_assets.cats.txt` deterministically.
  - Whether preview generation works headless is UNVERIFIED. If it does not, leave the default previews or load the bkit renders.
  - The owner registers the folder under Preferences > File Paths > Asset Libraries (GUI, PC).

## 8. Candidate records

### 8.1 Facts

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Cycles bake + UV pack/smart project + colour attributes (Blender built-ins) | B1, B2, B3 | Blender Foundation | bpy 5.2.2 (also 5.1.2, 5.0.1) | 2026-09-15 | LTS | GPL-3.0 (bpy) | free |
| Geometry Nodes + Asset Browser catalogs | B7, B8, B9 | Blender Foundation | Blender 5.2 LTS | tracks Blender | active | GPL | free |
| FBX / glTF exporters | B4, B5 | Blender Foundation (core add-ons) | FBX 5.15.0; glTF 5.2.40 (`bl_info` on the 5.2 branch) | tracks Blender | active | GPL | free |
| Node Wrangler | B10 | Blender Foundation | bundled (listed among the documented core add-ons in the manual source) | tracks Blender | active | GPL | free |
| Rigify (re-assessed) | B10; extension 0.6.12 in [tooling-2026-10.md](tooling-2026-10.md) | Blender Foundation | bundled per the manual source; also on the Extensions Platform | 2024-06-07 (extension page) | active | GPL-2.0-or-later | free |
| 3D Importer (texture and vertex-colour paths) | R1, R2, D1, D3 | Roblox | ships with Studio | importer page 2026-03-31 | active | Roblox terms | free (each import uploads) |
| Animation Clip Editor import | D5, D6 | Roblox | ships with Studio | 2026-08-04 | active | Roblox terms | free |
| `AnimationClipProvider` | R25 | Roblox | engine | tracks engine | active | Roblox terms | free |
| Studio 3D Export (glTF) | R12 | Roblox | beta | page 2026-09-24 | beta | Roblox terms | free |
| Avatar Setup, Adaptive Animation, avatar specs and reference files | R13-R17, R29 | Roblox | Studio / docs | 2026-06-16 to 2026-10-02 (page dates) | active | Roblox terms; reference-file licence not stated | free (publishing has a fee) |
| glTF Transform CLI (`@gltf-transform/cli`) | T1, T2, T3 | Don McCurdy | 4.5.1 | 2026-09-28 (sibling `@gltf-transform/extensions` 4.5.1 on npm search; the CLI's own date not shown) | active; 2.0k stars | MIT | free |
| Khronos glTF validator (`gltf-validator`, used by `gltf-transform validate`) | T1 | emackey (npm publisher) | 2.0.0-dev.3.10 | 2024-10-22 | dev-tagged, slow | Apache-2.0 | free |
| Krita | T4 | Krita Foundation / KDE | 5.3.4 | 2026-09-15 | active | GPL-3.0 | free |
| Material Maker | T5 | RodZill4 | 1.6 per sidebar (2026-04-18); releases page also shows 1.7 "14 Jul" (year not shown) | 2026 | active; 5.6k stars | MIT | free |
| ImageMagick | T6 | ImageMagick Studio | 7.1.2-32 | not shown | active | ImageMagick License (Apache-2.0-derived) | free |
| Bool Tool | B12 | nickberckley | 2.1.0 | 2026-07-14 | active (community) | GPL-3.0-or-later | free |
| LoopTools (unchanged) | B13 | community | 4.7.7 | 2024-05-14 | "limited support" | GPL-2.0-or-later | free |
| TexTools | B14 | franMarz | not shown | not shown | active repo, 2.4k stars; not on the Extensions Platform | LICENSE.txt present, type not read (UNVERIFIED) | free |
| Auto-Rig Pro | B15 | Artell | 3.13.32 | not shown | active | GPL | USD 25 Lite / 50 Full |
| Moon Animator 2 | E1 | xsixx | listing tag "!V36000" | 2026-09-27 (economy endpoint `Updated`) | active | Creator Store terms | paid in USD; listing says "On sale for 33% off" (current price UNVERIFIED; USD 19.99 seen 2026-10-05 in `knowledge/records/tools-options.json`) |

### 8.2 Assessment

| Candidate | Purpose | Capabilities | Security | Overlap | Automation (Claude/Codex) | Expected benefit | Decision |
|---|---|---|---|---|---|---|---|
| Cycles bake + UV + colour attributes | colour and PBR transfer into Roblox-readable maps | the bake types in section 3; Selected to Active normals; image or colour-attribute targets; concave packing with margins | local only | none (B02 lists baking as MISSING) | headless `bpy` in the container and CI; MCP `execute_blender_code` on the PC | closes B06; textured assets with normals | **SELECT**: `bkit/bake.py` (palette atlas first, then vertex colours, then Cycles bake) |
| Geometry Nodes + Asset Browser | parametric prop generators and a kit library | seeded scatter with stable ids; catalogs as plain text | local only | bmesh ops already cover the geometry; GN adds parameters people can edit in the GUI | headless node-group construction; the catalog file is plain text | reusable, browsable kits for any genre | **SELECT**: `bkit/gn.py`, `bkit/library.py` (P2) |
| FBX / glTF exporter settings | Roblox-conformant export | the options in section 3.1 | none | `ops.export_fbx`/`export_glb` | headless | clips import as Roblox documents them; vertex colours ship | **SELECT**: change the animated FBX defaults; add a GLB vertex-colour option |
| Node Wrangler | faster manual material wiring | node shortcuts | none | none | GUI only | human convenience when editing baked materials | **SELECT** (built in; enable on the PC, no install) |
| Rigify | control rigs for hand animation | metarig to control rig with DEF bones | none | the R15 profiles, `ops.armature` | GUI mostly | none for the pipeline: DEF-bone naming is not R15, and the result would need baking and renaming | **REJECT** as a pipeline dependency (a person may still use it) |
| 3D Importer | the Studio half of B05, B06 and B07 | the settings in section 2; PBR creates a SurfaceAppearance; vertex colours are multiplied by Color | uploads mesh and images, so ask first | none | GUI only | the only documented import route | **SELECT** (as before; ask before each import) |
| Clip Editor import | bring clips in without uploading | multi-clip FBX/glTF; local save; rig type, scale and rest-pose options | local save; the upload is a separate step | the 3D Importer's animation import | GUI; saved clips are visible to `execute_luau` | B07 clip test with no animation upload | **SELECT** |
| `AnimationClipProvider` | play local clips in Studio | Studio-only temporary ids | none | KeyframeSequenceProvider | `execute_luau` | B07 length and marker check without publishing | **SELECT** (in an extended ImportInspector) |
| Studio 3D Export (glTF) | observe what Studio actually holds | glTF with textures, vertex colours, skins, cages and FACS; no animation | local file; beta | ImportInspector's EditableMesh colour reader | GUI export; the file is checked headlessly | B06/B07 evidence from a reproducible file | **SELECT**: new `factory.py compare-export` (owner exports, container checks) |
| Avatar Setup / Adaptive Animation / specs / reference files | avatar-compatible bodies and clip reuse | auto rig, skin, cages, FACS; R15 playback on custom rigs | Avatar Setup Save uploads or publishes; reference-file licence unknown | the R15 profiles | GUI only; the spec becomes data in `bkit/r15.py` | correct names, budgets and checks without guessing | **SELECT as reference**: encode the spec as data; never vendor the files; Avatar Setup only in a game repo |
| glTF Transform CLI | GLB validation and clip resampling | `inspect`, `validate`, `resample`, `palette`, `simplify`, `weld`, `resize` | npm supply chain; `sharp` brings a native libvips binary | Blender re-import probe; bpy image ops | `npx @gltf-transform/cli@4.5.1 validate <file>` from both agents | spec-level GLB errors that Blender's importer tolerates | **SELECT** (pinned, opt-in pre-release step; not a hard gate until a baseline exists) |
| glTF validator (standalone) | as above | as above | as above | `gltf-transform validate` already wraps it | CLI | none beyond the wrapper | **REJECT** standalone (use it through glTF Transform) |
| Krita | hand-painted texture touch-ups on baked maps | painting, layers, Python API | local app; official installer only | Blender Texture Paint | GUI only | stylised detail that flat palettes cannot give | **SELECT** (optional PC install; not a repo dependency) |
| Material Maker | procedural texture authoring | node graph, CLI export (1.5 or later) | local app (Godot) | Blender procedural shaders plus `bake_maps` | CLI exists | small | **REJECT** (REVISIT if Blender shaders prove insufficient) |
| ImageMagick | image conversion, resizing, channel packing | CLI | the vendor recommends "a security policy" before use | bpy image API (already pinned) | CLI | none beyond bpy | **REJECT** |
| Bool Tool | interactive boolean workflow | boolean operators, cutter management | none | `ops.boolean` plus the built-in modifier | GUI | human convenience only | **REJECT** (optional personal install) |
| TexTools | UV and bake helpers | bake modes, texel density, UV tools | GitHub zip install outside the Extensions Platform | `bkit/bake.py`, built-in UV ops | GUI | duplicated by the bake module | **REJECT** |
| Auto-Rig Pro | auto rigging and game-engine export | Unity, Unreal and Godot presets; no Roblox preset listed | purchase | R15 profiles, `bind_auto` | GUI | none for Roblox naming | **REJECT** (paid) |
| Moon Animator 2 | Studio animation workspace | third-party plugin | purchase; full access to the place. A third-party "Free Version" reupload exists, which is an unauthorised copy, so never install it | Animation Editor, Clip Editor, Blender | GUI only | unproven | **REJECT** (unchanged; paid) |

## 9. Implementation input (bkit and pipeline additions)

| # | Deliverable | Headless proof (container, bpy 5.0.1/5.1.2/5.2.2, Lune) | Studio part | Gap |
|---|---|---|---|---|
| 1 | `bkit/bake.py` `palette_atlas` and `vertex_colors_from_materials`; `template` builds bake a palette by default; `appearance` block in `roblox_expectation_v*.json` | Read back the PNG pixels: every cell equals its material's sRGB colour exactly, and the pixel hash is identical on all three versions (pixels, not file bytes). Re-imported FBX/GLB has one material, an image texture and the colour attribute. `qa-selftest` cases: a textured marker passes; a multi-material untextured asset fails `appearance_declared` | Owner imports a palette marker and a vertex-colour marker (uploads). ImportInspector must find a SurfaceAppearance or TextureID on the first, and the palette's vertex colours with white `Color` on the second; a capture shows the orange front | B06 |
| 2 | `ops.export_fbx` animated settings (Force Start/End off, Simplify 0.0, `colors_type` explicit); `export_glb(vertex_color=...)` | Re-import the animation_test FBX: one action whose key count equals the frame count + 1; vertex colours survive FBX and GLB | covered by row 5 | B01, B07 |
| 3 | QA checks `uv_single_set`, `uv_unit_square`, `texture_size`, `texture_colorspace`, `texture_suffix`, `appearance_declared` | known-bad self-test cases fail exactly these checks | none | B01 |
| 4 | `atlas_uvs` + `bake_maps` (Cycles CPU) | Bake a flat-coloured box: sampled pixels within 2/255 of the material colour. A flat low-poly normal bake is about (128,128,255) everywhere. High-to-low normal bake on a bevelled box versus its low-poly copy has non-flat pixels on the bevels. Packed islands do not overlap and keep a margin of at least `margin_px` | the textured import in row 1 | B02, B06 |
| 5 | `bkit/clips.py` (`export_clips`, sidecar, clip QA) and an ImportInspector `inspectClips(rig, expectation)` using `AnimationClipProvider:RegisterAnimationClip` | GLB re-import gives the expected action names and ranges; a loop-closure case and a scale-key case fail as designed; Lune spec for `inspectClips` against mocked tracks | Owner: Import 3D the rig, Clip Editor import of the GLB, then `execute_luau` compares track lengths and markers | B07 |
| 6 | `bkit/r15.py` (pose and avatar trees, part list, attachments, budgets, scale ranges) plus an `avatar_body` blockout template (15 `_Geo` parts, `_Att` objects, no cages) and a `rig_profile` QA | Template passes; mutations (rename a bone, weight Root, exceed the head budget, move `Root_Att`) each fail one check | Owner: Import 3D with Rig Type R15 and Validate UGC Body; Avatar Setup opens and reports | B07 (new avatar row) |
| 7 | `factory.py compare-export <studio.gltf> <expectation.json>` | Run on the factory's own GLB as a stand-in: passes; altered copies fail | Owner exports the imported model through 3D Export (beta) | B05, B06, B07 |
| 8 | `ops.collision_proxy`; collision tags in the expectation; rescoped `lod_chain` docs | Hull contains every visual vertex (signed distance at most 1e-4); triangles at most `max_tris` | Studio helper applies CanCollide, Transparency and CollisionFidelity; ImportInspector checks them | B08 |
| 9 | `bkit/gn.py` generators | seeded geometry hashes identical across the three versions | none | B02 |
| 10 | `bkit/library.py` + `factory.py library` | Reopen each `.blend`: the asset count and catalog UUIDs match `blender_assets.cats.txt`; the file's hash is stable | Owner registers the library folder | B02 |
| 11 | Robustness: find the Principled node by type in `ops.pbr_material` and `render.py`; drop the `use_nodes` assignment; channelbag API in any action walker | A self-test renames the Principled node to a non-English name and `pbr_material` still works | none | B01 |
| 12 | Skill and doc updates: `blender-asset-factory` (bake, clips, profiles), `blender-roblox-roundtrip` (two appearance markers, 3D Export check, clip test), `roblox-animation-integration` (Clip Editor and `AnimationClipProvider` route), `docs/blender.md` | `python3 tools/sync_skills.py` and the gate | none | B02, B06, B07 |
| 13 | Optional `gltf-transform validate` step in the pre-release tier | zero errors on all template GLBs (count a baseline first) | none | B01 |

Cages, layered clothing and FACS stay out of the factory until the owner obtains Roblox's template cages and their licence is confirmed. Rigid accessories (one mesh, one attachment, at most 4k triangles) can be a neutral template now.

## 10. UNVERIFIED (not selected on)

- Whether Import 3D maps a colour-only texture to `TextureID` or to a SurfaceAppearance ColorMap. D1 (2022) and D2 (2026, a user report) both describe SurfaceAppearance.
- Whether the importer splits glTF's packed metallic-roughness texture.
- Whether face-corner vertex colours keep hard borders after import (the docs specify the Vertex domain).
- How vertex colours combine with SurfaceAppearance: D3 (staff) and D4 (feature request) conflict.
- Whether 1024 is an engine cap for SurfaceAppearance maps or only a budget guideline (R4 calls it "(maximum)" in a guidance table).
- Whether palette cells bleed at Roblox mip levels.
- Cycles bake, `uv.pack_islands` and `uv.smart_project` running headless with the bpy wheel (expected: the wheel already renders with Cycles in B03). Rows 1 and 4 prove it.
- Whether Geometry Nodes output is identical across bpy 5.0.1, 5.1.2 and 5.2.2, and whether asset preview generation works headless.
- Whether the Clip Editor creates KeyframeSequence or CurveAnimation, and which root (`HumanoidRootPart` or `Root`/`HumanoidRootNode`) its R15 rig type accepts.
- Whether keyed bone scale is dropped (inferred from Pose holding only a CFrame), and whether Blender's FBX exporter writes timeline markers.
- Whether FBX custom properties become Roblox attributes.
- What `Use Imported Pivot` and `Set Pivot to Scene Origin` do to the pivot finding recorded in B05.
- How attachments are represented in Roblox's Blender rig template, and the licence of Roblox's reference and template files.
- Whether KeyframeSequenceProvider is deprecated as a class: R25 says AnimationClipProvider replaces it, while R26 marks only two of its methods.
- Moon Animator 2's current USD price, Material Maker's latest release (1.6 or 1.7), TexTools' licence type, and whether Node Wrangler and Rigify ship enabled in the 5.2 binaries (the manual source lists them as core add-ons).
- Whether gltf-transform `palette` applies to meshes that already have UVs: the docs say they are "not eligible".

## Summary

**Selected:**
- in the repo: Cycles bake, UV packing and colour attributes through `bkit/bake.py`; Geometry Nodes and Asset Browser catalogs (`bkit/gn.py`, `bkit/library.py`); corrected FBX/glTF exporter settings; the R15 pose and avatar profiles as data; clip export with a sidecar and clip QA; collision proxies; glTF Transform 4.5.1 as an optional validator;
- in Studio, with the owner: Import 3D (ask first), Clip Editor import, `AnimationClipProvider` temporary ids, and 3D Export to glTF for headless comparison;
- reference only: the avatar, head, accessory and emote specifications, Avatar Setup and Adaptive Animation;
- optional on the PC: Node Wrangler (built in) and Krita.

**Rejected:** Rigify as a pipeline rig; the standalone glTF validator; Material Maker; ImageMagick; Bool Tool; TexTools; Auto-Rig Pro; Moon Animator 2 and any reupload of it; a custom LOD import path, which Roblox does not support; gltf-transform `palette` as the B06 fix.

**Revisit (trigger):** cages, layered clothing and FACS once Roblox's template cages and their licence are confirmed; Material Maker if Blender shaders prove insufficient; making `gltf-transform validate` a hard gate once a zero-error baseline exists.

## Sources (all accessed 2026-10-06)

Roblox documentation:
- R1 https://create.roblox.com/docs/en-us/studio/importer.md
- R2 https://create.roblox.com/docs/en-us/art/modeling/3d-importer.md
- R3 https://create.roblox.com/docs/en-us/art/modeling/surface-appearance.md
- R4 https://create.roblox.com/docs/en-us/art/modeling/texture-specifications.md
- R5 https://create.roblox.com/docs/en-us/art/modeling/export-requirements.md
- R6 https://create.roblox.com/docs/en-us/art/blender.md
- R7 https://create.roblox.com/docs/en-us/parts/meshes.md
- R8 https://create.roblox.com/docs/en-us/reference/engine/enums/CollisionFidelity.md
- R9 https://create.roblox.com/docs/en-us/workspace/collisions.md
- R10 https://create.roblox.com/docs/en-us/art/modeling/specifications.md (20,000 triangles per mesh, at most 4 influences, cage suffixes)
- R11 https://create.roblox.com/docs/en-us/art/modeling/reimport.md
- R12 https://create.roblox.com/docs/en-us/art/modeling/gltf-export.md
- R13 https://create.roblox.com/docs/en-us/art/characters/specifications.md
- R14 https://create.roblox.com/docs/en-us/art/characters/head-specifications.md
- R15 https://create.roblox.com/docs/en-us/avatar-setup.md
- R16 https://create.roblox.com/docs/en-us/avatar/character-bodies/project-files.md
- R17 https://create.roblox.com/docs/en-us/art/characters/creating/template-files.md
- R18 https://create.roblox.com/docs/en-us/art/accessories/specifications.md
- R19 https://create.roblox.com/docs/en-us/art/accessories/clothing-specifications.md
- R20 https://create.roblox.com/docs/en-us/avatar/emotes/export.md
- R21 https://create.roblox.com/docs/en-us/avatar/emotes/specifications.md
- R22 https://create.roblox.com/docs/en-us/animation/editor.md
- R23 https://create.roblox.com/docs/en-us/animation/curve-editor.md
- R24 https://create.roblox.com/docs/en-us/animation/using.md
- R25 https://create.roblox.com/docs/en-us/reference/engine/classes/AnimationClipProvider.md
- R26 https://create.roblox.com/docs/en-us/reference/engine/classes/KeyframeSequenceProvider.md
- R27 https://create.roblox.com/docs/en-us/reference/engine/classes/Pose.md
- R28 https://create.roblox.com/docs/en-us/reference/engine/classes/KeyframeSequence.md
- R29 https://create.roblox.com/docs/en-us/characters/adaptive-animation.md
- R30 https://create.roblox.com/docs/llms.txt (page index)

DevForum (announcements, staff posts; feature requests and user reports are leads only):
- D1 https://devforum.roblox.com/t/pbr-support-for-the-unified-smart-mesh-importer-beta/1735648 (2022-03-28)
- D2 https://devforum.roblox.com/t/imported-avatar-into-studio-keeps-getting-surfaceappearance-added/4630035 (2026-05-11, user report)
- D3 https://devforum.roblox.com/t/vertex-colored-meshes-using-blender-and-studio/3050119 (2024-07-02, Roblox staff)
- D4 https://devforum.roblox.com/t/vertex-coloring-support-for-surfaceappearance/3981469 (2025-10-06, feature request)
- D5 https://devforum.roblox.com/t/full-release-animation-clip-editor-improved-importing-and-gltf-support/4260501 (2026-01-15)
- D6 https://devforum.roblox.com/t/animation-import-improvements/4775593 (2026-08-04)
- D7 https://devforum.roblox.com/t/introducing-mesh-streaming-and-improved-cloud-lods-in-published-experiences-opt-in-phase/4601232 (2026-04-27)
- D8 https://devforum.roblox.com/t/ability-to-define-custom-lods-for-models/3955951 (2025-09-24, feature request)

Roblox listings and repositories:
- E1 https://create.roblox.com/store/asset/4725618216/Moon-Animator-2 and the read-only endpoint `https://economy.roblox.com/v2/assets/<id>/details` (name, creator, `Updated`, description). The third-party "Free Version" reupload was read the same way; its id is not recorded here
- G1 https://github.com/Roblox/creator-docs (licence statement)

Blender:
- B1 https://projects.blender.org/blender/blender-manual/raw/branch/main/manual/render/cycles/baking.rst
- B2 https://projects.blender.org/blender/blender/raw/branch/blender-v5.2-release/source/blender/editors/object/object_bake_api.cc
- B3 https://projects.blender.org/blender/blender/raw/branch/blender-v5.2-release/source/blender/editors/uvedit/uvedit_unwrap_ops.cc
- B4 https://projects.blender.org/blender/blender/raw/branch/blender-v5.2-release/scripts/addons_core/io_scene_fbx/__init__.py
- B5 https://projects.blender.org/blender/blender/raw/branch/blender-v5.2-release/scripts/addons_core/io_scene_gltf2/__init__.py
- B6 https://projects.blender.org/blender/blender-developer-docs/raw/branch/main/docs/release_notes/5.0/python_api.md
- B7 https://projects.blender.org/blender/blender-manual/raw/branch/main/manual/files/asset_libraries/catalogs.rst
- B8 https://projects.blender.org/blender/blender-manual/raw/branch/main/manual/files/asset_libraries/introduction.rst
- B9 https://projects.blender.org/blender/blender-manual/raw/branch/main/manual/modeling/geometry_nodes/point/distribute_points_on_faces.rst
- B10 https://projects.blender.org/blender/blender-manual/raw/branch/main/manual/addons/index.rst
- B11 https://pypi.org/project/bpy/
- B12 https://extensions.blender.org/add-ons/bool-tool/
- B13 https://extensions.blender.org/add-ons/looptools/
- B14 https://github.com/franMarz/TexTools-Blender and https://github.com/franMarz/TexTools-Blender/issues/219
- B15 https://superhivemarket.com/products/auto-rig-pro

Tools:
- T1 https://registry.npmjs.org/@gltf-transform/cli/latest and https://registry.npmjs.org/-/v1/search?text=gltf-validator&size=3
- T2 https://gltf-transform.dev/cli , https://gltf-transform.dev/modules/functions/functions/palette and https://gltf-transform.dev/modules/functions/functions/resample
- T3 https://github.com/donmccurdy/glTF-Transform
- T4 https://krita.org/en/download/
- T5 https://github.com/RodZill4/material-maker and https://github.com/RodZill4/material-maker/releases
- T6 https://imagemagick.org/download/ and https://imagemagick.org/license/
