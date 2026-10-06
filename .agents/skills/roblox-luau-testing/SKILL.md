---
name: roblox-luau-testing
description: Add focused automated tests for high-risk Luau logic - pure cores in Lune specs (tests/*.spec.luau) against injected fakes (FakeEnv, DataStore, ProfileStore, Marketplace, MemoryStore, Policy), Golden snapshots, the engine-probe contract for T3 adapters, and Jest Lua inside Studio - covering damage math, rewards, economy, queues, ranking, persistence, receipts and generators. Use when adding or changing Luau logic or when a bug needs a regression test.
---

# Luau testing

## Purpose
Every piece of high-risk Luau logic has a fast automated test, including at least one failure case, that runs in the repo gate. Engine-bound adapters carry an honest tier and, at T3, a named Studio probe.

## Triggers
New or changed Luau logic; a bug that needs a regression test; a seed that broke a generator; logic that is only checked by hand in Studio; a new `*Roblox.luau` adapter.

## Inputs
The module under test, its risky paths (money, damage, persistence, receipts, ranking, queues, generators) and known failure cases or seeds.

## Required context
- `tests/run.luau` (runner and the `t` helpers: `t.eq` deep, `t.near`, `t.ok`, `t.throws`), `docs/runtime-kits.md` (core/adapter split, Env, tiers T0-T4), `docs/gamekit-platform.md` (Testing and Studio probes).
- Pattern specs: `tests/gamekit_platform_data.spec.luau` (yielding code on FakeEnv threads), `tests/gamekit_platform_commerce.spec.luau` (marketplace fakes, receipts), `tests/gamekit_platform_queue.spec.luau` (determinism and a golden), `tests/scenekit.spec.luau`, `tests/procgen.spec.luau`.
- Fakes in `tests/fakes/`: `FakeEnv` (clock, `spawn` runs at once, `wait` parks until `advance`, errors and reports collected), `FakeDataStore`, `FakeProfileStore`, `FakeMarketplace`, `FakeMemoryStore`, `FakePolicy`, `FakeConfig`, `FakeTextService`, `FakeAnalytics`, `FakePlatformRoblox`.
- `tests/lib/Golden.luau` and `tests/golden/`; `references/legacy-testez-author.md` (TestEZ is unmaintained; prefer Jest Lua).

## Tools
- Pure Luau: Lune, `lune run tests/run.luau [filter]`; `@lune/roblox` gives datatypes, `Enum` and DataModel construction. Lune's `require` yields inside coroutines it did not start, so require modules at the top of a spec.
- Goldens: `FACTORY_UPDATE_GOLDEN=<name> lune run tests/run.luau <filter>` or `python3 tools/check.py --update-golden=<name>`; never an unscoped update.
- T3 adapters: a probe in a `fixtures/kits/<side>/*_probes.luau` registry plus a `tests/engine/<probe>.luau` entry; `tests/kits_load.spec.luau` enforces headers and registration.
- Roblox-dependent logic beyond probes: Jest Lua (`jsdotlua/jest-lua`) in Studio via `execute_luau`, or the Open Cloud Luau Execution API once a key and test place exist (BLOCKED_EXTERNAL, gap-matrix D03).

## Procedure
1. Split the module: a pure core with the env injected as the last parameter (no `game`, `task`, `os.time`, `math.random`, `Instance.new` or `GetService`), and a thin `<Name>Roblox.luau` adapter with `-- @tier` (and `-- probe:` at T3).
2. Write `tests/<area>.spec.luau` returning `{ { name, fn = function(t) ... end } }`. Drive yielding code on FakeEnv threads and advance the clock; inject failures through the fakes (`fail(n)`, latency, session steals, duplicate receipts).
3. Cover the closed reason lists: every reject reason has a case, plus at least one failure path per public function. Pin deterministic outputs (plans, layouts, event mappings) with a Golden; explain any golden change.
4. Check the specs bite: mutate a guard condition (for example invert a check), confirm a test fails, then restore. Keep survivors only when the mutant is provably equivalent.
5. Run `lune run tests/run.luau <area>`, then the full suite and `lune run tests/runtime/run.luau`; keep it under a few seconds per spec.
6. Run PRE_COMMIT (luau-quality), which runs every spec plus the inherited suites.

## Outputs
New or updated `tests/*.spec.luau` files, fakes or goldens as needed, and a green `N passed, 0 failed` runner line.

## Acceptance
New logic has specs including at least one failure case; T3 adapters have a registered probe; the suite is green in `python3 tools/check.py`.

## Failure
- A spec needs Roblox services: extract the logic into the core, or add a fake with the documented method names; Studio-only behaviour becomes a probe.
- `require` hangs or errors inside a spawned thread: move it to the top of the spec.
- Flaky results: remove time and `math.random` dependence; use `packages/ProcGen/Rng.luau` with a fixed seed and the FakeEnv clock.
- Never skip, weaken or delete a test to get green; never update a golden to hide an unexplained change.

## Related
luau-quality, roblox-persistence-and-commerce, roblox-multiplayer-integrity, roblox-procedural-generation.
