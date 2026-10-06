# Factory architecture

## Layers
| Layer | What | Runs in | Verified by |
|---|---|---|---|
| Plans (pure Luau) | `packages/SceneKit`, `packages/ProcGen`, `packages/Pipeline` | Lune, Studio, CI | `lune run tests/run.luau`, fixture hashes |
| Apply (Roblox side) | `SceneKit.Apply` (Instances, ChangeHistory undo), `Apply.terrain` | Studio (and Lune DataModel for .rbxlx) | Lune DataModel tests; Studio smoke (`fixtures/factory`) |
| Assets | `tools/blender/bkit` (ops, templates, qa, render, roundtrip) | bpy wheel or Blender | `factory.py templates`, `roundtrip` |
| Observation | Blender renders of manifests/assets, Studio `screen_capture`, manifest diffs | Cycles CPU / Studio | images reviewed per change |
| Inherited first pass | `packages/Runtime`, `Creator`, `Diagnostics`, `fixtures/*.project.json` | Studio | first-pass receipts (see gap matrix) |
| Agent layer | `AGENTS.md`, `CLAUDE.md`, `.agents/skills` -> `.claude/skills`, `.claude/agents`, hooks, `.mcp.json` | Claude Code + Codex | `tools/check.py` (skills-sync, hooks-selftest) |

## Context budget
- Permanent instructions: `AGENTS.md` (~50 lines) + `CLAUDE.md` (~10 lines).
- Task context: one skill (each < 80 lines) plus the module header it names. Every SKILL.md has the same ten `##` sections (Purpose, Triggers, Inputs, Required context, Tools, Procedure, Outputs, Acceptance, Failure, Related); `tools/sync_skills.py --check` enforces them with the frontmatter rules.
- Everything else is retrieved on demand (`rg`, JSON reports). Large legacy checklists live in skill `references/` and load only for that task.
- Deterministic tools (generators, validators, QA) produce compact JSON so agents read summaries, not raw scenes.

## Ownership (parallel agents)
| Area | Owner | Others |
|---|---|---|
| `packages/**`, `tests/**`, `tools/lune/**` | roblox-engineer | read |
| `tools/blender/**`, Blender session | technical-artist | read; never connect a second Blender client |
| `.agents/skills/**`, `AGENTS.md`, `CLAUDE.md`, `docs/**` | coordinator (main session) | propose via the coordinator |
| `docs/research/**` | researcher | read |
| Studio MCP session | coordinator only | none |
| Verification | qa-reviewer (read-only) | — |

## Claude vs Codex
Both read `AGENTS.md`. Codex discovers `.agents/skills`; Claude discovers `.claude/skills` (mirrored copy, checked in CI). Subagents are Claude-only; every gate is also a plain command (`tools/check.py`) Codex can run. The publish/spend/force-push/protected-folder guards run in both: Claude through `.claude/settings.json`, Codex through `.codex/hooks.json` (same `tools/hooks` scripts) plus `.codex/rules/factory.rules` and `.codex/config.toml` (sandbox, MCP servers, prompted tools). Parity is partial: Codex hooks cannot ask, so asks become denies there; they run only after the project and each hook are trusted (`/hooks`); a failing or timed-out hook lets the call run in either client. Details and checks: `docs/mcp.md` ("Codex").
