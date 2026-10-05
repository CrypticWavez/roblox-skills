---
name: roblox-research
description: Run a dated, sourced research pass on Roblox tooling, Studio features, Luau/Blender/MCP/Claude Code ecosystem, or market/visual references, and record each candidate with source, publisher, version, date, licence, price, security, overlap, Claude/Codex access and a SELECT/REJECT decision. Use before adding any tool or making a market claim.
---

# Research

**Purpose.** Decisions backed by primary sources, recorded so the next agent does not redo them.

**Inputs.** Question, scope (tooling / market / visual reference), date.

## Procedure
1. Check existing records first: `docs/research/` (latest: `tooling-2026-10.md`), `knowledge/records/*.json`. Do not redo a fresh pass on the same question.
2. Primary sources first: create.roblox.com docs, DevForum announcements, GitHub repo pages/releases, PyPI/crates/npm, vendor pricing pages. Community posts (Reddit, YouTube) only as leads to verify.
3. For each tool record: NAME, OFFICIAL SOURCE, PUBLISHER, VERSION, LAST UPDATE, MAINTENANCE, LICENSE, PRICE, PURPOSE, CAPABILITIES, SECURITY, OVERLAP, AUTOMATION/CLAUDE/CODEX ACCESS, EXPECTED BENEFIT, SELECT/REJECT. Mark anything not confirmed as UNVERIFIED.
4. Market/chart research: dated snapshots only; never infer popularity from design opinion or motion/audio from stills; no claims about revenue or retention.
5. Write the result to `docs/research/<topic>-<yyyy-mm>.md` (or a JSON record under `knowledge/records/`) and link it from `docs/gap-matrix.md` when it changes a decision.

**Acceptance.** Every claim has a URL and access date; recommendations follow from recorded facts.

**Related.** roblox-asset-intake.
