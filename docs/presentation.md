# Presentation: look, sound and feel

How the factory makes a place look, sound and feel finished without choosing a theme: environment presets (SceneKit/Lighting schema 2), materials (material-library/1), budgets per device class (perf/1), visual effects (AVKit vfx/1), the audio mix (AVKit audio-graph/1), game feel (Feel) and the day/night cycle (GameKit/WorldCycle). Every preset is data named by function, validated, digested in `tests/golden/av-presets.json` and tunable by a game. Skill: `roblox-presentation-pass`. Research: [visual-audio-assets](research/visual-audio-assets-2026-10.md), [ui-cinematics-feel](research/ui-cinematics-feel-2026-10.md). Contracts and tiers: [runtime-kits.md](runtime-kits.md).

"Documented" below means a Roblox-published number; "convention" means a factory starting point to calibrate on a 2-4 GB Android phone with the MicroProfiler. Validators keep the two apart: documented limits are errors, conventions are warnings.

## What ships

| Area | Modules | Tier | Proof here | Pending Studio proof |
|---|---|---|---|---|
| Environment presets | `SceneKit/Lighting` (leaf, no requires) | T1 | `tests/scenekit_lighting.spec.luau`, `build_fixtures` hashes | probe `av_lighting_presets` |
| Materials | `SceneKit/Materials`, `assets/material-library.json` | T1 (override T3) | `tests/scenekit_materials.spec.luau` | probe `lookdev_material_override` (execute_luau) |
| Budgets | `SceneKit/Budgets` (perf/1), `SceneKit/Validate` light rules | T0 | `tests/scenekit_budgets.spec.luau`, `tests/scenekit_dressing.spec.luau` | device runs (owner) |
| VFX | `AVKit/Vfx`, `VfxLibrary`, `Pool`, `VfxPoolRoblox` | T1 / T3 | `tests/avkit_vfx.spec.luau`, `tests/avkit_pool.spec.luau` | probe `av_vfx_grid` |
| Audio | `AVKit/AudioGraph`, `AudioCues`, `Music`, `AudioGraphRoblox`, `AudioMixer`, `AudioDirector` | T1 / T3 | `tests/avkit_audio.spec.luau` | probes `av_audiograph_wires`, `av_audio_master_level` |
| Feel | `Feel/Spring`, `Shake`, `HitStop`, `Popups`, `Screen`, `Haptics`, `Cues`, `FeelRoblox` | T0 / T3 | `tests/feel.spec.luau`, `tests/feel_roblox.spec.luau` | probe `feel_marker_cue`; haptics on a device |
| Day/night | `GameKit/WorldCycle` | T1 | `tests/gamekit_worldcycle.spec.luau` | probe `worldcycle_phases` |

All probes live in `fixtures/kits/shared/lookdev_probes.luau` with runners in `tests/engine/`; `tests/avkit_probes.spec.luau` runs them against fakes, which proves they load and their logic holds, not that Studio agrees. The lookdev fixture (`Workspace` attribute `SETUP_ONLY_KitFixture = "lookdev"` in the kits place) builds value-step swatches and every material, cycles the lighting presets (key L, P pauses), plays the VFX grid and fires Feel cues on a marker, for screen captures and owner judgement.

## Environment presets (Lighting schema 2)

A preset owns the Lighting properties, one Atmosphere, one Sky (no skybox textures), Clouds (under Terrain), `Workspace.GlobalWind` and persistent post-processing (Bloom, ColorCorrection, DepthOfField off, SunRays, optional ColorGrading). `apply` writes every field (missing ones take engine defaults), so the result never depends on what ran before; it creates only `SceneKit<Class>` children and reports anything else as foreign or a conflict. `LightingStyle` and `PrioritizeLightingQuality` cannot be written by scripts: presets declare them under `requires`, `inspect` reports `requires_ok`, and the owner sets them in Studio.

