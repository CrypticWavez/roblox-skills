# MCP servers: purpose, ownership, safety

| Server | Why | Client config | Transport / ports | Auth | Telemetry | Health check |
|---|---|---|---|---|---|---|
| `Roblox_Studio` (built-in Studio MCP) | inspect/edit/run/play/capture/input in Studio | `.mcp.json` (Claude, Windows: `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat`); Codex: same command in `~/.codex/config.toml` `[mcp_servers.Roblox_Studio]` | stdio launcher -> running Studio; no user port | local Studio session (acts as Ethan's account) | Roblox's | `list_roblox_studios` returns the diagnostic place |
| `blender` (`mcp-for-blender` 2.1.8, ahujasid; renamed from `blender-mcp`) | scene inspection, object/material ops, `execute_blender_code`, viewport screenshot, export | `.mcp.json` `uvx mcp-for-blender==2.1.8`, `DISABLE_TELEMETRY=true`; workbench Codex uses the vendored copy on port 9877 | stdio server -> add-on socket on 127.0.0.1:9876 (9877 workbench diagnostic) | **none** (loopback only) | on by default in the add-on; turn off in add-on prefs and env | `get_scene_info` |
| WEPPY bridge | pre-existing sync bridge on :3002 | user-level | HTTP loopback :3002 | unknown | unknown | 0 plugin clients at last audit; keep only for a verified unique function |
| GitHub | PRs/CI | Claude GitHub integration | HTTPS | OAuth | n/a | — |

Rejected: `Roblox/studio-rust-mcp-server` (archived 2026-04-03, superseded by the built-in server), third-party Studio MCPs (unofficial, broader surface), `blender-mcp==1.6.4` user config (outdated; mismatched with the 2.1.8 add-on protocol — the local audit saw `CONNECTION_CLOSED`).

## Operation ownership
Studio: see the table in `.agents/skills/roblox-studio-testing/SKILL.md`. Rojo owns synced source; Studio MCP never edits Rojo-managed scripts. Blender: bpy scripts (`tools/blender/factory.py`) for reproducible work; MCP for interactive inspection. One client per Blender instance.

## Safety gates (enforced by `.claude/settings.json` + `tools/hooks/guard_mcp.mjs`)
- Allowed without prompt: read-only Studio tools, `execute_luau`, play/input tools.
- Ask: `insert_asset`, `upload_image`, `store_image`, `generate_*`, `http_get`, Luau that writes DataStores or prompts purchases.
- Deny: Luau that publishes/uploads (`SavePlaceAsync`, `CreatePlaceAsync`, `CreateAssetAsync`, `PublishAsync`…), Bash publish/upload commands, Open Cloud write calls, force-push to main.
- Never expose MCP ports beyond loopback; never pass secrets through MCP arguments.

## Local machine notes (audit 2026-10-05)
- Studio 0.741.19 with `%LOCALAPPDATA%\Roblox\mcp.bat` present; Blender 5.1.2; vendored mcp-for-blender 2.1.8 (protocol 13).
- Fix: update the user-level Claude `blender` entry from `uvx blender-mcp==1.6.4` to `uvx mcp-for-blender==2.1.8`.
- `aftman` precedes `rokit` on PATH, so bare `rojo` resolves to Aftman and fails; put `~/.rokit/bin` first or remove Aftman.
- The global Codex configuration grants high trust outside this repo; details are in the private local-audit note, not here.
