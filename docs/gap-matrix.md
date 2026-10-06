# Second-pass gap matrix

Generated from `reports/gap-matrix.json` by `python3 tools/gap_matrix.py`; edit the JSON, not this file. As of 2026-10-06.

Second-pass audit of the Roblox production factory (this repo plus a read-only audit of the owner's local workbench), updated after the runtime-kit build groups (G1 to G8, G9a, G9b) were integrated. Machine-specific security details are kept in the project's private notes, not in this public repo. SETUP_ONLY: no game content, publishing, uploads or spending.

**Rule:** VERIFIED_* requires a representative execution observed in this pass or in CI. Files, configs, listed MCP servers and screenshots alone do not count.

| Status | Count |
|---|---|
| VERIFIED_STRONG | 9 |
| VERIFIED_ACCEPTABLE | 27 |
| WEAK | 4 |
| PARTIAL | 41 |
| BROKEN | 1 |
| MISSING | 2 |
| OUTDATED | 1 |
| REDUNDANT | 1 |
| BLOCKED_EXTERNAL | 7 |
| INTENTIONALLY_EXCLUDED | 3 |

## Summary

| ID | Area | Capability | Status | Priority | Verification |
|---|---|---|---|---|---|
| [T01](#t01) | Agent tooling | Skills discoverable by Claude Code | VERIFIED_STRONG | P0 | Fresh Claude session init lists the repo skills; a plain task prompt made Claude load the matching skill unprompted; skills-sync gate step fails on a removed heading or renamed skill (checked in a scratch copy). |
| [T02](#t02) | Agent tooling | Skills discoverable by Codex | VERIFIED_ACCEPTABLE | P2 | Codex's own prompt rendering listed 20 of 20 repo skills before the integration. |
| [T03](#t03) | Agent tooling | Small permanent instructions shared by Claude and Codex | VERIFIED_STRONG | P2 | Fresh-session recall of imported content. |
| [T04](#t04) | Agent tooling | Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards | VERIFIED_ACCEPTABLE | P1 | Self-test in the pre-commit gate and CI (404/404 on the integrated branch); live denials observed; `guard_mcp` on a real Studio event pending (owner step). |
| [T05](#t05) | Agent tooling | Permission rules apply on a fresh checkout | BLOCKED_EXTERNAL | P3 | Warnings observed; deny protection still covered by `Edit(weppy-project-sync/**)`. |
| [T06](#t06) | Agent tooling | Specialist subagents with explicit ownership | VERIFIED_STRONG | P3 | Real parallel tasks completed and merged (5 workers, then 10 groups). |
| [T07](#t07) | Agent tooling | Repo gate (fast / pre-commit / pre-release) | VERIFIED_ACCEPTABLE | P1 | Both tiers on the integrated head in the container (nothing skipped); strict CI on 367cd72; strict CI on the integrated head pending. |
| [T08](#t08) | Agent tooling | Continuous integration | VERIFIED_ACCEPTABLE | P1 | Green strict CI on 367cd72; the integrated head is pending. |
| [T09](#t09) | Agent tooling | Pinned Luau toolchain | WEAK | P2 | `python3 tools/pc_doctor.py` on the PC shows PASS for path-order and toolchain:rojo (7.7.0). |
| [T10](#t10) | Agent tooling | Selene lint with the Roblox standard library | VERIFIED_ACCEPTABLE | P2 | Selene step green in CI; container run on the integrated head. |
| [T11](#t11) | Agent tooling | Rojo projects build from a clean clone | VERIFIED_STRONG | P2 | Rojo builds of all five projects in the container; five in the workflow, four run in CI so far. |
| [T12](#t12) | Agent tooling | Reusable project starter | VERIFIED_ACCEPTABLE | P1 | `starter-smoke` in the pre-commit gate and CI; `tools/starter_smoke.py`; Python unit tests. |
| [T13](#t13) | Agent tooling | Publish/spend guards and MCP settings for Codex | PARTIAL | P1 | Hook, rule and config parity in the pre-commit self-test; live Codex behaviour pending. |
| [T14](#t14) | Agent tooling | Engine probe runner and tier enforcement (studio_run, kit_tiers) | PARTIAL | P1 | `reports/engine/kitsmoke_all.json` PASS from the Studio CLI route; `kit_tiers.py --check` in the gate. |
| [T15](#t15) | Agent tooling | Luau type analysis with pinned definitions (luau-lsp) | PARTIAL | P2 | `luau_analyze.py` reports 0 files over on the integrated head in CI; on the PC the plugin shows diagnostics after an edit. |
| [T16](#t16) | Agent tooling | Owner-record write protection (release/owner-*.json) | PARTIAL | P2 | Self-test cases in the gate; Claude file-tool protection pending the settings change. |
| [T17](#t17) | Agent tooling | Starter boot skeleton and kit layout | PARTIAL | P2 | Lune specs in the scaffold (T0/T2); S07 owner record pending (T3). |
| [T18](#t18) | Agent tooling | Pinned optional dependencies with licence notices (starter bundles) | PARTIAL | P3 | Unit tests and starter smoke; CI in a game repo. |
| [L01](#l01) | Local workbench (PC) | Local workbench gate | BROKEN | P1 | `./.venv/Scripts/python.exe tools/check.py` passes on a quiet tree. |
| [L02](#l02) | Local workbench (PC) | Version control and rollback for the workbench | MISSING | P1 | `git log` shows a commit. |
| [L03](#l03) | Local workbench (PC) | Owner PC setup checks (pc_doctor, pinned PC tools, user-level skills copy) | PARTIAL | P2 | `python3 tools/pc_doctor.py` (with `--blender <exe>`) on the PC reports no FAIL. |
| [M01](#m01) | MCP and Studio | Built-in Roblox Studio MCP connection | VERIFIED_ACCEPTABLE | P1 | Live tool calls returned the expected results in Studio for the three recorded tools. |
| [M02](#m02) | MCP and Studio | Claude user-level Blender MCP | OUTDATED | P1 | `get_scene_info` answers from Claude in the repo. |
| [M03](#m03) | MCP and Studio | Blender MCP inside Codex | BLOCKED_EXTERNAL | P2 | Config parity in the self-test; live Codex connection pending. |
| [M04](#m04) | MCP and Studio | Blender MCP add-on telemetry off | WEAK | P1 | `python3 tools/pc_doctor.py --blender <exe>` shows telemetry:addon PASS on the PC. |
| [M05](#m05) | MCP and Studio | WEPPY bridge | REDUNDANT | P2 | Setting off, or a documented unique function. |
| [M06](#m06) | MCP and Studio | Codex global configuration | WEAK | P1 | Owner review. |
| [M07](#m07) | MCP and Studio | MCP audit per server (why, client, tools, permissions, ports, network, auth, telemetry, overlap, failure modes, health check) | VERIFIED_ACCEPTABLE | P2 | Table cross-checked against the installed package, the guards and the self-test. |
| [M08](#m08) | MCP and Studio | Tools from unconfigured MCP servers (claude.ai connectors, plugins, Codex apps) | PARTIAL | P2 | Codex catch-all in the self-test; Claude side pending the owner's choice. |
| [S01](#s01) | MCP and Studio | Studio testing modes (Test, Test Here, Run, Server & Clients) and device emulation | BLOCKED_EXTERNAL | P1 | Console output and captures saved under `reports/studio/`. |
| [S06](#s06) | MCP and Studio | Studio MCP operations beyond the core loop (property inspection, script read/edit, asset search/insert, console, camera, keyboard/mouse/character input) | BLOCKED_EXTERNAL | P1 | Pending: observed output of each tool on the PC. |
| [S02](#s02) | Scene authoring | SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune) | PARTIAL | P0 | Observed in Studio at 9c12091 only; HEAD pending the owner steps. |
| [S03](#s03) | Scene authoring | Scene-authoring API as data (buildings, props, lights and signs, interior dressing, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance) | VERIFIED_STRONG | P0 | Specs, fixture hashes, previews. |
| [S04](#s04) | Scene authoring | Measurement and player-scale helpers | VERIFIED_ACCEPTABLE | P2 | Specs. |
| [S05](#s05) | Scene authoring | Terrain, lighting presets and day/night cycle applied in Studio | PARTIAL | P2 | ENGINE_DONE ok for both probes and one capture per preset. |
| [S07](#s07) | Scene authoring | Model operations and selection scope (model.inspect, scale, pivot, material, collision, optimize) | PARTIAL | P2 | Specs in the gate; Studio pending. |
| [S08](#s08) | Scene authoring | Level dressing: lights, signs and interior props | PARTIAL | P2 | Specs in the gate; Studio pending. |
| [S09](#s09) | Scene authoring | Material library and MaterialService overrides (material-library/1) | PARTIAL | P2 | ENGINE_DONE ok plus a swatch capture. |
| [S10](#s10) | Scene authoring | Kit piece swap (kit/1) | PARTIAL | P2 | ENGINE_DONE ok for `lvl_kit_swap`. |
| [P01](#p01) | Procedural generation | Seeded generators (dungeon, cave, arena, settlement, forest, courses) | VERIFIED_STRONG | P0 | Specs and fixture hashes in the gate and CI. |
| [P02](#p02) | Procedural generation | Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance) | VERIFIED_ACCEPTABLE | P2 | Specs and fixture reports. |
| [P03](#p03) | Procedural generation | Determinism and manifests | VERIFIED_STRONG | P1 | Gate. |
| [P04](#p04) | Procedural generation | Forests and biome dressing | VERIFIED_ACCEPTABLE | P2 | Specs, seed sweeps and fixture hashes in the gate. |
| [P05](#p05) | Procedural generation | Course generators (linear, tower, race loop, lanes, micro-arena) | VERIFIED_ACCEPTABLE | P2 | Specs, sweeps and fixture hashes in the gate. |
| [B01](#b01) | Blender | Blender asset templates and QA reports (23 kinds) | VERIFIED_STRONG | P0 | Template and QA runs on three bpy versions; CI matrix; self-test proves known-bad assets fail. |
| [B02](#b02) | Blender | Blender built-ins in the factory (texture baking, Geometry Nodes, Asset Browser catalogs, Rigify) | PARTIAL | P2 | Headless bakes on three bpy versions; Studio half pending (probe `import_appearance`). |
| [B03](#b03) | Blender | Preview renders for visual QA | VERIFIED_ACCEPTABLE | P2 | Renders reviewed in this pass. |
| [B04](#b04) | Blender | Round trip, Blender half (create, revise, export, reimport, diff, expectation) | VERIFIED_STRONG | P0 | Runs in the pre-release gate and CI. |
| [B05](#b05) | Blender | Round trip, Studio half (3D Importer, then ImportInspector against the expectation) | PARTIAL | P0 | ImportInspector in Studio at 9c024fb: 6 of 7 checks passed for v1 and v2 and the revision was detected; the hardened and extended inspector is verified in Lune only. |
| [B06](#b06) | Blender | Material colour survives the Studio import | BLOCKED_EXTERNAL | P1 | Pending T3 probe `import_appearance`: a Studio import shows the baked colours and appearance_bound reports a texture. |
| [B07](#b07) | Blender | Rigged and animated asset into Studio (skinned mesh, bone names, animation clip) | BLOCKED_EXTERNAL | P1 | Pending T3 probe `import_clips`: inspector output in Studio saved under `reports/`. |
| [B08](#b08) | Blender | Retopology, LOD chains and smooth skin weighting (bkit) | VERIFIED_ACCEPTABLE | P2 | Self-test on three bpy versions in the pre-release gate and CI. |
| [B09](#b09) | Blender | Brush sculpting in scripts | INTENTIONALLY_EXCLUDED | P3 | Self-test case for the stand-in. |
| [B10](#b10) | Blender | Animation clip export (clips/1, multi-clip GLB) | VERIFIED_ACCEPTABLE | P2 | Executed headless on three bpy versions. |
| [B11](#b11) | Blender | Kit export (kit/1) and offline asset intake | VERIFIED_ACCEPTABLE | P2 | Executed headless on three bpy versions. |
| [B12](#b12) | Blender | glTF structural validation | VERIFIED_ACCEPTABLE | P2 | Unit tests and representative runs. |
| [R01](#r01) | Inherited modules | Inherited pure-Luau modules (ReceiptLedger, CommerceCatalog, Lifetime, Motion, AudioMixer, AudioDirector, EffectsPool, MovementProfile, AnimationInspector and WorldInspector maths, UI logic, FaultQueue) | VERIFIED_ACCEPTABLE | P2 | Inherited suites and new specs pass in the gate. |
| [R02](#r02) | Inherited modules | Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector) | WEAK | P2 | Fresh receipts with today's Studio version. |
| [K01](#k01) | Runtime kits | Runtime-kit foundation and contract (Env, Probe, Fsm, Signal, Scope, Retry, Events, Settings, Catalog; tiers, probe protocol, require allowlist) | VERIFIED_ACCEPTABLE | P1 | Lune specs and the tier report in the gate. |
| [K02](#k02) | Runtime kits | Player data with session locking and settings persistence (PlayerData, SettingsStore) | PARTIAL | P2 | ENGINE_DONE ok for `platform_playerdata_memory`; T4 never claimed. |
| [K03](#k03) | Runtime kits | Policy, text-filter, config and moderation gating (fail-closed) | PARTIAL | P2 | ENGINE_DONE ok for `platform_policy_emulator`. |
| [K04](#k04) | Runtime kits | Commerce: catalog/1 prompts, prices, ownership and receipts | PARTIAL | P2 | Lune specs; live purchases never claimed in this factory. |
| [K05](#k05) | Runtime kits | Matchmaking queue, teleport and party adapters | PARTIAL | P2 | ENGINE_DONE ok for `platform_party_simulator`. |
| [K06](#k06) | Runtime kits | Action gameplay kit (rounds, vitals, combat and hit validation, projectiles, zones, abilities, movement, vehicles, interaction, animation sets) | PARTIAL | P2 | ENGINE_DONE ok for the eight `action_` probes. |
| [K07](#k07) | Runtime kits | Server Authority fixture (BindToSimulation, Input Action System input) | PARTIAL | P1 | ENGINE_DONE ok for the four authority probes and a clean 2-client run. |
| [K08](#k08) | Runtime kits | Economy and progression kit (wallet, items, inventory, progression, objectives, streaks, crafting, generators, unlocks, seasons, live-ops, economy simulation) | VERIFIED_ACCEPTABLE | P2 | Lune specs and slice goldens in the gate. |
| [K09](#k09) | Runtime kits | Odds disclosure and paid-random policy gate | VERIFIED_ACCEPTABLE | P2 | Lune specs. |
| [K10](#k10) | Runtime kits | Trade escrow, plots, followers, outfits, dialogue, onboarding and voting | PARTIAL | P2 | ENGINE_DONE ok for the four `economy_` probes. |
| [K11](#k11) | Runtime kits | UI kit, components and transitions (packages/UIKit) | PARTIAL | P2 | ENGINE_DONE ok for the three probes plus gallery captures. |
| [K12](#k12) | Runtime kits | UI audits (touch target, contrast, text size, safe area, overlap, gamepad reach, legacy fonts, text fit) | PARTIAL | P2 | ENGINE_DONE ok for `ui_gallery_audit`. |
| [K13](#k13) | Runtime kits | Input map on the Input Action System (GameKit/InputMap, InputMapRoblox) | PARTIAL | P2 | ENGINE_DONE ok for `inputmap_contexts`. |
| [K14](#k14) | Runtime kits | Cutscenes and camera (cinematics/1) | PARTIAL | P2 | ENGINE_DONE ok for `cin_play_sample`. |
| [K15](#k15) | Runtime kits | VFX library (vfx/1) with pooling | PARTIAL | P2 | ENGINE_DONE ok plus a capture. |
| [K16](#k16) | Runtime kits | Audio graph, buses and cues (audio-graph/1) | PARTIAL | P2 | ENGINE_DONE ok with a peak above 0. |
| [K17](#k17) | Runtime kits | Game feel kit (springs, shake, hit-stop, popups, safe flashes, haptics, cues) | PARTIAL | P2 | ENGINE_DONE ok plus a recording. |
| [K18](#k18) | Runtime kits | AI kit (navigation, perception, behaviour trees, waves, checkpoints) | PARTIAL | P2 | ENGINE_DONE ok for both probes. |
| [K19](#k19) | Runtime kits | Placement grid, team balance and leaderboards | PARTIAL | P3 | Lune specs. |
| [K20](#k20) | Runtime kits | Kit smoke harness (all probe registries in one Studio run) | PARTIAL | P1 | `reports/engine/kitsmoke_all.json` PASS. |
| [K21](#k21) | Runtime kits | Cross-group integration slices (race, stalker AI, projectile arena, session persistence, UI onboarding, authority client) | VERIFIED_ACCEPTABLE | P2 | Lune spec with golden in the pre-commit gate. |
| [D01](#d01) | Research | Fresh tooling research with select/reject decisions | VERIFIED_ACCEPTABLE | P3 | Decisions applied: built-in Studio MCP, Rokit over Aftman, mcp-for-blender 2.1.8, bpy 5.2 LTS in CI, Open Cloud execution and asset uploads rejected for this factory. |
| [D02](#d02) | Research | Deep observational game dossiers | PARTIAL | P3 | n/a |
| [D03](#d03) | Research | In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution) | BLOCKED_EXTERNAL | P2 | CI job green. |
| [D04](#d04) | Research | Research and knowledge database | PARTIAL | P2 | Gate steps in pre-commit. |
| [X01](#x01) | Boundary | Publishing, asset upload, purchases, live products, ads | INTENTIONALLY_EXCLUDED | P0 | Self-test in the gate and CI. |
| [X02](#x02) | Boundary | Commercial game content (genre, theme, world, characters, economy, UI) | INTENTIONALLY_EXCLUDED | P0 | Review. |
| [Q01](#q01) | Production lab | Performance lab (budgets and profiling) | PARTIAL | P2 | `reports/engine/perf_capture.json` PASS from Studio; `Budgets.check` on device stats. |
| [Q02](#q02) | Production lab | Release readiness checks | VERIFIED_ACCEPTABLE | P3 | `tests/test_release_check.py` in the `python-unit` gate step; the game gate's `--tier pre-release`. |
| [Q03](#q03) | Production lab | Game security validation (server authority, remote validation, abuse tests) | PARTIAL | P2 | Lune refusal cases in the gate; multi-client Studio pending. |
| [Q04](#q04) | Production lab | Visual regression | PARTIAL | P2 | Hash goldens in the gate; `capture-staleness` gate step (non-fatal); image diff not built. |
| [Q05](#q05) | Production lab | Visual-reference library | MISSING | P3 | None. |
| [Q06](#q06) | Production lab | Asset sourcing and approval (intake, provenance) | VERIFIED_ACCEPTABLE | P2 | Gate step with a negative self-test. |
| [Q07](#q07) | Production lab | Gameplay-system library | PARTIAL | P3 | Full Lune suite in the gate; kit-tiers report; Studio pending. |
| [Q08](#q08) | Production lab | Analytics (telemetry and offline report) | PARTIAL | P3 | Python and Lune tests in the gate; Studio pending. |
| [Q09](#q09) | Production lab | Genre playbooks and taxonomy (29 playbooks, 17 genres, 43 subgenres) | VERIFIED_ACCEPTABLE | P3 | Lint and unit tests. |
| [Q10](#q10) | Production lab | Neutral production pipeline (brief, stages, issue drafts) | VERIFIED_ACCEPTABLE | P3 | Unit tests and starter smoke. |
| [Q11](#q11) | Production lab | CC0 asset fetch with provenance | PARTIAL | P2 | One real item pinned with a matching sha256. |

## Steps that need the owner's machine or decision

**T02 Skills discoverable by Codex** (VERIFIED_ACCEPTABLE)

1. Optional: run `codex` in the repo on the PC, open `/skills` (expect the 23 names in `.agents/skills/`) and ask for a seeded cave layout to see it load `roblox-procedural-generation`.

**T04 Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards** (VERIFIED_ACCEPTABLE)

1. On the PC, in Claude Code in this repo: ask for an `execute_luau` that calls `DataStoreService:GetDataStore("probe"):SetAsync("k", 1)` on the diagnostic place and confirm Claude asks first (decline it).
2. Apply the `.claude/settings.json` change set in `docs/mcp.md` (section "Owner step: proposed `.claude/settings.json` changes": Studio read allows, `http_get` and `subagent` asks, the Blender asset-tool, `asphalt upload` and `Edit(release/owner-*.json)` denies, removal of the redundant `Write(weppy-project-sync/**)`, the `Edit|Write|MultiEdit|NotebookEdit` guard matcher, 10 s hook timeouts, and item 5 for connectors), then run `node tools/hooks/selftest.mjs`; it fails if a rule disagrees with `guard_mcp`.

**T05 Permission rules apply on a fresh checkout** (BLOCKED_EXTERNAL)

1. Open Claude Code in the repo once and accept the trust prompt and the project MCP servers.
2. Optional: delete the `Write(weppy-project-sync/**)` line from `.claude/settings.json` (item 3 of the `docs/mcp.md` change set).

**T09 Pinned Luau toolchain** (WEAK)

1. Windows Settings > Environment Variables > Path: move `%USERPROFILE%\.rokit\bin` above `%USERPROFILE%\.aftman\bin` (or remove the Aftman entry); see `docs/pc-setup.md` item 7.
2. Open a new terminal, run `python3 tools/pc_doctor.py`, and expect path-order PASS and toolchain:rojo 7.7.0.

**T13 Publish/spend guards and MCP settings for Codex** (PARTIAL)

1. Open Codex in this repo on the PC, trust the project, run `/hooks` and trust all three hooks (the hashes changed and there is a new file-edit hook).
2. Check: `codex execpolicy check --rules .codex/rules/factory.rules -- rojo upload x` prints `forbidden`, and asking Codex to run `rojo upload` is refused.

**T14 Engine probe runner and tier enforcement (studio_run, kit_tiers)** (PARTIAL)

1. On the PC, prepare the kits place (K20) and run `python3 tools/studio_run.py --probe kitsmoke_all`, then `--probe perf_capture`.
2. Run `python3 tools/kit_tiers.py` to join the new reports and commit `reports/engine/` and `reports/kit-tiers.json`.

**T15 Luau type analysis with pinned definitions (luau-lsp)** (PARTIAL)

1. Optional, on the PC: install the plugin as `docs/pc-setup.md` (section "Claude Code luau-lsp plugin") describes and confirm diagnostics appear after an edit.

**T16 Owner-record write protection (release/owner-*.json)** (PARTIAL)

1. Apply items 3 and 4 of the `docs/mcp.md` settings change set, then ask Claude to edit a scratch `release/owner-test.json` and confirm it is denied.

**T17 Starter boot skeleton and kit layout** (PARTIAL)

1. Scaffold a scratch repo outside the factory (`python3 tools/new_project.py <folder> --name BootCheck`), build its place with Rojo, open it unpublished, run Play Solo and then Server & Clients with 2 players, and check one `BOOT_REPORT` line per side with every phase ok.

**L01 Local workbench gate** (BROKEN)

1. When the Codex run finishes, run `./.venv/Scripts/python.exe tools/check.py` in the workbench folder.

**L02 Version control and rollback for the workbench** (MISSING)

1. With Codex idle: `git add -A` then `git commit -m "workbench snapshot"` in the workbench folder (check `.gitignore` excludes `.venv`, `backups/` and large media first).

**L03 Owner PC setup checks (pc_doctor, pinned PC tools, user-level skills copy)** (PARTIAL)

1. Work through `docs/pc-setup.md` items 1 to 9 (installs, the tools folder, PATH order, telemetry, the user-skills copy).
2. Run `python3 tools/pc_doctor.py --blender <Blender executable>` and fix any FAIL as the doc says.

**M02 Claude user-level Blender MCP** (OUTDATED)

1. `claude mcp remove blender -s user`
2. Start Blender 5.1.2 with the 2.1.8 add-on connected, open Claude Code in the repo, approve the `blender` project server, and ask for `get_scene_info`.

**M03 Blender MCP inside Codex** (BLOCKED_EXTERNAL)

1. Open Codex in this repo on the PC and trust the project and its three hooks, then `codex mcp list` (expect `Roblox_Studio` and `blender`).
2. With Blender 5.1.2 open and the 2.1.8 add-on connected, ask Codex for `get_scene_info` and confirm the three disabled asset tools are not offered.

**M04 Blender MCP add-on telemetry off** (WEAK)

1. Blender > Edit > Preferences > Add-ons > Blender MCP: untick telemetry, then Save Preferences (`docs/pc-setup.md` item 8).
2. Run `python3 tools/pc_doctor.py --blender <Blender executable>` and expect telemetry:addon PASS.

**M06 Codex global configuration** (WEAK)

1. Review the Codex section of the private local-audit note and tighten `~/.codex/config.toml` (approval on request, workspace-write sandbox, only needed browser origins).

**M08 Tools from unconfigured MCP servers (claude.ai connectors, plugins, Codex apps)** (PARTIAL)

1. Decide item 5 of the `docs/mcp.md` settings change set (Option A, Option B, both or neither), apply it in `.claude/settings.json` and run `node tools/hooks/selftest.mjs`.

**S01 Studio testing modes (Test, Test Here, Run, Server & Clients) and device emulation** (BLOCKED_EXTERNAL)

1. Covered by S02 (Run mode). For multi-client: run `python3 tools/network_manifest.py`, `rojo build fixtures/network.project.json -o build/network.rbxl`, open that place in Studio (it stays unpublished), Test > Clients and Servers > 2 players > Start, then `get_console_output`.
2. Device emulation: Test > Device (phone, then tablet) on the diagnostic place, `screen_capture` each, and record the result under `reports/studio/`.
3. Kits place: prepare it as in K20, set `SETUP_ONLY_KitFixture` to `kitsmoke`, press Play (then Test > Clients and Servers with 2 players), save the Output under `build/`, and run `python3 tools/studio_run.py --probe kitsmoke_all --from-output build/<file>.txt`.

**S06 Studio MCP operations beyond the core loop (property inspection, script read/edit, asset search/insert, console, camera, keyboard/mouse/character input)** (BLOCKED_EXTERNAL)

1. In Claude Code on the PC with SETUP_ONLY_Factory_Diagnostic open: `inspect_instance` on the SETUP_ONLY_ModularBuilding model; `script_read` then `multi_edit` on a scratch Script that Rojo does not manage; `search_asset` with a neutral query (no insert unless you approve it).
2. `start_stop_play` (Test), then `user_keyboard_input` (hold W for a second), `user_mouse_input`, `character_navigation` to a point, `get_console_output` and `screen_capture`; set the camera through `execute_luau` and capture again.
3. Call `skill` and `subagent` once each on the diagnostic place (Claude should ask before `subagent`) and note which tools `subagent` was able to call.
4. Save the outputs as `reports/studio/operations-<date>.json`.

**S02 SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** (PARTIAL)

1. Pull the PR branch, `rojo build fixtures/factory.project.json -o SETUP_ONLY_Factory_Diagnostic.rbxl` with Rokit's rojo, open it in Studio (unpublished).
2. `execute_luau`: `return game:GetService("HttpService"):JSONEncode(require(game.ReplicatedStorage.Workbench.Pipeline.FactorySmoke).run(workspace))`; compare with `tests/golden/studio-smoke.json`, then undo twice.
3. Set `ServerScriptService.FactorySmoke.Enabled = true`, `start_stop_play` in Run mode, approve the console read, check `FACTORY_SMOKE` in `get_console_output`, stop play and set Enabled back to false.

**S05 Terrain, lighting presets and day/night cycle applied in Studio** (PARTIAL)

1. On the kits place prepared as in K20, set `SETUP_ONLY_KitFixture` to `lookdev`, run `tests/engine/av_lighting_presets.luau` and `tests/engine/worldcycle_phases.luau` (`docs/presentation.md`), press Play, cycle the presets with L and `screen_capture` each.

**S09 Material library and MaterialService overrides (material-library/1)** (PARTIAL)

1. On the kits place prepared as in K20 with `SETUP_ONLY_KitFixture = lookdev`, run `python3 tools/studio_run.py --probe lookdev_material_override` and capture the swatches.

**S10 Kit piece swap (kit/1)** (PARTIAL)

1. On the kits place prepared as in K20, run `python3 tools/studio_run.py --probe lvl_kit_swap`.

**P05 Course generators (linear, tower, race loop, lanes, micro-arena)** (VERIFIED_ACCEPTABLE)

1. On the kits place prepared as in K20, run `python3 tools/studio_run.py --probe lvl_course_run`.

**B05 Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** (PARTIAL)

1. Pull the integrated branch on the PC and run `python3 tools/blender/factory.py roundtrip build/roundtrip` (or `blender -b --python tools/blender/factory.py -- roundtrip build/roundtrip`). It writes the fixed, palette-baked marker, its colour map and its expectations.
2. In SETUP_ONLY_Factory_Diagnostic, Import 3D `build/roundtrip/SM_RoundTripMarker_v2.fbx` (Scale Unit Stud, Insert In Workspace and Insert Using Scene Position on). This is one more private upload (mesh plus colour image).
3. `execute_luau`: `ImportInspector.inspect` on the new model with `build/roundtrip/roblox_expectation_v2.json`, or run `tests/engine/import_appearance.luau`; pivot_base_centre, orientation_side and appearance_bound should pass.

**B06 Material colour survives the Studio import** (BLOCKED_EXTERNAL)

1. Approve one private upload (mesh plus colour image) and Import 3D a baked asset into the unpublished diagnostic place: the marker v2 from B05 (same import) or a template FBX from `build/blender/<kind>/`.
2. Run `tests/engine/import_appearance.luau` (or `ImportInspector.inspect`) on it and save the output under `reports/engine/` or `reports/studio/`.

**B07 Rigged and animated asset into Studio (skinned mesh, bone names, animation clip)** (BLOCKED_EXTERNAL)

1. Approve one more private upload, then Import 3D `pet_follower_clips.glb` (or one clip FBX) from `build/blender/` with rig and animation on into the diagnostic place.
2. Paste the clips/1 sidecar into `ReplicatedStorage.ImportClips`, run `tests/engine/import_clips.luau` and save the result; it also records whether clips land in the model or in `ServerStorage.RBX_ANIMSAVES`.
3. Optionally import the humanoid template and `auto_weighted_humanoid.fbx` (B08) and check that the Bone names match and the mesh deforms when a bone is rotated.

**R02 Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector)** (WEAK)

1. Build the creator and diagnostic places (`rojo build fixtures/creator.project.json -o build/creator.rbxl`, likewise diagnostic after `python3 tools/network_manifest.py` if needed), open each unpublished, press Play and save the console output of the UI and Diagnostic client fixtures under `reports/studio/`.

**K01 Runtime-kit foundation and contract (Env, Probe, Fsm, Signal, Scope, Retry, Events, Settings, Catalog; tiers, probe protocol, require allowlist)** (VERIFIED_ACCEPTABLE)

1. On the kits place prepared as in K20, run `python3 tools/studio_run.py --probe foundation_env_studio`.

**K02 Player data with session locking and settings persistence (PlayerData, SettingsStore)** (PARTIAL)

1. On the kits place prepared as in K20, run `platform_playerdata_memory` in a play session as `docs/gamekit-platform.md` ("Studio probes (owner steps)") describes (memory backend, no DataStores).

**K03 Policy, text-filter, config and moderation gating (fail-closed)** (PARTIAL)

1. On the kits place prepared as in K20, run `platform_policy_emulator` once per Player Emulator region with the test profile enabled (`docs/gamekit-platform.md`, "Studio probes (owner steps)").

**K05 Matchmaking queue, teleport and party adapters** (PARTIAL)

1. On the kits place prepared as in K20, run `platform_party_simulator` in Server & Clients with two or more clients placed in one party with the Party Simulator (`docs/gamekit-platform.md`).

**K06 Action gameplay kit (rounds, vitals, combat and hit validation, projectiles, zones, abilities, movement, vehicles, interaction, animation sets)** (PARTIAL)

1. On the kits place prepared as in K20 (AuthorityMode Server), run each `tests/engine/action_*.luau` entry, for example `python3 tools/studio_run.py --probe action_hitbox_shapecast` (`docs/gamekit-action.md` section 15).

**K07 Server Authority fixture (BindToSimulation, Input Action System input)** (PARTIAL)

1. On the kits place prepared as in K20 (AuthorityMode Server), run `tests/engine/action_authority_suite.luau`.
2. Set `SETUP_ONLY_KitFixture` to `authority`, start Test > Clients and Servers with 2 players, move and fire from both clients, and save the server and client Output under `reports/studio/`.

**K10 Trade escrow, plots, followers, outfits, dialogue, onboarding and voting** (PARTIAL)

1. On the kits place prepared as in K20, run `economy_followers_formation`, `economy_outfits_apply` and `economy_plots_claim_race` in a play session, and `economy_trade_two_client` in Server & Clients with 2 players (`docs/gamekit-economy.md`, "Probes and verification").

**K11 UI kit, components and transitions (packages/UIKit)** (PARTIAL)

1. On the kits place prepared as in K20, set `SETUP_ONLY_KitFixture` to `ui-gallery`, press Play, run the `ui_ease_parity`, `ui_style_sheet` and `ui_nav_keyboard` entries in the client session (`tests/engine/README.md`, play-session runs) and capture each story at phone and desktop sizes.

**K12 UI audits (touch target, contrast, text size, safe area, overlap, gamepad reach, legacy fonts, text fit)** (PARTIAL)

1. In the K11 gallery session, run `tests/engine/ui_gallery_audit.luau` and keep its output.

**K13 Input map on the Input Action System (GameKit/InputMap, InputMapRoblox)** (PARTIAL)

1. In a client play session on the kits place prepared as in K20, run `tests/engine/inputmap_contexts.luau`.

**K14 Cutscenes and camera (cinematics/1)** (PARTIAL)

1. In a client play session on the kits place prepared as in K20, run `tests/engine/cin_play_sample.luau`.

**K15 VFX library (vfx/1) with pooling** (PARTIAL)

1. On the kits place prepared as in K20 with `SETUP_ONLY_KitFixture = lookdev`, run `tests/engine/av_vfx_grid.luau` and capture the VFX grid.

**K16 Audio graph, buses and cues (audio-graph/1)** (PARTIAL)

1. On the kits place prepared as in K20, run `tests/engine/av_audiograph_wires.luau` and `tests/engine/av_audio_master_level.luau` (`docs/presentation.md`).

**K17 Game feel kit (springs, shake, hit-stop, popups, safe flashes, haptics, cues)** (PARTIAL)

1. On the kits place prepared as in K20 with the lookdev fixture, run `tests/engine/feel_marker_cue.luau` and record a short screen capture of the cues.

**K18 AI kit (navigation, perception, behaviour trees, waves, checkpoints)** (PARTIAL)

1. On the kits place prepared as in K20, run `python3 tools/studio_run.py --probe lvl_pathfinding_probe` and `--probe lvl_navagent_door`.

**K20 Kit smoke harness (all probe registries in one Studio run)** (PARTIAL)

1. Prepare the kits place once: `rojo build fixtures/kits.project.json -o build/kits.rbxl`, open it unpublished in Studio, set `Workspace.AuthorityMode = Server` (it cannot be set from script) and save; later runs omit `--build` so the setting stays.
2. Run `python3 tools/studio_run.py --probe kitsmoke_all`, then the play-session route for client probes (S01).

**D03 In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution)** (BLOCKED_EXTERNAL)

1. Only in a future game repository, and only if the owner authorises a private test universe: Wally `jsdotlua/jest`, upload the test place version, run via the Luau Execution API with the key in CI secrets. Its scripts can read and modify DataStores, so use a universe with no production data.

**Q01 Performance lab (budgets and profiling)** (PARTIAL)

1. On the kits place prepared as in K20, run `python3 tools/studio_run.py --probe perf_capture`, then `perf_capture_client` in a play session (`tests/engine/README.md`).

**Q03 Game security validation (server authority, remote validation, abuse tests)** (PARTIAL)

1. On the kits place prepared as in K20, run `platform_remoteguard_flood` in a play session and then the Server & Clients flood test in `docs/gamekit-platform.md` ("Studio probes (owner steps)"); expect no accepted calls, 10 schema rejects, then rate rejects.
2. Run the authority fixture with 2 clients (K07).

**Q08 Analytics (telemetry and offline report)** (PARTIAL)

1. On the kits place prepared as in K20, run `platform_telemetry_recorder` in a play session and feed its `TELEMETRY_JSON` lines to `python3 tools/analytics_report.py --console` (`docs/gamekit-platform.md`).

**Q11 CC0 asset fetch with provenance** (PARTIAL)

1. On the PC (network allowed): `python3 tools/fetch_assets.py --list`, a dry run for one small CC0 item (`--source <key> --item <id>`), then the same with `--pin --purpose <reason>`; check the sha256 and the new `files` entry, and keep the download in `build/asset-cache`.


## Rows

### T01

**Skills discoverable by Claude Code** · Agent tooling · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** GitHub repo: 25 Roblox pass skills. Workbench: 7 Codex skills discovered.
- **ACTUAL STATE:** The repo held 25 loose `roblox-*/skill.md` files (lowercase name, escaped markdown, 11 genre checklists; 2 of them, multiplayer-state-fix and persistence-and-rewards-audit, were empty). Neither Claude nor Codex looked in those folders. Now 23 skills live in `.agents/skills/` and are mirrored to `.claude/skills/`; the runtime-kit integration added `roblox-gameplay-kit`, `roblox-presentation-pass` and `roblox-production-pipeline` and updated 19 others, each keeping the ten sections.
- **EVIDENCE:** Commit 054af82 tree. A fresh headless Claude Code 2.1.289 session in this repo listed all 19 repo skills in its init event (before `project-bootstrap` was added; Codex's rendering lists all 20, T02). Usage probe 2026-10-06 (`reports/skill-usage-2026-10-06.json`): a Claude Code subagent given only the task "generate a seeded cave layout for seed 7 and validate it" called the Skill tool for `roblox-procedural-generation` as its first action, followed it, and returned hash 1289b461 with 11 of 11 validators passing (re-run by the coordinator: same hash). On the integrated branch `python3 tools/sync_skills.py --check` (pre-commit gate, CI) reports 23 skills, 0 errors; the three newest have not been listed by a fresh session yet.
- **DEFECT:** No agent ever loaded the old guidance.
- **ROOT CAUSE:** Uploaded without the SKILL.md / skills-directory conventions.
- **IMPACT:** All earlier skill guidance was dead text.
- **FIX:** Rewrote into focused skills (23 now, including `project-bootstrap`), each with the ten sections Purpose, Triggers, Inputs, Required context, Tools, Procedure, Outputs, Acceptance, Failure and Related. `sync_skills.py --check` enforces them plus frontmatter, name = directory, description, size and LF line endings (read as bytes, with a built-in CRLF self-test; `.gitattributes` keeps skill files LF on Windows checkouts). Legacy checklists moved to `references/`; old root folders removed.
- **VERIFICATION:** Fresh Claude session init lists the repo skills; a plain task prompt made Claude load the matching skill unprompted; skills-sync gate step fails on a removed heading or renamed skill (checked in a scratch copy).

### T02

**Skills discoverable by Codex** · Agent tooling · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Workbench `tools/check_skill_discovery.py` verified 7 skills through the Codex app server.
- **ACTUAL STATE:** This repo uses the `.agents/skills/<name>/SKILL.md` layout Codex reads. codex-cli 0.160.1 (installed in a scratch folder, not logged in) rendered the model-visible input for a fresh session in a clean export of the branch: its skills list named all 20 repo skills of that time from `.agents/skills`, and AGENTS.md is included. The three skills added by the runtime-kit integration (23 now) use the same layout but have not been rendered by Codex.
- **EVIDENCE:** `reports/codex-skills-2026-10-06.json` (`codex debug prompt-input` in a `git archive` export with an empty CODEX_HOME; 20 of 20 skills listed, none missing).
- **DEFECT:** No live Codex model turn has chosen and followed a skill (needs a Codex login). The three newest skills were not re-rendered (no codex CLI in the integration pass).
- **ROOT CAUSE:** No Codex login in the cloud session.
- **IMPACT:** Low: discovery is proven; use was proven for Claude (T01).
- **FIX:** Discovery verified with the real CLI; a live turn on the PC remains optional.
- **VERIFICATION:** Codex's own prompt rendering listed 20 of 20 repo skills before the integration.

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
- **ACTUAL STATE:** PostToolUse `fast_on_edit` (format, JSON, secrets from `tools/hooks/secret-patterns.json`, SKILL.md rules). PreToolUse `guard_bash` parses commands (argv, runners and wrappers such as npx and xargs, variables, PowerShell parameter prefixes, inline script bodies) and denies publish/upload tools, package-registry publishing and auth (`wally publish/login/logout`, `pesde publish/yank/deprecate/auth`), write requests to Roblox web APIs (curl, wget, httpie, PowerShell, inline scripts) including URLs hidden in variables, force pushes or deletions of main/master in any spelling, writes to owner records `release/owner-*.json` (T16), command lines over 64 KiB, and anything but known read-only commands on a line that names `weppy-project-sync/`. `guard_mcp` checks every string in a Studio or Blender tool input and classifies all 26 Studio tools: it denies publishing or asset/place-creating Luau, completed purchases, subscription, Premium, Robux-transfer and bulk purchase prompts, the Blender asset tools (`generate_3d`, `import_asset`, `search_assets` and the 1.x generate/import/download/poll tools) and Blender Python that publishes or writes to a Roblox web API; it asks before asset/quota Studio tools, Studio `subagent` (its own tool calls bypass the hooks), other purchase prompts, DataStore/MemoryStore writes, Blender Python that imports network/shell modules or builds code, unknown Studio or Blender tools, and tools of servers the factory does not configure (GitHub reads pass; M08). `tools/check.py` provides the pre-commit and pre-release tiers and installs a git pre-commit hook. The same guards run under Codex (T13).
- **EVIDENCE:** `node tools/hooks/selftest.mjs` (pre-commit gate and CI), re-run on the integrated branch: 404/404 hook cases in both directions (101 named regressions for the eight first-audit bypasses HOOK-1 to HOOK-8, 93 named second-pass cases GUARD-1 to GUARD-5), 4 near-64 KiB command shapes denied within the hook timeout, all 26 Studio tools classified with no `.claude/settings.json` rule disagreeing with `guard_mcp`, and 17 secret samples checked against both the edit hook and `tools/check.py`. Earlier: a mutation check broke each guard rule in turn and the self-test caught 22 of 22; live in a session the guard denied a heredoc containing a publish command and a Python heredoc that named the protected folder; 3011 distinct Bash commands of that session were replayed through the guard and the 10 changed decisions were audit probe commands (session-only, not reproducible from the repo). The earlier "1514-command corpus" claim had no artifact in the repo and is withdrawn.
- **DEFECT:** Guards match text, so code that builds tool names or URLs at run time, scripts run from files, and aliases stored in git or shell config are not covered (documented in the guard headers and `docs/mcp.md`). `guard_mcp` has never run on a real Studio event. Under Claude, file-edit tools on owner records and tools of unconfigured MCP servers stay unguarded until the owner applies the `docs/mcp.md` settings change set (T16, M08). The folder and owner-record rules are deliberately conservative: an interpreter line that merely mentions them is denied, so text about them is edited with the Edit tool.
- **ROOT CAUSE:** Hooks inspect command text, not runtime behaviour.
- **IMPACT:** Residual risk if an agent is manipulated into hiding a publish call in a script file; deny rules, Studio's own prompts and the account's lack of live products remain.
- **FIX:** Rewritten after two rounds of review findings (curl form/data uploads, DataStore writes, flag-order and refspec force pushes, CreateAssetVersionAsync, purchase prompts, folder redirects, rojo global flags, runner and xargs wrappers, httpie, oversized lines, MCP input fields other than `code`); the integration pass added the 26-tool Studio classification, purchase-prompt and Blender asset-tool denials, registry and owner-record rules and the unknown-server ask. No hook can publish or spend: they only return allow, ask or deny.
- **VERIFICATION:** Self-test in the pre-commit gate and CI (404/404 on the integrated branch); live denials observed; `guard_mcp` on a real Studio event pending (owner step).

### T05

**Permission rules apply on a fresh checkout** · Agent tooling · BLOCKED_EXTERNAL · P3

- **PREVIOUS CLAIM:** n/a (new in this pass)
- **ACTUAL STATE:** Claude ignores the 21 `permissions.allow` entries until the workspace is trusted; deny rules and hooks still apply. Claude also reports that `Write(weppy-project-sync/**)` in the deny list is never matched because `Edit(...)` rules cover every file-editing tool.
- **EVIDENCE:** Fresh headless Claude Code 2.1.289 sessions printed both warnings.
- **DEFECT:** Until trusted, every Studio read tool prompts. The `Write(...)` deny entry is redundant (the `Edit(...)` entry already protects the folder).
- **ROOT CAUSE:** Claude Code workspace-trust design; Edit rules cover Write.
- **IMPACT:** Friction on first run; no safety gap.
- **FIX:** Documented in CLAUDE.md. Removing the redundant entry from `.claude/settings.json` was blocked for this session (an agent may not edit the settings that govern it), so it is left for the owner; it is part of the `docs/mcp.md` settings change set (T04).
- **VERIFICATION:** Warnings observed; deny protection still covered by `Edit(weppy-project-sync/**)`.

### T06

**Specialist subagents with explicit ownership** · Agent tooling · VERIFIED_STRONG · P3

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.claude/agents/`: roblox-engineer (packages, tests), technical-artist (Blender), qa-reviewer (read-only), researcher (docs/research). File ownership table in `docs/architecture.md`; Codex follows the same table via AGENTS.md.
- **EVIDENCE:** Fresh Claude session init lists all four agents. On 2026-10-05 a workflow ran roblox-engineer (ProcGen, SceneKit), technical-artist (Blender QA) and general-purpose engineers in five isolated worktrees with disjoint file sets, each checked by a read-only qa-reviewer; all five merged without code conflicts (only the regenerated golden hash file overlapped). On 2026-10-06 ten build groups (G1 to G8, G9a, G9b) worked in separate worktrees from one frozen contract (`docs/runtime-kits.md`, section 11 ownership list); their commits were integrated onto one branch where the full Lune suite (1214 cases after the K21 slices) and the Python tests (183) pass.
- **DEFECT:** None open.
- **ROOT CAUSE:** n/a
- **IMPACT:** Low.
- **FIX:** n/a
- **VERIFICATION:** Real parallel tasks completed and merged (5 workers, then 10 groups).

### T07

**Repo gate (fast / pre-commit / pre-release)** · Agent tooling · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** Workbench `tools/check.py` 43 checks passed at 19:43Z.
- **ACTUAL STATE:** `tools/check.py` runs StyLua, JSON, the shared-pattern secret scan over every committable file, skills sync, gap matrix, doc links (relative links, heading anchors, well-formed URLs), the knowledge index and record paths, the fixtures README, asset provenance, Rojo sourcemaps of every project (orphan `.luau` files fail), a self-test that feeds each content check a broken input, hook self-test, Selene, Lune specs, the inherited suites, fixture builds with golden hashes (added, removed and changed fixtures fail; a missing golden fails) and the project-starter smoke; pre-release adds Blender templates, round trip, QA self-test and previews. Without `--strict`, Selene and (pre-release only) `luau-lsp-analyze` may skip; any other skipped step fails, in the installed git hook too; `--strict` (CI) allows none. `--update-golden` rewrites every golden, `--update-golden=NAME[,NAME]` only the named ones (fixture-hashes, studio-smoke or a spec golden), and a `golden-update` step lists what changed. For the runtime kits, pre-commit also runs `python-unit` (every `tests/test_*.py`), `playbook-lint`, `asset-sources`, `luau-defs-lock`, `kit-tiers` and `capture-staleness` (non-fatal), and pre-release runs `material-library`, `blender-kit`, `gltf-validate-templates`, previews of the five course fixtures, `luau-lsp-analyze` and `starter-smoke-full`.
- **EVIDENCE:** Both tiers passed in GitHub Actions in strict mode with nothing skipped (run 37393231152 on 367cd72). Planted broken inputs (bad link and anchor, malformed URL, unregistered asset id, orphan `.luau`, undocumented fixture, a workbench record claiming 'verified', stale index, missing golden, missing core tools) each failed the gate in a scratch copy; an intended SceneKit change went green with one `--update-golden`. On the integrated head (fd29fd6) in the cloud container, with a locally generated Roblox std and a source-built luau-lsp 1.70.1: pre-commit PASS with nothing skipped (Selene 0 errors, 183 Python tests, kit-tiers, 1214 Lune cases) and pre-release PASS with nothing skipped on bpy 5.0.1, 5.1.2 and 5.2.2 (Blender templates, round trip, QA self-test, material library, kit bake, glTF validation, 9 previews, luau-lsp 0 files over, full starter smoke).
- **DEFECT:** The integrated head has not run in strict CI yet.
- **ROOT CAUSE:** New steps and ten groups' code landed together.
- **IMPACT:** Until CI runs, a step that only fails under `--strict` or on Windows/CI tooling would go unnoticed.
- **FIX:** Push and keep both tiers green in strict CI on the PR head.
- **VERIFICATION:** Both tiers on the integrated head in the container (nothing skipped); strict CI on 367cd72; strict CI on the integrated head pending.

### T08

**Continuous integration** · Agent tooling · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.github/workflows/factory.yml`: a pre-commit job (Rokit toolchain, Selene std generation, Rojo builds of the projects, `--tier pre-commit --strict`) and a Blender matrix on bpy 5.1.2 (the PC's version) and 5.2.2 LTS that runs `--tier pre-release --strict`. The integration (c70ff63) added the `kits` place to the Rojo build loop and the luau-lsp steps (`rokit install`, `python3 tools/luau_defs.py`, then `luau-lsp-analyze` inside the pre-release tier); the current workflow has not run in CI yet.
- **EVIDENCE:** Runs 3 to 5 passed (pre-commit gate with Selene and nothing skipped, Blender templates and round trip on both bpy versions). Run 37393231152 on 367cd72 passed all three jobs in strict mode (pre-commit with Selene, pre-release on bpy 5.1.2 and 5.2.2).
- **DEFECT:** Not yet run on the integrated head. Untested in Actions: the kits place build, the rokit download of luau-lsp 1.70.1 (the release asset was refused in the cloud container, so G9b built it from source) and every new gate step.
- **ROOT CAUSE:** The integration has not been pushed yet.
- **IMPACT:** CI-only failures (toolchain downloads, strict skips) are unknown for the integrated head.
- **FIX:** Push the integrated branch and keep strict CI green on the PR head; if rokit cannot fetch luau-lsp, build it from source at tag 1.70.1.
- **VERIFICATION:** Green strict CI on 367cd72; the integrated head is pending.

### T09

**Pinned Luau toolchain** · Agent tooling · WEAK · P2

- **PREVIOUS CLAIM:** Bootstrap and toolchain partially verified; explicit Rokit binaries. Earlier in this pass: luau-lsp pinned at 1.68.1 and never run.
- **ACTUAL STATE:** `rokit.toml` pins rojo 7.7.0, lune 0.10.5, stylua 2.5.2, selene 0.31.0 and luau-lsp 1.70.1, matching the PC except luau-lsp. `templates/pc-tools/rokit.toml` pins the same set plus darklua 0.19.0 (MIT) and Wally 0.3.2 (MPL-2.0) for an owner tools folder. `tools/pc_doctor.py` (read-only) checks every pin, the Rokit-before-Aftman PATH order and the tools folder; `docs/pc-setup.md` item 7 gives the fix. On the PC, Aftman's shim directory precedes Rokit's on PATH, so a bare `rojo` resolves to Aftman and fails.
- **EVIDENCE:** Local audit (`where rojo`, PATH order). `tests/test_pc_doctor.py` (9, fake PATH; passes on the integrated branch): Aftman first gives FAIL for path-order and toolchain:rojo, and a wrong version is reported. CI installs the pinned set with `rokit install`; the cloud container built lune, stylua and selene at the pinned versions (rojo 7.7.1 from crates) and luau-lsp 1.70.1 from source at the pinned tag (the release download was refused).
- **DEFECT:** PATH order on the PC is still unfixed and unverified.
- **ROOT CAUSE:** Aftman installed before Rokit; both add shims.
- **IMPACT:** Agents and humans running bare `rojo` on the PC get an error.
- **FIX:** Put `%USERPROFILE%\.rokit\bin` before `%USERPROFILE%\.aftman\bin`, or uninstall Aftman (Rokit reads aftman.toml).
- **VERIFICATION:** `python3 tools/pc_doctor.py` on the PC shows PASS for path-order and toolchain:rojo (7.7.0).

### T10

**Selene lint with the Roblox standard library** · Agent tooling · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Selene in the workbench gate.
- **ACTUAL STATE:** A plain `selene generate-roblox-std` fails TLS through the cloud proxy, so a fresh container with no `roblox.yml` reports Selene SKIPPED. CI generates the std first and lints `packages` with it.
- **EVIDENCE:** GitHub Actions run 3 (1eee84a): `[ok  ] selene`. On the integrated head this container used a Roblox std generated from a locally served API dump: c70ff63 fixed the 2 errors and 3 warnings it found in kit code and 1 in the starter's Boot.luau, and the pre-commit gate's `selene packages` reports 0 errors, 0 warnings and 0 parse errors (fd29fd6).
- **DEFECT:** Strict CI has not run Selene on the integrated head yet.
- **ROOT CAUSE:** The proxy's TLS interception breaks selene's own fetch of the API dump.
- **IMPACT:** Lint regressions would only show in CI.
- **FIX:** CI pre-commit job (strict, so a skip fails it).
- **VERIFICATION:** Selene step green in CI; container run on the integrated head.

### T11

**Rojo projects build from a clean clone** · Agent tooling · VERIFIED_STRONG · P2

- **PREVIOUS CLAIM:** Three Rojo fixture builds in the workbench gate.
- **ACTUAL STATE:** All five projects build from a clean clone: creator, diagnostic, factory, network and the kits diagnostic place (`fixtures/kits.project.json`: every kit package plus opt-in fixtures keyed by the Workspace attribute `SETUP_ONLY_KitFixture`). `network.project.json` used to read `../artifacts/network/SourceManifest.luau`, which only the PC workbench generated; it now reads `build/network/SourceManifest.luau`, written by `python3 tools/network_manifest.py` from the place's own sources (per-file sha256 and the combined `input_sha256` that the Echo scripts put in their evidence).
- **EVIDENCE:** Cloud container: `python3 tools/network_manifest.py` then `rojo build fixtures/network.project.json` (Rojo 7.7.1) built the place, and deserialising it in Lune listed FaultQueue, Settings and SourceManifest under ReplicatedStorage.WorkbenchNetwork. On the integrated branch `rojo build fixtures/kits.project.json` built SETUP_ONLY_Kits_Diagnostic. CI builds creator, diagnostic, factory and network; kits was added to the loop in c70ff63 and has not run in CI yet.
- **DEFECT:** The workbench's own manifest format is unknown; this one keeps the only field the scripts read.
- **ROOT CAUSE:** Generated file referenced but never committed.
- **IMPACT:** n/a
- **FIX:** Generator plus CI build of every project.
- **VERIFICATION:** Rojo builds of all five projects in the container; five in the workflow, four run in CI so far.

### T12

**Reusable project starter** · Agent tooling · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** Not claimed (mission section 1).
- **ACTUAL STATE:** `tools/new_project.py <dest>` scaffolds a separate starter/2 game repository with infrastructure only: factory packages laid out by class (authoring packages in `ServerStorage.Authoring`, kits in `ReplicatedStorage.Kits` plus leaf copies of ProcGen Rng/Grid/Graph and SceneKit Vec/Lighting, legacy packages in `ReplicatedStorage.Kits` beside the kits, `ServerPackages`), a phased boot skeleton that tolerates absent kits (T17), the pinned toolchain, the Lune runner and specs, a gate with fast, pre-commit and pre-release tiers (skills-packages, brief, deps, blink when a `.blink` file exists, asset-provenance, release-check), CI with `--strict` and a committed-lockfile check, the release checker (Q02), the production pipeline (Q10), optional pinned dependency bundles (T18), the Claude and Codex guards, game-repo AGENTS/CLAUDE templates with every game-design field left TBD, 17 skills and `starter.json` with each module's tier, Lune flag and probe. `--update` refreshes packages, skills, hooks and managed files, adds new bundles, migrates starter/1, moves an older `ReplicatedStorage.Legacy` folder next to the kits and refuses when files were edited locally. It refuses a destination inside the factory or a non-empty one, and never runs a git write.
- **EVIDENCE:** Gate step `starter-smoke` (pre-commit) scaffolds into a temp dir, runs `git init` there and runs that repo's own gate, plus the refusals and `--update`. On the integrated branch `tests/test_new_project.py` (23) and `tests/test_release_check.py` (14) pass. G8 also ran `tools/starter_smoke.py` (19 checks PASS), a manual scaffold whose own pre-commit gate passed (28 Lune cases, Rojo build), and an all-kits scaffold (37 Lune specs, Rojo build). Since c70ff63 `DEFAULT_PACKAGES` is the authoring packages plus all five kits, and `starter-smoke-full` (pre-release) scaffolds them and runs the new repo's gate: PASS on the integrated head.
- **DEFECT:** The generated CI has never run on GitHub and a generated place has not been opened in Studio (T17).
- **ROOT CAUSE:** No game repository exists (setup-only).
- **IMPACT:** First real use may surface CI setup issues.
- **FIX:** On the first explicit game-build request, push the new repo and confirm its CI is green.
- **VERIFICATION:** `starter-smoke` in the pre-commit gate and CI; `tools/starter_smoke.py`; Python unit tests.

### T13

**Publish/spend guards and MCP settings for Codex** · Agent tooling · PARTIAL · P1

- **PREVIOUS CLAIM:** Not claimed; the mission requires the factory to stay usable by both Claude and Codex.
- **ACTUAL STATE:** `.codex/config.toml` (on-request approvals, workspace-write sandbox, no network, the `.mcp.json` servers with the ask tools prompted, Studio `subagent` prompted, and the Blender asset tools `generate_3d`, `import_asset` and `search_assets` in `disabled_tools`), `.codex/hooks.json` (PreToolUse with three matchers, all with `--client=codex`, which turns every ask into a deny because Codex hooks cannot ask: Bash and a file-edit matcher `apply_patch|Edit|Write|MultiEdit|NotebookEdit` to `guard_bash.mjs`, and a `^mcp__.*$` catch-all to `guard_mcp.mjs`), and `.codex/rules/factory.rules` (prefix rules: forbidden or prompt for plain publish, registry publish/auth, literal owner-record writes and force-push commands). Setup and health checks are in `docs/mcp.md`.
- **EVIDENCE:** Self-test on the integrated branch: 402/402 hook cases through the `.codex/hooks.json` commands; 54/54 plain publish/upload/registry/owner-record/force-push deny cases forbidden or prompted by the rules, and 7 allow cases prompted, none forbidden; config parity 40/40 tools. With `CODEX_BIN` (codex-cli 0.160.1) G9a also got 256/256 rule decisions identical to `codex execpolicy check`, and the `disabled_tools` config parsed in `codex mcp get --json`; no codex CLI was available in the integration pass.
- **DEFECT:** Nothing applies until the project and each hook are trusted in Codex, and the hook hashes changed, so earlier trust must be renewed. A hook that errors, times out or cannot find `node` lets the call run. In a linked git worktree Codex reads the main checkout's hooks. CLI bypass flags and the PC's permissive global Codex config (M06) override the project config. Whether Codex fires PreToolUse for `apply_patch` under that name and with which input fields, and whether `disabled_tools` hides the tools from the model, are unverified. No live Codex model turn and no Windows run were made.
- **ROOT CAUSE:** Codex's hook and trust model differs from Claude's; the PC is outside this container.
- **IMPACT:** Codex sessions on the PC run unguarded until the owner trusts the project and hooks.
- **FIX:** Shared guards with a Codex mode, a catch-all for unknown servers, rules for the plain forms, config parity checked in the gate.
- **VERIFICATION:** Hook, rule and config parity in the pre-commit self-test; live Codex behaviour pending.

### T14

**Engine probe runner and tier enforcement (studio_run, kit_tiers)** · Agent tooling · PARTIAL · P1

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `tools/studio_run.py` runs a `tests/engine/<probe>.luau` entry (41 exist) through the documented Studio command line (RunScript on a local place under `build/`, default `build/kits.rbxl`; `--placeId`, `--universeId` and places outside `build/` are refused), parses ENGINE_CHECK/ENGINE_DONE lines into `reports/engine/<probe>.json` (engine-report/1), records play-session output with `--from-output` (pinned by sha256), and reports BLOCKED_EXTERNAL with exit 3 where Studio is absent. `tools/kit_tiers.py` requires `--!strict` and one `@tier` header per kit module and a registered probe for every probe line of a T3 module (a module may name several and is proven only when all pass), and joins Studio evidence into `reports/kit-tiers.json` (kit-tiers/1), failing `--check` on an evidence file that is not a valid engine-report/1; `studio_run.py` refuses output whose ENGINE_DONE says it ran in Lune, so the Lune kit-smoke harness can never become engine evidence; `tests/kits_load.spec.luau` enforces the same headers in Lune.
- **EVIDENCE:** On the integrated branch: `tests/test_studio_run.py` (21, including a fake Studio CLI) and `tests/test_kit_tiers.py` (12) pass; `studio_run.py --probe kitsmoke_all` gives BLOCKED_EXTERNAL, exit 3; `kit_tiers.py --print`: 161 modules (157 kit), T0 88, T1 38, T3 27, T4 8, 31 header-named probes all PENDING (a module may name several; AudioGraphRoblox names two), 0 of 27 T3 modules with a passing probe, no problems; `reports/kit-tiers.json` is now generated and `kit_tiers.py --check` passes in the pre-commit gate; 41 `tests/engine/` entries.
- **DEFECT:** No Studio run; whether the Studio command line needs a logged-in user and whether RunScript runs in Edit mode are unverified.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Every T3 claim stays PENDING.
- **FIX:** The owner runs the probes on the PC and re-runs `python3 tools/kit_tiers.py`.
- **VERIFICATION:** `reports/engine/kitsmoke_all.json` PASS from the Studio CLI route; `kit_tiers.py --check` in the gate.

### T15

**Luau type analysis with pinned definitions (luau-lsp)** · Agent tooling · PARTIAL · P2

- **PREVIOUS CLAIM:** None (luau-lsp was pinned but never run).
- **ACTUAL STATE:** `luau-defs.lock.json` pins the Roblox definitions and API docs by commit (0382dc76) and sha256; `tools/luau_defs.py` fetches and verifies them into `build/luau-lsp/`. `tools/luau_analyze.py` runs `luau-lsp analyze` over `packages/` and `fixtures/` with a Rojo sourcemap and fails on any per-file increase over `tests/golden/luau-lsp-baseline.json` (exit 3, SKIPPED, without a binary); it fails when luau-lsp crashes, exits with a code other than 0 or 1, or prints output it cannot parse, so a broken analyzer can never pass the step. The repo-local Claude Code plugin `luau-lsp@roblox-factory` runs the same server and definitions; it is an LSP server, not MCP (`docs/pc-setup.md`).
- **EVIDENCE:** G9b, on its own branch, with luau-lsp 1.70.1 built from source at the pinned tag: 338 diagnostics in 43 files, 0 over; a planted error gave 1 file over and exit 1; `claude plugin validate --strict` passed for the marketplace and the plugin; a live LSP round trip got publishDiagnostics. On the integrated branch in this pass: `luau_defs.py` fetched both pinned files and `--verify` matched; `tests/test_luau_analyze.py` (16, the live round trip skipped without luau-lsp on PATH) passes; the same source-built binary reported 611 diagnostics in 127 files against the 338 baseline: 86 files over (+314: GameKit 43 files, UIKit 15, AVKit 7, ProcGen 3, Feel 3, kit fixtures 8, SceneKit, Cinematics, Pipeline and Runtime 7) and 3 under. Typing passes fixed every kit file (GameKit, UIKit, Cinematics, Feel, AVKit, authoring kits and kit fixtures to 0) and the baseline was re-recorded: 278 diagnostics in 38 files, 0 over (fd29fd6 names each file that fell and why; none rose).
- **DEFECT:** CI's rokit-installed binary is untested (release download refused here); the plugin has not run inside a Claude Code session.
- **ROOT CAUSE:** Groups wrote modules without a shared analyzer run; the proxy blocks the release asset; cloud sessions start no LSP.
- **IMPACT:** Type regressions are gated in strict CI and in any local pre-release run that has the binary; a local run without it may skip the step.
- **FIX:** In CI run `rokit install`, `python3 tools/luau_defs.py` and `python3 tools/luau_analyze.py`, building luau-lsp from source if rokit cannot fetch it.
- **VERIFICATION:** `luau_analyze.py` reports 0 files over on the integrated head in CI; on the PC the plugin shows diagnostics after an edit.

### T16

**Owner-record write protection (release/owner-*.json)** · Agent tooling · PARTIAL · P2

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** Owner sign-offs in a game repo (`release/owner-*.json`, read by the release checker, which never turns them into PASS) are protected from agent writes. `guard_bash` (Claude Bash, Codex shell, and file-edit events by path) allows only read-only commands on a line that names a record, a glob that could expand to one, or a release folder it enters: reading, copying elsewhere, `git add` and `git commit` pass; redirects, `tee`, `cp`/`mv` into a record, `sed -i`, `rm`, `ln`, interpreters naming it, `git checkout/restore/mv` and `git apply/am` are denied. Copies under `fixtures/` or `tests/` pass, and paths are resolved first. `.codex/rules` cover the literal `release/owner-exceptions.json`.
- **EVIDENCE:** Self-test on the integrated branch (404/404, including 11 fixture-exemption cases among the 93 second-pass cases). G9a built the proposed settings in a scratch copy: the Edit-hook probe denied a record, allowed an ordinary file and allowed a fixture copy.
- **DEFECT:** Claude's Edit, Write, MultiEdit and NotebookEdit tools are unguarded until the owner adds the file-edit matcher and the `Edit(release/owner-*.json)` deny; the Codex `apply_patch` event shape is unverified. Residual: a symlink that points a fixture path at a real release folder, and scripts run from files. Conservative: a fixture target reached through `cd`, or an interpreter line that only mentions a record, is denied.
- **ROOT CAUSE:** Agents may not edit the settings that govern them; Codex hook event shapes are undocumented.
- **IMPACT:** Until then an agent could write an owner sign-off with Claude's file tools.
- **FIX:** Owner applies the `docs/mcp.md` settings change set (T04).
- **VERIFICATION:** Self-test cases in the gate; Claude file-tool protection pending the settings change.

### T17

**Starter boot skeleton and kit layout** · Agent tooling · PARTIAL · P2

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** In a starter/2 game repo, `src/shared/Boot.luau` runs the phases config, kits, data, remotes, telemetry, ui and input, each with a timeout; it stops on the first failure, runs cleanups in reverse and prints one `BOOT_REPORT` line (boot-report/1). `KitLoader` loads optional kits and fails only for kits `Config.kits.required` names, so a repo with no kit installed still builds and boots. Config is all TBD; the server and client phases and a neutral loading screen use localisation keys and respect reduced motion.
- **EVIDENCE:** `tests/boot.spec.luau` (order, failure stop, timeout, cleanup, kit loading, both sides with fakes) and `tests/layout.spec.luau` (built place deserialised, every static require resolved) pass inside the scaffold that `starter-smoke` builds in the pre-commit gate (G8: 28 Lune cases in a manual scaffold, 37 in an all-kits scaffold).
- **DEFECT:** Never run in the engine (release item S07).
- **ROOT CAUSE:** Studio runs only on the PC; no game repo exists (setup-only).
- **IMPACT:** Boot order and replication in a real session are unproven.
- **FIX:** The owner runs Play Solo and Server & Clients in a scaffolded place and records S07.
- **VERIFICATION:** Lune specs in the scaffold (T0/T2); S07 owner record pending (T3).

### T18

**Pinned optional dependencies with licence notices (starter bundles)** · Agent tooling · PARTIAL · P3

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `templates/starter/deps.json` (starter-deps/1) allows three bundles: persistence (ProfileStore 1.0.3, server realm, Apache-2.0 with notice text), studio-tests (Jest Lua and JestGlobals 3.10.0, dev realm, MIT) and networking (Blink 0.18.9). A scaffold with `--deps` writes `wally.toml` with `private = true` and exact `=x.y.z` pins and `THIRD_PARTY_NOTICES.md`; Wally 0.3.2 is pinned in rokit.toml; the game gate step `deps` and CI require a committed `wally.lock`. The starter never installs or publishes.
- **EVIDENCE:** `tests/test_new_project.py` dependency-bundle cases (a fake wally and rokit on PATH prove they are never run) pass on the integrated branch; G8 scaffolded `--deps persistence` (exact pin, `private = true`, no lockfile, no Packages folder) and an all-bundles repo in `starter_smoke.py`.
- **DEFECT:** `wally install`, the ProfileStore runtime and the Blink compile are unverified; the `deps` step stays red until the owner commits `wally.lock` in a game repo.
- **ROOT CAUSE:** Installs and network fetches are owner actions in a game repo.
- **IMPACT:** The first install may surface a pin or realm issue.
- **FIX:** In the first game repo the owner runs `wally install`, commits `wally.lock` and lets CI verify it.
- **VERIFICATION:** Unit tests and starter smoke; CI in a game repo.

### L01

**Local workbench gate** · Local workbench (PC) · BROKEN · P1

- **PREVIOUS CLAIM:** `reports/verification.json` pass at 19:43Z.
- **ACTUAL STATE:** Re-run during the audit: FAIL 42/43 (`authored-inputs-unchanged`). A Codex process running since 13:09 was editing `tools/profiles.py` and had added 8 files the last pass never covered. `wb.ps1 validate` passes (427 records, 0 errors).
- **EVIDENCE:** Remote Control session on the PC, read-only.
- **DEFECT:** The recorded pass does not cover the current files.
- **ROOT CAUSE:** Concurrent writer and no version control.
- **IMPACT:** No trustworthy green state for the workbench right now.
- **FIX:** The owner chose to keep Codex running, so Claude stayed read-only. Re-run the gate once the Codex run ends.
- **VERIFICATION:** `./.venv/Scripts/python.exe tools/check.py` passes on a quiet tree.

### L02

**Version control and rollback for the workbench** · Local workbench (PC) · MISSING · P1

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `git` branch master with 0 commits, no remote, nothing tracked.
- **EVIDENCE:** Local audit.
- **DEFECT:** No history; two agents can overwrite each other silently.
- **ROOT CAUSE:** Never initialised beyond `git init`.
- **IMPACT:** Nothing in the workbench can be rolled back.
- **FIX:** Local-only snapshot (no remote, no upload) once Codex is idle; the owner deferred this.
- **VERIFICATION:** `git log` shows a commit.

### L03

**Owner PC setup checks (pc_doctor, pinned PC tools, user-level skills copy)** · Local workbench (PC) · PARTIAL · P2

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `docs/pc-setup.md` lists the nine approved items (ImageMagick, Krita, Audacity, glTF Transform, Material Maker, a tools folder pinned by `templates/pc-tools/rokit.toml`, Rokit before Aftman on PATH, the Blender MCP telemetry check, the user-skills copy), optional extras and the luau-lsp plugin, each with its doctor check and no machine paths. `tools/pc_doctor.py` is read-only and shows the home folder as `~`; `tools/user_skills.py` copies skills to the user level as a dry run by default, stamps the copies and refuses this repo and any git repo.
- **EVIDENCE:** On the integrated branch `tests/test_pc_doctor.py` (9) and `tests/test_user_skills.py` (7) pass. G9b ran the doctor in the cloud container: 2 FAIL, as expected there (rojo 7.7.1 from crates, no luau-lsp on PATH).
- **DEFECT:** Never run on the owner's PC; none of the nine items is confirmed installed.
- **ROOT CAUSE:** The PC is outside this container.
- **IMPACT:** Agents on the PC cannot rely on the extra tools or a correct PATH.
- **FIX:** The owner installs the items and runs the doctor.
- **VERIFICATION:** `python3 tools/pc_doctor.py` (with `--blender <exe>`) on the PC reports no FAIL.

### M01

**Built-in Roblox Studio MCP connection** · MCP and Studio · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** Native Studio connection partially verified (sync/readback, Play, screenshots, simulated input).
- **ACTUAL STATE:** The built-in Studio MCP (user-level `Roblox_Studio`, Studio 0.741.19) was driven live from a Claude Code session on the PC. The saved reports record `execute_luau`, `search_game_tree` and `screen_capture` (the image stayed on the PC); the session also listed the open Studio and started Run mode, but those calls are not recorded in the reports. The repo's `.mcp.json` declares the same command with hook gating. The guard now classifies all 26 Studio tools (table in `docs/mcp.md`); `skill`, `wait_job_finished` and `search_asset` are reads there, but Claude still prompts for them until the owner applies the settings change set (T04).
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json`, `reports/studio/roundtrip-2026-10-05.json`.
- **DEFECT:** The repo's own `.mcp.json` entry was not the one used (the PC session ran from the workbench folder); reading console output in Run mode was blocked by the PC's permission prompt.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Studio-side claims below stay blocked until run there.
- **FIX:** Open Claude Code in this repo on the PC once, approve the project server, and approve the console read.
- **VERIFICATION:** Live tool calls returned the expected results in Studio for the three recorded tools.

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
- **ACTUAL STATE:** The repo declares the same Studio and Blender servers for Codex in `.codex/config.toml` (`uvx mcp-for-blender==2.1.8`, telemetry off), with `approval_mode = "prompt"` on exactly the tools the Claude guard asks for and the Blender asset tools (`generate_3d`, `import_asset`, `search_assets`) in `disabled_tools`. No Codex model session has connected to Blender.
- **EVIDENCE:** Self-test on the integrated branch: the two servers in `.codex/config.toml` are identical to `.mcp.json`, and 40 of 40 tools are prompted in Codex exactly when `guard_mcp` asks and disabled exactly when it denies.
- **DEFECT:** Tools configured but not loaded.
- **ROOT CAUSE:** Codex project trust not granted.
- **IMPACT:** Codex can't drive Blender interactively; headless `factory.py` still works.
- **FIX:** Owner trusts this project and its hooks in Codex, then runs `codex mcp list` and asks for `get_scene_info` with Blender open.
- **VERIFICATION:** Config parity in the self-test; live Codex connection pending.

### M04

**Blender MCP add-on telemetry off** · MCP and Studio · WEAK · P1

- **PREVIOUS CLAIM:** Workbench Codex config sets telemetry off for its vendored server.
- **ACTUAL STATE:** The add-on installed in Blender (`blender_mcp.py` v1.2) defaults telemetry to on; whether it was turned off is unverified. The server side is off via `DISABLE_TELEMETRY` in `.mcp.json` and `.codex/config.toml`. `tools/pc_doctor.py` checks that server flag (telemetry:server) and, with `--blender <exe>`, reads the add-on preference through Blender in background mode without saving preferences (telemetry:addon); `docs/pc-setup.md` item 8 gives the manual check.
- **EVIDENCE:** Local audit read the add-on source default. `tests/test_pc_doctor.py` (passes on the integrated branch): a server flag set to false gives FAIL; a fake Blender reporting consent true gives FAIL, false gives PASS and a crash gives FAIL. G9b ran the doctor's Blender script on bpy 5.0.1 in the container (no add-on installed, so TODO).
- **DEFECT:** The add-on preference on the PC is unread, so prompt, code or screenshot telemetry from the add-on is possible.
- **ROOT CAUSE:** Upstream default; the PC is outside this container.
- **IMPACT:** Private material could leave the machine.
- **FIX:** Turn it off in the add-on preferences.
- **VERIFICATION:** `python3 tools/pc_doctor.py --blender <exe>` shows telemetry:addon PASS on the PC.

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

### M07

**MCP audit per server (why, client, tools, permissions, ports, network, auth, telemetry, overlap, failure modes, health check)** · MCP and Studio · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** First pass listed servers without an audit.
- **ACTUAL STATE:** `docs/mcp.md` has one column per server (Roblox_Studio, blender, WEPPY, GitHub) covering every field, a table of all 26 Studio tools with the guard's decision, the Blender tool classes, a section on other MCP servers (connectors, plugins, Codex apps; M08), owner records, the Codex setup, the owner-only settings change set, the decision to run `execute_luau` and `multi_edit` without a prompt (guarded by content checks on every input string, the unpublished diagnostic place, Rojo source and undo), and the needs-based decision not to add browser, filesystem or docs/search MCP servers. The Blender column reflects 2.1.8 (14 tools, `look` replaces `get_viewport_screenshot`); outdated mentions in the research note and the asset-factory skill were corrected. The luau-lsp plugin is an LSP server and is documented in `docs/pc-setup.md`. The former local machine notes and the owner's name were removed.
- **EVIDENCE:** Blender tool list and telemetry state read from the installed 2.1.8 package; Codex setup checked against codex-cli 0.160.1; the hook self-test exercises every permission the tables state and requires all 26 Studio tools to be classified (40/40 configured tools on the integrated branch).
- **DEFECT:** WEPPY's auth, telemetry and tools are unknown (its folder is read-only and out of scope). GitHub MCP writes have no repo guard. The Blender socket has no authentication (vendor note).
- **ROOT CAUSE:** Third-party servers outside this repo.
- **IMPACT:** WEPPY stays unused for factory work (M05).
- **FIX:** Documented; WEPPY kept unused until the owner confirms its auth.
- **VERIFICATION:** Table cross-checked against the installed package, the guards and the self-test.

### M08

**Tools from unconfigured MCP servers (claude.ai connectors, plugins, Codex apps)** · MCP and Studio · PARTIAL · P2

- **PREVIOUS CLAIM:** Not covered.
- **ACTUAL STATE:** `guard_mcp` asks for any tool of a server the factory does not configure (GitHub read tools such as `get_`, `list_`, `search_`, `*_read`, `actions_get` and `actions_list` pass). Under Codex the `^mcp__.*$` catch-all routes every MCP tool through it and turns the ask into a deny. Under Claude the PreToolUse matcher covers only `mcp__Roblox_Studio__.*|mcp__blender.*`, so other servers' tools meet only Claude's own permission prompts.
- **EVIDENCE:** Self-test on the integrated branch: the catch-all cases pass through `.codex/hooks.json` (402/402); `docs/mcp.md` sections "Other MCP servers" and settings item 5.
- **DEFECT:** Claude stays unguarded for unconfigured servers until the owner chooses Option A (`disableClaudeAiConnectors`), Option B (widen the matcher to `mcp__.*`), both, or knowingly neither. GitHub MCP writes have no repo guard (M07).
- **ROOT CAUSE:** Agents may not edit their own settings; connectors load per account.
- **IMPACT:** A connector tool could write outside the factory's guards in a Claude session.
- **FIX:** Owner decision on `docs/mcp.md` settings item 5.
- **VERIFICATION:** Codex catch-all in the self-test; Claude side pending the owner's choice.

### S01

**Studio testing modes (Test, Test Here, Run, Server & Clients) and device emulation** · MCP and Studio · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Play and local one/two-client RemoteEvent/leave fixtures passed.
- **ACTUAL STATE:** The gate's "native" passes replay hashes of saved receipts; they do not open Studio. MCP `start_stop_play` covers Test and Run; Test Here and Server & Clients are started from the Studio UI. On 2026-10-05 Run mode was started on the PC but the FACTORY_SMOKE console line could not be read (permission prompt). Play-session probes now have a harness: the Workspace attribute `SETUP_ONLY_KitFixture` arms the kits place's fixture scripts (`authority`, `ui-gallery`, `lookdev`, `kitsmoke`); `kitsmoke` runs every shared plus server and shared plus client registry, and `tools/studio_run.py --from-output` records the saved Output as `reports/engine/<probe>.json`. Probes that need Server & Clients: `platform_remoteguard_flood` (network delivery), `platform_party_simulator`, `economy_trade_two_client` and the authority fixture (K07).
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` (run_mode field); research section 2; `tests/engine/README.md` (play-session runs); `tests/test_studio_run.py` covers the `--from-output` parser.
- **DEFECT:** No play mode has produced observed output in this pass.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Replication and play behaviour of new code is unproven.
- **FIX:** Run S02 in Run mode, and one Server & Clients session with 2 clients on the network fixture.
- **VERIFICATION:** Console output and captures saved under `reports/studio/`.

### S06

**Studio MCP operations beyond the core loop (property inspection, script read/edit, asset search/insert, console, camera, keyboard/mouse/character input)** · MCP and Studio · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Native Studio connection partially verified (sync/readback, Play, screenshots, simulated input).
- **ACTUAL STATE:** Only five Studio tools were exercised live in this pass (see M01). `inspect_instance`, `script_read`/`multi_edit`, `search_asset`/`insert_asset`, `get_console_output`, camera control, `user_keyboard_input`, `user_mouse_input` and `character_navigation` were not run, so the first pass's simulated-input claim is neither confirmed nor refuted. In `.claude/settings.json` all of them are allowed except `insert_asset` (ask) and `search_asset` (no rule, so Claude prompts). The guard now classifies all 26 Studio tools: `subagent` asks (its own tool calls bypass the hooks; which tools it may call is unverified), and `skill`, `wait_job_finished` and `search_asset` are reads, though Claude prompts for them until the settings change (T04). A second, non-MCP route exists: `tools/studio_run.py` drives the documented Studio command line (RunScript on a local `build/` place); it is untested in Studio (T14).
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` and `reports/studio/roundtrip-2026-10-05.json` record no calls to these tools; `.claude/settings.json` allow/ask lists.
- **DEFECT:** Unexercised operations.
- **ROOT CAUSE:** Studio runs only on the PC; the PC session was used for the smoke test and the round trip, and a permission prompt blocked the Run-mode console read.
- **IMPACT:** Agents may rely on input simulation, script editing or asset insertion that nobody has seen work with the current Studio version.
- **FIX:** One scripted pass on the diagnostic place covering each tool, saved under `reports/studio/`.
- **VERIFICATION:** Pending: observed output of each tool on the PC.

### S02

**SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** · Scene authoring · PARTIAL · P0

- **PREVIOUS CLAIM:** WorldInspector queries and metadata-only content graphs; "no setup game world".
- **ACTUAL STATE:** At commit 9c12091, `FactorySmoke` was run in real Studio (0.741.19) on the owner's PC through Studio MCP `execute_luau`, in the unpublished SETUP_ONLY_Factory_Diagnostic place that Rojo built from `fixtures/factory.project.json`. It built both scenes with string requires across SceneKit and ProcGen, and the hashes and part counts equalled that commit's Lune golden: building 778d1d9a / 96 parts, dungeon 8494d161 / 108 parts. Two ChangeHistoryService undos removed both scenes. Since then the generators changed (about 1000 lines, including the new `ProcGen/RoomGraph.luau`), the dungeon golden is now 927f2db4, and `Apply.scene` replaces by default; none of that has run in Studio.
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` (commit 9c12091); `tests/golden/studio-smoke.json` at 9c12091 and at HEAD. At HEAD the factory place builds and all its string requires resolve to ModuleScripts (checked by deserialising the Rojo build in Lune). On the integrated branch `python3 tools/capture_staleness.py` reports the dungeon entry of `reports/studio/smoke-2026-10-05.json` as STALE (recorded 8494d161, current 927f2db4) and the building entry CURRENT.
- **DEFECT:** Studio parity at HEAD is unverified: the new generators, the new dungeon golden and the replace-then-undo path have not run in Studio. Run mode is unproven: the PC's permission prompt blocked reading the FACTORY_SMOKE console line.
- **ROOT CAUSE:** The console read needs the owner's approval on the PC; later commits change hashes on purpose.
- **IMPACT:** Edit-time parity and undo are proven. Play-time parity is not, and the parity proof applies to 9c12091's hashes.
- **FIX:** Re-run steps 1 to 3 after pulling, and approve the console read once for the Run-mode line.
- **VERIFICATION:** Observed in Studio at 9c12091 only; HEAD pending the owner steps.

### S03

**Scene-authoring API as data (buildings, props, lights and signs, interior dressing, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance)** · Scene authoring · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present (metadata graphs only).
- **ACTUAL STATE:** `packages/SceneKit`: plans are data, built from seeds and style profiles, validated (part budget, door clear width against every wall, room clearance, stair rise, headroom and oriented-box obstruction at any yaw, prop clipping and support), hashed into manifests, compared between revisions, rendered, and applied in Studio with undo; `Apply.scene` replaces the previous model of the same name unless `{replace = false}`. Part specs can carry a light (Point/Spot/Surface) or a sign (SurfaceGui with placeholder text), validated by `light_placement` and `sign_text`; `Building.decorate` places one light per room and neutral props along walls with a seed, clear of doorways, stair openings and windows. Dressing is opt-in and no fixture uses it. Prop clipping now confirms AABB hits with oriented-box penetration, as the stair checks do. Light validation now errors above range 120 (the engine cap) and warns above 60 and at more than 4 lights or more than 1 shadow-casting light per room. Lighting presets are S05, the material library S09 and kit/1 piece swaps S10.
- **EVIDENCE:** Lune specs (`tests/scenekit.spec.luau`, `tests/scenekit_layout.spec.luau`: 300 seeded subdivisions with no bisected doorway, 36 two-storey buildings and the settlement-202 houses with every doorway clear, railing vs next flight at 3 to 5 storeys, yawed stairs, the fixture ramp clear of the Annex; `tests/scenekit_dressing.spec.luau`: a 48-building decorate sweep plus yaws 30, 90 and 217 with every room lit, zero penetration and doorway width intact, and the cap-120 error and 60 warning cases). On the integrated branch `lune run tests/run.luau scenekit` passes 82 cases in 9 files. A scratch sweep of 240 decorated cases found 0 failures, and 7 sabotaged decorate rules were each caught. All 11 SETUP_ONLY fixtures build and validate with stable hashes; the six scene fixtures kept their hashes through the integration. Studio parity of the smoke scenes was observed at 9c12091 (S02); the replace-then-undo path and dressing have not run in Studio.
- **DEFECT:** Fixed in this pass: stair headroom at 3+ storeys, inverted gable slopes, ramp yaw, front camera; after review: Apply not replacing with no options, partitions cutting doorways, railing clipping the next flight, the fixture ramp buried in a foundation, AABB stair checks failing at non-axis yaw.
- **ROOT CAUSE:** Rotation-convention errors, caught by validators and renders.
- **IMPACT:** n/a after fixes.
- **FIX:** Regression specs for each.
- **VERIFICATION:** Specs, fixture hashes, previews.

### S04

**Measurement and player-scale helpers** · Scene authoring · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Conservative AABB/ray queries in WorldInspector.
- **ACTUAL STATE:** `Measure`: engine defaults (gravity 196.2, WalkSpeed 16, JumpHeight 7.2) and design guides (doors, ceilings, corridors, cover), jump reach, clearances, sightlines, camera clearance; `canJump(gap, rise, margin?, engine?)`, `profile(playerScale)` and `airTime` serve the course validators (P05).
- **EVIDENCE:** Measurement specs, including `tests/scenekit_coverage.spec.luau` for `cameraClearance` (wall behind: clear=false, 6 studs available; open: clear=true, 12.5) and `corridorWidth` (5 fails, 6 passes, 10 comfortable, 3 players need 8.5). ProcGen's camera and sightline checks use their own grid logic.
- **DEFECT:** Guides are heuristics, not playtested with a character.
- **ROOT CAUSE:** No Studio character run yet.
- **IMPACT:** Values may need tuning per game.
- **FIX:** Check with `character_navigation` during S02; probe `lvl_course_run` compares gravity, walk speed and jump height with `Measure.ENGINE` and raycasts landings (pending).
- **VERIFICATION:** Specs.

### S05

**Terrain, lighting presets and day/night cycle applied in Studio** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Terrain heightmaps, flatten, smooth, paint, sculpt, carve and water produce ops that `Apply.terrain` replays: a spec with a recording Terrain checks the exact call order, positions, sizes and materials and one undo recording, and malformed op lists are rejected before any voxel changes. `SceneKit/Lighting` schema 2 has 15 presets named by function (lookdev_neutral, lookdev_contrast, bright_noon, overcast, golden_hour, blue_hour, night_clear, low_light, dense_fog, storm_dim, interior_warm, interior_cool, readability_max, perf_low, flat_capture) covering Lighting, Atmosphere, a Sky with no asset ids, Clouds, GlobalWind, Bloom, ColorCorrection, DepthOfField, SunRays and optional ColorGrading, with validate, blend, apply, inspect (`requires_ok` for LightingStyle and PrioritizeLightingQuality), a post-effect audit per device class and preview hints; schema 1 ids resolve to the same numbers. `GameKit/WorldCycle` (T1, probe `worldcycle_phases`) drives 7 day/night phases from server time, each blending into a preset, plus a weather overlay. None of it has been applied in Studio.
- **EVIDENCE:** On the integrated branch: `scenekit_lighting` 12, `gamekit_worldcycle` 7, `tests/scenekit.spec.luau`, `tests/scenekit_coverage.spec.luau`; probes `av_lighting_presets` and `worldcycle_phases` pass against fakes in `avkit_probes` (10; not engine evidence). G5 rendered approximate Blender previews of six presets (lookdev_neutral, bright_noon, golden_hour, blue_hour, night_clear, storm_dim) that differ as intended (Cycles, no fog).
- **DEFECT:** Voxel output and the look of the presets in the engine are unseen; post-effect ranges and their mobile cost are unverified.
- **ROOT CAUSE:** Engine-only behaviour.
- **IMPACT:** Presets and terrain plans may need adjustment once seen.
- **FIX:** Run probes `av_lighting_presets` and `worldcycle_phases` with the lookdev fixture and capture each preset; apply a `Terrain.heightmap` plan in the diagnostic place and capture it.
- **VERIFICATION:** ENGINE_DONE ok for both probes and one capture per preset.

### S07

**Model operations and selection scope (model.inspect, scale, pivot, material, collision, optimize)** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Mission section 13 namespace; missing from the first pass and from the namespace map.
- **ACTUAL STATE:** `SceneKit.Model` runs inspect, scale, pivot, material, collision and optimize over an Instance, a list or `Model.selection()` (Studio's Selection; empty under Lune). Each op builds a change list first: `dryRun` returns it untouched; otherwise one ChangeHistory recording wraps the apply, and a failed property set rolls back and cancels the recording. Pivot and scale maths is SceneKit's own, so Lune and Studio run the same code.
- **EVIDENCE:** `tests/scenekit_model.spec.luau` (8 cases on real `@lune/roblox` instances: dry run, commit and cancel, revert, rollback); bad inputs raise (scale factor 0, -1, NaN, inf; unknown pivot mode); 4 sabotaged behaviours each caught.
- **DEFECT:** Never run in Studio: Selection, ChangeHistory undo, CollisionFidelity writes and scaling welded assemblies are unverified; `scale` warns that joint C0/C1 are not scaled.
- **ROOT CAUSE:** Added in this pass; Studio only on the PC.
- **IMPACT:** Studio-only behaviour may differ from the Lune DataModel.
- **FIX:** On the PC: select a model, run `inspect`, `pivot(..., "base_center")` and `scale(..., 2)` through `execute_luau`, undo each once, and save the output.
- **VERIFICATION:** Specs in the gate; Studio pending.

### S08

**Level dressing: lights, signs and interior props** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Mission section 14; not implemented in the first pass.
- **ACTUAL STATE:** Placement and validation are verified in Lune (S03 sweeps), and `Apply` creates the Light and SurfaceGui instances in a Lune DataModel. Light rules: range above 120 (engine cap) is an error, above 60 a budget warning, and more than 4 lights or more than 1 shadow-casting light per room are warnings. The lit look and sign rendering are unseen.
- **EVIDENCE:** `tests/scenekit_dressing.spec.luau` (8 on the integrated branch, including the cap-120 error and 60 warning cases); a decorated building rendered with `factory.py render-manifest` and reviewed (four rooms, centred fixtures, props on walls clear of doorways, sign above the door).
- **DEFECT:** Not observed in Studio.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Light ranges and sign legibility are untested in the engine.
- **FIX:** On the PC: build a building, `Building.decorate(scene, building, { lights = "mixed", sign = "SIGN_A" })`, `Apply.scene`, `screen_capture`, then undo; review light ranges against the lookdev captures (S05).
- **VERIFICATION:** Specs in the gate; Studio pending.

### S09

**Material library and MaterialService overrides (material-library/1)** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `assets/material-library.json` (material-library/1) names 15 neutral materials. `SceneKit/Materials` builds a tier-0 plan that switches a built-in material place-wide to an existing MaterialVariant with `SetBaseMaterialOverride` (no upload), and tier-1 variant plans that list the map slots still pending (OpenGL normals, power of two, 1024 px by default). Blender's `factory.py bake --mode tile` writes entries in the same format and `material-preview` renders sphere and cube tiles.
- **EVIDENCE:** On the integrated branch `scenekit_materials` 7 passes; probe `lookdev_material_override` passes against fakes; G6's tile-bake and material-preview cases are in `qa-selftest` (51/51 on bpy 5.0.1, 5.1.2 and 5.2.2).
- **DEFECT:** The MaterialService override is unverified (Lune lacks the methods, and building variants needs plugin security); no map has been bound in Studio; the probe has a Studio runner now (`tests/engine/lookdev_material_override.luau`) but has not run.
- **ROOT CAUSE:** Engine-only behaviour.
- **IMPACT:** Material swaps may look or behave differently in the engine.
- **FIX:** Run `python3 tools/studio_run.py --probe lookdev_material_override` on the kits place with the lookdev fixture and capture the swatches.
- **VERIFICATION:** ENGINE_DONE ok plus a swatch capture.

### S10

**Kit piece swap (kit/1)** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `SceneKit/Kit` (T0) validates kit/1 and defines, finds, fits and resolves pieces and makes placeholders; `ProcGen/CourseScene` tags every part with kit/1 `asset` keys; `SceneKit/Apply.swap` (T3, probe `lvl_kit_swap`) replaces greybox parts with kit pieces. Blender's `factory.py kit` writes kit/1 (B11).
- **EVIDENCE:** On the integrated branch `scenekit_kit` 8 passes; `Apply.swap` is specced in Lune with a pivotTo shim; `lvl_kit_swap` passes against fakes in `gamekit_world_probes` (6; not engine evidence).
- **DEFECT:** The Studio swap (PivotTo, bounds fit) is unobserved.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Swapped pieces could land offset or mis-scaled in the engine.
- **FIX:** Run probe `lvl_kit_swap` on the kits place.
- **VERIFICATION:** ENGINE_DONE ok for `lvl_kit_swap`.

### P01

**Seeded generators (dungeon, cave, arena, settlement, forest, courses)** · Procedural generation · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** `packages/ProcGen`: BSP + MST dungeons whose loops are walkable on the carved grid and wrap real wall (`minLoopWallStuds`), goals and encounters placed in rooms big enough for them on the best shortest route (shortfalls fail `encounters_placed`), cellular-automata caves re-joined until exactly one region, symmetric arenas with the objective on the true centre, road/lot settlements, and forests (`Forest.generate`: noise-ranked open/sparse/dense/rocky bands, role-tagged clearings, an entry-to-exit spanning path network, trees, bushes and rocks spaced per band with path, clearing and spawn exclusions; `ForestScene.toScene` turns it into SceneKit parts). Courses are P05.
- **EVIDENCE:** `tests/procgen.spec.luau` (every validator asserted, no exclusions), `tests/procgen_regressions.spec.luau` (independent grid loop check on seeds 1 to 40, 200-seed sweeps for loops, encounters and run length, caves at two sizes (48x36, 32x24) over seeds 1 to 200, arenas at 7 sizes x 2 symmetries) and `tests/procgen_forest.spec.luau` (13 cases); golden fixture hashes in the gate (forest 3d7d7cb5). A forest sweep found 0 failures over 300 seeds at 256x192, 50 at 384x256 and 200 at 160x128. On the integrated branch `lune run tests/run.luau procgen` passes 62 cases in 4 files.
- **DEFECT:** Fixed during the pass: seed 303 had no loop, 4-stud caves, 1-cell arena lanes. After review: graph-only loops (47 of seeds 1 to 200 had no walkable loop), cramped goal rooms failing encounter_space on 12 of 25 spec seeds while the spec skipped that check, cave seed 87 split in two, NaN spawn fairness, off-centre arena objective. Known limitation, kept by decision: `ProcGen/Rng` stays byte-stable, and adjacent numeric seeds share near-identical first draws (seeds 1 to 6 all give a first `next()` of about 0.3165), so per-entity seeds should be string-derived (hashed keys, as the economy kit's VotingRound, EconomySim and slices do). Mixing numeric seeds inside Rng would change every fixture hash.
- **ROOT CAUSE:** Generator parameters; caught by validators.
- **IMPACT:** n/a after fixes.
- **FIX:** RoomGraph loop measure, capacity-aware placement, region re-join loop, unreachable spawns fail, centred objective; goldens regenerated (dungeon 06ace82c, arena 20898139, Studio smoke dungeon 927f2db4).
- **VERIFICATION:** Specs and fixture hashes in the gate and CI.

### P02

**Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance)** · Procedural generation · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Implemented on the layout grid and room graph with machine-readable checks, including encounters_placed and walkable-loop redundant_paths. Forests add path_clearance, clearing_reachability (BFS on a 2-stud grid minus trunk and rock discs), spawn_clear, band_density, min_trunk_spacing, obstacle_gap, clearing_space and clearings_placed. Courses add `Validate.course` (`ProcGen/CourseValidate`), measured from the geometry: jumpable gaps (`Measure.canJump` with the course profile), reachability, checkpoint gating and spacing, monotone difficulty, landing size, headroom and overlap for linear and tower courses; loop closure, minimum turn radius, grade, bank, gate spacing and coverage for race loops; lane balance, connectivity and slot access for lanes; spawn fairness, symmetry, separation, clearance and piece overlap for micro-arenas.
- **EVIDENCE:** Every fixture's checks in `build/fixtures/report.json`; failing cases in the specs for each validator (unreachable spawn, graph-only loop, pillar loop, encounter shortfall, split cave; for forests a trunk on the path, a dropped spur path, an over-dense band, a rock at the spawn, twin trunks, a trunk in a clearing, a 4-stud path, too many clearings, a part budget one below the estimate). Disabling each of the 11 forest rules in a scratch copy made the intended case fail. `procgen_course` (19 on the integrated branch) has a failing case per course check.
- **DEFECT:** Grid and disc reasoning, not PathfindingService or Humanoid physics; forest density bounds are design heuristics.
- **ROOT CAUSE:** Headless by design.
- **IMPACT:** A layout can pass the grid and still snag a character on geometry.
- **FIX:** Add a PathfindingService reachability probe to S02 later; probe `lvl_course_run` (T3) compares gravity, walk speed and jump height with `Measure.ENGINE` and raycasts landings.
- **VERIFICATION:** Specs and fixture reports.

### P03

**Determinism and manifests** · Procedural generation · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** Hash-drift blocking for planning records.
- **ACTUAL STATE:** Same seed gives the same manifest hash; canonical sorted JSON; golden hashes for fixtures and the Studio smoke; course manifests carry `course.hash`; spec goldens pin the kit slices (gamekit-action, gamekit-economy, gamekit-world, cinematics-orbit, av-presets, uikit-ease, kit-smoke, gamekit_platform_queue, gamekit_platform_telemetry_calls, slices-integration). `--update-golden=NAME` rewrites one golden at a time.
- **EVIDENCE:** `fixture-hashes` gate step locally and in CI; the forest fixture builds byte-identical twice and was added to the golden without changing the other five hashes. The five course fixtures were added with the scoped `--update-golden=fixture-hashes`; on the integrated branch all 11 fixtures PASS and the six earlier hashes are unchanged (arena 20898139, cave a9fa3357, dungeon 06ace82c, forest 3d7d7cb5, modular_building dec2fd84, settlement bc5005c2).
- **DEFECT:** None found.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Gate.

### P04

**Forests and biome dressing** · Procedural generation · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** Seeded forest layouts (`packages/ProcGen/Forest.luau`) validated by `Validate.forest` and converted by `ForestScene.toScene`; the `forest` fixture (seed 606, 256 x 192 studs, 529 parts) passes all its checks and is in the golden gate. Biome dressing is coloured part tiles per band, not Terrain materials.
- **EVIDENCE:** `lune run tests/run.luau procgen_forest` (13 passed); `build/fixtures/report.json` forest: all checks pass; `tests/golden/fixture-hashes.json` forest 3d7d7cb5.
- **DEFECT:** Never run in Studio; no Terrain-backed variant.
- **ROOT CAUSE:** Added in this pass; Studio only on the PC.
- **IMPACT:** Studio behaviour of the forest scene is unobserved.
- **FIX:** Add the forest to the Studio smoke when S02 is re-run; optional Terrain.paint output per band.
- **VERIFICATION:** Specs, seed sweeps and fixture hashes in the gate.

### P05

**Course generators (linear, tower, race loop, lanes, micro-arena)** · Procedural generation · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `ProcGen/Course` generates course/1 manifests (segments, checkpoints, spawn, finish, hash) with `linear`, `tower`, `raceLoop`, `lanes` and `microArena` from `{seed, length|floors|laps|lanes|players, difficultyCurve, segmentKinds, playerScale}`; `Validate.course` checks them (P02) and `CourseScene` builds the SceneKit plan with kit/1 asset keys and GameKit binding attributes. Five fixtures are in the golden gate.
- **EVIDENCE:** On the integrated branch: `procgen_course` 19 cases (including a 40-course sweep); fixtures course_linear bb228047, course_tower d77b60ca, course_race_loop c8f08c8a, course_lanes 36fa47cc and course_micro_arena 099c41e1 PASS. G7: a scratch sweep of 1,700 courses had 0 validation failures, and the five manifests were rendered with `render-manifest` on bpy 5.0.1 and reviewed (arena hazard and tile defects fixed in the generator).
- **DEFECT:** Engine numbers (gravity, jump, landings) are unchecked in Studio (probe `lvl_course_run`). Square floor tiles stick out up to one tile past a round micro-arena's rim (documented; outside the wall in the fixture).
- **ROOT CAUSE:** Headless by design.
- **IMPACT:** A course can validate and still need tuning with a real character.
- **FIX:** Run probe `lvl_course_run`; the course previews join the pre-release tier.
- **VERIFICATION:** Specs, sweeps and fixture hashes in the gate.

### B01

**Blender asset templates and QA reports (23 kinds)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Blender direct authoring/export verified (68-triangle 2-bone fixture, 128px bake, FBX+GLB, reimport, turntable).
- **ACTUAL STATE:** `tools/blender/factory.py templates`: humanoid, npc, enemy, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests, and ten function-named gameplay greyboxes (pickup, pad_button, dropper, conveyor_segment, tower_base, checkpoint_gate, obby_platform_set, track_segment, pet_follower with idle and walk clips, accessory_rigid) with collision proxies, sockets and expectations; every template ships a palette atlas (B06). QA runs before export and a failing asset writes no FBX/GLB (exit 1, `qa.json` kept). Checks use world transforms, count only deform-bone weights, and re-import the shipped FBX and GLB against a signature of the export set. `qa <file>` works on .blend, .fbx, .glb and .gltf (including re-imported clip files), with seam-aware glTF welding, and applies the Studio pivot rule (`studio_pivot_at_origin`) to the roots of any of them. Newer checks: one UV set inside 0..1, texture size, colour space and Reimport suffix, declared appearance, R15 rig profile and sides, clip range, unique clip names, markers in range. The rig and animation tests use smooth bone-heat weights limited to 4 normalised influences; QA warns on unnormalised weights.
- **EVIDENCE:** G6, on bpy 5.0.1, 5.1.2 and 5.2.2: all 23 templates pass QA with 0 errors and 0 warnings; `factory.py qa` on all 49 shipped FBX, GLB and clip files gives 47 clean and 2 warnings that predate the integration (`creature.glb` pivot_base_center, `prop.glb` uv_zero_area_faces); `qa-selftest` 51/51 on each. On the integrated branch in this pass, `qa-selftest` gave 51/51 on bpy 5.0.1. Earlier: 13/13 on the owner's Blender 5.1.2 (at 9c12091); CI Blender jobs on 5.1.2 and 5.2.2; the audit's off-origin .blend/.fbx/.glb files exit 1.
- **DEFECT:** Fixed: Blender 5.1+/5.2 boolean empty material slot, FBX animation loss, join material indices, mirror self-merge, inset bounds. After review: the probe tested a different export than the shipped files, QA never blocked export, local-only transform checks, non-deform groups counted as weights, false GLB errors, stale matrix_world in set_origin_base_center. In the integration: Left and Right bones swapped on the humanoid, npc and enemy rigs, output folders resolved against the filesystem root, and a QA crash on re-imported clip files.
- **ROOT CAUSE:** Blender 5.1+ boolean behaviour change; exporter defaults.
- **IMPACT:** The factory would have failed QA on the owner's installed Blender, and mirrored rigs would have animated the wrong side.
- **FIX:** `prune_material_slots`; `qa.gated_export`; shipped-file probe; world-space and deform-bone checks; `_weld_seams`; `studio_pivot_at_origin`; `rig_profile_sides`; absolute output folders; clip-file QA; `qa-selftest` in the pre-release tier.
- **VERIFICATION:** Template and QA runs on three bpy versions; CI matrix; self-test proves known-bad assets fail.

### B02

**Blender built-ins in the factory (texture baking, Geometry Nodes, Asset Browser catalogs, Rigify)** · Blender · PARTIAL · P2

- **PREVIOUS CLAIM:** Workbench: a 128px bake fixture.
- **ACTUAL STATE:** Texture baking is scripted (`tools/blender/bkit/bake.py`): `palette_atlas` (the default for every template), `vertex_colors`, `atlas_uvs` and deterministic Cycles `bake_maps` (base colour sRGB, roughness and metalness Non-Color, tangent-space OpenGL normal, emissive; CPU, fixed samples and seed, no denoiser), plus `bake --mode tile` writing material-library/1 entries; `textures.py` and QA enforce map roles, colour spaces, Reimport suffixes, one UV set in 0..1 and the 1024 px limit. Geometry Nodes, asset catalogs and Rigify are not scripted, and the avatar_body template is not done.
- **EVIDENCE:** G6: qa-selftest bake, texture, library and tile cases (51/51 on bpy 5.0.1, 5.1.2 and 5.2.2; 51/51 on 5.0.1 on the integrated branch); `factory.py bake pickup --mode maps` and material-preview renders reviewed.
- **DEFECT:** Studio binding of PBR maps is unobserved (Reimport suffixes; how the glTF import treats the packed metallicRoughness image is unverified). Geometry Nodes, catalogs and Rigify are missing.
- **ROOT CAUSE:** Scoped; the Studio half needs an owner import.
- **IMPACT:** Kits and catalogs stay manual; baked maps may need adjustment once imported.
- **FIX:** Owner imports a maps-baked template and runs `tests/engine/import_appearance.luau` (B06); Geometry Nodes and catalogs in a later pass.
- **VERIFICATION:** Headless bakes on three bpy versions; Studio half pending (probe `import_appearance`).

### B03

**Preview renders for visual QA** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Turntable and comparison images.
- **ACTUAL STATE:** `render-manifest` renders SceneKit manifests (Cycles CPU) from their cameras, or frames cameras from the part bounds when a manifest has none, so plain `scene:manifest()` output renders; templates render front and three-quarter views. The stage ground sits below the lowest mesh, so floors at Y=0 no longer render black; the pre-release tier renders the building, dungeon, settlement and forest fixtures. The factory also renders intake raw and final stills, material-preview sphere and cube tiles and deterministic icons; the five course manifests render with `render-manifest`.
- **EVIDENCE:** `build/previews/*.png` reviewed; they exposed three geometry bugs in the first round, and in this round black floors (stage coplanar with floor tops) and black discs at forest path bends (joint pads coplanar with segments), both fixed and re-rendered. Integration: G6 reviewed previews of the ten new templates, the bakes, intake and material tiles (a coplanar conveyor chevron and the dropper arm were fixed from them); G7 reviewed the five course renders on bpy 5.0.1 (arena hazard and tile defects fixed).
- **DEFECT:** Small CPU renders; not Studio lighting.
- **ROOT CAUSE:** Headless.
- **IMPACT:** Look in Studio still needs S02 captures.
- **FIX:** n/a
- **VERIFICATION:** Renders reviewed in this pass.

### B04

**Round trip, Blender half (create, revise, export, reimport, diff, expectation)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Baseline/revision exports and reimport hashes.
- **ACTUAL STATE:** `roundtrip` builds SM_RoundTripMarker v1 and v2 (no export if source QA fails, stale outputs removed first), exports FBX and GLB at the world origin, reimports both, checks triangles, dimensions, origin at the base centre and at the world origin, front direction, surface offsets, materials and names, and writes `roblox_expectation_v*.json` (with `front_offset`/`up_offset`) for the Studio side. The marker now carries a side fin (for the mirrored-import check) and a palette atlas, and the re-import checks side, one material, the colour map and the colour attribute; the v1 expectation is 4.6 x 7.0 x 3.5 studs, front_offset -0.626, side_offset 0.197, 44 triangles.
- **EVIDENCE:** `roundtrip-report.json` passes on bpy 5.0.1, 5.1.2 and 5.2.2 in the container (G6: v1 25 checks, v2 26), on the owner's Blender 5.1.2 (9c12091, 9c024fb, 1eee84a) and in CI; on the integrated branch in this pass v1 and v2 PASS on bpy 5.0.1.
- **DEFECT:** Fixed after the Studio import: the marker's origin sat off the world origin (Studio pivot), and the pivot check only looked at minimum Z.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Runs in the pre-release gate and CI.

### B05

**Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** · Blender · PARTIAL · P0

- **PREVIOUS CLAIM:** Blocked: no documented zero-upload import route.
- **ACTUAL STATE:** The owner imported the neutral SM_RoundTripMarker v1 and v2 with Import 3D (Scale Unit = Stud) into the unpublished diagnostic place, and `ImportInspector` (at 9c024fb) ran in Studio with its default EditableMesh reader. Both revisions matched Blender on scale (4 x 7 x 3.5 and 4 x 8 x 4.5 studs), rotation, facing (surface-centroid offset -0.620 vs -0.62 and -1.026 vs -1.026, plus a screen_capture from -Z) and collision, and `compareRevisions` detected the update. The pivot failed: Studio puts the model pivot at the FBX file origin, and the marker's origin sat off Blender's world origin. Each import uploaded a private mesh asset to the owner's account (there is no local-only import). Since then the inspector was hardened in Lune (pivot as a stud offset from the base centre, triangle count, `appearance_bound` for multi-material imports, missing expectation data fails, `compareRevisions` on size, triangles and surface offsets), and the integration added an appearance block per route (colour and PBR maps on SurfaceAppearance or MeshPart, vertex colours with part Color, MaterialVariant names), `orientation_side` for mirrored imports (from the expectation's side_offset) and clips/1 inspection (B07). The marker is now palette-baked with a side fin (B04).
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json` (inspector at 9c024fb; v2 was the pre-fix export, which matches its +1.25 stud pivot error exactly). `lune run tests/run.luau import_inspector`: 28 cases on the integrated branch (8 before the hardening, whose new spec failed 11 cases against the old inspector; 31 single-check mutations were all caught at 18 cases).
- **DEFECT:** The pivot fix (1eee84a), the hardened inspector and the appearance, side and clip checks have not run in Studio; the EditableMesh colour reader is untested there. The palette-baked marker should now bind a colour map (B06), unconfirmed until imported. The marker's vertical asymmetry (up offset about 0.05 studs) is too small for the upside-down diagnosis; the pivot check and the capture catch that case instead.
- **ROOT CAUSE:** Studio's importer anchors the pivot at the file origin, not at the object origin.
- **IMPACT:** Every asset exported off the world origin arrives with a misplaced pivot.
- **FIX:** Export at the world origin (done for the marker; the QA pivot check covers origin vs bounds). Confirm by importing the fixed, baked v2.
- **VERIFICATION:** ImportInspector in Studio at 9c024fb: 6 of 7 checks passed for v1 and v2 and the revision was detected; the hardened and extended inspector is verified in Lune only.

### B06

**Material colour survives the Studio import** · Blender · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** None (first pass never imported into Studio); MISSING in this pass until the bake landed.
- **ACTUAL STATE:** The 2026-10-05 imports were plain grey (Color 0.639, 0.635, 0.647, empty TextureID, no SurfaceAppearance): per-material Principled base colours do not carry through Import 3D. Now a palette atlas is the default bake for every template and the marker: one `MAT_<asset>` with `<asset>_Color.png` plus a `Color` vertex-colour fallback. Blender re-imports of the FBX and GLB keep one material, a bound colour map whose sampled face colours match the source materials, and the colour attribute. `ImportInspector` fails `appearance_bound` when a multi-material import has no texture, SurfaceAppearance or vertex colours.
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json` (the grey import); `roundtrip-report.json` checks appearance_one_material, appearance_color_map and appearance_color_attribute on bpy 5.0.1, 5.1.2 and 5.2.2 (G6; 5.0.1 again on the integrated branch); `qa-selftest` palette_atlas.
- **DEFECT:** No Studio import of a baked asset yet, so whether Import 3D binds the colour map (and what it does with the vertex colours) is unobserved.
- **ROOT CAUSE:** A MeshPart takes one texture or SurfaceAppearance; material base colours without image textures are not converted. Each import uploads a private asset, so it needs the owner's approval.
- **IMPACT:** Until confirmed, factory assets may still arrive colourless.
- **FIX:** Palette atlas by default (done in Blender); the owner imports a baked asset and runs probe `import_appearance`.
- **VERIFICATION:** Pending T3 probe `import_appearance`: a Studio import shows the baked colours and appearance_bound reports a texture.

### B07

**Rigged and animated asset into Studio (skinned mesh, bone names, animation clip)** · Blender · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Not claimed separately; the templates' Blender QA stood in for it.
- **ACTUAL STATE:** The rigged and animated templates (humanoid, NPC, enemy, creature, animation test, pet_follower with idle and walk) pass Blender QA headlessly, including bone influences, R15 rig profiles (the mirrored sides were fixed) and clip checks. Clips export as a multi-clip GLB and per-clip FBX with a clips/1 sidecar (B10). `ImportInspector.inspectClips`/`studioClips` and `tests/engine/import_clips.luau` compare an import with the sidecar (presence, length within half a frame, markers, play plan) and record where clips land. None has been imported into Studio: the only Studio import so far was the static SM_RoundTripMarker.
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json` (static marker only); G6: qa-selftest clips_export, clip_qa_failures, r15_profile and gameplay_templates on three bpy versions; `import_inspector` 28 on the integrated branch.
- **DEFECT:** The Studio half of the character, NPC, enemy and animation pipelines is unobserved: skinning, Bone names and clip playback.
- **ROOT CAUSE:** Every 3D import uploads a private asset, which needs the owner's approval; only the marker was approved.
- **IMPACT:** Character and animation assets may break on import (bone names, skinning, clip length) without anyone noticing.
- **FIX:** Import `pet_follower_clips.glb` (or a clip FBX) and run probe `import_clips`; include a humanoid for bone names and skinning.
- **VERIFICATION:** Pending T3 probe `import_clips`: inspector output in Studio saved under `reports/`.

### B08

**Retopology, LOD chains and smooth skin weighting (bkit)** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Skill promised weighting; only rigid binding existed.
- **ACTUAL STATE:** `ops.voxel_remesh`, `ops.quadriflow`, `ops.lod_chain`, `ops.bind_auto`/`ops.limit_weights` and the seeded `ops.noise_displace` run headless on bpy 5.0.1, 5.1.2 and 5.2.2. Heat weighting is normalised and capped at 4 influences; vertices heat cannot reach are bound to the nearest bone and reported. LOD copies keep the Armature modifier and their triangle counts strictly decrease.
- **EVIDENCE:** `factory.py qa-selftest` (33 cases when this landed, 51 now) on all three versions, including an auto-weighted humanoid (raw heat gave up to 7 influences; after `bind_auto` max 4, normalised, none unweighted), a 1280/640/320/128-triangle rock LOD chain, a skinned LOD chain, and bad cases (5 influences, unweighted vertices) failing the right check; seeded geometry hashes identical across versions; 7 sabotaged ops each caught. 51/51 on bpy 5.0.1 on the integrated branch.
- **DEFECT:** Not imported into Studio; glTF export hides skin defects (it keeps the 4 strongest influences and rebinds unweighted vertices), so weights are judged on the .blend or .fbx.
- **ROOT CAUSE:** Studio imports upload assets (see B07).
- **IMPACT:** Roblox's handling of smooth FBX skin weights is unobserved.
- **FIX:** Include `auto_weighted_humanoid.fbx` in the B07 import.
- **VERIFICATION:** Self-test on three bpy versions in the pre-release gate and CI.

### B09

**Brush sculpting in scripts** · Blender · INTENTIONALLY_EXCLUDED · P3

- **PREVIOUS CLAIM:** Listed in the mission's operations.
- **ACTUAL STATE:** Excluded: `bpy.ops.sculpt.brush_stroke` needs a 3D viewport and fails its poll in background mode (checked on 5.0.1 and 5.2.2), and scripted strokes are not reviewable art. The seeded `noise_displace` modifier is the scripted stand-in for rocks and terrain pieces; hand sculpting happens in Blender, followed by `factory.py qa`.
- **EVIDENCE:** Background poll failure; `op_noise_displace_seeded` self-test case on three versions.
- **DEFECT:** n/a
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Self-test case for the stand-in.

### B10

**Animation clip export (clips/1, multi-clip GLB)** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `tools/blender/bkit/clips.py`: clips are tagged on actions (slot, range, fps, loop, root_motion, priority, weight, markers); one GLB carries one animation per clip through NLA tracks, one FBX per clip follows Roblox's export recipe (no forced start/end keys, simplify 0.0), and a clips/1 sidecar travels with them for GameKit AnimSet and ImportInspector. QA: clip_range, clip_names_unique, clip_slot, marker_in_range, clip_bones_known, clip_loop_closed, clip_in_place.
- **EVIDENCE:** G6 on bpy 5.0.1, 5.1.2 and 5.2.2: qa-selftest clips_export (2 GLB animations of the right lengths, FBX ranges kept, sidecar valid) and clip_qa_failures; the pet_follower clip files pass `factory.py qa` and `tools/gltf_validate.py`.
- **DEFECT:** Markers and loop flags travel only in the sidecar; the Studio import is B07. AnimSet was tested on synthetic clips/1 documents, not these sidecars.
- **ROOT CAUSE:** Neither format carries every clip property Roblox needs.
- **IMPACT:** Games must ship the sidecar with the clips.
- **FIX:** n/a
- **VERIFICATION:** Executed headless on three bpy versions.

### B11

**Kit export (kit/1) and offline asset intake** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `factory.py kit --templates <kinds>` writes kit/1 (pieces with `source = blender_template:<kind>`, atlas materials, sockets and collision proxies) for `SceneKit/Kit` (S10). `intake` takes a third-party GLB through QA, normalise and palette bake to a kit/1 entry; `compare-export` diffs the FBX and GLB of one asset; `icon` renders deterministic transparent thumbnails; `textures` and `bake` check and make map sets.
- **EVIDENCE:** G6 command suite 18/18 exit 0 on bpy 5.0.1, 5.1.2 and 5.2.2: `kit --templates pickup,checkpoint_gate` (kit/1 validates; each piece's GLB and FBX pass QA and each GLB passes the glTF validator), `intake` on the bundled GLB fixture, `compare-export` (FBX and GLB PASS) and `icon` (pixel hash stable within a version, different across versions); intake raw and final previews reviewed. On the integrated branch the qa-selftest intake case passes on bpy 5.0.1.
- **DEFECT:** Pieces have not been imported into Studio (B06, S10); greybox art only; icons are not byte-identical across Blender versions; intake has run only on the bundled fixture.
- **ROOT CAUSE:** Headless by design; no third-party asset sourced (setup-only).
- **IMPACT:** The first real intake may need a normalise or bake fix.
- **FIX:** Gate step `blender-kit` (pre-release, added in c70ff63) builds a kit on every pre-release run; it passed on bpy 5.0.1, 5.1.2 and 5.2.2 on the integrated head, not yet in CI.
- **VERIFICATION:** Executed headless on three bpy versions.

### B12

**glTF structural validation** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `tools/gltf_validate.py` (pure Python, gltf-validate/1) checks the GLB container, buffers and views, accessor bounds and alignment, attributes, at most 4 influences, normalised weights, the node graph, skins, morph targets, animation samplers, image headers (size, power of two) and TEXCOORD_0; `gltf-transform inspect` runs only when npx exists and the owner opts in.
- **EVIDENCE:** On the integrated branch `tests/test_gltf_validate.py` 22 OK; G6: every template GLB passes. Gate step `gltf-validate-templates` (pre-release, added in c70ff63) validates them on every pre-release run; it passed on the three bpy versions on the integrated head, not yet in CI.
- **DEFECT:** Not the Khronos validator (no extension semantics); the gltf-transform path was not exercised.
- **ROOT CAUSE:** Pure Python by choice (no network, no Node dependency).
- **IMPACT:** Extension-level problems would pass.
- **FIX:** n/a
- **VERIFICATION:** Unit tests and representative runs.

### R01

**Inherited pure-Luau modules (ReceiptLedger, CommerceCatalog, Lifetime, Motion, AudioMixer, AudioDirector, EffectsPool, MovementProfile, AnimationInspector and WorldInspector maths, UI logic, FaultQueue)** · Inherited modules · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Workbench Lune suites: 28 runtime fixtures plus creator and network suites; commerce foundation partially verified.
- **ACTUAL STATE:** Modules and the first pass's 7 Lune suites were copied into the repo and re-run against the repo's copies. Seven second-pass specs add grant-once under retried UpdateAsync transforms, unknown/malformed receipts, retry then defer, v1 migration, corrupt schema refusal, cross-universe refusal, lifetime eviction/expiry/closed and bounded motion curves. In the integration `ReceiptLedger` gained `minRetentionDays` (default 30, a convention), an injected clock, pruning of out-of-window receipts before the capacity check and the reasons `pruned`, `corrupt_receipt` and `invalid_clock`; `CommerceCatalog` gained `validateEntry`, a `productId` alias with `id_conflict` and `fromCatalog` (catalog/1) with available, preview_only and unavailable states, legacy `new` unchanged. AudioMixer, AudioDirector and EffectsPool moved to `packages/AVKit` (Pool gained expire and remaining) and the old paths re-export them; the inspectors share one `assertDiagnosticTarget` (Studio, GameId 0, PlaceId 0).
- **EVIDENCE:** On the integrated branch: runtime 31 (three new retention cases), creator animation 32, audio/movement 6, effects 15, UI 10, world 25, diagnostics network 11 (130 cases, 106 before) and `tests/inherited.spec.luau` 7; each is a gate step.
- **DEFECT:** The runtime suite used to write `reports/runtime_status.json` into the tracked reports folder (fixed). The 30-day receipt retention is a convention, not a documented Roblox re-delivery window.
- **ROOT CAUSE:** Workbench-specific output path; the platform does not publish the window.
- **IMPACT:** Real DataStore, audio and engine behaviour remain unverified (mocks and maths only).
- **FIX:** Output redirected to `build/`; suites in the pre-commit gate; engine behaviour through the AVKit and GameKit probes.
- **VERIFICATION:** Inherited suites and new specs pass in the gate.

### R02

**Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector)** · Inherited modules · WEAK · P2

- **PREVIOUS CLAIM:** Native receipts for UI, effects, world, observation and network.
- **ACTUAL STATE:** Copied and built into `factory.rbxl` and the creator/diagnostic places by Rojo. `NativeUI` now uses FontFace and takes env, events and measure as options, so it loads and runs in Lune; `Creator/UI` uses string requires, Scope, PreRender, FontFace and catalog/1 `entry.id`. `RobloxReceiptAdapter` (T4, no probe) binds on `BindReceiptHandler` or the legacy callback and turns a ledger error into `ledger_error`. `NativeAudio` carries a DEPRECATED header pointing to `AVKit/AudioGraph`, and `Creator/Effects` uses string requires to the AVKit pool. Nothing was executed in Studio in this pass; the first pass's native receipts are replays.
- **EVIDENCE:** On the integrated branch: `uikit_inherited` 5 (NativeUI state machine, card chain, guarded callbacks, theme repaint, focus restore, disconnection, legacy_font rule), `tests/creator/ui.luau` 10, the receipt adapter through FakeMarketplace (`gamekit_platform_commerce` 14, runtime 31); Rojo builds of creator and diagnostic (G4, G5).
- **DEFECT:** No live re-run of any module; NativeAudio, NativeEffects, Effects and Observation still have no Lune case; no real receipt has been processed (T4).
- **ROOT CAUSE:** Studio only on the PC; receipts need a published place.
- **IMPACT:** Unknown regressions since the receipts were taken.
- **FIX:** Re-run `fixtures/creator/UI.client.luau` and `fixtures/runtime/Diagnostic.client.luau` in Studio; new code uses `AVKit/AudioGraphRoblox` and `VfxPoolRoblox`; real receipts only in a future game's private test place.
- **VERIFICATION:** Fresh receipts with today's Studio version.

### K01

**Runtime-kit foundation and contract (Env, Probe, Fsm, Signal, Scope, Retry, Events, Settings, Catalog; tiers, probe protocol, require allowlist)** · Runtime kits · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `docs/runtime-kits.md` froze the contract the build groups shared: pure cores plus `*Roblox` adapters, tiers T0 to T4 (T3 needs a Studio probe on the unpublished kits place; T4 needs live services and is never claimed), the ENGINE_CHECK/ENGINE_DONE probe protocol, Server Authority rules, a require allowlist, module ownership and the cross-group formats (kit-event/1, settings/1, catalog/1, clips/1, kit/1, material-library/1, perf/1). Stage 0 GameKit: Check, Json (canonical encode), Env (with the diagnostic-place guard), EnvRoblox (T3, probe `foundation_env_studio`), Signal, Scope, Fsm (fsm/1), Retry, Events (kit-event/1 builders and sinks), Settings (settings/1), Catalog (catalog/1, no prices) and Probe. `fixtures/kits.project.json` maps every package and the opt-in fixtures.
- **EVIDENCE:** On the integrated branch: `gamekit_foundation` 75 cases; `kits_load` 167 cases (header, tier, probe name and registration, require allowlist, no `GetService` in cores, every core loads in Lune); `tools/kit_tiers.py` reports no problems over 161 modules; the kits place builds with Rojo.
- **DEFECT:** EnvRoblox's probe `foundation_env_studio` has not run; every adapter's T3 status waits on the owner's runs (T14).
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** The contract is enforced headlessly; the shared Studio Env is unobserved.
- **FIX:** Owner runs `foundation_env_studio` with the other probes.
- **VERIFICATION:** Lune specs and the tier report in the gate.

### K02

**Player data with session locking and settings persistence (PlayerData, SettingsStore)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed (persistence existed only as the inherited ReceiptLedger, R01).
- **ACTUAL STATE:** `GameKit/PlayerData` (T0): session-locked data with versioned migrations and three backends (memory, DataStore, an injected ProfileStore that is never vendored); load refusals are closed reasons (locked, corrupt, newer_schema, migration_failed, too_large); `grantReceipt` and `keyStore`. `PlayerDataRoblox` (T3, probe `platform_playerdata_memory`) chooses the backend and binds with kicks, autosave and a BindToClose flush. `SettingsStore` persists settings/1 and gives a patch schema for a guarded remote.
- **EVIDENCE:** On the integrated branch: `gamekit_platform_data` 33 and `gamekit_platform_settings` 7, with FakeDataStore and FakeProfileStore failure injection (throttling, a stolen session, a player leaving mid-load, a newer schema). The `session_persistence` slice in `slices_integration` (22 cases, golden slices-integration) runs two servers over one FakeDataStore: the second is refused while the first holds the lock, a stolen lock reports lock_lost, a migration runs once and data round-trips exactly, with Wallet, Inventory, Progression, SettingsStore and Onboarding using `keyStore` as their store.
- **DEFECT:** Probe `platform_playerdata_memory` has not run; real DataStore and ProfileStore sessions are T4 (never claimed here). Wired as the economy kit's store only in Lune (the session_persistence slice), not in a running game.
- **ROOT CAUSE:** Studio runs only on the PC; live persistence needs a published place.
- **IMPACT:** Session locking against the real services is unproven.
- **FIX:** Run the probe; live sessions only in a future game's private test place.
- **VERIFICATION:** ENGINE_DONE ok for `platform_playerdata_memory`; T4 never claimed.

### K03

**Policy, text-filter, config and moderation gating (fail-closed)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `PolicyGate` and `TextFilter` cores (T0) fail closed: a policy error refuses and a filter failure shows nothing. `PolicyGateRoblox` is T3 (probe `platform_policy_emulator`); `TextFilterRoblox`, `ConfigRoblox` and `ModerationRoblox` are T4 with no probe; the `Config` and `Moderation` cores are T0.
- **EVIDENCE:** On the integrated branch: `gamekit_platform_policy` 15 (service errors, unknown policy) and `gamekit_platform_config` 6.
- **DEFECT:** Probe `platform_policy_emulator` has not run; real filtering, bans and ConfigService are T4. Unconfirmed platform facts (BanAsync limits, ConfigService snapshot method names) are handled by failing closed.
- **ROOT CAUSE:** Studio runs only on the PC; the T4 services need a published place.
- **IMPACT:** Policy-gated features are proven against fakes only.
- **FIX:** Run the probe with Studio's Player Emulator; T4 parts only in a future game.
- **VERIFICATION:** ENGINE_DONE ok for `platform_policy_emulator`.

### K04

**Commerce: catalog/1 prompts, prices, ownership and receipts** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Commerce foundation partially verified (workbench).
- **ACTUAL STATE:** `GameKit/Commerce` (T0): `canPrompt` with closed reasons, a price provider that never yields, an ownership cache (subscription, negative and unknown TTLs), a grant writer and a receipt processor that grants once and returns Processed only after a durable save. `CommerceRoblox` (T4, no probe) fetches info, prices, ownership and price levels, prompts only after `canPrompt` and binds receipts on `BindReceiptHandler`. UIKit `ShopCard` shows catalog/1 entries with no purchase call.
- **EVIDENCE:** On the integrated branch `gamekit_platform_commerce` 14 with FakeMarketplace; runtime 31 (ReceiptLedger retention, R01). The `session_persistence` slice delivers one receipt twice through a PlayerData session and it grants once; it found that a live Wallet or Inventory later overwrote a receipt grant, fixed in 39991f5 (callers reload from `onResult`, `docs/gamekit-platform.md`).
- **DEFECT:** Live prompts, prices and receipts are T4 and excluded here (X01). Unconfirmed: whether BindReceiptHandler receives ad-reward receipts, the receipt re-delivery window, the GetUsersPriceLevelsAsync shape and whether developer products carry IsForSale; the code fails closed on each.
- **ROOT CAUSE:** Purchases need a published place and the owner's account.
- **IMPACT:** Commerce logic is proven against fakes only.
- **FIX:** Only in a future game's private test place, by the owner.
- **VERIFICATION:** Lune specs; live purchases never claimed in this factory.

### K05

**Matchmaking queue, teleport and party adapters** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `GameKit/Queue` (T0) makes deterministic matchmaking plans: parties never split, skill bands widen from the oldest ticket, partial matches, pools and expiry. `PartyRoblox` is T3 (probe `platform_party_simulator`); `MemoryQueueRoblox` (push, pull, ack, size and cycle with requeue, drop, expire and lost accounting) and `TeleportRoblox` (options, teleport, reserve, retry on Flooded after 15 s and Failure after 1 s, at most 3) are T4.
- **EVIDENCE:** On the integrated branch `gamekit_platform_queue` 14 plus golden `gamekit_platform_queue`, with FakeMemoryStore and teleport fakes.
- **DEFECT:** Probe `platform_party_simulator` has not run; MemoryStore queues and teleports need a published game (T4). Unconfirmed: GetPartyAsync's field shape and ReserveServer's current status.
- **ROOT CAUSE:** Studio runs only on the PC; the T4 services need a published place.
- **IMPACT:** Cross-server flows are proven against fakes only.
- **FIX:** Run the party probe; T4 parts only in a future game.
- **VERIFICATION:** ENGINE_DONE ok for `platform_party_simulator`.

### K06

**Action gameplay kit (rounds, vitals, combat and hit validation, projectiles, zones, abilities, movement, vehicles, interaction, animation sets)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** 13 T0 cores in `packages/GameKit`: RoundLoop (phase timing, late-join policy, last standing, fsm/1 snapshot), Vitals (modifier pipeline, downed, revive, regen; integer-safe, NaN rejected), Cooldowns (server clock, charges), StatusEffects, Knockback (velocity maths; ragdoll as a request event), Hitbox (sphere, box and capsule overlap and swept tests, pose history, hit-claim validation with a 200 ms rewind cap), Projectile (closed-form gravity and drag, pierce, client-shot validation), Zones (hysteresis, hazards, kill volumes, gated courses), Abilities (cost and cooldown committed at cast start, GCD, channels), Movement (sprint, coyote-time jump, dash, slide, ledge, teleport and fly checks), Vehicles (fixed-step arcade car, rig plan), Interact (server-timed holds, forged touches, rate limits) and AnimSet (clips/1 to standard slots, markers, an 8-track player). T3 adapters, each with a probe: RoundLoopRoblox, HitboxRoblox (Raycast, Spherecast, Blockcast casters and Shapecast), ZonesRoblox, VehicleRigRoblox, InteractRoblox, AnimSetRoblox (game-supplied or Studio-only temporary ids; never uploads), MovementRoblox and AuthorityRoblox (K07). Seeded slices `round_arena` and `time_trial`.
- **EVIDENCE:** On the integrated branch: `gamekit_action` 131 cases in 12 files and `gamekit_slices_action` 4 with golden gamekit-action matching (round_arena a6e958d5, time_trial 70b6784a). Engine-only checks are listed in each spec's ENGINE_ONLY list and fail against the fakes by design.
- **DEFECT:** The eight `action_` probes have not run in Studio. Unverified engine facts: BindToSimulation's return shape and dt argument, VehicleRig motor and servo signs, the temporary animation id method names, whether `GetNetworkPing` is one-way or round trip, Humanoid FloorMaterial and launch velocity under Server Authority. AnimSet was tested on synthetic clips/1 documents.
- **ROOT CAUSE:** Studio runs only on the PC; `Workspace.AuthorityMode` cannot be set from script.
- **IMPACT:** Adapter behaviour in the engine is unproven.
- **FIX:** Run the `tests/engine/action_*.luau` entries on the kits place with AuthorityMode Server.
- **VERIFICATION:** ENGINE_DONE ok for the eight `action_` probes.

### K07

**Server Authority fixture (BindToSimulation, Input Action System input)** · Runtime kits · PARTIAL · P1

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `fixtures/kits/shared/authority_Arena.luau` is the core, run in Lune and Studio: input is token-bucketed, validated, clamped and sequenced. `authority_Sim.server.luau` uses one `bindStep`, attributes through a 64-per-Instance writer, an UnreliableRemoteEvent for input and a RemoteEvent for claims; `authority_Input.client.luau` builds its actions from one `GameKit/InputMap` map through `InputMapRoblox` and stamps claims with the `ArenaClock` attribute. Opt-in with `SETUP_ONLY_KitFixture = authority`, on diagnostic places only. Four authority probes: `authority_simulation_bind`, `authority_mode`, `authority_attribute_budget`, `authority_input_actions`.
- **EVIDENCE:** On the integrated branch `gamekit_action_authority` passes inside the 131 action cases; the round_arena slice runs the arena with an exploiter bot and a 150 ms bot; the kits place build contains the scripts (Script, LocalScript, ModuleScripts as intended, G2). The `authority_input_client` slice loads the client script itself in Lune over fakes and its payloads pass the fixture arena; `tests/engine/authority_simulation_bind.luau` is now the Studio runner for that probe (not run).
- **DEFECT:** Never run in Studio; BindToSimulation's shape and IAS replication to the server are unverified.
- **ROOT CAUSE:** Studio runs only on the PC; AuthorityMode is an owner setting.
- **IMPACT:** Server-authoritative play is proven only headlessly.
- **FIX:** Owner sets AuthorityMode Server, runs the authority suite and a 2-client session.
- **VERIFICATION:** ENGINE_DONE ok for the four authority probes and a clean 2-client run.

### K08

**Economy and progression kit (wallet, items, inventory, progression, objectives, streaks, crafting, generators, unlocks, seasons, live-ops, economy simulation)** · Runtime kits · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** All T0 with the store, sink and policy injected: Wallet (integer currencies, caps and floors, atomic multi-currency transactions, two-phase prepare/commit/rollback, retry-safe transaction ids, store written before reporting; a store that refuses a write (returns false) fails the change with `store_failed` and reports nothing; `reload()` re-reads after another writer), ItemDefs and Inventory (stacks, instances with uids, equip slots by kind, capacity, weight, unique and paid items kept apart, atomic apply, quarantine on load), Progression, Objectives, Streaks, Crafting (refuses recipe data that would multiply items), Generators (capped offline earnings from server UTC), UnlockGraph (refuses cycles and unreachable nodes), SeasonTrack (free and premium tracks as flags, no prices), LiveOps (UTC windows, seeded rotations) and EconomySim (offline Monte Carlo, economy-sim/1 report).
- **EVIDENCE:** On the integrated branch: `gamekit_economy` 141 cases in 17 files and `gamekit_slices_economy` 3 with golden gamekit-economy matching (plot_generator 8220246e, collection_loop 5b0b8486); G3: EconomySim gives the same report for the same seed, conserves currency and matches a closed-form case. The `session_persistence` and `projectile_arena` slices drive Wallet, Inventory and Progression from PlayerData and from round results; they found that a refused write was counted as saved (fixed in 39991f5, with `Wallet.reload` and `Inventory.reload`).
- **DEFECT:** Exercised with PlayerData (K02) and Telemetry only in Lune (slices), not with live DataStores in a running game; every number is the game's to set.
- **ROOT CAUSE:** Setup-only: no game exists; live services are T4.
- **IMPACT:** Integration with persistence is proven by interface only.
- **FIX:** Wire PlayerData as the store and Telemetry as the sink in the first game; tune with EconomySim.
- **VERIFICATION:** Lune specs and slice goldens in the gate.

### K09

**Odds disclosure and paid-random policy gate** · Runtime kits · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `OddsTable` discloses odds by largest remainder over 1,000,000 units, so they sum to exactly 100.0000%, and updates the disclosure for once-only outcomes, boosts and disclosed pity. Paid rolls refuse unless the injected predicate allows `paidRandomItems` (a missing or failing policy refuses). `Trade` requires both players' `trading` policy for paid items and rechecks at commit.
- **EVIDENCE:** On the integrated branch `gamekit_economy_odds` 9 and `gamekit_economy_trade` 13 pass; G3: 500 seeded random tables sum to 100.0000%, a paid roll without a policy is refused, and chi-square on 100k seeded rolls was 3.09 against a limit of 18.467.
- **DEFECT:** The policy read is K03's PolicyGate (T3, probe pending); no UI component renders the disclosure yet.
- **ROOT CAUSE:** Integration happens in a game.
- **IMPACT:** Low: the gate fails closed.
- **FIX:** Pass the PolicyGate predicate in the game; render `disclose()` before any purchase.
- **VERIFICATION:** Lune specs.

### K10

**Trade escrow, plots, followers, outfits, dialogue, onboarding and voting** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** T0: Trade (escrow state machine; any change resets both accepts; accept names the current revision; confirm countdown; two-phase commit across inventories and wallets with rollback; journal idempotency; one open trade per player), Plots (claims resolve in call order; ordered, seeded or nearest assignment), Followers (line, grid, arc and ring formations, stable slots, catch-up and teleport), Outfits (outfit/1 validation and HumanoidDescription plans; no asset ids ship), Dialogue (dialogue/1 graphs checked for unreachable nodes, islands, missing exits and endless loops; sessions resume without re-running effects), Onboarding (funnel that resumes after rejoin) and VotingRound (seeded ballots, no self votes, tie-breaks). T3: FollowersRoblox (AlignPosition and AlignOrientation from BindToSimulation, PreSimulation fallback, probe `economy_followers_formation`) and OutfitsRoblox (probe `economy_outfits_apply`). Probes `economy_plots_claim_race` and `economy_trade_two_client` exercise the cores in a session.
- **EVIDENCE:** On the integrated branch the economy specs pass (trade 13, probes 3); G3: a 400-round seeded trade fuzz with injected store failures conserved every item, uid and coin; the probe registry passes against FakeEconomyEngine (wiring only) and the two-client probe fails without two players. The `ui_onboarding_flow` and `session_persistence` slices drive Onboarding through UIKit and PlayerData: order enforced, resume after rejoin, each event reported once, and a refused write now fails as `store_failed` (39991f5).
- **DEFECT:** The four `economy_` probes have not run. Unverified: the BindToSimulation callback signature (FollowersRoblox derives dt from the clock if none is passed), whether `Humanoid.ApplyDescriptionAsync` exists (chosen at run time) and the default avatar scale ranges.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Follower and outfit adapters are unproven in the engine.
- **FIX:** Run the four `tests/engine/economy_*.luau` entries.
- **VERIFICATION:** ENGINE_DONE ok for the four `economy_` probes.

### K11

**UI kit, components and transitions (packages/UIKit)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** UI logic existed only in the inherited Creator/UI and NativeUI (R01, R02).
- **ACTUAL STATE:** Tokens (neutral dark and light themes, hue slots left to the game, a colour-blind override from settings/1), Style (FontFace only; emits a StyleSheet plan that `StyleRoblox` builds natively, T3), Breakpoints, State, Localize, Ease (engine easing curves plus springs, probe `ui_ease_parity`), Transitions (interruptible; springs keep velocity; reduced motion collapses to short fades), Nav (probe `ui_nav_keyboard`), Build (the component contract), 27 components (including TouchActionButton, TeleportTransition, a SettingsPanel bound to settings/1 and a ShopCard that shows catalog/1 entries with no purchase call and a setup-mode watermark), gallery stories in the UI Labs `(target) -> cleanup` form and a story browser with theme, reduced-motion, pseudo-localisation and device switches.
- **EVIDENCE:** On the integrated branch `uikit` 153 cases in 9 files (golden uikit-ease); `uikit_probes` 9 runs the six UI and input probes against fakes (not engine evidence).
- **DEFECT:** Ease parity with TweenService, StyleSheet application (Lune has no `StyleRule:SetProperties`), StyleQuery conditions and GuiService selection are unverified; touch-drag release and emoji grapheme counting are unconfirmed; no gallery captures exist.
- **ROOT CAUSE:** Studio runs only on the PC; Lune cannot evaluate StyleSheets or layout.
- **IMPACT:** Visual and input behaviour in the engine is unproven.
- **FIX:** Run probes `ui_ease_parity`, `ui_style_sheet` and `ui_nav_keyboard` in a client session and capture the gallery.
- **VERIFICATION:** ENGINE_DONE ok for the three probes plus gallery captures.

### K12

**UI audits (touch target, contrast, text size, safe area, overlap, gamepad reach, legacy fonts, text fit)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `UIKit/Audit` (T1) runs 11 rule ids over a UI tree; seeded bad trees are flagged with exact rule ids and paths, text with TextTransparency 1 is exempt from contrast, and the layout-free rules are clean on every gallery story. `AuditRoblox` (T3, probe `ui_gallery_audit`) uses engine AbsoluteSize and TextFits, a CoreUISafeInsets probe for the safe area, a pseudo-localisation text-fit pass and a legacy Font enum check.
- **EVIDENCE:** On the integrated branch `uikit_audit` 19 and `uikit_probes` 9 (fakes).
- **DEFECT:** Layout rules (touch target, overlap, safe area, gamepad reach) need engine AbsoluteSize; the gamepad reachability heuristic is unconfirmed.
- **ROOT CAUSE:** Lune cannot read layout.
- **IMPACT:** Layout defects pass the headless audit.
- **FIX:** Run probe `ui_gallery_audit` in the gallery session (K11).
- **VERIFICATION:** ENGINE_DONE ok for `ui_gallery_audit`.

### K13

**Input map on the Input Action System (GameKit/InputMap, InputMapRoblox)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `InputMap` (T0): contexts, reserved actions, rebinding with swap, saved overrides that round-trip (applied together, conflicts reverted one by one), glyphs and deterministic validation messages. `InputMapRoblox` (T3, probe `inputmap_contexts`) builds one InputContext per context, one InputAction per action and one InputBinding per binding.
- **EVIDENCE:** On the integrated branch `gamekit_inputmap` 12, including a seeded 600-edit run in which a reserved action never ends up unbound. The authority client fixture now builds its actions through InputMapRoblox (eba5d6e); the `authority_input_client` and `ui_onboarding_flow` slices exercise it.
- **DEFECT:** Input firing through IAS bindings and where an InputContext must be parented are unverified; whether a Sink context can take the client's system keys is unverified (they are refused instead).
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Rebinding is proven headlessly only.
- **FIX:** Run probe `inputmap_contexts`.
- **VERIFICATION:** ENGINE_DONE ok for `inputmap_contexts`.

### K14

**Cutscenes and camera (cinematics/1)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** `Cinematics` (T0): cinematics/1 validate, sample, `eventsBetween` (t0 < t <= t1, so events at t = 0 fire on the first frame), a hold-to-skip player, reduce, bake and digest; `Spline` (T0); `CinematicsRoblox` (T3, probe `cin_play_sample`) drives the Camera from PreRender and builds frames with `fromMatrix` (Lune 0.10.5's `CFrame.lookAt` mirrors Z).
- **EVIDENCE:** On the integrated branch `cinematics` 17 with golden cinematics-orbit.
- **DEFECT:** Real Camera playback, events, skip and restore are unverified.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Cutscene playback is proven against a fake camera only.
- **FIX:** Run probe `cin_play_sample`.
- **VERIFICATION:** ENGINE_DONE ok for `cin_play_sample`.

### K15

**VFX library (vfx/1) with pooling** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Inherited EffectsPool only (R01).
- **ACTUAL STATE:** `AVKit/Vfx` (T1): vfx/1 covering emitters, beams, trails, lights and Highlight, with palette and texture roles, burst or loop mode, a budget estimate, colour-vision palettes, reduced-motion, flash and performance modes. `VfxLibrary` (T0) has 21 neutral presets within conventions; `Pool` (moved from Creator/EffectsPool) gained expire and remaining; `VfxPoolRoblox` (T3, probe `av_vfx_grid`) pools clones, follows targets and lets loops linger.
- **EVIDENCE:** On the integrated branch `avkit_vfx` 10, `avkit_pool` 11 and `avkit_presets` 3 (golden av-presets); `av_vfx_grid` passes against fakes.
- **DEFECT:** Emit, PivotTo and rendering are not in Lune; the look and cost are unseen.
- **ROOT CAUSE:** Engine-only behaviour.
- **IMPACT:** Effects may look or cost differently in the engine.
- **FIX:** Run probe `av_vfx_grid`, capture the grid and profile on a device.
- **VERIFICATION:** ENGINE_DONE ok plus a capture.

### K16

**Audio graph, buses and cues (audio-graph/1)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Inherited AudioMixer and AudioDirector only (R01).
- **ACTUAL STATE:** `AVKit/AudioGraph` (T1): 7 standard buses (master, music, sfx, ui, ambience, dialogue, world) with AudioCompressor, AudioEqualizer and AudioReverb chains; validation rejects cycles, orphan buses and missing standard buses and caps voices (32 warning, 64 error); fader ducking with an optional sidechain mode. `AudioCues` (T0) ships 28 neutral cues with cooldown, max concurrency and stealing and reports `missing_asset` for unmapped slots; `Music` (T0) starts tracks on the beat or bar with equal-power crossfades; `AudioGraphRoblox` (T3, probes `av_audiograph_wires` and `av_audio_master_level`) schedules music with Play(atTime) and serves AudioDirector.
- **EVIDENCE:** On the integrated branch `avkit_audio` 18; both probes pass against fakes.
- **DEFECT:** Playback, Wire.Connected and analyzer levels are unavailable in Lune; whether `AudioPlayer.Asset` accepts built-in `rbxasset://sounds` and whether `DefaultListenerLocation` must be None are unverified.
- **ROOT CAUSE:** Engine-only behaviour.
- **IMPACT:** Audio routing is proven structurally only.
- **FIX:** Run both probes in Studio (with an approved content string if needed).
- **VERIFICATION:** ENGINE_DONE ok with a peak above 0.

### K17

**Game feel kit (springs, shake, hit-stop, popups, safe flashes, haptics, cues)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** Feel cores (T0) are deterministic: closed-form Spring (same result at any frame rate), Shake (hashed value noise; 0 under reduced motion), HitStop (one freeze at most 0.2 s, at most 0.35 s per second), Popups (aggregate, stack, K/M/B), Screen (at most 3 flashes per second; soft tints under reduce-flashing), Haptics (clamped patterns, rate limit) and Cues (a sound needs a visual channel; animation marker binding). `FeelRoblox` (T3, probe `feel_marker_cue`).
- **EVIDENCE:** On the integrated branch `feel` 19 in 2 files (cores 14, adapter 5); `feel_marker_cue` passes against fakes.
- **DEFECT:** Camera, AnimationTrack freeze and HapticService are unseen; motion needs a recording; the full HapticEffectType list is unverified. UIKit `Ease.spring` and `Feel/Spring` take the same parameters, and whether one should forward to the other is undecided.
- **ROOT CAUSE:** Engine-only behaviour; haptics need a device.
- **IMPACT:** Feel effects are proven numerically only.
- **FIX:** Run probe `feel_marker_cue`, record motion on the PC and test haptics on a device.
- **VERIFICATION:** ENGINE_DONE ok plus a recording.

### K18

**AI kit (navigation, perception, behaviour trees, waves, checkpoints)** · Runtime kits · PARTIAL · P2

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** T0 cores: NavAgent, Perception, BehaviorTree, WaveDirector and Checkpoints, with the seeded slices `course_checkpoints` and `wave_lane`. `NavAgentRoblox` (T3, probe `lvl_pathfinding_probe`; door handling in `lvl_navagent_door`) wraps PathfindingService.
- **EVIDENCE:** On the integrated branch: nav 7, perception 4, behaviour trees 7, waves 5 and checkpoints 8 cases, and `gamekit_slices_world` 4 with golden gamekit-world matching (course_checkpoints 6e8a5f13, wave_lane 8e0ce327); the level probes pass against FakePathfinding (`gamekit_world_probes` 6, not engine evidence).
- **DEFECT:** NavAgentRoblox is pending both probes.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Pathing on real geometry is unproven.
- **FIX:** Run `lvl_pathfinding_probe` and `lvl_navagent_door`.
- **VERIFICATION:** ENGINE_DONE ok for both probes.

### K19

**Placement grid, team balance and leaderboards** · Runtime kits · PARTIAL · P3

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** T0 cores: PlacementGrid, TeamBalance, Leaderboard and LiveBoard. `LeaderboardRoblox` (writes off unless enabled) and `LiveBoardRoblox` are T4 (OrderedDataStore and MemoryStore sorted maps), with FakeOrderedStore and FakeLiveSortedMap in the specs.
- **EVIDENCE:** On the integrated branch: placement 6, teams 4 and leaderboard 7 cases.
- **DEFECT:** The T4 adapters need live services and are never claimed here.
- **ROOT CAUSE:** Live stores need a published place.
- **IMPACT:** Leaderboard persistence is proven against fakes only.
- **FIX:** Only in a future game's private test place.
- **VERIFICATION:** Lune specs.

### K20

**Kit smoke harness (all probe registries in one Studio run)** · Runtime kits · PARTIAL · P1

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `Pipeline/KitSmoke` (T3, probe `kitsmoke_all`) merges every `fixtures/kits/<side>/*_probes.luau` registry and adds `kitsmoke_registries` (each registry loads, no duplicate or invalid names); runners arm on `SETUP_ONLY_KitFixture = kitsmoke`; `tests/engine/kitsmoke_all.luau` is the Studio command-line entry. `tools/lune/kit_smoke.luau` runs the harness's own registries (debug commands, inspector target, perf capture) against fakes and checks golden kit-smoke. `GameKit/DebugCommands` (T0) is active only in Studio on an unpublished place (GameId 0, PlaceId 0) and reports `status` for release check A17.
- **EVIDENCE:** On the integrated branch `lune run tools/lune/kit_smoke.luau`: 11 registries loaded, 0 problems, 0 failures, server 15/15 and client 7/7 checks, golden kit-smoke match; `pipeline_kitsmoke` 8 and `gamekit_debug` 9.
- **DEFECT:** Never run in Studio; in Lune each group runs its own registry in its spec, so only Studio runs them all together.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Engine behaviour of every probe is unproven.
- **FIX:** Owner runs `kitsmoke_all` on the PC.
- **VERIFICATION:** `reports/engine/kitsmoke_all.json` PASS.

### K21

**Cross-group integration slices (race, stalker AI, projectile arena, session persistence, UI onboarding, authority client)** · Runtime kits · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `tests/slices_integration.spec.luau` composes modules of at least three groups per slice through their public APIs, seeded, with fakes injected through env: race_loop_vehicle (Course, Zones, Vehicles, Checkpoints, Leaderboard, Telemetry), stalker_ai (Dungeon, NavAgentRoblox over FakePathfinding, Perception, BehaviorTree, Vitals, RoundLoop, AudioCues, Shake), projectile_arena (microArena, TeamBalance, RoundLoop, RemoteGuard, Projectile and Hitbox rewind, Vitals, Wallet, Progression, HitStop, Popups), session_persistence (PlayerData on two servers, the economy kits, SettingsStore, Onboarding, Commerce receipts, Telemetry), ui_onboarding_flow (Onboarding, Settings, Cinematics skip, InputMap, UIKit) and authority_input_client (the Studio client script loaded in Lune). Each asserts its invariants before its digest goes into golden slices-integration.
- **EVIDENCE:** On the integrated branch `lune run tests/run.luau slices_integration`: 22 passed, golden slices-integration stable over repeated runs; the full suite 1214 passed in 91 files. The slices found two real bugs, fixed in 39991f5: a refused store write counted as saved (Wallet, Inventory, Onboarding) and a live Wallet or Inventory overwriting receipt grants.
- **DEFECT:** Headless only: engine behaviour of the adapters in these slices is still the T3 probes' job (K20), and nothing here shows a slice is fun or performs on devices.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Composition bugs between kits are caught in the gate; engine bugs are not.
- **FIX:** 747db48 (slices), 39991f5 (fixes); add a slice when a new kit joins a loop.
- **VERIFICATION:** Lune spec with golden in the pre-commit gate.

### D01

**Fresh tooling research with select/reject decisions** · Research · VERIFIED_ACCEPTABLE · P3

- **PREVIOUS CLAIM:** Research corpus verified (295 chart records).
- **ACTUAL STATE:** `docs/research/tooling-2026-10.md` (Studio MCP, testing modes, Luau toolchain, Blender MCP rename, Blender built-ins, mesh import limits, Claude Code and Codex mechanics, procgen references, plus a back-fill of price, last update, maintenance and licence) and `docs/research/tooling-2026-10-addendum.md` (UI, animation, VFX, terrain, context and code index, visual QA and video, performance, security, CI/CD, extra MCP servers). Each candidate has source, publisher, version, last update, maintenance, licence, price, purpose, security, overlap, Claude/Codex access, benefit and SELECT/REJECT/REVISIT. On 2026-10-06 eight more dated research docs fed the runtime kits: agent tooling and connectors, Blender animation pipeline, gameplay libraries, genre coverage, pipeline audit, release/monetisation/analytics, UI/cinematics/feel and visual/audio assets, each with sources and SELECT/REJECT decisions.
- **EVIDENCE:** Dated sources fetched 2026-10-05 and 2026-10-06 (registries, official docs, release pages), listed in each file's Sources section. `docs/research/*-2026-10*.md`: 10 files, each with a Sources section.
- **DEFECT:** Some release years are unknown because GitHub feeds and APIs were blocked; facts were read through a summarising fetcher. Several selections are not implemented yet (Script Profiler capture, WriteVoxels terrain apply, pinning the Rokit installer script); the luau-lsp analysis is now built (T15).
- **ROOT CAUSE:** Source pages incomplete.
- **IMPACT:** Low.
- **FIX:** n/a
- **VERIFICATION:** Decisions applied: built-in Studio MCP, Rokit over Aftman, mcp-for-blender 2.1.8, bpy 5.2 LTS in CI, Open Cloud execution and asset uploads rejected for this factory.

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
- **ACTUAL STATE:** Rejected for this setup-only factory (research addendum section I; `tooling-2026-10.md` section 10, correction 1). It needs an API key and uploads a place version to run, and Luau Execution scripts can read and modify DataStores. The starter's optional `studio-tests` bundle pins Jest Lua and JestGlobals 3.10.0 (dev realm, MIT) for a game repo (T18); nothing runs it here.
- **EVIDENCE:** Research section 3 and section 10; Roblox Luau Execution docs fetched 2026-10-06.
- **DEFECT:** Engine-only modules have no automated in-engine test.
- **ROOT CAUSE:** Account access and the upload boundary.
- **IMPACT:** Studio-bound regressions caught only by manual runs.
- **FIX:** If the owner authorises a private test universe: Wally `jsdotlua/jest`, upload the test place version, run via the Luau Execution API with the key in CI secrets.
- **VERIFICATION:** CI job green.

### D04

**Research and knowledge database** · Research · PARTIAL · P2

- **PREVIOUS CLAIM:** Knowledge records verified on the workbench (inherited).
- **ACTUAL STATE:** `knowledge/records/` holds 25 records: 22 copied from the owner's workbench and 3 repo-scoped (including the two written for the kits). The 22 cite tools, tests and reports that exist only there (39 of 40 cited paths are absent from this repo), so they are now scoped `workbench` with `*_on_workbench` statuses and a note; `knowledge/INDEX.md` lists the records and research docs. The gate's `knowledge-paths` step fails a record that cites a missing path without that scope, and `knowledge-index` fails a stale index.
- **EVIDENCE:** Gate steps `knowledge-index` and `knowledge-paths`; a planted record claiming 'verified' failed.
- **DEFECT:** Most records are claims this repo cannot reproduce.
- **ROOT CAUSE:** Records were copied without their tools.
- **IMPACT:** Agents reading the records must treat them as the workbench's claims.
- **FIX:** Port or re-verify a record's tool here, then switch its scope to `repo`.
- **VERIFICATION:** Gate steps in pre-commit.

### X01

**Publishing, asset upload, purchases, live products, ads** · Boundary · INTENTIONALLY_EXCLUDED · P0

- **PREVIOUS CLAIM:** Intentionally excluded.
- **ACTUAL STATE:** Excluded and enforced: hooks deny publish/upload commands, package-registry publishing, Open Cloud and DataStore/Messaging writes, publishing or asset-creating Luau, completed purchases and subscription, Premium, Robux-transfer and bulk purchase prompts, and ask before asset-creating Studio tools, other purchase prompts and DataStore/MemoryStore writes. The one exception, approved by the owner on 2026-10-05: Import 3D of the neutral round-trip marker into the unpublished diagnostic place, which uploaded two private mesh assets (ids kept out of the repo). Under Codex the same guards deny what Claude would ask (T13).
- **EVIDENCE:** Hook self-test (404 cases on the integrated branch, also run through the Codex hook commands) including every Prompt*Purchase, CreateAssetVersionAsync and CreatePlaceInPlayerInventoryAsync; `reports/studio/roundtrip-2026-10-05.json`.
- **DEFECT:** n/a
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Self-test in the gate and CI.

### X02

**Commercial game content (genre, theme, world, characters, economy, UI)** · Boundary · INTENTIONALLY_EXCLUDED · P0

- **PREVIOUS CLAIM:** Intentionally excluded.
- **ACTUAL STATE:** Excluded. Fixtures are named SETUP_ONLY_* and use neutral greybox, stone and timber styles; Cryptic's Realm and other games were not touched. `fixtures/briefs/` holds two inherited planning-validation inputs with hypothetical genre and aesthetic fields for a workbench tool that is not in this repo; `fixtures/README.md` labels them as such, and they are not game decisions. The project starter leaves every game-design field TBD.
- **EVIDENCE:** Fixture names and style profiles; `fixtures/README.md`; `templates/starter/AGENTS.md.tmpl`; read-only audit only on the PC.
- **DEFECT:** n/a
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Review.

### Q01

**Performance lab (budgets and profiling)** · Production lab · PARTIAL · P2

- **PREVIOUS CLAIM:** Performance pass skill.
- **ACTUAL STATE:** Static budgets run on every build: ProcGen's `performance_part_estimate` validator on each fixture and Blender QA's triangle and material budgets. `SceneKit/Budgets` (perf/1) sets limits for phone_low, phone, tablet, desktop and console (frame ms, instances, memory, parts, triangles, shadowed lights, particle rate, sounds, highlights, texture estimate, post effects), with documented limits marked apart from conventions; `check(stats, class)` reports a missing counter as missing, never 0. `Diagnostics/PerfProbe` (T0) aggregates perf/1 stats (frame_ms p50/p95/p99, memory per category, counts, device class, source) with validate and compare; `PerfProbeRoblox` (T3) reads Stats memory per DeveloperMemoryTag, InstanceCount, a bounded Workspace walk, client SceneTriangleCount and Heartbeat times through probes `perf_capture` (server, Edit mode) and `perf_capture_client` (play session). `roblox-performance-pass` documents the before/after procedure.
- **EVIDENCE:** On the integrated branch: `scenekit_budgets` 6, `diagnostics_perf` 9 and the kit smoke (server 15/15, client 7/7 against FakePerfEngine); `build/fixtures/report.json` (performance_part_estimate per fixture) and Blender QA reports from the pre-release gate.
- **DEFECT:** No Studio or device capture yet; Stats member names are unverified; device classes and convention limits are uncalibrated.
- **ROOT CAUSE:** Profiling needs Studio or a device.
- **IMPACT:** Budgets are estimates; frame time and memory on real devices are unknown.
- **FIX:** Run `perf_capture` and `perf_capture_client` on the PC; calibrate the perf/1 conventions with captures from a 2 to 4 GB Android phone in a future game's private test place.
- **VERIFICATION:** `reports/engine/perf_capture.json` PASS from Studio; `Budgets.check` on device stats.

### Q02

**Release readiness checks** · Production lab · VERIFIED_ACCEPTABLE · P3

- **PREVIOUS CLAIM:** Release pass skill.
- **ACTUAL STATE:** The starter ships `tools/release_check.py` (release-check/1) for game repos: A01 to A17 are automated static checks (hygiene and engine settings, RemoteGuard use, catalog/1 with owner-verified ids, one receipt handler, paid-random odds, text filtering, motion and flash settings, telemetry and onboarding funnel, perf/1 budgets, asset provenance, localisation keys, debug off, deprecated APIs, hard-coded prices, the persistence boundary, a publish tripwire, release metadata and store-art specs); S01 to S07, O01 to O15 and P01 to P03 always report OWNER_REQUIRED, and an owner record shows as `owner_record`, never PASS. A16 becomes WAIVED_BY_OWNER only when an owner exception covers every hit. `docs/release-runbook.md` is generated from the checklist, and the game gate's pre-release tier runs it.
- **EVIDENCE:** On the integrated branch `tests/test_release_check.py` (14) passes: the good fixture passes A01 to A17 with the S, O and P items OWNER_REQUIRED, each of the 17 bad fixtures fails exactly its item, owner records never produce PASS and the runbook is current. G8: a fresh scaffold's pre-release tier fails only A08, A09 and A17 (onboarding funnel, perf captures, release metadata and art) with 25 OWNER_REQUIRED, as intended.
- **DEFECT:** The checks are static source and data heuristics and have never run against a real game; owner items are manual by design.
- **ROOT CAUSE:** Release checks need a game, which this setup-only repo must not create.
- **IMPACT:** The first game's release pass may surface missing checks.
- **FIX:** Exercise it on the first game repo and add cases as real defects appear.
- **VERIFICATION:** `tests/test_release_check.py` in the `python-unit` gate step; the game gate's `--tier pre-release`.

### Q03

**Game security validation (server authority, remote validation, abuse tests)** · Production lab · PARTIAL · P2

- **PREVIOUS CLAIM:** Multiplayer integrity skill and network diagnostics.
- **ACTUAL STATE:** Remote validation: `GameKit/RemoteGuard` with `Schema` and `RateLimit` (token bucket per player and key) rejects with closed reasons, checks the rate before the schema, always rejects NaN, inf and invalid UTF-8, checks arity and length, dedupes request ids and has an authorize hook; `RemoteGuardRoblox.bind` refuses an unguarded remote (T3, probe `platform_remoteguard_flood`). Server-authority abuse tests in the action kit refuse impossible hit distances, forged origins, claims older than the 200 ms rewind or from the future, rapid fire, replayed shots, off-target hit points, teleport and fly, gate shortcuts and wrong way, cast-cancel cooldown abuse, forged touches, NaN input, input floods and reordering; the round_arena slice runs an exploiter bot against them. The inherited network suite (bounded queues, loss, duplication, reordering, deterministic fault replay) still runs. `roblox-multiplayer-integrity` points at these modules.
- **EVIDENCE:** On the integrated branch: `gamekit_platform_remotes` 27 (a 1000-call flood, NaN and inf, arity, invalid UTF-8, dedupe, unguarded-remote refusal); `gamekit_action` 131 and `gamekit_slices_action` 4; `tests/diagnostics/network.luau` 11 (gate step `inherited-diagnostics-network`); exploit table in `docs/gamekit-action.md` section 16.
- **DEFECT:** No multi-client Studio abuse run: the flood probe and the authority fixture (K07) have not run in Server & Clients.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Replication-level exploits are covered by headless tests only.
- **FIX:** Run `platform_remoteguard_flood` in Server & Clients (expected: no accepted calls, 10 schema rejects, then rate rejects) and the authority fixture with 2 clients.
- **VERIFICATION:** Lune refusal cases in the gate; multi-client Studio pending.

### Q04

**Visual regression** · Production lab · PARTIAL · P2

- **PREVIOUS CLAIM:** Visual QA skill.
- **ACTUAL STATE:** Structural regression is enforced: fixture manifest hashes, the Studio smoke hashes and the kit spec goldens fail the gate on any unintended change. `Pipeline/CaptureSet` makes named capture plans (capture-manifest/1, shots `<scene>.<profile>.<angle>`) that record the scene hash, and `tools/capture_staleness.py` flags any capture or Studio smoke record whose scene hash changed (CURRENT, STALE, INCOMPLETE, INVALID). Image regression is not built: previews are reviewed by eye and there is no baseline image or pixel diff.
- **EVIDENCE:** On the integrated branch: `pipeline_captureset` 5 and `tests/test_capture_staleness.py` 8 pass; `capture_staleness.py` reports the dungeon entry of `reports/studio/smoke-2026-10-05.json` STALE (8494d161 vs 927f2db4) and the building entry CURRENT; gate step `fixture-hashes`.
- **DEFECT:** No image baselines; one stale Studio smoke record; no gallery or lookdev captures yet.
- **ROOT CAUSE:** Renders differ across Blender versions, so pixel baselines need per-version images and tolerances; Studio captures need the PC.
- **IMPACT:** A material or lighting change that keeps geometry identical passes unnoticed; the dungeon smoke evidence is out of date.
- **FIX:** Rerun the Studio smoke (S02) and record captures through CaptureSet; per-Blender-version low-resolution preview baselines with a perceptual tolerance remain future work.
- **VERIFICATION:** Hash goldens in the gate; `capture-staleness` gate step (non-fatal); image diff not built.

### Q05

**Visual-reference library** · Production lab · MISSING · P3

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** Missing. There is no store of reference images, captures or tags in the repo.
- **EVIDENCE:** No reference folder or index in `git ls-files`.
- **DEFECT:** Missing.
- **ROOT CAUSE:** Not built in either pass.
- **IMPACT:** Style decisions in a future game have no shared reference set.
- **FIX:** A small index of own captures and licensed links with tags and licence fields, kept outside commercial content.
- **VERIFICATION:** None.

### Q06

**Asset sourcing and approval (intake, provenance)** · Production lab · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Asset intake skill.
- **ACTUAL STATE:** `assets/provenance.json` is the registry (source, licence, approval, date, purpose), and the `asset-provenance` gate step scans every committable file for Roblox asset ids (rbxassetid, rbxthumb, asset, library, catalog and store URLs, `?id=`, and AssetId/MeshId/TextureId/SoundId/AnimationId/ImageId/DecalId fields). An unregistered id fails, 0 is the only placeholder, and only approved ids may appear in place content. The registry holds one id, a research citation inherited from the workbench. `roblox-asset-intake` describes the approval procedure. External CC0 files have their own pinned route (Q11): `assets/sources.json` and a `files` list with `source_key` in `assets/provenance.json`.
- **EVIDENCE:** Gate step `asset-provenance` (every committable file scanned and 1 registered id on the integrated head; 224 files when it landed); a planted unregistered id failed with its file and line.
- **DEFECT:** No asset has been through the intake approval path, so approved entries are unexercised.
- **ROOT CAUSE:** Setup-only: no assets are sourced.
- **IMPACT:** The approval half is untested until the first real intake.
- **FIX:** Run the first real intake through `roblox-asset-intake` in a game repo.
- **VERIFICATION:** Gate step with a negative self-test.

### Q07

**Gameplay-system library** · Production lab · PARTIAL · P3

- **PREVIOUS CLAIM:** Genre system checklists and inherited runtime modules.
- **ACTUAL STATE:** Reusable gameplay logic now lives in the runtime kits (K01 to K20): GameKit (platform services, action, economy and progression, levels and AI, input map, world cycle, debug commands), UIKit, Cinematics, AVKit and Feel, built as pure cores plus `*Roblox` adapters. `tools/kit_tiers.py` counts 161 modules (157 kit): 88 T0 and 38 T1 proven in Lune, 27 T3 adapters awaiting Studio probes and 8 T4 adapters (live services) never claimed. 29 genre playbooks map genres to these modules (Q09); the inherited pure-Luau modules remain (R01). Nothing picks a genre, content or prices (X02).
- **EVIDENCE:** On the integrated branch `lune run tests/run.luau`: 1214 passed, 0 failed (91 files); `kits_load` 168; `kit_tiers.py --print`: 31 header-named probes, all PENDING.
- **DEFECT:** No T3 adapter has run in Studio (0 of 27 with a passing probe). PolicyGate as the paid-random predicate and the odds disclosure in UI are proven by interface only; PlayerData as the economy store, Telemetry as the sink and InputMap in the authority fixture are exercised headlessly by the K21 slices.
- **ROOT CAUSE:** Studio runs only on the PC; no game exists to wire the kits together (setup-only).
- **IMPACT:** The cores are tested building blocks; engine behaviour and integration need the owner's probe runs and a first game.
- **FIX:** Owner runs `kitsmoke_all` and the group probes (T14, K20); wire the kits in the first game repo.
- **VERIFICATION:** Full Lune suite in the gate; kit-tiers report; Studio pending.

### Q08

**Analytics (telemetry and offline report)** · Production lab · PARTIAL · P3

- **PREVIOUS CLAIM:** Analytics foundation partially verified (workbench).
- **ACTUAL STATE:** `GameKit/Telemetry` (T0) maps kit-event/1 events with batching and redaction; `TelemetryRoblox` (T3, probe `platform_telemetry_recorder`) forwards them, and live AnalyticsService delivery is T4. `tools/analytics_report.py` builds an offline report from kit-event/1 JSONL (and the legacy neutral session rows) with date windows and synthetic-event exclusion; `fixtures/analytics/kit_events.jsonl` and `expected_kit_report.json` are its fixtures.
- **EVIDENCE:** On the integrated branch `tests/test_analytics_report.py` 15 OK and `gamekit_platform_telemetry` 20 (golden `gamekit_platform_telemetry_calls`).
- **DEFECT:** Probe `platform_telemetry_recorder` has not run; live AnalyticsService delivery is T4 (owner, in a published game); the workbench record `analytics-offline-session-foundation` still describes the workbench tool, while the repo record `kit-event-offline-report` describes `tools/analytics_report.py`.
- **ROOT CAUSE:** Live delivery needs a published place; the record predates the port.
- **IMPACT:** Event mapping and reports are proven offline only.
- **FIX:** Run the recorder probe; retire or re-scope the workbench analytics record; check live delivery in a future game's test place.
- **VERIFICATION:** Python and Lune tests in the gate; Studio pending.

### Q09

**Genre playbooks and taxonomy (29 playbooks, 17 genres, 43 subgenres)** · Production lab · VERIFIED_ACCEPTABLE · P3

- **PREVIOUS CLAIM:** 11 genre checklists in `roblox-genre-systems`.
- **ACTUAL STATE:** `.agents/skills/roblox-genre-systems/references/taxonomy.json` (genre-taxonomy/1) maps all 17 genres and 43 subgenres of the research table to a primary playbook (plus optional also-playbooks) or a reasoned exclusion (only Utility & Other), with aliases and 4 cross-cutting playbooks. 29 playbooks share 9 sections and cite kit modules; none picks a genre, content or prices. `tools/playbook_lint.py` checks the map against the research doc, the format, that Covers/Also lines match the map, that cited modules exist in the ownership list or on disk, and neutral wording.
- **EVIDENCE:** On the integrated branch `python3 tools/playbook_lint.py`: PASS, 29 playbooks, 17 genres, 43 subgenres, 622 module citations, now resolved against the merged kits (notes only for authoring modules found on disk); `tests/test_playbook_lint.py` 28 OK, including a failure case per rule.
- **DEFECT:** Playbooks are references, not playtested; six cross-group slices exist (K21), but not one per genre, and no taxonomy-to-slice link. Earlier plans said 39 subgenres; the cited table has 43 and the lint follows it.
- **ROOT CAUSE:** Gameplay quality needs a game and players.
- **IMPACT:** Guidance may need revision once a game uses it.
- **FIX:** Gate step `playbook-lint` (pre-commit, added in c70ff63).
- **VERIFICATION:** Lint and unit tests.

### Q10

**Neutral production pipeline (brief, stages, issue drafts)** · Production lab · VERIFIED_ACCEPTABLE · P3

- **PREVIOUS CLAIM:** Not claimed.
- **ACTUAL STATE:** A starter/2 game repo gets `production/brief.json` (game-brief/1, all TBD), `production/pipeline.json` (six stages, concept to release-candidate, each with brief, file, gate, release, playtest and owner exit gates), design prompts, issue forms, `tools/production.py status` and `tools/plan_issues.py` (local drafts, no API calls). The game gate's `brief` step checks brief/AGENTS.md parity and the owner gates of passed stages. Skill `roblox-production-pipeline`.
- **EVIDENCE:** On the integrated branch `tests/test_new_project.py` (game-repo gate step cases) passes; G8's `starter_smoke.py` runs `production.py status` and `plan_issues.py` in a scaffold.
- **DEFECT:** Not used by a real team yet.
- **ROOT CAUSE:** Setup-only: no game exists.
- **IMPACT:** The stage gates may need tuning in use.
- **FIX:** Use it on the first game-build request.
- **VERIFICATION:** Unit tests and starter smoke.

### Q11

**CC0 asset fetch with provenance** · Production lab · PARTIAL · P2

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `assets/sources.json` (asset-sources/1) lists 4 CC0-only sources (ambientCG, Poly Haven via dl.polyhaven.org, and Kenney and Quaternius as manual sources) with host, anchored item pattern, allowed types and size cap, and a commit-pinned CC0 legal-code text sha256. `tools/fetch_assets.py` is a dry run unless `--pin` is given; with `--pin` it verifies the licence text, follows redirects only to allow-listed https hosts, checks type by content and size, extracts zips safely, keeps the cache in `build/asset-cache` (never in git) and appends a `files` entry with source_key, sha256, bytes and licence evidence to `assets/provenance.json`. `tools/asset_sources.py --check` validates both files.
- **EVIDENCE:** On the integrated branch `tests/test_fetch_assets.py` (15, file:// fixtures, no network) passes and `asset_sources.py --check` reports 4 sources, 0 pinned files, 0 problems. G9b fetched the CC0 legal-code text live and its sha256 matched.
- **DEFECT:** No real item has been fetched: the ambientCG redirect host, the Poly Haven path layout and the Kenney and Quaternius URLs are unverified.
- **ROOT CAUSE:** The proxy blocks the source hosts in the cloud container.
- **IMPACT:** The first real fetch may need a source-entry fix.
- **FIX:** First owner-approved `--pin` on the PC or in a game repo.
- **VERIFICATION:** One real item pinned with a matching sha256.
