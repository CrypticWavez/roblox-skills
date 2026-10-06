# Visual quality, lighting, materials, VFX, audio and free asset sources: research (verified 2026-10-06)

This pass extends earlier research instead of redoing it:
- [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md), section C. Native ParticleEmitter/Beam/Trail are SELECT, vfx-editor is REVISIT and Lumina is REJECT. Those decisions stand. This pass adds engine limits, a preset format and budgets.
- [ui-cinematics-feel-2026-10.md](ui-cinematics-feel-2026-10.md), section 3e and its `Feel` design. It covers the post-processing class list, the ColorGradingEffect parenting conflict and transient screen pulses. This pass covers persistent grading, the environment, materials and audio.
- [genre-coverage-2026-10.md](genre-coverage-2026-10.md), sections 4 and 5. That pass found that Sound/SoundGroup are discouraged and that `NativeAudio` is OUTDATED. This pass designs the replacement.
- `knowledge/records/tools-options.json`. Krita and Audacity were researched there and not selected. They are not re-researched here.

Nothing here picks a genre, theme, world, characters or economy. Lighting presets are named after physical conditions (time of day, weather, interior, inspection), and VFX recipes after gameplay event types (impact, pickup, telegraph). Every genre needs these.

**Method.**
- All sources were fetched on 2026-10-06. The list is in section 9.
- Roblox docs were read as `.md` variants (`https://create.roblox.com/docs/en-us/<path>.md`). Property security levels and descriptions come from the creator-docs YAML (`https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/<classes|enums>/<Name>.yaml`) where the page summary left them out.
- Dates come from DevForum announcements, and licence terms from each asset source's own licence or terms page.
- To see the response fields, I read one Poly Haven API metadata response (`/files/<asset>`), one ambientCG `full_json` query and the `mcp-for-blender` add-on source. No asset file was downloaded.
- Pages were read through a summarising fetcher, so short quotes are given where the wording matters.
- Nothing was installed, bought, signed up for or downloaded.
- No Roblox asset ids appear in this file, because the `asset-provenance` gate scans it.

**Decision rule** (same as the addendum):
- **SELECT**: use in the factory now, as a built-in API, in-repo code, a documented source or a documented PC install.
- **REJECT**: do not adopt.
- **REVISIT**: the facts are recorded, but the decision waits for the stated trigger.

---

## 1. Decisions in brief

1. **Lighting targets Unified Lighting.**
   - `LightingStyle` (Realistic or Soft) and `PrioritizeLightingQuality` replaced `Technology` (fully live 2025-01-21).
   - Their write security is `RobloxScriptSecurity`, so no script, plugin or `execute_luau` call can set them.
   - Presets therefore *declare* the values they expect, and `inspect` checks them. They are set in Studio's Properties panel, or possibly through the Rojo project file (UNVERIFIED).
2. **Environment presets are data** in `packages/SceneKit/Lighting.luau`.
   - Each preset owns Lighting properties, Atmosphere, Sky (no textures), Clouds, `Workspace.GlobalWind` and persistent post-processing: Bloom, ColorCorrection, a single ColorGrading and SunRays.
   - New functions: `validate` (documented ranges) and `blend` (transitions).
   - DepthOfField and Blur stay transient and belong to `Feel`/`Cinematics`.
3. **Materials come in two tiers.**
   - **Tier 0 (now, zero uploads):** the built-in 2022 materials with colour roles (`Style.luau`), plus `MaterialService:SetBaseMaterialOverride`, which any script may call.
   - **Tier 1 (a game repository, uploads ask first):** MaterialVariant and SurfaceAppearance built from a `material-library/1` manifest of CC0 textures. The textures are validated offline and previewed in Blender first.
4. **VFX is a data format.** A `vfx/1` preset uses only native instances and built-in textures. It is validated against the documented limits, and the existing `EffectsPool` pools it.
5. **Audio moves to the Audio API.**
   - An `AudioGraph` backend replaces `NativeAudio` (SoundGroup); AudioMixer and AudioDirector stay unchanged.
   - Faders form the buses, an `AudioCompressor` sidechain does ducking, and `AudioAnalyzer` checks signal level (PeakLevel/RmsLevel) to show sound actually reaches the bus, with no human listening.
6. **Asset sources.**
   - CC0 first: ambientCG; Poly Haven, downloaded from the **website** (its API forbids commercial use); Kenney; Quaternius.
   - Sonniss GDC bundles serve as a professional SFX library on the owner's PC only.
   - Creator Store models and Roblox-licensed music (APM) are used only through `roblox-asset-intake` in a game repository.
   - Rejected as pipeline sources: the Poly Haven API, the Freesound API, Sketchfab, Poly Pizza, OpenGameArt by default, Mixamo and custom fonts.
7. **Provenance for external files.**
   - A new `assets/sources.json` holds sha256 pins, licences and redistribution flags.
   - A stdlib-only fetch script downloads into a gitignored cache, and only when run on purpose.
   - An offline gate step checks the manifest.
   - **No binary assets go into this public repo.**
8. **Budgets.** Documented engine numbers become validator constants. Every other number is a labelled factory convention, to be calibrated on a 2-4 GB Android device.
9. **Stale code fact.** `packages/SceneKit/Validate.luau` line 372 caps light `Range` at 60 and calls it the "engine cap". The cap has been 120 studs since 2025-09-23.
10. **PC installs for this topic: none required.** A Sonniss library is optional, owner-side, and kept outside every repository. FFmpeg (already selected) gains audio intake checks.

## 2. What the repo has today (judged 2026-10-06)

| File | Reusable | Problems found | Verdict |
|---|---|---|---|
| [packages/SceneKit/Lighting.luau](../../packages/SceneKit/Lighting.luau) | Five profiles as plain data (neutral-day, overcast, golden-hour, night, inspection-flat); `apply` writes Lighting properties and one Atmosphere; `inspect`; a Lune spec (`tests/scenekit.spec.luau`, "lighting profiles apply and inspect") | No post-processing, Sky, Clouds, GlobalWind, `ShadowSoftness`, `GeographicLatitude`, `ColorShift_*`, Atmosphere `Color`/`Decay`. No check of `LightingStyle`/`PrioritizeLightingQuality`. No range validation and no blend between profiles. `apply` adopts any existing Atmosphere and does not mark ownership | **Extend** to schema 2 (section 6.1). Keep the five ids so existing captures stay comparable |
| [packages/SceneKit/Style.luau](../../packages/SceneKit/Style.luau) | Role to `Enum.Material` name plus RGB, in three neutral profiles | No MaterialVariant names, no SurfaceAppearance, no base-material overrides | **Extend** with optional `variant` per role (tier 1) |
| `packages/SceneKit/Validate.luau` line 372 | `light_placement` check | `MAX_LIGHT_RANGE = 60 -- engine cap`. The engine cap is 120 (section 3a). Building lights clamp to 12-60 (`Building.luau`), which is fine as a budget but is not the cap | **Fix**: separate the engine cap (120) from a budget default |
| [packages/Runtime/NativeEffects.luau](../../packages/Runtime/NativeEffects.luau) | Lifetime-bounded diagnostic marker (a translucent ball) with priority-based reduction | Diagnostic only; not a VFX library | **Keep** as a diagnostic |
| `packages/Creator/Effects.luau` + `EffectsPool.luau` | Pooled Beam/Trail/ParticleEmitter with three recipes, reduced effects, capacity and no asset ids. Built-in textures `rbxasset://textures/particles/sparkles_main.dds` and `SquareParticle.png` | Recipes are code, not data. Colours are hard-coded. No flipbooks, lights, Highlight or limit validation | **Reuse** as the pool and backend for `vfx/1` presets |
| [packages/Runtime/AudioMixer.luau](../../packages/Runtime/AudioMixer.luau) | Pure gains 0..1, fades up to 60 s, up to 32 ducks, master | Header says "Backend applies gains to SoundGroups" | **Keep**; fix the comment when the backend changes |
| [packages/Creator/AudioDirector.luau](../../packages/Creator/AudioDirector.luau) | Event and music-state routing, explicit backend contract (`play`, `stop`), bounded trace, `missing_asset` for unconfigured events; `inspect` reports `hearing = "NOT_VERIFIED"` | none for routing | **Keep**; the new backend fits its contract |
| `packages/Runtime/NativeAudio.luau` | Channel-to-group volume stepping, `inspect` | Creates `SoundGroup`s, which the docs now discourage | **Replace** with `AudioGraph` (section 6.4) |
| [assets/provenance.json](../../assets/provenance.json) | Registry and gate for Roblox asset ids | Nothing records external files (no sha256, licence URL or redistribution flag) | **Add** `assets/sources.json` alongside it (section 6.5) |
| `tools/blender/bkit/ops.py` `pbr_material` | Constant Principled values (colour, roughness, metallic, emission) | No image-texture maps; previews use no HDRI (gap-matrix B03: "not Studio lighting"); colour is lost on import (B06) | **Extend** with the texture validator and material preview (section 6.2) |

