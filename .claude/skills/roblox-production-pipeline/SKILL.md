---
name: roblox-production-pipeline
description: Run a game repository through its production stages (concept, greybox, vertical-slice, alpha, beta, release-candidate) - read production/pipeline.json and the game brief, report each exit gate, write issue drafts with tools/plan_issues.py, keep brief, AGENTS.md tables and decisions log in step, and stop at owner gates. Genre-neutral; use in a game repo created by tools/new_project.py, never to decide what the game is.
---

# Production pipeline

## Purpose
Move a game repository from an explicit game-build request to a release candidate in stages with checkable exit gates, so every team member and agent knows what "done" means now. **Gate:** production skill. It acts on a game repository created by `tools/new_project.py` for an explicit game-build request; in the factory it applies only to the starter templates and `fixtures/release`. It never decides genre, theme, world, characters, economy numbers or UI: those come from the request or the owner and are recorded in `production/brief.json`.

## Triggers
"What's next for the game", "plan the next stage", "write the issues for greybox", "are we ready for alpha", starting work in a fresh game repository, a stage review, or a brief field being decided.

## Inputs
`production/pipeline.json` (production-pipeline/1: `current` stage, stages with `goal`, `skills`, `exit` gates), `production/brief.json` (game-brief/1), `docs/design/*.md`, `release/report.json` when the release checker has run, `release/owner-*.json` (owner records), `starter.json` (installed packages and module tiers).

## Required context
The game repo's `AGENTS.md` (decision tables, boundary), `docs/production-plan.md` (stages, roles, working loop), `docs/release-runbook.md` (release item ids used by `release` gates), `docs/decisions.md`. Gate kinds: `brief` (fields decided), `file` (design doc `Status:` no longer TBD), `gate` (a `tools/check.py` tier passes), `release` (release checklist items), `playtest` and `owner` (only the owner records them).

## Tools
- `python3 tools/production.py status`: current stage, each exit gate as DONE, OPEN, RUN, OWNER_REQUIRED or OWNER_RECORDED, and the TBD brief fields.
- `python3 tools/plan_issues.py [--stage STAGE]`: one Markdown draft per open gate in `build/issue-drafts/<stage>/` plus `index.json`; no API calls. Issue forms: `.github/ISSUE_TEMPLATE/{system,asset,bug,playtest}.yml`.
- `python3 tools/check.py` (step `brief`: brief valid for the stage, passed stages fully gated, `AGENTS.md` tables equal to the brief) and `python3 tools/release_check.py`.

## Procedure
1. Run `python3 tools/production.py status`. Read the stage goal and its skills; open each named skill only when its work starts.
2. For `brief` gates: list the TBD fields to the owner with what each unblocks. Fill a field only from the request or an owner answer; record it in `docs/decisions.md` (date, decision, who, source), `production/brief.json` and the matching `AGENTS.md` row in one commit.
3. Run `python3 tools/plan_issues.py`; review the drafts, trim or split them into small issues, and hand them to the owner or team to create. Never create issues, labels or milestones through an API unless the owner asks for that action.
4. Work the issues with the stage's skills. Kit modules first (`starter.json` modules and tiers); new game code in `src/` with a Lune spec; `python3 tools/check.py` before each commit.
5. For `release` gates run `python3 tools/release_check.py` and fix automated failures at the root. For S/O items prepare what the owner needs (steps, captures, text) and stop.
6. When every gate shows DONE or OWNER_RECORDED, tell the owner the stage is ready for review. Only the owner records owner and playtest gates and moves `current`; the gate fails if a passed stage lacks them.

## Outputs
A status summary (stage, gates, TBD fields, blockers), issue drafts under `build/issue-drafts/<stage>/`, decision rows and brief updates with their sources, and the list of owner actions waiting.

## Acceptance
`python3 tools/production.py status` matches what was reported; `python3 tools/check.py` passes (step `brief` included); every decided brief field has a decision row with a source; no owner or playtest gate was marked done by an agent; nothing chose game content without a source.

## Failure
- A brief field is needed but nobody has decided it: ask the owner with options and their consequences; keep it TBD and work on what does not depend on it.
- Step `brief` fails after `current` moved: the stage was advanced without its owner or playtest record or with TBD fields; move `current` back or get the owner's record.
- A release gate stays OPEN on an S or O item: that is the owner's work; report it, do not mark it.
- `plan_issues.py` refuses: fix `production/pipeline.json` (step `brief` names the problem).

## Related
roblox-release-pass, roblox-genre-systems, roblox-luau-testing, roblox-studio-testing, roblox-performance-pass, roblox-ui-ux-pass, roblox-persistence-and-commerce, project-bootstrap.
