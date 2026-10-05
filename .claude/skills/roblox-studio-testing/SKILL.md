---
name: roblox-studio-testing
description: Drive and observe Roblox Studio through the built-in Studio MCP server - inspect hierarchy/properties, edit scripts, run Luau, start/stop Test/Run, read console output, capture screenshots, simulate keyboard/mouse/character navigation - across the right testing mode (Test, Test Here, Run, multi-client Server & Clients, device emulation). Use for any in-Studio verification.
---

# Studio testing and control

## Purpose
Observe real Studio behaviour instead of assuming it, on the unpublished diagnostic place, with one owner per operation.

## Triggers
Any in-Studio verification: applying SceneKit output, the round-trip Studio half, the factory smoke test, play-mode behaviour, replication, UI on devices, console errors.

## Inputs
The target place (must be the unpublished diagnostic place), the Rojo project to sync (`fixtures/*.project.json`), the scenario, the testing mode, and the expected observation.

## Required context
`docs/mcp.md` (server table, operation ownership, safety gates). Tools are `mcp__Roblox_Studio__<tool>`; every call takes a `studio_id` from `list_roblox_studios`.

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
| Assets / generation | `search_asset` (search only); `insert_asset`, `generate_*`, `upload_image`, `store_image` create assets or use quota under Ethan's account, so the hooks ask first |
| WEPPY bridge | only for a function it is verified to add (none verified yet) |

## Procedure
1. `list_roblox_studios`; pick the **unpublished diagnostic place** explicitly. Refuse protected targets (published games, Cryptic's Realm, Noobs VS Zombies) unless Ethan names them for that task.
2. Inspect before changing (`get_studio_state`, `search_game_tree`).
3. Choose the mode: **Test (F5)** client and server with your avatar; **Test Here**; **Run (F8)** server simulation without an avatar (world, physics, NPC logic); **Server & Clients (F7)**, up to 8 clients, for replication, ownership, remotes and leave/join; the Device emulator for touch and UI layout. Replication bugs need multi-client.
4. Act with `execute_luau` (idempotent scripts that return JSON) or input simulation; then `get_console_output` and `screen_capture`.
5. Stop play; record mode, Studio version, place, inputs, outputs and screenshots under `reports/`.
6. Factory smoke: enable `ServerScriptService.FactorySmoke` (from `fixtures/factory.project.json`), press Run, compare the printed `FACTORY_SMOKE` hashes with `tests/golden/studio-smoke.json`.

## Outputs
Console excerpts, returned JSON and captures, plus a report under `reports/` naming mode, Studio version and place.

## Acceptance
Every claim cites a console excerpt, returned JSON or capture from this session, taken in the mode the behaviour needs.

## Failure
- No studio listed: Studio is closed or MCP is disabled (Assistant > `...` > Manage MCP Servers).
- Every read prompts: the workspace trust prompt or project MCP approval is still pending (`CLAUDE.md`).
- A hook denied or asked: publishing, uploads, purchases and DataStore writes are gated on purpose (`docs/mcp.md`); do not work around them.
- Hangs: stop play and re-run with smaller scripts. Never retry a mutating call blindly; inspect state first.

## Related
visual-qa, roblox-scene-authoring, blender-roblox-roundtrip, roblox-luau-testing.
