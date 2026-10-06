---
name: roblox-presentation-pass
description: Give a place a finished look, sound and feel from neutral, function-named presets instead of hand-tuned one-offs - lighting and post-processing presets, day/night cycle and weather, material overrides, VFX presets with pooling, the audio bus mix with cues, ducking and music crossfades, and game-feel feedback (springs, camera shake, hit-stop, damage popups, flash-safe screen effects, haptics) - inside per-device budgets and with reduced motion and flash safety built in. Use for "make this look better", "set up lighting/mood/time of day", "add hit effects/juice/screen shake", "set up sound/music/mixing", "VFX for pickups/levels/abilities", "check presentation budgets", "flash/motion accessibility".
---

# Roblox presentation pass (look, sound and feel)

## Purpose
Make a place read and feel like a top-chart game using data presets that are validated, budgeted and accessible by default: SceneKit/Lighting schema 2, material-library/1, perf/1 budgets, AVKit (vfx/1, audio-graph/1) and Feel, plus GameKit/WorldCycle. Presets are named by function; a game re-skins them through palettes, texture roles and asset slots, never by editing the factory's theme (it has none).

## Triggers
Lighting or mood setup, time of day, weather, post-processing, material look, hit/pickup/level-up/ability effects, screen shake, hit-stop, damage numbers, flashes, haptics, sound effects, music and mixing, ducking under dialogue, performance budgets for effects and lights, reduced-motion or photosensitivity review, a "presentation pass" before a release.

## Inputs
The place or fixture to dress; the device classes to support (phone_low, phone, tablet, desktop, console); the game's palette roles and approved texture/audio slots if any (otherwise built-ins and `missing_asset`); settings/1 values (`Settings.effective`) for reduced motion, flashes, haptics and bus volumes; which moments need feedback (hit, pickup, reward, level up, spawn, status).

## Required context
`docs/presentation.md` (what ships, budgets, rules, examples). Read a module only for option names: `packages/SceneKit/Lighting.luau` header, `packages/AVKit/README.md`, `packages/Feel/README.md`, `packages/GameKit/WorldCycle.luau` header. Specs show each API in use: `tests/scenekit_lighting.spec.luau`, `tests/avkit_vfx.spec.luau`, `tests/avkit_audio.spec.luau`, `tests/feel.spec.luau`, `tests/gamekit_worldcycle.spec.luau`. Contract and tiers: `docs/runtime-kits.md`.

## Tools
- Lune: `lune run tests/run.luau scenekit`, `avkit`, `feel`, `gamekit_worldcycle`; preset digests `tests/golden/av-presets.json` (update only when intended: `FACTORY_UPDATE_GOLDEN=av-presets lune run tests/run.luau avkit_presets`).
- Studio MCP (main session only) on the unpublished kits diagnostic place built from `fixtures/kits.project.json`: set `Workspace` attribute `SETUP_ONLY_KitFixture = "lookdev"` for the swatches, preset cycle (key L), VFX grid and Feel marker; `screen_capture` per preset; probe runners in `tests/engine/` (`av_lighting_presets`, `av_vfx_grid`, `av_audiograph_wires`, `av_audio_master_level`, `feel_marker_cue`, `worldcycle_phases`) and `lookdev_material_override` from the registry through `execute_luau`.
- Blender headless preview of SceneKit manifests (`python3 tools/blender/factory.py render-manifest`) for geometry; lighting judgement needs Studio captures.

