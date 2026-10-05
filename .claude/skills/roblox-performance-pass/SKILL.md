---
name: roblox-performance-pass
description: Measure and fix Roblox performance - frame time (MicroProfiler), memory and instance counts, part/triangle budgets, connections and loops, replication bandwidth, UI churn, VFX lifetime - with numbers before and after. Use for lag, frame drops, memory growth, server heartbeat issues.
---

# Performance pass

## Purpose
Performance claims backed by numbers measured before and after each fix, in the Studio mode where the cost occurs. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures.

## Triggers
Lag, frame drops, memory growth, server heartbeat drops, long load times, part or triangle budgets exceeded.

## Inputs
The scenario that is slow, target device classes and budgets (frame time, memory, parts, triangles, network KB/s), the current build.

## Required context
`references/legacy-performance-profiling.md`; budget sources: SceneKit `Validate.scene(scene, { maxParts })` (default 5000), ProcGen rule `maxParts` (`performance_part_estimate`), Blender `BUDGETS` in `tools/blender/bkit/qa.py`.

## Tools
Studio MicroProfiler and Developer Console (memory, `Stats` network KB/s), Studio MCP `start_stop_play`, `execute_luau`, `get_console_output`; `packages/Creator/EffectsPool.luau` and `packages/Runtime/Lifetime.luau` for bounded VFX lifetimes.

## Procedure
1. Baseline in the right mode (client FPS in Test; server heartbeat and memory in Server & Clients): MicroProfiler dumps, Developer Console memory, instance and part counts, network KB/s.
2. Static checks: part budgets from SceneKit/ProcGen validation, Blender QA triangle budgets, per-frame loops (RenderStepped/Heartbeat), connections without cleanup, `while true` without yields, frequent remote traffic.
3. Fix the highest cost first: merge static geometry, stream large worlds (StreamingEnabled), pool and bound VFX (EffectsPool, Lifetime), throttle replication, disconnect on cleanup.
4. Re-measure with the same scenario and record before/after.

## Outputs
A before/after table per metric and scenario (mode, device class, value, budget) and the fixes made.

## Acceptance
Stated budgets met on the target device class with recorded numbers; correctness tests still pass.

## Failure
- Numbers vary run to run: repeat the scenario and report the median, not the best run.
- The cost is on a device you do not have: record it as unverified (device emulation is not physical-device evidence).

## Related
roblox-scene-authoring, roblox-procedural-generation, roblox-release-pass.