## 3. Engine facts (Roblox: built into the engine and Studio; free; Roblox terms; tracks Studio)

Facts common to every built-in in this section:

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Unified Lighting and the Lighting service | docs `environment/lighting`, `reference/engine/classes/Lighting` | Roblox | engine | Fully live 2025-01-21; local light range raised to 120 on 2025-09-23 | active | Roblox terms | free |
| Atmosphere, Sky, Clouds, GlobalWind | docs `environment/atmosphere`, `/skybox`, `/clouds`, `/global-wind` | Roblox | engine | unknown | active | Roblox terms | free |
| Post-processing | docs `environment/post-processing-effects` plus class pages | Roblox | engine | unknown | active (Compatibility technology deprecated in favour of ColorGrading Retro) | Roblox terms | free |
| MaterialService, MaterialVariant, TerrainDetail | docs `parts/materials` plus class pages | Roblox | engine | unknown | active | Roblox terms | free |
| SurfaceAppearance and texture specs | docs `art/modeling/surface-appearance`, `/texture-specifications` | Roblox | engine | 4K texture rendering live 2026-01-30 | active | Roblox terms | free |
| ParticleEmitter, Beam, Trail, Highlight, local lights | docs `effects/*` | Roblox | engine | unknown | active | Roblox terms | free |
| Audio API | docs `audio/objects`, `audio/effects` plus class pages | Roblox | engine | Out of Studio beta 2024-09-10. Acoustic Simulation thread dated 2026-01-28 and out of beta by 2026-09-22 | active (Sound, SoundGroup and SoundEffect are "discouraged") | Roblox terms | free |

### 3a. Lighting

| Feature | Fact | Source |
|---|---|---|
| Unified Lighting | It "replaces the existing *Technology* property ... with two new properties: *LightingStyle* and *PrioritizeLightingQuality*". Mapping: Future = Realistic + priority on; ShadowMap = Soft + priority on; Voxel = Soft + priority off. "Neither of these properties are scriptable" | DevForum 2025-01-21 |
| LightingStyle | `Realistic` (0): "The most advanced and realistic lighting and shadows Roblox can deliver." `Soft` (1): "A flat, retro-Roblox look with softer lights and shadows." | docs `enums/LightingStyle` |
| PrioritizeLightingQuality | `true` "prioritizes features such as advanced shadows and high-quality shaders at closer distances, while a setting of false prioritizes view distance" | docs `classes/Lighting` |
| Security | YAML: `LightingStyle` and `PrioritizeLightingQuality` are read None, write **RobloxScriptSecurity**. `Technology` is RobloxScriptSecurity for both read and write, and deprecated. So plugin-level `execute_luau` can read the new properties but not write them | creator-docs `Lighting.yaml` |
| Technology enum | Legacy, Voxel ("4×4×4 voxel map"), Compatibility ("now deprecated"; use "Voxel lighting with a ColorGradingEffect set to Retro preset"), ShadowMap, Future, Unified (5, undocumented) | docs `enums/Technology` |
| Scriptable properties | `Ambient` (default black), `OutdoorAmbient` (default 127 grey; clamped to at least `Ambient` per channel), `Brightness`, `ClockTime`, `GeographicLatitude`, `GlobalShadows`, `ShadowSoftness` (default 0.2), `EnvironmentDiffuseScale` and `EnvironmentSpecularScale` (default 0; "especially important to make metal look more realistic"; lower Ambient when raising diffuse), `ExposureCompensation` (-5 to 5), `ColorShift_Top`/`ColorShift_Bottom`. `Outlines` and `ShadowColor` are deprecated | docs `classes/Lighting`, `Lighting.yaml` |
| ShadowSoftness conflict | The class page says it works only with ShadowMap or Future "and the device is capable of rendering shadow maps". The guide says it is "only valid when LightingStyle is set to Realistic". Recorded as UNVERIFIED | both pages |
| Local light range | "Light range limits are now set to 120 studs maximum (previously 60)" for PointLight, SpotLight and SurfaceLight. "Fewer lights mean better performance". Improved attenuation was promised "in the next couple of months"; no later release was found. `ExtendLightRangeTo120` is NotScriptable and unused: "light range always clamped to 120" | DevForum 2025-09-23; `Lighting.yaml` |
| Light properties | `Brightness` (default 1), `Color`, `Enabled`, `Shadows`. SpotLight `Angle` up to 180; SurfaceLight 0 to 180 with `Face` | docs `classes/Light`, `effects/light-sources` |

### 3b. Atmosphere, Sky, Clouds, wind

| Feature | Fact | Source |
|---|---|---|
| Atmosphere | Lives in Lighting. `Density` sets how much the air obscures objects; it "does not directly affect the skybox". `Offset` gives a horizon silhouette (high) or blends distant objects into the sky (low); balance it against Density. `Haze` affects both above and below the horizon. `Color` is "best combined with increased Haze". `Glare` needs Haze > 0. `Decay` needs Haze and Glare > 0. No numeric ranges are published | docs `environment/atmosphere`; `Atmosphere.yaml` |
| Sky | Six `Skybox*` faces, `CelestialBodiesShown`, `SunTextureId`/`MoonTextureId`, `SunAngularSize`/`MoonAngularSize` (0 hides a body), `StarCount`, `SkyboxOrientation` ("a low-cost feature which works seamlessly across all platforms"). No recommended face resolution is given | docs `environment/skybox` |
| Clouds | Must be parented under `Terrain` to render. `Cover` 0-1, `Density` 0-1, `Color`. They drift with global wind, and Lighting/Atmosphere tint them. No texture is needed | docs `environment/clouds` |
| GlobalWind | `Workspace.GlobalWind` moves terrain grass, dynamic clouds, and particles that have `WindAffectsDrag` on and `Drag` > 0. Grass animation slows under reduced motion | docs `environment/global-wind` |

### 3c. Post-processing (persistent use; transient pulses are in the ui-cinematics doc)

| Effect | Fact | Source |
|---|---|---|
| Parenting | Under Lighting, an effect applies to everyone; under the Camera, it applies to one player. Some effects need a higher Studio Editor Quality Level to show | docs `environment/post-processing-effects` |
| BloomEffect | `Intensity`; `Size` (radius in pixels; 0 disables the bleed); `Threshold` (1 means "only pure white colors will bloom", 0 means all) | `BloomEffect.yaml` |
| ColorCorrectionEffect | `Brightness`, `Contrast`, `Saturation`, `TintColor` ("by how much the RGB channels of pixels are scaled"). Ranges are not published | `ColorCorrectionEffect.yaml` |
| ColorGradingEffect | "expected to be parented to Lighting and will be ignored if parented elsewhere"; "only the most recently parented instance to Lighting will be applied". `TonemapperPreset`: Default ("post-2019 ... vivid colors and high contrasts") or Retro ("imitate the pre-2019 Roblox appearance") | docs `classes/ColorGradingEffect`; `TonemapperPreset.yaml` |
| SunRaysEffect | `Intensity` (opacity, 0 to 1); `Spread` "should be set between 0 and 1 as values outside that range have undefined behavior". Shaped by objects between the camera and the sun | `SunRaysEffect.yaml` |
| DepthOfFieldEffect | `FocusDistance` and `InFocusRadius` (studs), `NearIntensity`, `FarIntensity`. No ranges or device notes | `DepthOfFieldEffect.yaml` |
| Device cost | No documented per-effect cost or mobile behaviour was found (UNVERIFIED) | (absence) |

### 3d. Materials

