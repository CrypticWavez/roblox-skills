---
name: roblox-luau-testing
description: Add focused automated tests for high-risk Luau logic - pure modules in Lune specs (tests/*.spec.luau), Roblox-API logic with Jest Lua inside Studio or the Open Cloud Luau Execution API - covering damage math, rewards, economy, queues, ranking, persistence helpers and generators. Use when adding or changing Luau logic or when a bug needs a regression test.
---

# Luau testing

## Purpose
Every piece of high-risk Luau logic has a fast automated test, including at least one failure case, that runs in the repo gate.

## Triggers
New or changed Luau logic; a bug that needs a regression test; a seed that broke a generator; logic that is only checked by hand in Studio.

## Inputs
The module under test, its risky paths (money, damage, persistence, ranking, generators) and known failure cases or seeds.

## Required context
`tests/run.luau` (runner and the `t` helpers), one existing spec as a pattern (`tests/scenekit.spec.luau`, `tests/procgen.spec.luau`, `tests/inherited.spec.luau`). `references/legacy-testez-author.md` holds the original TestEZ checklist (TestEZ is unmaintained; prefer Jest Lua).

## Tools
- Pure Luau (no Roblox services): Lune, `lune run tests/run.luau [filter]`; `@lune/roblox` gives datatypes and DataModel construction (`Instance`, `CFrame`, `Vector3`, `serializePlace`).
- Roblox-dependent logic: Jest Lua (`jsdotlua/jest-lua`, successor to TestEZ) in Studio via `execute_luau`, or headless through the Open Cloud Luau Execution API once an API key and test place exist (BLOCKED_EXTERNAL, gap-matrix D03).

## Procedure
1. Pick the riskiest pure functions first; put Roblox calls behind small adapters so the logic runs in Lune (pattern: `packages/Runtime/ReceiptLedger.luau` with `packages/Runtime/RobloxReceiptAdapter.luau`).
2. Write `tests/<area>.spec.luau` returning a list of `{ name = ..., fn = function(t) ... end }`; use `t.eq` (deep), `t.near`, `t.ok`, `t.throws`. Include seed sweeps for generators and failure cases for validators.
3. Run `lune run tests/run.luau <area>`, then the full suite; keep it under a few seconds.
4. Run PRE_COMMIT (luau-quality), which runs every spec plus the inherited suites.

## Outputs
New or updated `tests/*.spec.luau` files and a green `N passed, 0 failed` runner line.

## Acceptance
New logic has specs including at least one failure case; the suite is green in `python3 tools/check.py`.

## Failure
- A spec needs Roblox services: extract the logic or move the test to Studio (Jest Lua) and record it as a Studio diagnostic.
- Flaky results: remove time and `math.random` dependence; use `packages/ProcGen/Rng.luau` with a fixed seed.
- Never skip, weaken or delete a test to get green.

## Related
luau-quality, roblox-persistence-and-commerce, roblox-procedural-generation.
