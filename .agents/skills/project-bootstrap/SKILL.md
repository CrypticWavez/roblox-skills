---
name: project-bootstrap
description: Scaffold a new, separate Roblox game repository from the factory with tools/new_project.py - factory packages, Rojo project with empty src folders, pinned toolchain, Lune runner and starter spec, trimmed gate, CI, hooks, game-repo AGENTS.md/CLAUDE.md with every game-design field TBD - and pull later package updates with --update. Use only on an explicit game-build request naming a new game; never to pick a genre, theme or content.
---

# Project bootstrap

## Purpose
Turn an explicit game-build request into a new game repository that has the factory's verified infrastructure and none of its decisions: game content is filled in later from the request, never by the factory.

## Triggers
Only an explicit game-build request from the owner ("start the new game in <repo>", "create the repository for <game>"). Also: pulling factory package fixes into a game repo created by this starter. Not for exploring ideas, not for fixtures, and never on a guess that a game is wanted.

## Inputs
The destination directory (new or empty, outside this repo and outside any other git repository), the project name, optional extra packages (`Runtime`, `Creator`, `Diagnostics`), and whatever the request already decided (genre, theme, devices...) to log after scaffolding.

## Required context
`docs/starter.md` (what is copied, what stays, update flow); `tools/new_project.py` docstring; AGENTS.md Boundary (the factory never decides game content).

## Tools
- `python3 tools/new_project.py <dest> [--name NAME] [--packages ...]`: scaffold; prints the packages (with added dependencies) and the factory commit; writes `starter.json`.
- `python3 tools/new_project.py --update <game repo> [--packages ...] [--force]`: refresh `packages/` and `starter.json` from this factory.
- In the new repo: `rokit install`, `python3 tools/check.py` (StyLua, JSON, secrets, skills, hooks, Selene, Lune specs, Rojo build), `lune run tests/run.luau`, `rojo build default.project.json -o build/game.rbxl`.
- Gate step `starter-smoke` in this repo (`python3 tools/check.py`) proves the starter still produces a green repo.

## Procedure
1. Confirm the request is explicit and names where the repository goes; if not, ask. Do not choose a genre, theme, world, characters, economy or UI.
2. Run `python3 tools/new_project.py <dest> --name <Name>`; add `--packages Runtime` (or `Creator`, `Diagnostics`) only when the request needs them.
3. In `<dest>`: `rokit install`, then `python3 tools/check.py`; every step except a SKIPPED Selene (needs `selene generate-roblox-std`) must pass.
4. Copy decisions the request states into the `Game decisions` table of `<dest>/AGENTS.md` and a dated row in `<dest>/docs/decisions.md`; leave every other field TBD.
5. `git init`, commit, and give the owner the commands to create and push the remote; never publish the place or upload assets.
6. Updates later: commit and branch in the game repo, run `--update` from the factory, review `git diff`, run its gate.

## Outputs
A game repository with `starter.json` (factory commit, package sha256), a green gate run in it, the decisions log, and a short report: dest, packages, factory commit, gate result, TBD fields.

## Acceptance
`python3 tools/check.py` in the new repo reports PASS with only Selene skipped (none under `--strict` in CI); `lune run tests/run.luau` shows 0 failed; `starter.json` lists the packages; no game-design field was filled without a source in the request.

## Failure
- `refused: ... overlaps the factory` / `inside the git repository` / `not empty`: pick a new directory outside every repo; never force it into an existing game.
- `--update` refused for edited packages: move game logic out of `packages/` (into `src/`), or fix the bug in the factory first; use `--force` only when the owner accepts losing the local edit.
- Game gate fails right after scaffolding: run `python3 tools/check.py` here (`starter-smoke`) and fix the template or package in the factory, not in the game repo.
- Smoke hash mismatch in `tests/packages.spec.luau`: the copied packages no longer match the factory golden; re-run `--update` or investigate the package change.

## Related
roblox-scene-authoring, roblox-procedural-generation, roblox-studio-testing, roblox-luau-testing, luau-quality, roblox-release-pass.