| Feature | Fact | Source |
|---|---|---|
| Built-in materials | About 50 base materials across the 2022 and pre-2022 sets. `MaterialService.Use2022Materials` is RobloxScriptSecurity | docs `parts/materials`, `classes/MaterialService` |
| MaterialVariant | `BaseMaterial` (read-only), `ColorMap`, `NormalMap`, `RoughnessMap`, `MetalnessMap`, `EmissiveMaskContent` and the `*Content` forms are read-only to scripts, with **PluginSecurity** write. `EmissiveStrength`, `EmissiveTint`, `MaterialPattern`, `StudsPerTile`, `AlphaMode` and `CustomPhysicalProperties` are ReadWrite. The colour map's alpha "is not used" (except per AlphaMode). Normal maps are "tangent space ... OpenGL format, not DirectX"; "Roblox expects imported meshes to include tangents" | docs `classes/MaterialVariant` |
| Overrides | Parts name a variant through `Part.MaterialVariant` (a string). `MaterialService:SetBaseMaterialOverride(material, name)`, `GetBaseMaterialOverride` and `GetMaterialVariant` have security **None**, so runtime scripts can switch a base material globally. The per-material `*Name` properties are RobloxEngineSecurity | docs `classes/MaterialService` |
| Terrain | Custom materials apply to terrain only as base-material overrides. `TerrainDetail` customises the top, side and bottom faces. "the materials for terrain are global per place, so you can't apply multiple variants of the same base material to the terrain in a single place" | docs `parts/materials` |
| Generators | Material Generator: "type any phrase", then "Save & Apply Variant" to the Material Manager; where the textures are stored is not stated. Texture Generator saves textures to the account's **Images** inventory ("Show in Inventory"). The Studio MCP `generate_material` "Generates a custom material variant" | docs `studio/material-generator`, `studio/texture-generator`, `studio/mcp` |

### 3e. SurfaceAppearance and textures

| Feature | Fact | Source |
|---|---|---|
| SurfaceAppearance | Overrides a MeshPart's look with PBR maps. "most SurfaceAppearance properties cannot be modified by scripts, as the necessary pre-processing is usually too expensive during runtime". Maps: Color/ColorMapContent (alpha meaning set by AlphaMode), Normal (OpenGL tangent space), Roughness, Metalness, EmissiveMaskContent with `EmissiveStrength`/`EmissiveTint`; `Color` tint; `ResampleMode` (Default or Pixelated) | `SurfaceAppearance.yaml`; docs `art/modeling/surface-appearance` |
| AlphaMode | Overlay (0: map over the part colour), Transparency (1: alpha is transparency; use `MeshPart.Transparency` 0 for hard edges or at least 0.02 for smooth gradients), TintMask (2: alpha controls how much `Color` tints), Opaque (3: ignores alpha; the guide marks it beta) | docs `enums/AlphaMode`, `art/modeling/surface-appearance` |
| Map formats | Albedo RGB 24-bit; Normal RGB 24-bit, "OpenGL format - Tangent Space" only; Roughness, Metalness and Emissive single-channel 8-bit. Uploads: .png, .jpg, .tga, .bmp. "Roblox may downsample textures". One UV set per component | docs `art/modeling/texture-specifications` |
| Resolution | The page states both "up to 4096×4096 pixel texture resolutions (4K)" and "up to 1024×1024 pixel spaces for texture maps" (conflict noted). Guidance: 256 for 5×5-stud objects, 512 for 10×10, 1024 for 20×20; PBR "256×256 for every 2×2×2 unit space" | same |
| 4K rendering | Live 2026-01-30 for "MeshPart (Skinned and Unskinned meshes), SurfaceAppearance, Texture, Decal and MaterialVariant". Images import "at up to 8k" and are "transcoded down to 4k". "If a device cannot handle or doesn't need the full 4k texture, Texture Streaming will automatically serve a lower-resolution version". ImageLabel is not listed | DevForum 2026-01-30 |
| Memory | Graphics memory depends on pixel dimensions ("1024x1024 texture consumes 4x memory of 512x512"); pre-compression gives no benefit. Large on-screen images: 512 maximum; minor images: under 256. Use one texture plus `SurfaceAppearance.Color` for colour variations; avoid re-uploading the same image under new ids, which defeats de-duplication | docs `performance-optimization/improve` |

### 3f. VFX limits (adds to addendum section C)

| Feature | Fact | Source |
|---|---|---|
| ParticleEmitter rate | "A single particle emitter can create up to 400 particles per second (100 per second on mobile)" | docs `effects/particle-emitters` |
| Lifetime | "maximum lifetime of 20 seconds"; a lifetime of 0 emits nothing | same; `ParticleEmitter.yaml` |
| Flipbooks | Layouts None, Grid2x2, Grid4x4, Grid8x8, Custom (`FlipbookSizeX/Y`); modes Loop, OneShot, PingPong, Random; `FlipbookFramerate` up to 30 fps; `FlipbookStartRandom`. "The flipbook texture size must be an exact multiple of the flipbook layout size"; leave spacing between frames for mip filtering. Clients low on memory "automatically deactivate flipbooks ... likely for older mobile phones" | same |
| Other emitter properties | `Squash`, `ZOffset`, `LightEmission` (0 normal, 1 additive), `LightInfluence`, `Brightness` (when LightInfluence is 0), `Orientation` (FacingCamera, FacingCameraWorldUp, VelocityParallel, VelocityPerpendicular), `Shape` with `ShapeStyle`/`ShapeInOut`, `Drag`, `VelocityInheritance`, `LockedToPart`, `TimeScale`, `WindAffectsDrag`. Sphere and Cylinder shapes "display incorrectly" under an Attachment | same |
| Cost | Fill rate ("The more pixels particles occupy ... the more costly"); overdraw from overlapping transparent particles; "Property changes to ParticleEmitters can have dramatic impact on performance" | same; docs `performance-optimization/improve` |
| Beam | Two Attachments; `Segments`; `CurveSize0/1` (Bezier); `TextureMode` Wrap, Static, Stretch; `TextureSpeed` (cycles per second); `LightEmission` 0-1; `LightInfluence` clamped 0-1; `Brightness` 0-10000 (default 1); `ZOffset`; `FaceCamera`. Look varies with the graphics quality level | `Beam.yaml`; docs `effects/beams` |
| Trail | Two Attachments; `Lifetime`, `TextureMode`, `TextureLength`, `FaceCamera`, colour and transparency sequences. No cost notes | docs `effects/trails` |
| Highlight | `DepthMode` AlwaysOnTop or Occluded; fill and outline colour and transparency. "255 simultaneous Highlight instances on the client-side". The first highlight costs about 1 ms on mobile; more add little; mobile cost grows with screen coverage; disabled highlights cost nothing; adding or removing rebuilds geometry; do not nest highlighted objects | docs `effects/highlighting` |

### 3g. Audio

| Feature | Fact | Source |
|---|---|---|
| Status | "Sound, SoundGroup, and SoundEffect objects are now discouraged in favor of the more robust functionality of audio objects." The Audio API left Studio beta on 2024-09-10 | docs `audio/objects`; DevForum 2024-09-10 |
| Objects | Producers: `AudioPlayer`, `AudioTextToSpeech`. Consumers: `AudioEmitter`, `AudioDeviceOutput`. `AudioListener` (a virtual microphone). `AudioDeviceInput` (voice). `Wire` carriers. Modifiers: `AudioFader`, `AudioEqualizer`, `AudioCompressor`, `AudioReverb`, `AudioChorus`, `AudioDistortion`, `AudioEcho`, `AudioFlanger`, `AudioPitchShifter`, `AudioTremolo` and `AudioAnalyzer` (plus `AudioLimiter`, named in a 2024 DevForum title) | docs `audio/objects`, `audio/effects` |
| Routing | 2D: AudioPlayer, Wire, AudioDeviceOutput. 3D: AudioPlayer, Wire, AudioEmitter (parented to an Attachment, Camera or PVInstance, otherwise "effectively silent"), AudioListener, Wire, AudioDeviceOutput. `AudioDeviceOutput.Player` nil means everyone hears it; set means only that player | docs `audio/objects`, `classes/AudioEmitter`, `classes/AudioDeviceOutput` |
| Wire | `SourceInstance`/`SourceName` (default "Output"), `TargetInstance`/`TargetName` (default "Input"). `Connected` is true only when everything is assigned, the pins exist and "the connection does not result in a cyclic processing graph" | docs `classes/Wire` |
| AudioPlayer | `Asset`, `AutoLoad`, `IsReady` ("may become false under extreme memory pressure"), `Looping`, `LoopRegion`, `PlaybackRegion`, `PlaybackSpeed` 0-20, `Volume` 0-10, `TimeLength`, `TimePosition`. `Play(atTime)`/`Stop(atTime)` give sample-accurate scheduling against `SoundService:GetMixerTime()` and return action ids for `Cancel`. `GetWaveformAsync`. Events `Ended`, `Looped`. `AssetId` is deprecated | docs `classes/AudioPlayer`, `classes/SoundService` |
| AudioEmitter | `AudioInteractionGroup`; `DistanceAttenuationMode` (default Custom); `SetDistanceAttenuation` takes up to 400 distance-to-volume pairs; `SetAngleAttenuation` (0-180°). Defaults: inverse-square distance falloff and constant angle volume. `AcousticSimulationEnabled` per emitter | docs `classes/AudioEmitter` |
| Mixing | `AudioFader.Volume` 0-3, plus `Bypass`. `AudioCompressor`: Attack 0.0001-0.5 s, Release 0.01-5 s, Threshold -60 to 0 dB, Ratio 1-50, MakeupGain -30 to 30 dB. Wires into its **Sidechain** pin drive the threshold, which "can be used to duck the volume of one stream in response to another". "the order of the audio effects impacts the custom sound" | docs `classes/AudioFader`, `classes/AudioCompressor`, `audio/effects` |
| AudioAnalyzer | `PeakLevel`, `RmsLevel`, `GetSpectrum()` (0-24 kHz; turn `SpectrumEnabled` off to save CPU). It "does not produce any output streams", so it can measure a stream silently | docs `classes/AudioAnalyzer` |
| SoundService | `DefaultListenerLocation` (ReadOnly to scripts) places an AudioListener "automatically wired to an AudioDeviceOutput". `AcousticSimulationEnabled` (global). `CharacterSoundsUseNewApi` (RolloutState). `AmbientReverb`, `DistanceFactor`, `DopplerScale`, `RolloffScale` and `VolumetricAudio` affect only legacy Sounds | docs `classes/SoundService` |
| Acoustic simulation | Occlusion, diffraction and reverb for AudioEmitter/AudioListener ("requires using the Advanced Audio API"). It "may lower accuracy or turn themselves off if necessary to maintain frame rate". Out of beta by 2026-09-22 | DevForum thread 4307121 |
| Uploads | .mp3, .ogg, .wav, .flac; "less than 20 MB in size and 7 minutes in duration"; sample rate up to 48 kHz; mono, stereo, 3.0 or 5.1. 100 free uploads per 30 days (2,000 if ID-verified). Audio starts private, and permissions are granted per experience or user. Moderation and copyright checks apply | docs `audio/assets` |
| Licensed library | The Creator Store has "more than 100,000 professionally-produced sound effects and music tracks". Roblox licensed APM Music; licensed music may appear in experiences and in gameplay videos but "may only be synchronized with the Roblox game content", with no use outside Roblox | docs `audio/assets`; Roblox Help "Using Licensed Music in Videos" |
| Upload licence | The uploader must own or have licensed all rights "including public performance licenses"; Roblox receives a perpetual licence to transmit, reproduce and create derivatives on the platform | Roblox Help "Audio Upload License Agreement" |
| Memory | "Audio files can be surprising contributor to memory usage, particularly if loaded all at once" | docs `performance-optimization/improve` |