| Preset | Intent | Tags |
|---|---|---|
| `lookdev_neutral` | Asset look-dev: even afternoon daylight with mild shadows and no grading (the former neutral-day) | inspection, outdoor, day |
| `lookdev_contrast` | Form and silhouette check: low key fill, crisp shadows from a lower sun | inspection, outdoor, day |
| `bright_noon` | Clear midday: high sun, short soft shadows, legible distance | outdoor, day, clear |
| `overcast` | Diffuse grey daylight, no hard shadows, low saturation | outdoor, day, weather |
| `golden_hour` | Low warm sun, long shadows, light haze and gentle bloom | outdoor, evening, clear |
| `blue_hour` | Twilight after sunset; transition between day and night | outdoor, evening, clear |
| `night_clear` | Readable night: moonlit fill keeps silhouettes and paths visible | outdoor, night, clear |
| `low_light` | Scenes lit by their own lights; a dim ambient floor so nothing is pitch black | interior, night, local_lights |
| `dense_fog` | Short sight lines: bright fog hides the distance, near field readable | outdoor, day, weather |
| `storm_dim` | Heavy weather: low dark clouds, strong wind, desaturated cool light | outdoor, day, weather |
| `interior_warm` | Rooms under warm practical lights; no aerial haze indoors | interior, local_lights |
| `interior_cool` | Rooms under cool neutral lights | interior, local_lights |
| `readability_max` | Competitive and accessibility baseline: high fill, no glare, bloom or haze | outdoor, day, accessibility |
| `perf_low` | Low-end fallback: Soft lighting, no clouds, no post-processing | outdoor, day, performance |
| `flat_capture` | Geometry capture: shadowless flat light, no fog or grading (the former inspection-flat) | inspection |

Schema 1 ids (`neutral-day`, `overcast`, `golden-hour`, `night`, `inspection-flat`) still resolve, with unchanged numbers, so fixture hashes did not move. `Lighting.blend(a, b, t)` interpolates (ClockTime on the shortest arc, booleans and enums switch at 0.5, disabled effects fade from zero-effect values); `audit` warns about readability, glare without haze, aggressive bloom or sun rays, persistent depth of field and the post-effect budget of a device class.

```lua
local Lighting = require(Workbench.SceneKit.Lighting)
local report = Lighting.apply(game.Lighting, "golden_hour")   -- report.conflicts, report.skipped
print(Lighting.inspect(game.Lighting).requires_ok)             -- LightingStyle set by the owner?
Lighting.apply(game.Lighting, Lighting.blend("bright_noon", "storm_dim", 0.4))
```

## Materials (material-library/1)

`assets/material-library.json` names 15 neutral materials (soil, grass, rock, sand, concrete, plaster, brick, planks, wood, metal plate, painted metal, tile, fabric, asphalt, emissive panel). Tier 0 is free and needs no upload: `Materials.overridePlan(library)` plus `Materials.applyOverrides(MaterialService, plan)` switch a built-in material place-wide to an existing MaterialVariant with `SetBaseMaterialOverride`. Tier 1 needs uploaded maps (game repo): `buildVariant` sets the scriptable properties and lists pending map slots; BaseMaterial and maps need plugin security, so build variants through `execute_luau`. Map rules: OpenGL normals (DirectX names are rejected), power-of-two resolution, 1024 by default, 2048 only with a written reason, never above.

## Budgets per device class (perf/1)

`SceneKit/Budgets.check(stats, class)` returns violations with their kind and class; a counter missing from the stats is reported as missing, never as 0.

| Counter | phone_low | phone | tablet | desktop | console | Kind |
|---|---|---|---|---|---|---|
| frame ms (p95) | 33.3 | 20 | 20 | 16.7 | 16.7 | convention (16.67 ms at 60 FPS documented) |
| instances | 30000 | 50000 | 60000 | 120000 | 100000 | convention |
| memory MB (total) | 900 | 1500 | 2000 | 3000 | 2500 | convention (most Android players have 2-4 GB) |
| parts | 6000 | 12000 | 15000 | 25000 | 25000 | convention |
| triangles | 300k | 600k | 750k | 1M | 1M | documented for desktop/console ("below 1,000,000 triangles"), convention below |
| shadow-casting lights | 4 | 8 | 8 | 16 | 16 | convention |
| particle rate (/s, total) | 300 | 600 | 800 | 1500 | 1500 | convention (per emitter 400 documented, 100 on mobile) |
| playing sounds | 16 | 24 | 32 | 32 | 32 | convention (voices total <= 64) |
| active Highlights | 2 | 4 | 8 | 8 | 8 | convention (255 documented; about 1 ms for the first on mobile) |
| texture estimate (MB) | 192 | 384 | 512 | 1024 | 1024 | convention |
| post effects | 1 | 2 | 3 | 4 | 4 | convention |

