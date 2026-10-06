# Roblox Game-Production Workbench: Tooling Research (verified 2026-10-05)

Method: primary sources fetched 2026-10-05 (create.roblox.com, devforum.roblox.com announcements, GitHub repo pages/raw READMEs, PyPI JSON API, crates.io API, code.claude.com docs, learn.chatgpt.com (Codex docs; developers.openai.com/codex now 302-redirects there), agentskills.io, blender.org, extensions.blender.org). GitHub API (`gh`) was blocked in this sandbox, so GitHub release tags were read via repo pages and crates.io; where those disagree it is flagged. Anything not confirmed from a primary source is marked **UNVERIFIED**. Nothing was installed.

Back-fill 2026-10-06: price, last update, maintenance and licence for the candidates below are in section 10, with corrections. Topics not covered here (UI, animation, VFX, terrain, context/code index, visual QA, performance, security, CI/CD, extra MCP servers) are in `tooling-2026-10-addendum.md`.

---

## 1. Roblox Studio MCP

### 1a. Built-in Studio MCP server (SELECT, primary integration)
- Source: https://create.roblox.com/docs/studio/mcp ; announcement https://devforum.roblox.com/t/assistant-updates-studio-built-in-mcp-server-and-playtest-automation/4474643 (2026-03-05)
- Publisher: Roblox. Ships inside Roblox Studio (no separate version; tracks Studio). Price: free. License: proprietary (part of Studio).
- Enable: Studio > Assistant > `...` > Manage MCP Servers > "Enable Studio as MCP server".
- Transport: **stdio** (launcher binary bridges to running Studio). No user-configured port.
- Client config (Claude Code / Claude Desktop / Cursor / Codex CLI use the same command):
  - macOS: `{"mcpServers":{"Roblox_Studio":{"command":"/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"}}}`
  - Windows: `{"mcpServers":{"Roblox_Studio":{"command":"cmd.exe","args":["/c","%LOCALAPPDATA%\\Roblox\\mcp.bat"]}}}`
  - Claude Code: put in project `.mcp.json` or `claude mcp add`. Codex: `~/.codex/config.toml` `[mcp_servers.Roblox_Studio] command=...` (TOML form UNVERIFIED from Roblox doc; Roblox says "same configuration").
  - Tool names in Claude will appear as `mcp__Roblox_Studio__<tool>`.
- **Exact tools (docs page, 2026-10):**
  - Scripts: `script_read`, `multi_edit`, `script_search`, `script_grep`
  - Asset/content generation: `generate_mesh`, `generate_material`, `generate_procedural_model`, `wait_job_finished`, `search_asset`, `insert_asset`
  - Images: `upload_image`, `store_image`
  - DataModel: `subagent`, `search_game_tree`, `inspect_instance`
  - Luau: `execute_luau`
  - Playtest: `get_studio_state`, `start_stop_play`, `get_console_output`, `screen_capture`
  - Input simulation: `character_navigation`, `user_keyboard_input`, `user_mouse_input`
  - Docs/skills: `http_get` (allow-listed Roblox doc URLs), `skill`
  - Session: `list_roblox_studios` (the March 2026 announcement also lists `set_active_studio`; current docs say every call takes an explicit `studio_id` instead -- treat `set_active_studio` as possibly removed, UNVERIFIED)
- Security: "MCP clients can read and modify content in your open Roblox places. Only connect clients you trust." `execute_luau` = arbitrary code in Studio (plugin security context). `generate_*`/`upload_image` consume Roblox account quota and create assets under your account. Gate mutating tools (execute_luau, multi_edit, insert_asset, upload_image, generate_*) behind permission prompts / PreToolUse hooks; allow read-only tools (script_read, script_grep, search_game_tree, inspect_instance, get_console_output, get_studio_state, screen_capture).
- Recommendation: **SELECT**.

### 1b. Roblox/studio-rust-mcp-server (REJECT, archived)
- Source: https://github.com/Roblox/studio-rust-mcp-server ; publisher Roblox; MIT.
- **Archived 2026-04-03**: "no longer being actively developed"; README directs users to the built-in Studio MCP server.
- Tools were: `run_code`, `insert_model`, `get_console_output`, `start_stop_play`, `run_script_in_play_mode`, `get_studio_mode`. Architecture: rmcp stdio server + axum web server long-polled by a Studio plugin (localhost port not documented on README; UNVERIFIED).
- Recommendation: **REJECT** (only as fallback documentation for old setups). Third-party alternatives (e.g. github.com/drgost1/robloxstudio-mcp, "51 tools") exist -- REJECT for a workbench: unofficial, broader attack surface.

