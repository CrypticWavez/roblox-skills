---
name: roblox-studio-testing
description: Drive and observe Roblox Studio through the built-in Studio MCP server - inspect hierarchy/properties, edit scripts, run Luau, start/stop Test/Run, read console output, capture screenshots, simulate keyboard/mouse/character navigation - across the right testing mode (Test, Test Here, Run, multi-client Server & Clients, device emulation), and run engine probes (Studio command line or play session) that turn kit tier T3 claims into recorded evidence. Use for any in-Studio verification.
---

# Studio testing and control

## Purpose
Observe real Studio behaviour instead of assuming it, on the unpublished diagnostic place, with one owner per operation.

## Triggers
Any in-Studio verification: applying SceneKit output, the round-trip Studio half, the factory smoke test, engine probes for T3 kit modules (`tools/kit_tiers.py` lists PENDING ones), play-mode behaviour, replication, UI on devices, console errors.

## Inputs
The target place (must be the unpublished diagnostic place), the Rojo project to sync (`fixtures/*.project.json`), the scenario, the testing mode, and the expected observation.

## Required context
`docs/mcp.md` (server table, every Studio tool and how the guards treat it, operation ownership, safety gates). Tools are `mcp__Roblox_Studio__<tool>`; every call takes a `studio_id` from `list_roblox_studios`. For probes: `tests/engine/README.md` (line format, entries, play-session runs) and `docs/runtime-kits.md` section 7 (probe names, owner prefixes, registries).

## Tools
| Need | Owner |
|---|---|
| Source of truth for code | Files + Rojo (`rojo serve` / `rojo build`); never hand-edit synced scripts in Studio |
| Hierarchy / properties | `search_game_tree`, `inspect_instance` |
| Script read/search/edit (unsynced places) | `script_read`, `script_search`, `script_grep`, `multi_edit` |
| Construct / run code | `execute_luau` (SceneKit, ImportInspector, diagnostics) |
| Play control and state | `start_stop_play`, `get_studio_state` |
| Logs | `get_console_output` |
| Visuals | `screen_capture` |
| Input | `user_keyboard_input`, `user_mouse_input`, `character_navigation` |
| Assets / generation | `search_asset` (search only); `insert_asset`, `generate_*`, `upload_image`, `store_image` create assets or use quota under the owner's account, so the hooks ask first |
| WEPPY bridge | only for a function it is verified to add (none verified yet) |
| Engine probes, command line | `python3 tools/studio_run.py --list`, `--probe <name> [--build]`: Studio `--task RunScript` on the local `build/kits.rbxl` (refuses `--placeId`, `--universeId` and places outside `build/`); writes `reports/engine/<probe>.json` (engine-report/1) |
| Engine probes, play session | Workspace attribute `SETUP_ONLY_KitFixture = "kitsmoke"` arms `fixtures/kits/{server,client}/kitsmoke_Runner.*`; record the saved Output with `studio_run.py --probe <name> --from-output build/<file>.txt` |
| Probe harness | `Pipeline/KitSmoke` merges every `fixtures/kits/<side>/*_probes.luau` registry and adds `kitsmoke_registries`; `tests/engine/<probe>.luau` are the RunScript entries; `GameKit/DebugCommands` gives developer commands that run only on the diagnostic place |
| Tier evidence | `python3 tools/kit_tiers.py` joins every `-- @tier` header with `reports/engine/` (PASS, FAIL, PENDING, BLOCKED_EXTERNAL) |

## Procedure
1. `list_roblox_studios`; pick the **unpublished diagnostic place** explicitly. Refuse protected targets (published games, Cryptic's Realm, Noobs VS Zombies) unless the owner names them for that task.
2. Inspect before changing (`get_studio_state`, `search_game_tree`).
3. Choose the mode: **Test (F5)** client and server with your avatar; **Test Here**; **Run (F8)** server simulation without an avatar (world, physics, NPC logic); **Server & Clients (F7)**, up to 8 clients, for replication, ownership, remotes and leave/join; the Device emulator for touch and UI layout. Replication bugs need multi-client.
4. Act with `execute_luau` (idempotent scripts that return JSON) or input simulation; then `get_console_output` and `screen_capture`.
5. Stop play; record mode, Studio version, place, inputs, outputs and screenshots under `reports/`.
6. Factory smoke: enable `ServerScriptService.FactorySmoke` (from `fixtures/factory.project.json`), press Run, compare the printed `FACTORY_SMOKE` hashes with `tests/golden/studio-smoke.json`.
7. Engine probes (owner's PC only; Studio is absent in this container and CI):
   - Edit-mode probes: `python3 tools/studio_run.py --probe kitsmoke_all --build`, then each own entry (`--probe perf_capture`).
   - Play-session probes (client registries, anything that needs a running simulation): open `build/kits.rbxl`, set `SETUP_ONLY_KitFixture` to `kitsmoke`, press Play (or F7 for replication), save the Output under `build/`, then record it with `--from-output`.
   - Then `python3 tools/kit_tiers.py` to refresh `reports/kit-tiers.json`.
   - Before Studio, prove the probes load with `lune run tools/lune/kit_smoke.luau`; that is Lune evidence and never goes under `reports/engine/`.

## Outputs
Console excerpts, returned JSON and captures, plus a report under `reports/` naming mode, Studio version and place. Probe runs: `reports/engine/<probe>.json` (status, counts, failures, commit, entry and place sha256; `source.route` is `studio-cli` or `from-output`).

## Acceptance
Every claim cites a console excerpt, returned JSON or capture from this session, taken in the mode the behaviour needs. A T3 module is verified only by a PASS `reports/engine/` report from Studio for its probe; Lune fakes, BLOCKED_EXTERNAL and PENDING are not verification.

## Failure
- No studio listed: Studio is closed or MCP is disabled (Assistant > `...` > Manage MCP Servers).
- Every read prompts: the workspace trust prompt or project MCP approval is still pending (`CLAUDE.md`).
- A hook denied or asked: publishing, uploads, purchases and DataStore writes are gated on purpose (`docs/mcp.md`); do not work around them.
- Hangs: stop play and re-run with smaller scripts. Never retry a mutating call blindly; inspect state first.
- `studio_run.py` exit 3 BLOCKED_EXTERNAL: no Studio on this machine; it writes `build/engine/<probe>.json` only. Run it on the owner's PC.
- `studio_run.py` FAIL: a failed check, a missing `ENGINE_DONE` line or counts that disagree with the check lines. Read `failures` in the report. A probe that needs `RunService:IsRunning()` gets no frame data in Edit mode; run it in a play session.
- UNVERIFIED until the first owner run: whether the Studio command line needs a logged-in user, and that `RunScript` runs in Edit mode.
- `kitsmoke_registries` fails: a registry did not load, is not a table, or two registries register the same probe name (the detail names the registry and probe).

## Related
visual-qa, roblox-scene-authoring, blender-roblox-roundtrip, roblox-luau-testing.
