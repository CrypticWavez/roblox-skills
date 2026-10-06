# Project starter: from a game-build request to a new repository

The factory never decides game content. [tools/new_project.py](../tools/new_project.py) turns an explicit game-build request into a separate game repository that holds infrastructure only: a working Rojo layout for the factory packages, a phased boot skeleton, the game gate, a release checker, a production pipeline and pinned optional dependencies. Every game-design and engine field starts as TBD (skill `project-bootstrap`; afterwards skill `roblox-production-pipeline` runs the stages).

```
python3 tools/new_project.py <dest> [--name NAME] [--packages PKG ...] [--deps BUNDLE ...]   # or --out <dest>
python3 tools/new_project.py --list                                                        # classes, bundles, skills
cd <dest> && git init && rokit install && python3 tools/check.py                           # then commit, push to a new repo
```

## Package classes and the Rojo layout

| Class | Packages | Rojo home | Why |
|---|---|---|---|
| authoring | SceneKit, ProcGen, Pipeline (the default) | `ServerStorage.Authoring` | plans, generators and import checks run on the server or in Studio; never replicated to clients |
| kits | GameKit, UIKit, Feel, Cinematics, AVKit (`--packages`) | `ReplicatedStorage.Kits`, plus the leaf copies `Kits/ProcGen/{Rng,Grid,Graph}` and `Kits/SceneKit/{Vec,Lighting}` | both sides require kits; the leaves are the same files mapped a second time so `require("../ProcGen/Rng")` resolves ([runtime-kits.md](runtime-kits.md) section 8) |
| legacy | Runtime, Creator, Diagnostics (opt-in) | `ReplicatedStorage.Kits`, beside the kits | first-pass modules that require kits (`../GameKit/Env`, the AVKit and UIKit shims) and each other; one folder keeps every relative require resolving and each module single. `--update` removes a `ReplicatedStorage.Legacy` folder left by an older starter/2 repo |

Packages a chosen package requires are added. The rest of `default.project.json`: `ReplicatedFirst.Loading` (`src/first`), `ReplicatedStorage.Shared` (`src/shared`) and optional `Packages`, `ServerScriptService.Server` (`src/server`), `ServerStorage.Assets` (`src/assets`) and optional `ServerPackages`, `StarterPlayerScripts.Client` (`src/client`), `StarterGui` (`src/gui`), `LocalizationService.GameStrings` (`src/localization/strings.csv`). No FilteringEnabled property. `DEFAULT_PACKAGES` is the authoring packages plus all five kits (GameKit, UIKit, Feel, Cinematics, AVKit); pass `--packages` to take fewer.

## Boot skeleton

`src/shared/Boot.luau` (T0, factory-managed) runs the phases config, kits, data, remotes, telemetry, ui and input, each on its own thread with a timeout (`Boot.DEFAULT_TIMEOUT` = 10 s, a convention; `Config.boot.timeouts` overrides). The first failure or timeout stops later phases, cleanups run in reverse, and the result is a `boot-report/1` table printed as one `BOOT_REPORT {json}` line. The server runs config, kits, data, remotes and telemetry; the client config, kits, remotes, ui and input. `src/shared/KitLoader.luau` finds optional kit modules under `ReplicatedStorage.Kits` and fails only for kits `Config.kits.required` names, so the repo builds and boots with no kit installed; until the kits merge it references only the Stage 0 modules (`GameKit/Check`, `Signal`, `Scope`, `Fsm`, `Env`, plus `Settings` for motion preferences). `src/shared/Config.luau` has every field TBD (a TBD data or telemetry switch boots without that layer; a decided one fails loudly until it is wired). The client publishes `BootProgress`/`BootState`/`BootFailedPhase` attributes for the neutral loading screen in `src/first/Loading.client.luau` (localisation keys, reduced motion respected, a slow and a failed state). The engine run of this sequence is release item S07, pending on the owner's PC (T3).

## What else the game repo gets