## 2. Studio testing modes (https://create.roblox.com/docs/studio/testing-modes)
- **Test (F5)** (formerly "Play"): spawns your avatar at SpawnLocation or ~(0,100,0).
- **Test Here** (formerly "Play Here"): spawns in front of current camera.
- **Run (F8)**: simulates without inserting an avatar; Studio camera.
- **Server & Clients (F7)**: one server + up to **8** client windows (multi-client).
- **Team Test**: collaborative test in Team Create; only one team test session at a time.
- Client/Server view toggle during solo test; Pause/Resume + step forward 1/60 s.
- Simulators: Device Simulator (device/screen emulation, also VR emulation), Network Simulator (latency/jitter/loss), Party Simulator, Player Emulator (locale/policy).
- Automation: driven by MCP `start_stop_play`, `get_console_output`, `character_navigation`, `user_keyboard_input`, `user_mouse_input`, `screen_capture` (the docs page itself does not mention automation).

## 3. Luau toolchain

| Tool | Source | Latest (verified) | License | Purpose | Rec |
|---|---|---|---|---|---|
| Rojo | github.com/rojo-rbx/rojo | crates.io `rojo` max_stable **7.7.1** (crate updated 2026-10-02); GitHub releases page summary showed 7.7.0 as latest (7.7 adds syncback, websockets, .jsonc, Host/Origin validation) -- exact GitHub tag UNVERIFIED | MPL-2.0 (UNVERIFIED in this pass; historically MPL-2.0) | Filesystem <-> Studio sync, build .rbxl/.rbxm | SELECT |
| Rokit | github.com/rojo-rbx/rokit | crates.io **1.2.0** (2025-09-30) | MIT | Toolchain manager; drop-in compatible with aftman.toml/foreman.toml | SELECT (over Aftman/Foreman) |
| Aftman / Foreman | LPGhatguy/aftman, Roblox/foreman | not checked | MIT | Older toolchain managers; Rokit README: Aftman maintainer "no longer interested in Roblox", Foreman angled to Roblox internal use | REJECT |
| Lune | github.com/lune-org/lune | crates.io **0.10.5** (2026-07) | MPL-2.0 | Standalone Luau runtime; fs/net/process/serde + `roblox` lib to read/write place/model files; not a Roblox game runner | SELECT (scripts, offline place manipulation) |
| StyLua | github.com/JohnnyMorganz/StyLua | **2.5.2** (crates, 2026-05) | MPL-2.0 (UNVERIFIED) | Formatter | SELECT |
| Selene | github.com/Kampfkarren/selene | **0.31.0** (crates, 2026-05) | MPL-2.0 (UNVERIFIED) | Linter (roblox std) | SELECT |
| luau-lsp | github.com/JohnnyMorganz/luau-lsp | **1.69.0** (2026-07-18) | MIT (UNVERIFIED) | LSP + `luau-lsp analyze` CLI type-checking with Rojo sourcemap; can wire into Claude Code plugin `lspServers` | SELECT |
| Wally | github.com/UpliftGames/wally | crates **0.3.2** (2026-09) | MPL-2.0 (UNVERIFIED) | Package manager (de-facto Roblox registry; jest-lua ships here) | SELECT |
| pesde | github.com/pesde-pkg/pesde | crates **0.7.4** (2026-09) | MIT (UNVERIFIED) | Newer package manager (Roblox + Lune targets, can consume Wally pkgs) | Optional; default Wally |
| Jest Lua | github.com/jsdotlua/jest-lua | **3.10.0** (per README Wally example) | MIT | Jest 27 port, used internally by Roblox; Wally `jsdotlua/jest@3.10.0` + `jest-globals`; **runs only inside Roblox** (not Lune) | SELECT |
| TestEZ | github.com/roblox/testez | effectively superseded by Jest Lua (Roblox moved to Jest Lua) -- archive status UNVERIFIED | Apache-2.0 | Legacy BDD test framework | REJECT |
| run-in-roblox | github.com/rojo-rbx/run-in-roblox | not checked; long unmaintained (UNVERIFIED) | MIT | Run script in local Studio from CLI (Windows/macOS only, needs Studio) | REJECT |
| Open Cloud Luau Execution API | create.roblox.com/docs/cloud/reference/features/luau-execution | GA (v2) | n/a, free w/ API key | Headless CI: run Luau against a place (current or specific version). Endpoints `POST /cloud/v2/universes/{u}/places/{p}[/versions/{v}]/luau-execution-session-tasks`, poll task, fetch `.../logs`; binary inputs endpoint. Limits: 5 min per task, 10 concurrent tasks per place. API-key or OAuth auth. | SELECT (CI: rojo build -> upload place version -> run Jest via Luau Execution) |

