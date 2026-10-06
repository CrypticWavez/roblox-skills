# MCP servers: purpose, ownership, safety

## Audit per server
| | `Roblox_Studio` (built-in Studio MCP) | `blender` (`mcp-for-blender` 2.1.8; renamed from `blender-mcp`) | WEPPY bridge | GitHub |
|---|---|---|---|---|
| Why | inspect, edit, run, play, capture, input on the diagnostic place | scene inspection and interactive ops; reproducible work stays in `tools/blender/factory.py` | pre-existing sync bridge for another project | PRs, CI |
| Client config | Claude `.mcp.json`; Codex `.codex/config.toml` (same command, checked by the self-test): `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat` (Windows only) | same two files: `uvx mcp-for-blender==2.1.8`, `DISABLE_TELEMETRY=true` | not configured in this repo (user level) | client integration / `gh`, not in this repo |
| Tools | 26, classified in [Studio MCP tools](#studio-mcp-tools-26) | 14: `get_scene_info`, `look`, `get_addon_status`, `disable_telemetry`, `execute_blender_code`, `generate_3d`, `search_assets`, `import_asset`, `record_trajectory_feedback`, `search_mentions`, `viewport_*`/`open_viewport` (UI); classes in [Blender MCP tools](#blender-mcp-tools) | unknown | PR/issue/branch/file reads and writes |
| Permissions | reads, code, play and input: no prompt (code and input are content-checked); asset, quota, network and `subagent`: ask | reads and bpy: no prompt (bpy content-checked); `generate_3d`, `search_assets`, `import_asset`: denied; `record_trajectory_feedback`: ask | none granted | reads pass; writes ask wherever `guard_mcp` sees them ([Other MCP servers](#other-mcp-servers)) |
| Ports | none of its own: stdio launcher to a running Studio | stdio server -> add-on socket `localhost:9876` (`BLENDER_HOST`/`BLENDER_PORT`; 9877 for the workbench diagnostic copy) | HTTP loopback :3002 (seen at audit) | none |
| Network | Studio talks to Roblox as the signed-in account; `http_get` and the asset tools reach Roblox services | `uvx` fetches the pinned package; the denied asset/generation tools would reach Poly Haven, Sketchfab, Poly Pizza, Hyper3D, Hunyuan3D, Tripo; telemetry off | unknown | HTTPS github.com |
| Auth | the signed-in Studio session (the owner's account) | **none** on the socket: any local process can send code (vendor note in `safe_mode.py`); third-party keys live in add-on prefs, never in the repo | **unknown** | OAuth |
| Telemetry | Roblox's own | server: off (`DISABLE_TELEMETRY=true`; observed `telemetry enabled: False` on 2.1.8); add-on: turn off in its preferences | **unknown** | n/a |
| Overlap | Rojo owns synced source (`multi_edit` on a Rojo-managed script is overwritten); `screen_capture` vs skill `visual-qa` | `tools/blender/factory.py` + `bkit` for anything reproducible | Rojo / the factory's own sync | `git` CLI |
| Failure modes | Studio not running or the wrong place selected (protected: published games); non-Windows client cannot start `cmd.exe`; Luau errors land in the console | add-on missing or older protocol (1.6.4 server: `CONNECTION_CLOSED`); two clients on one Blender; first `uvx` run needs network | 0 plugin clients at last audit | token expiry |
| Health check | `list_roblox_studios` lists the diagnostic place | `get_addon_status`, then `get_scene_info` | none defined | `gh auth status` |

WEPPY unknowns stay unknown: its folder is outside this repo's ownership and read-only, so its auth, telemetry and tools were not inspected. Decision: the factory does not use it; keep it only for a verified unique function, after the owner confirms its auth.

Not added (needs-based, 2026-10-06): browser control (Chrome DevTools MCP, Playwright MCP): no web UI here, and a logged-in browser reaches the Creator Dashboard, which can publish and spend; both projects state they are not a security boundary, and Chrome DevTools MCP sends usage statistics by default. Filesystem MCP: redundant with the clients' file tools and its `write_file`/`edit_file`/`move_file` would bypass the edit hook. Docs/search MCP: redundant with built-in web search/fetch. Rejected earlier: `Roblox/studio-rust-mcp-server` (archived 2026-04-03, superseded by the built-in server), third-party Studio MCPs (unofficial, broader surface), `blender-mcp==1.6.4` (outdated protocol).

## Studio MCP tools (26)
The tool list on create.roblox.com/docs/studio/mcp (page updated 2026-10-02; read for `docs/research/agent-tooling-connectors-2026-10.md`). `set_active_studio` was removed on 2026-08-19. Decisions come from `tools/hooks/guard_mcp.mjs`; the self-test checks that all 26 are classified and that `.codex/config.toml` prompts exactly for the ask tools.

| Class | Tools | Notes |
|---|---|---|
| read: no prompt, no content check | `list_roblox_studios`, `get_studio_state`, `search_game_tree`, `inspect_instance`, `script_read`, `script_search`, `script_grep`, `get_console_output`, `screen_capture`, `skill`, `wait_job_finished`, `search_asset` | `skill` returns Roblox's built-in Assistant skills (`rbx-debug`, `rbx-perf-profiling`, `rbx-device-simulator-lua`, ...). `wait_job_finished` only polls a job an asked `generate_*` call started. `search_asset` searches the Creator Store and inserts nothing, so a query that names write APIs passes. |
| code: no prompt, content-checked | `execute_luau`, `multi_edit` | see [Safety gates](#safety-gates) |
| play and input: no prompt, content-checked | `start_stop_play`, `user_keyboard_input`, `user_mouse_input`, `character_navigation` | |
| ask | `insert_asset`, `upload_image`, `store_image`, `generate_mesh`, `generate_material`, `generate_procedural_model` | create assets or use generation quota under the owner's account |
| ask | `http_get` | fetches a URL through Studio |
| ask | `subagent` | starts Roblox's own `explore` or `playtest` agent inside Studio. The repo hooks never see the tools that agent calls, and which tools it may call (`insert_asset`, `generate_*`) is not documented (UNVERIFIED). Approve only with the diagnostic place selected and a prompt you have read. |
| any other name | content checks, then ask | Roblox adds tools without notice: classify a new one in `guard_mcp.mjs`, `.codex/config.toml`, the self-test's `STUDIO_TOOLS` and this table. |

In Codex every ask tool has `approval_mode = "prompt"` and the guard turns the ask into a deny. In Claude, `.claude/settings.json` allows the 9 original reads and the 6 code/play/input tools and asks for the 6 asset tools; `skill`, `wait_job_finished`, `search_asset`, `http_get` and `subagent` are not listed yet, so Claude prompts for them until the owner applies the [change set](#owner-step-proposed-claudesettingsjson-changes) (the guard already asks for `http_get` and `subagent`).

## Blender MCP tools
`guard_mcp` treats every server named `blender*` (`blender`, `blender_lab`, the workbench copy) the same way.

| Class | Tools | Why |
|---|---|---|
| deny (Claude and Codex) | `generate_3d`, `search_assets`, `import_asset`; any `generate_*`, `import_*`, `download_*` or `poll_*` tool; the 1.x Poly Haven, Sketchfab, Poly Pizza, Hyper3D, Hunyuan3D and Tripo search and preview tools | `generate_3d` spends paid credits or quota (Hyper3D Rodin, Hunyuan3D, Tripo). `search_assets`/`import_asset` use the Poly Haven API, whose terms forbid "commercial profit" use, and Sketchfab and Poly Pizza models with per-model licences (`docs/research/visual-audio-assets-2026-10.md`). Assets come in as CC0 with recorded provenance (skill `roblox-asset-intake`). `.codex/config.toml` also lists the three in `disabled_tools`, so Codex never offers them to the model, even while its hooks are untrusted. |
| ask | `record_trajectory_feedback` | sends the session trajectory to the vendor |
| read: no prompt | `get_scene_info`, `look`, `get_addon_status`, `disable_telemetry`, `get_*_status`, `viewport_*`, `open_viewport`, `search_mentions` | |
| code: content-checked | `execute_blender_code` and its variants (`execute_blender_code_for_cli` in Blender Lab) | deny Python that starts a publishing tool or writes to a Roblox web API; ask for network or shell modules and dynamically built code |
| any other name | ask | Blender Lab's inspection tools (`get_blendfile_summary_*`, `jump_to_*`, `render_*`, docs search) ask until its trial classifies them |

## Other MCP servers
Claude Code also loads claude.ai connectors (subscription login) and plugin servers; Codex loads ChatGPT apps (`mcp__codex_apps__<app>__<tool>`) and plugin servers. None of them is configured by this repo.
- `guard_mcp`: tools of a server whose name contains `github` pass when they only read (`get_*`, `list_*`, `search_*`, `*_read`, `actions_get`/`actions_list`); every other tool of every other server asks ("an MCP server the factory does not configure"), and Codex turns that into a deny.
- Codex: the `^mcp__.*$` matcher in `.codex/hooks.json` sends every MCP tool through `guard_mcp`.
- Claude: the PreToolUse matcher in `.claude/settings.json` covers only `Roblox_Studio` and `blender*`, so other servers run with Claude's own permission prompts and no repo guard until the owner chooses one of the options in the [change set](#owner-step-proposed-claudesettingsjson-changes).

## Operation ownership
Studio: see the table in `.agents/skills/roblox-studio-testing/SKILL.md`. Rojo owns synced source; Studio MCP never edits Rojo-managed scripts. Blender: bpy scripts for reproducible work, MCP for interactive inspection. One client per Blender instance.

## Safety gates
`tools/hooks/guard_bash.mjs` and `guard_mcp.mjs`, wired by `.claude/settings.json` and `.codex/hooks.json`.
- Ask: the Studio ask tools above and Blender's `record_trajectory_feedback`; Luau that writes DataStores/MemoryStores or prompts a product, pass, bundle, asset or commerce purchase, a subscription cancellation or real-world commerce; Luau that does the same through a kit adapter that hides the API name: `CommerceRoblox.prompt` (the product could be a subscription, which the guard cannot tell), LeaderboardRoblox `submit`/`remove` or `writes = true`, LiveBoardRoblox with LiveBoard `submit`/`remove`, MemoryQueueRoblox `push`/`ack`/`cycle`, the PlayerData `dataStoreBackend`/`profileStoreBackend` or `allowStudioDataStores`, `RobloxReceiptAdapter.store`; Blender Python that imports network/shell modules or builds code dynamically. Approve only for the diagnostic place.
- Deny, MCP: Luau that publishes, uploads or creates assets/places, completes a purchase (`Perform*Purchase`), prompts a purchase Studio does not reliably mock (`PromptSubscriptionPurchase`, `PromptRobloxSubscriptionPurchase`, `PromptPremiumPurchase`, `PromptRobuxTransfer*`, `PromptBulkPurchase`: a test could charge a real account; `docs/research/release-monetization-analytics-2026-10.md`), or sends an HttpService write to a Roblox web API; Blender's paid and licence-risk tools; Blender Python that starts a publishing tool or writes to a Roblox web API.
- Deny, shell: publish/upload commands (`rojo upload`, `mantle deploy`, tarmac and asphalt uploads, `rbxcloud` except `get*`/`list*`/`help`); package-registry writes and logins (`wally publish/login/logout`; `pesde publish/yank/deprecate` and `pesde auth login/logout/token`; `install`, `add`, `update`, `search` and `pesde auth whoami` pass), also behind runners, wrappers, xargs and inline scripts; write requests to Roblox web APIs (curl, wget, httpie, PowerShell, inline scripts; option prefixes resolved); force pushes or deletions of main/master in any spelling (prefixes, `:`/`+:`, mirror or matching config); any command line over 64 KiB; writes into `weppy-project-sync/` or into an [owner record](#owner-records). On a line that names one of these protected paths, everything except known read-only commands is denied (interpreters and anything fed by a pipe included, so edit docs that mention them with the Edit tool).
- `execute_luau` and `multi_edit` run without a prompt (decision): they are the core of diagnostic Studio work, and a prompt per call trains approving without reading. What guards them: `guard_mcp` checks every string in the tool input, whatever the field is called (`multi_edit` edits included); work targets the unpublished diagnostic place, where DataStores need a published experience and product and pass purchases are test purchases; Rojo source wins; ChangeHistory undo. Residual: text matching misses obfuscated code (`loadstring`, built strings); calls through kit adapters are matched by name, so renamed requires are a residual, and so is a module already in the place (a probe registry, a script) that the code only runs.
- Blender safe mode (`BLENDER_MCP_SAFE_MODE=1`) stays off: it blocks `sys` and `open`, which interactive `bkit` calls need; the guard asks for network/shell/dynamic code instead.
- `node tools/hooks/selftest.mjs` (pre-commit gate) feeds known-good and known-bad events to both guards, directly and through the `.codex/hooks.json` commands, and checks the Codex rules and config against them; the exact patterns live in the guard scripts.
- Never expose MCP ports beyond loopback; never pass secrets through MCP arguments.

## Owner records
`release/owner-*.json` at any depth (a game repo's `release/`, the starter template's copy) holds release sign-offs and publish exceptions. Only the owner writes them; the release check reads them.
- Shell (`guard_bash`, Claude and Codex): on a line that names an owner record, a glob that could expand to one, or a release folder it enters (`cd release`, `env -C release`), each command must be read-only. Reading (`cat`, `jq`), copying elsewhere, `git diff/log/show`, `git add` and `git commit` pass; redirections, `tee`, `cp`/`mv` into the record or its folder, `sed -i`, `rm`, interpreters that name it, `git checkout/restore` of it and `git apply/am` are denied.
- File edits: Codex `apply_patch` (and Claude-style `Edit`/`Write`/`MultiEdit`/`NotebookEdit` events) go to `guard_bash` through `.codex/hooks.json`, which denies a patch that adds, updates, deletes or moves onto a record. Claude's own file tools reach the guard only after the owner adds the Edit/Write matcher from the change set below; until then `.claude/settings.json` has no rule for these files.
- Codex rules: `.codex/rules/factory.rules` forbids the plain forms on the documented record `release/owner-exceptions.json` (`tee`, `rm`, `touch`, `truncate`, `shred`, `unlink`, `git checkout/restore`). Prefix rules cannot glob, so other names rely on the hook.
- Copies below a `fixtures/` or `tests/` folder of the working directory are test data and pass (paths are resolved first, so `fixtures/../release/owner-x.json` is still a record).
- Residual: a symlink that points a fixture path at a real release folder, scripts run from files, and paths built at run time.

## Codex
Checked with codex-cli 0.160.1, 2026-10-06.
- Files:
  - `.codex/config.toml`: on-request approvals, workspace-write sandbox, no network. It declares the `.mcp.json` servers, with `approval_mode = "prompt"` on every tool `guard_mcp` asks for, and Blender's `disabled_tools` for the three it denies (the key parses in 0.160.1, checked with `codex mcp get`; that Codex then hides the tools from the model is UNVERIFIED without a live server).
  - `.codex/hooks.json` has three PreToolUse matchers, each run with `--client=codex`:
    - `^Bash$` -> `guard_bash.mjs`;
    - `^(apply_patch|Edit|Write|MultiEdit|NotebookEdit)$` -> `guard_bash.mjs`;
    - `^mcp__.*$` -> `guard_mcp.mjs`. This covers every MCP tool, including ChatGPT apps and plugins.
  - `.codex/rules/factory.rules`: prefix rules that forbid or prompt for plain publish, registry, owner-record and force-push commands.
- Setup: trust the project (Codex loads `.codex/` only for trusted projects), then run `/hooks` and trust each hook (a hook is skipped until its current hash is trusted, so re-trust after this file changes). Health: `codex mcp list`; `codex execpolicy check --rules .codex/rules/factory.rules -- rojo upload x` returns `forbidden`; `CODEX_BIN=codex node tools/hooks/selftest.mjs` compares every rule decision with Codex's.
- Codex hooks cannot ask (an `ask` is reported as unsupported and the tool runs), so the guards turn every ask into a deny under Codex. Those actions need Claude Code or the owner.
- Residual risk (PARTIAL parity):
  - Nothing applies until the project and its hooks are trusted. An untrusted project or untrusted hooks run with none of this.
  - A hook that errors, times out or cannot find `node` lets the call run. Claude fails the same way on timeouts.
  - Whether Codex fires PreToolUse for `apply_patch` under that tool name, and with which input fields, is UNVERIFIED. The guard reads any path field and any `*** Begin Patch` text. If the hook does not fire, `apply_patch` edits to owner records are unguarded in Codex.
  - In a linked git worktree, Codex reads the main checkout's `.codex/hooks.json`.
  - The Windows `commandWindows` path is unverified.
  - CLI flags (`--dangerously-bypass-approvals-and-sandbox`, `--sandbox danger-full-access`) override the project config.
  - Rules see only plain command lines.
- Docs (accessed 2026-10-06, redirected from developers.openai.com/codex): learn.chatgpt.com/docs/hooks, /docs/agent-configuration/rules, /docs/config-file/config-reference, /docs/config-file/config-advanced, /docs/extend/mcp.

## Owner step: proposed `.claude/settings.json` changes
Agents may not edit the settings that govern them, so these are for the owner to apply by hand. Nothing below is applied yet. After editing, run `node tools/hooks/selftest.mjs`: it fails if a listed MCP rule disagrees with `guard_mcp`. `tools/new_project.py` copies this file into new game repos.

The changes:
1. `permissions.allow`: add `mcp__Roblox_Studio__skill`, `mcp__Roblox_Studio__wait_job_finished` and `mcp__Roblox_Studio__search_asset`. They are reads, and Claude prompts for them today.
2. `permissions.ask`: add `mcp__Roblox_Studio__http_get` and `mcp__Roblox_Studio__subagent`, which the guard already asks for.
3. `permissions.deny`:
   - Add `mcp__blender__generate_3d`, `mcp__blender__import_asset` and `mcp__blender__search_assets`. These hold even if `node` or the hook fails.
   - Add `Bash(asphalt upload:*)`.
   - Add `Edit(release/owner-*.json)`. A bare path in a permission rule is matched from the working directory, so it covers the `release/` folder of the repo Claude starts in and not fixture copies. The hook in item 4 covers every depth.
   - Remove the redundant `Write(weppy-project-sync/**)`, since Edit rules cover every file tool (gap-matrix T05).
4. `hooks.PreToolUse`:
   - Add a matcher `Edit|Write|MultiEdit|NotebookEdit` that runs `node "$CLAUDE_PROJECT_DIR/tools/hooks/guard_bash.mjs"`. It applies the fixture-aware owner-record and `weppy-project-sync/` path checks to Claude's file tools.
   - Raise the hook timeouts from 5 to 10 seconds to match Codex.
5. The surface of claude.ai connectors and plugins. Leaving it as it is is also a valid choice. Two options, which can be combined:
   - **Option A**: `"disableClaudeAiConnectors": true` at the top level stops claude.ai connectors from loading in Claude Code sessions in this repo (env equivalent `ENABLE_CLAUDEAI_MCP_SERVERS=false`). The trade-off is that connectors the owner uses on purpose (Drive, GitHub, Linear) disappear from factory sessions.
   - **Option B**: widen the MCP matcher from `mcp__Roblox_Studio__.*|mcp__blender.*` to `mcp__.*`, so every MCP tool goes through `guard_mcp` (GitHub reads pass; every other unknown tool asks). In hosted Claude Code sessions (web, remote), the harness's own MCP servers would then ask on every call as well; there, keep the narrow matcher or list those servers' read tools in `allow`.

Items 1 to 4 as JSON (the existing entries are elided):
```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/tools/hooks/guard_bash.mjs\"", "timeout": 10 }] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [{ "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/tools/hooks/guard_bash.mjs\"", "timeout": 10 }] },
      { "matcher": "mcp__Roblox_Studio__.*|mcp__blender.*", "hooks": [{ "type": "command", "command": "node \"$CLAUDE_PROJECT_DIR/tools/hooks/guard_mcp.mjs\"", "timeout": 10 }] }
    ]
  },
  "permissions": {
    "allow": ["...", "mcp__Roblox_Studio__skill", "mcp__Roblox_Studio__wait_job_finished", "mcp__Roblox_Studio__search_asset"],
    "ask": ["...", "mcp__Roblox_Studio__http_get", "mcp__Roblox_Studio__subagent"],
    "deny": ["Bash(rojo upload:*)", "Bash(asphalt upload:*)", "Edit(weppy-project-sync/**)", "Edit(release/owner-*.json)", "mcp__blender__generate_3d", "mcp__blender__import_asset", "mcp__blender__search_assets"]
  }
}
```
