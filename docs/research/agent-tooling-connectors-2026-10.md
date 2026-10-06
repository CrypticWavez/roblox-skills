# Agent tooling: connectors, plugins, skills, Studio plugins and creator-PC tools for Claude and Codex (verified 2026-10-06)

This pass extends earlier research instead of redoing it:
- [tooling-2026-10.md](tooling-2026-10.md), sections 1 (Studio MCP), 4 (Blender MCP), 7 (Claude Code) and 8 (Codex), with the section 10 back-fill.
- [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md), sections E (luau-lsp, memory), F (capture) and J (extra MCP servers: Playwright, Chrome DevTools, Filesystem, Fetch, Context7, GitHub). Those decisions stand unless this file says otherwise.
- Same-day sibling passes, not repeated here: [ui-cinematics-feel-2026-10.md](ui-cinematics-feel-2026-10.md) (storybook plugins, the `afrxo/roblox-agent-skills` pack), [visual-audio-assets-2026-10.md](visual-audio-assets-2026-10.md) (Material Maker, Studio generators, asset sources), [blender-animation-pipeline-2026-10.md](blender-animation-pipeline-2026-10.md) (Krita, ImageMagick, glTF Transform, Moon Animator 2) and `knowledge/records/tools-options.json` (Figma pricing, Aseprite, Audacity).

Nothing here picks a genre, theme, world, characters or economy. Every selection is tooling that any game repository would use.

**Method.**
- All sources were fetched on 2026-10-06; the list is at the end. Primary sources only: create.roblox.com (`.md` page variants), DevForum announcement threads, code.claude.com, claude.com, learn.chatgpt.com, developers.openai.com, help.openai.com, blender.org, vendor docs (Figma, Linear, Notion, Rojo, Inkscape wiki), GitHub repo and release pages, and registries (npm, crates.io, Open VSX, winget-pkgs manifests).
- Blocked or partial sources: projects.blender.org web pages returned 403, so the Blender Lab repo was read through its public Gitea API (`https://projects.blender.org/api/v1/repos/lab/blender_mcp/...`). inkscape.org returned 403 except the release page. The official Claude marketplace catalog (`.claude-plugin/marketplace.json`) was read only up to about 96.7k characters (plugins "a" to "l"); the rest was not scanned, and a claude.com marketplace search for "roblox" returned no plugins. The GitHub API returned 403, as in earlier passes.
- Creator Store pages have no readable body. Free/paid status of one plugin came from the public, read-only economy details endpoint (`https://economy.roblox.com/v2/assets/<id>/details`). No Roblox asset ids are recorded in this file, because the `asset-provenance` gate scans it.
- Pages were read through a summarising fetcher, so short quotes are given where wording matters. Nothing was installed, bought, signed up for or downloaded.

**Decision rule** (same as the addendum): **SELECT** = add to the factory now (pinned tool, repo config, documented PC install, skill or reference). **REJECT** = do not adopt; this always applies to anything paid, abandoned, closed-source with full place access, or that publishes or uploads. **REVISIT** = facts recorded, decision waits for the stated trigger.

