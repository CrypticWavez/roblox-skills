# Feel

Game feel: closed-form springs, trauma shake, hit-stop, damage-number popups, rate-limited screen flashes, haptics and data-defined cues that fire VFX, audio, shake and hit-stop together. Honours the settings/1 reduced-motion, reduce-flashing and haptics flags. Guide: [docs/presentation.md](../../docs/presentation.md). Contract and tiers: [docs/runtime-kits.md](../../docs/runtime-kits.md).

Owner: G5 (look, sound and feel).

| Module | Tier | What it does |
|---|---|---|
| `Spring` | T0 | closed-form damped spring (damping ratio, frequency in Hz); frame-rate independent; numbers or tables |
| `Shake` | T0 | trauma shake with seeded hashed value noise; presets hit_light, hit_heavy, blast, land, rumble; `shakeScale` (0 under reduced motion) |
| `HitStop` | T0 | freeze windows clamped to 0.2 s, merged, capped at 0.35 s per rolling second (conventions) |
| `Popups` | T0 | aggregate same-key hits, stack per anchor, K/M/B formatting, `+` for gains, no rise or pop under reduced motion |
| `Screen` | T0 | flashes (at most 3 per rolling second, WCAG 2.3.1), soft flashes under reduce-flashing, tints, vignette, FOV and blur punches (dropped under reduced motion) |
| `Haptics` | T0 | HapticEffect patterns: validate, clamp waveforms, rate limit, off when `haptics` is false |
| `Cues` | T0 | one cue across every channel; a sound needs a visual channel; per-frame budget; animation marker binding |
| `FeelRoblox` | T3 (probe `feel_marker_cue`) | the client adapter: camera shake and FOV, AnimationTrack hit-stop, owned ColorCorrection and Blur, edge vignette, pooled BillboardGui popups, haptics |

Lune specs: `tests/feel.spec.luau`, `tests/feel_roblox.spec.luau`; probes run from `tests/avkit_probes.spec.luau` against fakes.
