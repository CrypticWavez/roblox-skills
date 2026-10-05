---
name: roblox-performance-pass
description: Measure and fix Roblox performance - frame time (MicroProfiler), memory and instance counts, part/triangle budgets, connections and loops, replication bandwidth, UI churn, VFX lifetime - with numbers before and after. Use for lag, frame drops, memory growth, server heartbeat issues.
---

# Performance pass

**Gate.** Production skill: it acts on a game repository only after an explicit game-build request (see `FUTURE_GAME_BUILD_PROMPT.md` in the workbench). In this factory repo, run it only against fixtures. Never publish, spend Robux, create live products or touch production data without fresh approval.

## Procedure
1. Baseline numbers in the right mode (client FPS in Test; server heartbeat and memory in Server & Clients): MicroProfiler dumps, Developer Console memory, instance and part counts, `Stats` network KB/s.
2. Static checks: SceneKit/ProcGen `maxParts` budgets, Blender QA triangle budgets, per-frame loops (RenderStepped/Heartbeat), connections without cleanup, `while true` without yields, frequent remote traffic.
3. Fix highest cost first: merge static geometry, stream large worlds (StreamingEnabled), pool VFX (`Creator/EffectsPool.luau`, `Runtime/Lifetime.luau`), throttle replication, disconnect on cleanup.
4. Re-measure with the same scenario; record before/after.

**Acceptance.** Stated budgets met on the target device class with recorded numbers; no regression in correctness tests.

**References.** `references/legacy-performance-profiling.md`.

**Related.** roblox-scene-authoring, roblox-release-pass.
