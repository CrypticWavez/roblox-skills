---
name: roblox-release-pass
description: Final completion and regression pass for an existing Rojo-based Roblox game - audit repo and Studio state, re-test critical flows in the right Studio modes, harden server authority, fix bugs and fallbacks, check performance/devices, and produce a release-readiness report (not a publish). Use for "finish the game", "make it publish ready", "regression test after big changes".
---

# Release and regression pass

## Purpose
A release-readiness report with fresh evidence for every critical flow. Publishing remains a human action. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures. Never publish, spend Robux, create live products or touch production data.

## Triggers
"Finish the game", "make it publish ready", a regression test after big changes, a release candidate.

## Inputs
The game repo, its completion contract or requirements matrix, target devices, last release notes.

## Required context
The game repo's own gate and completion contract; `references/legacy-final-ship.md` and `references/legacy-release-regression.md` (original checklists); roblox-studio-testing for modes.

## Tools
The game repo's equivalent of `python3 tools/check.py --tier pre-release`; Studio MCP (`start_stop_play`, `execute_luau`, `get_console_output`, `screen_capture`, input simulation); the device emulator.

## Procedure
1. Baseline: run the game repo's pre-release gate; list failing gates first.
2. Critical-flow matrix: join, onboarding, core loop, failure/retry, session end, purchase prompts (sandbox), save/load, leave/rejoin. For each: Studio mode (Test, Server & Clients, Run, device emulator), expected result, evidence.
3. Run the flows via roblox-studio-testing; capture console output and screenshots.
4. Fix root causes with roblox-multiplayer-integrity, roblox-persistence-and-commerce, roblox-ui-ux-pass and roblox-performance-pass as needed; re-run the affected flows plus a regression sweep.
5. Write `reports/release-readiness.json` in the game repo: flow, status, evidence, open risks, human sign-offs still needed (fun, art, fairness, physical devices).

## Outputs
`reports/release-readiness.json` and the evidence it cites (console excerpts, captures, gate report).

## Acceptance
Every critical flow has fresh evidence from this pass; no open error-level issue; publishing is left to a human.

## Failure
- A flow cannot be run here (physical device, live services): mark it BLOCKED_EXTERNAL with the owner steps, not as passed.
- A regression appears late: fix it, then re-run the whole affected flow set, not only the fixed step.

## Related
roblox-studio-testing, visual-qa, roblox-multiplayer-integrity, roblox-persistence-and-commerce, roblox-ui-ux-pass, roblox-performance-pass.