Light rules in `Validate`: range above 120 studs is an error (engine cap, DevForum 2025-09-23); above 60 is a warning (budget); more than 4 lights or more than 1 shadow-casting light per room are warnings.

## Visual effects (vfx/1)

A preset is burst or loop data: emitters, beams, trails, lights and an optional Highlight, with palette roles (`accent`, `positive`, `negative`, `neutral`, `bright`, `special`, `surface`) instead of colours and texture roles (`spark`, `soft`, `smoke`, `ring`, `streak`, `confetti`, `glow`, `beam`) instead of asset ids. Only `sparkles_main.dds` and `SquareParticle.png` are known built-ins; a game maps roles to its approved textures through `Vfx.build(preset, env, { palette, textures })`.

Validator: rate above 400/s, lifetime above 20 s, flipbook above 30 fps or not a multiple of the layout, light range above 120 and raw asset ids are problems; rate above 100/s (mobile), more than 200 peak particles, overdraw above 400 (sum of peak particles x size squared), shadow-casting lights and Highlights are warnings. A burst must outlive its particles. Accessibility: `motion = true` presets skip under reduced motion; items with `flash = true` drop when flashes are off; `reduced = { drop, burstScale, rateScale, skip }` is the performance mode.

The 21 presets, all inside the conventions: `hit_spark`, `impact_dust`, `heal_glow`, `pickup_sparkle`, `levelup_burst`, `reward_burst`, `trail_basic`, `muzzle_flash`, `explosion_small`, `smoke_puff`, `splash`, `confetti`, `shield_bubble`, `teleport_ring`, `footstep_dust`, `speed_lines`, `aura_loop`, `spawn_in`, `despawn_out`, `charge_up`, `status_tick`. Each carries its intent; `sound` names an AudioCues cue.

```lua
local pool = VfxPoolRoblox.new(env, { parent = workspace.Effects, effective = Settings.effective(values) })
local handle = pool:play("shield_bubble", character.HumanoidRootPart)   -- loops follow Instances
RunService.PreRender:Connect(function(dt) pool:step(dt) end)
handle:stop()   -- emitters stop; the clone lingers until its particles fade, then is reused
```

## Audio (audio-graph/1)

Seven standard buses match settings/1 `volume.*`: master, music, sfx, ui, ambience, dialogue, world. Each bus is an AudioFader plus an ordered effects chain (AudioCompressor, AudioEqualizer, AudioReverb) feeding its parent; master feeds one AudioDeviceOutput and an AudioAnalyzer tap; `world` owns an AudioListener on the camera so 3D AudioEmitters reach the mix. `AudioGraph.validate` rejects cycles, orphan buses, missing standard buses and ducks by an ancestor; voices above 64 fail, above 32 warn.