| In the game repo | Source |
|---|---|
| `tools/check.py` (gate tiers fast, pre-commit, pre-release; steps include skills-packages, brief, deps, blink only when a `.blink` file exists, asset-provenance), `tools/release_check.py`, `tools/production.py`, `tools/plan_issues.py` | `templates/starter/tools/` |
| `tests/boot.spec.luau` (phase order, failure stop, timeout, cleanup, kit loading, both sides' phases with fakes), `tests/layout.spec.luau` (builds the place, deserialises it with `@lune/roblox`, resolves every static require), `tests/packages.spec.luau` (every module recorded with its tier, Lune-loadable modules load, ProcGen/SceneKit/Pipeline/GameKit behaviour) | `templates/starter/tests/` |
| `production/brief.json` (game-brief/1, all TBD), `production/pipeline.json` (stages concept, greybox, vertical-slice, alpha, beta, release-candidate with exit gates), `docs/design/*.md` (prompts only), `docs/production-plan.md`, `.github/ISSUE_TEMPLATE/{system,asset,bug,playtest}.yml` | `templates/starter/` |
| `release/release.json` (release-meta/1, TBD), `release/perf/budgets.json`, `docs/release-runbook.md` (generated from the checklist), `src/shared/telemetry.json`, `assets/provenance.json` | `templates/starter/` |
| `AGENTS.md` (game-decision and engine-setting tables with a Brief key column, all TBD), `CLAUDE.md`, `docs/decisions.md`, `README.md`, `.gitignore`, `.gitattributes`, CI (`--strict`; a dispatchable pre-release tier) | `templates/starter/` (`{{NAME}}`, `{{CREATED}}` filled; `.tmpl` keeps the game's instruction files from loading inside the factory) |
| `rokit.toml` (factory pins plus bundle tools), `stylua.toml`, `selene.toml`, `tests/run.luau`, `tools/sync_skills.py`, `tools/hooks/*`, `.codex/hooks.json`, `.codex/rules/factory.rules` | factory, verbatim |
| `.claude/settings.json`, `.mcp.json` (`Roblox_Studio` only), `.codex/config.toml` | generated from the factory's files |
| 17 game-facing skills (`SKILLS`, including roblox-gameplay-kit, roblox-presentation-pass, roblox-production-pipeline and roblox-release-pass), mirrored to `.claude/skills` | factory `.agents/skills/` |
| `starter.json` (starter/2): factory repository and commit, packages with class and sha256, every module's tier, Lune flag and probe, the pending Studio probes, skills and managed files with sha256, dependency bundles, smoke hashes | generated |

## Release readiness (owner-only publishing)

[release_check.py](../templates/starter/tools/release_check.py) writes `release/report.json` (release-check/1). Items A01-A17 are automated (project hygiene and engine settings, RemoteGuard, catalog/1 in mode game with owner-verified ids, one receipt handler, paid random items, text filtering, motion and flash settings, telemetry catalog and onboarding funnel, perf/1 within budget, asset provenance, localisation keys, debug tools off, deprecated APIs, store text, persistence boundaries, publish tripwire, release metadata and store-art specs). Items S01-S07 (Studio), O01-O15 (account, maturity questionnaire, audience, genre and devices, products, icon, thumbnails and video, badges, passes, friend-invite message, localisation settings, social links, publish, after publish) and P01-P03 always report OWNER_REQUIRED; the owner signs them in `release/owner-*.json`, which shows as `owner_record` and never as PASS. The full list with specs and Roblox sources is the generated [release runbook](../templates/starter/docs/release-runbook.md). Fixtures: [fixtures/release](../fixtures/release/README.md).

## Dependencies (optional, pinned)

`--deps persistence` (ProfileStore 1.0.3, server realm, Apache-2.0), `studio-tests` (Jest Lua 3.10.0 and JestGlobals, dev realm, MIT; `studio-tests.project.json` maps `DevPackages` and `tests/studio`) and `networking` (Blink CLI 0.18.9 in `rokit.toml`) come from the allowlist [deps.json](../templates/starter/deps.json). The starter writes `wally.toml` (`private = true`, exact `=x.y.z` pins in the right realm table), `THIRD_PARTY_NOTICES.md` (licences; Apache-2.0 notice text for ProfileStore) and the rokit pins (Wally 0.3.2). It never runs `wally install`: it prints the owner's command, and the gate step `deps` stays red until the owner commits `wally.lock` (committed-lockfile policy). Server-only packages map to `ServerStorage.ServerPackages`.

## What stays in the factory
Blender tooling and its skills, research records (`docs/research/`, `knowledge/`, skill `roblox-research`), fixtures and goldens, the gap matrix, the factory gate (skill `luau-quality`) and this starter (skill `project-bootstrap`). Copied skills that name those paths mean the factory checkout at the commit in `starter.json`.

## Pulling factory updates
1. In the game repo: commit, then `git switch -c factory-update`.
2. In the factory: `python3 tools/new_project.py --update <game repo> [--packages ...] [--deps ...]`. It replaces packages, the copied skills, `tools/hooks` and every managed file whose factory copy changed, adds requested packages and bundles, merges the package folders of `default.project.json` (a starter/1 `ReplicatedStorage.Workbench` is removed) and the rokit pins, adds template files the repo lacks, and rewrites `starter.json`. User files (`src/`, the brief, `AGENTS.md`, decisions) are never overwritten. It refuses with uncommitted changes, or when a package, skill or managed file was edited in the game repo (sha256 differs from `starter.json`); `--force` overrides.
3. Review `git diff`, run `python3 tools/check.py`, merge.

## Safety
Refuses a dest inside the factory, inside another git repository, or non-empty (a lone `.git` from a freshly created empty repository is allowed); never runs a git command that writes; never installs, publishes, uploads or buys. The game repo keeps the factory's guards, and its release checker never passes an owner item.

## Verification
- `python3 -m unittest tests/test_new_project.py tests/test_release_check.py`: package classes and layout, leaf copies, tier parse, bundles (pins, notices, wally never run), `--update` (no-op, refusals, refresh, starter/1 migration), refusals; the good release fixture passes A01-A17 with S/O/P OWNER_REQUIRED, each of the 17 bad fixtures fails exactly its item, owner records never pass an item, the runbook is current.
- `python3 tools/starter_smoke.py`: a default repo (rojo build, the three Lune specs, gate fast tier, release checker, production status, issue drafts) and an all-packages, all-bundles repo (rojo build, Lune specs, pins, no lockfile).
- Factory gate step `starter-smoke`: scaffolds into a temp dir and runs the new repo's pre-commit gate, then the refusals and `--update`.
- Pending: the boot sequence in Play Solo and Server & Clients on the owner's PC (T3, release item S07); the generated CI workflow has not run on GitHub; publishing and live products stay owner-only (BLOCKED_EXTERNAL).
