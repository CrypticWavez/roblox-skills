# Second-pass gap matrix

Generated from `reports/gap-matrix.json` by `python3 tools/gap_matrix.py`; edit the JSON, not this file. As of 2026-10-05.

Second-pass audit of the Roblox production factory (this repo plus a read-only audit of Ethan's local workbench). Machine-specific security details are kept in the project's private notes, not in this public repo. SETUP_ONLY: no game content, publishing, uploads or spending.

**Rule:** VERIFIED_* requires a representative execution observed in this pass or in CI. Files, configs, listed MCP servers and screenshots alone do not count.

| Status | Count |
|---|---|
| VERIFIED_STRONG | 8 |
| VERIFIED_ACCEPTABLE | 7 |
| WEAK | 4 |
| PARTIAL | 6 |
| BROKEN | 1 |
| MISSING | 2 |
| OUTDATED | 1 |
| REDUNDANT | 1 |
| BLOCKED_EXTERNAL | 7 |
| INTENTIONALLY_EXCLUDED | 2 |

## Summary

| ID | Area | Capability | Status | Priority | Verification |
|---|---|---|---|---|---|
| [T01](#t01) | Agent tooling | Skills discoverable by Claude Code | VERIFIED_STRONG | P0 | Fresh Claude session init lists 19 repo skills; skills-sync gate step. |
| [T02](#t02) | Agent tooling | Skills discoverable by Codex | BLOCKED_EXTERNAL | P2 | Codex lists 19 repo skills. |
| [T03](#t03) | Agent tooling | Small permanent instructions shared by Claude and Codex | VERIFIED_STRONG | P2 | Fresh-session recall of imported content. |
| [T04](#t04) | Agent tooling | Tiered hooks (FAST_ON_EDIT, PRE_COMMIT, PRE_RELEASE) and publish/spend guards | VERIFIED_ACCEPTABLE | P1 | Self-test in the pre-commit gate and CI; live denials observed. |
| [T05](#t05) | Agent tooling | Permission rules apply on a fresh checkout | BLOCKED_EXTERNAL | P3 | Warnings observed; deny protection still covered by `Edit(weppy-project-sync/**)`. |
| [T06](#t06) | Agent tooling | Specialist subagents with explicit ownership | VERIFIED_ACCEPTABLE | P3 | Discovery observed. |
| [T07](#t07) | Agent tooling | Repo gate (fast / pre-commit / pre-release) | VERIFIED_STRONG | P1 | Executed locally in the cloud container and in CI. |
| [T08](#t08) | Agent tooling | Continuous integration | PARTIAL | P1 | Green CI on the PR head. |
| [T09](#t09) | Agent tooling | Pinned Luau toolchain | WEAK | P2 | `rojo --version` prints 7.7.0 from a new terminal. |
| [T10](#t10) | Agent tooling | Selene lint with the Roblox standard library | PARTIAL | P2 | Selene step green in CI. |
| [T11](#t11) | Agent tooling | Rojo projects build from a clean clone | PARTIAL | P2 | All four projects build in CI. |
| [L01](#l01) | Local workbench (PC) | Local workbench gate | BROKEN | P1 | `./.venv/Scripts/python.exe tools/check.py` passes on a quiet tree. |
| [L02](#l02) | Local workbench (PC) | Version control and rollback for the workbench | MISSING | P1 | `git log` shows a commit. |
| [M01](#m01) | MCP and Studio | Built-in Roblox Studio MCP connection | PARTIAL | P1 | `list_roblox_studios` and `get_studio_state` return the diagnostic place. |
| [M02](#m02) | MCP and Studio | Claude user-level Blender MCP | OUTDATED | P1 | `get_scene_info` answers from Claude in the repo. |
| [M03](#m03) | MCP and Studio | Blender MCP inside Codex | BLOCKED_EXTERNAL | P2 | `codex mcp get blender_workbench --json` lists the server after reload. |
| [M04](#m04) | MCP and Studio | Blender MCP add-on telemetry off | WEAK | P1 | Preference unchecked and saved. |
| [M05](#m05) | MCP and Studio | WEPPY bridge | REDUNDANT | P2 | Setting off, or a documented unique function. |
| [M06](#m06) | MCP and Studio | Codex global configuration | WEAK | P1 | Owner review. |
| [S01](#s01) | MCP and Studio | Studio testing modes (Test, Test Here, Run, Server & Clients) | BLOCKED_EXTERNAL | P1 | Console output and captures saved under `reports/studio/`. |
| [S02](#s02) | Scene authoring | SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune) | BLOCKED_EXTERNAL | P0 | Hashes and part counts equal the golden; two Ctrl+Z presses (one undo waypoint per scene) remove the generated scenes. |
| [S03](#s03) | Scene authoring | Scene-authoring API as data (buildings, props, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance) | VERIFIED_STRONG | P0 | Specs, fixture hashes, previews. |
| [S04](#s04) | Scene authoring | Measurement and player-scale helpers | VERIFIED_ACCEPTABLE | P2 | Specs. |
| [S05](#s05) | Scene authoring | Terrain and lighting applied in Studio | PARTIAL | P2 | Screen captures per lighting profile. |
| [P01](#p01) | Procedural generation | Seeded generators (dungeon, cave, arena, settlement) | VERIFIED_STRONG | P0 | Specs and fixture hashes. |
| [P02](#p02) | Procedural generation | Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance) | VERIFIED_ACCEPTABLE | P2 | Specs and fixture reports. |
| [P03](#p03) | Procedural generation | Determinism and manifests | VERIFIED_STRONG | P1 | Gate. |
| [B01](#b01) | Blender | Blender asset templates and QA reports (13 kinds) | VERIFIED_STRONG | P0 | Template runs on three bpy versions; CI matrix. |
| [B02](#b02) | Blender | Blender built-ins in the factory (Geometry Nodes, Asset Browser catalogs, texture baking, Rigify) | MISSING | P2 | n/a |
| [B03](#b03) | Blender | Preview renders for visual QA | VERIFIED_ACCEPTABLE | P2 | Renders reviewed in this pass. |
| [B04](#b04) | Blender | Round trip, Blender half (create, revise, export, reimport, diff, expectation) | VERIFIED_STRONG | P0 | Runs in pre-release gate and CI. |
| [B05](#b05) | Blender | Round trip, Studio half (3D Importer, then ImportInspector against the expectation) | BLOCKED_EXTERNAL | P0 | ImportInspector report passes for v1 and v2 and flags the revision diff. |
| [R01](#r01) | Inherited modules | Inherited pure-Luau modules (ReceiptLedger, CommerceCatalog, Lifetime, Motion, AudioMixer, AudioDirector, EffectsPool, MovementProfile, AnimationInspector and WorldInspector maths, UI logic, FaultQueue) | VERIFIED_ACCEPTABLE | P2 | Inherited suites and new specs pass in the gate. |
| [R02](#r02) | Inherited modules | Studio-bound inherited modules (NativeUI, NativeAudio, NativeEffects, RobloxReceiptAdapter, Effects, Observation, engine queries in WorldInspector) | WEAK | P2 | Fresh receipts with today's Studio version. |
| [D01](#d01) | Research | Fresh tooling research with select/reject decisions | VERIFIED_ACCEPTABLE | P3 | Decisions applied: built-in Studio MCP, Rokit over Aftman, mcp-for-blender 2.1.8, bpy 5.2 LTS in CI. |
| [D02](#d02) | Research | Deep observational game dossiers | PARTIAL | P3 | n/a |
| [D03](#d03) | Research | In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution) | BLOCKED_EXTERNAL | P2 | CI job green. |
| [X01](#x01) | Boundary | Publishing, asset upload, purchases, live products, ads | INTENTIONALLY_EXCLUDED | P0 | Self-test in gate and CI. |
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

**S02 SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** (BLOCKED_EXTERNAL)

1. In the clone: `rokit install`, then `rojo build fixtures/factory.project.json -o SETUP_ONLY_Factory_Diagnostic.rbxl`; open that file in Studio (unpublished).
2. From Claude Code in the repo: `list_roblox_studios`, then `execute_luau` with `return game:GetService("HttpService"):JSONEncode(require(game.ReplicatedStorage.Workbench.Pipeline.FactorySmoke).run(workspace))`.
3. Compare `building` and `dungeon` hash and part counts with `tests/golden/studio-smoke.json`.
4. Press Ctrl+Z twice in Studio (one waypoint per scene); `search_game_tree` should no longer find `SETUP_ONLY_SmokeBuilding` or `SETUP_ONLY_SmokeDungeon`.
5. Set `ServerScriptService.FactorySmoke.Enabled = true`, `start_stop_play` in Run mode, read `FACTORY_SMOKE` from `get_console_output`, stop play.
6. `screen_capture` from the manifest cameras for visual QA; save outputs under `reports/studio/`.

**B05 Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** (BLOCKED_EXTERNAL)

1. Authorise importing `SM_RoundTripMarker_v1.fbx` (neutral marker, no game content) in the unpublished diagnostic place.
2. In Studio use Import 3D with Scale Unit = Studs on the FBX and leave the model at the origin.
3. `execute_luau`: run `ImportInspector.inspect` on the imported model with `build/roundtrip/roblox_expectation_v1.json`; save the JSON to `reports/studio/`.
4. Repeat with v2 and run `ImportInspector.compareRevisions`.

**D03 In-engine test runner in CI (Jest Lua via Open Cloud Luau Execution)** (BLOCKED_EXTERNAL)

1. Decide whether a private, unpublished test universe and an Open Cloud key (Luau execution + place publish scopes) may be created for CI.


## Rows

### T01

**Skills discoverable by Claude Code** · Agent tooling · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** GitHub repo: 25 Roblox pass skills. Workbench: 7 Codex skills discovered.
- **ACTUAL STATE:** The repo held 25 loose `roblox-*/skill.md` files (lowercase name, escaped markdown, 11 genre checklists; 2 of them, multiplayer-state-fix and persistence-and-rewards-audit, were empty). Neither Claude nor Codex looked in those folders. Now 19 skills live in `.agents/skills/` and are mirrored to `.claude/skills/`.
- **EVIDENCE:** Commit 054af82 tree. A fresh headless Claude Code 2.1.289 session in this repo listed all 19 repo skills in its init event. `python3 tools/sync_skills.py --check` passes in the gate.
- **DEFECT:** No agent ever loaded the old guidance.
- **ROOT CAUSE:** Uploaded without the SKILL.md / skills-directory conventions.
- **IMPACT:** All earlier skill guidance was dead text.
- **FIX:** Rewrote into 19 focused skills (PURPOSE, TRIGGERS, INPUTS, CONTEXT, TOOLS, PROCEDURE, OUTPUTS, ACCEPTANCE, FAILURE, RELATED). Legacy checklists moved to `references/`; old root folders removed. The validator enforces frontmatter, name, description length, size and line endings.
- **VERIFICATION:** Fresh Claude session init lists 19 repo skills; skills-sync gate step.

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
- **ACTUAL STATE:** PostToolUse `fast_on_edit` (format, JSON, secrets, SKILL.md rules); PreToolUse `guard_bash` and `guard_mcp` deny publish/upload/Open Cloud writes/force-push to main and ask before asset-creating Studio tools, purchase prompts and DataStore writes. `tools/check.py` provides the pre-commit and pre-release tiers and installs a git pre-commit hook.
- **EVIDENCE:** `node tools/hooks/selftest.mjs` 13/13. Live: in this session the Bash guard denied a heredoc that contained a publish command, and the edit hook flagged an unformatted spec.
- **DEFECT:** Guards are string matchers. They stop accidental or obvious publish/upload calls, not deliberately obfuscated code.
- **ROOT CAUSE:** Hooks inspect text, not runtime behaviour.
- **IMPACT:** Residual risk if an agent is manipulated into obfuscating a publish call; deny rules and Studio's own prompts remain.
- **FIX:** Implemented; no hook can publish or spend (they only return allow/ask/deny).
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

**Specialist subagents with explicit ownership** · Agent tooling · VERIFIED_ACCEPTABLE · P3

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.claude/agents/`: roblox-engineer (packages, tests), technical-artist (Blender), qa-reviewer (read-only), researcher (docs/research). File ownership table in `docs/architecture.md`; Codex follows the same table via AGENTS.md.
- **EVIDENCE:** Fresh Claude session init lists all four agents; the session named the Blender owner correctly.
- **DEFECT:** Not yet exercised on a real parallel task.
- **ROOT CAUSE:** n/a
- **IMPACT:** Low.
- **FIX:** n/a
- **VERIFICATION:** Discovery observed.

### T07

**Repo gate (fast / pre-commit / pre-release)** · Agent tooling · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** Workbench `tools/check.py` 43 checks passed at 19:43Z.
- **ACTUAL STATE:** This repo's `tools/check.py` runs StyLua, JSON, secret scan, skills sync, hook self-test, Selene, Lune specs, fixture builds with golden hashes, and (pre-release) Blender templates, round trip and previews. Missing tools report SKIPPED, never PASS.
- **EVIDENCE:** `build/check-report.json` from the pre-release run in this pass (see PR).
- **DEFECT:** Selene is SKIPPED in the cloud (see T10).
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Executed locally in the cloud container and in CI.

### T08

**Continuous integration** · Agent tooling · PARTIAL · P1

- **PREVIOUS CLAIM:** None.
- **ACTUAL STATE:** `.github/workflows/factory.yml`: pre-commit job (Rokit toolchain, Rojo builds, gate incl. Selene) and a Blender job on bpy 5.1.2 (the PC's version) and 5.2.2 LTS.
- **EVIDENCE:** Workflow file; first run happens on the draft PR.
- **DEFECT:** Unverified until the first run is green.
- **ROOT CAUSE:** n/a
- **IMPACT:** First real test of `rokit install` and Selene's Roblox std in a clean environment.
- **FIX:** Drive the PR's CI to green.
- **VERIFICATION:** Green CI on the PR head.

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

**Selene lint with the Roblox standard library** · Agent tooling · PARTIAL · P2

- **PREVIOUS CLAIM:** Selene in the workbench gate.
- **ACTUAL STATE:** `selene generate-roblox-std` cannot fetch the API dump through the cloud proxy, so the gate reports SKIPPED here. CI runs it.
- **EVIDENCE:** Gate output `selene SKIPPED` with the reason.
- **DEFECT:** Not linted in the cloud container.
- **ROOT CAUSE:** Network policy of the cloud environment.
- **IMPACT:** Lint regressions would only show in CI.
- **FIX:** CI pre-commit job.
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

**Built-in Roblox Studio MCP connection** · MCP and Studio · PARTIAL · P1

- **PREVIOUS CLAIM:** Native Studio connection partially verified (sync/readback, Play, screenshots, simulated input).
- **ACTUAL STATE:** User-level `Roblox_Studio` entry is connected on the PC (Studio 0.741.19, `mcp.bat` present). The repo's `.mcp.json` adds the same command with hook gating. The cloud session cannot reach Studio.
- **EVIDENCE:** Local audit `claude mcp list`; config review against Roblox's documented command.
- **DEFECT:** No live tool call in this pass.
- **ROOT CAUSE:** Studio runs only on the PC.
- **IMPACT:** Studio-side claims below stay blocked until run there.
- **FIX:** Run the Studio proof steps (S02).
- **VERIFICATION:** `list_roblox_studios` and `get_studio_state` return the diagnostic place.

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
- **ACTUAL STATE:** The gate's "native" passes replay hashes of saved receipts; they do not open Studio. Per Roblox's docs, MCP `start_stop_play` covers Test and Run; Test Here and Server & Clients (F7) are started from the Studio UI. The skill documents which mode to use for what.
- **EVIDENCE:** Workbench `tools/check.py` source and receipts; research section 2.
- **DEFECT:** No live mode exercised in this pass; first-pass evidence is retained, not re-run.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Replication and play behaviour of new code is unproven.
- **FIX:** Run S02 in Run mode, and one Server & Clients session with 2 clients on the network fixture.
- **VERIFICATION:** Console output and captures saved under `reports/studio/`.

### S02

**SceneKit and ProcGen running inside Studio (string requires, ChangeHistoryService undo, Instance output identical to Lune)** · Scene authoring · BLOCKED_EXTERNAL · P0

- **PREVIOUS CLAIM:** WorldInspector queries and metadata-only content graphs; "no setup game world".
- **ACTUAL STATE:** `Apply.scene` records undo with ChangeHistoryService and creates Parts; it is executed in Lune against `@lune/roblox` instances. `FactorySmoke` builds the same two scenes in Studio and prints hashes to compare with `tests/golden/studio-smoke.json` (building 778d1d9a / 96 parts, dungeon 8494d161 / 108 parts).
- **EVIDENCE:** Lune specs and golden file. Studio half not run.
- **DEFECT:** Real-engine parity, undo and string `require` in Studio are unproven.
- **ROOT CAUSE:** Studio only on the PC.
- **IMPACT:** Core claim of the scene API in Studio is unproven.
- **FIX:** Run the steps on the PC.
- **VERIFICATION:** Hashes and part counts equal the golden; two Ctrl+Z presses (one undo waypoint per scene) remove the generated scenes.

### S03

**Scene-authoring API as data (buildings, props, paths, roads, fences, vegetation, terrain plans, lighting, cameras, seeds, dry-run, bounds, compare, style profiles, provenance)** · Scene authoring · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present (metadata graphs only).
- **ACTUAL STATE:** `packages/SceneKit`: plans are data, built from seeds and style profiles, validated (part budget, door/room clearance, stair rise and headroom, prop clipping and support), hashed into manifests, compared between revisions, and rendered.
- **EVIDENCE:** Lune specs (walls, floor holes, buildings 1-4 storeys x 3 roofs, Vec vs CFrame rotation parity, terrain, cameras, lighting). Five SETUP_ONLY fixture places build and validate with stable hashes. Blender previews caught and fixed a flipped gable roof, a mis-oriented wedge/ramp and a front camera that faced the back.
- **DEFECT:** Fixed: stair headroom of 1 stud at 3+ storeys (now alternating lanes); gable roof slopes inverted; ramp yaw; front camera.
- **ROOT CAUSE:** Rotation-convention errors, caught by validators and renders.
- **IMPACT:** n/a after fixes.
- **FIX:** Regression tests added for each.
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
- **FIX:** Apply the settlement fixture's terrain ops in the diagnostic place during S02 and capture it.
- **VERIFICATION:** Screen captures per lighting profile.

### P01

**Seeded generators (dungeon, cave, arena, settlement)** · Procedural generation · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** `packages/ProcGen`: BSP + MST + guaranteed loops, cellular-automata caves joined into one region, symmetric arenas with cover and spawn shields, road/lot settlements.
- **EVIDENCE:** Seed sweeps in specs; golden fixture hashes in the gate.
- **DEFECT:** Fixed during the pass: seed 303 had no loop, a cramped encounter room, 4-stud caves, 1-cell arena lanes.
- **ROOT CAUSE:** Generator parameters; caught by validators.
- **IMPACT:** n/a after fixes.
- **FIX:** minLoops guarantee, roomy encounter selection, 8-stud cave cells, cover gaps and protected spawn radius.
- **VERIFICATION:** Specs and fixture hashes.

### P02

**Layout validators (connectivity, reachability, redundant paths, dead ends, purposeless branches, spawn fairness, player scale, camera clearance, sightlines, encounter space, performance)** · Procedural generation · VERIFIED_ACCEPTABLE · P2

- **PREVIOUS CLAIM:** Not present.
- **ACTUAL STATE:** Implemented on the layout grid and room graph with machine-readable checks.
- **EVIDENCE:** Every fixture's checks in `build/fixtures/report.json`; failing cases in specs.
- **DEFECT:** Grid-level reasoning, not PathfindingService or Humanoid physics.
- **ROOT CAUSE:** Headless by design.
- **IMPACT:** A layout can pass the grid and still snag a character on geometry.
- **FIX:** Add a PathfindingService reachability probe to S02 later.
- **VERIFICATION:** Specs and fixture reports.

### P03

**Determinism and manifests** · Procedural generation · VERIFIED_STRONG · P1

- **PREVIOUS CLAIM:** Hash-drift blocking for planning records.
- **ACTUAL STATE:** Same seed gives the same manifest hash; canonical sorted JSON; golden hashes for fixtures and the Studio smoke.
- **EVIDENCE:** `fixture-hashes` gate step; CI.
- **DEFECT:** None found.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Gate.

### B01

**Blender asset templates and QA reports (13 kinds)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Blender direct authoring/export verified (68-triangle 2-bone fixture, 128px bake, FBX+GLB, reimport, turntable).
- **ACTUAL STATE:** `tools/blender/factory.py templates`: humanoid, npc, enemy, creature, weapon, prop, vehicle, building, modular kit, environment, material/rig/animation tests. Each writes .blend, FBX, GLB and `qa.json` (topology, normals, UVs, materials, pivot, scale, budgets, 4 influences, export reimport probe).
- **EVIDENCE:** All 13 pass on bpy 5.0.1, 5.1.2 and 5.2.2 LTS in this pass.
- **DEFECT:** Found: on Blender 5.1.2 (installed on the PC) and 5.2.2, an EXACT boolean adds an empty material slot, so building and modular templates failed material QA. Also fixed: FBX dropped animation clips, join lost material indices, mirror self-merge, inset shrank bounds.
- **ROOT CAUSE:** Blender 5.1+ boolean behaviour change; exporter defaults.
- **IMPACT:** The factory would have failed QA on Ethan's installed Blender.
- **FIX:** `ops.prune_material_slots` after applying modifiers; CI runs bpy 5.1.2 and 5.2.2.
- **VERIFICATION:** Template runs on three bpy versions; CI matrix.

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
- **ACTUAL STATE:** `render-manifest` renders SceneKit manifests from their cameras (Cycles CPU); templates render front and three-quarter views.
- **EVIDENCE:** `build/previews/*.png` reviewed; they exposed three geometry bugs.
- **DEFECT:** Small CPU renders; not Studio lighting.
- **ROOT CAUSE:** Headless.
- **IMPACT:** Look in Studio still needs S02 captures.
- **FIX:** n/a
- **VERIFICATION:** Renders reviewed in this pass.

### B04

**Round trip, Blender half (create, revise, export, reimport, diff, expectation)** · Blender · VERIFIED_STRONG · P0

- **PREVIOUS CLAIM:** Baseline/revision exports and reimport hashes.
- **ACTUAL STATE:** `roundtrip` builds SM_RoundTripMarker v1 and v2, exports FBX and GLB, reimports both, checks triangles, dimensions, pivot, front direction, materials and names, and writes `roblox_expectation_v*.json` for the Studio side.
- **EVIDENCE:** `build/roundtrip/roundtrip-report.json` pass on bpy 5.0.1, 5.1.2, 5.2.2.
- **DEFECT:** None open.
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Runs in pre-release gate and CI.

### B05

**Round trip, Studio half (3D Importer, then ImportInspector against the expectation)** · Blender · BLOCKED_EXTERNAL · P0

- **PREVIOUS CLAIM:** Blocked: no documented zero-upload import route.
- **ACTUAL STATE:** `packages/Pipeline/ImportInspector` checks mesh presence, scale (diagnoses metre/stud, Y/Z swap, cm), orientation, base pivot, front direction, collision fidelity and appearance, and compares revisions. Tested on mocks. Studio's 3D Importer can upload the mesh as an asset under Ethan's account (the first pass found no documented zero-upload route), which this setup may not do without his explicit go-ahead.
- **EVIDENCE:** Mock specs.
- **DEFECT:** The pipeline stops at the FBX until the import is authorised.
- **ROOT CAUSE:** Asset upload boundary plus Studio-only importer.
- **IMPACT:** The full Blender to Roblox loop is not proven.
- **FIX:** Ethan authorises one import of the neutral SM_RoundTripMarker into the unpublished diagnostic place.
- **VERIFICATION:** ImportInspector report passes for v1 and v2 and flags the revision diff.

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
- **ACTUAL STATE:** Excluded and enforced: hooks deny publish/upload commands and publishing Luau, and ask before asset creation, purchase prompts and DataStore writes.
- **EVIDENCE:** Hook self-test cases for each class.
- **DEFECT:** n/a
- **ROOT CAUSE:** n/a
- **IMPACT:** n/a
- **FIX:** n/a
- **VERIFICATION:** Self-test in gate and CI.

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