- **Faders.** Master stays at its graph volume; each standard bus fader is graph volume x the settings/1 effective volume (which already includes the user's master) x the duck envelope x an optional AudioMixer channel gain.
- **Ducking.** Default mode `fader`: while a `by` bus has voices, the bus moves linearly to `amount` over `attack` and back over `release` (music to 0.4 and ambience to 0.6 under dialogue, conventions). Mode `sidechain` wires the `by` bus into the bus compressor's Sidechain pin.
- **Cues.** `AudioCues` admits voices: per-cue cooldown and maxConcurrent, bus and total voice caps with priority stealing, seeded volume and pitch variation, and `missing_asset` for any slot the game has not mapped to approved audio. 28 neutral default cues (UI, hits, pickups, rewards, footsteps, loops, dialogue).
- **Music.** `Music` starts the next track on the next beat or bar of the playing one and crossfades with equal-power curves; `AudioGraphRoblox` schedules it with `AudioPlayer:Play(atTime)`/`Stop(atTime)` on the mixer clock.
- **AudioDirector.** `mix:backend()` implements its backend, so its trace and `missing_asset` reporting stay.

3D note: for emitters to pass through the master fader, `SoundService.DefaultListenerLocation` should be None (read-only to scripts, set in Studio); `inspect()` reports it. Whether that is required is UNVERIFIED until the probes run.

## Game feel

| Module | Rule |
|---|---|
| `Spring` | closed form, so 60 steps of 1/60 s equal 30 of 1/30 s; damping ratio 1 never overshoots |
| `Shake` | offset = trauma^2 x maximum x hashed value noise, never above the maximum; scale by `shakeScale` (0 under reduced motion) |
| `HitStop` | one freeze at most 0.2 s, overlaps merge, at most 0.35 s frozen per rolling second |
| `Popups` | same key on the same anchor within 0.15 s merges; stacks without overlap; K/M/B; `+` on gains so meaning is not colour alone; no rise or pop under reduced motion |
| `Screen` | at most 3 flash starts in any rolling second (WCAG 2.3.1), extra flashes dropped; flash brightness capped at 0.5; reduce-flashing turns flashes into soft tints (0.12, at least 0.35 s); reduced motion drops FOV and blur punches |
| `Haptics` | verified types only (UIClick, GameplayCollision, GameplayExplosion, Custom); waveform clamped to 32 keys and 1000 ms; 50 ms between plays; off when `haptics` is false |
| `Cues` | one data cue fires VFX, sound, shake, hit-stop, haptic, flash, tint and popup; a sound needs a visual channel; at most 6 cues per frame, strongest first; `bindMarkers(track, { Hit = "hit_light" })` |

`FeelRoblox` applies them on the client: call `feel:step(dt)` from `BindToRenderStep` at `RenderPriority.Camera.Value + 1` so shake rides on top of the camera scripts.

## Day and night

`GameKit/WorldCycle` turns `Workspace:GetServerTimeNow()` into a clock (default 20-minute day, convention) so every client agrees without replication. Phases map clock hours to Lighting presets (night, dawn, morning, day, evening, dusk, late night) and blend over the last 0.75 h before each boundary; `ClockTime` always follows the clock. `setWeather("storm_dim", 0.8, 20, now)` ramps an overlay. `step` returns a state at most once a second unless the phase changes; apply it with `WorldCycle.apply(game.Lighting, state)`.

## Tuning and adding presets

1. Copy a preset (`Lighting.copy`, `VfxLibrary.get`, `AudioCues.defaults`, `Cues.defaults`) and edit it in the game repo; validators run on use.
2. A factory preset change is intended only when its digest moves: run `FACTORY_UPDATE_GOLDEN=av-presets lune run tests/run.luau avkit_presets` (or `python3 tools/check.py --update-golden=av-presets`) and say why in the commit.
3. Name new presets by function (`hit_spark`, `interior_warm`), never by theme.

## Limits and UNVERIFIED

- Lune has no ParticleEmitter:Emit, Model:PivotTo, AudioPlayer playback, Wire.Connected, AudioAnalyzer levels, MaterialService override methods or HapticEffect playback; adapters take `options.engine` overrides in specs, and the Studio probes are pending.
- The ranges of ColorCorrection, Bloom and DepthOfField and the mobile cost of each post effect are not published; AudioEqualizer and AudioReverb ranges here are conventions inside the engine ranges.
- Whether `AudioPlayer.Asset` accepts `rbxasset://sounds/...` built-ins (probe `av_audio_master_level` uses one; a run may pass an approved content string instead).
- The full HapticEffectType list; only the four types above are used.
- Stills prove looks, not motion: record motion on the owner's PC.