Security: Open Cloud API keys should be scoped (universe-place write + luau-execution), IP-restricted, stored as CI secrets, never in repo/skills.

## 4. Blender MCP -- the rename is REAL
- Repo: https://github.com/ahujasid/mcp-for-blender (old URL github.com/ahujasid/blender-mcp now resolves to it; README titled "MCP for Blender"). Publisher: Siddharth Ahuja (community; "not affiliated with the Blender Foundation"). License MIT. ~28.7k stars.
- **PyPI:**
  - `mcp-for-blender` **2.1.8**, uploaded **2026-10-05** (2.1.x line active). Summary: "Open source Blender integration through the Model Context Protocol (not affiliated with Blender Foundation)". MIT.
  - `blender-mcp` **2.0.0** (2026-09-16) = compatibility shim: "Renamed to mcp-for-blender. Installing this package installs it for you." requires_dist `mcp-for-blender>=2.0.0`. `uvx blender-mcp` still works. Python import path unchanged: `blender_mcp`.
- Install: `uvx mcp-for-blender` (server); addon via `uvx mcp-for-blender install-addon` (per README) or manual addon.py. Requires Blender >= 3.0, Python >= 3.10, uv.
- Transport: MCP stdio to client; server talks to Blender addon over TCP socket **localhost:9876** (`BLENDER_HOST`, `BLENDER_PORT`).
- **Tools (server.py @mcp.tool, 31, the 1.x set as read on 2026-10-05; OUTDATED for 2.1.8, which exposes 14: `get_scene_info`, `look`, `get_addon_status`, `disable_telemetry`, `execute_blender_code`, `generate_3d`, `search_assets`, `import_asset`, `record_trajectory_feedback`, `search_mentions`, `viewport_*`/`open_viewport`; current list in `docs/mcp.md`):** `get_addon_status`, `disable_telemetry`, `get_scene_info`, `get_object_info`, `get_viewport_screenshot`, `execute_blender_code`, `describe_node_type`, `bpy_api_lookup`, `get_polyhaven_categories`, `search_polyhaven_assets`, `download_polyhaven_asset`, `set_texture`, `get_polyhaven_status`, `get_hyper3d_status`, `get_sketchfab_status`, `search_sketchfab_models`, `get_sketchfab_model_preview`, `download_sketchfab_model`, `get_polypizza_status`, `search_polypizza_models`, `download_polypizza_model`, `generate_hyper3d_model_via_text`, `generate_hyper3d_model_via_images`, `poll_rodin_job_status`, `import_generated_asset`, `get_hunyuan3d_status`, `generate_hunyuan3d_model`, `poll_hunyuan_job_status`, `import_generated_asset_hunyuan`, `export_scene`, `record_trajectory_feedback`. Prompt: `asset_creation_strategy`.
- **Single-client limitation:** "Only run one instance of the MCP server (either Cursor or Claude Desktop), not both" -- one socket to the addon. Claude Code and Codex must not both attach simultaneously.
- **Telemetry: ON by default.** Collects tool execution events (name, success, duration), and with consent can upload **viewport screenshots, prompts, executed code, scene observations and trajectory feedback**. Disable with `DISABLE_TELEMETRY=true` env var, the addon preference, or `disable_telemetry` tool. See TERMS_AND_CONDITIONS.md in repo.
- Security: `execute_blender_code` = arbitrary Python in Blender; third-party asset downloads (Sketchfab, Poly Pizza) carry license/provenance issues; Hyper3D/Hunyuan generation sends data to external services.
- Recommendation: **SELECT with conditions** -- pin `mcp-for-blender==2.1.x`, set `DISABLE_TELEMETRY=true` in .mcp.json env, deny external-asset/generation tools by default (permissions deny list), one client at a time. For deterministic pipeline steps prefer headless `blender -b -P script.py` over MCP.

