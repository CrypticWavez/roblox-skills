---
name: roblox-luau-testing
description: Add focused automated tests for high-risk Luau logic - pure modules in Lune specs (tests/*.spec.luau), Roblox-API logic with Jest Lua inside Studio or the Open Cloud Luau Execution API - covering damage math, rewards, economy, queues, ranking, persistence helpers and generators.
---

# Luau testing

**Where tests run.**
- Pure Luau (no Roblox services): Lune, `lune run tests/run.luau [filter]`. Fast, CI-friendly. Use `@lune/roblox` for datatypes and DataModel construction (Instance, CFrame, Vector3, serializePlace).
- Roblox-dependent logic: Jest Lua (`jsdotlua/jest-lua`, successor to TestEZ) inside Studio via `execute_luau`, or headless through the Open Cloud Luau Execution API (5 min/task) once an API key and test place exist (BLOCKED_EXTERNAL).

## Procedure
1. Pick the riskiest pure functions first; extract Roblox calls behind small adapters so the logic is testable in Lune (pattern: `Runtime/ReceiptLedger.luau` + `RobloxReceiptAdapter.luau`).
2. Write `tests/<area>.spec.luau` returning `{ {name, fn(t)} }`; use `t.eq`, `t.near`, `t.ok`, `t.throws`. Include seed sweeps for generators and failure cases for validators.
3. Run the suite; keep it under a few seconds.

**Acceptance.** New logic has specs including at least one failure case; suite green.

**References.** `references/legacy-testez-author.md` (original TestEZ-focused checklist; TestEZ is unmaintained, prefer Jest Lua).

**Related.** luau-quality.