## Procedure
1. Budget first: pick the lowest device class you ship to and read its row in `SceneKit/Budgets.CLASSES` (documented limits vs conventions). Collect stats and run `Budgets.check(stats, class)`; run `Validate.scene` for light range (120 cap, 60 budget), lights and shadow casters per room.
2. Lighting: choose presets by function (`lookdev_neutral` to judge assets, `readability_max` as the competitive floor, `perf_low` for low-end). `Lighting.audit(preset, { postEffects = Budgets.CLASSES[class].post_effects })` must be clean; `Lighting.apply(game.Lighting, id)` then `Lighting.inspect(game.Lighting)`: no conflicts, and ask the owner to set `LightingStyle`/`PrioritizeLightingQuality` when `requires_ok` is false (scripts cannot). For time of day use `WorldCycle.new()` with `Workspace:GetServerTimeNow()`; weather with `setWeather`.
3. Materials: tier 0 first (`Materials.overridePlan` + `applyOverrides` on MaterialService, variants built via `execute_luau`); tier 1 maps only after the owner uploads them in a game repo.
4. VFX: start from `VfxLibrary` ids; tune copies, keep `Vfx.validate` free of problems and warnings you cannot justify; build with the game palette (`Vfx.palette(effective.colorblindMode)` for colour-vision variants) and approved textures; play through one `VfxPoolRoblox` per client (`step` every frame, `stop` loops so they linger and recycle).
5. Audio: start from `AudioGraph.default()` and `AudioCues.defaults()`; map slots to approved content (no ids in the factory); `AudioGraphRoblox.new(env, { parent, camera, assets, music })`, `mix:step(dt, effective)` every frame; route AudioDirector through `mix:backend()`. Keep voices within 32, dialogue ducking music and ambience.
6. Feel: define cues (`Cues.defaults()` as the pattern), every sound with a visual channel; `FeelRoblox.new(env, { camera, guiParent, effective, vfx = pool, audio = mix })`, bind animation markers with `feel:bindMarkers(track, { Hit = "hit_light" })`, `feel:freeze(track)` for hit-stop, `feel:step(dt)` at `RenderPriority.Camera.Value + 1`.
7. Accessibility check: run with `reducedMotion = true` (no shake, punches or motion presets), `reduceFlashing = true` (soft tints only, flash lights dropped), `haptics = false`, and each colour-vision mode; confirm meaning never rests on colour or sound alone.
8. Prove it: Lune specs green, digests unchanged unless intended, then the Studio probes and lookdev captures per preset; motion needs a recording on the owner's PC.

## Outputs
Applied presets (owned `SceneKit<Class>` instances and attributes `SceneKitLightingProfile`/`SceneKitLightingBlend`), budget and audit reports, VFX and audio adapters wired to settings, Feel cue tables, probe ENGINE_CHECK/ENGINE_DONE lines, captures per preset, and any preset changes with their updated `av-presets` digests.

## Acceptance
Validators and audits clean (warnings justified in writing); `Budgets.check` has no violations for the target class; Lighting `inspect` shows the preset with no conflicts; no more than 3 flashes in any second and none under reduce-flashing; shake 0 under reduced motion; every sound cue has a visual channel; probes report `ENGINE_DONE ... "ok":true` in Studio; Lune suite and `python3 tools/check.py` pass. Fun, polish and device performance are judged by people on devices, not by these checks.

## Failure
- `Lighting.apply` conflicts: a non-owned Atmosphere/Sky/Clouds/ColorGrading exists; adopt it (`{ adopt = true }`) or remove it, never stack two.
- `requires_ok` false: LightingStyle is owner-set in Studio; report it, do not work around it.
- Vfx problems name the field and limit (rate, lifetime, flipbook, light range, raw ids): fix the preset, never the validator.
- `missing_asset` from cues or music: the slot has no approved content; leave it reported until the owner approves audio.
- Audio probe peak stays 0: the built-in content path may not load in AudioPlayer (UNVERIFIED); rerun with an approved content string, check `DefaultListenerLocation` and that every Wire is Connected.
- Material variant build fails in a play session: BaseMaterial needs plugin security; use `execute_luau`.
- A changed digest in `av-presets` without an intended preset change is a regression.

## Related
roblox-scene-authoring, visual-qa, roblox-performance-pass, roblox-ui-ux-pass, roblox-animation-integration, roblox-studio-testing, roblox-asset-intake, luau-quality.
