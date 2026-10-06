# Project starter: from a game-build request to a new repository

The factory never decides game content. `tools/new_project.py` turns an explicit game-build request into a separate game repository that holds infrastructure only; every game-design field in its `AGENTS.md` starts as TBD (skill `project-bootstrap`).

```
python3 tools/new_project.py <dest> [--name NAME] [--packages SceneKit ProcGen Pipeline ...]
cd <dest> && git init && rokit install && python3 tools/check.py   # then commit, push to a new repo
```

## What is copied
| In the game repo | Source |
|---|---|
| `packages/SceneKit`, `ProcGen`, `Pipeline` (default) | factory `packages/` byte for byte (LF); packages they require are added automatically. `Runtime`, `Creator`, `Diagnostics` only with `--packages` (first-pass modules, Studio halves only partly re-verified; commerce and UI are game decisions) |
| `default.project.json`: packages under `ReplicatedStorage.Workbench` (same path as the factory's projects and skills), empty `src/shared`, `src/server`, `src/client` | `templates/starter/` |
| `rokit.toml`, `stylua.toml`, `selene.toml`, `tests/run.luau`, `tools/sync_skills.py`, `tools/hooks/*` | factory, verbatim |
| `.claude/settings.json` (hooks, permissions; allow rules for factory-only scripts dropped), `.mcp.json` (`Roblox_Studio` only), `.codex/config.toml` (same sandbox and approvals, `Roblox_Studio` only) | generated from the factory's files |
| `.codex/hooks.json`, `.codex/rules/factory.rules` (the same guards for Codex; they find the repo root with git, so `git init` first) | factory, verbatim |
| `tests/packages.spec.luau` (every copied module loads; ProcGen/SceneKit determinism; Pipeline smoke hashes equal the factory's Studio-verified golden), `tools/check.py` (trimmed gate: StyLua, JSON, secrets, skills, hooks, Selene, Lune, Rojo build), `.github/workflows/ci.yml` (`--strict`), `.gitignore`, `.gitattributes`, `AGENTS.md`/`CLAUDE.md` (safety rules; game decisions TBD), `docs/decisions.md`, `README.md` | `templates/starter/` (`{{NAME}}`, `{{CREATED}}` filled; `.tmpl` keeps the game's instruction files from loading inside the factory) |
| 14 game-facing skills, mirrored to `.claude/skills` | factory `.agents/skills/` (list in `SKILLS`) |
| `starter.json`: factory repository, commit, `packages_dirty`, per-package sha256 and file count, skills, smoke hashes | generated |

## What stays in the factory
Blender tooling and its skills, research records (`docs/research/`, `knowledge/`, skill `roblox-research`), fixtures and goldens, the gap matrix, the factory gate (skill `luau-quality`) and this starter (skill `project-bootstrap`). Copied skills that name those paths mean the factory checkout at the commit in `starter.json`.

## Pulling factory updates
1. In the game repo: commit, then `git switch -c factory-update`.
2. In the factory: `python3 tools/new_project.py --update <game repo> [--packages ...]`. It replaces `packages/<name>` with the factory's copy, adds requested packages, and rewrites `starter.json` (commit, hashes, smoke). It refuses with uncommitted changes, or when a package was edited in the game repo (hash differs from `starter.json`); `--force` overrides both.
3. Review `git diff`, run `python3 tools/check.py`, merge. Templates, hooks and skills are one-time copies: to see their changes, scaffold a fresh repo into a temp directory and `diff -r` it with the game repo.

## Safety
Refuses a dest inside the factory, inside another git repository, or non-empty (a lone `.git` from a freshly created empty repository is allowed); never runs a git command that writes; publishes, uploads and buys nothing. The game repo keeps the factory's guards: no publishing, uploads, live products, spending or production data writes without the owner's explicit approval, and decisions are logged in `docs/decisions.md`.

## Verification
Gate step `starter-smoke` (pre-commit, about 5 s): scaffolds into a temp dir, runs the new repo's own pre-commit gate (StyLua, Lune specs and `rojo build` must PASS), then checks both refusals and `--update` (no-op on a fresh copy, refused after a package edit). A package syntax error, a changed generator default (smoke hash mismatch), a broken Rojo path, a broken gate template and an unknown template placeholder each make it FAIL. The generated CI workflow has not run on GitHub yet.
