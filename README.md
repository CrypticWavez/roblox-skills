# Roblox production factory

Reusable, game-neutral tooling for building Roblox experiences with Claude Code and Codex: a scene-authoring API, seeded procedural layouts with validators, a headless Blender asset factory with QA and a Blender-to-Roblox round trip, Studio MCP guidance, skills, hooks and gates. **SETUP_ONLY**: nothing here starts a game, publishes, uploads or spends.

- Agents start at [AGENTS.md](AGENTS.md) (Claude also reads [CLAUDE.md](CLAUDE.md)).
- What works, what doesn't and what needs Ethan's PC: [docs/gap-matrix.md](docs/gap-matrix.md), generated from `reports/gap-matrix.json` (edit the JSON, then run `python3 tools/gap_matrix.py`).

## Quick start

```sh
rokit install                                  # rojo, lune, stylua, selene, luau-lsp (rokit.toml)
python3 tools/check.py                         # pre-commit gate (format, JSON, secrets, skills, hooks, lint, specs, fixtures)
lune run tools/lune/build_fixtures.luau build/fixtures   # five SETUP_ONLY places + manifests + report.json
python3 tools/blender/factory.py templates build/blender  # needs `pip install bpy` (3.13) or an installed Blender
python3 tools/check.py --tier pre-release      # adds Blender templates, round trip, QA self-test and previews
```

| Path | What |
|---|---|
| `packages/SceneKit` | buildings, props, paths, vegetation, terrain, lighting, cameras, measurement, validation, apply with undo |
| `packages/ProcGen` | RNG, graphs, grids, dungeon/cave/arena/settlement generators, layout validators, manifests |
| `packages/Pipeline` | Studio-side import inspector and the Studio smoke test |
| `packages/Runtime`, `Creator`, `Diagnostics` | modules inherited from the first pass |
| `tools/blender` | `factory.py` CLI and the `bkit` library |
| `tools/hooks`, `tools/check.py` | Claude Code hooks and the tiered gate |
| `.agents/skills` (mirrored to `.claude/skills`) | 19 task skills |
| `fixtures`, `tests` | Rojo projects, Lune specs, golden hashes |
| `docs`, `reports` | architecture, MCP, scene authoring, Blender, research, gap matrix |