### Blender versions
- LTS: **Blender 5.2 LTS** (5.2.2, 2026-09-15) and **4.5 LTS** (4.5.14, 2026-09-15). Source: https://www.blender.org/download/lts/
- `bpy` on PyPI: **5.2.2** (2026-09-15), GPL-3.0, **requires Python ==3.13.*** -- matches 5.2 LTS. Useful for headless CI asset validation without a Blender install (large wheel).
- Recommendation: pin Blender 5.2 LTS; `bpy==5.2.2` for CI.

## 5. Blender built-ins for an asset factory
- Since 4.2 most add-ons moved to the Extensions Platform (https://extensions.blender.org); only a handful of core add-ons remain bundled (projects.blender.org/blender/blender-addons).
- **Rigify**: extension (extensions.blender.org/add-ons/rigify), 0.6.12, Blender 4.2+, GPL. Manual still documents it. Install via extensions (`blender --command extension install` or Preferences > Get Extensions). Useful for humanoid rigs, but Roblox R15 needs its own bone naming -- prefer Roblox's R15 rig templates for avatars. Rec: optional.
- **LoopTools**: extension 4.7.7, Blender 4.2+, GPL-2.0+, "community, limited support". Rec: optional.
- **Node Wrangler**: still a bundled core add-on (manual lists under addons/node in 5.x; repo projects.blender.org/extensions/node_wrangler) -- bundled status for 5.2 partly UNVERIFIED.
- **Asset Browser** (core, 3.0+): asset libraries + catalogs; good for the kit-of-parts library.
- **Geometry Nodes** (core): procedural modular kits, scatter, LOD variants; drive via bpy for batch generation.
- **UV tooling** (core): Smart UV Project, Lightmap Pack, Pack Islands (UDIM/ shape-aware packing improvements in 3.6+/4.x), Minimize Stretch. Roblox requires single UV set in 0..1.
- glTF 2.0 and FBX I/O are bundled core add-ons.

## 6. Roblox mesh import specifics
- Sources: https://create.roblox.com/docs/art/modeling/specifications , /3d-importer , /texture-specifications , /export-requirements , https://create.roblox.com/docs/cloud/guides/usage-assets
- Triangle limit: **20,000 triangles per individual mesh**. Must be watertight, non-zero thickness; quads preferred.
- Formats (3D Importer): **.fbx and .gltf/.glb** (multiple meshes, hierarchy, basic + PBR textures, rigging, skinning, animation, cages, vertex colors); .obj with limited features.
- Scale: Importer "Scale Unit" setting (Studs default, or Meters, etc.). Blender export: Apply Scalings -> "FBX Unit Scale", Path Mode Copy + Embed Textures, disable Add Leaf Bones, disable Bake Animation unless animated. Convention 1 stud ~ 0.28 m (UNVERIFIED in this pass; set Scale Unit explicitly per import).
- Skinning: max **4 bone influences per vertex**; bones frozen (scale 1, rot 0); one animation track per export.
- Cages: `_InnerCage` / `_OuterCage` suffixes; don't alter cage vertices/UVs; imported as WrapLayer/WrapTarget.
- PBR SurfaceAppearance: Albedo RGB, Normal (**OpenGL tangent-space only**), Roughness, Metalness, Emissive mask (8-bit grey). One material per mesh; single UV set in 0..1. Max texture 4096x4096 per texture-spec page (page also cites 1024 guidance for UV atlases -- check before committing budget; partly UNVERIFIED). Resolution guidance: 5-stud obj 256, 10-stud 512, 20-stud 1024.
- **Open Cloud Assets API**: `POST /assets/v1/assets` create, `PATCH /assets/v1/assets/{id}` update (fbx only), `GET /assets/v1/operations/{id}` poll. Models: .fbx/.gltf/.glb/.rbxm/.rbxmx up to 20 MB; decals png/jpeg/bmp/tga up to 8000x8000; audio; video; animations (.rbxm/.rbxmx). Auth `x-api-key` (asset read/write) or OAuth `asset:read`/`asset:write`. Assets go through moderation. Rec: **SELECT** for the factory upload step (key in secrets, never in repo).

## 7. Claude Code (code.claude.com/docs, fetched 2026-10-05)

### Skills -- `.claude/skills/<skill-name>/SKILL.md`
- Locations: personal `~/.claude/skills/<n>/SKILL.md`; project `.claude/skills/<n>/SKILL.md`; enterprise (managed dir); plugin `<plugin>/skills/<n>/SKILL.md` (invoked `/plugin:skill`). Precedence enterprise > personal > project.
- Frontmatter must start on line 1 with `---`. Field names lowercase-hyphenated (except `when_to_use`).
- Fields: `name` (optional in Claude Code; defaults to directory name; lowercase + hyphens), `description` (recommended; **description + when_to_use truncated at 1,536 chars**), `when_to_use`, `disable-model-invocation` (bool), `user-invocable` (bool), `allowed-tools` (space/comma string or YAML list; grant lasts only for the turn), `disallowed-tools`, `arguments`, `argument-hint`, `shell` (bash|powershell), `context: fork`, `agent` (Explore/Plan/general-purpose/custom), `background`, `model`, `effort` (low..max), `paths` (globs), `hooks`, `metadata`, `license`, `compatibility` (<=500 chars).
- Substitutions: `$ARGUMENTS`, `$0..`, `$name`, `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PROJECT_DIR}`, `${CLAUDE_SESSION_ID}`, `${CLAUDE_EFFORT}`; `` !`cmd` `` dynamic injection.
- Reserved names: `synced`, `anthropic-skills`.
- **Cross-tool portability rule (agentskills.io spec, which Codex follows):** `name` REQUIRED, 1-64 chars, `[a-z0-9-]`, no leading/trailing or double hyphen, **must equal the directory name**; `description` REQUIRED, **<=1024 chars**; optional `license`, `compatibility` (<=500), `metadata` (string->string), `allowed-tools` (experimental, space-separated). Keep SKILL.md < 500 lines / < ~5k tokens; use `scripts/`, `references/`, `assets/`. => For a Claude+Codex workbench, always set name = dir name and keep description <= 1024 chars; put Claude-only fields (context, agent, hooks, paths...) only where Codex ignoring them is harmless.

### Subagents -- `.claude/agents/<name>.md` (project) / `~/.claude/agents/` (user)
- Required: `name`, `description`. Optional: `tools` (comma list; `Agent(x,y)` to restrict spawning), `disallowedTools`, `model` (sonnet/opus/haiku/fable/inherit/full id), `permissionMode` (default/acceptEdits/auto/dontAsk/plan/bypassPermissions), `memory` (user/project/local), `skills` (preload list), `mcpServers` (inline or by name), `hooks`, `maxTurns`, `isolation: worktree`, `background`.

### Hooks (settings.json `hooks`)
- Events: SessionStart, Setup, SessionEnd, UserPromptSubmit, UserPromptExpansion, Stop, StopFailure, PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, PermissionRequest, PermissionDenied, FileChanged, ConfigChange, InstructionsLoaded, CwdChanged, DirectoryAdded, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, TeammateIdle, Elicitation, ElicitationResult, Notification, MessageDisplay, PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, WorktreeCreate, WorktreeRemove.
- Schema: `{"hooks":{"<Event>":[{"matcher":"Bash|Edit|mcp__.*","hooks":[{"type":"command|http|mcp_tool|prompt|agent","command":"...","timeout":600}]}]}}`. Matcher: exact/pipe list or JS regex.
- Exit 0 = success (stdout JSON parsed); **exit 2 = block** (PreToolUse, UserPromptSubmit, Stop...), always wins over JSON; other codes non-blocking. JSON: `hookSpecificOutput.permissionDecision` allow|deny|ask|defer (PreToolUse), `additionalContext` (<=10k chars), `updatedInput`, `decision:"block"`.
- Config sources: `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, managed, plugin `hooks/hooks.json`, skill/agent frontmatter.

### MCP -- project `.mcp.json`
- `{"mcpServers":{"name":{"type":"stdio|http|sse|ws","command","args","env","url","headers","timeout"}}}`; `${VAR}` and `${VAR:-default}` expansion. Project servers prompt for approval in interactive sessions (auto-load in `-p`/SDK/cloud). Scopes: local (default, ~/.claude.json), project (.mcp.json), user. Tool names `mcp__<server>__<tool>`.

### Plugins
- Layout: `.claude-plugin/plugin.json` (optional; only `name` required, kebab-case), `skills/`, `agents/`, `commands/`, `hooks/hooks.json`, `.mcp.json`, `.lsp.json` (e.g. luau-lsp), `bin/`, `settings.json`. Validate with `claude plugin validate`. Names starting `claude-`/`anthropic-` are reserved.
- Rec: ship the workbench as plain `.claude/` project config first; package as a plugin later if reused across repos.

## 8. Codex
- **AGENTS.md** (learn.chatgpt.com/docs/agent-configuration/agents-md): global `~/.codex/AGENTS.override.md` then `~/.codex/AGENTS.md`; then walks repo root -> cwd, at each level `AGENTS.override.md` before `AGENTS.md`; later (closer) files override earlier. Default cap **32 KiB** (`project_doc_max_bytes`); alternate names via `project_doc_fallback_filenames` (e.g. could add `CLAUDE.md`).
- **Skills** (learn.chatgpt.com/docs/build-skills): REPO `.agents/skills` (cwd and `$REPO_ROOT/.agents/skills`), USER `$HOME/.agents/skills`, ADMIN `/etc/codex/skills`, SYSTEM bundled. (`~/.codex/skills` is the older location -- current docs list `~/.agents/skills`; legacy support UNVERIFIED.) Required frontmatter `name`, `description`; optional `agents/openai.yaml` (display name/icon, `allow_implicit_invocation: false`, MCP tool dependencies). Invoke `$skillname` or implicit by description. Follows agentskills.io standard => same SKILL.md works for Claude if it obeys the spec constraints.
- Workbench pattern: canonical skills in `.agents/skills/<name>/SKILL.md`, and `.claude/skills` as a symlink (or a sync script) to it; CLAUDE.md that `@AGENTS.md`-imports (or vice versa) so both agents share one instruction file. (Symlink support on Windows checkouts needs `core.symlinks=true`.)
- Codex MCP config: `~/.codex/config.toml` `[mcp_servers.<name>]` (command/args/env) -- format not re-verified this pass (UNVERIFIED).

## 9. Roblox procedural generation / building references
- Built into Studio: Terrain Editor (Generate, Import heightmap/colormap), Studio MCP `generate_procedural_model` / `generate_mesh` / `generate_material` (Roblox Cube-based generative AI; check licensing/moderation).
- Open-source WFC in Luau: no clearly maintained, widely adopted Roblox WFC library found in this pass -- **UNVERIFIED**. Reference algorithms: marian42/wavefunctioncollapse (C#/Unity, MIT) and mxgmn/WaveFunctionCollapse (original, MIT) -- port the simple-tiled model to Luau in-repo. 
- Community building plugins commonly cited (F3X Building Tools, Archimedes, ResizeAlign, GapFill & Extrude, Brushtool) -- versions/licenses UNVERIFIED; use as human-side tools, not workbench dependencies.
- Recommendation: implement procgen as in-repo Luau modules (seeded RNG via `Random.new(seed)`), tested with Jest Lua; use Blender Geometry Nodes for mesh kit variants.

## Summary SELECT / REJECT
SELECT: built-in Studio MCP; Rojo 7.7.x; Rokit; Lune; StyLua; Selene; luau-lsp; Wally (pesde optional); Jest Lua; Open Cloud Luau Execution + Assets API; mcp-for-blender 2.1.x (telemetry off, one client); Blender 5.2 LTS + bpy 5.2.2; Asset Browser, Geometry Nodes, core UV tools; Claude `.claude/skills|agents|settings.json|.mcp.json`; Codex `AGENTS.md` + `.agents/skills`.
REJECT: studio-rust-mcp-server (archived), third-party Studio MCPs, Aftman/Foreman, TestEZ, run-in-roblox, `blender-mcp` name for new configs (shim only).

Superseded 2026-10-06 (section 10, correction 1): the Open Cloud Luau Execution and Assets API SELECTs (sections 3 and 6 and the line above) are REJECT in this SETUP_ONLY factory.

## 10. Back-fill 2026-10-06: price, last update, maintenance

Sources fetched 2026-10-06: crates.io API, PyPI project pages, npm registry search API, GitHub repo and release pages, extensions.blender.org, blender.org, create.roblox.com (`/docs/updates/2026-09-28`, `/docs/en-us/studio/mcp.md`), learn.chatgpt.com config reference. The GitHub API returned 403, and GitHub Atom feeds, commit pages and the PyPI JSON API were blocked by robots.txt, so GitHub-only release dates are given as shown on the release page. That page shows "dd Mon" without a year, so in those cases the year is recorded as unknown. Nothing was installed.

| Candidate | Price | Last update (source) | Maintenance | Licence (2026-10-06) |
|---|---|---|---|---|
| Built-in Studio MCP | free with Studio | Tracks Studio; version 741 live in the week of 2026-09-28 (Roblox updates page). Tool list re-read 2026-10-06: the same 26 tools as section 1a | active (Roblox) | proprietary (Roblox terms) |
| studio-rust-mcp-server | free | archived 2026-04-03 | unmaintained | MIT |
| Rojo | free | 7.7.1, 2026-10-02 (crates.io); 7.7.0 was 2026-07-02 | active | MPL-2.0 (crates.io; was UNVERIFIED) |
| Rokit | free | 1.2.0, 2025-09-30 (crates.io) | no release in 12 months; repo not archived | MIT |
| Aftman | free | 0.3.0, 2024-05-21 (crates.io) | stale | MIT |
| Foreman | free | 1.7.0, 2026-05-01 (crates.io) | active (Roblox). REJECT still stands because it overlaps Rokit | MIT |
| Lune | free | 0.10.5, 2026-07-02 (crates.io) | active | MPL-2.0 |
| StyLua | free | 2.5.2, 2026-05-16 (crates.io) | active | MPL-2.0 (was UNVERIFIED) |
| Selene | free | 0.31.0, 2026-05-21 (crates.io) | active | MPL-2.0 (was UNVERIFIED) |
| luau-lsp | free | 1.69.0, 2026-07-18; 1.68.1 2026-06-14; 1.68.0 2026-05-16 (release page) | active, about one release a month | MIT (repo sidebar; was UNVERIFIED) |
| Wally | free | 0.3.2, **2023-06-05** (crates.io; GitHub release "05 Jun"). This corrects the "2026-09" in section 3 | no tagged release since 2023; repo not archived | MPL-2.0 (crates.io) |
| pesde | free | 0.7.4, 2026-09-09 (crates.io) | active | MIT (crates.io; was UNVERIFIED) |
| Jest Lua | free | v3.10.0 (release page "23 Dec", year not shown) | unknown | MIT |
| TestEZ | free | archived 2024-09-14 (repo banner) | unmaintained | Apache-2.0 |
| run-in-roblox | free | 0.3.0, 2020-10-30 (crates.io) | unmaintained (no release in about 6 years; not archived) | MIT |
| Open Cloud Luau Execution / Assets API | free with an API key or OAuth | unknown | active (Roblox) | Roblox terms |
| mcp-for-blender | free | 2.1.8, 2026-10-05 (PyPI page) | active | MIT |
| Blender 5.2 LTS / `bpy` | free | 5.2.2, 2026-09-15 (blender.org) | LTS, 2-year critical-fix window | GPL |
| Rigify | free | 0.6.12, 2024-06-07 (extensions.blender.org) | extension, no newer version listed | GPL-2.0-or-later |
| LoopTools | free | 4.7.7, 2024-05-14 (extensions.blender.org) | "Community", limited support | GPL-2.0-or-later |
| Asset Browser, Geometry Nodes, UV tools, Node Wrangler | free (Blender core) | tracks Blender | active | GPL |
| Claude Code | unknown (needs the owner's existing Claude plan or API billing; pricing page not fetched) | 2.1.290, 2026-10-05 (npm) | active | proprietary ("SEE LICENSE IN README.md") |
| Codex CLI | unknown (needs the owner's existing ChatGPT plan or API key; pricing page not fetched) | 0.157.1, 2026-09-26 (npm) | active | Apache-2.0 |

Corrections and resolved UNVERIFIEDs:
1. **Open Cloud is REJECT here.** The SELECTs for the Luau Execution API (section 3) and the Assets API (section 6) conflict with AGENTS.md (SETUP_ONLY: no publishing, no uploads, no production data) and with the guard hooks, which deny Open Cloud writes (`docs/mcp.md`). Luau Execution needs a place that exists on Roblox. The docs also say a task "can also invoke engine APIs that read and/or modify data stored in the cloud, such as those for DataStores". The CI design "upload place version -> run Jest" therefore publishes. Revisit only in a future game repository after explicit authorization. Details: addendum section I.
2. Wally's last release is 0.3.2 from 2023-06-05, not 2026-09. Wally is still the registry where Jest Lua ships, but release activity is stale. pesde (0.7.4, 2026-09-09) is the actively released alternative. The decision stays SELECT Wally / optional pesde until a dependency is actually needed.
3. Licences now verified: Rojo, StyLua, Selene, Wally and Lune are MPL-2.0; luau-lsp, pesde and Rokit are MIT.
4. The Codex MCP config format is now verified (learn.chatgpt.com config reference). `[mcp_servers.<id>]` takes `command`, `args`, `env`, `cwd`, `url`, `enabled`, `enabled_tools`, `disabled_tools`, `startup_timeout_sec`, `tool_timeout_sec` and `bearer_token_env_var`. `enabled_tools`/`disabled_tools` are the Codex least-privilege lever, playing the role Claude's permission rules play. Codex Memories (`features.memories`) are off by default.
5. The pins lag the latest releases: `rokit.toml` pins Rojo 7.7.0 (latest 7.7.1) and luau-lsp 1.68.1 (latest 1.69.0). This is informational and is not a defect on its own.
6. TestEZ is confirmed archived (2024-09-14), and run-in-roblox's last release was 2020-10-30, so both REJECTs are confirmed.

## Sources
- https://create.roblox.com/docs/studio/mcp
- https://devforum.roblox.com/t/assistant-updates-studio-built-in-mcp-server-and-playtest-automation/4474643
- https://github.com/Roblox/studio-rust-mcp-server
- https://create.roblox.com/docs/studio/testing-modes
- https://create.roblox.com/docs/cloud/reference/features/luau-execution
- https://create.roblox.com/docs/cloud/guides/usage-assets
- https://create.roblox.com/docs/art/modeling/specifications , /3d-importer , /texture-specifications , /export-requirements
- https://github.com/rojo-rbx/rojo/releases , https://github.com/rojo-rbx/rokit , https://github.com/lune-org/lune , https://github.com/JohnnyMorganz/luau-lsp/releases , https://github.com/jsdotlua/jest-lua
- `https://crates.io/api/v1/crates/<name>` for rojo, lune, stylua, selene, rokit, wally and pesde
- https://github.com/ahujasid/mcp-for-blender (README + src/blender_mcp/server.py)
- https://pypi.org/project/mcp-for-blender/ , https://pypi.org/project/blender-mcp/ , https://pypi.org/project/bpy/
- https://www.blender.org/download/lts/ , https://extensions.blender.org/add-ons/rigify/versions/ , https://extensions.blender.org/add-ons/looptools/ , https://projects.blender.org/blender/blender-addons
- https://code.claude.com/docs/en/skills , /hooks , /sub-agents , /mcp , /plugins-reference
- https://agentskills.io/specification
- https://learn.chatgpt.com/docs/build-skills , https://learn.chatgpt.com/docs/agent-configuration/agents-md

Back-fill sources (fetched 2026-10-06):
- `https://crates.io/api/v1/crates/<name>` for rojo, stylua, selene, wally, pesde, rokit, lune, aftman, foreman and run-in-roblox
- https://github.com/UpliftGames/wally/releases , https://github.com/JohnnyMorganz/luau-lsp , https://github.com/JohnnyMorganz/luau-lsp/releases , https://github.com/jsdotlua/jest-lua/releases , https://github.com/Roblox/testez , https://github.com/rojo-rbx/run-in-roblox , https://github.com/rojo-rbx/rokit/releases , https://github.com/Roblox/studio-rust-mcp-server
- https://pypi.org/project/mcp-for-blender/
- https://registry.npmjs.org/-/v1/search?text=%40anthropic-ai%2Fclaude-code , https://registry.npmjs.org/-/v1/search?text=%40openai%2Fcodex
- https://www.blender.org/download/lts/ , https://extensions.blender.org/add-ons/rigify/versions/ , https://extensions.blender.org/add-ons/looptools/
- https://create.roblox.com/docs/updates/2026-09-28 , https://create.roblox.com/docs/en-us/studio/mcp.md , https://create.roblox.com/docs/cloud/reference/features/luau-execution.md
- https://learn.chatgpt.com/docs/config-file/config-reference
