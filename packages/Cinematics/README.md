# Cinematics

Data-driven cutscenes and camera paths in the cinematics/1 format: validation, deterministic sampling, events, hold-to-skip, letterbox, fades and subtitles, bake and digest, splines with arc-length timing, and a Studio player. Neutral fixtures only.

Guide: [docs/uikit.md](../../docs/uikit.md#cinematics). Owner: G4. Contract and tiers: [docs/runtime-kits.md](../../docs/runtime-kits.md).

| Module | Tier | What |
|---|---|---|
| `Cinematics` | T0 | `validate`, `define`, `sample`, `eventsBetween` (`t0 < t <= t1`), `skipEvents`, `reduce`, `bake`, `digest`, `player` |
| `Spline` | T0 | centripetal Catmull-Rom, Bezier, arc-length tables |
| `CinematicsRoblox` | T3 | `play` on a Camera from RunService.PreRender with an overlay and IAS skip; `keyFromCamera` for authoring (probe `cin_play_sample`) |

Specs: `lune run tests/run.luau cinematics` (golden `tests/golden/cinematics-orbit.json` from `fixtures/kits/shared/cin_setup_only_orbit.luau`).
