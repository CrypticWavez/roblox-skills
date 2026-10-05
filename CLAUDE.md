@AGENTS.md

## Claude Code specifics
- Skills: `.claude/skills/` (generated from `.agents/skills/`; edit the source and run `python3 tools/sync_skills.py`).
- Subagents in `.claude/agents/`: `roblox-engineer` (packages, tests), `technical-artist` (Blender), `qa-reviewer` (read-only verification), `researcher` (docs/research only). Use them for genuinely parallel work with disjoint files; the main session integrates and is the only one that drives Studio MCP.
- Hooks (`.claude/settings.json`): FAST_ON_EDIT checks the touched file (format, JSON, secrets, SKILL.md); PreToolUse guards block publish/upload/force-push commands and ask before asset-creating Studio tools or DataStore writes. Node is required for hooks.
- MCP (`.mcp.json`): `Roblox_Studio` (built-in Studio server) and `blender` (`mcp-for-blender`, telemetry off). Ownership and safety rules: `docs/mcp.md`.
- First run in a new checkout: accept the workspace trust prompt and approve the project MCP servers. Until then Claude ignores the `permissions.allow` list (deny rules and hooks still apply), so every Studio read prompts.
- Keep replies compact: cite report paths and commands instead of pasting large output.
