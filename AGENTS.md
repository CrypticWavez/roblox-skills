# Roblox production factory — agent instructions

Shared by Claude Code (via `CLAUDE.md`) and Codex. Keep this file short; detail lives in skills and docs.

## Boundary: SETUP_ONLY
This repo builds reusable tools, neutral fixtures and research. It does not start a game.
- Never choose a genre, theme, world, characters, economy or production UI.
- Never publish, upload assets, create live products, spend Robux, buy tools/assets, run ads or touch production data.
- Never modify Cryptic's Realm, other game repos, or `weppy-project-sync/`.
- Studio work targets an explicitly selected **unpublished diagnostic place**. Protected: published games, Noobs VS Zombies.
- A future game starts only from an explicit game-build request, in a separate repository.

## Where things are
| Need | Go to |
|---|---|
| Build environments (buildings, props, paths, terrain, lighting, measurement) | skill `roblox-scene-authoring`, `packages/SceneKit/` |
| Seeded layouts + validators (dungeon, cave, arena, settlement) | skill `roblox-procedural-generation`, `packages/ProcGen/` |
| Blender assets, QA, Roblox import round trip | skills `blender-asset-factory`, `blender-asset-qa`, `blender-roblox-roundtrip`, `tools/blender/` |
| Studio control and testing modes | skill `roblox-studio-testing`, `docs/mcp.md` |
| Seeing results | skill `visual-qa` |
| Gates and hooks (Claude and Codex) | skill `luau-quality`, `tools/check.py`, `tools/hooks/`, `.codex/`, `docs/mcp.md` |
| Capability status and open gaps | `reports/gap-matrix.json` (canonical: edit this, then `python3 tools/gap_matrix.py`); `docs/gap-matrix.md` is generated, never hand-edited |
| Inherited first-pass runtime/creator/diagnostic modules | `packages/Runtime`, `packages/Creator`, `packages/Diagnostics`, `fixtures/` |
| Research | `docs/research/`, `knowledge/records/` |
| New game repository (explicit game-build request only) | skill `project-bootstrap`, `tools/new_project.py`, `docs/starter.md` |

Skills live in `.agents/skills/` (Codex) and are mirrored to `.claude/skills/` (Claude) by `python3 tools/sync_skills.py`. Edit only `.agents/skills/`.

## Working rules
- Read the skill for the task, not the whole repo. Retrieve with `rg`/Grep; manifests and reports are JSON.
- Plans are data: author with SceneKit/ProcGen/bkit code, validate, then apply. No one-off Studio scripts for basic construction.
- Same seed ⇒ same manifest hash. Hash changes must be intended (`python3 tools/check.py --update-golden`).
- Before committing: `python3 tools/check.py` (pre-commit tier). Before a PR is ready: `--tier pre-release`.
- New Luau logic gets a Lune spec in `tests/`. Never skip or weaken a test or validation rule to get green.
- One writer per Studio session and per Blender session. One agent owns a file set at a time (see `docs/architecture.md`).
- No secrets in files, logs or records. The `tools/hooks` guards block publishing, uploads, spending, force-pushes to main and protected-folder writes, in Claude Code (`.claude/settings.json`) and in Codex (`.codex/`, once the project and its hooks are trusted; Codex denies what Claude asks). Do not work around them; residual gaps are in `docs/mcp.md`.

## Verification language
VERIFIED_STRONG, VERIFIED_ACCEPTABLE, WEAK, PARTIAL, BROKEN, MISSING, OUTDATED, REDUNDANT, BLOCKED_EXTERNAL, INTENTIONALLY_EXCLUDED. Verified means a representative execution produced observed output in this session or CI. Files, docs, configs, listed MCP servers or screenshots alone are not verification. Fixture passes do not prove fun, commercial success or device coverage.
