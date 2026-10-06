# Second-pass gap matrix

Generated from `reports/gap-matrix.json` by `python3 tools/gap_matrix.py`; edit the JSON, not this file. As of 2026-10-06.

Second-pass audit of the Roblox production factory (this repo plus a read-only audit of Ethan's local workbench). Machine-specific security details are kept in the project's private notes, not in this public repo. SETUP_ONLY: no game content, publishing, uploads or spending.

**Rule:** VERIFIED_* requires a representative execution observed in this pass or in CI. Files, configs, listed MCP servers and screenshots alone do not count.

| Status | Count |
|---|---|
| VERIFIED_STRONG | 11 |
| VERIFIED_ACCEPTABLE | 14 |
| WEAK | 4 |
| PARTIAL | 12 |
| BROKEN | 1 |
| MISSING | 6 |
| OUTDATED | 1 |
| REDUNDANT | 1 |
| BLOCKED_EXTERNAL | 6 |
| INTENTIONALLY_EXCLUDED | 3 |

## Summary

| ID | Area | Capability | Status | Priority | Verification |
|---|---|---|---|---|---|
| [T01](#t01) | Agent tooling | Skills discoverable by Claude Code | VERIFIED_STRONG | P0 | Fresh Claude session init lists the repo skills; a plain task prompt made Claude load the matching skill unprompted; skills-sync gate step fails on a removed heading or renamed skill (checked in a scratch copy). |
| [T02](#t02) | Agent tooling | Skills discoverable by Codex | VERIFIED_ACCEPTABLE | P2 | Codex's own prompt rendering lists 20 of 20 repo skills. |
| [T03](#t03) | Agent tooling | Small permanent instructions shared by Claude and Codex | VERIFIED_STRONG | P2 | Fresh-session recall of imported content. |
| [T04](#t04) | Agent tooling | Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards | VERIFIED_ACCEPTABLE | P1 | Self-test in the pre-commit gate and CI; live denials observed; `guard_mcp` on a real Studio event pending (owner step). |
| [T05](#t05) | Agent tooling | Permission rules apply on a fresh checkout | BLOCKED_EXTERNAL | P3 | Warnings observed; deny protection still covered by `Edit(weppy-project-sync/**)`. |
| [T06](#t06) | Agent tooling | Specialist subagents with explicit ownership | VERIFIED_STRONG | P3 | Real parallel task completed and merged. |
| [T07](#t07) | Agent tooling | Repo gate (fast / pre-commit / pre-release) | VERIFIED_STRONG | P1 | Executed in the cloud container and in GitHub Actions (both tiers, strict). |
| [T08](#t08) | Agent tooling | Continuous integration | VERIFIED_STRONG | P1 | Green strict CI on the PR head. |
| [T09](#t09) | Agent tooling | Pinned Luau toolchain | WEAK | P2 | `rojo --version` prints 7.7.0 from a new terminal. |
| [T10](#t10) | Agent tooling | Selene lint with the Roblox standard library | VERIFIED_ACCEPTABLE | P2 | Selene step green in CI. |
| [T11](#t11) | Agent tooling | Rojo projects build from a clean clone | VERIFIED_STRONG | P2 | Rojo builds of all four projects in the container and CI. |
| [T12](#t12) | Agent tooling | Reusable project starter | VERIFIED_ACCEPTABLE | P1 | `starter-smoke` in the pre-commit gate and CI. |
| [T13](#t13) | Agent tooling | Publish/spend guards and MCP settings for Codex | PARTIAL | P1 | Hook, rule and config parity in the pre-commit self-test; live Codex behaviour pending. |
| [L01](#l01) | Local workbench (PC) | Local workbench gate | BROKEN | P1 | `./.venv/Scripts/python.exe tools/check.py` passes on a quiet tree. |
| [L02](#l02) | Local workbench (PC) | Version control and rollback for the workbench | MISSING | P1 | `git log` shows a commit. |
| [M01](#m01) | MCP and Studio | Built-in Roblox Studio MCP connection | VERIFIED_ACCEPTABLE | P1 | Live tool calls returned the expected results in Studio for the three recorded tools. |
| [M02](#m02) | MCP and Studio | Claude user-level Blender MCP | OUTDATED | P1 | `get_scene_info` answers from Claude in the repo. |
| [M03](#m03) | MCP and Studio | Blender MCP inside Codex | BLOCKED_EXTERNAL | P2 | Config parity in the self-test; live Codex connection pending. |
| [M04](#m04) | MCP and Studio | Blender MCP add-on telemetry off | WEAK | P1 | Preference unchecked and saved. |
| [M05](#m05) | MCP and Studio | WEPPY bridge | REDUNDANT | P2 | Setting off, or a documented unique function. |
| [M06](#m06) | MCP and Studio | Codex global configuration | WEAK | P1 | Owner review. |
| [M07](#m07) | MCP and Studio | MCP audit per server (why, client, tools, permissions, ports, network, auth, telemetry, overlap, failure modes, health check) | VERIFIED_ACCEPTABLE | P2 | Table cross-checked against the installed package, the guards and the self-test. |
| [S01](#s01) | MCP and Studio | Studio testing modes (Test, Test Here, Run, Server & Clients) and device emulation | BLOCKED_EXTERNAL | P1 | Console output and captures saved under `reports/studio/`. |
| [S06](#s06) | MCP and Studio | Studio MCP operations beyond the core loop (property inspection, script read/edit, asset search/insert, console, camera, keyboard/mouse/character input) | BLOCKED_EXTERNAL | P1 | Pending: observed output of each tool on the PC. |
| [S02](#s02) | Scene authoring | SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune) | PARTIAL | P0 | Observed in Studio at 9c12091 only; HEAD pending the owner steps. |
| [S03](#s03) | Scene authoring | Scene-authoring API as data (buildings, props, lights and signs, interior dressing, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance) | VERIFIED_STRONG | P0 | Specs, fixture hashes, previews. |
| [S04](#s04) | Scene authoring | Measurement and player-scale helpers | VERIFIED_ACCEPTABLE | P2 | Specs. |
| [S05](#s05) | Scene authoring | Terrain and lighting applied in Studio | PARTIAL | P2 | Screen captures per lighting profile. |
| [S07](#s07) | Scene authoring | Model operations and selection scope (model.inspect, scale, pivot, material, collision, optimize) | PARTIAL | P2 | Specs in the gate; Studio pending. |
| [S08](#s08) | Scene authoring | Level dressing: lights, signs and interior props | PARTIAL | P2 | Specs in the gate; Studio pending. |
| [P01](#p01) | Procedural generation | Seeded generators (dungeon, cave, arena, settlement, forest) | VERIFIED_STRONG | P0 | Specs and fixture hashes in the gate and CI. |
| [P02](#p02) | Procedural generation | Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance) | VERIFIED_ACCEPTABLE | P2 | Specs and fixture reports. |
| [P03](#p03) | Procedural generation | Determinism and manifests | VERIFIED_STRONG | P1 | Gate. |
| [P04](#p04) | Procedural generation | Forests and biome dressing | VERIFIED_ACCEPTABLE | P2 | Specs, seed sweeps and fixture hashes in the gate. |
| [B01](#b01) | Blender | Blender asset templates and QA reports (13 kinds) | VERIFIED_STRONG | P0 | Template and QA runs on three bpy versions; CI matrix; self-test proves known-bad assets fail. |
| [B02](#b02) | Blender | Blender built-ins in the factory (Geometry Nodes, Asset Browser catalogs, texture baking, Rigify) | MISSING | P2 | n/a |
| [B03](#b03) | Blender | Preview renders for visual QA | VERIFIED_ACCEPTABLE | P2 | Renders reviewed in this pass. |
| [B04](#b04) | Blender | Round trip, Blender half (create, revise, export, reimport, diff, expectation) | VERIFIED_STRONG | P0 | Runs in the pre-release gate and CI. |
| [B05](#b05) | Blender | Round trip, Studio half (3D Importer, then ImportInspector against the expectation) | PARTIAL | P0 | ImportInspector in Studio at 9c024fb: 6 of 7 checks passed for v1 and v2 and the revision was detected; the hardened inspector is verified in Lune only. |
| [B06](#b06) | Blender | Material colour survives the Studio import | MISSING | P1 | A Studio import shows the baked colours, and the inspector's appearance_bound reports a texture. |
| [B07](#b07) | Blender | Rigged and animated asset into Studio (skinned mesh, bone names, animation clip) | BLOCKED_EXTERNAL | P1 | Pending: inspector output in Studio saved under `reports/studio/`. |
| [B08](#b08) | Blender | Retopology, LOD chains and smooth skin weighting (bkit) | VERIFIED_ACCEPTABLE | P2 | Self-test on three bpy versions in the pre-release gate and CI. |
| [B09](#b09) | Blender | Brush sculpting in scripts | INTENTIONALLY_EXCLUDED | P3 | Self-test case for the stand-in. |
| [R01](#r01) | Inherited modules | Inherited pure-Luau modules (ReceiptLedger, CommerceCatalog, Lifetime, Motion, AudioMixer, AudioDirector, EffectsPool, MovementProfile, AnimationInspector and WorldInspector maths, UI logic, FaultQueue) | VERIFIED_ACCEPTABLE | P2 | Inherited suites and new specs pass in the gate. |
| [R02](#r02) | Inherited modules | Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector) | WEAK | P2 | Fresh receipts with today's Studio version. |
| [D01](#d01) | Research | Fresh tooling research with select/reject decisions | VERIFIED_ACCEPTABLE | P3 | Decisions applied: built-in Studio MCP, Rokit over Aftman, mcp-for-blender 2.1.8, bpy 5.2 LTS in CI, Open Cloud execution and asset uploads rejected for this factory. |
| [D02](#d02) | Research | Deep observational game dossiers | PARTIAL | P3 | n/a |
| [D03](#d03) | Research | In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution) | BLOCKED_EXTERNAL | P2 | CI job green. |
| [D04](#d04) | Research | Research and knowledge database | PARTIAL | P2 | Gate steps in pre-commit. |
| [X01](#x01) | Boundary | Publishing, asset upload, purchases, live products, ads | INTENTIONALLY_EXCLUDED | P0 | Self-test in the gate and CI. |
| [X02](#x02) | Boundary | Commercial game content (genre, theme, world, characters, economy, UI) | INTENTIONALLY_EXCLUDED | P0 | Review. |
| [Q01](#q01) | Production lab | Performance lab (budgets and profiling) | PARTIAL | P2 | Static budget checks run in the gate; runtime profiling not built. |
| [Q02](#q02) | Production lab | Release readiness checks | MISSING | P3 | None. |
| [Q03](#q03) | Production lab | Game security validation (server authority, remote validation, abuse tests) | PARTIAL | P2 | Network fault suite passes in the gate; security validation not built. |
| [Q04](#q04) | Production lab | Visual regression | PARTIAL | P2 | Hash goldens verified in the gate; image diff not built. |
| [Q05](#q05) | Production lab | Visual-reference library | MISSING | P3 | None. |
| [Q06](#q06) | Production lab | Asset sourcing and approval (intake, provenance) | VERIFIED_ACCEPTABLE | P2 | Gate step with a negative self-test. |
| [Q07](#q07) | Production lab | Gameplay-system library | PARTIAL | P3 | R01 suites pass in the gate. |
| [Q08](#q08) | Production lab | Analytics | MISSING | P3 | None. |

## Steps that need the owner's machine or decision

**T02 Skills discoverable by Codex** (VERIFIED_ACCEPTABLE)

1. Optional: run `codex` in the repo on the PC, open `/skills` (expect the 20 names in `.agents/skills/`) and ask for a seeded cave layout to see it load `roblox-procedural-generation`.

**T04 Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards** (VERIFIED_ACCEPTABLE)

1. On the PC, in Claude Code in this repo: ask for an `execute_luau` that calls `DataStoreService:GetDataStore("probe"):SetAsync("k", 1)` on the diagnostic place and confirm Claude asks first (decline it).
2. Optional `.claude/settings.json` edits an agent may not make: add `mcp__Roblox_Studio__http_get` to `ask` (the guard already asks), raise the PreToolUse hook timeouts to 10 s to match Codex, and add `Bash(asphalt upload:*)` to `deny`.

**T05 Permission rules apply on a fresh checkout** (BLOCKED_EXTERNAL)

1. Open Claude Code in the repo once and accept the trust prompt and the project MCP servers.
2. Optional: delete the `Write(weppy-project-sync/**)` line from `.claude/settings.json`.

**T09 Pinned Luau toolchain** (WEAK)

1. Windows Settings > Environment Variables > Path: move `%USERPROFILE%\.rokit\bin` above `%USERPROFILE%\.aftman\bin` (or remove the Aftman entry).
2. Open a new terminal and run `rojo --version`; expect 7.7.0.

**T13 Publish/spend guards and MCP settings for Codex** (PARTIAL)

1. Open Codex in this repo on the PC, trust the project, run `/hooks` and trust both hooks.
2. Check: `codex execpolicy check --rules .codex/rules/factory.rules -- rojo upload x` prints `forbidden`, and asking Codex to run `rojo upload` is refused.

**L01 Local workbench gate** (BROKEN)

1. When the Codex run finishes, run `./.venv/Scripts/python.exe tools/check.py` in the workbench folder.

**L02 Version control and rollback for the workbench** (MISSING)

1. With Codex idle: `git add -A` then `git commit -m "workbench snapshot"` in the workbench folder (check `.gitignore` excludes `.venv`, `backups/` and large media first).

**M02 Claude user-level Blender MCP** (OUTDATED)

1. `claude mcp remove blender -s user`
2. Start Blender 5.1.2 with the 2.1.8 add-on connected, open Claude Code in the repo, approve the `blender` project server, and ask for `get_scene_info`.

**M03 Blender MCP inside Codex** (BLOCKED_EXTERNAL)

1. Open Codex in this repo on the PC and trust the project, then `codex mcp list` (expect `Roblox_Studio` and `blender`).
2. With Blender 5.1.2 open and the 2.1.8 add-on connected, ask Codex for `get_scene_info`.

**M04 Blender MCP add-on telemetry off** (WEAK)

1. Blender > Edit > Preferences > Add-ons > Blender MCP: untick telemetry, then Save Preferences.

**M06 Codex global configuration** (WEAK)

1. Review the Codex section of the private local-audit note and tighten `~/.codex/config.toml` (approval on request, workspace-write sandbox, only needed browser origins).

**S01 Studio testing modes (Test, Test Here, Run, Server & Clients) and device emulation** (BLOCKED_EXTERNAL)

1. Covered by S02 (Run mode). For multi-client: run `python3 tools/network_manifest.py`, `rojo build fixtures/network.project.json -o build/network.rbxl`, open that place in Studio (it stays unpublished), Test > Clients and Servers > 2 players > Start, then `get_console_output`.
2. Device emulation: Test > Device (phone, then tablet) on the diagnostic place, `screen_capture` each, and record the result under `reports/studio/`.

**S06 Studio MCP operations beyond the core loop (property inspection, script read/edit, asset search/insert, console, camera, keyboard/mouse/character input)** (BLOCKED_EXTERNAL)

1. In Claude Code on the PC with SETUP_ONLY_Factory_Diagnostic open: `inspect_instance` on the SETUP_ONLY_ModularBuilding model; `script_read` then `multi_edit` on a scratch Script that Rojo does not manage; `search_asset` with a neutral query (no insert unless you approve it).
2. `start_stop_play` (Test), then `user_keyboard_input` (hold W for a second), `user_mouse_input`, `character_navigation` to a point, `get_console_output` and `screen_capture`; set the camera through `execute_luau` and capture again.
3. Save the outputs as `reports/studio/operations-<date>.json`.

**S02 SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** (PARTIAL)

1. Pull the PR branch, `rojo build fixtures/factory.project.json -o SETUP_ONLY_Factory_Diagnostic.rbxl` with Rokit's rojo, open it in Studio (unpublished).
2. `execute_luau`: `return game:GetService("HttpService"):JSONEncode(require(game.ReplicatedStorage.Workbench.Pipeline.FactorySmoke).run(workspace))`; compare with `tests/golden/studio-smoke.json`, then undo twice.
3. Set `ServerScriptService.FactorySmoke.Enabled = true`, `start_stop_play` in Run mode, approve the console read, check `FACTORY_SMOKE` in `get_console_output`, stop play and set Enabled back to false.

**B05 Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** (PARTIAL)

1. Pull this branch on the PC and run `python3 tools/blender/factory.py roundtrip build/roundtrip` (or `blender -b --python tools/blender/factory.py -- roundtrip build/roundtrip`). It writes the fixed marker and its expectations.
2. In SETUP_ONLY_Factory_Diagnostic, Import 3D `build/roundtrip/SM_RoundTripMarker_v2.fbx` (Scale Unit Stud, Insert In Workspace and Insert Using Scene Position on). This is one more private mesh upload.
3. `execute_luau`: `ImportInspector.inspect` on the new model with `build/roundtrip/roblox_expectation_v2.json`; pivot_base_centre should pass.

**B07 Rigged and animated asset into Studio (skinned mesh, bone names, animation clip)** (BLOCKED_EXTERNAL)

1. Approve one more private upload, then Import 3D the humanoid template FBX from `build/blender/` (rig and animation on) into the diagnostic place.
2. In Studio, check that the Bone instances carry the template's names, that the mesh deforms when a bone is rotated, and that the imported clip length matches the template; save the result under `reports/studio/`.

**D03 In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution)** (BLOCKED_EXTERNAL)

1. Only in a future game repository, and only if Ethan authorises a private test universe: Wally `jsdotlua/jest`, upload the test place version, run via the Luau Execution API with the key in CI secrets. Its scripts can read and modify DataStores, so use a universe with no production data.


## Rows

### T01

**Skills discoverable by Claude Code** · Agent tooling · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** GitHub repo: 25 Roblox pass skills. Workbench: 7 Codex skills discovered.
- **ACTUAL STATE:** The repo held 25 loose `roblox-*/skill.md` files (lowercase name, escaped markdown, 11 genre checklists; 2 of them, multiplayer-state-fix and persistence-and-rewards-audit, were empty). Neither Claude nor Codex looked in those folders. Now 20 skills live in `.agents/skills/` and are mirrored to `.claude/skills/`.
- **EVIDENCE:** Commit 054af82 tree. A fresh headless Claude Code 2.1.289 session in this repo listed all 19 repo skills in its init event (before `project-bootstrap` was added; Codex's rendering lists all 20, T02). Usage probe 2026-10-06 (`reports/skill-usage-2026-10-06.json`): a Claude Code subagent given only the task "generate a seeded cave layout for seed 7 and validate it" called the Skill tool for `roblox-procedural-generation` as its first action, followed it, and returned hash 1289b461 with 11 of 11 validators passing (re-run by the coordinator: same hash). `python3 tools/sync_skills.py --check` (pre-commit gate, CI) reports the skill count with 0 errors.
- **DEFECT:** No agent ever loaded the old guidance.
- **ROOT CAUSE:** Uploaded without the SKILL.md / skills-directory conventions.
- **IMPACT:** All earlier skill guidance was dead text.
- **FIX:** Rewrote into focused skills (20 now, including `project-bootstrap`), each with the ten sections Purpose, Triggers, Inputs, Required context, Tools, Procedure, Outputs, Acceptance, Failure and Related. `sync_skills.py --check` enforces them plus frontmatter, name = directory, description, size and LF line endings (read as bytes, with a built-in CRLF self-test; `.gitattributes` keeps skill files LF on Windows checkouts). Legacy checklists moved to `references/`; old root folders removed.
- **VERIFICATION:** Fresh Claude session init lists the repo skills; a plain task prompt made Claude load the matching skill unprompted; skills-sync gate step fails on a removed heading or renamed skill (checked in a scratch copy).

### T02

**Skills discoverable by Codex** · Agent tooling · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Workbench `tools/check_skill_discovery.py` verified 7 skills through the Codex app server.
- **ACTUAL STATE:** This repo uses the `.agents/skills/<name>/SKILL.md` layout Codex reads. codex-cli 0.160.1 (installed in a scratch folder, not logged in) rendered the model-visible input for a fresh session in a clean export of the branch: its skills list names all 20 repo skills from `.agents/skills`, and AGENTS.md is included.
- **EVIDENCE:** `reports/codex-skills-2026-10-06.json` (`codex debug prompt-input` in a `git archive` export with an empty CODEX_HOME; 20 of 20 skills listed, none missing).
- **DEFECT:** No live Codex model turn has chosen and followed a skill (needs a Codex login).
- **ROOT CAUSE:** No Codex login in the cloud session.
- **IMPACT:** Low: discovery is proven; use was proven for Claude (T01).
- **FIX:** Discovery verified with the real CLI; a live turn on the PC remains optional.
- **VERIFICATION:** Codex's own prompt rendering lists 20 of 20 repo skills.

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
- **ACTUAL STATE:** PostToolUse `fast_on_edit` (format, JSON, secrets from `tools/hooks/secret-patterns.json`, SKILL.md rules). PreToolUse `guard_bash` parses commands (argv, runners and wrappers such as npx and xargs, variables, PowerShell parameter prefixes, inline script bodies) and denies publish/upload tools, write requests to Roblox web APIs (curl, wget, httpie, PowerShell, inline scripts) including URLs hidden in variables, force pushes or deletions of main/master in any spelling, command lines over 64 KiB, and anything but known read-only commands on a line that names `weppy-project-sync/`. `guard_mcp` checks every string in a Studio or Blender tool input: it denies publishing or asset/place-creating Luau, completed purchases and Blender Python that publishes or writes to a Roblox web API, and asks before asset/quota Studio tools, Blender's third-party and paid tools, purchase prompts, DataStore/MemoryStore writes and Blender Python that imports network/shell modules or builds code. `tools/check.py` provides the pre-commit and pre-release tiers and installs a git pre-commit hook. The same guards run under Codex (T13).
- **EVIDENCE:** `node tools/hooks/selftest.mjs` (pre-commit gate and CI): 308/308 hook cases in both directions, 101 of them named regressions for the eight bypasses a second audit found (HOOK-1 to HOOK-8), 4 near-64 KiB command shapes denied within the hook timeout, and 17 secret samples checked against both the edit hook and `tools/check.py`. A mutation check during the fix broke each guard rule in turn and the self-test caught 22 of 22. Live in this session: the guard denied a heredoc containing a publish command and a Python heredoc that named the protected folder. Session-only (not reproducible from the repo, because the corpus holds machine-specific commands): this session's 3011 distinct Bash commands were replayed through the new guard; the 10 changed decisions were audit probe commands. The earlier "1514-command corpus" claim had no artifact in the repo and is withdrawn.
- **DEFECT:** Guards match text, so code that builds tool names or URLs at run time, scripts run from files, and aliases stored in git or shell config are not covered (documented in the guard headers and `docs/mcp.md`). `guard_mcp` has never run on a real Studio event. The folder rule is deliberately conservative: an interpreter line that merely mentions the folder is denied, so text about it is edited with the Edit tool.
- **ROOT CAUSE:** Hooks inspect command text, not runtime behaviour.
- **IMPACT:** Residual risk if an agent is manipulated into hiding a publish call in a script file; deny rules, Studio's own prompts and the account's lack of live products remain.
- **FIX:** Rewritten after two rounds of review findings (curl form/data uploads, DataStore writes, flag-order and refspec force pushes, CreateAssetVersionAsync, purchase prompts, folder redirects, rojo global flags, runner and xargs wrappers, httpie, oversized lines, MCP input fields other than `code`). No hook can publish or spend: they only return allow, ask or deny.
- **VERIFICATION:** Self-test in the pre-commit gate and CI; live denials observed; `guard_mcp` on a real Studio event pending (owner step).

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
- **ACTUAL STATE:** `tools/check.py` runs StyLua, JSON, the shared-pattern secret scan over every committable file, skills sync, gap matrix, doc links (relative links, heading anchors, well-formed URLs), the knowledge index and record paths, the fixtures README, asset provenance, Rojo sourcemaps of every project (orphan `.luau` files fail), a self-test that feeds each content check a broken input, hook self-test, Selene, Lune specs, the inherited suites, fixture builds with golden hashes (added, removed and changed fixtures fail; a missing golden fails) and the project-starter smoke; pre-release adds Blender templates, round trip, QA self-test and previews. A skipped step other than Selene fails by default and in the installed git hook; `--strict` (CI) also fails on Selene. `--update-golden` rewrites both the fixture and the Studio smoke goldens.
- **EVIDENCE:** Pre-release tier passed in the cloud container on the merged branch (Selene SKIPPED there: no network for its std). Both tiers passed in GitHub Actions in strict mode with nothing skipped (run 37393231152 on 367cd72). Planted broken inputs (bad link and anchor, malformed URL, unregistered asset id, orphan `.luau`, undocumented fixture, a workbench record claiming 'verified', stale index, missing golden, missing core tools) each failed the gate in a scratch copy; an intended SceneKit change went green with one `--update-golden`.
- **DEFECT:** The new content steps have not yet run in GitHub Actions.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Executed in the cloud container and in GitHub Actions (both tiers, strict).

### T08

**Continuous integration** · Agent tooling · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.github/workflows/factory.yml`: a pre-commit job (Rokit toolchain, Selene std generation, Rojo builds of the projects, `--tier pre-commit --strict`) and a Blender matrix on bpy 5.1.2 (the PC's version) and 5.2.2 LTS that runs `--tier pre-release --strict`.
- **EVIDENCE:** Runs 3 to 5 passed (pre-commit gate with Selene and nothing skipped, Blender templates and round trip on both bpy versions). Run 37393231152 on 367cd72 passed all three jobs in strict mode (pre-commit with Selene, pre-release on bpy 5.1.2 and 5.2.2).
- **DEFECT:** None at 367cd72.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** Keep CI green on the PR head.
- **VERIFICATION:** Green strict CI on the PR head.

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

**Rojo projects build from a clean clone** · Agent tooling · VERIFIED_STRONG · P2

- **PREVIOUS CLAIM:** Three Rojo fixture builds in the workbench gate.
- **ACTUAL STATE:** All four projects build from a clean clone. `network.project.json` used to read `../artifacts/network/SourceManifest.luau`, which only the PC workbench generated; it now reads `build/network/SourceManifest.luau`, written by `python3 tools/network_manifest.py` from the place's own sources (per-file sha256 and the combined `input_sha256` that the Echo scripts put in their evidence).
- **EVIDENCE:** Cloud container: `python3 tools/network_manifest.py` then `rojo build fixtures/network.project.json` (Rojo 7.7.1) built the place, and deserialising it in Lune listed FaultQueue, Settings and SourceManifest under ReplicatedStorage.WorkbenchNetwork. CI builds creator, diagnostic, factory and network.
- **DEFECT:** The workbench's own manifest format is unknown; this one keeps the only field the scripts read.
- **ROOT CAUSE:** Generated file referenced but never committed.
- **IMPACT:** n/a
- **FIX:** Generator plus CI build of all four projects.
- **VERIFICATION:** Rojo builds of all four projects in the container and CI.

### T12

**Reusable project starter** · Agent tooling · VERIFIED_ACCEPTABLE · P1

- **PREVIOUS CLAIM:** Not claimed (mission section 1).
- **ACTUAL STATE:** `tools/new_project.py <dest>` scaffolds a separate game repository with infrastructure only: factory packages (SceneKit, ProcGen, Pipeline by default, dependencies added automatically; Runtime, Creator and Diagnostics opt-in), a Rojo project, the pinned toolchain, the Lune runner and a starter spec, a trimmed gate, CI, the Claude and Codex guards (`.claude/settings.json`, `.codex/` with only the Studio server), game-repo AGENTS/CLAUDE templates with every game-design field left TBD, a decisions log, 14 skills and `starter.json` with package hashes. `--update` pulls package changes and refuses when a package was edited in the game repo. It refuses a destination inside the factory or a non-empty one, and never runs a git write.
- **EVIDENCE:** Gate step `starter-smoke` (pre-commit): scaffolds into a temp dir, runs `git init` there and runs that repo's own gate (StyLua, skills, hooks self-test including the Codex hook, rule and config parity, Lune specs, Rojo build), plus the refusals and `--update`. Breaking a package, a template path, the template gate or a placeholder each made it fail; so did the Codex guard files before the starter copied them.
- **DEFECT:** The generated CI has never run on GitHub and a generated place has not been opened in Studio.
- **ROOT CAUSE:** No game repository exists (setup-only).
- **IMPACT:** First real use may surface CI setup issues.
- **FIX:** On the first explicit game-build request, push the new repo and confirm its CI is green.
- **VERIFICATION:** `starter-smoke` in the pre-commit gate and CI.

### T13

**Publish/spend guards and MCP settings for Codex** · Agent tooling · PARTIAL · P1

- **PREVIOUS CLAIM:** Not claimed; the mission requires the factory to stay usable by both Claude and Codex.
- **ACTUAL STATE:** `.codex/config.toml` (on-request approvals, workspace-write sandbox, no network, the `.mcp.json` servers with the ask tools prompted), `.codex/hooks.json` (PreToolUse: Bash to `guard_bash.mjs`, Studio/Blender MCP to `guard_mcp.mjs`, both with `--client=codex`, which turns every ask into a deny because Codex hooks cannot ask), and `.codex/rules/factory.rules` (prefix rules: forbidden or prompt for plain publish and force-push commands). Setup and health checks are in `docs/mcp.md`.
- **EVIDENCE:** Self-test: 307/307 hook cases through the `.codex/hooks.json` commands; 40/40 plain publish/upload/force-push cases forbidden or prompted by the rules, none of the allow cases forbidden; 217/217 rule decisions identical to `codex execpolicy check` from codex-cli 0.160.1 (re-run by the coordinator with `CODEX_BIN`); config parity 36/36.
- **DEFECT:** Nothing applies until the project and each hook are trusted in Codex. A hook that errors, times out or cannot find `node` lets the call run. In a linked git worktree Codex reads the main checkout's hooks. CLI bypass flags and the PC's permissive global Codex config (M06) override the project config. No live Codex model turn and no Windows run were made.
- **ROOT CAUSE:** Codex's hook and trust model differs from Claude's; the PC is outside this container.
- **IMPACT:** Codex sessions on the PC run unguarded until the owner trusts the project and hooks.
- **FIX:** Shared guards with a Codex mode, rules for the plain forms, config parity checked in the gate.
- **VERIFICATION:** Hook, rule and config parity in the pre-commit self-test; live Codex behaviour pending.

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
- **ACTUAL STATE:** The built-in Studio MCP (user-level `Roblox_Studio`, Studio 0.741.19) was driven live from a Claude Code session on the PC. The saved reports record `execute_luau`, `search_game_tree` and `screen_capture` (the image stayed on the PC); the session also listed the open Studio and started Run mode, but those calls are not recorded in the reports. The repo's `.mcp.json` declares the same command with hook gating.
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
- **ACTUAL STATE:** The repo now declares the same Studio and Blender servers for Codex in `.codex/config.toml` (`uvx mcp-for-blender==2.1.8`, telemetry off), with `approval_mode = "prompt"` on exactly the tools the Claude guard asks for. No Codex model session has connected to Blender.
- **EVIDENCE:** Self-test: the two servers in `.codex/config.toml` are identical to `.mcp.json`, and 36 of 36 tools prompt in Codex exactly when `guard_mcp` asks.
- **DEFECT:** Tools configured but not loaded.
- **ROOT CAUSE:** Codex project trust not granted.
- **IMPACT:** Codex can't drive Blender interactively; headless `factory.py` still works.
- **FIX:** Owner trusts this project and its hooks in Codex, then runs `codex mcp list` and asks for `get_scene_info` with Blender open.
- **VERIFICATION:** Config parity in the self-test; live Codex connection pending.

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

### M07

**MCP audit per server (why, client, tools, permissions, ports, network, auth, telemetry, overlap, failure modes, health check)** · MCP and Studio · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** First pass listed servers without an audit.
- **ACTUAL STATE:** `docs/mcp.md` has one column per server (Roblox_Studio, blender, WEPPY, GitHub) covering every field, the decision to run `execute_luau` and `multi_edit` without a prompt (guarded by content checks on every input string, the unpublished diagnostic place, Rojo source and undo), and the needs-based decision not to add browser, filesystem or docs/search MCP servers. The Blender column reflects 2.1.8 (14 tools, `look` replaces `get_viewport_screenshot`); outdated mentions in the research note and the asset-factory skill were corrected.
- **EVIDENCE:** Blender tool list and telemetry state read from the installed 2.1.8 package; Codex setup checked against codex-cli 0.160.1; the hook self-test exercises every permission the table states.
- **DEFECT:** WEPPY's auth, telemetry and tools are unknown (its folder is read-only and out of scope). GitHub MCP writes have no repo guard. The Blender socket has no authentication (vendor note).
- **ROOT CAUSE:** Third-party servers outside this repo.
- **IMPACT:** WEPPY stays unused for factory work (M05).
- **FIX:** Documented; WEPPY kept unused until Ethan confirms its auth.
- **VERIFICATION:** Table cross-checked against the installed package, the guards and the self-test.

### S01

**Studio testing modes (Test, Test Here, Run, Server & Clients) and device emulation** · MCP and Studio · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Play and local one/two-client RemoteEvent/leave fixtures passed.
- **ACTUAL STATE:** The gate's "native" passes replay hashes of saved receipts; they do not open Studio. MCP `start_stop_play` covers Test and Run; Test Here and Server & Clients are started from the Studio UI. On 2026-10-05 Run mode was started on the PC but the FACTORY_SMOKE console line could not be read (permission prompt).
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` (run_mode field); research section 2.
- **DEFECT:** No play mode has produced observed output in this pass.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Replication and play behaviour of new code is unproven.
- **FIX:** Run S02 in Run mode, and one Server & Clients session with 2 clients on the network fixture.
- **VERIFICATION:** Console output and captures saved under `reports/studio/`.

### S06

**Studio MCP operations beyond the core loop (property inspection, script read/edit, asset search/insert, console, camera, keyboard/mouse/character input)** · MCP and Studio · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Native Studio connection partially verified (sync/readback, Play, screenshots, simulated input).
- **ACTUAL STATE:** Only five Studio tools were exercised live in this pass (see M01). `inspect_instance`, `script_read`/`multi_edit`, `search_asset`/`insert_asset`, `get_console_output`, camera control, `user_keyboard_input`, `user_mouse_input` and `character_navigation` were not run, so the first pass's simulated-input claim is neither confirmed nor refuted. In `.claude/settings.json` all of them are allowed except `insert_asset` (ask) and `search_asset` (no rule, so Claude prompts).
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` and `reports/studio/roundtrip-2026-10-05.json` record no calls to these tools; `.claude/settings.json` allow/ask lists.
- **DEFECT:** Unexercised operations.
- **ROOT CAUSE:** Studio runs only on the PC; the PC session was used for the smoke test and the round trip, and a permission prompt blocked the Run-mode console read.
- **IMPACT:** Agents may rely on input simulation, script editing or asset insertion that nobody has seen work with the current Studio version.
- **FIX:** One scripted pass on the diagnostic place covering each tool, saved under `reports/studio/`.
- **VERIFICATION:** Pending: observed output of each tool on the PC.

### S02

**SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** · Scene authoring · PARTIAL · P0

- **PREVIOUS CLAIM:** WorldInspector queries and metadata-only content graphs; "no setup game world".
- **ACTUAL STATE:** At commit 9c12091, `FactorySmoke` was run in real Studio (0.741.19) on Ethan's PC through Studio MCP `execute_luau`, in the unpublished SETUP_ONLY_Factory_Diagnostic place that Rojo built from `fixtures/factory.project.json`. It built both scenes with string requires across SceneKit and ProcGen, and the hashes and part counts equalled that commit's Lune golden: building 778d1d9a / 96 parts, dungeon 8494d161 / 108 parts. Two ChangeHistoryService undos removed both scenes. Since then the generators changed (about 1000 lines, including the new `ProcGen/RoomGraph.luau`), the dungeon golden is now 927f2db4, and `Apply.scene` replaces by default; none of that has run in Studio.
- **EVIDENCE:** `reports/studio/smoke-2026-10-05.json` (commit 9c12091); `tests/golden/studio-smoke.json` at 9c12091 and at HEAD. At HEAD the factory place builds and all its string requires resolve to ModuleScripts (checked by deserialising the Rojo build in Lune).
- **DEFECT:** Studio parity at HEAD is unverified: the new generators, the new dungeon golden and the replace-then-undo path have not run in Studio. Run mode is unproven: the PC's permission prompt blocked reading the FACTORY_SMOKE console line.
- **ROOT CAUSE:** Console read needs Ethan's approval on his machine; later commits change hashes on purpose.
- **IMPACT:** Edit-time parity and undo are proven. Play-time parity is not, and the parity proof applies to 9c12091's hashes.
- **FIX:** Re-run steps 1 to 3 after pulling, and approve the console read once for the Run-mode line.
- **VERIFICATION:** Observed in Studio at 9c12091 only; HEAD pending the owner steps.

### S03

**Scene-authoring API as data (buildings, props, lights and signs, interior dressing, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance)** · Scene authoring · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present (metadata graphs only).
- **ACTUAL STATE:** `packages/SceneKit`: plans are data, built from seeds and style profiles, validated (part budget, door clear width against every wall, room clearance, stair rise, headroom and oriented-box obstruction at any yaw, prop clipping and support), hashed into manifests, compared between revisions, rendered, and applied in Studio with undo; `Apply.scene` replaces the previous model of the same name unless `{replace = false}`. Part specs can carry a light (Point/Spot/Surface) or a sign (SurfaceGui with placeholder text), validated by `light_placement` and `sign_text`; `Building.decorate` places one light per room and neutral props along walls with a seed, clear of doorways, stair openings and windows. Dressing is opt-in and no fixture uses it. Prop clipping now confirms AABB hits with oriented-box penetration, as the stair checks do.
- **EVIDENCE:** Lune specs (`tests/scenekit.spec.luau`, `tests/scenekit_layout.spec.luau`: 300 seeded subdivisions with no bisected doorway, 36 two-storey buildings and the settlement-202 houses with every doorway clear, railing vs next flight at 3 to 5 storeys, yawed stairs, the fixture ramp clear of the Annex; `tests/scenekit_dressing.spec.luau`: a 48-building decorate sweep plus yaws 30, 90 and 217 with every room lit, zero penetration and doorway width intact). A scratch sweep of 240 decorated cases found 0 failures, and 7 sabotaged decorate rules were each caught. Six SETUP_ONLY fixtures build and validate with stable hashes. Studio parity of the smoke scenes was observed at 9c12091 (S02); the replace-then-undo path and dressing have not run in Studio.
- **DEFECT:** Fixed in this pass: stair headroom at 3+ storeys, inverted gable slopes, ramp yaw, front camera; after review: Apply not replacing with no options, partitions cutting doorways, railing clipping the next flight, the fixture ramp buried in a foundation, AABB stair checks failing at non-axis yaw.
- **ROOT CAUSE:** Rotation-convention errors, caught by validators and renders.
- **IMPACT:** n/a after fixes.
- **FIX:** Regression specs for each.
- **VERIFICATION:** Specs, fixture hashes, previews.

### S04

**Measurement and player-scale helpers** · Scene authoring · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Conservative AABB/ray queries in WorldInspector.
- **ACTUAL STATE:** `Measure`: engine defaults (gravity 196.2, WalkSpeed 16, JumpHeight 7.2) and design guides (doors, ceilings, corridors, cover), jump reach, clearances, sightlines, camera clearance.
- **EVIDENCE:** Measurement specs, including `tests/scenekit_coverage.spec.luau` for `cameraClearance` (wall behind: clear=false, 6 studs available; open: clear=true, 12.5) and `corridorWidth` (5 fails, 6 passes, 10 comfortable, 3 players need 8.5). ProcGen's camera and sightline checks use their own grid logic.
- **DEFECT:** Guides are heuristics, not playtested with a character.
- **ROOT CAUSE:** No Studio character run yet.
- **IMPACT:** Values may need tuning per game.
- **FIX:** Check with `character_navigation` during S02.
- **VERIFICATION:** Specs.

### S05

**Terrain and lighting applied in Studio** · Scene authoring · PARTIAL · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Terrain heightmaps, flatten, smooth, paint, sculpt, carve and water produce ops that `Apply.terrain` replays: a spec with a recording Terrain checks the exact call order, positions, sizes and materials and one undo recording, and malformed op lists are rejected before any voxel changes. Lighting profiles apply to a Lune Lighting service. Neither has been applied in Studio.
- **EVIDENCE:** `tests/scenekit.spec.luau`, `tests/scenekit_coverage.spec.luau`.
- **DEFECT:** Voxel output and the look of lighting profiles are unverified.
- **ROOT CAUSE:** Engine-only behaviour.
- **IMPACT:** Terrain plans may need adjustment once seen.
- **FIX:** Apply a `Terrain.heightmap` plan (as in `tests/scenekit.spec.luau`) and each lighting profile in the diagnostic place and capture them; no fixture emits terrain ops yet.
- **VERIFICATION:** Screen captures per lighting profile.

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
- **ACTUAL STATE:** Placement and validation are verified in Lune (S03 sweeps), and `Apply` creates the Light and SurfaceGui instances in a Lune DataModel. The lit look and sign rendering are unseen.
- **EVIDENCE:** `tests/scenekit_dressing.spec.luau`; a decorated building rendered with `factory.py render-manifest` and reviewed (four rooms, centred fixtures, props on walls clear of doorways, sign above the door).
- **DEFECT:** Not observed in Studio.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Light ranges and sign legibility are untested in the engine.
- **FIX:** On the PC: build a building, `Building.decorate(scene, building, { lights = "mixed", sign = "SIGN_A" })`, `Apply.scene`, `screen_capture`, then undo.
- **VERIFICATION:** Specs in the gate; Studio pending.

### P01

**Seeded generators (dungeon, cave, arena, settlement, forest)** · Procedural generation · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** `packages/ProcGen`: BSP + MST dungeons whose loops are walkable on the carved grid and wrap real wall (`minLoopWallStuds`), goals and encounters placed in rooms big enough for them on the best shortest route (shortfalls fail `encounters_placed`), cellular-automata caves re-joined until exactly one region, symmetric arenas with the objective on the true centre, road/lot settlements, and forests (`Forest.generate`: noise-ranked open/sparse/dense/rocky bands, role-tagged clearings, an entry-to-exit spanning path network, trees, bushes and rocks spaced per band with path, clearing and spawn exclusions; `ForestScene.toScene` turns it into SceneKit parts).
- **EVIDENCE:** `tests/procgen.spec.luau` (every validator asserted, no exclusions), `tests/procgen_regressions.spec.luau` (independent grid loop check on seeds 1 to 40, 200-seed sweeps for loops, encounters and run length, caves at two sizes (48x36, 32x24) over seeds 1 to 200, arenas at 7 sizes x 2 symmetries) and `tests/procgen_forest.spec.luau` (13 cases); golden fixture hashes in the gate (forest 3d7d7cb5). A forest sweep found 0 failures over 300 seeds at 256x192, 50 at 384x256 and 200 at 160x128.
- **DEFECT:** Fixed during the pass: seed 303 had no loop, 4-stud caves, 1-cell arena lanes. After review: graph-only loops (47 of seeds 1 to 200 had no walkable loop), cramped goal rooms failing encounter_space on 12 of 25 spec seeds while the spec skipped that check, cave seed 87 split in two, NaN spawn fairness, off-centre arena objective.
- **ROOT CAUSE:** Generator parameters; caught by validators.
- **IMPACT:** n/a after fixes.
- **FIX:** RoomGraph loop measure, capacity-aware placement, region re-join loop, unreachable spawns fail, centred objective; goldens regenerated (dungeon 06ace82c, arena 20898139, Studio smoke dungeon 927f2db4).
- **VERIFICATION:** Specs and fixture hashes in the gate and CI.

### P02

**Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance)** · Procedural generation · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Implemented on the layout grid and room graph with machine-readable checks, including encounters_placed and walkable-loop redundant_paths. Forests add path_clearance, clearing_reachability (BFS on a 2-stud grid minus trunk and rock discs), spawn_clear, band_density, min_trunk_spacing, obstacle_gap, clearing_space and clearings_placed.
- **EVIDENCE:** Every fixture's checks in `build/fixtures/report.json`; failing cases in the specs for each validator (unreachable spawn, graph-only loop, pillar loop, encounter shortfall, split cave; for forests a trunk on the path, a dropped spur path, an over-dense band, a rock at the spawn, twin trunks, a trunk in a clearing, a 4-stud path, too many clearings, a part budget one below the estimate). Disabling each of the 11 forest rules in a scratch copy made the intended case fail.
- **DEFECT:** Grid and disc reasoning, not PathfindingService or Humanoid physics; forest density bounds are design heuristics.
- **ROOT CAUSE:** Headless by design.
- **IMPACT:** A layout can pass the grid and still snag a character on geometry.
- **FIX:** Add a PathfindingService reachability probe to S02 later.
- **VERIFICATION:** Specs and fixture reports.

### P03

**Determinism and manifests** · Procedural generation · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** Hash-drift blocking for planning records.
- **ACTUAL STATE:** Same seed gives the same manifest hash; canonical sorted JSON; golden hashes for fixtures and the Studio smoke.
- **EVIDENCE:** `fixture-hashes` gate step locally and in CI; the forest fixture builds byte-identical twice and was added to the golden without changing the other five hashes.
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

### B01

**Blender asset templates and QA reports (13 kinds)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Blender direct authoring/export verified (68-triangle 2-bone fixture, 128px bake, FBX+GLB, reimport, turntable).
- **ACTUAL STATE:** `tools/blender/factory.py templates`: humanoid, npc, enemy, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests. QA runs before export and a failing asset writes no FBX/GLB (exit 1, `qa.json` kept). Checks use world transforms, count only deform-bone weights, and re-import the shipped FBX and GLB against a signature of the export set. `qa <file>` works on .blend, .fbx, .glb and .gltf, with seam-aware glTF welding, and applies the Studio pivot rule (`studio_pivot_at_origin`) to the roots of any of them: the Export set, otherwise the scene's meshes, armatures and empties minus cutters and helpers; kits with several roots only warn. QA leaves no temp folders. The rig and animation tests use smooth bone-heat weights limited to 4 normalised influences; QA warns on unnormalised weights.
- **EVIDENCE:** All 13 templates and QA of all 26 shipped FBX/GLB files pass on bpy 5.0.1, 5.1.2 and 5.2.2 in the container; 13/13 on Ethan's Blender 5.1.2 (at 9c12091); CI Blender jobs on 5.1.2 and 5.2.2. `factory.py qa-selftest`: 33 known-good and known-bad cases agree across source, saved .blend, FBX and GLB and the export gate on all three bpy versions, including an asset 0.75 studs off the world origin that every format must fail. The audit's off-origin .blend/.fbx/.glb files now exit 1.
- **DEFECT:** Fixed: Blender 5.1+/5.2 boolean empty material slot, FBX animation loss, join material indices, mirror self-merge, inset bounds. After review: the probe tested a different export than the shipped files, QA never blocked export, local-only transform checks, non-deform groups counted as weights, false GLB errors, stale matrix_world in set_origin_base_center.
- **ROOT CAUSE:** Blender 5.1+ boolean behaviour change; exporter defaults.
- **IMPACT:** The factory would have failed QA on Ethan's installed Blender.
- **FIX:** `prune_material_slots`; `qa.gated_export`; shipped-file probe; world-space and deform-bone checks; `_weld_seams`; `studio_pivot_at_origin`; `qa-selftest` in the pre-release tier.
- **VERIFICATION:** Template and QA runs on three bpy versions; CI matrix; self-test proves known-bad assets fail.

### B02

**Blender built-ins in the factory (Geometry Nodes, Asset Browser catalogs, texture baking, Rigify)** · Blender · MISSING · P2

- **PREVIOUS CLAIM:** Workbench: a 128px bake fixture.
- **ACTUAL STATE:** The factory scripts primitives, modifiers, UVs, PBR materials, rigid and automatic (bone heat) weighting, voxel/QuadriFlow retopology and Decimate LOD chains (B08), and keyframes. Geometry Nodes, asset catalogs, baking and Rigify are researched but not scripted.
- **EVIDENCE:** `tools/blender/bkit/ops.py`; research section 5.
- **DEFECT:** Missing automation.
- **ROOT CAUSE:** Scoped out of this pass.
- **IMPACT:** Kits and baked textures stay manual.
- **FIX:** Next pass: GN scatter/LOD, catalog writer, bake step with QA.
- **VERIFICATION:** n/a

### B03

**Preview renders for visual QA** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Turntable and comparison images.
- **ACTUAL STATE:** `render-manifest` renders SceneKit manifests (Cycles CPU) from their cameras, or frames cameras from the part bounds when a manifest has none, so plain `scene:manifest()` output renders; templates render front and three-quarter views. The stage ground sits below the lowest mesh, so floors at Y=0 no longer render black; the pre-release tier renders the building, dungeon, settlement and forest fixtures.
- **EVIDENCE:** `build/previews/*.png` reviewed; they exposed three geometry bugs in the first round, and in this round black floors (stage coplanar with floor tops) and black discs at forest path bends (joint pads coplanar with segments), both fixed and re-rendered.
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
- **ACTUAL STATE:** Ethan imported the neutral SM_RoundTripMarker v1 and v2 with Import 3D (Scale Unit = Stud) into the unpublished diagnostic place, and `ImportInspector` (at 9c024fb) ran in Studio with its default EditableMesh reader. Both revisions matched Blender on scale (4 x 7 x 3.5 and 4 x 8 x 4.5 studs), rotation, facing (surface-centroid offset -0.620 vs -0.62 and -1.026 vs -1.026, plus a screen_capture from -Z) and collision, and `compareRevisions` detected the update. The pivot failed: Studio puts the model pivot at the FBX file origin, and the marker's origin sat off Blender's world origin. Each import uploaded a private mesh asset to Ethan's account (there is no local-only import). Since then the inspector was hardened in Lune: the pivot is compared as an offset from the base centre in studs (the old tolerance grew with distance from the world origin, so a far placement could pass the recorded defect), the triangle count is compared with Blender's, a multi-material import without a texture, SurfaceAppearance or vertex colours fails `appearance_bound`, missing expectation data fails as not checked, and `compareRevisions` compares size, triangles and surface offsets.
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json` (inspector at 9c024fb; v2 was the pre-fix export, which matches its +1.25 stud pivot error exactly). `lune run tests/run.luau import_inspector`: 18 cases (was 8; the new spec fails 11 cases against the old inspector), and 31 single-check mutations were all caught.
- **DEFECT:** The pivot fix (1eee84a) and the hardened inspector have not run in Studio; its EditableMesh colour reader is untested there. Material colours are lost (B06), so the marker's `appearance_bound` now fails by design until a texture is baked. The marker's vertical asymmetry (up offset about 0.05 studs) is too small for the upside-down diagnosis; the pivot check and the capture catch that case instead.
- **ROOT CAUSE:** Studio's importer anchors the pivot at the file origin, not at the object origin.
- **IMPACT:** Every asset exported off the world origin arrives with a misplaced pivot.
- **FIX:** Export at the world origin (done for the marker; the QA pivot check covers origin vs bounds). Confirm by importing the fixed v2.
- **VERIFICATION:** ImportInspector in Studio at 9c024fb: 6 of 7 checks passed for v1 and v2 and the revision was detected; the hardened inspector is verified in Lune only.

### B06

**Material colour survives the Studio import** · Blender · MISSING · P1

- **PREVIOUS CLAIM:** None (first pass never imported into Studio).
- **ACTUAL STATE:** Both imported MeshParts are plain grey (Color 0.639, 0.635, 0.647, empty TextureID, no SurfaceAppearance). The marker's per-material Principled base colours (MAT_Body grey, MAT_Front orange) do not carry through Import 3D. `ImportInspector` now fails `appearance_bound` with "material colours lost" for such imports instead of passing.
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json`.
- **DEFECT:** Untextured multi-material assets lose all colour in Roblox.
- **ROOT CAUSE:** A MeshPart takes one texture or SurfaceAppearance; material base colours without image textures are not converted.
- **IMPACT:** Factory assets would arrive colourless unless their colours are baked.
- **FIX:** Bake base colour into one texture per asset in Blender (UV atlas), export it with the FBX, then confirm the import binds it (that import uploads a mesh and an image).
- **VERIFICATION:** A Studio import shows the baked colours, and the inspector's appearance_bound reports a texture.

### B07

**Rigged and animated asset into Studio (skinned mesh, bone names, animation clip)** · Blender · BLOCKED_EXTERNAL · P1

- **PREVIOUS CLAIM:** Not claimed separately; the templates' Blender QA stood in for it.
- **ACTUAL STATE:** The rigged and animated templates (humanoid, NPC, enemy, creature, animation test) pass Blender QA headlessly, including bone influences and clip checks (B01). None has been imported into Studio: the only Studio import in this pass was the static SM_RoundTripMarker. `ImportInspector` checks static MeshParts, so skinning, bone names and clip playback in Studio are untested.
- **EVIDENCE:** `reports/studio/roundtrip-2026-10-05.json` (static marker only); pre-release `blender-templates` step.
- **DEFECT:** The Studio half of the character, NPC, enemy and animation pipelines is missing.
- **ROOT CAUSE:** Every 3D import uploads a private asset, which needs Ethan's approval; only the marker was approved.
- **IMPACT:** Character and animation assets may break on import (bone names, skinning, clip length) without anyone noticing.
- **FIX:** Import one neutral rigged template with its clip, and extend the inspector to compare bones, skinning and clip length with a Blender expectation.
- **VERIFICATION:** Pending: inspector output in Studio saved under `reports/studio/`.

### B08

**Retopology, LOD chains and smooth skin weighting (bkit)** · Blender · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Skill promised weighting; only rigid binding existed.
- **ACTUAL STATE:** `ops.voxel_remesh`, `ops.quadriflow`, `ops.lod_chain`, `ops.bind_auto`/`ops.limit_weights` and the seeded `ops.noise_displace` run headless on bpy 5.0.1, 5.1.2 and 5.2.2. Heat weighting is normalised and capped at 4 influences; vertices heat cannot reach are bound to the nearest bone and reported. LOD copies keep the Armature modifier and their triangle counts strictly decrease.
- **EVIDENCE:** `factory.py qa-selftest` 33/33 on all three versions, including an auto-weighted humanoid (raw heat gave up to 7 influences; after `bind_auto` max 4, normalised, none unweighted), a 1280/640/320/128-triangle rock LOD chain, a skinned LOD chain, and bad cases (5 influences, unweighted vertices) failing the right check; seeded geometry hashes identical across versions; 7 sabotaged ops each caught.
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
- **ACTUAL STATE:** `docs/research/tooling-2026-10.md` (Studio MCP, testing modes, Luau toolchain, Blender MCP rename, Blender built-ins, mesh import limits, Claude Code and Codex mechanics, procgen references, plus a back-fill of price, last update, maintenance and licence) and `docs/research/tooling-2026-10-addendum.md` (UI, animation, VFX, terrain, context and code index, visual QA and video, performance, security, CI/CD, extra MCP servers). Each candidate has source, publisher, version, last update, maintenance, licence, price, purpose, security, overlap, Claude/Codex access, benefit and SELECT/REJECT/REVISIT.
- **EVIDENCE:** Dated sources fetched 2026-10-05 and 2026-10-06 (registries, official docs, release pages), listed in each file's Sources section.
- **DEFECT:** Some release years are unknown because GitHub feeds and APIs were blocked; facts were read through a summarising fetcher. Several selections are not implemented yet (luau-lsp gate step, Script Profiler capture, WriteVoxels terrain apply, pinning the Rokit installer script).
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
- **ACTUAL STATE:** Rejected for this setup-only factory (research addendum section I; `tooling-2026-10.md` section 10, correction 1). It needs an API key and uploads a place version to run, and Luau Execution scripts can read and modify DataStores.
- **EVIDENCE:** Research section 3 and section 10; Roblox Luau Execution docs fetched 2026-10-06.
- **DEFECT:** Engine-only modules have no automated in-engine test.
- **ROOT CAUSE:** Account access and the upload boundary.
- **IMPACT:** Studio-bound regressions caught only by manual runs.
- **FIX:** If Ethan authorises a private test universe: Wally `jsdotlua/jest`, upload the test place version, run via the Luau Execution API with the key in CI secrets.
- **VERIFICATION:** CI job green.

### D04

**Research and knowledge database** · Research · PARTIAL · P2

- **PREVIOUS CLAIM:** Knowledge records verified on the workbench (inherited).
- **ACTUAL STATE:** `knowledge/records/` holds 23 records copied from the owner's workbench. 22 cite tools, tests and reports that exist only there (39 of 40 cited paths are absent from this repo), so they are now scoped `workbench` with `*_on_workbench` statuses and a note; `knowledge/INDEX.md` lists the records and research docs. The gate's `knowledge-paths` step fails a record that cites a missing path without that scope, and `knowledge-index` fails a stale index.
- **EVIDENCE:** Gate steps `knowledge-index` and `knowledge-paths`; a planted record claiming 'verified' failed.
- **DEFECT:** Most records are claims this repo cannot reproduce.
- **ROOT CAUSE:** Records were copied without their tools.
- **IMPACT:** Agents reading the records must treat them as the workbench's claims.
- **FIX:** Port or re-verify a record's tool here, then switch its scope to `repo`.
- **VERIFICATION:** Gate steps in pre-commit.

### X01

**Publishing, asset upload, purchases, live products, ads** · Boundary · INTENTIONALLY_EXCLUDED · P0

- **PREVIOUS CLAIM:** Intentionally excluded.
- **ACTUAL STATE:** Excluded and enforced: hooks deny publish/upload commands, Open Cloud and DataStore/Messaging writes, publishing or asset-creating Luau and completed purchases, and ask before asset-creating Studio tools, purchase prompts and DataStore/MemoryStore writes. The one exception, approved by Ethan on 2026-10-05: Import 3D of the neutral round-trip marker into the unpublished diagnostic place, which uploaded two private mesh assets (ids kept out of the repo). Under Codex the same guards deny what Claude would ask (T13).
- **EVIDENCE:** Hook self-test (308 cases, also run through the Codex hook commands) including every Prompt*Purchase, CreateAssetVersionAsync and CreatePlaceInPlayerInventoryAsync; `reports/studio/roundtrip-2026-10-05.json`.
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
- **ACTUAL STATE:** Static budgets run on every build: ProcGen's `performance_part_estimate` validator on each fixture and Blender QA's triangle and material budgets. There is no runtime profiling tooling (MicroProfiler, Script Profiler, memory or frame-time capture); `roblox-performance-pass` is a procedure only.
- **EVIDENCE:** `build/fixtures/report.json` (performance_part_estimate per fixture) and Blender QA reports from the pre-release gate.
- **DEFECT:** No runtime measurement.
- **ROOT CAUSE:** Profiling needs Studio or a device; nothing was built for it.
- **IMPACT:** Budgets are estimates; frame time and memory on real devices are unknown.
- **FIX:** A Studio profiling procedure that saves MicroProfiler/Stats output for the fixtures into `reports/studio/`, with thresholds.
- **VERIFICATION:** Static budget checks run in the gate; runtime profiling not built.

### Q02

**Release readiness checks** · Production lab · MISSING · P3

- **PREVIOUS CLAIM:** Release pass skill.
- **ACTUAL STATE:** Only the `roblox-release-pass` skill exists. It is a checklist for a game repository and writes `reports/release-readiness.json` there; nothing executable checks release readiness.
- **EVIDENCE:** `.agents/skills/roblox-release-pass/SKILL.md`; no release tool in `tools/`.
- **DEFECT:** Procedure only.
- **ROOT CAUSE:** Release checks need a game, which this setup-only repo must not create.
- **IMPACT:** A future game repo starts its release checks from a checklist, not a tool.
- **FIX:** Ship an executable release checklist (config, permissions, product ids, place settings) with the project starter.
- **VERIFICATION:** None.

### Q03

**Game security validation (server authority, remote validation, abuse tests)** · Production lab · PARTIAL · P2

- **PREVIOUS CLAIM:** Multiplayer integrity skill and network diagnostics.
- **ACTUAL STATE:** The inherited network diagnostics suite (11 Lune cases: bounded queues, loss, duplication, reordering, deterministic fault replay) runs in the gate. Remote-argument validation and exploit or abuse tests do not exist; `roblox-multiplayer-integrity` is a procedure.
- **EVIDENCE:** `tests/diagnostics/network.luau` (gate step `inherited-diagnostics-network`).
- **DEFECT:** No remote-validation helpers or abuse harness.
- **ROOT CAUSE:** First pass focused on transport faults, not server authority.
- **IMPACT:** Security of future game remotes rests on review alone.
- **FIX:** A remote-schema validator module with Lune specs that feed malformed, oversized and out-of-order calls.
- **VERIFICATION:** Network fault suite passes in the gate; security validation not built.

### Q04

**Visual regression** · Production lab · PARTIAL · P2

- **PREVIOUS CLAIM:** Visual QA skill.
- **ACTUAL STATE:** Structural regression is enforced: fixture manifest hashes and the Studio smoke hashes are goldens, so any geometry change fails the gate unless intended. Image regression is not: previews (B03) are reviewed by eye and there is no baseline image or pixel diff.
- **EVIDENCE:** `tests/golden/fixture-hashes.json`, `tests/golden/studio-smoke.json`, gate step `fixture-hashes`.
- **DEFECT:** No image baselines.
- **ROOT CAUSE:** Renders differ across Blender versions, so pixel baselines need per-version images and tolerances.
- **IMPACT:** A material or lighting change that keeps geometry identical passes unnoticed.
- **FIX:** Per-Blender-version low-resolution preview baselines with a perceptual tolerance in the pre-release tier.
- **VERIFICATION:** Hash goldens verified in the gate; image diff not built.

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
- **ACTUAL STATE:** `assets/provenance.json` is the registry (source, licence, approval, date, purpose), and the `asset-provenance` gate step scans every committable file for Roblox asset ids (rbxassetid, rbxthumb, asset, library, catalog and store URLs, `?id=`, and AssetId/MeshId/TextureId/SoundId/AnimationId/ImageId/DecalId fields). An unregistered id fails, 0 is the only placeholder, and only approved ids may appear in place content. The registry holds one id, a research citation inherited from the workbench. `roblox-asset-intake` describes the approval procedure.
- **EVIDENCE:** Gate step `asset-provenance` (224 files scanned); a planted unregistered id failed with its file and line.
- **DEFECT:** No asset has been through the intake approval path, so approved entries are unexercised.
- **ROOT CAUSE:** Setup-only: no assets are sourced.
- **IMPACT:** The approval half is untested until the first real intake.
- **FIX:** Run the first real intake through `roblox-asset-intake` in a game repo.
- **VERIFICATION:** Gate step with a negative self-test.

### Q07

**Gameplay-system library** · Production lab · PARTIAL · P3

- **PREVIOUS CLAIM:** Genre system checklists and inherited runtime modules.
- **ACTUAL STATE:** Reusable logic exists only as the inherited pure-Luau modules in R01 (receipts, lifetime, motion, audio, effects, UI logic). The 11 genre references in `roblox-genre-systems` are checklists, not code. There is no movement, combat, inventory or quest system.
- **EVIDENCE:** `packages/Runtime`, `packages/Creator`; `.agents/skills/roblox-genre-systems/references/`.
- **DEFECT:** No reusable gameplay systems.
- **ROOT CAUSE:** Gameplay systems border on game design, which the setup-only boundary excludes.
- **IMPACT:** A future game builds its core systems from scratch.
- **FIX:** Genre-neutral system modules (input mapping, interaction prompts, inventory container) with specs, chosen at game-build time.
- **VERIFICATION:** R01 suites pass in the gate.

### Q08

**Analytics** · Production lab · MISSING · P3

- **PREVIOUS CLAIM:** Analytics foundation partially verified (workbench).
- **ACTUAL STATE:** Missing in this repo. The offline analytics report tool, its schema and its test exist only on the owner's workbench. `fixtures/analytics/` (neutral events, an expected report, default exclusions) is labelled in `fixtures/README.md` as inherited input for that tool, and its knowledge record is scoped to the workbench.
- **EVIDENCE:** `fixtures/README.md`; `knowledge-paths` lists the record's four absent artifacts.
- **DEFECT:** No executable analytics in the repo.
- **ROOT CAUSE:** Only the fixtures were copied.
- **IMPACT:** A future game starts analytics from scratch or from the workbench copy.
- **FIX:** Port the workbench report tool with its test and a gate step, or delete the fixtures.
- **VERIFICATION:** None.
