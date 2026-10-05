---
name: roblox-release-pass
description: Final completion and regression pass for an existing Rojo-based Roblox game - audit repo and Studio state, re-test critical flows in the right Studio modes, harden server authority, fix bugs and fallbacks, check performance/devices, and produce a release-readiness report (not a publish). Use for "finish the game", "make it publish ready", "regression test after big changes".
---

# Release and regression pass

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval.

**Inputs.** Game repo, its completion contract/requirements matrix, target devices, last release notes.

## Procedure
1. Baseline: `python3 tools/check.py --tier pre-release` equivalent in the game repo; list failing gates first.
2. Critical-flow matrix: join, onboarding, core loop, failure/retry, session end, purchase prompts (sandbox), save/load, leave/rejoin. For each: Studio mode (Test / Server & Clients / Run / device emulator), expected result, evidence.
3. Run flows via roblox-studio-testing; capture console + screenshots.
4. Fix root causes with roblox-multiplayer-integrity, roblox-persistence-and-commerce, roblox-ui-ux-pass, roblox-performance-pass as needed; re-run the affected flows plus a regression sweep.
5. Write `reports/release-readiness.json`: flow, status, evidence, open risks, human sign-offs still needed (fun, art, fairness, physical devices).

**Acceptance.** Every critical flow has fresh evidence; no open error-level issue; publishing remains a human action.

**References.** `references/legacy-final-ship.md`, `references/legacy-release-regression.md` (original checklists).

**Related.** all production skills, roblox-studio-testing, visual-qa.
