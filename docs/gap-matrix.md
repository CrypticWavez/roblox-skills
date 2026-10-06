# Second-pass gap matrix

Generated from `reports/gap-matrix.json` by `python3 tools/gap_matrix.py`; edit the JSON, not this file. As of 2026-10-06.

Second-pass audit of the Roblox production factory (this repo plus a read-only audit of Ethan's local workbench). Machine-specific security details are kept in the project's private notes, not in this public repo. SETUP_ONLY: no game content, publishing, uploads or spending.

**Rule:** VERIFIED_* requires a representative execution observed in this pass or in CI. Files, configs, listed MCP servers and screenshots alone do not count.

| Status | Count |
|---|---|
| VERIFIED_STRONG | 9 |
| VERIFIED_ACCEPTABLE | 10 |
| WEAK | 4 |
| PARTIAL | 4 |
| BROKEN | 1 |
| MISSING | 3 |
| OUTDATED | 1 |
| REDUNDANT | 1 |
| BLOCKED_EXTERNAL | 5 |
| INTENTIONALLY_EXCLUDED | 2 |

## Summary

| ID | Area | Capability | Status | Priority | Verification |
|---|---|---|---|---|---|
| [T01](#t01) | Agent tooling | Skills discoverable by Claude Code | VERIFIED_STRONG | P0 | Fresh Claude session init lists 19 repo skills; skills-sync gate step fails on a removed heading or renamed skill (checked in a scratch copy). |
| [T02](#t02) | Agent tooling | Skills discoverable by Codex | BLOCKED_EXTERNAL | P2 | Codex lists 19 repo skills. |
| [T03](#t03) | Agent tooling | Small permanent instructions shared by Claude and Codex | VERIFIED_STRONG | P2 | Fresh-session recall of imported content. |
| [T04](#t04) | Agent tooling | Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards | VERIFIED_ACCEPTABLE | P1 | Self-test in the pre-commit gate and CI; live denials observed. |
| [T05](#t05) | Agent tooling | Permission rules apply on a fresh checkout | BLOCKED_EXTERNAL | P3 | Warnings observed; deny protection still covered by `Edit(weppy-project-sync/**)`. |
| [T06](#t06) | Agent tooling | Specialist subagents with explicit ownership | VERIFIED_STRONG | P3 | Real parallel task completed and merged. |
| [T07](#t07) | Agent tooling | Repo gate (fast / pre-commit / pre-release) | VERIFIED_STRONG | P1 | Executed in the cloud container (pre-release) and in GitHub Actions (pre-commit). |
| [T08](#t08) | Agent tooling | Continuous integration | VERIFIED_ACCEPTABLE | P1 | Green CI on the PR head (runs 3 to 5); strict jobs to be confirmed on the next run. |
| [T09](#t09) | Agent tooling | Pinned Luau toolchain | WEAK | P2 | `rojo --version` prints 7.7.0 from a new terminal. |
| [T10](#t10) | Agent tooling | Selene lint with the Roblox standard library | VERIFIED_ACCEPTABLE | P2 | Selene step green in CI. |
| [T11](#t11) | Agent tooling | Rojo projects build from a clean clone | PARTIAL | P2 | All four projects build in CI. |
| [L01](#l01) | Local workbench (PC) | Local workbench gate | BROKEN | P1 | `./.venv/Scripts/python.exe tools/check.py` passes on a quiet tree. |
| [L02](#l02) | Local workbench (PC) | Version control and rollback for the workbench | MISSING | P1 | `git log` shows a commit. |
| [M01](#m01) | MCP and Studio | Built-in Roblox Studio MCP connection | VERIFIED_ACCEPTABLE | P1 | Live tool calls returned the expected results in Studio. |
| [M02](#m02) | MCP and Studio | Claude user-level Blender MCP | OUTDATED | P1 | `get_scene_info` answers from Claude in the repo. |
| [M03](#m03) | MCP and Studio | Blender MCP inside Codex | BLOCKED_EXTERNAL | P2 | `codex mcp get blender_workbench --json` lists the server after reload. |
| [M04](#m04) | MCP and Studio | Blender MCP add-on telemetry off | WEAK | P1 | Preference unchecked and saved. |
| [M05](#m05) | MCP and Studio | WEPPY bridge | REDUNDANT | P2 | Setting off, or a documented unique function. |
| [M06](#m06) | MCP and Studio | Codex global configuration | WEAK | P1 | Owner review. |
| [S01](#s01) | MCP and Studio | Studio testing modes (Test, Test Here, Run, Server & Clients) | BLOCKED_EXTERNAL | P1 | Console output and captures saved under `reports/studio/`. |
| [S02](#s02) | Scene authoring | SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune) | VERIFIED_ACCEPTABLE | P0 | Observed in Studio: hashes and part counts equal the golden, and two undos removed both scenes (search_game_tree). |
| [S03](#s03) | Scene authoring | Scene-authoring API as data (buildings, props, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance) | VERIFIED_STRONG | P0 | Specs, fixture hashes, previews. |
| [S04](#s04) | Scene authoring | Measurement and player-scale helpers | VERIFIED_ACCEPTABLE | P2 | Specs. |
| [S05](#s05) | Scene authoring | Terrain and lighting applied in Studio | PARTIAL | P2 | Screen captures per lighting profile. |
| [P01](#p01) | Procedural generation | Seeded generators (dungeon, cave, arena, settlement) | VERIFIED_STRONG | P0 | Specs and fixture hashes in the gate and CI. |
| [P02](#p02) | Procedural generation | Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance) | VERIFIED_ACCEPTABLE | P2 | Specs and fixture reports. |
| [P03](#p03) | Procedural generation | Determinism and manifests | VERIFIED_STRONG | P1 | Gate. |
| [B01](#b01) | Blender | Blender asset templates and QA reports (13 kinds) | VERIFIED_STRONG | P0 | Template and QA runs on three bpy versions; CI matrix; self-test proves known-bad assets fail. |
| [B02](#b02) | Blender | Blender built-ins in the factory (Geometry Nodes, Asset Browser catalogs, texture baking, Rigify) | MISSING | P2 | n/a |
| [B03](#b03) | Blender | Preview renders for visual QA | VERIFIED_ACCEPTABLE | P2 | Renders reviewed in this pass. |
| [B04](#b04) | Blender | Round trip, Blender half (create, revise, export, reimport, diff, expectation) | VERIFIED_STRONG | P0 | Runs in the pre-release gate and CI. |
| [B05](#b05) | Blender | Round trip, Studio half (3D Importer, then ImportInspector against the expectation) | PARTIAL | P0 | ImportInspector in Studio: 6 of 7 checks pass for v1 and v2 and the revision is detected; pivot pending the fixed file. |
| [B06](#b06) | Blender | Material colour survives the Studio import | MISSING | P1 | A Studio import shows the baked colours, and the inspector's appearance_bound reports a texture. |
| [R01](#r01) | Inherited modules | Inherited pure-Luau modules (ReceiptLedger, CommerceCatalog, Lifetime, Motion, AudioMixer, AudioDirector, EffectsPool, MovementProfile, AnimationInspector and WorldInspector maths, UI logic, FaultQueue) | VERIFIED_ACCEPTABLE | P2 | Inherited suites and new specs pass in the gate. |
| [R02](#r02) | Inherited modules | Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector) | WEAK | P2 | Fresh receipts with today's Studio version. |
| [D01](#d01) | Research | Fresh tooling research with select/reject decisions | VERIFIED_ACCEPTABLE | P3 | Decisions applied: built-in Studio MCP, Rokit over Aftman, mcp-for-blender 2.1.8, bpy 5.2 LTS in CI. |
| [D02](#d02) | Research | Deep observational game dossiers | PARTIAL | P3 | n/a |
| [D03](#d03) | Research | In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution) | BLOCKED_EXTERNAL | P2 | CI job green. |
| [X01](#x01) | Boundary | Publishing, asset upload, purchases, live products, ads | INTENTIONALLY_EXCLUDED | P0 | Self-test in the gate and CI. |
| [X02](#x02) | Boundary | Commercial game content (genre, theme, world, characters, economy, UI) | INTENTIONALLY_EXCLUDED | P0 | Review. |

## Steps that need Ethan's machine or decision

**T02 Skills discoverable by Codex** (BLOCKED_EXTERNAL)

1. Clone or pull branch `claude/factory-second-pass-y7bey4` of CrypticWavez/roblox-skills on the PC.
2. Run `codex` in the clone and open `/skills`; expect the 19 names in `.agents/skills/`.

**T05 Permission rules apply on a fresh checkout** (BLOCKED_EXTERNAL)

1. Open Claude Code in the repo once and accept the trust prompt and the project MCP servers.
2. Optional: delete the `Write(weppy-project-sync/**)` line from `.claude/settings.json`.

**T09 Pinned Luau toolchain** (WEAK)

1. Windows Settings > Environment Variables > Path: move `%USERPROFILE%\.rokit\bin` above `%USERPROFILE%\.aftman\bin` (or remove the Aftman entry).
2. Open a new terminal and run `rojo --version`; expect 7.7.0.

**L01 Local workbench gate** (BROKEN)

1. When the Codex run finishes, run `./.venv/Scripts/python.exe tools/check.py` in the workbench folder.

**L02 Version control and rollback for the workbench** (MISSING)

1. With Codex idle: `git add -A` then `git commit -m "workbench snapshot"` in the workbench folder (check `.gitignore` excludes `.venv`, `backups/` and large media first).

**M02 Claude user-level Blender MCP** (OUTDATED)

1. `claude mcp remove blender -s user`
2. Start Blender 5.1.2 with the 2.1.8 add-on connected, open Claude Code in the repo, approve the `blender` project server, and ask for `get_scene_info`.

**M03 Blender MCP inside Codex** (BLOCKED_EXTERNAL)

1. Trust the workbench project in Codex, reload, then run `codex mcp get blender_workbench --json`.

**M04 Blender MCP add-on telemetry off** (WEAK)

1. Blender > Edit > Preferences > Add-ons > Blender MCP: untick telemetry, then Save Preferences.

**M06 Codex global configuration** (WEAK)

1. Review the Codex section of the private local-audit note and tighten `~/.codex/config.toml` (approval on request, workspace-write sandbox, only needed browser origins).

**S01 Studio testing modes (Test, Test Here, Run, Server & Clients)** (BLOCKED_EXTERNAL)

1. Covered by S02 (Run mode). For multi-client: open the unpublished network diagnostic place, Test > Clients and Servers > 2 players > Start, then `get_console_output`.

**S02 SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** (VERIFIED_ACCEPTABLE)

1. Pull the PR branch, `rojo build fixtures/factory.project.json -o SETUP_ONLY_Factory_Diagnostic.rbxl` with Rokit's rojo, open it in Studio (unpublished).
2. `execute_luau`: `return game:GetService("HttpService"):JSONEncode(require(game.ReplicatedStorage.Workbench.Pipeline.FactorySmoke).run(workspace))`; compare with `tests/golden/studio-smoke.json`, then undo twice.
3. Set `ServerScriptService.FactorySmoke.Enabled = true`, `start_stop_play` in Run mode, approve the console read, check `FACTORY_SMOKE` in `get_console_output`, stop play and set Enabled back to false.

**B05 Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** (PARTIAL)

1. In SETUP_ONLY_Factory_Diagnostic, Import 3D `build/roundtrip-1eee84a/SM_RoundTripMarker_v2.fbx` (Scale Unit Stud, Insert In Workspace and Insert Using Scene Position on). This is one more private mesh upload.
2. `execute_luau`: `ImportInspector.inspect` on the new model with `build/roundtrip-1eee84a/roblox_expectation_v2.json`; pivot_base_centre should pass.

**D03 In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution)** (BLOCKED_EXTERNAL)

1. Decide whether a private, unpublished test universe and an Open Cloud key (Luau execution + place publish scopes) may be created for CI.


## Rows

### T01

**Skills discoverable by Claude Code** · Agent tooling · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** GitHub repo: 25 Roblox pass skills. Workbench: 7 Codex skills discovered.
- **ACTUAL STATE:** The repo held 25 loose `roblox-*/skill.md` files (lowercase name, escaped markdown, 11 genre checklists; 2 of them, multiplayer-state-fix and persistence-and-rewards-audit, were empty). Neither Claude nor Codex looked in those folders. Now 19 skills live in `.agents/skills/` and are mirrored to `.claude/skills/`.
- **EVIDENCE:** Commit 054af82 tree. A fresh headless Claude Code 2.1.289 session in this repo listed all 19 repo skills in its init event. `python3 tools/sync_skills.py --check` (pre-commit gate, CI) reports 19 skills, 0 errors.
- **DEFECT:** No agent ever loaded the old guidance.
- **ROOT CAUSE:** Uploaded without the SKILL.md / skills-directory conventions.
- **IMPACT:** All earlier skill guidance was dead text.
- **FIX:** Rewrote into 19 focused skills, each with the ten sections Purpose, Triggers, Inputs, Required context, Tools, Procedure, Outputs, Acceptance, Failure and Related. `sync_skills.py --check` enforces them plus frontmatter, name = directory, description, size and line endings; a skill missing a heading fails the gate. Legacy checklists moved to `references/`; old root folders removed.
- **VERIFICATION:** Fresh Claude session init lists 19 repo skills; skills-sync gate step fails on a removed heading or renamed skill (checked in a scratch copy).

### T02

**Skills discoverable by Codex** · Agent tooling · BLOCKED_EXTERNAL · P2

- **PREVIOUS CLAIM:** Workbench `tools/check_skill_discovery.py` verified 7 skills through the Codex app server.
- **ACTUAL STATE:** This repo uses the same `.agents/skills/<name>/SKILL.md` layout Codex reads. Codex is not installed in the cloud container.
- **EVIDENCE:** Layout matches the workbench's verified layout; not executed with Codex in this pass.
- **DEFECT:** Unproven for this repo.
- **ROOT CAUSE:** No Codex host available in the cloud session.
- **IMPACT:** Low: same layout as a verified one.
- **FIX:** Run discovery on the PC.
- **VERIFICATION:** Codex lists 19 repo skills.

### T03

**Small permanent instructions shared by Claude and Codex** · Agent tooling · VERIFIED_STRONG · P2

- **PREVIOUS CLAIM:** Workbench AGENTS.md (11 lines) plus a one-line CLAUDE.md pointer; the GitHub repo had none.
- **ACTUAL STATE:** `AGENTS.md` (boundary, retrieval table, working rules, verification language) is canonical; `CLAUDE.md` imports it with `@AGENTS.md` and adds Claude specifics.
- **EVIDENCE:** A fresh headless Claude session quoted `## Boundary: SETUP_ONLY` from the imported file and named `technical-artist` as the Blender owner without tool use.
- **DEFECT:** None found.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Fresh-session recall of imported content.

### T04

**Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards** · Agent tooling · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** First pass shipped no hooks ("no fabricated hooks").
- **ACTUAL STATE:** PostToolUse `fast_on_edit` (format, JSON, secrets from `tools/hooks/secret-patterns.json`, SKILL.md rules). PreToolUse `guard_bash` parses commands (argv, runners such as npx, variables, PowerShell parameter prefixes, inline script bodies) and denies publish/upload tools, Open Cloud and DataStore/Messaging writes, write requests whose URL is hidden in a variable, force pushes or deletions of main/master in any argument order, and anything but known read-only commands on a line that names `weppy-project-sync/`. `guard_mcp` denies publishing or asset/place-creating Luau and completed purchases, and asks before asset-creating Studio tools, purchase prompts and DataStore/MemoryStore writes. `tools/check.py` provides the pre-commit and pre-release tiers and installs a git pre-commit hook.
- **EVIDENCE:** `node tools/hooks/selftest.mjs`: 170/170 hook cases in both directions (including false-positive cases such as `feature/main-menu` and plain reads) and 17 secret samples checked against both the edit hook and `tools/check.py`; a corpus of 1514 real commands was replayed for false positives. Live in this session: the guard denied an earlier heredoc containing a publish command and, after the rewrite, a Python heredoc that named the protected folder.
- **DEFECT:** Text guards cannot see scripts run from files, shell aliases, or paths and URLs produced by other programs (documented in the guard header). The folder rule is deliberately conservative: an interpreter command line that merely mentions the folder name is denied, so text about it is edited with the Edit tool.
- **ROOT CAUSE:** Hooks inspect command text, not runtime behaviour.
- **IMPACT:** Residual risk if an agent is manipulated into hiding a publish call in a script file; deny rules and Studio's own prompts remain.
- **FIX:** Rewritten after review findings (curl form/data uploads, DataStore writes, flag-order force pushes, CreateAssetVersionAsync, purchase prompts, folder redirects, rojo global flags). No hook can publish or spend: they only return allow/ask/deny.
- **VERIFICATION:** Self-test in the pre-commit gate and CI; live denials observed.

### T05

**Permission rules apply on a fresh checkout** · Agent tooling · BLOCKED_EXTERNAL · P3

- **PREVIOUS CLAIM:** n/a (new in this pass)
- **ACTUAL STATE:** Claude ignores the 21 `permissions.allow` entries until the workspace is trusted; deny rules and hooks still apply. Claude also reports that `Write(weppy-project-sync/**)` in the deny list is never matched because `Edit(...)` rules cover every file-editing tool.
- **EVIDENCE:** Fresh headless Claude Code 2.1.289 sessions printed both warnings.
- **DEFECT:** Until trusted, every Studio read tool prompts. The `Write(...)` deny entry is redundant (the `Edit(...)` entry already protects the folder).
- **ROOT CAUSE:** Claude Code workspace-trust design; Edit rules cover Write.
- **IMPACT:** Friction on first run; no safety gap.
- **FIX:** Documented in CLAUDE.md. Removing the redundant entry from `.claude/settings.json` was blocked for this session (an agent may not edit the settings that govern it), so it is left for Ethan.
- **VERIFICATION:** Warnings observed; deny protection still covered by `Edit(weppy-project-sync/**)`.

### T06

**Specialist subagents with explicit ownership** · Agent tooling · VERIFIED_STRONG · P3

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.claude/agents/`: roblox-engineer (packages, tests), technical-artist (Blender), qa-reviewer (read-only), researcher (docs/research). File ownership table in `docs/architecture.md`; Codex follows the same table via AGENTS.md.
- **EVIDENCE:** Fresh Claude session init lists all four agents. On 2026-10-05 a workflow ran roblox-engineer (ProcGen, SceneKit), technical-artist (Blender QA) and general-purpose engineers in five isolated worktrees with disjoint file sets, each checked by a read-only qa-reviewer; all five merged without code conflicts (only the regenerated golden hash file overlapped).
- **DEFECT:** None open.
- **ROOT CAUSE:** n/a
- **IMPACT:** Low.
- **FIX:** n/a
- **VERIFICATION:** Real parallel task completed and merged.

### T07

**Repo gate (fast / pre-commit / pre-release)** · Agent tooling · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** Workbench `tools/check.py` 43 checks passed at 19:43Z.
- **ACTUAL STATE:** `tools/check.py` runs StyLua, JSON, the shared-pattern secret scan over every committable file, skills sync, gap matrix, hook self-test, Selene, Lune specs, the inherited suites and fixture builds with golden hashes (added, removed and changed fixtures all fail); pre-release adds Blender templates, round trip, QA self-test and previews. Missing tools report SKIPPED, never PASS, and `--strict` (used in CI) counts SKIPPED as a failure.
- **EVIDENCE:** Pre-release tier passed in the cloud container on the merged branch (Selene SKIPPED there: no network for its std). Pre-commit tier passed in GitHub Actions with Selene running and nothing skipped (runs 3 to 5 on 1eee84a, 492ebfc, ab9487d).
- **DEFECT:** Selene cannot run in the cloud container (see T10).
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Executed in the cloud container (pre-release) and in GitHub Actions (pre-commit).

### T08

**Continuous integration** · Agent tooling · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.github/workflows/factory.yml`: a pre-commit job (Rokit toolchain, Selene std generation, Rojo builds of three projects, `--tier pre-commit --strict`) and a Blender matrix on bpy 5.1.2 (the PC's version) and 5.2.2 LTS that runs `--tier pre-release --strict`.
- **EVIDENCE:** The first run never got a hosted runner and was cancelled. Runs 3 to 5 passed: pre-commit gate with Selene and no skipped steps, Blender templates and round trip on both bpy versions. The strict pre-release jobs run from the integration commit onward.
- **DEFECT:** Strict mode and the in-CI pre-release tier are new; their first run is pending at this commit.
- **ROOT CAUSE:** n/a
- **IMPACT:** First real test of `rokit install` and Selene's Roblox std in a clean environment.
- **FIX:** Keep CI green on the PR head.
- **VERIFICATION:** Green CI on the PR head (runs 3 to 5); strict jobs to be confirmed on the next run.

### T09

**Pinned Luau toolchain** · Agent tooling · WEAK · P2

- **PREVIOUS CLAIM:** Bootstrap and toolchain partially verified; explicit Rokit binaries.
- **ACTUAL STATE:** `rokit.toml` pins rojo 7.7.0, lune 0.10.5, stylua 2.5.2, selene 0.31.0, luau-lsp 1.68.1, matching the PC. On the PC, Aftman's shim directory precedes Rokit's on PATH, so a bare `rojo` resolves to Aftman and fails.
- **EVIDENCE:** Local audit (`where rojo`, PATH order). CI installs the pinned set with `rokit install`; the cloud container built lune, stylua and selene at the pinned versions (rojo 7.7.1 from crates).
- **DEFECT:** PATH order on the PC.
- **ROOT CAUSE:** Aftman installed before Rokit; both add shims.
- **IMPACT:** Agents and humans running bare `rojo` on the PC get an error.
- **FIX:** Put `%USERPROFILE%\.rokit\bin` before `%USERPROFILE%\.aftman\bin`, or uninstall Aftman (Rokit reads aftman.toml).
- **VERIFICATION:** `rojo --version` prints 7.7.0 from a new terminal.

### T10

**Selene lint with the Roblox standard library** · Agent tooling · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Selene in the workbench gate.
- **ACTUAL STATE:** `selene generate-roblox-std` cannot fetch the API dump through the cloud proxy, so the container reports SKIPPED. CI generates the std first and lints `packages` with it.
- **EVIDENCE:** GitHub Actions run 3 (1eee84a): `[ok  ] selene`; container gate output `selene SKIPPED` with the reason.
- **DEFECT:** Not linted in the cloud container.
- **ROOT CAUSE:** Network policy of the cloud environment.
- **IMPACT:** Lint regressions would only show in CI.
- **FIX:** CI pre-commit job (strict, so a skip fails it).
- **VERIFICATION:** Selene step green in CI.

### T11

**Rojo projects build from a clean clone** · Agent tooling · PARTIAL · P2

- **PREVIOUS CLAIM:** Three Rojo fixture builds in the workbench gate.
- **ACTUAL STATE:** creator, diagnostic and factory projects build in the cloud. `network.project.json` points at `../artifacts/network/SourceManifest.luau`, which only the PC workbench generates.
- **EVIDENCE:** `rojo build` outputs in `build/`; the network build fails with a missing path.
- **DEFECT:** Hidden machine state.
- **ROOT CAUSE:** Generated file referenced but never committed.
- **IMPACT:** Network diagnostics can't be rebuilt from the repo.
- **FIX:** CI builds the other three. Next: port the generator (`tools/network_check.py` on the PC) or commit a neutral manifest.
- **VERIFICATION:** All four projects build in CI.

### L01

**Local workbench gate** · Local workbench (PC) · BROKEN · P1

- **PREVIOUS CLAIM:** `reports/verification.json` pass at 19:43Z.
- **ACTUAL STATE:** Re-run during the audit: FAIL 42/43 (`authored-inputs-unchanged`). A Codex process running since 13:09 was editing `tools/profiles.py` and had added 8 files the last pass never covered. `wb.ps1 validate` passes (427 records, 0 errors).
- **EVIDENCE:** Remote Control session on the PC, read-only.
- **DEFECT:** The recorded pass does not cover the current files.
- **ROOT CAUSE:** Concurrent writer and no version control.
- **IMPACT:** No trustworthy green state for the workbench right now.
- **FIX:** Ethan chose to keep Codex running, so Claude stayed read-only. Re-run the gate once the Codex run ends.
- **VERIFICATION:** `./.venv/Scripts/python.exe tools/check.py` passes on a quiet tree.

### L02

**Version control and rollback for the workbench** · Local workbench (PC) · MISSING · P1

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `git` branch master with 0 commits, no remote, nothing tracked.
- **EVIDENCE:** Local audit.
- **DEFECT:** No history; two agents can overwrite each other silently.
- **ROOT CAUSE:** Never initialised beyond `git init`.
- **IMPACT:** Nothing in the workbench can be rolled back.
- **FIX:** Local-only snapshot (no remote, no upload) once Codex is idle; Ethan deferred this.
- **VERIFICATION:** `git log` shows a commit.

### M01

**Built-in Roblox Studio MCP connection** · MCP and Studio · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** Native Studio connection partially verified (sync/readback, Play, screenshots, simulated input).
- **ACTUAL STATE:** The built-in Studio MCP (user-level `Roblox_Studio`, Studio 0.741.19) was driven live from a Claude Code session on the PC: `list_roblox_studios`, `execute_luau`, `search_game_tree`, `screen_capture` and `start_stop_play`. The repo's `.mcp.json` declares the same command with hook gating.
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json`, `reports/studio/roundtrip-2026-10-05.json`.
- **DEFECT:** The repo's own `.mcp.json` entry was not the one used (the PC session ran from the workbench folder); reading console output in Run mode was blocked by the PC's permission prompt.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Studio-side claims below stay blocked until run there.
- **FIX:** Open Claude Code in this repo on the PC once, approve the project server, and approve the console read.
- **VERIFICATION:** Live tool calls returned the expected results in Studio.

### M02

**Claude user-level Blender MCP** · MCP and Studio · OUTDATED · P1

- **PREVIOUS CLAIM:** Blender MCP direct connection verified (vendored mcp-for-blender 2.1.8, protocol 13).
- **ACTUAL STATE:** Claude's user-level `blender` entry runs `uvx blender-mcp==1.6.4` and returns CONNECTION_CLOSED. The workbench verified the renamed `mcp-for-blender` 2.1.8 server (protocol 13) through its own route.
- **EVIDENCE:** Local audit `claude mcp list`.
- **DEFECT:** Outdated package name and version.
- **ROOT CAUSE:** Upstream renamed `blender-mcp` to `mcp-for-blender`; the user config still uses the old package (version mismatch with the add-on is inferred, not proven).
- **IMPACT:** Claude has no working Blender MCP on the PC.
- **FIX:** Project `.mcp.json` pins `uvx mcp-for-blender==2.1.8` with `DISABLE_TELEMETRY=true`. Remove the stale user entry so it cannot shadow or confuse.
- **VERIFICATION:** `get_scene_info` answers from Claude in the repo.

### M03

**Blender MCP inside Codex** · MCP and Studio · BLOCKED_EXTERNAL · P2

- **PREVIOUS CLAIM:** Blocked: Codex disables the untrusted project config layer.
- **ACTUAL STATE:** Unchanged.
- **EVIDENCE:** Workbench `reports/blender_mcp_host.json`; local audit.
- **DEFECT:** Tools configured but not loaded.
- **ROOT CAUSE:** Codex project trust not granted.
- **IMPACT:** Codex can't drive Blender interactively; headless `factory.py` still works.
- **FIX:** Owner trusts the workbench in Codex.
- **VERIFICATION:** `codex mcp get blender_workbench --json` lists the server after reload.

### M04

**Blender MCP add-on telemetry off** · MCP and Studio · WEAK · P1

- **PREVIOUS CLAIM:** Workbench Codex config sets telemetry off for its vendored server.
- **ACTUAL STATE:** The add-on installed in Blender (`blender_mcp.py` v1.2) defaults telemetry to on; whether it was turned off is unverified. The server side is off via `DISABLE_TELEMETRY`.
- **EVIDENCE:** Local audit read the add-on source default.
- **DEFECT:** Possible prompt/code/screenshot telemetry from the add-on.
- **ROOT CAUSE:** Upstream default.
- **IMPACT:** Private material could leave the machine.
- **FIX:** Turn it off in the add-on preferences.
- **VERIFICATION:** Preference unchecked and saved.

### M05

**WEPPY bridge** · MCP and Studio · REDUNDANT · P2

- **PREVIOUS CLAIM:** Partially verified; kept as optional shared bridge.
- **ACTUAL STATE:** Connected at user level with 0 plugin clients and an asset-upload setting enabled. No function was found that the built-in Studio MCP lacks.
- **EVIDENCE:** Local audit.
- **DEFECT:** Overlapping server with an upload path enabled.
- **ROOT CAUSE:** Pre-existing bridge kept for compatibility.
- **IMPACT:** Larger attack surface; an upload route exists outside the repo's guards.
- **FIX:** Keep it unused for factory work; disable its asset-upload setting unless a unique function is verified. `weppy-project-sync/` stays untouched.
- **VERIFICATION:** Setting off, or a documented unique function.

### M06

**Codex global configuration** · MCP and Studio · WEAK · P1

- **PREVIOUS CLAIM:** Not covered.
- **ACTUAL STATE:** The global Codex configuration on the PC grants high trust to every Codex project (no approval step, broad sandbox, a third-party browser origin with file transfer). Specific values are kept out of this public repo and recorded in the project's private local-audit note.
- **EVIDENCE:** Local audit (read-only); private note `second-pass/local-audit.md` in the project files.
- **DEFECT:** Weak isolation for every Codex project on the machine.
- **ROOT CAUSE:** Global convenience settings.
- **IMPACT:** Prompt injection from browsed content could read or move local files.
- **FIX:** Outside this repo; Claude did not change it.
- **VERIFICATION:** Owner review.

### S01

**Studio testing modes (Test, Test Here, Run, Server & Clients)** · MCP and Studio · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Play and local one/two-client RemoteEvent/leave fixtures passed.
- **ACTUAL STATE:** The gate's "native" passes replay hashes of saved receipts; they do not open Studio. MCP `start_stop_play` covers Test and Run; Test Here and Server & Clients are started from the Studio UI. On 2026-10-05 Run mode was started on the PC but the FACTORY_SMOKE console line could not be read (permission prompt).
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` (run_mode field); research section 2.
- **DEFECT:** No play mode has produced observed output in this pass.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Replication and play behaviour of new code is unproven.
- **FIX:** Run S02 in Run mode, and one Server & Clients session with 2 clients on the network fixture.
- **VERIFICATION:** Console output and captures saved under `reports/studio/`.

### S02

**SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** · Scene authoring · VERIFIED_ACCEPTABLE · P0

- **PREVIOUS CLAIM:** WorldInspector queries and metadata-only content graphs; "no setup game world".
- **ACTUAL STATE:** `FactorySmoke` was run in real Studio (0.741.19) on Ethan's PC through Studio MCP `execute_luau`, in the unpublished SETUP_ONLY_Factory_Diagnostic place that Rojo built from `fixtures/factory.project.json`. It built both scenes with string requires across SceneKit and ProcGen, and the hashes and part counts equal the Lune golden: building 778d1d9a / 96 parts, dungeon 8494d161 / 108 parts. Two ChangeHistoryService undos removed both scenes.
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` (commit 9c12091); `tests/golden/studio-smoke.json`.
- **DEFECT:** Run mode is unproven: the PC's permission prompt blocked reading the FACTORY_SMOKE console line. The generators changed after 9c12091 (review fixes), so the new goldens have not yet been reproduced in Studio.
- **ROOT CAUSE:** Console read needs Ethan's approval on his machine; later commits change hashes on purpose.
- **IMPACT:** Edit-time parity and undo are proven. Play-time parity is not, and the parity proof applies to 9c12091's hashes.
- **FIX:** Re-run steps 1 to 3 after pulling, and approve the console read once for the Run-mode line.
- **VERIFICATION:** Observed in Studio: hashes and part counts equal the golden, and two undos removed both scenes (search_game_tree).

### S03

**Scene-authoring API as data (buildings, props, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance)** · Scene authoring · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present (metadata graphs only).
- **ACTUAL STATE:** `packages/SceneKit`: plans are data, built from seeds and style profiles, validated (part budget, door clear width against every wall, room clearance, stair rise, headroom and oriented-box obstruction at any yaw, prop clipping and support), hashed into manifests, compared between revisions, rendered, and applied in Studio with undo; `Apply.scene` replaces the previous model of the same name unless `{replace = false}`.
- **EVIDENCE:** Lune specs (`tests/scenekit.spec.luau`, `tests/scenekit_layout.spec.luau`: 600 subdivided buildings with no bisected doorway, railing vs next flight at 3 to 5 storeys, yawed stairs, the fixture ramp clear of the Annex). Five SETUP_ONLY fixture places build and validate with stable hashes. Studio parity of the smoke scenes (S02).
- **DEFECT:** Fixed in this pass: stair headroom at 3+ storeys, inverted gable slopes, ramp yaw, front camera; after review: Apply not replacing with no options, partitions cutting doorways, railing clipping the next flight, the fixture ramp buried in a foundation, AABB stair checks failing at non-axis yaw.
- **ROOT CAUSE:** Rotation-convention errors, caught by validators and renders.
- **IMPACT:** n/a after fixes.
- **FIX:** Regression specs for each.
- **VERIFICATION:** Specs, fixture hashes, previews.

### S04

**Measurement and player-scale helpers** · Scene authoring · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Conservative AABB/ray queries in WorldInspector.
- **ACTUAL STATE:** `Measure`: engine defaults (gravity 196.2, WalkSpeed 16, JumpHeight 7.2) and design guides (doors, ceilings, corridors, cover), jump reach, clearances, sightlines, camera clearance.
- **EVIDENCE:** Measurement specs; validators use them on every fixture.
- **DEFECT:** Guides are heuristics, not playtested with a character.
- **ROOT CAUSE:** No Studio character run yet.
- **IMPACT:** Values may need tuning per game.
- **FIX:** Check with `character_navigation` during S02.
- **VERIFICATION:** Specs.

### S05

**Terrain and lighting applied in Studio** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Terrain heightmaps, sculpt, carve, water and paint produce ops validated in Lune; `Apply.terrain` calls `Terrain:FillBlock`/`FillBall`. Lighting profiles apply to a Lighting instance in Lune.
- **EVIDENCE:** Specs; Lune lacks a real Terrain voxel engine.
- **DEFECT:** Voxel output and the look of lighting profiles are unverified.
- **ROOT CAUSE:** Engine-only behaviour.
- **IMPACT:** Terrain plans may need adjustment once seen.
- **FIX:** Apply a `Terrain.heightmap` plan (as in `tests/scenekit.spec.luau`) and each lighting profile in the diagnostic place and capture them; no fixture emits terrain ops yet.
- **VERIFICATION:** Screen captures per lighting profile.

### P01

**Seeded generators (dungeon, cave, arena, settlement)** · Procedural generation · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** `packages/ProcGen`: BSP + MST dungeons whose loops are walkable on the carved grid and wrap real wall (`minLoopWallStuds`), goals and encounters placed in rooms big enough for them on the best shortest route (shortfalls fail `encounters_placed`), cellular-automata caves re-joined until exactly one region, symmetric arenas with the objective on the true centre, road/lot settlements.
- **EVIDENCE:** `tests/procgen.spec.luau` (every validator asserted, no exclusions) and `tests/procgen_regressions.spec.luau` (independent grid loop check on seeds 1 to 40, 200-seed sweeps for loops, encounters and run length, caves at four sizes, arenas at 7 sizes x 2 symmetries); golden fixture hashes in the gate.
- **DEFECT:** Fixed during the pass: seed 303 had no loop, 4-stud caves, 1-cell arena lanes. After review: graph-only loops (47 of seeds 1 to 200 had no walkable loop), cramped goal rooms failing encounter_space on 12 of 25 spec seeds while the spec skipped that check, cave seed 87 split in two, NaN spawn fairness, off-centre arena objective.
- **ROOT CAUSE:** Generator parameters; caught by validators.
- **IMPACT:** n/a after fixes.
- **FIX:** RoomGraph loop measure, capacity-aware placement, region re-join loop, unreachable spawns fail, centred objective; goldens regenerated (dungeon 06ace82c, arena 20898139, Studio smoke dungeon 927f2db4).
- **VERIFICATION:** Specs and fixture hashes in the gate and CI.

### P02

**Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance)** · Procedural generation · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Implemented on the layout grid and room graph with machine-readable checks, including encounters_placed and walkable-loop redundant_paths.
- **EVIDENCE:** Every fixture's checks in `build/fixtures/report.json`; failing cases in the specs for each validator (unreachable spawn, graph-only loop, pillar loop, encounter shortfall, split cave).
- **DEFECT:** Grid-level reasoning, not PathfindingService or Humanoid physics.
- **ROOT CAUSE:** Headless by design.
- **IMPACT:** A layout can pass the grid and still snag a character on geometry.
- **FIX:** Add a PathfindingService reachability probe to S02 later.
- **VERIFICATION:** Specs and fixture reports.

### P03

**Determinism and manifests** · Procedural generation · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** Hash-drift blocking for planning records.
- **ACTUAL STATE:** Same seed gives the same manifest hash; canonical sorted JSON; golden hashes for fixtures and the Studio smoke.
- **EVIDENCE:** `fixture-hashes` gate step locally and in CI (runs 3 to 5).
- **DEFECT:** None found.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Gate.

### B01

**Blender asset templates and QA reports (13 kinds)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Blender direct authoring/export verified (68-triangle 2-bone fixture, 128px bake, FBX+GLB, reimport, turntable).
- **ACTUAL STATE:** `tools/blender/factory.py templates`: humanoid, npc, enemy, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests. QA runs before export and a failing asset writes no FBX/GLB (exit 1, `qa.json` kept). Checks use world transforms, count only deform-bone weights, block single-root assets off the world origin (Studio pivot), and re-import the shipped FBX and GLB against a signature of the export set. `qa <file>` works on .blend, .fbx, .glb and .gltf, with seam-aware glTF welding.
- **EVIDENCE:** All 13 templates and QA of all 26 shipped FBX/GLB files pass on bpy 5.0.1, 5.1.2 and 5.2.2 in the container; 13/13 on Ethan's Blender 5.1.2 (at 9c12091); CI Blender jobs on 5.1.2 and 5.2.2. `factory.py qa-selftest`: 19 known-good/known-bad cases agree across source, FBX and GLB and the export gate.
- **DEFECT:** Fixed: Blender 5.1+/5.2 boolean empty material slot, FBX animation loss, join material indices, mirror self-merge, inset bounds. After review: the probe tested a different export than the shipped files, QA never blocked export, local-only transform checks, non-deform groups counted as weights, false GLB errors, stale matrix_world in set_origin_base_center.
- **ROOT CAUSE:** Blender 5.1+ boolean behaviour change; exporter defaults.
- **IMPACT:** The factory would have failed QA on Ethan's installed Blender.
- **FIX:** `prune_material_slots`; `qa.gated_export`; shipped-file probe; world-space and deform-bone checks; `_weld_seams`; `studio_pivot_at_origin`; `qa-selftest` in the pre-release tier.
- **VERIFICATION:** Template and QA runs on three bpy versions; CI matrix; self-test proves known-bad assets fail.

### B02

**Blender built-ins in the factory (Geometry Nodes, Asset Browser catalogs, texture baking, Rigify)** · Blender · MISSING · P2

- **PREVIOUS CLAIM:** Workbench: a 128px bake fixture.
- **ACTUAL STATE:** The new factory scripts primitives, modifiers, UVs, PBR materials, rigid binding and keyframes. Geometry Nodes, asset catalogs, baking and Rigify are researched but not scripted.
- **EVIDENCE:** `tools/blender/bkit/ops.py`; research section 5.
- **DEFECT:** Missing automation.
- **ROOT CAUSE:** Scoped out of this pass.
- **IMPACT:** Kits, LOD variants and baked textures stay manual.
- **FIX:** Next pass: GN scatter/LOD, catalog writer, bake step with QA.
- **VERIFICATION:** n/a

### B03

**Preview renders for visual QA** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Turntable and comparison images.
- **ACTUAL STATE:** `render-manifest` renders SceneKit manifests (Cycles CPU) from their cameras, or frames cameras from the part bounds when a manifest has none, so plain `scene:manifest()` output renders; templates render front and three-quarter views.
- **EVIDENCE:** `build/previews/*.png` reviewed; they exposed three geometry bugs.
- **DEFECT:** Small CPU renders; not Studio lighting.
- **ROOT CAUSE:** Headless.
- **IMPACT:** Look in Studio still needs S02 captures.
- **FIX:** n/a
- **VERIFICATION:** Renders reviewed in this pass.

### B04

**Round trip, Blender half (create, revise, export, reimport, diff, expectation)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Baseline/revision exports and reimport hashes.
- **ACTUAL STATE:** `roundtrip` builds SM_RoundTripMarker v1 and v2 (no export if source QA fails, stale outputs removed first), exports FBX and GLB at the world origin, reimports both, checks triangles, dimensions, origin at the base centre and at the world origin, front direction, surface offsets, materials and names, and writes `roblox_expectation_v*.json` (with `front_offset`/`up_offset`) for the Studio side.
- **EVIDENCE:** `roundtrip-report.json` passes on bpy 5.0.1, 5.1.2, 5.2.2 in the container, on Ethan's Blender 5.1.2 (9c12091, 9c024fb, 1eee84a) and in CI.
- **DEFECT:** Fixed after the Studio import: the marker's origin sat off the world origin (Studio pivot), and the pivot check only looked at minimum Z.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Runs in the pre-release gate and CI.

### B05

**Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** · Blender · PARTIAL · P0

- **PREVIOUS CLAIM:** Blocked: no documented zero-upload import route.
- **ACTUAL STATE:** Ethan imported the neutral SM_RoundTripMarker v1 and v2 with Import 3D (Scale Unit = Stud) into the unpublished diagnostic place, and `ImportInspector` ran in Studio with its default EditableMesh reader. Both revisions matched Blender on scale (4 x 7 x 3.5 and 4 x 8 x 4.5 studs), rotation, facing (surface-centroid offset -0.620 vs -0.62 and -1.026 vs -1.026, plus a screen_capture from -Z) and collision. `compareRevisions` detected the update. The pivot failed: Studio puts the model pivot at the FBX file origin, and the marker's origin sat off Blender's world origin. Each import uploaded a private mesh asset to Ethan's account (there is no local-only import).
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json` (inspector at 9c024fb; v2 was the pre-fix export, which matches its +1.25 stud pivot error exactly).
- **DEFECT:** The pivot is off by the object's offset from the world origin. Fixed in 1eee84a, where the marker exports at the world origin and the Blender reimport checks require it, but Studio has not yet seen the fixed file. Material colours are lost (see B06).
- **ROOT CAUSE:** Studio's importer anchors the pivot at the file origin, not at the object origin.
- **IMPACT:** Every asset exported off the world origin arrives with a misplaced pivot.
- **FIX:** Export at the world origin (done for the marker; the QA pivot check covers origin vs bounds). Confirm by importing the fixed v2.
- **VERIFICATION:** ImportInspector in Studio: 6 of 7 checks pass for v1 and v2 and the revision is detected; pivot pending the fixed file.

### B06

**Material colour survives the Studio import** · Blender · MISSING · P1

- **PREVIOUS CLAIM:** None (first pass never imported into Studio).
- **ACTUAL STATE:** Both imported MeshParts are plain grey (Color 0.639, 0.635, 0.647, empty TextureID, no SurfaceAppearance). The marker's per-material Principled base colours (MAT_Body grey, MAT_Front orange) do not carry through Import 3D.
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json`.
- **DEFECT:** Untextured multi-material assets lose all colour in Roblox.
- **ROOT CAUSE:** A MeshPart takes one texture or SurfaceAppearance; material base colours without image textures are not converted.
- **IMPACT:** Factory assets would arrive colourless unless their colours are baked.
- **FIX:** Bake base colour into one texture per asset in Blender (UV atlas), export it with the FBX, then confirm the import binds it (that import uploads a mesh and an image).
- **VERIFICATION:** A Studio import shows the baked colours, and the inspector's appearance_bound reports a texture.

### R01

**Inherited pure-Luau modules (ReceiptLedger, CommerceCatalog, Lifetime, Motion, AudioMixer, AudioDirector, EffectsPool, MovementProfile, AnimationInspector and WorldInspector maths, UI logic, FaultQueue)** · Inherited modules · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Workbench Lune suites: 28 runtime fixtures plus creator and network suites; commerce foundation partially verified.
- **ACTUAL STATE:** Modules and the first pass's 7 Lune suites were copied into the repo and re-run against the repo's copies: 106 cases pass (runtime 28, animation 22, audio/movement 6, effects 15, UI 9, world 15, network 11). Seven new second-pass specs add grant-once under retried UpdateAsync transforms, unknown/malformed receipts, retry then defer, v1 migration, corrupt schema refusal, cross-universe refusal, lifetime eviction/expiry/closed and bounded motion curves.
- **EVIDENCE:** `tests/runtime`, `tests/creator`, `tests/diagnostics` (inherited) and `tests/inherited.spec.luau`; each is a gate step.
- **DEFECT:** The runtime suite wrote `reports/runtime_status.json` into the tracked reports folder on every run.
- **ROOT CAUSE:** Workbench-specific output path.
- **IMPACT:** Gate runs dirtied the tree. Real DataStore, audio and engine behaviour remain unverified (mocks and maths only).
- **FIX:** Output redirected to `build/`; suites added to the pre-commit gate.
- **VERIFICATION:** Inherited suites and new specs pass in the gate.

### R02

**Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector)** · Inherited modules · WEAK · P2

- **PREVIOUS CLAIM:** Native receipts for UI, effects, world, observation and network.
- **ACTUAL STATE:** Copied and built into `factory.rbxl` and the creator/diagnostic places by Rojo. Not executed in Studio in this pass; the first pass's native receipts are replays.
- **EVIDENCE:** Rojo builds; workbench receipts.
- **DEFECT:** No live re-run.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Unknown regressions since the receipts were taken.
- **FIX:** Re-run the workbench's targeted native procedure (`docs/observation.md` on the PC) after S02.
- **VERIFICATION:** Fresh receipts with today's Studio version.

### D01

**Fresh tooling research with select/reject decisions** · Research · VERIFIED_ACCEPTABLE · P3

- **PREVIOUS CLAIM:** Research corpus verified (295 chart records).
- **ACTUAL STATE:** `docs/research/tooling-2026-10.md`: Studio MCP, testing modes, Luau toolchain, Blender MCP rename, Blender built-ins, mesh import limits, Claude Code and Codex mechanics, procgen references, each with source, version, licence and SELECT/REJECT.
- **EVIDENCE:** Dated sources fetched 2026-10-05; unverifiable items are marked UNVERIFIED in the doc.
- **DEFECT:** Some licences and tags marked UNVERIFIED.
- **ROOT CAUSE:** Source pages incomplete.
- **IMPACT:** Low.
- **FIX:** n/a
- **VERIFICATION:** Decisions applied: built-in Studio MCP, Rokit over Aftman, mcp-for-blender 2.1.8, bpy 5.2 LTS in CI.

### D02

**Deep observational game dossiers** · Research · PARTIAL · P3

- **PREVIOUS CLAIM:** 22 desk dossiers; zero complete deep dives (first pass's own finding).
- **ACTUAL STATE:** Unchanged; not part of the infrastructure pass.
- **EVIDENCE:** Workbench `reports/research_status.json`.
- **DEFECT:** Observational coverage missing.
- **ROOT CAUSE:** Needs permitted gameplay observation.
- **IMPACT:** Design references are desk-level only.
- **FIX:** Out of scope here.
- **VERIFICATION:** n/a

### D03

**In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution)** · Research · BLOCKED_EXTERNAL · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Selected in research. It needs an API key and uploads a place version to run, which the setup boundary forbids without explicit authorisation.
- **EVIDENCE:** Research section 3.
- **DEFECT:** Engine-only modules have no automated in-engine test.
- **ROOT CAUSE:** Account access and the upload boundary.
- **IMPACT:** Studio-bound regressions caught only by manual runs.
- **FIX:** If Ethan authorises a private test universe: Wally `jsdotlua/jest`, upload the test place version, run via the Luau Execution API with the key in CI secrets.
- **VERIFICATION:** CI job green.

### X01

**Publishing, asset upload, purchases, live products, ads** · Boundary · INTENTIONALLY_EXCLUDED · P0

- **PREVIOUS CLAIM:** Intentionally excluded.
- **ACTUAL STATE:** Excluded and enforced: hooks deny publish/upload commands, Open Cloud and DataStore/Messaging writes, publishing or asset-creating Luau and completed purchases, and ask before asset-creating Studio tools, purchase prompts and DataStore/MemoryStore writes. The one exception, approved by Ethan on 2026-10-05: Import 3D of the neutral round-trip marker into the unpublished diagnostic place, which uploaded two private mesh assets (ids kept out of the repo).
- **EVIDENCE:** Hook self-test (170 cases) including every Prompt*Purchase, CreateAssetVersionAsync and CreatePlaceInPlayerInventoryAsync; `reports/studio/roundtrip-2026-10-05.json`.
- **DEFECT:** n/a
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Self-test in the gate and CI.

### X02

**Commercial game content (genre, theme, world, characters, economy, UI)** · Boundary · INTENTIONALLY_EXCLUDED · P0

- **PREVIOUS CLAIM:** Intentionally excluded.
- **ACTUAL STATE:** Excluded. Fixtures are named SETUP_ONLY_* and use neutral greybox, stone and timber styles; Cryptic's Realm and other games were not touched.
- **EVIDENCE:** Fixture names and style profiles; read-only audit only on the PC.
- **DEFECT:** n/a
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Review.