### 3h. Performance budgets

Documented numbers:
- "stay below 1,000 draw calls and 1,000,000 triangles for the game to run well on your baseline device"; 16.67 ms per frame at 60 FPS (docs `performance-optimization/design`).
- Shadow quality degrades with graphics quality, and shadows are disabled below level 4. Guidance: switch off `CastShadow` on small or moving parts and `Light.Shadows` where not needed; "Limit the range and angle of light instances"; "Use fewer light instances" (docs `performance-optimization/improve`).
- About 60% of Android players have 2-4 GB of RAM, about 35% have 4-8 GB and about 5% more than 8 GB. Over half of all players use devices scoring 10,000-20,000 on Passmark. The device emulator "isn't accurate for memory usage" (docs `performance-optimization/test-on-hardware`).
- Distant LOD: `Model.LevelOfDetail` SLIM with instance streaming; `RenderFidelity` Automatic or Performance; identical meshes and textures share a draw call through instancing (docs `performance-optimization/improve`).

Per-feature budget table. "Doc" marks a documented limit; "Conv." marks a factory convention that is a starting point to calibrate on a 2-4 GB Android device with MicroProfiler:

| Feature | Doc limit | Conv. default for validators | Mobile fallback to design for |
|---|---|---|---|
| Local lights | Range ≤ 120 | ≤ 4 lights and ≤ 1 shadow-casting light per room-sized volume; `Shadows = false` unless the preset says why | no shadows below quality 4 |
| Global shadows | (degrades with quality) | `CastShadow = false` on parts under 1 stud, on effects and on moving dressing | lower-quality shadows or none |
| Post-processing | none published | at most one owned instance per class from presets; DOF and Blur only transient | assume any effect may cost or vanish (UNVERIFIED) |
| Particles | ≤ 400/s per emitter (100/s on mobile); lifetime ≤ 20 s; flipbook ≤ 30 fps | author for ≤ 100/s; ≤ 200 live particles per preset at peak; no gameplay meaning carried only by flipbook frames | flipbooks switch off on low memory |
| Transparency | overdraw warning | no more than 3 stacked transparent layers at a gameplay focus point (conv.) | overdraw cost |
| Highlight | 255 simultaneous; about 1 ms for the first on mobile | ≤ 8 active; keep fill transparency high on large objects | cost grows with screen coverage |
| Textures | 4K max (streamed); 256 per 2×2×2 studs; on-screen UI images ≤ 512 | 1024 cap for tiling MaterialVariants and props; 2048 only for hero assets with a written reason; 4K never by default | Texture Streaming serves lower mips |
| Audio | 20 MB / 7 min per file | `AutoLoad = false` for cues outside the current state; ≤ 32 voices across buses | `IsReady` can drop under memory pressure |
| Acoustic simulation | self-throttles | opt in only on emitters that matter for gameplay | may switch itself off |

## 4. Asset sources

### 4a. Facts

| Source | Official source (licence text) | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| ambientCG | https://docs.ambientcg.com/license/ ; API docs https://docs.ambientcg.com/api/ | a single operator ("operated ... by just one person"); name not recorded | API v1-v3 (v2 `full_json`) | catalogue live (date sort exists) | active; the API is "potentially not as reliable or stable as needed for an 'enterprise-level' application" | CC0 1.0 | free |
| Poly Haven (assets) | https://polyhaven.com/license | Poly Haven | n/a | unknown | active | CC0 for assets; the website, logos and renders are copyrighted | free |
| Poly Haven API | https://raw.githubusercontent.com/Poly-Haven/Public-API/master/ToS.md | Poly Haven | n/a (`api.polyhaven.com`) | unknown | active; repo AGPL-3.0 | ToS: "Use of the API for the purpose of commercial profit is strictly prohibited" | free for non-commercial use |
| Kenney | https://kenney.nl/support ; asset pages show "Creative Commons CC0" | Kenney | per pack | unknown | active (14 catalogue pages) | CC0 | free (optional donation) |
| Quaternius | https://quaternius.com/faq.html | Quaternius | per pack | unknown | active | CC0 ("All models are under the CC0 License") | free |
| OpenGameArt | https://opengameart.org/content/faq | OpenGameArt.org | n/a | unknown | active | per submission: CC0, CC-BY, CC-BY-SA, OGA-BY, GPL | free |
| Freesound | https://freesound.org/help/faq/ ; API terms https://freesound.org/docs/api/terms_of_use.html | MTG, Universitat Pompeu Fabra (UNVERIFIED) | APIv2 | unknown | active | per sound: CC0, CC-BY, CC-BY-NC, Sampling+ (retired) | free; an account is required to download |
| Sonniss #GameAudioGDC | https://sonniss.com/gdc-bundle-license/ | Sonniss | bundles 2015-2024 (newest listed: GDC 2024, 9 parts) | 2024 bundle | archive page | custom royalty-free licence | free |
| Google Fonts | https://raw.githubusercontent.com/google/fonts/main/README.md | Google | n/a | unknown | active | mostly OFL 1.1, some Apache 2, Ubuntu Font Licence | free |
| Mixamo | https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html | Adobe | n/a | FAQ last updated 2021-09-14 | unknown | Adobe terms | free with an Adobe ID |
| Sketchfab | https://sketchfab.com/licenses | Epic Games (UNVERIFIED) | n/a | unknown | active | Standard or Editorial store licences, plus CC licences on free models | free and paid |
| Poly Pizza | https://poly.pizza/docs/tos | dook | API v1.1 | unknown | active | per-model Creative Commons; ToS forbids extraction "for machine learning or artificial intelligence training" without permission | free |
| Roblox Creator Store (models, meshes, images, audio, plugins, fonts) | docs `production/creator-store`; Roblox Terms of Use | Roblox and creators | n/a | publisher requirements tightened 2026-08-26 | active | Terms of Use: shared UGC lets "other Users ... use Creator's UGC to create their own Experiences and other UGC on the Services" | free and paid |
| Roblox built-in content | docs `datatypes/Font` (43 families at `rbxasset://fonts/families/`), `parts/materials` | Roblox | ships with the client | tracks the client | active | Roblox terms | free |

### 4b. Redistribution and automation

