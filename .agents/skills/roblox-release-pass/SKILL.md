---
name: roblox-release-pass
description: Release-readiness and regression pass for a Rojo-based Roblox game repo made by the factory starter - run tools/release_check.py (automated A01-A17: remotes, catalog, receipts, paid random items, text filtering, accessibility, telemetry, performance, provenance, localisation, debug, deprecated APIs, store text, persistence, publish tripwire, metadata and store art specs), re-test critical flows in Studio, and hand the owner the S/O/P items, which never pass automatically. Not a publish. Use for "make it publish ready", "release candidate", "regression test after big changes".
---

# Release and regression pass

## Purpose
A release-readiness report with fresh evidence: every automated item passes, every critical flow has a Studio run, and the owner has an exact list of what only they can do. Publishing remains the owner's action. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in the factory run it only against `fixtures/release`. Never publish, spend Robux, create live products or touch production data.

## Triggers
"Finish the game", "make it publish ready", a release candidate, the beta or release-candidate stage of `production/pipeline.json`, a regression test after big changes.

## Inputs
`release/release.json` (release-meta/1: name, description, genre, devices, audience, maturity summary, players, access, locales, version notes, and the paths of the catalog, telemetry catalog, localisation tables, perf budgets and captures, paid random items, store art, generated code), `production/brief.json`, `src/`, the Rojo projects, `assets/provenance.json`, `release/owner-*.json` (owner records), last release notes.

## Required context
`docs/release-runbook.md` (generated from the checklist in `tools/release_check.py`: every item, its spec and its Roblox source), roblox-studio-testing for Studio modes, `references/legacy-final-ship.md` and `references/legacy-release-regression.md` (original checklists).

## Tools
- `python3 tools/release_check.py`: writes `release/report.json` (release-check/1); exit 1 while an automated item fails. `python3 tools/check.py --tier pre-release` runs it after the whole gate.
- Studio MCP (`start_stop_play`, `execute_luau`, `get_console_output`, `screen_capture`, input simulation), Device Simulator and Player Emulator, on an unpublished place built with `rojo build default.project.json`.
- Kits the checks expect: GameKit/RemoteGuard (A02), GameKit/Catalog and GameKit/CommerceRoblox (A03, A04), GameKit/PolicyGate and GameKit/OddsTable (A05), GameKit/TextFilter (A06), GameKit/Settings (A07), GameKit/Telemetry (A08), GameKit/PlayerData (A15).

## Procedure
1. Baseline: `python3 tools/check.py --tier pre-release`. Fix automated failures at the root (never by weakening a check or editing the checker, which is factory-managed). A16 hits are removed, or the owner records an exception.
2. Critical-flow matrix (S01): join, onboarding, core loop, fail and retry, session end, purchase prompts (Studio test purchases only), save and load, leave and rejoin; each in Play Solo and Server & Clients with 2+ clients, plus the boot report (S07: BOOT_REPORT ok on both sides, loading screen clears).
3. Run the flows with roblox-studio-testing; capture console output and screenshots. Device Simulator per declared device (S04), Player Emulator per target locale and policy region (S03), telemetry sequence (S05), performance capture saved as perf/1 stats under `release/perf` and listed in `release/release.json` (S06, feeds A09).
4. Fix root causes with roblox-multiplayer-integrity, roblox-persistence-and-commerce, roblox-ui-ux-pass and roblox-performance-pass; re-run the affected flows plus a regression sweep, then `python3 tools/release_check.py` again.
5. Hand the owner the S/O/P list from `release/report.json` with the evidence gathered: account requirements, maturity questionnaire, audience, genre and devices, products and pricing, icon (512x512), thumbnails (16:9, under 3 MB, up to 10), badges (512x512), passes, friend-invite message, localisation settings, social links, publish with version notes, after-publish checks. The owner records each in a `release/owner-<name>.json` file.

## Outputs
`release/report.json`, the evidence it cites (console excerpts, captures, perf/1 files), and a short report: automated pass/fail counts, flows run with their mode and result, open risks, the owner items waiting, and human sign-offs still needed (fun, art, fairness, physical devices).

## Acceptance
`release/report.json` shows every A item PASS (or A16 WAIVED_BY_OWNER); every S item has fresh evidence from this pass handed to the owner; every S, O and P item still reads OWNER_REQUIRED in the report (the tool never passes them, an agent never writes `release/owner-*.json`); no open error-level issue; publishing is left to the owner.

## Failure
- An automated check looks wrong: report it with the file and line; fix the checker in the factory (`templates/starter/tools/release_check.py`) and pull it with `new_project.py --update`, never by editing it here.
- A flow cannot be run here (physical device, live services, real purchases): mark it BLOCKED_EXTERNAL with the owner's steps, not as passed.
- A regression appears late: fix it, then re-run the whole affected flow set, not only the fixed step.

## Related
roblox-production-pipeline, roblox-studio-testing, visual-qa, roblox-multiplayer-integrity, roblox-persistence-and-commerce, roblox-ui-ux-pass, roblox-performance-pass, roblox-asset-intake.
