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
Existing research first: `knowledge/INDEX.md` lists every doc in `docs/research/` and every record in `knowledge/records/` with its status and scope. Records with scope `workbench` were copied from the owner's local workbench: the paths, commands and receipts they cite exist only there and their `*_on_workbench` statuses cannot be reproduced here, so treat them as leads to re-check, not as evidence. `reports/gap-matrix.json` rows for the capability in question.

## Tools
Web search and fetch for primary sources; `rg` over `docs/research/` and `knowledge/records/`; `python3 tools/knowledge_index.py` to regenerate `knowledge/INDEX.md`; `python3 tools/gap_matrix.py` to regenerate `docs/gap-matrix.md` after editing the JSON; `python3 tools/check.py --live-links` (opt-in) to request every cited URL.

## Procedure
1. Check the existing records; do not redo a fresh pass on the same question.
2. Primary sources first: create.roblox.com docs, DevForum announcements, GitHub repo pages and releases, PyPI/crates/npm, vendor pricing pages. Community posts (Reddit, YouTube) are leads to verify, not sources.
3. For each tool record: NAME, OFFICIAL SOURCE, PUBLISHER, VERSION, LAST UPDATE, MAINTENANCE, LICENSE, PRICE, PURPOSE, CAPABILITIES, SECURITY, OVERLAP, AUTOMATION/CLAUDE/CODEX ACCESS, EXPECTED BENEFIT, SELECT/REJECT. Mark anything not confirmed as UNVERIFIED.
4. Market/chart research: dated snapshots only; never infer popularity from design opinion or motion/audio from stills; no revenue or retention claims.
5. Write the result to `docs/research/<topic>-<yyyy-mm>.md` (or a JSON record under `knowledge/records/` with `id`, `title`, `status`, `scope` (`repo` when every cited path exists here) and `scope_note`), then run `python3 tools/knowledge_index.py`. Asset ids you cite (Creator Store links) go in `assets/provenance.json` as `research_citation`.
6. When it changes a decision, record it in the relevant row of `reports/gap-matrix.json` (for example cite the file in its `evidence` or `fix` field), then run `python3 tools/gap_matrix.py`. Never edit `docs/gap-matrix.md`: it is generated, and the gate fails when it is stale.

## Outputs
A dated research file or JSON record, and the updated gap-matrix row with its regenerated doc.

## Acceptance
Every claim has a URL and access date; recommendations follow from the recorded facts; `python3 tools/check.py` passes, including `doc-links`, `knowledge-index`, `knowledge-paths`, `asset-provenance` and `gap-matrix`.

## Failure
- Source unreachable or contradictory: mark the fact UNVERIFIED with what was tried, and do not SELECT on it.
- Gate step `gap-matrix` fails: the doc was edited by hand or the JSON is invalid; fix the JSON and regenerate.
- `doc-links` fails: a relative link or anchor is broken, or a URL is malformed (put URL patterns in a code span). `knowledge-index` fails: rerun `python3 tools/knowledge_index.py`.
- Never install, buy or sign up for a tool during research.

## Related
roblox-asset-intake, luau-quality.