**Install and drive legend** (used in every assessment table):
- Who installs: **AGENT** (an agent may run the install command, on the PC or in a container, after the owner approves that command), **OWNER-STORE** (the owner, through the Creator Store and the owner's Roblox account; never automated), **OWNER-UI** (the owner, through a GUI installer, Blender/VS Code UI or an account setting), **BUILT-IN** (ships with Studio, Blender or the client).
- How an agent drives it: **CLI**, **MCP**, **LSP**, **FILES** (the agent reads or writes a documented file format), **GUI-ONLY**.

---

## 1. Decisions in brief

1. **Studio MCP stays the only Studio control path, but four of its 26 tools are unclassified here.** `subagent`, `skill`, `wait_job_finished` and `search_asset` are in none of the allow/ask lists in `.claude/settings.json`, `.codex/config.toml` or `tools/hooks/guard_mcp.mjs`. `subagent` starts Roblox's own explore or playtest agent inside Studio, and the repo hooks never see that agent's tool calls. It should ask; the other three are reads (gap G1). `set_active_studio` was removed on 2026-08-19, which settles an UNVERIFIED in `tooling-2026-10.md`.
2. **Two MCP surfaces bypass the guards.** Connectors the owner adds on claude.ai load into Claude Code automatically on a subscription login. ChatGPT plugins are usable in Codex. The repo's PreToolUse matchers cover only Bash, `Roblox_Studio` and `blender*`, so these tools run unguarded. Set `disableClaudeAiConnectors` in the factory and add a catch-all MCP guard (gap G2).
3. **Luau code intelligence: build a small repo-local plugin; do not use the official one.** The official `lua-lsp` plugin runs `lua-language-server` for `.lua` files only. The factory writes `.luau` and needs Roblox types. Ship a repo-local Claude plugin whose `.lsp.json` starts `luau-lsp lsp` with pinned Roblox definitions, add the `luau-lsp analyze` gate step selected in the addendum, and bump the pin from 1.68.1 to **1.70.1** (2026-09-27) (gap G3).
4. **Blender: trial the official Blender Lab MCP server** (v1.0.3, 2026-09-11, GPL-3.0-or-later). This is the "Blender connector" in Anthropic's 2026-04-28 creative-work announcement. It has no asset-download or 3D-generation tools, bundles searchable Blender Python API docs and has `_for_cli` variants that work on unopened `.blend` files. If the trial confirms that, it should replace `mcp-for-blender` (gap G6).
5. **Connectors: GitHub only.** Figma, Linear, Notion, Asana, Canva and Adobe are REJECT for the factory: each needs an account, puts design or production data in a third-party cloud and does not produce Roblox UI. Production tracking uses GitHub Issues and milestones through `gh` and the read-only GitHub MCP, driven by a new genre-neutral production-plan skill (gap G5).
6. **Codex now has plugins**, with a repo-level marketplace at `.agents/plugins/marketplace.json`. Nothing needs adopting yet. Packaging the factory's skills and guards as a Claude plus Codex plugin is REVISIT (gap G8). `$imagegen` (gpt-image-2) is REVISIT in a game repository. `openai/skills` is deprecated.
7. **Community Roblox MCP servers and Roblox skill packs: all REJECT.** Each is archived, has a paid tier, has telemetry on by default, uploads through Open Cloud, or has almost no review history (0 to 3 stars, 1 to 6 commits).
8. **Studio plugins: no Creator Store install is required.** The Rojo plugin comes from `rojo plugin install` (AGENT, CLI). The Tag Editor is built in. Every community plugin asked about is REJECT: paid, stale, closed-source with full place access, uploads, or overlaps seeded SceneKit/ProcGen output. The owner list in section 8 is short on purpose.
9. **Creator-PC tools: add Inkscape** for its command-line SVG-to-PNG export, so agents can author UI icons and frames as SVG text (gap G4). The sibling decisions stand: Krita optional, glTF Transform through pinned `npx`, ImageMagick and Material Maker not repo dependencies. OBS and jsfxr are REVISIT; Blockbench, LMMS, Bfxr and Upscayl are REJECT.
10. **VS Code: five extensions** (luau-lsp, StyLua, Selene, Claude Code, Codex). The Rojo VS Code extension is REJECT (last release 2022).

## 2. What the repo has today (judged 2026-10-06)

| File | State | Problem for this topic |
|---|---|---|
| [.mcp.json](../../.mcp.json), [.codex/config.toml](../../.codex/config.toml) | `Roblox_Studio` (Windows launcher) and `blender` (`mcp-for-blender==2.1.8`, telemetry off) for both clients | no Blender Lab option; Codex prompts on 11 named tools only |
| [.claude/settings.json](../../.claude/settings.json) | 15 Studio tools allowed, 6 asked; PreToolUse matchers for `Bash` and `mcp__Roblox_Studio__.*` / `mcp__blender.*` | `subagent`, `skill`, `wait_job_finished`, `search_asset`, `http_get` not listed; no `disableClaudeAiConnectors`; any other MCP server is unguarded |
| [tools/hooks/guard_mcp.mjs](../../tools/hooks/guard_mcp.mjs) | `ASK_TOOLS` (asset/quota tools and `http_get`), `READ_TOOLS`, code checks for everything else; the Blender branch matches any `mcp__blender*__` server | `subagent` falls through to the text checks, which see only its prompt, not what the Studio-side agent then does |
| [.codex/hooks.json](../../.codex/hooks.json) | guards Bash and Studio/Blender MCP tools | no guard for plugin or other MCP tools |
| [rokit.toml](../../rokit.toml) | luau-lsp 1.68.1 | latest is 1.70.1; no `.lsp.json`, no `analyze` gate step (addendum E: selected, not implemented) |
| Plugins | none: no `.claude-plugin/`, no `.agents/plugins/` | skills and hooks reach game repos only as one-time copies ([docs/starter.md](../starter.md)) |
| [docs/mcp.md](../mcp.md) | per-server audit; "Local machine notes" section | that section records observations of the owner's PC in a public repo; it belongs in a private note (hygiene, not a decision) |
| `.agents/skills/roblox-studio-testing/SKILL.md` | tool table for Studio MCP | does not mention `subagent`, `skill` or Roblox's built-in `rbx-*` skills |

## 3. Roblox Studio MCP: tool list and changes since the last pass

Source: `https://create.roblox.com/docs/en-us/studio/mcp.md` (page "Last updated: October 2, 2026"), plus the DevForum announcements cited below.

**Tool list (26):** scripts `script_read`, `multi_edit`, `script_search`, `script_grep`; assets and generation `generate_mesh`, `generate_material`, `generate_procedural_model`, `wait_job_finished`, `search_asset`, `insert_asset`, `upload_image`, `store_image`; DataModel `subagent`, `search_game_tree`, `inspect_instance`; `execute_luau` (requires `datamodel_type` Edit, Client or Server); playtest `get_studio_state`, `start_stop_play`, `get_console_output`, `screen_capture`; input `character_navigation`, `user_keyboard_input`, `user_mouse_input`; docs `http_get`, `skill`; session `list_roblox_studios`. This is the same set as the 2026-10-06 back-fill in `tooling-2026-10.md`.

**Changes and facts not in earlier passes:**
- 2026-08-19, "Studio MCP: Multi-Agent Improvements and Connected AI Clients": `set_active_studio` removed; every tool takes `studio_id`; `list_roblox_studios` now returns the place id; Assistant Settings shows the connected AI clients; "clients like Claude Code and Codex pick up the new tools on their own" after a restart. Known issue still open: "Studio crashes during heavy workflows or long sessions".
- 2026-03-19: mesh generation got bounding boxes and a triangle cap (default 10,000), and `screen_capture` switched to JPEG to stay under client result limits. Claude Code caps MCP output at 25,000 tokens by default (`MAX_MCP_OUTPUT_TOKENS`), and image results stay subject to that cap (code.claude.com/docs/en/mcp), so captures should use small sizes.
- 2026-04-09, "[Studio Beta] Studio Assistant & MCP Playtest Agent": the playtest subagent runs scripted gameplay checks and reports Pass/Fail/Inconclusive/Error. Limits: "False positives", a 50-turn limit, a "Daily usage cap", loop detection. Enabled under File > Beta Features. Whether the beta flag is still required now that `subagent` is in the main tool list is UNVERIFIED.
- `subagent`: "Launches a specialized subagent to handle complex, multi-step tasks autonomously. Available types include `explore` ... and `playtest`". Which Studio tools that subagent may call (for example `insert_asset` or `generate_*`) is not documented (UNVERIFIED).
- `skill` returns Roblox's built-in Assistant skills. The Assistant skills page (2026-09-25) lists `rbx-create-skill`, `rbx-debug`, `rbx-device-simulator-lua`, `rbx-docs-search`, `rbx-perf-profiling`, `rbx-scene-analysis` and `rbx-unit-test`. Custom Assistant skills use `name`, `description` and an optional `enabled` field. Where Studio stores them is not documented.
- Quick connect in Studio lists Antigravity, Codex CLI, Claude Code, Claude Desktop, Cursor, Gemini CLI and VS Code. The repo keeps its own project-level config.
- 2026-02-21: Roblox said it would next add "support for connecting Assistant to third-party MCP servers, enabling access to tools like Blender and Figma". No release of that was found (UNVERIFIED). It would matter because Studio would become an MCP client that the repo hooks cannot see.
- The 2026-10-02 "Build with a coding harness" guide recommends Script Sync plus MCP and does not mention Rojo. Script Sync is covered in section 8.

**Classification (proposed; implemented by gap G1).**

| Tool | Claude today | `guard_mcp` today | Codex today | Proposed |
|---|---|---|---|---|
| 9 reads (`list_roblox_studios`, `get_studio_state`, `search_game_tree`, `inspect_instance`, `script_*`, `get_console_output`, `screen_capture`) | allow | READ | no per-tool setting | unchanged |
| `execute_luau`, `multi_edit`, play and input tools | allow | code checks | no per-tool setting | unchanged |
| `insert_asset`, `upload_image`, `store_image`, `generate_*` | ask | ask | prompt | unchanged |
| `http_get` | not listed (prompts) | ask | prompt | add to Claude `ask` (already an owner step in gap-matrix T04) |
| `skill` | not listed (prompts) | code checks | not listed | allow; add to `READ_TOOLS` |
| `wait_job_finished` | not listed | code checks | not listed | allow; `READ_TOOLS` (it only polls a job an asked `generate_*` started) |
| `search_asset` | not listed | code checks | not listed | allow; `READ_TOOLS` (the studio-testing skill already treats it as search only) |
| `subagent` | not listed (prompts) | only its prompt text is checked | not listed | `ask` in Claude, `approval_mode = "prompt"` in Codex, add to `ASK_TOOLS` (Codex turns the ask into a deny, as for other asks) |

## 4. Claude Code: plugins, marketplaces, code intelligence and connectors

### 4a. Facts

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Official marketplace `claude-plugins-official` | https://github.com/anthropics/claude-plugins-official ; https://code.claude.com/docs/en/plugins/anthropic-marketplaces | Anthropic (plus partner plugins) | catalog | continuous (4,351 commits) | active; Claude Code adds it on the first interactive start; auto-update on by default | Apache-2.0 (repo); each plugin has its own | free; partner plugins need vendor accounts |
| Official `lua-lsp` plugin | https://code.claude.com/docs/en/plugins/code-intelligence | Anthropic | 1.0.0 | n/a | active | repo Apache-2.0 | free |
| Plugin `.lsp.json` / `lspServers` (for a custom luau-lsp plugin) | https://code.claude.com/docs/en/plugins/components ; https://code.claude.com/docs/en/plugins/manifest-reference | Anthropic | Claude Code 2.1.28x to 2.1.290 (npm endpoints disagreed on 2026-10-06; the VS Code build is 2.1.290) | 2026-10-05 | active | proprietary | part of the owner's plan |
| luau-lsp | https://github.com/JohnnyMorganz/luau-lsp ; Open VSX `JohnnyMorganz/luau-lsp` | JohnnyMorganz | **1.70.1** (synced to Luau 0.740) | 2026-09-27 (release page and Open VSX) | active, about one release a month | MIT (Open VSX) | free |
| claude.ai connectors inside Claude Code | https://code.claude.com/docs/en/mcp ; https://claude.com/docs/connectors/directory | Anthropic and vendors | n/a | n/a | active; one catalog for claude.ai, Desktop, mobile, Claude Code and Cowork | vendor terms | plan plus vendor accounts |
| GitHub plugin (official GitHub MCP server) | marketplace entry `github`; https://github.com/github/github-mcp-server | GitHub | v1.11.0 (addendum J) | year unknown (addendum) | active | not shown on fetched pages (addendum) | free |
| Figma plugin and connector (remote `https://mcp.figma.com/mcp`) | https://github.com/figma/mcp-server-guide ; https://developers.figma.com/docs/figma-mcp-server/rate-limits-access/ | Figma | marketplace pins commit `172920731eed` | n/a | active | repo licence not shown | Starter: "Up to 20/month" tool calls on the docs page versus 6 in the guide README (conflict); paid Dev or Full seat: up to 200/day |
| Linear MCP (`https://mcp.linear.app/mcp`, read-only variant `/mcp/readonly`) | https://linear.app/docs/mcp | Linear | n/a | n/a | active | Linear terms | Linear account; plan limits not stated |
| Notion MCP (remote) | https://developers.notion.com/docs/mcp | Notion | n/a | n/a | active | Notion terms | Notion account |
| Asana, Canva, Adobe for creativity, Atlassian, Miro | claude.com connectors page; marketplace entries; https://www.anthropic.com/news/claude-for-creative-work | vendors | n/a | creative connectors announced 2026-04-28 | active | vendor terms | vendor accounts |
| Playwright plugin | `external_plugins/playwright` in the official marketplace | Microsoft (server) | 0.0.83 (addendum J) | 2026-09-28 | active | Apache-2.0 | free |
| `anthropics/skills` (`skill-creator`) | https://github.com/anthropics/skills | Anthropic | n/a | n/a | active | Apache-2.0 for most skills; document skills source-available | free |
| Community Roblox skill packs | https://github.com/MSayib/roblox-dev-skill ; https://github.com/zilibobi/roblox-skills ; https://github.com/AshExplained/roblox-skills (afrxo pack: ui-cinematics doc 4c) | individuals | none tagged | MSayib README "Last Updated: June 25, 2026" | 3, 0 and 0 stars; 3, 1 and 6 commits | MIT (MSayib, AshExplained); not shown (zilibobi) | free |

### 4b. Assessment

| Candidate | Purpose / capabilities | Security | Overlap | Install / drive (Claude, Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Official marketplace | Install with `/plugin install <name>@claude-plugins-official` at user, project or local scope. Plugins can add skills, agents, hooks, MCP and LSP servers. The catalog scan (a to l) found no Roblox, Luau, Blender or game-engine plugin; claude.com search for "roblox" returned none | "A plugin can run hooks and MCP servers, so read the pane before you install." Auto-update is on for official marketplaces, so a plugin's hooks can change between sessions | repo `.claude/` config | AGENT (`claude plugin install`, owner approves) / CLI | nothing Roblox-specific to install | **SELECT as a source only**: install individual plugins by name, never the marketplace wholesale |
| Official `lua-lsp` | `"command": "lua-language-server"`, `"extensionToLanguage": {".lua": "lua"}` | local process | luau-lsp | AGENT / LSP | none: the repo has no `.lua` files and lua-language-server has no Luau types or Roblox API | **REJECT** |
| Custom luau-lsp plugin | A strict `.lsp.json` (`command`, `args`, `extensionToLanguage` required; `env`, `initializationOptions`, `settings`, `workspaceFolder`, timeouts, `restartOnCrash`, `maxRestarts`, `diagnostics` default true). `${CLAUDE_PROJECT_DIR}` is substituted in LSP `args`. The LSP runs `luau-lsp lsp --definitions:@roblox=<file> --docs=<file>`; definitions come from `luau-lsp.pages.dev/type-definitions/globalTypes.<Security>.d.luau` and docs from `luau-lsp.pages.dev/api-docs/en-us.json`; it reloads `sourcemap.json` when that file changes | Definitions are downloaded once (network), so pin them by sha256. "Code intelligence plugins work in terminal sessions"; cloud sessions do not start plugin language servers | Selene (lint), the gate | Claude: LSP diagnostics after every edit plus a read-only `LSP` tool for symbol lookups. Codex: no documented LSP hook, but both clients can run `luau-lsp analyze` (CLI) | type errors caught while editing; symbol navigation instead of whole-file reads | **SELECT** (gap G3) |
| claude.ai connectors in Claude Code | "MCP servers you've added in claude.ai ... are automatically available in Claude Code" with a subscription login. Off: `"disableClaudeAiConnectors": true` or `ENABLE_CLAUDEAI_MCP_SERVERS=false` | Unguarded here: the PreToolUse matchers cover only Studio and Blender tools. Connector verification "isn't a security audit" | project `.mcp.json` | settings key / env var | none for the factory | **REJECT for the factory**: set `disableClaudeAiConnectors` (gap G2) |
| GitHub plugin / MCP | issues, PRs, code search; read-only mode and toolsets | writes PRs and issues unless restricted | `gh` CLI | OWNER-UI or AGENT / MCP; Codex `[mcp_servers]` | production tracking in game repos | **SELECT** (unchanged from addendum J: read-only toolsets for reviewers; issue writes only in a game repo) |
| Figma | design context, variables, screenshots; write-to-canvas tools on the remote server | design files leave the PC; OAuth account | UIKit tokens (ui-cinematics doc 6.1) | OWNER-UI / MCP | reading tokens from a mockup. Output is React plus Tailwind, not Roblox UI | **REJECT** now (seat cost for real use; nothing Roblox-native). **REVISIT** if the owner designs UI in Figma: map `get_variable_defs` onto UIKit StyleSheet tokens |
| Linear / Notion / Asana | issue trackers and wikis with write tools | a second system of record outside git; accounts | GitHub Issues and milestones, `docs/decisions.md` | OWNER-UI / MCP | none over GitHub | **REJECT** |
| Canva / Adobe for creativity | cloud image and design creation | cloud content; account terms | Krita, Inkscape, CC0 sources | OWNER-UI / MCP | none in SETUP_ONLY | **REJECT** |
| Playwright plugin | browser automation | as addendum J | n/a | n/a | n/a | **REVISIT** (unchanged) |
| `skill-creator` | drafts skills, runs with/without-skill test prompts, benchmarks, optimises descriptions for triggering (`run_loop.py`, `aggregate_benchmark.py`) | runs local Python | `tools/sync_skills.py` (structure only), the one usage probe in `reports/skill-usage-2026-10-06.json` | reference; Codex ships an equivalent `$skill-creator` | a method for measuring whether the 20 skills trigger | **SELECT as reference** for gap G7; do not vendor |
| Community Roblox skill packs | MSayib: about 5,100 lines plus a "Context7 fallback". zilibobi: a creator-docs clone with a daily git pull. AshExplained: 40 skills including economy, monetization and PRD-to-issues | unreviewed prompt content; network fallbacks; economy and monetization advice is game content | the repo's 20 skills, which are tested | Claude plugin or git clone | ideas only (AshExplained's brief to vertical slices to issues flow informs gap G5) | **REJECT** |

## 5. Blender connectors: Blender Lab MCP versus mcp-for-blender

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Blender Lab `blender_mcp` | https://www.blender.org/lab/mcp-server/ ; https://projects.blender.org/lab/blender_mcp | Blender Foundation (Blender Lab) | v1.0.3 "Screenshot Fix" (server `pyproject.toml` still says 1.0.2) | 2026-09-11; repo updated 2026-09-29 | active; v1.0.0 2026-04-27, v1.0.2 2026-09-08; 25 stars | GPL-3.0-or-later (MCPB manifest) | free |
| `mcp-for-blender` (in use) | tooling-2026-10.md section 4 | Siddharth Ahuja (community) | 2.1.8 | 2026-10-05 | active | MIT | free; generators can cost credits |

| Candidate | Purpose / capabilities | Security | Overlap | Install / drive | Benefit | Decision |
|---|---|---|---|---|---|---|
| Blender Lab | 26 tools: `execute_blender_code` and `execute_blender_code_for_cli` (runs in a background Blender); `get_blendfile_summary_*` (data-blocks, missing files, linked libraries, path info, usage guess, each with a `_for_cli` twin); `get_object_detail_summary`, `get_objects_summary`; `get_python_api_docs`, `search_api_docs`, `search_manual_docs` (bundled API reference and manual); `get_screenshot_of_area_as_image`, `get_screenshot_of_window_as_image`, `get_screenshot_of_window_as_json`; `jump_to_*`; `render_thumbnail_to_path`, `render_viewport_to_path`. No asset download or 3D generation. Needs Blender 5.1 or newer | Official warning: "The MCP server will execute LLM generated code in Blender without any guards in place to protect your data from removal or being sent to a remote location." Telemetry is not mentioned and the add-on socket's default port is not documented (both UNVERIFIED). The server's Python package is named `blender-mcp`, the same name as the PyPI compatibility shim for mcp-for-blender, so install it only from the pinned git tag | mcp-for-blender (two clients must never share one Blender) | Add-on: OWNER-UI from the Blender Lab extensions repository `https://lab.blender.org/`. Server: AGENT, `pip install git+https://projects.blender.org/lab/blender_mcp.git#subdirectory=mcp` pinned to `@v1.0.3` (or the same URL through `uvx --from`; UNVERIFIED until run). Drive: MCP. Named `blender_lab`, it is already caught by the Claude matcher `mcp__blender.*`, the Codex matcher and the Blender branch of `guard_mcp` | Version-matched bpy docs search reduces API guessing, which matters because the blender pipeline doc found name- and version-sensitive bpy calls. Its smaller tool surface removes the third-party asset and generation tools the asset doc rejects. `_for_cli` inspection of factory outputs | **SELECT for a trial** (gap G6). Replace mcp-for-blender only if the trial shows parity for screenshots and code execution, and telemetry is confirmed off |
| mcp-for-blender | unchanged | unchanged (gap-matrix M04 WEAK: add-on telemetry) | Blender Lab | unchanged | unchanged | **SELECT** (unchanged) until G6 decides |

## 6. Codex and ChatGPT: plugins, skills, MCP and apps

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Codex CLI | npm `@openai/codex` | OpenAI | 0.160.1 | 2026-10-05 (npm search) | active | Apache-2.0 | owner's ChatGPT plan or API key |
| Codex plugins | https://learn.chatgpt.com/docs/plugins.md ; https://developers.openai.com/plugins/build/plugins | OpenAI | n/a | n/a | active (new since the last pass) | n/a | included |
| `openai/skills` | https://github.com/openai/skills | OpenAI | n/a | n/a | "deprecated", superseded by the plugins repository | per skill | free |
| Codex image generation (`$imagegen`) | https://learn.chatgpt.com/docs/image-generation.md | OpenAI | gpt-image-2 | n/a | active | OpenAI usage policies; "You do not need to credit OpenAI" | counts toward Codex limits, used "3–5x faster" than turns without images; API pricing with `OPENAI_API_KEY` |
| ChatGPT GitHub app | https://help.openai.com/en/articles/11145903-connecting-github-to-chatgpt-deep-research | OpenAI | n/a | page updated 2026-10-06 | active | OpenAI terms | plan-dependent |
| Codex IDE extension | Open VSX `openai/chatgpt` | OpenAI | 26.5908.31748 | 2026-09-11 | active | "SEE LICENSE IN LICENSE.md" | included in ChatGPT plans |

| Candidate | Purpose / capabilities | Security | Overlap | Install / drive | Benefit | Decision |
|---|---|---|---|---|---|---|
| Codex plugins | Bundle skills, MCP servers, browser extensions and hooks. Installed with `/plugins` (CLI), the ChatGPT desktop Plugins tab or the web; usable "in Chat or Work in ChatGPT, or in Codex". Portable root `plugin.json` (`$schema`, `name`, `version`, `description`) plus a legacy `.codex-plugin/plugin.json`. Repo marketplace `$REPO_ROOT/.agents/plugins/marketplace.json`; `codex plugin marketplace add owner/repo` | "the host's sandbox and approval policy applies", but `.codex/hooks.json` matches only Bash and Studio/Blender tools, so plugin MCP tools are unguarded | `.agents/skills`, `.codex/` | OWNER-UI or AGENT / CLI | a channel to ship factory skills and guards to game repos | **REVISIT** (gap G8); guard any plugin tools first (gap G2) |
| `openai/skills` | `$skill-installer` catalog (`.system`, `.curated`, `.experimental`) | per-skill scripts | plugins | CLI | none | **REJECT** (deprecated) |
| `$imagegen` | text and reference-image generation in CLI, IDE and app; references with `-i` | generated art is content; uploads to Roblox stay owner-only | CC0 sources, Krita, Inkscape | built in / CLI | concept references, icon and thumbnail drafts | **REVISIT** in a game repo: record outputs in the asset sources manifest proposed by the visual-audio doc (6.5), mark them AI-generated, never upload without approval |
| ChatGPT GitHub app | "read-only": retrieves "permitted repository content on demand"; repositories chosen at install | read-only; data-use follows the plan's settings | Codex cloud, `gh` | OWNER-UI | ChatGPT chat and deep research can answer questions about the factory without Codex | **SELECT** (optional; owner, this repository only) |
| Codex IDE extension | Codex inside VS Code | as Codex CLI | Codex CLI | OWNER-UI | same agent in the editor | **SELECT** (section 10) |

## 7. Community Roblox Studio MCP servers (security review)

| Candidate | Facts (2026-10-06) | Security | Decision |
|---|---|---|---|
| `boshyxd/robloxstudio-mcp` (npm `robloxstudio-mcp`, `robloxstudio-mcp-inspector`) | MIT; 485 stars; **archived 2026-06-06** after the maintainer lost npm access, pointing users to a fork; v2.7.0-next.6; 43 tools (31 in the read-only inspector edition); Studio plugin over HTTP that needs "Allow HTTP Requests" | unmaintained package name on npm; an HTTP-enabled plugin; no auth mentioned | **REJECT** |
| WEPPY (`hope1026/weppy-roblox-mcp`, `npx -y @weppy/roblox-mcp@latest`) | AGPL-3.0 plus a commercial licence; 60 stars, 318 commits; localhost `127.0.0.1:3002` plus a Studio plugin; Node 22+; paid "Pro" tier (multi-place, sync, UI Studio, playtest, asset management); asset upload through Open Cloud | Google Analytics 4 telemetry "enabled by default" (off with `ENABLE_TELEMETRY=false`); upload path; `@latest` | **REJECT**: paid tier, default telemetry, uploads, overlaps the built-in server. This is the "WEPPY bridge" in `docs/mcp.md` (gap-matrix M05 REDUNDANT) |
| Open Cloud MCP servers (e.g. `kevinswint/roblox-opencloud-mcp-server`) | leads only, not fetched | Open Cloud writes publish or touch production data | **REJECT** (SETUP_ONLY; Open Cloud is already REJECT, addendum I) |
| Other listings (`IDKDeadXD/roblox-studio-mcp`, PyPI `mcp-roblox-docs`, directory listings) | leads only | unreviewed | **REJECT** |

## 8. Studio plugins (the owner's list)

Creator Store plugins run with full access to the open place and install through the owner's Roblox account. Agents never install them.

| Plugin | Facts (2026-10-06) | Who installs / drive | Decision |
|---|---|---|---|
| Rojo plugin | One plugin per major version: "Make sure you install the correct one!" Install with `rojo plugin install` (CLI), the `Rojo.rbxm` release asset, or Roblox.com. GitHub lists 7.7.0 (02 Jul) as the latest release; crates.io has 7.7.1 (2026-10-02) | **AGENT** (CLI on the PC; writes Studio's local Plugins folder, no account; `guard_bash` already allows `rojo plugin`) / CLI and FILES | **SELECT**: run after every `rokit install` that changes the Rojo pin |
| Tag Editor + Properties "Tags" | Built in since 2022-11-15 (View tab). The CollectionService page: tags "can also be managed directly in Studio through the Tags section of an instance's properties" | **BUILT-IN** / `execute_luau` (`CollectionService`) | **SELECT** (no install); community tag editors **REJECT** (redundant) |
| Assistant (MCP host) | hosts the MCP server, the `rbx-*` skills and the playtest agent (beta) | **BUILT-IN** / MCP | **SELECT** as host; the playtest agent is **REVISIT** (beta, daily cap, false positives) |
| Script Sync | Syncs `Script`/`LocalScript`/`ModuleScript`/`Folder` with `.luau` files both ways; up to 10,000 scripts per synced instance; "third-party tools like Rojo are a better choice" for whole-project version control. Its page says it is not beta; the coding-harness page says to enable a beta (conflict) | **BUILT-IN** / FILES | **REVISIT** for a game repo that uses Team Create; Rojo stays the factory's sync |
| Avatar Setup, Material Generator | built in; Avatar Setup "Save" opens Asset Configuration (upload or publish with fees) | **BUILT-IN** / GUI-ONLY | reference only, and REJECT in the factory (blender and visual-audio docs) |
| Luau LSP companion | Sends "serialized tree updates" of the DataModel over HTTP to `http://localhost` port 3667; settings documented for VS Code only | **OWNER-STORE** / none for agents | **REVISIT**: only useful for the owner in VS Code when editing Studio-only instances; Rojo sourcemaps cover the factory |
| Moon Animator 2 | paid | OWNER-STORE | **REJECT** (unchanged) |
| Archimedes 3 (Scriptos) | free arc-building plugin (2022-01-02); source "currently proprietary"; listing shows v3.1.9 | OWNER-STORE / GUI-ONLY | **REJECT**: closed source with full place access; arcs come from Blender or SceneKit paths |
| F3X Building Tools | `F3XTeam/RBX-Building-Tools`: 62 stars, licence not shown, in-game tool plus plugin with an export feature | OWNER-STORE / GUI-ONLY | **REJECT**: native Studio tools and SceneKit cover it |
| Brushtool 2.1 (XAXA) | free (economy endpoint: not for sale, public domain), updated 2026-05-14 | OWNER-STORE / GUI-ONLY | **REJECT**: manual scatter is not reproducible; ProcGen and SceneKit scatter with seeds |
| Model Reflow | no primary source found | n/a | **REJECT** (unverifiable; price UNVERIFIED) |
| Interface Tools (fivefactor) | free (2019-12-09): Material Icons (Apache-2.0), Kenney icons, a contrast checker, "Custom asset upload" | OWNER-STORE / GUI-ONLY | **REJECT**: stale and uploads. Take icons from their CC0 or Apache sources through the asset pipeline instead |
| TweenSequence Editor (pa00) | free (2019-01-02); exports an Animator ModuleScript; last author update 2019 | OWNER-STORE / GUI-ONLY | **REJECT**: stale; native styling transitions and the planned cinematics data tracks cover it |
| Flipbook, UI Labs, vfx-editor | see the addendum and ui-cinematics doc 4c | OWNER-STORE | **REVISIT** (unchanged) |

**Owner list.** Required Creator Store installs: **none**. Required local plugin: Rojo, through `rojo plugin install`. Optional later: the Luau LSP companion (VS Code users), and one storybook plugin once a UIKit gallery exists.

## 9. Desktop tools for a Windows creator PC

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Inkscape | https://inkscape.org/release/ ; https://wiki.inkscape.org/wiki/Using_the_Command_Line ; winget `Inkscape.Inkscape` | Inkscape project | 1.4.4 (news post dated 2026-05-06; 1.5 in development) | 2026-05-06 | active | GPL (the winget manifest says GPL-3.0-or-later; the vendor licence page was blocked) | free |
| OBS Studio | https://github.com/obsproject/obs-studio/releases ; https://github.com/obsproject/obs-websocket ; winget `OBSProject.OBSStudio` | OBS Project | 32.2.2 | 2026-08-14 | active | GPL (obs-websocket: GPL-2.0) | free |
| Blockbench | https://github.com/JannisX11/blockbench | JannisX11 | 5.2.1 | 2026-09-21 | active; 5.7k stars | GPL-3.0 | free |
| LMMS | https://github.com/LMMS/lmms/releases | LMMS | 1.2.2 stable; 1.3.0-alpha.2 | 2020-07-04; 2024-09-06 | stable line stale | GPLv2+ (release notes) | free |
| jsfxr | https://github.com/chr15m/jsfxr ; npm `jsfxr` | chr15m | 1.4.1 | unknown | 451 stars | Unlicense | free |
| Upscayl | https://github.com/upscayl/upscayl/releases | Upscayl | v2.15.0 | 2024-12-25 (release page) | unknown | not shown | free |
| resvg (CLI) | https://github.com/linebender/resvg ; crates.io `resvg` | linebender | 0.48.1 | 2026-08-02 (crates.io) | active | Apache-2.0 OR MIT | free |
| Already planned: Krita, Audacity, glTF Transform, ImageMagick, Material Maker, FFmpeg | blender pipeline doc 8.1; `knowledge/records/tools-options.json`; visual-audio doc 5; addendum F | various | 5.3.4; n/a; 4.5.1; 7.1.2-32; 1.6 or 1.7; 9.0.2 | see those docs | active | GPL / GPL / MIT / ImageMagick / MIT / LGPL-GPL | free |

| Candidate | Purpose / capabilities | Security | Overlap | Install / drive | Benefit | Decision |
|---|---|---|---|---|---|---|
| Inkscape | `inkscape --export-type="png" --export-filename=out.png my_file.svg`, `--export-id` for one object, `--actions` and `--shell` for batches | local app; official installer or winget only | Krita (raster); resvg (Linux and macOS binaries only, no Windows asset in v0.48.1) | **OWNER-UI** or **AGENT** (`winget install Inkscape.Inkscape` after approval) / CLI and FILES (SVG is text an agent writes and diffs) | UI icons, button frames, badges and 9-slice art authored as reviewable SVG and rasterized at exact sizes. The same CLI runs on Linux, so the container can prove it | **SELECT** (gap G4) |
| OBS Studio | capture and composition; obs-websocket bundled "since OBS Studio 28.0.0", port 4455, password generated on first load | the websocket password is a secret; a scene can capture anything on screen | FFmpeg `gdigrab` (addendum F) | OWNER-UI; agents could drive the websocket (CLI client not chosen) | trailer and store-video capture | **REVISIT** when a game repo reaches store assets; FFmpeg stays the agent capture path |
| Blockbench | low-poly modelling and pixel texture painting; glTF/OBJ export; JS plugins; no CLI; no Roblox exporter | plugins can be proprietary | Blender `bkit` templates and QA | OWNER-UI / GUI-ONLY | a fast blocky-style editor for a person | **REJECT** for the factory (no agent path; Blender covers it); a personal install is harmless |
| LMMS | music sequencing | none special | Roblox-licensed music (visual-audio doc 4) | OWNER-UI / GUI-ONLY | original music | **REJECT** (stable release from 2020; music is game content) |
| jsfxr | presets (`pickupCoin`, `laserShoot`, `explosion`, `powerUp`, `hitHurt`, `jump`, `blipSelect` ...), `toWave`/`toBuffer`, CLI `sfxr-to-wav`; determinism needs saved parameters (presets use random values) | npm supply chain | Kenney CC0 audio, Sonniss (visual-audio doc) | AGENT (`npx jsfxr@1.4.1`) / CLI and FILES | placeholder SFX from parameter files with no binary in git | **REVISIT** in a game repo (8-bit timbre is a style choice). Roblox audio still needs an upload to play |
| Bfxr | desktop sfxr variant | not checked | jsfxr | GUI | none over jsfxr | **REJECT** |
| Upscayl | AI upscaling (Real-ESRGAN family) | model licences not shown | CC0 textures already ship at 1K to 8K | OWNER-UI | none | **REJECT** |
| resvg | SVG renderer and CLI | small Rust binary | Inkscape | Linux binary from the release; Windows needs `cargo install` | faster CI rendering | **REVISIT** only if Inkscape is too heavy for CI |
| Planned set | see those docs | see those docs | see those docs | Krita and Audacity: OWNER-UI, GUI mostly; glTF Transform: AGENT with pinned `npx @gltf-transform/cli@4.5.1`; FFmpeg: CLI | see those docs | Agree with the siblings: Krita and Audacity optional, glTF Transform SELECT, FFmpeg SELECT. **ImageMagick and Material Maker are REJECT as repo dependencies** in the sibling docs. If the owner installs them anyway, that is harmless, but no gate or skill may depend on them; ImageMagick needs the vendor's security policy |

## 10. VS Code extensions

| Extension (id) | Version (Open VSX unless stated) | Licence | Purpose | Decision |
|---|---|---|---|---|
| Luau Language Server (`JohnnyMorganz.luau-lsp`) | 1.70.1, 2026-09-27; verified publisher | MIT | types, completion and hover for Luau with Rojo sourcemaps | **SELECT** |
| StyLua (`JohnnyMorganz.stylua`) | 1.7.2, 2026-05-16 | MPL-2.0 | format on save with the repo's `stylua.toml` | **SELECT** |
| Selene (`Kampfkarren.selene-vscode`) | not on Open VSX; VS Code Marketplace shows 70,492 installs, version not read (UNVERIFIED) | not read | inline lint with `selene.toml` | **SELECT** |
| Claude Code (`anthropic.claude-code`) | 2.1.290, 2026-10-05 | Anthropic legal terms | Claude Code in the editor; shares plugins with the CLI | **SELECT** |
| Codex (`openai.chatgpt`) | 26.5908.31748, 2026-09-11 | see its LICENSE.md | Codex in the editor | **SELECT** |
| Rojo (`evaera.vscode-rojo`) | 2.1.2, 2022-08-26 | see its LICENSE.txt | starts `rojo serve` from the editor | **REJECT**: stale; the CLI does the same |

Install route: OWNER-UI, or AGENT with `code --install-extension <id>` after approval. These are owner editor tools, not repo dependencies.

## 11. Owner PC install list (generic; feeds gap G9)

| Tier | Item | Who installs | Route | Agent drives it through |
|---|---|---|---|---|
| In use | Roblox Studio (MCP server built in) | OWNER-UI | Roblox installer | MCP |
| In use | Blender 5.2 LTS | OWNER-UI | blender.org | CLI (`blender -b -P`), MCP |
| In use | Rokit toolchain (rojo, lune, stylua, selene, luau-lsp) | AGENT | `rokit install` | CLI |
| In use | Node.js (hooks), Python 3, uv, Git, FFmpeg | OWNER-UI or AGENT | vendor installers or winget | CLI |
| Add | Rojo Studio plugin | AGENT | `rojo plugin install` | FILES |
| Add | VS Code plus the five extensions in section 10 | OWNER-UI or AGENT | VS Code UI or `code --install-extension` | LSP, editor |
| Add | Inkscape | OWNER-UI or AGENT | winget `Inkscape.Inkscape` | CLI |
| Optional | Krita, Audacity | OWNER-UI | vendor installers | mostly GUI |
| Optional | glTF Transform | AGENT | `npx @gltf-transform/cli@4.5.1` (no global install) | CLI |
| Optional | ChatGPT GitHub app (read-only, this repo only) | OWNER-UI | ChatGPT settings | n/a |
| Trial | Blender Lab MCP add-on and server | OWNER-UI (add-on), AGENT (server from the pinned tag) | `https://lab.blender.org/` extension repository; pip or uvx from git | MCP |
| Later (REVISIT) | OBS Studio; jsfxr; a storybook plugin; Luau LSP companion | as above | as above | as above |
| Do not install | community Roblox MCP servers; Roblox skill packs; Moon Animator 2 and any re-upload; Archimedes, F3X, Brushtool, Interface Tools, TweenSequence Editor; Blockbench, LMMS, Bfxr, Upscayl as factory tools; Figma, Linear, Notion, Asana, Canva and Adobe connectors for the factory; Roblox "Build" (mobile game creation that auto-publishes: "goes live on your profile. No approval process"); Studio Assistant BYOK (API billing; Claude Code already drives Studio) | n/a | n/a | n/a |

## 12. Gaps and implementation input

| # | Capability | Deliverable | Verification (container unless stated) | Priority / effort |
|---|---|---|---|---|
| G1 | Studio MCP tools fully classified, and Roblox's built-in skills used | `guard_mcp.mjs`: `subagent` added to `ASK_TOOLS`; `skill`, `wait_job_finished` and `search_asset` added to `READ_TOOLS`. Owner edits `.claude/settings.json`: allow those three, ask for `subagent` and `http_get`. `.codex/config.toml`: `approval_mode = "prompt"` for `subagent`. `docs/mcp.md` tool table; `roblox-studio-testing`, `roblox-performance-pass` and `roblox-ui-ux-pass` point to `skill` with `rbx-debug`, `rbx-perf-profiling` and `rbx-device-simulator-lua` | `node tools/hooks/selftest.mjs` with new cases (subagent asks under Claude and is denied under Codex; the three reads pass; a `search_asset` query containing "SetAsync" passes); `python3 tools/sync_skills.py --check`. Studio: owner calls `skill` and `subagent` once and records the prompts | P1 / S |
| G2 | No unguarded MCP surface | Owner adds `"disableClaudeAiConnectors": true` to `.claude/settings.json` (and the starter template). New `tools/hooks/guard_mcp_other.mjs` with a PreToolUse catch-all for every other MCP server: ask under Claude, deny under Codex, with an explicit allow-list for read-only GitHub tools. Codex matcher syntax for "every other server" is UNVERIFIED (lookahead may be unsupported), so the script itself skips Studio and Blender tools | selftest feeds `mcp__figma__create_new_file` (ask/deny), `mcp__github__get_file_contents` (allow) and a Studio read (unchanged decision); fresh-session check that no claude.ai connector tools load | P1 / S |
| G3 | Luau code intelligence in the agent loop | Bump `rokit.toml` to luau-lsp 1.70.1. `tools/luau_defs.py`: fetch the definitions and docs files into gitignored `build/luau-lsp/` and verify them against a committed sha256 lock. Gate step `luau-lsp-analyze` (pre-release first, against a counted baseline, then pre-commit). Repo-local plugin `plugins/luau-lsp/` (`.claude-plugin/plugin.json` plus `.lsp.json` mapping `.luau` to `luau-lsp lsp --definitions:@roblox=${CLAUDE_PROJECT_DIR}/build/luau-lsp/<file>`) behind a local marketplace; the owner enables it (it waits for workspace trust) | `luau-lsp analyze` exit status and diagnostic count over `packages/` and fixtures match the baseline; a planted type error in a scratch copy raises the count. Plugin: `claude --plugin-dir plugins/luau-lsp` in a terminal session, plant an error, expect "Found N new diagnostic issues" (cloud sessions do not start LSPs) | P1 / M |
| G4 | UI raster pipeline (SVG to PNG) | `tools/ui_raster.py`: renders SVG sources with the Inkscape CLI to declared sizes; checks size (1024 or less), alpha, trimmed bounds and declared 9-slice margins (JSON sidecar); records each output in the asset sources manifest. Neutral fixture SVGs (shapes only) under `fixtures/`; SKIP when Inkscape is absent; skill text in `roblox-ui-ux-pass` | Container with Inkscape: render fixtures, check dimensions and alpha, pixel hash stable per Inkscape version (golden keyed by version). Studio display needs an upload, so it waits for a game repo and the owner | P2 / M |
| G5 | Brief-to-release production planning | New genre-neutral skill `game-production-plan`: milestones (prototype, vertical slice, content complete, beta, release candidate), each with definition-of-done tied to existing gates and skills; `templates/starter/docs/production-plan.md` and `.github/ISSUE_TEMPLATE/` (feature, bug, asset request with a provenance field); `tools/plan_issues.py` turns `plan.json` into `gh issue create` commands, printed by default and run only in a game repo | Schema and unit tests for `plan.json` and the generated command list; `starter-smoke` sees the new templates; no `gh` write in the factory | P1 / M |
| G6 | Official Blender MCP trial | Optional `blender_lab` entry documented in `docs/mcp.md` (commented example for `.mcp.json` and `.codex/config.toml`, git tag `v1.0.3`); a trial report comparing it with mcp-for-blender (docs search accuracy on 10 bpy questions, screenshot parity, telemetry, socket port) | Container: start the server and list tools over stdio (expect the 26 names); guard selftest for `mcp__blender_lab__execute_blender_code`. `_for_cli` tools need a Blender binary (the bpy wheel may not be enough: UNVERIFIED). Interactive tools: owner's PC with Blender 5.1+ | P2 / M |
| G7 | Skill trigger evaluation | `tests/skill-triggers.json` (3 should-trigger and 2 should-not prompts per skill) and `tools/skill_evals.py`: runs `claude -p` with streamed JSON, optionally `codex exec`, records which skill loaded; opt-in pre-release step, since it costs tokens. Method from `skill-creator` | Logged-in headless Claude Code in the container: at least 90% positive triggers and no wrong-skill loads on the negatives; report under `reports/`. Codex needs a login | P2 / M |
| G8 | Factory updates reach game repos | Package skills, guards and the luau-lsp plugin as one Claude plugin plus a Codex plugin (portable `plugin.json`), served from this repo's marketplace and pinned by tag in each game repo, replacing the one-time copies described in `docs/starter.md`. Hooks stay pinned (no auto-update) | `claude plugin validate`; scaffold a game repo, install from a local marketplace path, confirm the skills list and hook selftest. Codex: `codex plugin marketplace add ./` in a scratch copy | P2 / L (REVISIT trigger: a second game repo, or observed skill drift) |
| G9 | Owner PC setup is documented and checkable | `docs/pc-setup.md` (section 11 without any machine specifics) and `tools/pc_doctor.py --json`: reports the presence and version of each tier-1 tool, installs nothing. Move the "Local machine notes" in `docs/mcp.md` to a private note | Unit test with a fake PATH; a container run reports PASS/SKIP deterministically. The owner runs it on the PC | P1 / S |

**Proposed gap-matrix updates (not applied here; `reports/gap-matrix.json` is edited separately):** T09 (luau-lsp pin 1.70.1; Rojo 7.7.1); M01 (26 tools, four unclassified, G1); T04 and T13 (unguarded connector and plugin surfaces, G2); M02 and M04 (Blender Lab trial, G6); D01 (cite this file); new rows for Luau code intelligence (G3), the UI raster pipeline (G4), production planning (G5), skill trigger evals (G7) and owner PC setup (G9).

## 13. UNVERIFIED

- Whether the Studio `subagent` (explore or playtest) can call asset-creating or quota tools, and whether the playtest beta flag is still required.
- Whether Studio Assistant can now act as an MCP client to third-party servers (planned 2026-02-21; no release found).
- Where Studio stores custom Assistant skills, and whether `skill` returns custom ones.
- Blender Lab MCP: telemetry, the add-on socket's default port, whether `uvx --from git+...@v1.0.3#subdirectory=mcp blender-mcp` starts as expected, and whether `_for_cli` tools work with the bpy wheel instead of a Blender binary.
- The claude-plugins-official catalog after the letter "l" (not scanned); Playwright and others are known to exist from search results only.
- Figma's Starter quota (20 per month on the docs page versus 6 in the guide README).
- Whether Codex hook matchers support regex lookahead, and how to disable ChatGPT plugins per project in Codex.
- Which luau-lsp definitions security level (`None`, `LocalUserSecurity`, `PluginSecurity`) suits game scripts versus plugin code.
- Script Sync beta status (the two Roblox pages conflict).
- Selene VS Code extension version; GitHub MCP and Figma guide licences; Inkscape's exact licence version; OBS's exact licence.
- Rojo 7.7.1 on GitHub releases (crates.io has it; the release page showed 7.7.0 as latest).
- Archimedes, Brushtool and Interface Tools listings were not inspected in Studio; price facts come from DevForum posts and one economy endpoint read.
- Claude Code CLI version on 2026-10-06 (npm endpoints returned 2.1.283, 2.1.289 and, in the earlier pass, 2.1.290).

## Sources (all fetched 2026-10-06)

- Roblox docs: https://create.roblox.com/docs/en-us/studio/mcp.md , https://create.roblox.com/docs/en-us/assistant/skills.md , https://create.roblox.com/docs/en-us/ai/coding-harness.md , https://create.roblox.com/docs/en-us/ai/build.md , https://create.roblox.com/docs/en-us/ai/accelerated-workflows.md , https://create.roblox.com/docs/en-us/scripting/sync.md , https://create.roblox.com/docs/en-us/avatar-setup.md , https://create.roblox.com/docs/en-us/studio/material-generator.md , https://create.roblox.com/docs/en-us/parts/model-generation.md , https://create.roblox.com/docs/en-us/reference/engine/classes/CollectionService.md , https://create.roblox.com/docs/llms.txt
- DevForum: https://devforum.roblox.com/t/studio-mcp-multi-agent-improvements-and-connected-ai-clients/4820583 , https://devforum.roblox.com/t/assistant-updates-mesh-generation-new-mcp-server-tools-screenshot-tool-and-more/4527258 , https://devforum.roblox.com/t/studio-beta-studio-assistant-mcp-playtest-agent/4566767 , https://devforum.roblox.com/t/studio-mcp-server-updates-and-external-llm-support-for-assistant/4415631 , https://devforum.roblox.com/t/assistant-updates-studio-built-in-mcp-server-and-playtest-automation/4474643 , https://devforum.roblox.com/t/tag-editor-plugin-for-studio/2055202 , https://devforum.roblox.com/t/introducing-archimedes-3-a-building-plugin/1610366 , https://devforum.roblox.com/t/plugin-interface-tools/404423 , https://devforum.roblox.com/t/tweensequence-editor/218976
- Roblox economy endpoint (one plugin, read-only GET): `https://economy.roblox.com/v2/assets/<id>/details`
- Claude: https://code.claude.com/docs/en/discover-plugins , https://code.claude.com/docs/en/plugins/anthropic-marketplaces , https://code.claude.com/docs/en/plugins/code-intelligence , https://code.claude.com/docs/en/plugins/components , https://code.claude.com/docs/en/plugins/manifest-reference , https://code.claude.com/docs/en/settings , https://code.claude.com/docs/en/mcp , https://claude.com/docs/connectors/directory , https://claude.com/connectors , https://claude.com/marketplace/plugins?q=roblox , https://www.anthropic.com/news/claude-for-creative-work , https://github.com/anthropics/claude-plugins-official , https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/.claude-plugin/marketplace.json , https://github.com/anthropics/skills , https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md
- Codex and ChatGPT: https://learn.chatgpt.com/docs/llms.txt , https://learn.chatgpt.com/docs/plugins.md , https://learn.chatgpt.com/docs/build-plugins.md , https://learn.chatgpt.com/docs/skills-and-plugins.md , https://learn.chatgpt.com/docs/image-generation.md , https://developers.openai.com/plugins/build/plugins , https://github.com/openai/skills , https://github.com/openai/plugins , https://help.openai.com/en/articles/11145903-connecting-github-to-chatgpt-deep-research
- Connectors: https://github.com/figma/mcp-server-guide , https://developers.figma.com/docs/figma-mcp-server/rate-limits-access/ , https://linear.app/docs/mcp , https://developers.notion.com/docs/mcp
- Blender: https://www.blender.org/lab/mcp-server/ , https://projects.blender.org/api/v1/repos/lab/blender_mcp , https://projects.blender.org/api/v1/repos/lab/blender_mcp/releases , https://projects.blender.org/api/v1/repos/lab/blender_mcp/contents , https://projects.blender.org/api/v1/repos/lab/blender_mcp/raw/readme_tools.rst , https://projects.blender.org/api/v1/repos/lab/blender_mcp/raw/mcp/README.md , https://projects.blender.org/api/v1/repos/lab/blender_mcp/raw/mcp/pyproject.toml , https://projects.blender.org/api/v1/repos/lab/blender_mcp/raw/mcp/manifest.json
- Community MCPs and skills: https://github.com/boshyxd/robloxstudio-mcp , https://github.com/hope1026/weppy-roblox-mcp , https://github.com/MSayib/roblox-dev-skill , https://github.com/zilibobi/roblox-skills , https://github.com/AshExplained/roblox-skills
- Luau and Rojo: https://github.com/JohnnyMorganz/luau-lsp/releases , https://github.com/JohnnyMorganz/luau-lsp/releases/tag/1.70.1 , https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/README.md , https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/editors/README.md , https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/plugin/README.md , https://rojo.space/docs/v7/getting-started/installation/ , https://github.com/rojo-rbx/rojo/releases , https://github.com/F3XTeam/RBX-Building-Tools
- VS Code and registries: https://open-vsx.org/api/JohnnyMorganz/luau-lsp , https://open-vsx.org/api/JohnnyMorganz/stylua , https://open-vsx.org/api/evaera/vscode-rojo , https://open-vsx.org/api/Anthropic/claude-code , https://open-vsx.org/api/openai/chatgpt , https://marketplace.visualstudio.com/items?itemName=Kampfkarren.selene-vscode , https://registry.npmjs.org/-/v1/search?text=%40openai%2Fcodex&size=3 , https://registry.npmjs.org/-/v1/search?text=%40anthropic-ai%2Fclaude-code&size=3 , https://registry.npmjs.org/@anthropic-ai/claude-code/latest , https://registry.npmjs.org/@openai/codex/latest , https://registry.npmjs.org/jsfxr/latest
- Desktop tools: https://inkscape.org/release/ , https://wiki.inkscape.org/wiki/Using_the_Command_Line , https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/i/Inkscape/Inkscape/1.2.0/Inkscape.Inkscape.locale.en-US.yaml , https://github.com/obsproject/obs-studio/releases , https://github.com/obsproject/obs-websocket , https://github.com/JannisX11/blockbench , https://github.com/JannisX11/blockbench/releases , https://github.com/LMMS/lmms/releases , https://github.com/chr15m/jsfxr , https://github.com/upscayl/upscayl/releases , https://crates.io/api/v1/crates/resvg , https://crates.io/api/v1/crates/resvg/0.48.1 , https://github.com/linebender/resvg/releases
