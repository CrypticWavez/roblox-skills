# Roblox production factory

Reusable, game-neutral tooling for building Roblox experiences of any genre with Claude Code and Codex: runtime kits (gameplay, economy, platform services, UI and cutscenes, lighting, VFX, audio and game feel) with Studio probes, a scene-authoring API, seeded procedural layouts and courses with validators, genre playbooks, a headless Blender asset factory with bakes, clips, QA and a Blender-to-Roblox round trip, a game-repo starter with a release checker, Studio MCP guidance, skills, hooks and gates. **SETUP_ONLY**: nothing here starts a game, publishes, uploads or spends.

- Agents start at [AGENTS.md](AGENTS.md) (Claude also reads [CLAUDE.md](CLAUDE.md)).
- What works, what doesn't and what needs the owner's PC: [docs/gap-matrix.md](docs/gap-matrix.md), generated from `reports/gap-matrix.json` (edit the JSON, then run `python3 tools/gap_matrix.py`).

## Quick start

```sh
rokit install                                  # rojo, lune, stylua, selene, luau-lsp (rokit.toml)
python3 tools/check.py                         # pre-commit gate (see Gate below)
lune run tools/lune/build_fixtures.luau build/fixtures   # eleven SETUP_ONLY places + manifests + report.json
python3 tools/blender/factory.py templates build/blender  # needs `pip install bpy` (3.13) or an installed Blender
python3 tools/check.py --tier pre-release      # adds Blender templates, kits, round trip, QA self-test, previews, luau-lsp
```

## Gate

`tools/check.py` is the one gate Claude, Codex, the git hook and CI run (skill `luau-quality` has the details and failure fixes).

| Tier | Runs | Time |
|---|---|---|
| FAST_ON_EDIT | Claude hook on the edited file: format, JSON, secrets, SKILL.md rules | < 1 s |
| PRE_COMMIT (`python3 tools/check.py`) | StyLua, JSON, secret scan, skills sync, gap matrix, Markdown links and URLs, [knowledge index](knowledge/INDEX.md) and record scopes, [fixtures README](fixtures/README.md), asset ids against [`assets/provenance.json`](assets/provenance.json), Rojo sourcemaps of every fixture project, a self-test of those content checks, hook self-test, Selene, Lune specs, fixture hashes, Python unit tests, playbook lint, CC0 asset sources, luau definitions lock, kit tiers, capture staleness, starter smoke | about a minute |
| PRE_RELEASE (`--tier pre-release`) | pre-commit plus Blender templates, round trip, QA self-test, material library, kit/1 bake, glTF validation, previews, luau-lsp analysis and the full starter smoke | minutes |

A SKIPPED step (tool missing) fails the run unless it is Selene, whose Roblox std needs network, or luau-lsp analysis without the pinned binary; `--strict` (CI) allows no skips. `--update-golden=<name>` rewrites only the named golden; bare `--update-golden` rewrites all of them. `--live-links` also requests every external URL; it is opt-in and never runs in CI.

| Path | What |
|---|---|
| `packages/GameKit` | gameplay, economy, platform services, AI, input map and the kit foundation ([docs/runtime-kits.md](docs/runtime-kits.md)) |
| `packages/UIKit`, `Cinematics` | UI tokens, components, transitions, audits, gallery; cutscenes and camera paths |
| `packages/AVKit`, `Feel` | VFX library and pooling, audio graph and cues, music; springs, shake, hit-stop, popups, haptics |
| `packages/SceneKit` | buildings, props, paths, vegetation, terrain, lighting presets, materials, budgets, kit pieces, cameras, measurement, validation, apply with undo |
| `packages/ProcGen` | RNG, graphs, grids, dungeon/cave/arena/settlement/forest generators, obby/tower/race/lane/arena courses, layout validators, manifests |
| `packages/Pipeline` | Studio-side import inspector, kit smoke harness, capture plans and the Studio smoke test |
| `packages/Runtime`, `Creator`, `Diagnostics` | modules inherited from the first pass |
| `tools/blender` | `factory.py` CLI and the `bkit` library (templates, bakes, clips, kit/1, intake) |
| `tools/new_project.py`, `templates/starter` | the game-repo starter with boot skeleton, release checker and production pipeline |
| `templates/starter/tools/monetize.py`, `store_art.py`, `store_page.py`, `ad_kit.py`, `store_publish.py` | every game's shop plan, store art, store page text, Ads Manager plan (never bought) and owner-approved store setup through Open Cloud (never spends) ([docs/monetization.md](docs/monetization.md)) |
| `tools/hooks`, `tools/check.py` | Claude Code hooks and the tiered gate |
| `.agents/skills` (mirrored to `.claude/skills`) | 23 task skills |
| `fixtures`, `tests` | Rojo projects, Lune specs, golden hashes |
| `docs`, `reports` | architecture, runtime kits, kit guides, MCP, scene authoring, presentation, Blender, starter, PC setup, research, gap matrix |