| Source | Attribution | Commit raw files to this public repo? | Fetch route | API or automation |
|---|---|---|---|---|
| ambientCG | none ("You don't need to give credit") | Allowed by CC0, but **fetch-only by policy** (repo size; no game content in the factory) | `https://ambientcg.com/get?file=<AssetId>_<Res>-<Fmt>.zip`, pinned by sha256 | `full_json` lists downloads with byte sizes but no checksums. No usage terms stated. Pin hashes ourselves |
| Poly Haven | none (appreciated) | Allowed by CC0; fetch-only by policy | manual website download, or a direct `dl.polyhaven.org` file URL recorded at intake, pinned | **Do not call `api.polyhaven.com` for a commercial game.** The API ToS forbids "commercial profit" use and requires attribution next to the content and a unique User-Agent. The API returns `md5` per file (seen on `/files/<asset>`). The site forbids scraping without permission |
| Kenney | none (the logo is reserved) | Allowed; fetch-only by policy | direct pack zip from the asset page (the URL pattern is UNVERIFIED), pinned | none |
| Quaternius | none | Allowed; fetch-only by policy | site download (.blend, FBX) | none |
| OpenGameArt | depends on the licence; CC0 needs none | only CC0, and only after checking the original author (the FAQ warns of re-uploads of others' work) | manual | none |
| Freesound | CC-BY needs credit; CC-BY-NC is never usable commercially | CC0 only, manual | manual download (account) | API "free only for non-commercial purposes"; downloads of originals use OAuth2 (UNVERIFIED which resources); an account is required |
| Sonniss GDC | none | **Never.** "may not distribute, publish, sub-license or otherwise supply the sound effects as sound effects to any other person" | owner keeps the library on the PC, outside every repo; manifest entries reference files by library-relative name and sha256 | none. "AI/ML training is strictly prohibited". Uploaded Roblox audio built from it must stay private (never distributed on the Creator Store) |
| Google Fonts | per licence (OFL needs none in use) | n/a | n/a | Roblox does not accept custom font uploads (community answer, 2026-07-11; no staff statement). Roblox publishes Google-sourced fonts itself (2023-01-25: "81 new fonts", goal "the entire Google Fonts catalog") |
| Mixamo | none stated | not stated in the FAQ, so treat as never | manual (Adobe ID) | none; output uses the Mixamo skeleton, not R15 |
| Creator Store | none | **Never** (the licence covers use "on the Services"); only asset ids, through `assets/provenance.json` | `insert_asset` (asks) into the diagnostic place, through `roblox-asset-intake` | `AssetService:LoadAssetAsync` returns a "Sandboxed" root "so Scripts within it cannot run"; "Allow Loading Third Party Assets" is off by default; "Some Free Models contain malicious scripts that Roblox can't always detect automatically" (DevForum 2025-09-16) |

### 4c. Assessment

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| ambientCG | CC0 PBR materials, HDRIs, decals and terrain in 1K-8K, JPG/PNG; maps listed per asset (`color`, `displacement`, `normal`, `roughness`) | downloads are untrusted zips: verify sha256, extract into a fresh directory, reject `..` paths | Poly Haven | `full_json` query plus a pinned fetch script; both agents | the tiling-material source for MaterialVariant | **SELECT** (primary texture source) |
| Poly Haven (website) | CC0 textures (separate `nor_gl` and `nor_dx`, packed `arm`), HDRIs, models | as above | ambientCG | manual or recorded direct URL only. The `mcp-for-blender` add-on source on `main` calls `api.polyhaven.com/files/<id>` for its Poly Haven import | neutral HDRIs for Blender look-dev; extra textures | **SELECT** for website downloads; **REJECT** the API and MCP import for game assets |
| Kenney | CC0 2D, 3D, UI and audio (Interface Sounds: 100 OGG files; UI Audio, Impact Sounds, RPG Audio, Music Jingles and more) | as above | Quaternius | pinned fetch | neutral UI and feedback SFX for audio-pipeline fixtures; prototype kits | **SELECT** |
| Quaternius | CC0 low-poly model packs (.blend, FBX) | run `factory.py qa` before use | Kenney, the Blender factory templates | pinned fetch | prototype stand-ins through the Blender QA and round trip | **SELECT** as a documented source; choosing a pack is game-repo work |
| Sonniss GDC | thousands of professional SFX; royalty-free; no attribution | licence forbids redistribution, so a public-repo leak is a licence breach | Kenney audio, the Creator Store library | none; the owner curates locally | highest-quality free SFX for any genre | **SELECT** as an owner-PC library (never committed, never made public on Roblox) |
| Creator Store, including Roblox-licensed music | huge Roblox-only catalogue; music with no upload needed | backdoors and remote loaders in free models; covered by the intake skill | everything | Studio MCP `search_asset` / `insert_asset` (ask) | zero-upload music and SFX, and models after review | **SELECT** only through `roblox-asset-intake` in a game repo |
| Roblox built-in content | 2022 materials, Terrain, Atmosphere, Clouds, default Sky, 43 font families, `rbxasset://` particle textures | none | n/a | `execute_luau` | the only zero-upload palette, so SETUP_ONLY can verify looks now | **SELECT** |
| OpenGameArt | mixed-licence art and audio | provenance risk (re-uploads) | Kenney, Quaternius | manual | occasional gap filler | **REJECT** as a default source; a manual CC0 exception is allowed in a game repo with the original author recorded |
| Freesound | huge mixed-licence SFX library | per-sound licences; NC is common | Kenney, Sonniss | API non-commercial; account needed | gap filler | **REJECT** for automation; a manual CC0 exception is allowed |
| Sketchfab, Poly Pizza | model marketplaces and aggregators (both are `mcp-for-blender` sources) | per-model licences; Editorial licences forbid commercial use; purchases | Quaternius, Kenney | MCP `search_assets`/`import_asset` (already ask) | none beyond the CC0 originals | **REJECT** |
| Mixamo | auto-rigging and a motion library | Adobe account; redistribution terms not stated | Roblox Animation Editor, Blender keyframes, the 2026 animation stack (genre doc section 5) | none | reference motion | **REJECT** (account, non-R15 skeleton, unclear terms) |
| Google Fonts in-game | OFL fonts | none | Roblox's built-in and Store fonts | n/a | none in-engine | **REJECT** for in-game use (no custom font upload). OFL fonts are fine for off-engine art |

## 5. Tools near this topic

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Asphalt | https://github.com/jacktabscode/asphalt ; crates.io `asphalt` | jacktabscode | 2.0.1 | 2026-06-01 (crates.io) | active (2.0.0 2026-04-30, 1.1.0 2025-09-13) | MIT | free |
| Tarmac | https://github.com/Roblox/tarmac | Roblox | 0.7.0 | unknown | no archive banner seen | MIT | free |
| Material Maker | https://github.com/RodZill4/material-maker | RodZill4 | 1.6 | 2026-04-18 (repo page) | active | MIT | free |
| Pillow | https://pypi.org/project/pillow/ | Python Pillow | 12.3.0 | 2026-07-01 | active | MIT-CMU | free |
| Studio Material/Texture Generator, MCP `generate_material` | docs `studio/material-generator`, `studio/texture-generator`, `studio/mcp` | Roblox | Studio | tracks Studio | active | Roblox terms | free (quota unknown) |
| FFmpeg / ffprobe (already SELECT, addendum F) | ffmpeg.org | FFmpeg project | 9.0.2 | 2026-09-18 | active | LGPL/GPL | free |

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude/Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Asphalt | `asphalt.toml`; uploads images, audio, video, animations and models through Open Cloud (`asset:read`/`asset:write` key); commits `asphalt.lock.toml`; generates Luau/TS id modules; alpha bleeding; targets `cloud`, `studio` ("Syncs assets locally to Roblox Studio ... before uploading") and `debug`; `--dry-run` | An upload tool with an API key. `tools/hooks/guard_bash.mjs` denies `asphalt upload` and any `sync` that is neither `--dry-run` nor `--target studio`/`debug` | the `assets/sources.json` plus provenance pipeline (section 6.5) | CLI via Rokit | id codegen and lockfile in a game repo; the `studio` target might give local previews without upload (UNVERIFIED: where files go, and whether it makes network calls) | **REJECT** the `cloud` target in the factory. **REVISIT** the `studio`/`debug` targets as a no-upload preview route once a pass confirms they make no network calls; full use in a game repo after explicit authorisation. Its lockfile and codegen are the pattern section 6.5 copies |
| Tarmac | asset manager with hermetic builds | uploads | Asphalt | CLI | none over Asphalt | **REJECT** |
| Material Maker | Godot-based procedural texture authoring and painting | desktop app | CC0 libraries plus Blender procedural nodes | GUI; no batch mode confirmed | procedural materials | **REJECT** (overlap; no confirmed headless export) |
| Pillow | image I/O and pixel statistics | library only | bpy (pinned 5.2.2 in CI) can load images and read pixels | Python | lighter texture checks than bpy | **REVISIT** if bpy-based texture checks prove too slow; the stdlib can read PNG/JPEG headers for sizes |
| Material/Texture Generator, `generate_material` | AI-made MaterialVariants and textures | Texture Generator saves images to the account inventory, which is an upload. Material Generator storage is not stated. Both are already "ask" in `docs/mcp.md` | ambientCG and Poly Haven CC0 | MCP (ask) | quick variants | **REJECT** in the factory; **REVISIT** in a game repo (asset creation, licence of output not stated) |
| FFmpeg / ffprobe | duration, sample rate, channels and size checks against the upload limits (section 3g); loudness measurement (filter docs could not be fetched; UNVERIFIED) | local | Audacity (not selected) | CLI on the PC; in a Linux container only if already present | catches files Roblox would reject before any upload | **SELECT** (already selected); add an `audio-intake` check that SKIPs when ffprobe is absent |

## 6. Factory design (input to the implementation plan)

### 6.1 Environment presets: `SceneKit/Lighting.luau` schema 2

```lua
["dusk-clear"] = { -- names describe conditions, never a theme; values are illustrative
	requires = { LightingStyle = "Realistic", PrioritizeLightingQuality = true }, -- checked, never written
	lighting = {
		ClockTime = 18.2, GeographicLatitude = 35, Brightness = 2, ExposureCompensation = 0.1,
		Ambient = { 40, 38, 45 }, OutdoorAmbient = { 120, 105, 110 },
		EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 1, GlobalShadows = true, ShadowSoftness = 0.25,
	},
	atmosphere = { Density = 0.35, Offset = 0.2, Haze = 1.8, Glare = 0.5, Color = { 200, 170, 160 }, Decay = { 90, 80, 110 } },
	sky = { CelestialBodiesShown = true, SunAngularSize = 12, StarCount = 3000 }, -- no Skybox* faces without approved ids
	clouds = { Enabled = true, Cover = 0.5, Density = 0.6, Color = { 230, 215, 210 } }, -- parented under Terrain
	wind = { 4, 0, 2 }, -- Workspace.GlobalWind
	post = {
		bloom = { Intensity = 0.5, Size = 24, Threshold = 0.9 },
		colorCorrection = { Brightness = 0, Contrast = 0.05, Saturation = 0.05, TintColor = { 255, 240, 232 } },
		colorGrading = { TonemapperPreset = "Default" }, -- Lighting only; one instance
		sunRays = { Intensity = 0.08, Spread = 0.6 },
	},
}
```

- **Ownership.** `apply` creates or updates children named `SceneKit<Class>` with the attribute `SceneKitOwned = true`. It never edits non-owned effects; it reports them in `inspect`. It refuses to add a ColorGradingEffect when a non-owned one exists, because only the most recently parented one applies.
- **`validate(preset)`.** Checks unknown keys, RGB 0-255, `ExposureCompensation` -5 to 5, Clouds `Cover`/`Density` 0-1, SunRays `Spread` 0-1, Bloom `Threshold` 0-1, `ShadowSoftness` 0-1 and the enum values in `requires`. ColorCorrection ranges are not published, so the -1 to 1 check is a convention.
- **`blend(a, b, t)`** is pure: numbers and colours interpolate, booleans and enums switch at `t >= 0.5`. Day/night, interior/exterior and cutscene grades tween it. `Feel.Screen` keeps its own transient ColorCorrection instance; whether two ColorCorrection effects stack is UNVERIFIED.
- **`inspect`** reports every owned value plus `LightingStyle` and `PrioritizeLightingQuality` (both readable) and a `requires_ok` flag.
- **Presets.** The five existing ids keep their values. New ones: `noon-clear`, `dawn`, `dusk-clear`, `night-moonlit`, `fog-dense`, `storm-dark`, `interior-dim`, `interior-bright`, `stylized-soft` (Soft) and `retro` (Soft with ColorGrading Retro, the documented replacement for Compatibility).
- **Light validator.** The engine cap becomes 120, with a separate budget table (section 6.6).

### 6.2 Material library (`material-library/1`) and texture checks

```json
{ "schema": "material-library/1",
  "materials": [ { "name": "Concrete_A", "base_material": "Concrete", "studs_per_tile": 8, "pattern": "Regular",
    "maps": { "color": "ambientcg/<AssetId>/1K-PNG#Color", "normal": "ambientcg/<AssetId>/1K-PNG#NormalGL",
              "roughness": "ambientcg/<AssetId>/1K-PNG#Roughness", "metalness": null, "emissive": null },
    "resolution": 1024, "override_base": false, "roblox": { "color": 0, "normal": 0, "roughness": 0 } } ] }
```

- **Tier 0 (factory, now).** `Style.luau` roles may name a built-in material plus an optional `variant`, ignored until tier 1. `SceneKit.Materials.override(base, name)` wraps `SetBaseMaterialOverride` (security None).
- **Tier 1 (game repo).** The validator and preview run offline. Upload asks first. The resulting ids go into `assets/provenance.json` as `approved`, with a `source_key` back to `assets/sources.json`. MaterialVariants are created through `execute_luau`, which has plugin security, because their maps are PluginSecurity write.
- **Texture validator** (`tools/blender/bkit/textures.py`, bpy, already pinned in CI):
  - Images are square powers of two, ≤ 1024 by default; 2048 needs a `justify` string; 4096 is never the default.
  - Normal maps must come from an OpenGL source (`_NormalGL`, `nor_gl`). DirectX names (`_NormalDX`, `nor_dx`) are rejected. The ambientCG file naming is UNVERIFIED in this pass.
  - Roughness, metalness and emissive must be single-channel 8-bit, converted from RGB if needed.
  - Packed `arm` maps are split. AO has no Roblox slot: it is dropped, or optionally multiplied into the colour.
  - The AlphaMode must be stated explicitly.
  - Colour variants use `SurfaceAppearance.Color` with TintMask instead of new textures, following the performance doc.
- **Preview.** `factory.py material-preview <library> <out>` builds a Principled material with image maps on a sphere and a tiled plane at the library's `studs_per_tile`, and renders it under a CC0 HDRI (fetched via section 6.5) or a fixed three-point fallback. This also addresses B03 ("not Studio lighting"), though Blender's look is still not Roblox's.
- **Meshes.** One material per mesh, baked to one texture set (B06 fix), with SurfaceAppearance.

### 6.3 VFX preset format (`vfx/1`)

```lua
impact_small = {
	duration = 0.6, priority = 3, sound = "impact_small", -- AudioDirector event key
	emitters = { {
		texture = "builtin:sparkles", burst = 12, rate = 0, lifetime = { 0.15, 0.3 },
		speed = { 8, 16 }, spread = { 40, 40 }, size = { { 0, 0.4 }, { 1, 0 } },
		transparency = { { 0, 0 }, { 1, 1 } }, color = "accent", -- palette role resolved by the caller
		lightEmission = 1, lightInfluence = 0, orientation = "FacingCamera", drag = 4,
		flipbook = nil, -- { layout = "Grid4x4", mode = "OneShot", fps = 30, startRandom = false }
	} },
	beams = {}, trails = {},
	lights = { { class = "PointLight", range = 8, brightness = 2, shadows = false, fade = 0.2 } },
	reduced = { drop = { "trails", "lights" }, burstScale = 0.5 },
}
```

- **Textures** are `builtin:<name>`, which maps to `rbxasset://` paths. Only `sparkles_main.dds` and `SquareParticle.png` are known; the rest of the built-in list is UNVERIFIED. The alternative is `asset:<provenance key>`, which must be approved.
- **Colours** are palette roles (`accent`, `positive`, `negative`, `neutral`) supplied by the game, so presets stay neutral.
- **Validator.** Rate > 400 is an error and > 100 a warning (mobile cap). Lifetime ≤ 20. Flipbook fps ≤ 30, and the texture size must be a multiple of the layout (sizes come from `sources.json`). Beams and trails need two attachment offsets. Light range ≤ 120, with a warning when `shadows = true`. The Highlight count is checked.
- **Budget estimates.** Peak live particles = Σ(burst + rate × lifetime.max). Overdraw score = Σ particles × size.max², with a budget per priority.
- **Neutral recipe set (event types).** `appear`, `vanish`, `pickup`, `impact_small`, `impact_medium`, `impact_large`, `heal`, `buff_loop`, `debuff_loop`, `level_up`, `reward_burst`, `telegraph_ring`, `projectile_trail`, `dash_trail`, `ambient_motes`, `splash`, `dust_puff`, `sparks`, `smoke_puff`, `select_outline` (Highlight) and `hover_glow`.
- **Builder.** `Vfx.build(preset, env)` returns an instance tree. It runs under Lune (`@lune/roblox`) for structure specs and becomes an EffectsPool adapter in Studio. `Feel` cue tables refer to these presets by key (ui-cinematics doc, section 6.3).

### 6.4 Audio manager: `Runtime/AudioGraph.luau`

```lua
{ schema = "audio-graph/1",
  buses = {
	master = { effects = { { class = "AudioCompressor", Threshold = -6, Ratio = 8 } } }, -- limiter-like safety
	music = { parent = "master", duck = { by = "dialogue", Threshold = -30, Ratio = 4, Attack = 0.01, Release = 0.4 } },
	sfx = { parent = "master" }, ui = { parent = "master" }, ambience = { parent = "master" },
	dialogue = { parent = "master" }, world = { parent = "master", listener = "camera" },
  },
  voices = { sfx = 24, ui = 8, music = 2, ambience = 4, dialogue = 2 },
  cues = { ["ui.click"] = { bus = "ui", source = "asset:<key>", volume = { 0.9, 1 }, pitch = { 0.97, 1.03 },
                            cooldown = 0.05, priority = 2, loop = false } } }
```

- **Buses.** Each bus is an `AudioFader`. `AudioMixer:step()` outputs 0-1 per channel and writes `Fader.Volume`. Effects chain in data order, which matters per the docs. Ducking wires the `by` bus into the music compressor's `Sidechain` pin. `AudioMixer:duck` stays for scripted ducks.
- **2D:** AudioPlayer, Wire, bus fader, ..., master, AudioDeviceOutput.
- **3D:** AudioPlayer, Wire, AudioEmitter on an Attachment or PVInstance. The graph's own AudioListener on the Camera feeds the `world` bus, which feeds master. For 3D sound to pass through the master fader, `SoundService.DefaultListenerLocation` must be None. It is ReadOnly to scripts, so it is set in Studio, and `inspect` checks it (design constraint; behaviour UNVERIFIED).
- **Voices.** A pool of AudioPlayers per bus with priority stealing. Per-cue cooldown stops spam, and random pitch and volume come from `PlaybackSpeed` and `Volume`. Rarely used cues get `AutoLoad = false`. A load wait on `IsReady` has a timeout.
- **Music.** `LoopRegion` gives intro-then-loop. Transitions are scheduled with `Play(atTime)` against `GetMixerTime()`, and two players crossfade through AudioMixer fades.
- **3D shaping.** Distance curves come from data through `SetDistanceAttenuation` (≤ 400 points). Acoustic simulation is opt-in per emitter.
- **Accessibility.** Volume groups per bus. `Feel.Cues` already requires a visual channel for any sound cue.
- **Contract.** It implements the AudioDirector backend (`play(key, def) -> boolean`, `stop(key)`), so AudioDirector, its trace and `missing_asset` do not change.

### 6.5 Asset fetch and provenance pipeline

```json
{ "schema": "asset-sources/1",
  "sources": [ { "key": "ambientcg/<AssetId>/1K-PNG", "kind": "texture-set",
    "source_page": "https://ambientcg.com/view?id=<AssetId>", "file_url": "https://ambientcg.com/get?file=<AssetId>_1K-PNG.zip",
    "licence": "CC0-1.0", "licence_url": "https://docs.ambientcg.com/license/", "attribution": "none",
    "redistributable": true, "commit": "fetch-only", "sha256": "<64 hex, pinned on the first approved fetch>",
    "bytes": 0, "pinned": "YYYY-MM-DD", "roles": ["material:concrete"], "api_terms": "none stated" } ] }
```

- **Fetch script** (`tools/fetch_assets.py`, stdlib only):
  - It runs only on an explicit request, never in the gate.
  - Unpinned entries are refused unless `--pin` is given; `--pin` records sha256 and bytes after an owner-approved first fetch.
  - Hosts must be on an allow-list: `ambientcg.com`, `dl.polyhaven.org`, `kenney.nl`, plus Quaternius's download host (UNVERIFIED). `api.polyhaven.com` is never on it.
  - Downloads go to `build/asset-cache/<key>/` (gitignored). The script verifies size and sha256 before unpacking.
  - Archives are extracted into a new empty directory, rejecting absolute or `..` members and enforcing member-count and total-size caps. Nothing in a download is ever executed.
  - It writes a `cache-manifest.json` with a sha256 per extracted file.
  - Entries with `redistributable: false` (Sonniss) are never downloaded. They point to an owner library by a library-relative name (`owner-library:<bundle>/<file>`) and a sha256, never by a machine path.
- **Gate step `asset-sources`** (offline, pre-commit). It checks:
  - the schema;
  - the licence allow-list: `CC0-1.0`; `OFL-1.1` (off-engine only); `LicenseRef-Sonniss-GDC`, which requires `redistributable: false` and `commit: "never"`;
  - that no `api.polyhaven.com` URL appears;
  - the sha256 format whenever `pinned` is set;
  - that every committed binary under `assets/` matches a `commit-ok` entry by sha256, and no file of a `never` entry is committed.

  A self-test plants bad entries, as `asset-provenance` already does.
- **Link to Roblox ids.** `assets/provenance.json` gains an optional `source_key`, so an approved, uploaded Roblox id traces back to its external file and licence. The `roblox-asset-intake` skill gains an "external file" branch.
- **Never in this repo:** Sonniss files, Mixamo output, Creator Store content, non-CC0 Freesound or OpenGameArt files, or any machine path.

### 6.6 Budgets as data: `SceneKit/Budgets.luau`

Two tables, `documented` (section 3h, with source URLs as comments) and `conventions` (section 3h "Conv." column). They are consumed by `Validate.dressing` (light counts per room, shadow lights, range), by the `vfx/1` validator and by the texture validator. Reports say which kind of limit failed.

### 6.7 Verification: what proves each part

| Part | Linux container (Lune, bpy, Rojo) | Studio (diagnostic place, MCP) | Human or device |
|---|---|---|---|
| Lighting v2 | Lune: apply each preset to an `@lune/roblox` DataModel; owned instances only; exactly one ColorGrading; `validate` negatives; `blend` determinism; a golden digest of the preset table. Rojo: build a place whose project file sets `Lighting.LightingStyle`, then read it back with Lune `roblox.deserializePlace` (UNVERIFIED that rbx-dom serialises it) | apply each preset with `execute_luau`; `screen_capture` from `Camera.captureSet` angles; `inspect` shows `requires_ok` | judging the look |
| Light cap fix | Lune: range 90 passes, 121 fails; fixture hashes unchanged | n/a | n/a |
| VFX presets | Lune: validator negatives (rate, lifetime, fps, flipbook multiple), the builder's instance tree, budget estimates | emit every preset on a grid; stills via `screen_capture` | motion via FFmpeg window capture (PC); MicroProfiler on a phone |
| AudioGraph | Lune with a fake instance env (or `@lune/roblox` if the reflection DB has the Audio classes): every cue reaches master, no cycles, the duck wire targets `Sidechain`, voice caps | in a play session, build the graph and assert every `Wire.Connected == true`; drive a test cue and require `AudioAnalyzer.PeakLevel > 0` on master. This needs one loadable audio source: a built-in content path (UNVERIFIED) or an approved id in a game repo | mix quality by ear |
| Texture validator and material preview | bpy headless on synthetic generated images (sizes, channels, GL/DX names); the preview PNG is read and reviewed | tier 1 only, after upload (game repo) | judging the look |
| Asset sources | gate self-test with planted bad entries; fetch script tests against a local fixture archive (sha mismatch refused, zip-slip refused) with no network | n/a | owner approves first fetches |

### 6.8 Proposed gap-matrix changes (for `reports/gap-matrix.json`; not edited here)

- **S05:** add lighting v2 as the fix and these verification steps.
- **R02:** mark NativeAudio OUTDATED, with AudioGraph as the fix.
- **B03:** CC0 HDRI look-dev.
- **B06:** link to the material library.
- **Q06:** external-file sources and the `asset-sources` gate.
- **New rows** (suggested ids V01-V05, a prefix unused today):
  - environment presets (PARTIAL);
  - VFX preset library (PARTIAL: Effects/EffectsPool only);
  - Audio API graph (MISSING);
  - external asset sources pipeline (MISSING);
  - visual and audio budgets as data (MISSING).

## 7. Corrections to earlier facts in this repo

- `packages/SceneKit/Validate.luau`: the "engine cap" of 60 for light Range is outdated. The cap is 120 (DevForum 2025-09-23; `Lighting.yaml`).
- `tooling-2026-10.md` section 6 left open whether 4096 or 1024 is the texture limit. 4K rendering is live (2026-01-30) for MeshPart, SurfaceAppearance, Texture, Decal and MaterialVariant, with streaming fallback. The texture-spec page still also mentions 1024 "pixel spaces", so treat 1024 as the budget and 4096 as the ceiling.
- A common belief is that Highlights are limited to 31. The docs now say 255 simultaneous.

## 8. UNVERIFIED

- Whether `rojo build` (rbx-dom) writes `Lighting.LightingStyle`/`PrioritizeLightingQuality` from a project file, and whether Lune 0.10.5's reflection database (0.728 per the ui-cinematics doc) knows ColorGradingEffect, MaterialVariant's Content properties and the Audio API classes.
- Which lighting setting gates `ShadowSoftness`: the class page says ShadowMap/Future, the guide says Realistic.
- ColorCorrection, Bloom `Intensity`/`Size` and DepthOfField ranges and defaults, and the per-effect cost on mobile; none are published.
- Whether two ColorCorrectionEffects (a preset baseline and a `Feel` pulse) combine.
- Whether light attenuation improvements shipped after 2025-09-23.
- The built-in `rbxasset://textures/particles/` and `rbxasset://sounds/` file lists, and whether `AudioPlayer.Asset` accepts `rbxasset://` content. The Client Tracker mirror was blocked by robots.txt.
- Where Material Generator stores its textures, and the licence and quota of generated output.
- Whether a 3D AudioEmitter heard through the default listener bypasses a script-created master fader, and whether `DefaultListenerLocation = None` fixes it.
- The `AudioLimiter` properties. Only the announcement title was seen.
- ambientCG's per-map file names inside the zips (for example `_NormalGL`), Kenney's direct zip URL pattern and Quaternius's download host.
- ambientCG's operator name (the docs say only "one person").
- Which Freesound API resources require OAuth2, and Freesound's publisher.
- Sketchfab's corporate owner, and Poly Pizza's per-model licence display.
- Whether Mixamo terms permit redistributing raw files (the FAQ is silent).
- Custom font upload: only a community answer (2026-07-11) says it is unsupported.
- FFmpeg `loudnorm`/`ebur128` details: the filter page was truncated and trac returned access denied.
- Blender bake operator options (`bpy.ops.object.bake` types and normal swizzle): only navigation pages were returned.
- Whether a Sonniss bundle newer than GDC 2024 exists; the archive page lists none.
- Where Asphalt's `studio` target copies files, how they are referenced (`rbxasset://`?), and whether it makes network calls.
- Whether `mcp-for-blender` 2.1.8's `import_asset` uses the same Poly Haven API path as the `main` add-on source read here.

## 9. Sources (all fetched 2026-10-06)

- **Roblox docs** (`.md` variants: `https://create.roblox.com/docs/en-us/<path>.md`):
  - environment: `environment/lighting`, `environment/atmosphere`, `environment/clouds`, `environment/skybox`, `environment/global-wind`, `environment/post-processing-effects`;
  - effects: `effects/light-sources`, `effects/particle-emitters`, `effects/beams`, `effects/trails`, `effects/highlighting`;
  - materials and textures: `parts/materials`, `art/modeling/texture-specifications`, `art/modeling/surface-appearance`;
  - audio: `audio/objects`, `audio/effects`, `audio/assets`;
  - performance: `performance-optimization/improve`, `performance-optimization/design`, `performance-optimization/test-on-hardware`;
  - assets and Studio: `production/creator-store`, `projects/assets/privacy`, `projects/assets/toolbox`, `studio/mcp`, `studio/material-generator`, `studio/texture-generator`;
  - reference: `reference/engine/classes/` Lighting, PointLight, Light, Atmosphere, BloomEffect, DepthOfFieldEffect, ColorGradingEffect, MaterialVariant, MaterialService, SoundService, AudioPlayer, AudioEmitter, AudioCompressor, AudioFader, AudioDeviceOutput, AudioAnalyzer and Wire; `reference/engine/enums/` Technology, LightingStyle and AlphaMode; `reference/engine/datatypes/Font`;
  - index: https://create.roblox.com/docs/llms.txt
- **creator-docs YAML** (`https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/<kind>/<Name>.yaml`): classes Lighting, Atmosphere, SurfaceAppearance, BloomEffect, DepthOfFieldEffect, SunRaysEffect, ColorCorrectionEffect, Beam and ParticleEmitter; enum TonemapperPreset.
- **DevForum:**
  - https://devforum.roblox.com/t/let-there-be-unified-light-unified-lighting-is-fully-live/3401512
  - https://devforum.roblox.com/t/extended-light-ranges-doubling-the-limit-to-120/3954367
  - https://devforum.roblox.com/t/4k-texture-rendering/4316229
  - https://devforum.roblox.com/t/full-release-acoustic-simulation-emit-audio-with-presence/4307121
  - https://devforum.roblox.com/t/roblox-audio-api-exits-beta-enhanced-sound-controls-now-available/3153454
  - https://devforum.roblox.com/t/loading-third-party-model-assets-in-experience/3939065
  - https://devforum.roblox.com/t/new-requirements-to-publish-to-the-creator-store/4820095
  - https://devforum.roblox.com/t/fonts-in-creator-marketplace-81-new-fonts/2164977
  - https://devforum.roblox.com/t/uploading-custom-fonts-or-workarounds/4731886 (community thread; a lead only)
- **Roblox Help:**
  - https://en.help.roblox.com/hc/en-us/articles/115004647846-Roblox-Terms-of-Use
  - https://en.help.roblox.com/hc/en-us/articles/23359485439124-Audio-Upload-License-Agreement
  - https://en.help.roblox.com/hc/en-us/articles/360038525351-Using-Licensed-Music-in-Videos
- **Asset sources:**
  - Poly Haven: https://polyhaven.com/license , https://docs.polyhaven.com/en/faq , https://github.com/Poly-Haven/Public-API , https://raw.githubusercontent.com/Poly-Haven/Public-API/master/README.md , https://raw.githubusercontent.com/Poly-Haven/Public-API/master/ToS.md , and one metadata read of `https://api.polyhaven.com/files/<asset>`
  - ambientCG: https://docs.ambientcg.com/license/ , https://docs.ambientcg.com/api/ , https://docs.ambientcg.com/api/v2/full_json/ , https://docs.ambientcg.com/asset-types/ , and one query of `https://ambientcg.com/api/v2/full_json?type=Material&limit=1&include=downloadData`
  - Kenney: https://kenney.nl/support , https://kenney.nl/assets , https://kenney.nl/assets/category:Audio , https://kenney.nl/assets/interface-sounds
  - Quaternius: https://quaternius.com/ , https://quaternius.com/faq.html
  - OpenGameArt and Freesound: https://opengameart.org/content/faq , https://freesound.org/help/faq/ , https://freesound.org/docs/api/ , https://freesound.org/docs/api/authentication.html , https://freesound.org/docs/api/terms_of_use.html
  - Sonniss: https://sonniss.com/gameaudiogdc , https://sonniss.com/gdc-bundle-license/
  - others: https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html , https://raw.githubusercontent.com/google/fonts/main/README.md , https://sketchfab.com/licenses , https://poly.pizza/ , https://poly.pizza/docs/tos
- **Tools:**
  - https://crates.io/api/v1/crates/asphalt , https://raw.githubusercontent.com/jacktabscode/asphalt/main/README.md
  - https://github.com/Roblox/tarmac , https://github.com/RodZill4/material-maker , https://pypi.org/project/pillow/
  - https://raw.githubusercontent.com/ahujasid/mcp-for-blender/main/addon.py
  - the repo's own `tools/hooks/guard_bash.mjs` (Asphalt and Tarmac rules)
- **Unreachable or unusable this pass:**
  - https://ffmpeg.org/ffmpeg-filters.html (truncated before `loudnorm`) and https://trac.ffmpeg.org/wiki/AudioVolume (access denied);
  - https://fonts.google.com/faq (script-rendered);
  - https://docs.blender.org/manual/en/latest/render/cycles/baking.html and https://docs.blender.org/api/current/bpy.ops.object.html (navigation only);
  - the Roblox Client Tracker mirror (robots.txt);
  - https://create.roblox.com/docs/en-us/environment/light-sources.md (404; the `effects/` path works).
