---
name: project-bootstrap
description: Scaffold a new, separate Roblox game repository from the factory with tools/new_project.py - factory packages by class (authoring, kits, legacy) in a working Rojo layout, a phased boot skeleton with loading screen, the game gate (fast, pre-commit, pre-release), the release checker, the production pipeline (brief, stages, issue drafts), pinned optional dependencies, CI, hooks and skills, with every game-design field TBD - and refresh it later with --update. Use only on an explicit game-build request naming a new game; never to pick a genre, theme or content.
---

# Project bootstrap

## Purpose
Turn an explicit game-build request into a new game repository that has the factory's verified infrastructure and none of its decisions, ready on day one to build any genre: boot phases, loading and error handling, gate and CI, release checklist, production stages. Game content is filled in later from the request or the owner, never by the factory.

## Triggers
Only an explicit game-build request from the owner ("start the new game in <repo>", "create the repository for <game>"). Also: pulling factory fixes (packages, skills, hooks, gate, checker, boot runner) into a game repo created by this starter. Not for exploring ideas, not for fixtures, and never on a guess that a game is wanted.

## Inputs
The destination directory (new or empty, outside this repo and outside any other git repository), the project name, the packages (default: authoring `SceneKit ProcGen Pipeline` plus kits `GameKit UIKit Feel Cinematics AVKit`; legacy `Runtime Creator Diagnostics` are opt-in; `--packages` replaces the list), optional dependency bundles (`--deps persistence studio-tests networking`), and whatever the request already decided, to record after scaffolding.

## Required context
`docs/starter.md` (layout, managed files, dependency policy, update flow); `tools/new_project.py` docstring; `docs/runtime-kits.md` (package classes, tiers, module names); AGENTS.md Boundary (the factory never decides game content).

## Tools
- `python3 tools/new_project.py <dest> [--name NAME] [--packages ...] [--deps ...]` (or `--out <dest>`); `--list` prints classes, bundles and skills. Writes `starter.json` (starter/2: packages and classes, every module's tier and probe, pending Studio probes, skills, managed-file hashes, bundles).
- `python3 tools/new_project.py --update <game repo> [--packages ...] [--deps ...] [--force]`: refresh packages, skills, hooks and managed files; merge Rojo package folders and rokit pins.
- In the new repo: `git init`, `rokit install`, `python3 tools/check.py`, `python3 tools/production.py status`, `python3 tools/release_check.py`.
- `python3 tools/starter_smoke.py` and the factory gate step `starter-smoke` prove the starter still produces a green repo.

## Procedure
1. Confirm the request is explicit and names where the repository goes; if not, ask. Do not choose a genre, theme, world, characters, economy or UI.
2. Run `python3 tools/new_project.py <dest> --name <Name>`; the defaults suit most requests; `--packages` replaces the list, so give the full set (e.g. the defaults plus `Runtime`) when the request needs a different one (dependencies are added) and `--deps` bundles only when the request needs them. Never run `wally install` yourself: print the owner's command.
3. In `<dest>`: `git init` (the Codex hooks find the repo root with git), `rokit install`, `python3 tools/check.py`; every step must pass except a SKIPPED Selene (needs `selene generate-roblox-std`) and, with `--deps`, `deps` until the owner installs and commits `wally.lock`.
4. Record decisions the request states: `production/brief.json`, the `AGENTS.md` tables (same values; step `brief` compares them) and a dated row in `docs/decisions.md`. Leave every other field TBD; the stage stays concept.
5. Commit, and give the owner the commands to create and push the remote. Next work follows skill roblox-production-pipeline. Never publish the place or upload assets.
6. Updates later: commit and branch in the game repo, run `--update` from the factory, review `git diff`, run its gate.

## Outputs
A game repository with `starter.json`, a green gate run in it, the decisions log, and a short report: dest, packages by class, modules and pending probes, bundles and owner steps, factory commit, gate result, TBD fields.

## Acceptance
`python3 tools/check.py` in the new repo reports PASS (Selene the only allowed SKIPPED outside CI); `lune run tests/run.luau` shows 0 failed (boot, layout and packages specs); `rojo build default.project.json` succeeds; `python3 tools/release_check.py` runs and reports every S/O/P item OWNER_REQUIRED; no game-design field was filled without a source in the request.

## Failure
- `refused: ... overlaps the factory` / `inside the git repository` / `not empty`: pick a new directory outside every repo; never force it into an existing game.
- `--update` refused for edited packages, skills or managed files: move game logic to `src/` and game skills to new names, or fix the factory first; `--force` only when the owner accepts losing the local edit.
- Game gate fails right after scaffolding: fix the template or package in the factory (`python3 tools/starter_smoke.py` reproduces it), not in the game repo.
- `skills-packages` names a module missing from an installed kit: the skill cites a module its group has not delivered; fix the skill or the kit in the factory.

## Related
roblox-production-pipeline, roblox-release-pass, roblox-scene-authoring, roblox-procedural-generation, roblox-studio-testing, roblox-luau-testing, luau-quality.
