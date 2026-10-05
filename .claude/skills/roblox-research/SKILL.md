---
name: roblox-research
description: Run a dated, sourced research pass on Roblox tooling, Studio features, Luau/Blender/MCP/Claude Code ecosystem, or market/visual references, and record each candidate with source, publisher, version, date, licence, price, security, overlap, Claude/Codex access and a SELECT/REJECT decision. Use before adding any tool or making a market claim.
---

# Research

## Purpose
Decisions backed by primary sources and recorded so the next agent does not redo them.

## Triggers
Before adding a tool, plugin, MCP server or dependency; before any market, popularity or visual-reference claim; when a recorded decision may be stale.

## Inputs
The question, the scope (tooling, market or visual reference) and today's date.

## Required context
Existing records first: `docs/research/` (latest `tooling-2026-10.md`) and `knowledge/records/*.json`. `reports/gap-matrix.json` rows for the capability in question.

## Tools
Web search and fetch for primary sources; `rg` over `docs/research/` and `knowledge/records/`; `python3 tools/gap_matrix.py` to regenerate `docs/gap-matrix.md` after editing the JSON.

## Procedure
1. Check the existing records; do not redo a fresh pass on the same question.
2. Primary sources first: create.roblox.com docs, DevForum announcements, GitHub repo pages and releases, PyPI/crates/npm, vendor pricing pages. Community posts (Reddit, YouTube) are leads to verify, not sources.
3. For each tool record: NAME, OFFICIAL SOURCE, PUBLISHER, VERSION, LAST UPDATE, MAINTENANCE, LICENSE, PRICE, PURPOSE, CAPABILITIES, SECURITY, OVERLAP, AUTOMATION/CLAUDE/CODEX ACCESS, EXPECTED BENEFIT, SELECT/REJECT. Mark anything not confirmed as UNVERIFIED.
4. Market/chart research: dated snapshots only; never infer popularity from design opinion or motion/audio from stills; no revenue or retention claims.
5. Write the result to `docs/research/<topic>-<yyyy-mm>.md` (or a JSON record under `knowledge/records/`).
6. When it changes a decision, record it in the relevant row of `reports/gap-matrix.json` (for example cite the file in its `evidence` or `fix` field), then run `python3 tools/gap_matrix.py`. Never edit `docs/gap-matrix.md`: it is generated, and the gate fails when it is stale.

## Outputs
A dated research file or JSON record, and the updated gap-matrix row with its regenerated doc.

## Acceptance
Every claim has a URL and access date; recommendations follow from the recorded facts; `python3 tools/gap_matrix.py --check` passes.

## Failure
- Source unreachable or contradictory: mark the fact UNVERIFIED with what was tried, and do not SELECT on it.
- Gate step `gap-matrix` fails: the doc was edited by hand or the JSON is invalid; fix the JSON and regenerate.
- Never install, buy or sign up for a tool during research.

## Related
roblox-asset-intake, luau-quality.
