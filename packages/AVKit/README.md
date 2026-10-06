# AVKit

Audio and visual effects as data: the vfx/1 preset format with a neutral library and pooling, and the audio-graph/1 mixer (buses, cues, ducking, music scheduling) on the Audio API. Pure validators and plans run in Lune; `*Roblox.luau` adapters build and drive the Instances. Guide: [docs/presentation.md](../../docs/presentation.md). Contract and tiers: [docs/runtime-kits.md](../../docs/runtime-kits.md).

Owner: G5 (look, sound and feel).

| Module | Tier | What it does |
|---|---|---|
| `Vfx` | T1 | vfx/1: validate (engine limits are problems, mobile budgets warnings), budget (peak particles, overdraw), plan (reduced effects, reduced motion, reduce-flashing), build (template Model on `@lune/roblox`) |
| `VfxLibrary` | T0 | 21 neutral presets named by function, palette roles instead of colours, texture roles instead of ids |
| `Pool` | T0 | bounded, priority-admitted pooling (moved from `Creator/EffectsPool`, opened: caller field schemas, keyed idle lists, `expire`) |
| `VfxPoolRoblox` | T3 (probe `av_vfx_grid`) | plays presets: clone, pivot, emit on schedule, light fades, follow, linger, Highlight adornee |
| `AudioGraph` | T1 | audio-graph/1: seven standard buses, effects chains, ducking, voice caps; validate (acyclic, every bus reaches master), plan, build, fader runtime |
| `AudioCues` | T0 | cue admission: cooldown, maxConcurrent, bus and total voice caps with priority stealing, missing_asset, seeded variation |
| `Music` | T0 | quantized starts on beat or bar, equal-power crossfades, mixer-clock schedule |
| `AudioGraphRoblox` | T3 (probes `av_audiograph_wires`, `av_audio_master_level`) | builds the graph, plays voices, writes fader automation, schedules music, reads the master analyzer, AudioDirector backend |
| `AudioMixer`, `AudioDirector` | T0 | moved from `Runtime/AudioMixer` and `Creator/AudioDirector` (shims keep the old paths) |

Lune specs: `tests/avkit_vfx.spec.luau`, `tests/avkit_pool.spec.luau`, `tests/avkit_audio.spec.luau`, `tests/avkit_presets.spec.luau` (golden `tests/golden/av-presets.json`), `tests/avkit_probes.spec.luau`.
